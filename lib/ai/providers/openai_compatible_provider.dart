// OpenAI 兼容接口提供者（通用实现）。
//
// 对应 C# 源文件 `Services/OpenAICompatible/OpenAICompatibleProvider.cs` 与
// `Services/OpenAICompatible/Models/OpenAICompatibleConfiguration.cs`。
//
// 与 C# 的差异 / 约定：
// - 移除 `CancellationToken`，超时由调用方 `Future.timeout` 控制（此处不内置）。
// - `event EventHandler<T>` 改为由本类持有的 `StreamController<T>.broadcast()`
//   暴露只读 [Stream]（见 [configurationChanged] / [connectionStatusChanged]）。
// - 流式响应严格使用 `http.Request` + `client.send` + `response.stream`
//   的逐行解析，**禁止** `http.post` 缓冲整段响应（C# 用
//   `HttpCompletionOption.ResponseHeadersRead` 达到同样效果）。
// - SSE 行以 `data: ` 前缀识别，`[DONE]` 终止。
// - `ProviderKind` 特例：智谱（ZhipuAI）temperature 收敛到 (0,1]；
//   小米米模（XiaoMiMiMo）改用 `max_completion_tokens` 并额外带 `api-key` 头。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/chat.dart';
import '../models/provider.dart';
import '../utils/output_sanitizer.dart';

/// OpenAI 兼容接口配置。
///
/// 对应 C# `OpenAICompatibleConfiguration`。`providerKind` 决定供应商特例行为，
/// `baseUrl` 应为去尾 `/` 的基础地址（如 `https://api.deepseek.com/v1`）。
class OpenAICompatibleConfiguration implements IModelConfiguration {
  @override
  String providerName;
  String providerKind;
  String baseUrl;
  String apiKey;
  String defaultModel;
  int timeoutSeconds;
  int maxRetries;
  double defaultTemperature;
  int defaultMaxTokens;
  bool enableStreaming;
  Map<String, String> customHeaders;

  /// 构造 OpenAI 兼容配置。
  OpenAICompatibleConfiguration({
    this.providerName = 'OpenAICompatible',
    this.providerKind = 'Custom',
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.defaultModel = 'gpt-3.5-turbo',
    this.timeoutSeconds = 120,
    this.maxRetries = 3,
    this.defaultTemperature = 0.7,
    this.defaultMaxTokens = 4000,
    this.enableStreaming = true,
    Map<String, String>? customHeaders,
  }) : customHeaders = customHeaders ?? <String, String>{};

  @override
  bool isValid() => baseUrl.isNotEmpty && getValidationErrors().isEmpty;

  @override
  List<String> getValidationErrors() {
    final errors = <String>[];
    if (baseUrl.trim().isEmpty) errors.add('API 基础地址不能为空');
    final isLocal = const {
      'ollama',
      'llamacpp',
      'rwkv',
    }.contains(providerKind.toLowerCase());
    if (!isLocal && apiKey.trim().isEmpty) errors.add('API Key 不能为空');
    return errors;
  }

  /// 创建智谱 AI 配置。
  factory OpenAICompatibleConfiguration.zhipuAI(
          String apiKey, String model) =>
      OpenAICompatibleConfiguration(
        providerName: 'ZhipuAI',
        providerKind: 'ZhipuAI',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: apiKey,
        defaultModel: model,
      );

  /// 创建 Ollama（OpenAI 兼容 /v1 模式）配置。
  factory OpenAICompatibleConfiguration.ollama(
          String baseUrl, String model) =>
      OpenAICompatibleConfiguration(
        providerName: 'Ollama',
        providerKind: 'Ollama',
        baseUrl: '${baseUrl.trim().replaceAll(RegExp(r'/$'), '')}/v1',
        apiKey: 'ollama',
        defaultModel: model,
      );
}

/// 通用 OpenAI 兼容提供者。
///
/// 可被 DeepSeek / 智谱 / RWKV 等子类继承，仅需通过配置指定 `providerKind`、
/// `baseUrl` 与 `defaultModel` 即可复用全部请求 / 流式 / 统计逻辑。
class OpenAICompatibleProvider implements IModelProvider {
  /// 注册名（用于注册表唯一键）。
  final String registeredProviderName;

  final Logger _logger;
  final http.Client _client;

