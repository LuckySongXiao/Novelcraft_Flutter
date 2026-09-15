// 记忆管理器实现（进程内存储）。
//
// 对应 C# 源文件 `Memory/MemoryManager.cs`。采用内存列表保存 [MemoryItem]，
// 按 [MemoryScope] + 项目 / 卷宗 / 章节 ID 过滤检索；压缩委托给 `CompressionEngine`。
//
// 与 C# 的差异：
// - 标识类型为 [String]（Dart 端不引 uuid），记忆项 ID 仍由 [MemoryItem] 自动生成。
// - 去掉 `CancellationToken`；异常统一捕获后回退到空结果，保证链路上游不崩溃。
library;

import 'package:logging/logging.dart';

import 'compression_engine.dart';
import 'memory.dart';

/// 记忆管理器。
class MemoryManager implements IMemoryManager {
  final Logger _logger;
  final CompressionEngine _compressionEngine;
  final List<MemoryItem> _items = <MemoryItem>[];

  /// 构造记忆管理器。
  MemoryManager({Logger? logger, CompressionEngine? compressionEngine})
      : _logger = logger ?? Logger('MemoryManager'),
        _compressionEngine = compressionEngine ?? CompressionEngine(logger: logger ?? Logger('CompressionEngine'));

  /// 判断记忆项是否落在指定范围。
  bool _scopeMatches(
    MemoryItem item,
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  }) {
    if (item.projectId != projectId) return false;
    if (item.scope != scope) return false;
    if (scope == MemoryScope.volume || scope == MemoryScope.chapter) {
      if (item.volumeId != volumeId) return false;
    }
    if (scope == MemoryScope.chapter) {
      if (item.chapterId != chapterId) return false;
    }
    return true;
  }

  @override
  Future<MemoryContext> getContext(
    String taskType,
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  }) async {
    try {
      final relevant = _items
          .where((i) => _scopeMatches(i, scope, projectId,
              volumeId: volumeId, chapterId: chapterId))
          .toList();
      final totalImportance =
          relevant.fold(0.0, (sum, i) => sum + i.importanceScore);
      final summary = relevant.isEmpty
          ? ''
          : await _compressionEngine.generateSummary(
              relevant.map((i) => i.content).join('\n'),
              maxLength: 200);
      return MemoryContext(
        taskType: taskType,
        scope: scope,
        projectId: projectId,
        volumeId: volumeId,
        chapterId: chapterId,
        relevantMemories: relevant,
        summary: summary,
        totalImportanceScore: totalImportance,
      );
    } catch (e, st) {
      _logger.severe('获取记忆上下文失败', e, st);
      return MemoryContext(
        taskType: taskType,
        scope: scope,
        projectId: projectId,
        volumeId: volumeId,
        chapterId: chapterId,
      );
    }
  }

  @override
  Future<bool> updateMemory(
    String content,
    int importanceScore,
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  }) async {
    try {
      _items.add(MemoryItem(
        content: content,
        importanceScore: importanceScore.clamp(1, 10),
        type: await _compressionEngine.analyzeContentType(content),
        scope: scope,
        projectId: projectId,
        volumeId: volumeId,
        chapterId: chapterId,
        originalLength: content.length,
      ));
      return true;
    } catch (e, st) {
      _logger.severe('更新记忆失败', e, st);
      return false;
    }
  }

  @override
  Future<MemoryCompressionResult> compressMemory(
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  }) async {
    final startTime = DateTime.now();
    try {
      final items = _items
          .where((i) => _scopeMatches(i, scope, projectId,
              volumeId: volumeId, chapterId: chapterId))
          .toList();
      final originalCount = items.length;
      final compressed = await _compressionEngine.compressLowImportance(
        items,
        compressionThreshold: 5,
      );
      // 用压缩后的结果替换原列表中的对应项。
      final compressedIds = compressed.map((c) => c.id).toSet();
      _items.removeWhere((i) => compressedIds.contains(i.id));
      _items.addAll(compressed);
      final freed = compressed.fold(
          0, (sum, c) => sum + (c.originalLength - c.content.length).clamp(0, 1 << 30));
      return MemoryCompressionResult(
        isSuccess: true,
        originalCount: originalCount,
        compressedCount: compressed.length,
        compressionRatio: originalCount > 0 ? compressed.length / originalCount : 0,
        freedMemoryBytes: freed,
        duration: DateTime.now().difference(startTime),
      );
    } catch (e, st) {
      _logger.severe('压缩记忆失败', e, st);
      return MemoryCompressionResult(
        isSuccess: false,
        errorMessage: e.toString(),
        duration: DateTime.now().difference(startTime),
      );
    }
  }

  @override
  Future<List<MemoryItem>> searchMemory(
    String query,
    MemoryScope scope,
    String projectId, {
    int maxResults = 10,
  }) async {
    try {
      final candidates = _items
          .where((i) => _scopeMatches(i, scope, projectId))
          .toList();
      final scored = <(MemoryItem, double)>[];
      for (final item in candidates) {
        final relevance =
            await _compressionEngine.relevanceScore(query, item);
        scored.add((item, relevance * item.importanceScore));
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      return scored.take(maxResults).map((e) => e.$1).toList();
    } catch (e, st) {
      _logger.severe('搜索记忆失败', e, st);
      return const [];
    }
  }

  @override
  Future<int> cleanupExpiredMemory(
    MemoryScope scope,
    String projectId, {
    int retentionDays = 30,
  }) async {
    try {
      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      final expired = _items
          .where((i) =>
              _scopeMatches(i, scope, projectId) &&
              i.lastAccessedAt.isBefore(cutoff))
          .toList();
      for (final item in expired) {
        _items.remove(item);
      }
      return expired.length;
    } catch (e, st) {
      _logger.severe('清理过期记忆失败', e, st);
      return 0;
    }
  }

  @override
  Future<MemoryStatistics> getMemoryStatistics(String projectId) async {
    final projectItems =
        _items.where((i) => i.projectId == projectId).toList();
    final byScope = <MemoryScope, int>{};
    final byType = <MemoryType, int>{};
    var totalUsage = 0;
    var importanceSum = 0.0;
    for (final item in projectItems) {
      byScope.update(item.scope, (c) => c + 1, ifAbsent: () => 1);
      byType.update(item.type, (c) => c + 1, ifAbsent: () => 1);
      totalUsage += item.content.length;
      importanceSum += item.importanceScore;
    }
    return MemoryStatistics(
      projectId: projectId,
      totalMemoryItems: projectItems.length,
      memoryCountByScope: byScope,
      memoryCountByType: byType,
      totalMemoryUsage: totalUsage,
      averageImportanceScore:
          projectItems.isEmpty ? 0 : importanceSum / projectItems.length,
      lastUpdated: DateTime.now(),
    );
  }
}
