// AI 模型提供者的抽象定义与配套数据类型。
//
// 对应 C# 源文件 `Interfaces/IModelProvider.cs`。与 C# 的差异：
// 1. 去掉了全部 `CancellationToken` 参数，超时统一由调用方用
//    `Future.timeout` 处理（C# 端各调用点均传默认值）。
// 2. C# 的 `event EventHandler<T>` 改为通过 [Stream] 暴露：
//    [IModelProvider.configurationChanged] 与
//    [IModelProvider.connectionStatusChanged] 返回
//    `StreamController<T>.broadcast().stream`，由实现类持有控制器。
// 3. [ChatRequest] / [ChatResponse] / [ChatChunk] / [TokenUsage] 定义于
//    同目录 `chat.dart`，此处不再重复。
library;

import 'dart:async';

import 'chat.dart';

/// 模型提供者类型。
///
/// 对应 C# `ModelProviderType` 枚举（CloudAPI / Local / MCP）。
enum ModelProviderType {
  /// 云端 API（如 DeepSeek、智谱、OpenAI 兼容服务）。
  cloudApi,

  /// 本地模型（如 Ollama、RWKV 本地推理服务）。
  local,

  /// MCP（模型上下文协议）服务。
  mcp,
}

/// 模型配置接口。
///
/// 对应 C# `IModelConfiguration`。各具体提供商通过实现本接口承载自身配置
/// （baseUrl / apiKey / 默认模型等）。
abstract class IModelConfiguration {
  /// 提供者名称（用于注册表中的唯一键）。
  String get providerName;

  /// 校验配置是否可用。
  bool isValid();

  /// 返回校验失败的错误信息列表（[isValid] 为 true 时应为空）。
  List<String> getValidationErrors();
}

/// 模型信息。
///
/// 对应 C# `ModelInfo`。`Parameters` 在 Dart 中表达为
/// `Map<String, dynamic>` 以承载各提供商的扩展参数。
class ModelInfo {
  /// 模型 ID（调用时传给 `model` 字段）。
  final String id;

  /// 模型展示名称。
  final String name;

  /// 模型描述。
  final String description;

  /// 模型大小（字节，已下载模型才有意义）。
  final int size;

  /// 是否已下载（本地模型）。
  final bool isDownloaded;

  /// 支持的能力标签（如 `chat` / `completion` / `vision`）。
  final List<String> capabilities;

  /// 附加参数（各提供商特有）。
  final Map<String, dynamic> parameters;

  /// 构造模型信息。
  ModelInfo({
    this.id = '',
    this.name = '',
    this.description = '',
    this.size = 0,
    this.isDownloaded = false,
    List<String>? capabilities,
    Map<String, dynamic>? parameters,
  })  : capabilities = capabilities ?? <String>[],
        parameters = parameters ?? <String, dynamic>{};

