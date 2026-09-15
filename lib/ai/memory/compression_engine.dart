// 记忆压缩引擎。
//
// 对应 C# 源文件 `Memory/CompressionEngine.cs` 与接口
// `Interfaces/ICompressionEngine.cs`。采用本地启发式实现（不发起任何 AI 请求）：
// 重要性评分、Jaccard 相似度、关键词提取、内容类型分析、摘要生成、相似合并。
//
// 与 C# 的差异：C# 的 `EvaluateEntityRelationsAsync` 依赖真实上下文记忆项数量，
// 这里以相同公式（相关记忆数 / 10 × 10，clamp 到 10）近似。
library;

import 'dart:math';

import 'package:logging/logging.dart';

import 'memory.dart';

/// 压缩策略。
enum CompressionStrategy {
  importanceBased,
  timeBased,
  accessFrequencyBased,
  similarityBased,
  hybrid,
}

/// 压缩配置（对应 C# `CompressionConfig`）。
class CompressionConfig {
  CompressionStrategy strategy;
  int importanceThreshold;
  int timeThresholdDays;
  int accessFrequencyThreshold;
  double similarityThreshold;
  double maxCompressionRatio;
  bool preserveHighImportance;
  int highImportanceThreshold;
  int summaryMaxLength;
  bool enableSemanticAnalysis;
  bool enableKeywordExtraction;

  /// 构造压缩配置。
  CompressionConfig({
    this.strategy = CompressionStrategy.hybrid,
    this.importanceThreshold = 5,
    this.timeThresholdDays = 30,
    this.accessFrequencyThreshold = 3,
    this.similarityThreshold = 0.8,
    this.maxCompressionRatio = 0.5,
    this.preserveHighImportance = true,
    this.highImportanceThreshold = 8,
    this.summaryMaxLength = 200,
    this.enableSemanticAnalysis = true,
    this.enableKeywordExtraction = true,
  });
}

/// 重要性评估因子（对应 C# `ImportanceFactors`）。
class ImportanceFactors {
  final double contentLengthWeight;
  final double keywordDensityWeight;
  final double entityRelationWeight;
  final double timeRecencyWeight;
  final double accessFrequencyWeight;
  final double userMarkingWeight;

  const ImportanceFactors({
    this.contentLengthWeight = 0.1,
    this.keywordDensityWeight = 0.2,
    this.entityRelationWeight = 0.3,
    this.timeRecencyWeight = 0.1,
    this.accessFrequencyWeight = 0.2,
    this.userMarkingWeight = 0.1,
  });
}

/// 记忆压缩引擎接口（对应 C# `ICompressionEngine`）。
abstract class ICompressionEngine {
  Future<int> evaluateImportance(String content, MemoryContext context);
  Future<List<MemoryItem>> compressLowImportance(
    List<MemoryItem> memoryItems, {
    int compressionThreshold = 5,
  });
  Future<List<MemoryItem>> optimizeRetrieval(
    String query,
    List<MemoryItem> memoryItems, {
    int maxResults = 10,
  });
  Future<String> generateSummary(String content, {int maxLength = 200});
  Future<List<MemoryItem>> mergeSimilarMemories(
    List<MemoryItem> memoryItems, {
    double similarityThreshold = 0.8,
  });
  Future<double> calculateSimilarity(String content1, String content2);
  Future<List<String>> extractKeywords(String content, {int maxKeywords = 10});
  Future<MemoryType> analyzeContentType(String content);
  Future<double> relevanceScore(String query, MemoryItem item);
}

/// 记忆压缩引擎实现（对应 C# `CompressionEngine`）。
class CompressionEngine implements ICompressionEngine {
  final Logger _logger;
  final CompressionConfig _config;
  final ImportanceFactors _factors;

  static const List<String> _stopWords = [
    '的', '了', '在', '是', '我', '有', '和', '就', '不', '人', '都', '一',
    '一个', '上', '也', '很', '到', '说', '要', '去', '你', '会', '着',
    '没有', '看', '好', '自己', '这',
  ];

  /// 构造压缩引擎。
  CompressionEngine({Logger? logger, CompressionConfig? config})
      : _logger = logger ?? Logger('CompressionEngine'),
        _config = config ?? CompressionConfig(),
        _factors = const ImportanceFactors();

