/// 聊天相关的通用数据模型。
///
/// 对应 C# 源文件 `Interfaces/IModelProvider.cs` 中的
/// `ChatRequest` / `ChatMessage` / `ChatResponse` / `ChatChunk` / `TokenUsage`
/// 等类型。此处删除了 `CancellationToken` 参数（Dart 无对应约定，
/// 原 C# 调用点均传默认值），超时统一由调用方用 `Future.timeout` 处理。
library;

/// 聊天角色枚举。
///
/// 取值与 OpenAI / Ollama 的 `role` 字段完全一致（`name` 即协议字符串）。
enum ChatRole {
  /// 系统角色。
  system,

  /// 用户角色。
  user,

  /// 助手角色。
  assistant,
}

/// 单条聊天消息。
///
/// 对应 C# `ChatMessage`：原先使用 `string Role`，这里改为强类型
/// [ChatRole] 并保留时间戳字段。
class ChatMessage {
  /// 消息角色。
  final ChatRole role;

  /// 消息内容。
  final String content;

  /// 消息时间戳。
  final DateTime timestamp;

  /// 构造一条聊天消息。
  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 构造一条系统消息。
  factory ChatMessage.system(String content) =>
      ChatMessage(role: ChatRole.system, content: content);

  /// 构造一条用户消息。
  factory ChatMessage.user(String content) =>
      ChatMessage(role: ChatRole.user, content: content);

  /// 构造一条助手消息。
  factory ChatMessage.assistant(String content) =>
      ChatMessage(role: ChatRole.assistant, content: content);

  /// 从 JSON 解析（字段缺失时使用默认值，兼容宽松解析）。
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawRole = json['role'] as String? ?? 'user';
    final role = ChatRole.values.firstWhere(
      (e) => e.name == rawRole,
      orElse: () => ChatRole.user,
    );
    final rawTs = json['timestamp'] as String?;
    return ChatMessage(
      role: role,
      content: json['content'] as String? ?? '',
      timestamp: rawTs == null ? DateTime.now() : DateTime.tryParse(rawTs) ?? DateTime.now(),
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// 聊天请求。
///
/// 对应 C# `ChatRequest`。字段与 C# 保持一致，`Parameters` 用
/// `Map<String, dynamic>` 表达以承载各提供商特有的扩展参数。
class ChatRequest {
  /// 模型 ID（空字符串表示使用提供商的默认模型）。
  String model;

  /// 消息列表。
  List<ChatMessage> messages;

  /// 温度参数。
  double temperature;

  /// 最大生成令牌数。
  int maxTokens;

  /// 是否流式响应。
  bool stream;

  /// 系统提示（空表示无）。
  String? systemPrompt;

  /// 额外参数（各提供商特有）。
  Map<String, dynamic> parameters;

  /// 构造聊天请求。
  ChatRequest({
    this.model = '',
    List<ChatMessage>? messages,
    this.temperature = 0.7,
    this.maxTokens = 1000,
    this.stream = false,
    this.systemPrompt,
    Map<String, dynamic>? parameters,
  })  : messages = messages ?? <ChatMessage>[],
        parameters = parameters ?? <String, dynamic>{};

  /// 从 JSON 解析。
  factory ChatRequest.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'] as List<dynamic>? ?? <dynamic>[];
    return ChatRequest(
      model: json['model'] as String? ?? '',
      messages: rawMessages
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList(),
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: json['maxTokens'] as int? ?? 1000,
      stream: json['stream'] as bool? ?? false,
      systemPrompt: json['systemPrompt'] as String?,
      parameters:
          (json['parameters'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'model': model,
        'messages': messages.map((m) => m.toJson()).toList(),
        'temperature': temperature,
        'maxTokens': maxTokens,
        'stream': stream,
        if (systemPrompt != null) 'systemPrompt': systemPrompt,
        'parameters': parameters,
      };
}

/// 令牌使用统计。
///
/// 对应 C# `TokenUsage`（字段命名改为驼峰）。
class TokenUsage {
  /// 提示令牌数。
  final int promptTokens;

  /// 完成令牌数。
  final int completionTokens;

  /// 总令牌数。
  final int totalTokens;

  /// 构造令牌使用统计。
  const TokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
  });

  /// 从 JSON 解析。
  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
        promptTokens: json['promptTokens'] as int? ?? 0,
        completionTokens: json['completionTokens'] as int? ?? 0,
        totalTokens: json['totalTokens'] as int? ?? 0,
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'totalTokens': totalTokens,
      };
}

/// 聊天响应。
///
/// 对应 C# `ChatResponse`。`ResponseTime` 以 `Duration` 表达，JSON 中以
/// 毫秒整数存储。
class ChatResponse {
  /// 响应 ID。
  String id;

  /// 实际使用的模型。
  String model;

  /// 响应内容。
  String content;

  /// 完成原因。
  String finishReason;

  /// 令牌使用统计（可能为 null）。
  TokenUsage? usage;

  /// 响应耗时。
  Duration responseTime;

  /// 是否成功。
  bool isSuccess;

  /// 错误信息（失败时）。
  String? errorMessage;

  /// 构造聊天响应。
  ChatResponse({
    this.id = '',
    this.model = '',
    this.content = '',
    this.finishReason = '',
    this.usage,
    this.responseTime = Duration.zero,
    this.isSuccess = true,
    this.errorMessage,
  });

  /// 从 JSON 解析。
  factory ChatResponse.fromJson(Map<String, dynamic> json) => ChatResponse(
        id: json['id'] as String? ?? '',
        model: json['model'] as String? ?? '',
        content: json['content'] as String? ?? '',
        finishReason: json['finishReason'] as String? ?? '',
        usage: json['usage'] == null
            ? null
            : TokenUsage.fromJson(json['usage'] as Map<String, dynamic>),
        responseTime:
            Duration(milliseconds: json['responseTimeMs'] as int? ?? 0),
        isSuccess: json['isSuccess'] as bool? ?? true,
        errorMessage: json['errorMessage'] as String?,
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'id': id,
        'model': model,
        'content': content,
        'finishReason': finishReason,
        if (usage != null) 'usage': usage!.toJson(),
        'responseTimeMs': responseTime.inMilliseconds,
        'isSuccess': isSuccess,
        if (errorMessage != null) 'errorMessage': errorMessage,
      };
}

/// 流式聊天数据块。
///
/// 对应 C# `ChatChunk`。
class ChatChunk {
  /// 数据块 ID。
  final String id;

  /// 本块内容。
  final String content;

  /// 是否已完成。
  final bool isComplete;

  /// 完成原因（完成块时携带）。
  final String? finishReason;

  /// 构造一个流式数据块。
  const ChatChunk({
    this.id = '',
    this.content = '',
    this.isComplete = false,
    this.finishReason,
  });
}
