// Ollama 本地模型提供者（原生 API）。
//
// 对应 C# 源文件 `Services/Ollama/OllamaApiService.cs`。与 OpenAI 兼容模式不同，
// Ollama 原生接口使用**裸 NDJSON** 流式协议：每个响应行是一个独立 JSON 对象，
// **没有** `data: ` 前缀、也**没有** `[DONE]` 终止标记；流以最后一个携带
// `"done": true` 的对象结束。因此本类的 [chatStream] 直接按行解析 JSON，不复用
// SSE 的 `data: ` 剥离逻辑。
//
// 其余要点：
// - `ProviderType` = [ModelProviderType.local]。
// - 端点：`/api/version`、`/api/tags`、`/api/chat`、`/api/generate`、`/api/pull`。
// - 使用 [Semaphore] 做并发限流（对应 C# `SemaphoreSlim`）。
// - 不直接 `import 'dart:io'`，可在 Web 端编译（仅发起 HTTP 请求）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/chat.dart';
import '../models/provider.dart';
import '../utils/output_sanitizer.dart';
import '../utils/semaphore.dart';

/// Ollama 配置。
class OllamaConfiguration implements IModelConfiguration {
  @override
  final String providerName;
  final String baseUrl;
  final String defaultModel;
  final int maxConcurrency;
  final int keepAlive;
  final Map<String, dynamic> options;

  /// 构造 Ollama 配置。
  OllamaConfiguration({
    this.providerName = 'Ollama',
    this.baseUrl = 'http://localhost:11434',
    this.defaultModel = 'qwen2.5:7b',
    this.maxConcurrency = 4,
    this.keepAlive = 5,
    this.options = const {},
  });

  /// 构造 Ollama 配置（便捷工厂）。
  factory OllamaConfiguration.local(
          {String baseUrl = 'http://localhost:11434',
          String defaultModel = 'qwen2.5:7b'}) =>
      OllamaConfiguration(baseUrl: baseUrl, defaultModel: defaultModel);

  @override
  bool isValid() => baseUrl.isNotEmpty && getValidationErrors().isEmpty;

  @override
  List<String> getValidationErrors() {
    final errors = <String>[];
    if (baseUrl.trim().isEmpty) errors.add('Ollama 基础地址不能为空');
    return errors;
  }
}

/// Ollama 本地模型提供者。
class OllamaProvider implements IModelProvider {
  final String registeredProviderName;
  final Logger _logger;
  final http.Client _client;
  final Semaphore _semaphore;

  OllamaConfiguration _configuration =
      OllamaConfiguration();
  var _isAvailable = false;
  var _disposed = false;
  ProviderStatistics _statistics = const ProviderStatistics();

  final StreamController<ModelConfigurationChangedEventArgs>
      _configChangedController =
      StreamController<ModelConfigurationChangedEventArgs>.broadcast();
  final StreamController<ConnectionStatusChangedEventArgs>
      _connectionChangedController =
      StreamController<ConnectionStatusChangedEventArgs>.broadcast();

  /// 构造 Ollama 提供者。
  OllamaProvider({
    this.registeredProviderName = 'Ollama',
    http.Client? client,
    Logger? logger,
    int maxConcurrency = 4,
  })  : _client = client ?? http.Client(),
        _logger = logger ?? Logger('Ollama.$registeredProviderName'),
        _semaphore = Semaphore(maxConcurrency);

  @override
  String get providerName => _configuration.providerName.isEmpty
      ? registeredProviderName
      : _configuration.providerName;

  @override
  ModelProviderType get providerType => ModelProviderType.local;

  @override
  bool get isAvailable => _isAvailable;

  @override
  Stream<ModelConfigurationChangedEventArgs> get configurationChanged =>
      _configChangedController.stream;

  @override
  Stream<ConnectionStatusChangedEventArgs> get connectionStatusChanged =>
      _connectionChangedController.stream;