  OpenAICompatibleConfiguration _configuration =
      OpenAICompatibleConfiguration();

  /// 当前生效的配置（只读）。
  ///
  /// 供子类扩展用（例如 `RwkvCloudProvider` 需要读 baseUrl 去探
  /// `/v1/server/status`，以及重新灌 Cloudflare 头）。
  OpenAICompatibleConfiguration get configuration => _configuration;

  /// 底层 HTTP 客户端（只读）。
  ///
  /// ⚠ 共享给子类复用，**不要 close** —— 生命周期归本 provider 管。
  http.Client get httpClient => _client;

  var _isAvailable = false;
  var _disposed = false;
  ProviderStatistics _statistics = const ProviderStatistics();

  final StreamController<ModelConfigurationChangedEventArgs>
      _configChangedController =
      StreamController<ModelConfigurationChangedEventArgs>.broadcast();
  final StreamController<ConnectionStatusChangedEventArgs>
      _connectionChangedController =
      StreamController<ConnectionStatusChangedEventArgs>.broadcast();

  /// 构造通用 OpenAI 兼容提供者。
  OpenAICompatibleProvider({
    required this.registeredProviderName,
    http.Client? client,
    Logger? logger,
  })  : _client = client ?? http.Client(),
        _logger = logger ?? Logger('OpenAICompatible.$registeredProviderName');

  @override
  String get providerName {
    final cfg = _configuration;
    if (cfg.providerName.trim().isEmpty ||
        (cfg.providerName.toLowerCase() == 'openaicompatible' &&
            registeredProviderName.toLowerCase() != 'openaicompatible')) {
      return registeredProviderName;
    }
    return cfg.providerName;
  }