  /// 从 JSON 解析（字段缺失使用默认值，兼容宽松解析）。
  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        isDownloaded: json['isDownloaded'] as bool? ?? false,
        capabilities: (json['capabilities'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            <String>[],
        parameters:
            (json['parameters'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'size': size,
        'isDownloaded': isDownloaded,
        'capabilities': capabilities,
        'parameters': parameters,
      };
}

/// 连接测试结果。
///
/// 对应 C# `ConnectionTestResult`。`responseTime` 以 [Duration] 表达，
/// JSON 中以毫秒整数 `responseTimeMs` 存储。
class ConnectionTestResult {
  /// 是否连接成功。
  final bool isSuccess;

  /// 响应耗时。
  final Duration responseTime;

  /// 错误信息（失败时）。
  final String? errorMessage;

  /// 服务器附加信息（如版本、模型数等）。
  final Map<String, dynamic> serverInfo;

  /// 构造连接测试结果。
  ConnectionTestResult({
    this.isSuccess = false,
    this.responseTime = Duration.zero,
    this.errorMessage,
    Map<String, dynamic>? serverInfo,
  }) : serverInfo = serverInfo ?? <String, dynamic>{};

  /// 从 JSON 解析。
  factory ConnectionTestResult.fromJson(Map<String, dynamic> json) =>
      ConnectionTestResult(
        isSuccess: json['isSuccess'] as bool? ?? false,
        responseTime:
            Duration(milliseconds: json['responseTimeMs'] as int? ?? 0),
        errorMessage: json['errorMessage'] as String?,
        serverInfo: (json['serverInfo'] as Map<String, dynamic>?) ??
            <String, dynamic>{},
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'isSuccess': isSuccess,
        'responseTimeMs': responseTime.inMilliseconds,
        if (errorMessage != null) 'errorMessage': errorMessage,
        'serverInfo': serverInfo,
      };
}

/// 提供者统计信息。
///
/// 对应 C# `ProviderStatistics`。`averageResponseTime` 以 [Duration] 表达，
/// `lastRequestTime` 可空。
class ProviderStatistics {
  /// 总请求数。
  final int totalRequests;

  /// 成功请求数。
  final int successfulRequests;

  /// 失败请求数。
  final int failedRequests;

  /// 平均响应时间。
  final Duration averageResponseTime;

  /// 累计消耗的令牌数。
  final int totalTokensUsed;

  /// 最后一次请求时间（无请求时为 null）。
  final DateTime? lastRequestTime;

  /// 构造提供者统计信息。
  const ProviderStatistics({
    this.totalRequests = 0,
    this.successfulRequests = 0,
    this.failedRequests = 0,
    this.averageResponseTime = Duration.zero,
    this.totalTokensUsed = 0,
    this.lastRequestTime,
  });

  /// 从 JSON 解析。
  factory ProviderStatistics.fromJson(Map<String, dynamic> json) =>
      ProviderStatistics(
        totalRequests: json['totalRequests'] as int? ?? 0,
        successfulRequests: json['successfulRequests'] as int? ?? 0,
        failedRequests: json['failedRequests'] as int? ?? 0,
        averageResponseTime:
            Duration(milliseconds: json['averageResponseTimeMs'] as int? ?? 0),
        totalTokensUsed: json['totalTokensUsed'] as int? ?? 0,
        lastRequestTime: json['lastRequestTime'] == null
            ? null
            : DateTime.tryParse(json['lastRequestTime'] as String),
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'totalRequests': totalRequests,
        'successfulRequests': successfulRequests,
        'failedRequests': failedRequests,
        'averageResponseTimeMs': averageResponseTime.inMilliseconds,
        'totalTokensUsed': totalTokensUsed,
        if (lastRequestTime != null)
          'lastRequestTime': lastRequestTime!.toIso8601String(),
      };
}

/// 配置变更事件参数。
///
/// 对应 C# `ModelConfigurationChangedEventArgs`。作为
/// [IModelProvider.configurationChanged] 流的元素。
class ModelConfigurationChangedEventArgs {
  /// 新配置。
  final IModelConfiguration newConfiguration;

  /// 旧配置（首次设置时为 null）。
  final IModelConfiguration? oldConfiguration;

  /// 构造配置变更事件参数。
  ModelConfigurationChangedEventArgs(this.newConfiguration,
      [this.oldConfiguration]);
}

/// 连接状态变更事件参数。
///
/// 对应 C# `ConnectionStatusChangedEventArgs`。作为
/// [IModelProvider.connectionStatusChanged] 流的元素。
class ConnectionStatusChangedEventArgs {
  /// 是否已连接。
  final bool isConnected;

  /// 错误信息（断开时可能携带）。
  final String? errorMessage;

  /// 构造连接状态变更事件参数。
  const ConnectionStatusChangedEventArgs(this.isConnected,
      [this.errorMessage]);
}

/// AI 模型提供者抽象接口。
///
/// 对应 C# `IModelProvider`。Dart 版本的差异：
/// - 移除 `CancellationToken`，超时交由调用方 `Future.timeout` 处理。
/// - `event` 改为由实现类持有的 `StreamController` 暴露的只读 [Stream]。
/// - 方法名改为 Dart camelCase 风格，语义与 C# 一一对应。
abstract class IModelProvider {
  /// 提供者名称（注册表唯一键）。
  String get providerName;

  /// 提供者类型（云端 / 本地 / MCP）。
  ModelProviderType get providerType;

  /// 提供者当前是否可用（已初始化且可连通）。
  bool get isAvailable;

  /// 配置变更事件流。
  Stream<ModelConfigurationChangedEventArgs> get configurationChanged;

  /// 连接状态变更事件流。
  Stream<ConnectionStatusChangedEventArgs> get connectionStatusChanged;

  /// 使用给定配置初始化提供者。
  ///
  /// 对应 C# `InitializeAsync`。返回是否初始化成功。
  Future<bool> initialize(IModelConfiguration configuration);

  /// 测试与提供者的连接。
  ///
  /// 对应 C# `TestConnectionAsync`。
  Future<ConnectionTestResult> testConnection();

  /// 获取当前可用模型列表。
  ///
  /// 对应 C# `GetAvailableModelsAsync`。
  Future<List<ModelInfo>> getAvailableModels();

  /// 发送一次非流式聊天请求。
  ///
  /// 对应 C# `ChatAsync`。
  Future<ChatResponse> chat(ChatRequest request);

  /// 发送流式聊天请求，分块回调 [onChunkReceived]。
  ///
  /// 对应 C# `ChatStreamAsync`。实现内必须使用
  /// `http.Request` + `client.send` 真流式读取，禁止 `post()` 缓冲。
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk) onChunkReceived,
  );

  /// 获取提供者统计信息。
  ///
  /// 对应 C# `GetStatisticsAsync`。
  Future<ProviderStatistics> getStatistics();

  /// 释放资源（关闭客户端、控制器、本地进程等）。
  ///
  /// 对应 C# `Dispose`。
  void dispose();
}