  @override
  Future<int> evaluateImportance(String content, MemoryContext context) async {
    try {
      var score = 0.0;
      final lengthScore =
          min(content.length / 1000.0, 1.0) * 10 * _factors.contentLengthWeight;
      score += lengthScore;

      final keywords = await extractKeywords(content, maxKeywords: 20);
      final wordCount = content.split(' ').length / 100.0;
      final keywordDensity = keywords.length / max(wordCount, 1.0);
      score += min(keywordDensity, 10.0) * _factors.keywordDensityWeight;

      final entityScore = min(context.relevantMemories.length / 10.0 * 10, 10.0);
      score += entityScore * _factors.entityRelationWeight;

      const timeScore = 10.0; // 新内容默认高分
      score += timeScore * _factors.timeRecencyWeight;

      score += await _contentTypeImportance(content);

      final finalScore = score.clamp(1, 10).round();
      return finalScore;
    } catch (e, st) {
      _logger.severe('评估内容重要性失败', e, st);
      return 5;
    }
  }

  @override
  Future<List<MemoryItem>> compressLowImportance(
    List<MemoryItem> memoryItems, {
    int compressionThreshold = 5,
  }) async {
    try {
      final result = <MemoryItem>[];
      for (final item in memoryItems) {
        if (item.importanceScore < compressionThreshold && !item.isCompressed) {
          final compressedContent =
              await generateSummary(item.content,
                  maxLength: _config.summaryMaxLength);
          result.add(MemoryItem(
            id: item.id,
            content: compressedContent,
            importanceScore: item.importanceScore,
            type: item.type,
            scope: item.scope,
            projectId: item.projectId,
            volumeId: item.volumeId,
            chapterId: item.chapterId,
            createdAt: item.createdAt,
            lastAccessedAt: item.lastAccessedAt,
            accessCount: item.accessCount,
            isCompressed: true,
            originalLength:
                item.originalLength > 0 ? item.originalLength : item.content.length,
            tags: item.tags,
            relatedEntityIds: item.relatedEntityIds,
          ));
        } else {
          result.add(item);
        }
      }
      return result;
    } catch (e, st) {
      _logger.severe('压缩低重要性记忆项失败', e, st);
      return memoryItems;
    }
  }