  @override
  ModelProviderType get providerType => ModelProviderType.cloudApi;

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
    if (configuration is! OpenAICompatibleConfiguration) {
      _logger.severe('配置类型不匹配，期望 OpenAICompatibleConfiguration');
      return false;
    }
    final config = configuration;
    try {
      final old = _configuration;
      _configuration = _normalize(config);
      _configChangedController
          .add(ModelConfigurationChangedEventArgs(_configuration, old));

      _isAvailable = (await testConnection()).isSuccess;
      _logger.info('OpenAI 兼容提供者初始化: $providerName '
          '(${_configuration.providerKind}), 可用: $_isAvailable');
      return _isAvailable;
    } catch (e, st) {
      _logger.severe('OpenAI 兼容提供者初始化失败', e, st);
      _isAvailable = false;
      return false;
    }
  }

  @override
  Future<ConnectionTestResult> testConnection() async {
    final startTime = DateTime.now();
    try {
      // 优先探测 /models 端点。
      final modelsResp = await _client.get(
        Uri.parse(_endpoint('models')),
        headers: _defaultHeaders(),
      );
      final elapsed = DateTime.now().difference(startTime);
      if (modelsResp.statusCode >= 200 && modelsResp.statusCode < 300) {
        List<dynamic>? dataList;
        try {
          final parsed =
              jsonDecode(modelsResp.body) as Map<String, dynamic>;
          dataList = parsed['data'] as List<dynamic>?;
        } catch (_) {
          dataList = null;
        }
        _setConnected(true);
        return ConnectionTestResult(
          isSuccess: true,
          responseTime: elapsed,
          serverInfo: {
            'endpoint': _endpoint('models'),
            'modelCount': dataList?.length ?? 0,
          },
        );
      }
      // 回退：用一个最小 chat 请求探活。
      final probe = await _probeChat(startTime);
      if (probe.isSuccess) return probe;
      _setConnected(false, 'HTTP ${modelsResp.statusCode}');
      return ConnectionTestResult(
        isSuccess: false,
        responseTime: elapsed,
        errorMessage: 'HTTP ${modelsResp.statusCode}: ${modelsResp.body}',
      );
    } catch (e) {
      final probe = await _probeChat(startTime);
      if (probe.isSuccess) return probe;
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
      final resp = await _client.get(
        Uri.parse(_endpoint('models')),
        headers: _defaultHeaders(),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return _fallbackModels();
      }
      final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = parsed['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return _fallbackModels();
      return data
          .whereType<Map<String, dynamic>>()
          .map((m) => ModelInfo(
                id: (m['id'] as String?) ?? '',
                name: (m['id'] as String?) ?? '',
                description: (m['owned_by'] as String?) ?? '',
                isDownloaded: true,
              ))
          .toList();
    } catch (e, st) {
      _logger.warning('获取模型列表失败', e, st);
      return _fallbackModels();
    }
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    final startTime = DateTime.now();
    try {
      final openAiReq = _convertRequest(request, stream: false);
      final resp = await _client.post(
        Uri.parse(_endpoint('chat/completions')),
        headers: {
          ..._defaultHeaders(),
          'Content-Type': 'application/json',
        },
        body: jsonEncode(openAiReq.toJson()),
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
      final openAiResp = OpenAIChatResponse.fromJson(parsed);
      final choice = openAiResp.choices.isNotEmpty ? openAiResp.choices.first : null;
      final visible = AIOutputSanitizer.extractVisibleContent(
        choice?.message?.content,
        choice?.message?.reasoningContent,
      );
      final success = ChatResponse(
        id: openAiResp.id ?? '',
        model: openAiResp.model ?? request.model,
        content: visible,
        finishReason: choice?.finishReason ?? '',
        usage: openAiResp.usage?.toTokenUsage(),
        responseTime: elapsed,
        isSuccess: true,
      );
      _updateStats(success, elapsed);
      return success;
    } catch (e, st) {
      _logger.severe('Chat 请求失败', e, st);
      final error = ChatResponse(
        isSuccess: false,
        errorMessage: e.toString(),
        responseTime: DateTime.now().difference(startTime),
      );
      _updateStats(error, error.responseTime);
      return error;
    }
  }

  @override
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk) onChunkReceived,
  ) async {
    final startTime = DateTime.now();
    final fullContent = StringBuffer();
    try {
      final openAiReq = _convertRequest(request, stream: true);
      final httpRequest = http.Request(
        'POST',
        Uri.parse(_endpoint('chat/completions')),
      );
      httpRequest.headers.addAll({
        ..._defaultHeaders(),
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      });
      httpRequest.body = jsonEncode(openAiReq.toJson());

      // 真流式：必须用 send + response.stream，禁止 post() 缓冲。
      final response = await _client.send(httpRequest);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        final error = ChatResponse(
          isSuccess: false,
          errorMessage: 'HTTP ${response.statusCode}: $body',
          responseTime: DateTime.now().difference(startTime),
        );
        _updateStats(error, error.responseTime);
        return error;
      }

      String? finishReason;
      await for (final line
          in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;
        try {
          final chunk = OpenAIStreamChunk.fromJson(
              jsonDecode(data) as Map<String, dynamic>);
          final choice =
              chunk.choices.isNotEmpty ? chunk.choices.first : null;
          final delta = choice?.delta;
          final visible = AIOutputSanitizer.extractVisibleContent(
            delta?.content,
            delta?.reasoningContent,
          );
          if (visible.isNotEmpty) {
            fullContent.write(visible);
            onChunkReceived(ChatChunk(
              id: chunk.id ?? '',
              content: visible,
              isComplete: false,
            ));
          }
          finishReason ??= choice?.finishReason;
        } catch (_) {
          // 忽略单行解析失败，继续读取后续流。
        }
      }
      onChunkReceived(ChatChunk(
        isComplete: true,
        finishReason: finishReason,
      ));
      final success = ChatResponse(
        content: fullContent.toString(),
        model: request.model,
        finishReason: finishReason ?? 'stop',
        responseTime: DateTime.now().difference(startTime),
        isSuccess: true,
      );
      _updateStats(success, success.responseTime);
      return success;
    } catch (e, st) {
      _logger.severe('流式 Chat 请求失败', e, st);
      final error = ChatResponse(
        content: fullContent.toString(),
        isSuccess: false,
        errorMessage: e.toString(),
        responseTime: DateTime.now().difference(startTime),
      );
      _updateStats(error, error.responseTime);
      return error;
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

  Map<String, String> _defaultHeaders() {
    final headers = <String, String>{
      'Accept': 'application/json',
      'User-Agent': 'NovelCraft/1.0',
    };
    if (_configuration.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${_configuration.apiKey}';
    }
    if (_configuration.providerKind.toLowerCase() == 'xiaomimimo' &&
        _configuration.apiKey.isNotEmpty) {
      headers['api-key'] = _configuration.apiKey;
    }
    for (final entry in _configuration.customHeaders.entries) {
      if (entry.key.toLowerCase() == 'authorization') continue;
      headers[entry.key] = entry.value;
    }
    return headers;
  }

  String _endpoint(String relative) =>
      '${_configuration.baseUrl.replaceAll(RegExp(r'/$'), '')}/${relative.trim().replaceAll(RegExp(r'^/'), '')}';

  Future<ConnectionTestResult> _probeChat(DateTime startTime) async {
    try {
      final probe = OpenAIChatRequest(
        model: _configuration.defaultModel,
        messages: [const OpenAIMessage(role: 'user', content: 'ping')],
        temperature: _normalizeTemperature(-1),
        maxTokens: 1,
        stream: false,
      );
      final resp = await _client.post(
        Uri.parse(_endpoint('chat/completions')),
        headers: {
          ..._defaultHeaders(),
          'Content-Type': 'application/json',
        },
        body: jsonEncode(probe.toJson()),
      );
      final elapsed = DateTime.now().difference(startTime);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        _setConnected(true);
        return ConnectionTestResult(
          isSuccess: true,
          responseTime: elapsed,
          serverInfo: {
            'endpoint': _endpoint('chat/completions'),
            'probeMode': 'chat',
          },
        );
      }
    } catch (e) {
      _logger.fine('OpenAI 兼容聊天探活失败', e);
    }
    _setConnected(false);
    return ConnectionTestResult(
      isSuccess: false,
      responseTime: DateTime.now().difference(startTime),
      errorMessage: '模型列表与聊天探活均失败',
    );
  }

  OpenAICompatibleConfiguration _normalize(OpenAICompatibleConfiguration c) {
    final kind = c.providerKind.trim().isEmpty ? 'Custom' : c.providerKind.trim();
    return OpenAICompatibleConfiguration(
      providerName: c.providerName.trim().isEmpty ? 'OpenAICompatible' : c.providerName.trim(),
      providerKind: kind,
      baseUrl: c.baseUrl.trim().isEmpty ? 'https://api.openai.com/v1' : c.baseUrl.trim().replaceAll(RegExp(r'/$'), ''),
      apiKey: c.apiKey.trim(),
      defaultModel: c.defaultModel.trim().isEmpty ? 'gpt-3.5-turbo' : c.defaultModel.trim(),
      timeoutSeconds: c.timeoutSeconds > 0 ? c.timeoutSeconds : 120,
      maxRetries: max(0, c.maxRetries),
      defaultTemperature: c.defaultTemperature,
      defaultMaxTokens: c.defaultMaxTokens > 0 ? c.defaultMaxTokens : 4000,
      enableStreaming: c.enableStreaming,
      customHeaders: Map<String, String>.from(c.customHeaders),
    );
  }

  OpenAIChatRequest _convertRequest(ChatRequest request, {required bool stream}) {
    final messages = <OpenAIMessage>[];
    if (request.systemPrompt != null && request.systemPrompt!.isNotEmpty) {
      messages.add(OpenAIMessage(role: 'system', content: request.systemPrompt!));
    }
    for (final m in request.messages) {
      messages.add(OpenAIMessage(role: m.role.name, content: m.content));
    }
    final usesMaxCompletionTokens =
        _configuration.providerKind.toLowerCase() == 'xiaomimimo';
    return OpenAIChatRequest(
      model: request.model.isEmpty ? _configuration.defaultModel : request.model,
      messages: messages,
      temperature: _normalizeTemperature(request.temperature),
      maxTokens: usesMaxCompletionTokens
          ? null
          : (request.maxTokens > 0 ? request.maxTokens : _configuration.defaultMaxTokens),
      maxCompletionTokens: usesMaxCompletionTokens
          ? (request.maxTokens > 0 ? request.maxTokens : _configuration.defaultMaxTokens)
          : _tryInt(request.parameters['max_completion_tokens']),
      stream: stream,
      topP: _tryDouble(request.parameters['top_p']),
      frequencyPenalty: _tryDouble(request.parameters['frequency_penalty']),
      presencePenalty: _tryDouble(request.parameters['presence_penalty']),
      stop: _tryStop(request.parameters['stop']),
      extra: _buildExtraFields(request.parameters),
    );
  }

  double _normalizeTemperature(double requested) {
    var t = requested >= 0 ? requested : _configuration.defaultTemperature;
    if (_configuration.providerKind.toLowerCase() == 'zhipuai') {
      t = t <= 0 ? 0.7 : t;
      return min(max(t, 0.01), 1.0);
    }
    return t;
  }

  Map<String, dynamic> _buildExtraFields(Map<String, dynamic> parameters) {
    final extra = <String, dynamic>{};
    // 白名单放行：各家的扩展采样/结构参数。
    // 其中 RWKV 家族的 `top_k` / `alpha_*`（rwkv_lightning）与 `dry_*`（llama.cpp）
    // 由 `kRwkvAntiRepeatSampling` 提供，见 `ai/rwkv/rwkv_sampling.dart`。
    // ⚠ 只有 RWKV 家族才该收到这些键（其他厂商的严格 API 会 400），调用方负责判定。
    for (final key in const [
      'thinking',
      'response_format',
      'tools',
      'tool_choice',
      'stream_options',
      'user',
      // RWKV 原生采样
      'top_k',
      'alpha_presence',
      'alpha_frequency',
      'alpha_decay',
      'stop_tokens',
      'chunk_size',
      // llama.cpp DRY 采样器
      'dry_multiplier',
      'dry_base',
      'dry_allowed_length',
      'dry_penalty_last_n',
    ]) {
      if (parameters.containsKey(key) && parameters[key] != null) {
        extra[key] = parameters[key];
      }
    }
    return extra;
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
    final tokens = _statistics.totalTokensUsed +
        (response.usage?.totalTokens ?? 0);
    _statistics = ProviderStatistics(
      totalRequests: total,
      successfulRequests: success,
      failedRequests: failed,
      averageResponseTime: Duration(milliseconds: avgMs),
      totalTokensUsed: tokens,
      lastRequestTime: DateTime.now(),
    );
  }

  List<ModelInfo> _fallbackModels() {
    final models = <String>{};
    if (_configuration.defaultModel.isNotEmpty) {
      models.add(_configuration.defaultModel);
    }
    switch (_configuration.providerKind.toLowerCase()) {
      case 'zhipuai':
        models.addAll(const [
          'glm-4.7-flash',
          'glm-4-flash',
          'glm-4',
          'glm-4-plus',
          'glm-3-turbo',
        ]);
      case 'deepseek':
        models.addAll(const [
          'deepseek-v4-flash',
          'deepseek-v4-pro',
          'deepseek-chat',
          'deepseek-reasoner',
        ]);
      case 'xiaomimimo':
        models.addAll(const ['mimo-v2.5-pro', 'mimo-v2.5', 'mimo-v2-flash']);
    }
    return models
        .map((m) => ModelInfo(
              id: m,
              name: m,
              description: '${_configuration.providerName} 兼容接口模型',
              isDownloaded: true,
            ))
        .toList();
  }

  static double? _tryDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static int? _tryInt(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static dynamic _tryStop(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is List) {
      return value
          .map((e) => e?.toString())
          .where((e) => e != null && e.isNotEmpty)
          .toList();
    }
    return value.toString();
  }
}

