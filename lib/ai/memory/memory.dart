/// 记忆系统的基础数据模型。
///
/// 对应 C# 源文件 `Interfaces/IMemoryManager.cs` 中的 `MemoryItem` /
/// `MemoryContext` / `MemoryType` / `MemoryScope` / `MemoryCompressionResult` /
/// `MemoryStatistics`。记忆内容以字符串 `projectId` / `volumeId` / `chapterId`
/// 标识范围（Dart 端不引入 uuid 依赖，沿用字符串标识）。
library;

/// 记忆类型枚举。
///
/// 对应 C# `MemoryType`：增加了中文权重（见 `CompressionEngine`）。
enum MemoryType {
  /// 世界设定。
  worldSetting,

  /// 角色信息。
  character,

  /// 剧情信息。
  plot,

  /// 对话内容。
  dialogue,

  /// 场景描述。
  scene,

  /// 事件记录。
  event,

  /// 关系信息。
  relationship,

  /// 系统信息。
  system,

  /// 其他。
  other,
}

/// 记忆范围枚举。
///
/// 对应 C# `MemoryScope`。
enum MemoryScope {
  /// 全局记忆层。
  global,

  /// 卷宗记忆层。
  volume,

  /// 章节记忆层。
  chapter,

  /// 段落记忆层。
  paragraph,
}

/// 单条记忆项。
///
/// 对应 C# `MemoryItem`。关联实体 ID 列表用 `List<String>` 表达。
class MemoryItem {
  /// 记忆项 ID。
  String id;

  /// 内容。
  String content;

  /// 重要性评分（1-10）。
  int importanceScore;

  /// 记忆类型。
  MemoryType type;

  /// 记忆范围。
  MemoryScope scope;

  /// 项目 ID。
  String projectId;

  /// 卷宗 ID（可为空）。
  String? volumeId;

  /// 章节 ID（可为空）。
  String? chapterId;

  /// 创建时间。
  DateTime createdAt;

  /// 最后访问时间。
  DateTime lastAccessedAt;

  /// 访问次数。
  int accessCount;

  /// 是否已压缩。
  bool isCompressed;

  /// 原始内容长度（压缩前）。
  int originalLength;

  /// 标签列表。
  List<String> tags;

  /// 关联的实体 ID 列表。
  List<String> relatedEntityIds;

