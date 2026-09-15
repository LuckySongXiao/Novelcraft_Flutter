// AI 模型管理器（注册表 + 路由器）。
//
// 对应 C# 源文件 `Services/ModelManager.cs`。职责：
// 1. 注册 / 注销 [IModelProvider]，首注册者自动成为默认提供者。
// 2. [ResolvePreferredProviderName] 的回退策略：首选 → 首个可用 → 首个已注册。
// 3. [chat] / [chatStream] 按提供者名（默认提供者）路由，并在失败时返回带
//    错误信息的 [ChatResponse]。
// 4. 维护各提供者的累计统计（平均响应时间采用累进平均，与 C# 一致）。
// 5. C# 的 `event` 改为由 `StreamController` 暴露的只读 [Stream]
//    （[providerChanged] / [modelResponse] / [errorOccurred]）。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../models/chat.dart';
import '../models/provider.dart';

/// 提供者变更事件参数（对应 C# `ProviderChangedEventArgs`）。
class ProviderChangedEventArgs {
  final String oldProviderName;
  final String newProviderName;
  ProviderChangedEventArgs(this.oldProviderName, this.newProviderName);
}

/// 模型响应事件参数（对应 C# `ModelResponseEventArgs`）。
class ModelResponseEventArgs {
  final String providerName;
  final ChatRequest request;
  final ChatResponse response;
  ModelResponseEventArgs(this.providerName, this.request, this.response);
}

/// 模型错误事件参数（对应 C# `ModelErrorEventArgs`）。
class ModelErrorEventArgs {
  final String providerName;
  final String errorMessage;
  final Object? exception;
  ModelErrorEventArgs(this.providerName, this.errorMessage, [this.exception]);
}

/// AI 模型管理器。
class ModelManager {
  final Logger _logger;
  final Map<String, IModelProvider> _providers = {};
  final Map<String, ProviderStatistics> _statistics = {};
  String _defaultProvider = '';
  var _disposed = false;

  final StreamController<ProviderChangedEventArgs> _providerChangedController =
      StreamController<ProviderChangedEventArgs>.broadcast();
  final StreamController<ModelResponseEventArgs> _modelResponseController =
      StreamController<ModelResponseEventArgs>.broadcast();
  final StreamController<ModelErrorEventArgs> _errorController =
      StreamController<ModelErrorEventArgs>.broadcast();

  /// 构造模型管理器。
  ModelManager({Logger? logger}) : _logger = logger ?? Logger('ModelManager');

  /// 提供者变更事件流。
  Stream<ProviderChangedEventArgs> get providerChanged =>
      _providerChangedController.stream;

  /// 模型响应事件流。
  Stream<ModelResponseEventArgs> get modelResponse =>
      _modelResponseController.stream;

  /// 错误事件流。
  Stream<ModelErrorEventArgs> get errorOccurred => _errorController.stream;

  /// 注册模型提供者；首个注册者自动成为默认提供者。
  bool registerProvider(IModelProvider provider) {
    if (_providers.containsKey(provider.providerName)) {
      _logger.warning('提供者已存在: ${provider.providerName}');
      return false;
    }
    _providers[provider.providerName] = provider;
    _statistics[provider.providerName] = const ProviderStatistics();
    // 订阅子提供者的连接状态变更，向上转发电离线错误。
    provider.connectionStatusChanged.listen((e) {
      if (!e.isConnected && e.errorMessage != null && e.errorMessage!.isNotEmpty) {
        _errorController.add(
            ModelErrorEventArgs(provider.providerName, e.errorMessage!));
      }
    });
    if (_defaultProvider.isEmpty) {
      _defaultProvider = provider.providerName;
      _logger.info('自动设置默认提供者: ${provider.providerName}');
    }
    _logger.info('注册模型提供者成功: ${provider.providerName}');
    return true;
  }

  /// 注销模型提供者并释放其资源。
  bool unregisterProvider(String providerName) {
    final provider = _providers.remove(providerName);
    if (provider == null) {
      _logger.warning('提供者不存在: $providerName');
      return false;
    }
    _statistics.remove(providerName);
    try {
      provider.dispose();
    } catch (e, st) {
      _logger.severe('释放提供者资源失败: $providerName', e, st);
    }
    if (_defaultProvider == providerName) {
      _defaultProvider = _providers.keys.firstOrNull ?? '';
    }
    _logger.info('注销模型提供者成功: $providerName');
    return true;
  }

  /// 获取指定提供者。
  IModelProvider? getProvider(String providerName) => _providers[providerName];

  /// 获取所有提供者。
  List<IModelProvider> getAllProviders() => _providers.values.toList();

  /// 获取所有当前可用的提供者。
  List<IModelProvider> getAvailableProviders() =>
      _providers.values.where((p) => p.isAvailable).toList();

  /// 设置默认提供者。
  bool setDefaultProvider(String providerName) {
    if (!_providers.containsKey(providerName)) {
      _logger.warning('设置默认提供者失败，提供者不存在: $providerName');
      return false;
    }
    final old = _defaultProvider;
    _defaultProvider = providerName;
    _logger.info('默认提供者已更改: $old -> $providerName');
    _providerChangedController.add(ProviderChangedEventArgs(old, providerName));
    return true;
  }