/// OpenAI 聊天请求（内部数据模型，对应 C# `OpenAIChatRequest`）。
class OpenAIChatRequest {
  final String model;
  final List<OpenAIMessage> messages;
  final double temperature;
  final int? maxTokens;
  final int? maxCompletionTokens;
  final bool stream;
  final double? topP;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final dynamic stop;
  final Map<String, dynamic> extra;

  OpenAIChatRequest({
    required this.model,
    required this.messages,
    this.temperature = 0.7,
    this.maxTokens,
    this.maxCompletionTokens,
    this.stream = false,
    this.topP,
    this.frequencyPenalty,
    this.presencePenalty,
    this.stop,
    this.extra = const {},
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': temperature,
      'stream': stream,
    };
    if (maxTokens != null) json['max_tokens'] = maxTokens;
    if (maxCompletionTokens != null) {
      json['max_completion_tokens'] = maxCompletionTokens;
    }
    if (topP != null) json['top_p'] = topP;
    if (frequencyPenalty != null) json['frequency_penalty'] = frequencyPenalty;
    if (presencePenalty != null) json['presence_penalty'] = presencePenalty;
    if (stop != null) json['stop'] = stop;
    json.addAll(extra);
    return json;
  }
}

/// OpenAI 消息（内部数据模型，对应 C# `OpenAIMessage`）。
class OpenAIMessage {
  final String role;
  final String content;
  final String? reasoningContent;