  @override
  Future<bool> initialize(IModelConfiguration configuration) async {
    if (_disposed) return false;
    if (configuration is! OllamaConfiguration) {
      _logger.severe('配置类型不匹配，期望 OllamaConfiguration');
      return false;
    }
    try {
      final old = _configuration;
      _configuration = configuration;
      _configChangedController
          .add(ModelConfigurationChangedEventArgs(_configuration, old));
      _isAvailable = (await testConnection()).isSuccess;
      _logger.info('Ollama 提供者初始化: $providerName, 可用: $_isAvailable');
      return _isAvailable;
    } catch (e, st) {
      _logger.severe('Ollama 提供者初始化失败', e, st);
      _isAvailable = false;
      return false;
    }
  }

  @override
  Future<ConnectionTestResult> testConnection() async {
    final startTime = DateTime.now();
    try {
      final resp = await _client.get(
        Uri.parse(_endpoint('api/version')),
      );
      final elapsed = DateTime.now().difference(startTime);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        Map<String, dynamic> serverInfo = const {};
        try {
          serverInfo = jsonDecode(resp.body) as Map<String, dynamic>;
        } catch (_) {
          serverInfo = const {};
        }
        _setConnected(true);
        return ConnectionTestResult(
          isSuccess: true,
          responseTime: elapsed,
          serverInfo: serverInfo,
        );
      }
      _setConnected(false, 'HTTP ${resp.statusCode}');
      return ConnectionTestResult(
        isSuccess: false,
        responseTime: elapsed,
        errorMessage: 'HTTP ${resp.statusCode}: ${resp.body}',
      );
    } catch (e) {
      _setConnected(false, e.toString());
      return ConnectionTestResult(
        isSuccess: false,
        responseTime: DateTime.now().difference(startTime),
        errorMessage: e.toString(),
      );
    }
  }

  @override
  Future<List<ModelInfo>> getAvailableModels() async {
    try {
      final resp = await _client.get(Uri.parse(_endpoint('api/tags')));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return const [];
      final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
      final models = parsed['models'] as List<dynamic>? ?? const [];
      return models
          .whereType<Map<String, dynamic>>()
          .map((m) => ModelInfo(
                id: (m['name'] as String?) ?? '',
                name: (m['name'] as String?) ?? '',
                description: (m['details'] is Map
                    ? (m['details'] as Map)['family']?.toString()
                    : null) ??
                    '',
                isDownloaded: true,
              ))
          .toList();
    } catch (e, st) {
      _logger.warning('获取 Ollama 模型列表失败', e, st);
      return const [];
    }
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    final startTime = DateTime.now();
    await _semaphore.acquire();
    try {
      final body = _buildChatBody(request, stream: false);
      final resp = await _client.post(
        Uri.parse(_endpoint('api/chat')),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      final elapsed = DateTime.now().difference(startTime);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final error = ChatResponse(
          isSuccess: false,
          errorMessage: 'HTTP ${resp.statusCode}: ${resp.body}',
          responseTime: elapsed,
        );
        _updateStats(error, elapsed);
        return error;
      }
      final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
      final message = parsed['message'];
      final content = message is Map
          ? AIOutputSanitizer.extractVisibleContent(message['content'] as String?)
          : '';
      final success = ChatResponse(
        model: request.model.isEmpty ? _configuration.defaultModel : request.model,
        content: content,
        finishReason: parsed['done'] == true ? 'stop' : '',
        responseTime: elapsed,
        isSuccess: true,
      );
      _updateStats(success, elapsed);
      return success;
    } catch (e, st) {
      _logger.severe('Ollama Chat 请求失败', e, st);
      final error = ChatResponse(
        isSuccess: false,
        errorMessage: e.toString(),
        responseTime: DateTime.now().difference(startTime),
      );
      _updateStats(error, error.responseTime);
      return error;
    } finally {
      _semaphore.release();
    }
  }

  @override
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk) onChunkReceived,
  ) async {
    final startTime = DateTime.now();
    await _semaphore.acquire();
    final fullContent = StringBuffer();
    try {
      final body = _buildChatBody(request, stream: true);
      final httpRequest = http.Request('POST', Uri.parse(_endpoint('api/chat')));
      httpRequest.headers['Content-Type'] = 'application/json';
      httpRequest.body = jsonEncode(body);

      // 真流式 + 裸 NDJSON：无 `data: ` 前缀，按行解析每个 JSON 对象。
      final response = await _client.send(httpRequest);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errBody = await response.stream.bytesToString();
        final error = ChatResponse(
          isSuccess: false,
          errorMessage: 'HTTP ${response.statusCode}: $errBody',
          responseTime: DateTime.now().difference(startTime),
        );
        _updateStats(error, error.responseTime);
        return error;
      }

      String? finishReason;
      await for (final line
          in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final obj = jsonDecode(trimmed) as Map<String, dynamic>;
          final message = obj['message'] as Map<String, dynamic>?;
          final delta =
              message == null ? null : (message['content'] as String? ?? '');
          final visible = AIOutputSanitizer.extractVisibleContent(delta);
          if (visible.isNotEmpty) {
            fullContent.write(visible);
            onChunkReceived(ChatChunk(content: visible, isComplete: false));
          }
          if (obj['done'] == true) {
            finishReason = obj['done_reason'] as String? ?? 'stop';
          }
        } catch (_) {
          // 忽略单行解析失败。
        }
      }
      onChunkReceived(ChatChunk(isComplete: true, finishReason: finishReason));
      final success = ChatResponse(
        content: fullContent.toString(),
        model: request.model.isEmpty ? _configuration.defaultModel : request.model,
        finishReason: finishReason ?? 'stop',
        responseTime: DateTime.now().difference(startTime),
        isSuccess: true,
      );
      _updateStats(success, success.responseTime);
      return success;
    } catch (e, st) {
      _logger.severe('Ollama 流式 Chat 请求失败', e, st);
      final error = ChatResponse(
        content: fullContent.toString(),
        isSuccess: false,
        errorMessage: e.toString(),
        responseTime: DateTime.now().difference(startTime),
      );
      _updateStats(error, error.responseTime);
      return error;
    } finally {
      _semaphore.release();
    }
  }

  @override
  Future<ProviderStatistics> getStatistics() async => _statistics;

  @override
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      _configChangedController.close();
      _connectionChangedController.close();
      _client.close();
    }
  }

  // ----- 内部实现 -----

  String _endpoint(String relative) =>
      '${_configuration.baseUrl.trim().replaceAll(RegExp(r'/$'), '')}/${relative.trim().replaceAll(RegExp(r'^/'), '')}';

  Map<String, dynamic> _buildChatBody(ChatRequest request, {required bool stream}) {
    final messages = <Map<String, dynamic>>[];
    if (request.systemPrompt != null && request.systemPrompt!.isNotEmpty) {
      messages.add({'role': 'system', 'content': request.systemPrompt!});
    }
    for (final m in request.messages) {
      messages.add({'role': m.role.name, 'content': m.content});
    }
    final options = <String, dynamic>{
      'temperature': request.temperature,
      'num_predict': request.maxTokens,
      'keep_alive': '${_configuration.keepAlive}m',
    }..addAll(_configuration.options);
    return {
      'model': request.model.isEmpty ? _configuration.defaultModel : request.model,
      'messages': messages,
      'stream': stream,
      'options': options,
    };
  }

  void _setConnected(bool connected, [String? errorMessage]) {
    if (_isAvailable != connected) {
      _isAvailable = connected;
      _connectionChangedController
          .add(ConnectionStatusChangedEventArgs(connected, errorMessage));
    } else {
      _isAvailable = connected;
    }
  }

  void _updateStats(ChatResponse response, Duration elapsed) {
    final total = _statistics.totalRequests + 1;
    final success = _statistics.successfulRequests + (response.isSuccess ? 1 : 0);
    final failed = _statistics.failedRequests + (response.isSuccess ? 0 : 1);
    final avgMs = _statistics.totalRequests == 0
        ? elapsed.inMilliseconds
        : ((_statistics.averageResponseTime.inMilliseconds *
                    _statistics.totalRequests +
                elapsed.inMilliseconds) /
                total)
            .round();
    _statistics = ProviderStatistics(
      totalRequests: total,
      successfulRequests: success,
      failedRequests: failed,
      averageResponseTime: Duration(milliseconds: avgMs),
      totalTokensUsed: _statistics.totalTokensUsed,
      lastRequestTime: DateTime.now(),
    );
  }
}