  /// 构造一条记忆项。
  MemoryItem({
    String? id,
    this.content = '',
    this.importanceScore = 5,
    this.type = MemoryType.other,
    this.scope = MemoryScope.global,
    this.projectId = '',
    this.volumeId,
    this.chapterId,
    DateTime? createdAt,
    DateTime? lastAccessedAt,
    this.accessCount = 0,
    this.isCompressed = false,
    this.originalLength = 0,
    List<String>? tags,
    List<String>? relatedEntityIds,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt = createdAt ?? DateTime.now(),
        lastAccessedAt = lastAccessedAt ?? DateTime.now(),
        tags = tags ?? <String>[],
        relatedEntityIds = relatedEntityIds ?? <String>[];

  /// 从 JSON 解析。
  factory MemoryItem.fromJson(Map<String, dynamic> json) => MemoryItem(
        id: json['id'] as String?,
        content: json['content'] as String? ?? '',
        importanceScore: json['importanceScore'] as int? ?? 5,
        type: _memoryTypeFromString(json['type'] as String?),
        scope: _memoryScopeFromString(json['scope'] as String?),
        projectId: json['projectId'] as String? ?? '',
        volumeId: json['volumeId'] as String?,
        chapterId: json['chapterId'] as String?,
        createdAt: json['createdAt'] == null
            ? DateTime.now()
            : DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now(),
        lastAccessedAt: json['lastAccessedAt'] == null
            ? DateTime.now()
            : DateTime.tryParse(json['lastAccessedAt'] as String) ?? DateTime.now(),
        accessCount: json['accessCount'] as int? ?? 0,
        isCompressed: json['isCompressed'] as bool? ?? false,
        originalLength: json['originalLength'] as int? ?? 0,
        tags: (json['tags'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            <String>[],
        relatedEntityIds: (json['relatedEntityIds'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            <String>[],
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'importanceScore': importanceScore,
        'type': type.name,
        'scope': scope.name,
        'projectId': projectId,
        if (volumeId != null) 'volumeId': volumeId,
        if (chapterId != null) 'chapterId': chapterId,
        'createdAt': createdAt.toIso8601String(),
        'lastAccessedAt': lastAccessedAt.toIso8601String(),
        'accessCount': accessCount,
        'isCompressed': isCompressed,
        'originalLength': originalLength,
        'tags': tags,
        'relatedEntityIds': relatedEntityIds,
      };
}

/// 记忆上下文。
///
/// 对应 C# `MemoryContext`。
class MemoryContext {
  /// 上下文 ID。
  final String id;

  /// 任务类型。
  final String taskType;

  /// 记忆范围。
  final MemoryScope scope;

  /// 项目 ID。
  final String projectId;

  /// 卷宗 ID（可为空）。
  final String? volumeId;

  /// 章节 ID（可为空）。
  final String? chapterId;

  /// 相关记忆项列表。
  final List<MemoryItem> relevantMemories;

  /// 上下文摘要。
  final String summary;

  /// 创建时间。
  final DateTime createdAt;

  /// 总重要性评分。
  final double totalImportanceScore;

  /// 构造记忆上下文。
  MemoryContext({
    String? id,
    this.taskType = '',
    this.scope = MemoryScope.global,
    this.projectId = '',
    this.volumeId,
    this.chapterId,
    List<MemoryItem>? relevantMemories,
    this.summary = '',
    DateTime? createdAt,
    this.totalImportanceScore = 0,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        relevantMemories = relevantMemories ?? <MemoryItem>[],
        createdAt = createdAt ?? DateTime.now();
}

/// 记忆压缩结果。
///
/// 对应 C# `MemoryCompressionResult`。
class MemoryCompressionResult {
  /// 是否成功。
  final bool isSuccess;

  /// 压缩前记忆项数量。
  final int originalCount;

  /// 压缩后记忆项数量。
  final int compressedCount;

  /// 压缩比例（0-1）。
  final double compressionRatio;

  /// 释放的内存大小（字节）。
  final int freedMemoryBytes;

  /// 压缩耗时。
  final Duration duration;

  /// 错误信息。
  final String? errorMessage;

  /// 构造记忆压缩结果。
  const MemoryCompressionResult({
    this.isSuccess = true,
    this.originalCount = 0,
    this.compressedCount = 0,
    this.compressionRatio = 0,
    this.freedMemoryBytes = 0,
    this.duration = Duration.zero,
    this.errorMessage,
  });
}

/// 记忆统计信息。
///
/// 对应 C# `MemoryStatistics`。
class MemoryStatistics {
  /// 项目 ID。
  final String projectId;

  /// 总记忆项数量。
  final int totalMemoryItems;

  /// 各范围的记忆项数量。
  final Map<MemoryScope, int> memoryCountByScope;

  /// 各类型的记忆项数量。
  final Map<MemoryType, int> memoryCountByType;

  /// 总内存使用量（字节）。
  final int totalMemoryUsage;

  /// 压缩率。
  final double compressionRatio;

  /// 平均重要性评分。
  final double averageImportanceScore;

  /// 最后更新时间。
  final DateTime lastUpdated;

  /// 构造记忆统计信息。
  MemoryStatistics({
    this.projectId = '',
    this.totalMemoryItems = 0,
    Map<MemoryScope, int>? memoryCountByScope,
    Map<MemoryType, int>? memoryCountByType,
    this.totalMemoryUsage = 0,
    this.compressionRatio = 0,
    this.averageImportanceScore = 0,
    DateTime? lastUpdated,
  })  : memoryCountByScope = memoryCountByScope ?? <MemoryScope, int>{},
        memoryCountByType = memoryCountByType ?? <MemoryType, int>{},
        lastUpdated = lastUpdated ?? DateTime.now();
}

/// 由字符串解析 [MemoryType]，未知值回退到 [MemoryType.other]。
MemoryType _memoryTypeFromString(String? value) {
  if (value == null) return MemoryType.other;
  return MemoryType.values.firstWhere(
    (e) => e.name == value,
    orElse: () => MemoryType.other,
  );
}

/// 由字符串解析 [MemoryScope]，未知值回退到 [MemoryScope.global]。
MemoryScope _memoryScopeFromString(String? value) {
  if (value == null) return MemoryScope.global;
  return MemoryScope.values.firstWhere(
    (e) => e.name == value,
    orElse: () => MemoryScope.global,
  );
}

/// 记忆管理器接口。
///
/// 对应 C# 源文件 `Interfaces/IMemoryManager.cs`。与 C# 的差异：
/// - 标识类型为 [String]（Dart 端不引入 uuid，沿用字符串项目 / 卷宗 / 章节 ID）。
/// - 去掉 `CancellationToken`，超时交由调用方 `Future.timeout`。
/// - `GetContextAsync` 返回 [MemoryContext] 而非可空（实现应始终返回有效上下文）。
abstract class IMemoryManager {
  /// 获取指定范围、任务类型的记忆上下文。
  Future<MemoryContext> getContext(
    String taskType,
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  });

  /// 更新一条记忆。
  Future<bool> updateMemory(
    String content,
    int importanceScore,
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  });

  /// 压缩指定范围的低重要性记忆。
  Future<MemoryCompressionResult> compressMemory(
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  });

  /// 在指定范围内搜索记忆。
  Future<List<MemoryItem>> searchMemory(
    String query,
    MemoryScope scope,
    String projectId, {
    int maxResults = 10,
  });

  /// 清理过期记忆，返回清理掉的条数。
  Future<int> cleanupExpiredMemory(
    MemoryScope scope,
    String projectId, {
    int retentionDays = 30,
  });

  /// 获取项目记忆统计信息。
  Future<MemoryStatistics> getMemoryStatistics(String projectId);
}