  const OpenAIMessage({
    required this.role,
    required this.content,
    this.reasoningContent,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (reasoningContent != null) 'reasoning_content': reasoningContent,
      };

  factory OpenAIMessage.fromJson(Map<String, dynamic> json) => OpenAIMessage(
        role: json['role'] as String? ?? 'user',
        content: json['content'] as String? ?? '',
        reasoningContent: json['reasoning_content'] as String?,
      );
}

/// OpenAI 聊天响应（内部数据模型，对应 C# `OpenAIChatResponse`）。
class OpenAIChatResponse {
  final String? id;
  final String? model;
  final List<OpenAIChoice> choices;
  final OpenAIUsage? usage;

  OpenAIChatResponse({
    this.id,
    this.model,
    this.choices = const [],
    this.usage,
  });

  factory OpenAIChatResponse.fromJson(Map<String, dynamic> json) =>
      OpenAIChatResponse(
        id: json['id'] as String?,
        model: json['model'] as String?,
        choices: (json['choices'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(OpenAIChoice.fromJson)
                .toList() ??
            const [],
        usage: json['usage'] == null
            ? null
            : OpenAIUsage.fromJson(json['usage'] as Map<String, dynamic>),
      );
}

/// OpenAI 选项（内部数据模型，对应 C# `OpenAIChoice`）。
class OpenAIChoice {
  final OpenAIMessage? message;
  final String? finishReason;
  final OpenAIMessage? delta;

  OpenAIChoice({this.message, this.finishReason, this.delta});

  factory OpenAIChoice.fromJson(Map<String, dynamic> json) => OpenAIChoice(
        message: json['message'] == null
            ? null
            : OpenAIMessage.fromJson(json['message'] as Map<String, dynamic>),
        finishReason: json['finish_reason'] as String?,
        delta: json['delta'] == null
            ? null
            : OpenAIMessage.fromJson(json['delta'] as Map<String, dynamic>),
      );
}

/// OpenAI 使用量（内部数据模型，对应 C# `OpenAIUsage`）。
class OpenAIUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  OpenAIUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
  });