  @override
  Future<List<MemoryItem>> optimizeRetrieval(
    String query,
    List<MemoryItem> memoryItems, {
    int maxResults = 10,
  }) async {
    try {
      final scored = <(MemoryItem, double)>[];
      for (final item in memoryItems) {
        final score = await relevanceScore(query, item);
        scored.add((item, score * item.importanceScore));
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      return scored.take(maxResults).map((e) => e.$1).toList();
    } catch (e, st) {
      _logger.severe('优化记忆检索失败', e, st);
      return memoryItems.take(maxResults).toList();
    }
  }

  @override
  Future<String> generateSummary(String content, {int maxLength = 200}) async {
    try {
      if (content.length <= maxLength) return content;
      final sentences = content
          .split(RegExp(r'[.!?。！？]'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      if (sentences.length <= 1) {
        return content.length > maxLength
            ? '${content.substring(0, maxLength)}...'
            : content;
      }
      final keywords = await extractKeywords(content, maxKeywords: 10);
      final keywordPattern = keywords.join('|');
      final important = sentences.toList()
        ..sort((a, b) =>
            _countMatches(b, keywordPattern).compareTo(_countMatches(a, keywordPattern)));
      final selected = <String>[];
      var current = 0;
      for (final sentence in important) {
        final len = sentence.length + 1;
        if (current + len <= maxLength) {
          selected.add(sentence.trim());
          current += len;
        } else {
          break;
        }
      }
      var summary = selected.join('。');
      if (summary.length < content.length) summary += '...';
      return summary;
    } catch (e, st) {
      _logger.severe('生成摘要失败', e, st);
      return content.length > maxLength
          ? '${content.substring(0, maxLength)}...'
          : content;
    }
  }

  @override
  Future<List<MemoryItem>> mergeSimilarMemories(
    List<MemoryItem> memoryItems, {
    double similarityThreshold = 0.8,
  }) async {
    try {
      final merged = <MemoryItem>[];
      final processed = <String>{};
      for (final item in memoryItems) {
        if (processed.contains(item.id)) continue;
        final similar = <MemoryItem>[item];
        processed.add(item.id);
        for (final other in memoryItems) {
          if (processed.contains(other.id)) continue;
          final sim = await calculateSimilarity(item.content, other.content);
          if (sim >= similarityThreshold) {
            similar.add(other);
            processed.add(other.id);
          }
        }
        merged.add(similar.length > 1 ? await _mergeItems(similar) : item);
      }
      return merged;
    } catch (e, st) {
      _logger.severe('合并相似记忆项失败', e, st);
      return memoryItems;
    }
  }

  @override
  Future<double> calculateSimilarity(String content1, String content2) async {
    try {
      if (content1.isEmpty || content2.isEmpty) return 0.0;
      final words1 = _extractWords(content1);
      final words2 = _extractWords(content2);
      final intersection = words1.intersection(words2).length;
      final union = words1.union(words2).length;
      return union > 0 ? intersection / union : 0.0;
    } catch (e, st) {
      _logger.severe('计算相似度失败', e, st);
      return 0.0;
    }
  }

  @override
  Future<List<String>> extractKeywords(String content, {int maxKeywords = 10}) async {
    try {
      if (content.isEmpty) return const [];
      final words = _extractWords(content);
      final freq = <String, int>{};
      for (final w in words) {
        if (_stopWords.contains(w.toLowerCase())) continue;
        freq[w.toLowerCase()] = (freq[w.toLowerCase()] ?? 0) + 1;
      }
      final sorted = freq.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return sorted.take(maxKeywords).map((e) => e.key).toList();
    } catch (e, st) {
      _logger.severe('提取关键词失败', e, st);
      return const [];
    }
  }

  @override
  Future<MemoryType> analyzeContentType(String content) async {
    final lower = content.toLowerCase();
    if (_containsAny(lower, ['角色', '人物', '性格', '外貌', '能力'])) {
      return MemoryType.character;
    }
    if (_containsAny(lower, ['剧情', '情节', '故事', '发展', '转折'])) {
      return MemoryType.plot;
    }
    if (_containsAny(lower, ['对话', '说道', '回答', '询问', '交谈'])) {
      return MemoryType.dialogue;
    }
    if (_containsAny(lower, ['场景', '环境', '地点', '描述', '景色'])) {
      return MemoryType.scene;
    }
    if (_containsAny(lower, ['世界', '设定', '规则', '体系', '背景'])) {
      return MemoryType.worldSetting;
    }
    if (_containsAny(lower, ['关系', '联系', '关联', '影响', '互动'])) {
      return MemoryType.relationship;
    }
    if (_containsAny(lower, ['事件', '发生', '经历', '过程', '结果'])) {
      return MemoryType.event;
    }
    return MemoryType.other;
  }

  @override
  Future<double> relevanceScore(String query, MemoryItem item) async {
    final similarity = await calculateSimilarity(query, item.content);
    final tagMatch =
        item.tags.any((t) => query.toLowerCase().contains(t.toLowerCase()))
            ? 0.5
            : 0.0;
    final typeMatch = query.toLowerCase().contains(item.type.name.toLowerCase())
        ? 0.3
        : 0.0;
    return similarity + tagMatch + typeMatch;
  }

  // ----- 内部实现 -----

  Future<double> _contentTypeImportance(String content) async {
    final type = await analyzeContentType(content);
    switch (type) {
      case MemoryType.worldSetting:
        return 3.0;
      case MemoryType.character:
        return 2.5;
      case MemoryType.plot:
        return 2.0;
      case MemoryType.relationship:
        return 1.5;
      case MemoryType.event:
        return 1.0;
      case MemoryType.scene:
        return 0.5;
      case MemoryType.dialogue:
        return 0.3;
      case MemoryType.system:
      case MemoryType.other:
        return 0.0;
    }
  }

  Future<MemoryItem> _mergeItems(List<MemoryItem> items) async {
    final primary =
        items.reduce((a, b) => a.importanceScore >= b.importanceScore ? a : b);
    final combined = items.map((i) => i.content).join('\n---\n');
    final mergedContent =
        await generateSummary(combined,
            maxLength: _config.summaryMaxLength * 2);
    return MemoryItem(
      id: primary.id,
      content: mergedContent,
      importanceScore:
          (items.map((i) => i.importanceScore).reduce((a, b) => a + b) /
                  items.length)
              .round(),
      type: primary.type,
      scope: primary.scope,
      projectId: primary.projectId,
      volumeId: primary.volumeId,
      chapterId: primary.chapterId,
      createdAt:
          items.map((i) => i.createdAt).reduce((a, b) => a.isBefore(b) ? a : b),
      lastAccessedAt: items.map((i) => i.lastAccessedAt).reduce((a, b) => a.isAfter(b) ? a : b),
      accessCount: items.fold(0, (sum, i) => sum + i.accessCount),
      isCompressed: true,
      originalLength: items.fold(0, (sum, i) => sum + i.originalLength),
      tags: items.expand((i) => i.tags).toSet().toList(),
      relatedEntityIds: items.expand((i) => i.relatedEntityIds).toSet().toList(),
    );
  }

  Set<String> _extractWords(String content) {
    final matches =
        RegExp(r'\b\w+\b').allMatches(content).map((m) => m.group(0)!).toList();
    return matches.where((w) => w.length > 1).toSet();
  }

  int _countMatches(String sentence, String keywordPattern) {
    if (keywordPattern.isEmpty) return 0;
    return RegExp(keywordPattern, caseSensitive: false)
        .allMatches(sentence)
        .length;
  }

  bool _containsAny(String content, List<String> keywords) =>
      keywords.any((k) => content.contains(k));
}