  /// 获取默认提供者（经回退策略解析）。
  IModelProvider? getDefaultProvider() {
    final name = resolvePreferredProviderName(_defaultProvider);
    return name == null ? null : _providers[name];
  }

  /// 使用默认提供者发起非流式聊天。
  Future<ChatResponse> chat(ChatRequest request) =>
      chatWith(request, _defaultProvider);

  /// 使用默认提供者发起流式聊天。
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk) onChunkReceived,
  ) =>
      chatStreamWith(request, _defaultProvider, onChunkReceived);

  /// 使用指定提供者发起非流式聊天。
  Future<ChatResponse> chatWith(ChatRequest request, String providerName) async {
    final start = DateTime.now();
    final resolved = resolvePreferredProviderName(providerName);
    final provider = resolved == null ? null : _providers[resolved];
    if (provider == null) {
      return _fail('提供者不存在: $providerName', start, providerName);
    }
    if (!provider.isAvailable) {
      return _fail('提供者不可用: $providerName', start, providerName);
    }
    try {
      final response = await provider.chat(request);
      _updateStatistics(provider.providerName, response);
      _modelResponseController
          .add(ModelResponseEventArgs(provider.providerName, request, response));
      return response;
    } catch (e, st) {
      _logger.severe('聊天请求失败: $providerName', e, st);
      return _fail(e.toString(), start, providerName);
    }
  }

  /// 使用指定提供者发起流式聊天。
  Future<ChatResponse> chatStreamWith(
    ChatRequest request,
    String providerName,
    void Function(ChatChunk) onChunkReceived,
  ) async {
    final start = DateTime.now();
    final resolved = resolvePreferredProviderName(providerName);
    final provider = resolved == null ? null : _providers[resolved];
    if (provider == null) {
      return _fail('提供者不存在: $providerName', start, providerName);
    }
    if (!provider.isAvailable) {
      return _fail('提供者不可用: $providerName', start, providerName);
    }
    try {
      final response = await provider.chatStream(request, onChunkReceived);
      _updateStatistics(provider.providerName, response);
      _modelResponseController
          .add(ModelResponseEventArgs(provider.providerName, request, response));
      return response;
    } catch (e, st) {
      _logger.severe('流式聊天请求失败: $providerName', e, st);
      return _fail(e.toString(), start, providerName);
    }
  }

  /// 获取所有提供者的可用模型。
  Future<Map<String, List<ModelInfo>>> getAllAvailableModels() async {
    final result = <String, List<ModelInfo>>{};
    for (final provider in _providers.values) {
      try {
        result[provider.providerName] =
            provider.isAvailable ? await provider.getAvailableModels() : const [];
      } catch (e, st) {
        _logger.severe('获取模型列表失败: ${provider.providerName}', e, st);
        result[provider.providerName] = const [];
      }
    }
    return result;
  }

  /// 解析首选提供者名称；若首选不可用则回退到首个可用，再回退首个已注册。
  String? resolvePreferredProviderName([String? preferredProviderName]) {
    if (preferredProviderName != null &&
        preferredProviderName.trim().isNotEmpty &&
        _providers.containsKey(preferredProviderName)) {
      final p = _providers[preferredProviderName]!;
      if (p.isAvailable) return preferredProviderName;
    }
    final firstAvailable = _providers.values
        .where((p) => p.isAvailable)
        .firstOrNull;
    if (firstAvailable != null) return firstAvailable.providerName;
    return _providers.keys.firstOrNull;
  }

  /// 获取指定提供者的统计信息。
  ProviderStatistics? getProviderStatistics(String providerName) =>
      _statistics[providerName];

  /// 获取全部统计信息。
  Map<String, ProviderStatistics> getAllStatistics() =>
      Map<String, ProviderStatistics>.from(_statistics);

  /// 释放所有提供者资源。
  void dispose() {
    if (!_disposed) {
      for (final provider in _providers.values) {
        try {
          provider.dispose();
        } catch (e, st) {
          _logger.severe('释放提供者资源失败: ${provider.providerName}', e, st);
        }
      }
      _providers.clear();
      _statistics.clear();
      _providerChangedController.close();
      _modelResponseController.close();
      _errorController.close();
      _disposed = true;
    }
  }

  ChatResponse _fail(String message, DateTime start, String providerName) {
    final response = ChatResponse(
      isSuccess: false,
      errorMessage: message,
      responseTime: DateTime.now().difference(start),
    );
    _errorController.add(ModelErrorEventArgs(providerName, message));
    return response;
  }

  void _updateStatistics(String providerName, ChatResponse response) {
    final stats = _statistics[providerName] ?? const ProviderStatistics();
    final total = stats.totalRequests + 1;
    final success = stats.successfulRequests + (response.isSuccess ? 1 : 0);
    final failed = stats.failedRequests + (response.isSuccess ? 0 : 1);
    final avgMs = stats.totalRequests == 0
        ? response.responseTime.inMilliseconds
        : ((stats.averageResponseTime.inMilliseconds * stats.totalRequests +
                response.responseTime.inMilliseconds) /
                total)
            .round();
    _statistics[providerName] = ProviderStatistics(
      totalRequests: total,
      successfulRequests: success,
      failedRequests: failed,
      averageResponseTime: Duration(milliseconds: avgMs),
      totalTokensUsed: stats.totalTokensUsed + (response.usage?.totalTokens ?? 0),
      lastRequestTime: DateTime.now(),
    );
  }
}