  factory OpenAIUsage.fromJson(Map<String, dynamic> json) => OpenAIUsage(
        promptTokens: json['prompt_tokens'] as int? ?? 0,
        completionTokens: json['completion_tokens'] as int? ?? 0,
        totalTokens: json['total_tokens'] as int? ?? 0,
      );

  TokenUsage toTokenUsage() => TokenUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens,
      );
}

/// OpenAI 流式分块（内部数据模型，对应 C# `OpenAIStreamChunk`）。
class OpenAIStreamChunk {
  final String? id;
  final List<OpenAIChoice> choices;

  OpenAIStreamChunk({this.id, this.choices = const []});

  factory OpenAIStreamChunk.fromJson(Map<String, dynamic> json) =>
      OpenAIStreamChunk(
        id: json['id'] as String?,
        choices: (json['choices'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(OpenAIChoice.fromJson)
                .toList() ??
            const [],
      );
}

/// OpenAI 模型列表响应（内部数据模型，对应 C# `OpenAIModelsResponse`）。
class OpenAIModelsResponse {
  final List<OpenAIModelItem> data;
  OpenAIModelsResponse({this.data = const []});

  factory OpenAIModelsResponse.fromJson(Map<String, dynamic> json) =>
      OpenAIModelsResponse(
        data: (json['data'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(OpenAIModelItem.fromJson)
                .toList() ??
            const [],
      );
}

/// OpenAI 模型项（内部数据模型，对应 C# `OpenAIModelItem`）。
class OpenAIModelItem {
  final String id;
  final String? ownedBy;
  OpenAIModelItem({this.id = '', this.ownedBy});

  factory OpenAIModelItem.fromJson(Map<String, dynamic> json) =>
      OpenAIModelItem(
        id: json['id'] as String? ?? '',
        ownedBy: json['owned_by'] as String?,
      );
}
