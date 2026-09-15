// 思维链处理器。
//
// 对应 C# 源文件 `Services/ThinkingChain/ThinkingChainProcessor.cs`。
//
// 与 C# 的差异 / 约定：
// - `event EventHandler<T>` 改为由 `StreamController<T>.broadcast()` 暴露的
//   只读 [Stream]（[thinkingChainUpdated] / [stepUpdated]）。
// - 去掉 `CancellationToken`，超时由调用方 `Future.timeout` 控制。
// - 流式处理不再用 `Task.Delay(100)` 人为模拟延迟（避免挂起），而是顺序解析
//   步骤并即时推送 [StepUpdated] 事件。
// - 置信度基值 0.5，长度 >50 加 0.2、>100 加 0.1，因果连词（因为/所以/因此/
//   由于/基于/根据）每个加 0.1，最终 clamp 到 [0,1]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';

import 'thinking_chain.dart';

/// 思维链更新类型。
enum ThinkingChainUpdateType {
  created,
  started,
  progressUpdated,
  completed,
  failed,
  cancelled,
}

/// 步骤更新类型。
enum ThinkingStepUpdateType {
  added,
  started,
  completed,
  failed,
  skipped,
}

/// 思维链合并策略。
enum ThinkingChainMergeStrategy {
  sequential,
  parallel,
  hierarchical,
  intelligent,
}

/// 思维链导出格式。
enum ThinkingChainExportFormat {
  markdown,
  json,
  plainText,
}

/// 思维链更新事件参数。
class ThinkingChainUpdateEventArgs {
  final ThinkingChain thinkingChain;
  final ThinkingChainUpdateType updateType;
  ThinkingChainUpdateEventArgs(this.thinkingChain, this.updateType);
}

/// 步骤更新事件参数。
class ThinkingStepUpdateEventArgs {
  final ThinkingStep step;
  final ThinkingStepUpdateType updateType;
  ThinkingStepUpdateEventArgs(this.step, this.updateType);
}

/// 思维链过滤选项。
class ThinkingChainFilterOptions {
  final double minConfidence;
  final Set<ThinkingStepType>? includeStepTypes;
  final Set<ThinkingStepType>? excludeStepTypes;
  final bool removeDuplicates;
  final int? maxSteps;

  ThinkingChainFilterOptions({
    this.minConfidence = 0.0,
    this.includeStepTypes,
    this.excludeStepTypes,
    this.removeDuplicates = false,
    this.maxSteps,
  });
}

/// 思维链验证结果。
class ThinkingChainValidationResult {
  double logicConsistencyScore = 0;
  double completenessScore = 0;
  double coherenceScore = 0;
  bool isValid = false;
  final List<String> issues = <String>[];
  final List<String> suggestions = <String>[];

  double get overallScore =>
      (logicConsistencyScore + completenessScore + coherenceScore) / 3;
}

/// 思维链统计信息。
class ThinkingChainStatistics {
  int totalSteps = 0;
  double averageConfidence = 0;
  double complexityScore = 0;
  final Map<ThinkingStepType, int> stepTypeCount = <ThinkingStepType, int>{};
}

/// 思维链处理器。
///
/// 解析文本为结构化思维步骤、过滤/合并/导出思维链，并提供逻辑验证与统计。
/// 思维链处理器接口（对应 C# `IThinkingChainProcessor`）。
///
/// 仅声明对外公开的能力，具体实现见 [ThinkingChainProcessor]。Agent 层通过此接口
/// 引用处理器，便于后续替换为其它实现（如纯本地启发式处理器）。
abstract class IThinkingChainProcessor {
  /// 思维链更新事件流。
  Stream<ThinkingChainUpdateEventArgs> get thinkingChainUpdated;

  /// 步骤更新事件流。
  Stream<ThinkingStepUpdateEventArgs> get stepUpdated;

  /// 解析思维链文本（一次性解析全部步骤）。
  Future<ThinkingChain> parseThinkingChain(
    String thinkingText, {
    String? taskId,
    String? agentId,
  });

  /// 流式处理思维链（顺序推送每个步骤的添加 / 完成事件）。
  Future<ThinkingChain> processThinkingChainStream(
    ThinkingChain thinkingChain,
    String thinkingText, {
    void Function(ThinkingStep)? onStepUpdated,
  });

  /// 过滤思维链（按置信度 / 类型 / 去重 / 最大步数）。
  Future<ThinkingChain> filterThinkingChain(
    ThinkingChain thinkingChain, {
    ThinkingChainFilterOptions? filterOptions,
  });

  /// 提取关键思维步骤（按置信度与长度排序，取前 [maxSteps]）。
  Future<List<ThinkingStep>> extractKeySteps(
    ThinkingChain thinkingChain, {
    int maxSteps = 5,
  });

  /// 生成思维链 Markdown 摘要。
  Future<String> generateSummary(ThinkingChain thinkingChain);

  /// 验证思维链逻辑（一致性 / 完整性 / 连贯性）。
  Future<ThinkingChainValidationResult> validateLogic(
      ThinkingChain thinkingChain);

  /// 合并多个思维链。
  Future<ThinkingChain> mergeThinkingChains(
    List<ThinkingChain> thinkingChains, {
    ThinkingChainMergeStrategy strategy = ThinkingChainMergeStrategy.sequential,
  });

  /// 导出思维链为指定格式。
  Future<String> exportThinkingChain(
    ThinkingChain thinkingChain, {
    ThinkingChainExportFormat format = ThinkingChainExportFormat.markdown,
  });
}

class ThinkingChainProcessor implements IThinkingChainProcessor {
  final Logger _logger;
  final RegExp _sentencePattern = RegExp(r'[.!?。！？]+\s*');

  final StreamController<ThinkingChainUpdateEventArgs>
      _thinkingChainUpdatedController =
      StreamController<ThinkingChainUpdateEventArgs>.broadcast();
  final StreamController<ThinkingStepUpdateEventArgs> _stepUpdatedController =
      StreamController<ThinkingStepUpdateEventArgs>.broadcast();

  /// 构造思维链处理器。
  ThinkingChainProcessor({Logger? logger})
      : _logger = logger ?? Logger('ThinkingChainProcessor');

  /// 思维链更新事件流。
  @override
  Stream<ThinkingChainUpdateEventArgs> get thinkingChainUpdated =>
      _thinkingChainUpdatedController.stream;

  /// 步骤更新事件流。
  @override
  Stream<ThinkingStepUpdateEventArgs> get stepUpdated =>
      _stepUpdatedController.stream;

  /// 解析思维链文本（非流式，一次性解析全部步骤）。
  @override
  Future<ThinkingChain> parseThinkingChain(
    String thinkingText, {
    String? taskId,
    String? agentId,
  }) async {
    try {
      _logger.fine('开始解析思维链文本，长度: ${thinkingText.length}');
      final chain = ThinkingChain(
        title: 'AI思维过程',
        description: '解析AI的思维推理过程',
        taskId: taskId,
        agentId: agentId,
        originalInput: thinkingText,
      );
      final steps = await _parseThinkingSteps(thinkingText);
      for (final step in steps) {
        chain.addStep(step);
      }
      chain.complete();
      _emitChain(chain, ThinkingChainUpdateType.created);
      _logger.fine('思维链解析完成，共 ${steps.length} 个步骤');
      return chain;
    } catch (e, st) {
      _logger.severe('解析思维链文本失败', e, st);
      rethrow;
    }
  }

  /// 流式处理思维链（顺序推送每个步骤的添加 / 完成事件）。
  @override
  Future<ThinkingChain> processThinkingChainStream(
    ThinkingChain thinkingChain,
    String thinkingText, {
    void Function(ThinkingStep)? onStepUpdated,
  }) async {
    try {
      _logger.fine('开始流式处理思维链');
      thinkingChain.start();
      _emitChain(thinkingChain, ThinkingChainUpdateType.started);

      final steps = await _parseThinkingSteps(thinkingText);
      for (final step in steps) {
        step.start();
        _emitStep(step, ThinkingStepUpdateType.started);
        thinkingChain.addStep(step);
        _emitStep(step, ThinkingStepUpdateType.added);
        step.complete();
        _emitStep(step, ThinkingStepUpdateType.completed);
        thinkingChain.updateProgress();
        _emitChain(thinkingChain, ThinkingChainUpdateType.progressUpdated);
        onStepUpdated?.call(step);
      }

      thinkingChain.complete();
      _emitChain(thinkingChain, ThinkingChainUpdateType.completed);
      return thinkingChain;
    } catch (e, st) {
      _logger.severe('流式处理思维链失败', e, st);
      thinkingChain.fail();
      _emitChain(thinkingChain, ThinkingChainUpdateType.failed);
      rethrow;
    }
  }

  /// 过滤思维链（按置信度 / 类型 / 去重 / 最大步数）。
  @override
  Future<ThinkingChain> filterThinkingChain(
    ThinkingChain thinkingChain, {
    ThinkingChainFilterOptions? filterOptions,
  }) async {
    final options = filterOptions ?? ThinkingChainFilterOptions();
    final filtered = ThinkingChain(
      title: '${thinkingChain.title} (已过滤)',
      description: thinkingChain.description,
      taskId: thinkingChain.taskId,
      agentId: thinkingChain.agentId,
      originalInput: thinkingChain.originalInput,
    );
    var steps = thinkingChain.steps.where((step) {
      if (step.confidence < options.minConfidence) return false;
      if (options.includeStepTypes != null &&
          !options.includeStepTypes!.contains(step.type)) {
        return false;
      }
      if (options.excludeStepTypes != null &&
          options.excludeStepTypes!.contains(step.type)) {
        return false;
      }
      return true;
    }).toList();

    if (options.removeDuplicates) {
      steps = _removeDuplicateSteps(steps);
    }
    if (options.maxSteps != null && steps.length > options.maxSteps!) {
      steps = steps.take(options.maxSteps!).toList();
    }
    for (final step in steps) {
      filtered.addStep(step);
    }
    filtered.complete();
    return filtered;
  }

  /// 提取关键思维步骤（按置信度与长度排序，取前 [maxSteps]）。
  @override
  Future<List<ThinkingStep>> extractKeySteps(
    ThinkingChain thinkingChain, {
    int maxSteps = 5,
  }) async {
    final sorted = thinkingChain.steps.toList()
      ..sort((a, b) {
        final cmp = b.confidence.compareTo(a.confidence);
        if (cmp != 0) return cmp;
        return b.content.length.compareTo(a.content.length);
      });
    return sorted.take(maxSteps).toList()
      ..sort((a, b) => a.stepNumber.compareTo(b.stepNumber));
  }

  /// 生成思维链 Markdown 摘要。
  @override
  Future<String> generateSummary(ThinkingChain thinkingChain) async {
    final buffer = StringBuffer();
    buffer.writeln('# ${thinkingChain.title}');
    buffer.writeln('**描述**: ${thinkingChain.description}');
    buffer.writeln('**步骤数**: ${thinkingChain.totalSteps}');
    buffer.writeln('**处理时间**: ${thinkingChain.duration.inSeconds.toStringAsFixed(2)}秒');
    buffer.writeln();
    final keySteps = await extractKeySteps(thinkingChain, maxSteps: 3);
    buffer.writeln('## 关键步骤');
    for (final step in keySteps) {
      final preview = step.content.length > 100
          ? '${step.content.substring(0, 100)}...'
          : step.content;
      buffer.writeln('- **${step.typeDescription}**: $preview');
    }
    if (thinkingChain.finalOutput != null &&
        thinkingChain.finalOutput!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## 最终输出');
      final fo = thinkingChain.finalOutput!;
      buffer.writeln(fo.length > 200 ? '${fo.substring(0, 200)}...' : fo);
    }
    return buffer.toString();
  }

  /// 验证思维链逻辑（一致性 / 完整性 / 连贯性）。
  @override
  Future<ThinkingChainValidationResult> validateLogic(
      ThinkingChain thinkingChain) async {
    final result = ThinkingChainValidationResult();
    result.logicConsistencyScore = _calculateLogicConsistency(thinkingChain);
    result.completenessScore = _calculateCompleteness(thinkingChain);
    result.coherenceScore = _calculateCoherence(thinkingChain);
    result.isValid = result.overallScore >= 0.6;
    if (result.logicConsistencyScore < 0.5) {
      result.issues.add('逻辑一致性较低，存在矛盾的推理步骤');
      result.suggestions.add('检查并修正矛盾的推理逻辑');
    }
    if (result.completenessScore < 0.5) {
      result.issues.add('思维链不够完整，缺少关键步骤');
      result.suggestions.add('补充缺失的推理步骤');
    }
    if (result.coherenceScore < 0.5) {
      result.issues.add('思维链连贯性不足，步骤间缺乏逻辑联系');
      result.suggestions.add('改善步骤间的逻辑连接');
    }
    return result;
  }

  /// 合并多个思维链。
  @override
  Future<ThinkingChain> mergeThinkingChains(
    List<ThinkingChain> thinkingChains, {
    ThinkingChainMergeStrategy strategy = ThinkingChainMergeStrategy.sequential,
  }) async {
    if (thinkingChains.isEmpty) {
      throw ArgumentError('思维链列表不能为空');
    }
    if (thinkingChains.length == 1) return thinkingChains.first;
    final merged = ThinkingChain(
      title: '合并的思维链',
      description: '合并了 ${thinkingChains.length} 个思维链',
      agentId: 'MergedAgent',
    );
    switch (strategy) {
      case ThinkingChainMergeStrategy.sequential:
        for (final c in thinkingChains) {
          for (final s in c.steps) {
            merged.addStep(s);
          }
        }
      case ThinkingChainMergeStrategy.parallel:
        final maxSteps =
            thinkingChains.map((c) => c.steps.length).fold(0, max);
        for (var i = 0; i < maxSteps; i++) {
          for (final c in thinkingChains) {
            if (i < c.steps.length) merged.addStep(c.steps[i]);
          }
        }
      case ThinkingChainMergeStrategy.hierarchical:
        final sorted = thinkingChains.toList()
          ..sort((a, b) =>
              _avgConfidence(b).compareTo(_avgConfidence(a)));
        for (final c in sorted) {
          for (final s in c.steps) {
            merged.addStep(s);
          }
        }
      case ThinkingChainMergeStrategy.intelligent:
        final all = thinkingChains.expand((c) => c.steps).toList()
          ..sort((a, b) {
            final t = a.type.index.compareTo(b.type.index);
            if (t != 0) return t;
            return b.confidence.compareTo(a.confidence);
          });
        for (final s in all) {
          merged.addStep(s);
        }
    }
    merged.complete();
    return merged;
  }

  /// 导出思维链为指定格式。
  @override
  Future<String> exportThinkingChain(
    ThinkingChain thinkingChain, {
    ThinkingChainExportFormat format = ThinkingChainExportFormat.markdown,
  }) async {
    switch (format) {
      case ThinkingChainExportFormat.markdown:
        return _exportToMarkdown(thinkingChain);
      case ThinkingChainExportFormat.json:
        return _exportToJson(thinkingChain);
      case ThinkingChainExportFormat.plainText:
        return _exportToPlainText(thinkingChain);
    }
  }

  /// 获取思维链统计信息。
  ThinkingChainStatistics getStatistics(ThinkingChain thinkingChain) {
    final stats = ThinkingChainStatistics();
    stats.totalSteps = thinkingChain.steps.length;
    for (final step in thinkingChain.steps) {
      stats.stepTypeCount.update(step.type, (c) => c + 1, ifAbsent: () => 1);
    }
    if (thinkingChain.steps.isNotEmpty) {
      stats.averageConfidence = thinkingChain.steps
              .map((s) => s.confidence)
              .reduce((a, b) => a + b) /
          thinkingChain.steps.length;
    }
    stats.complexityScore = _calculateComplexityScore(thinkingChain);
    return stats;
  }

  /// 释放事件控制器。
  void dispose() {
    _thinkingChainUpdatedController.close();
    _stepUpdatedController.close();
  }

  // ----- 内部实现 -----

  Future<List<ThinkingStep>> _parseThinkingSteps(String thinkingText) async {
    final steps = <ThinkingStep>[];
    try {
      final sentences = thinkingText
          .split(_sentencePattern)
          .where((s) => s.trim().isNotEmpty)
          .toList();
      for (var i = 0; i < sentences.length; i++) {
        final sentence = sentences[i].trim();
        if (sentence.isEmpty) continue;
        steps.add(ThinkingStep(
          stepNumber: i + 1,
          title: '思维步骤 ${i + 1}',
          content: sentence,
          type: determineStepType(sentence),
          status: ThinkingStepStatus.completed,
          confidence: calculateConfidence(sentence),
        ));
      }
    } catch (e, st) {
      _logger.warning('解析思维步骤时出现错误', e, st);
    }
    return steps;
  }

  /// 确定步骤类型（与 C# `DetermineStepType` 一致）。
  ThinkingStepType determineStepType(String content) {
    final lower = content.toLowerCase();
    if (lower.contains('分析') || lower.contains('analyze')) {
      return ThinkingStepType.analysis;
    }
    if (lower.contains('计划') || lower.contains('plan')) {
      return ThinkingStepType.planning;
    }
    if (lower.contains('推理') || lower.contains('reason')) {
      return ThinkingStepType.reasoning;
    }
    if (lower.contains('评估') || lower.contains('evaluate')) {
      return ThinkingStepType.evaluation;
    }
    if (lower.contains('综合') || lower.contains('synthesis')) {
      return ThinkingStepType.synthesis;
    }
    if (lower.contains('验证') || lower.contains('verify')) {
      return ThinkingStepType.verification;
    }
    if (lower.contains('结论') || lower.contains('conclusion')) {
      return ThinkingStepType.conclusion;
    }
    return ThinkingStepType.reasoning;
  }

  /// 计算步骤置信度（与 C# `CalculateConfidence` 一致）。
  double calculateConfidence(String content) {
    var base = 0.5;
    if (content.length > 50) base += 0.2;
    if (content.length > 100) base += 0.1;
    const keywords = ['因为', '所以', '因此', '由于', '基于', '根据'];
    final count = keywords.where((kw) => content.contains(kw)).length;
    base += count * 0.1;
    return min(1.0, base);
  }

  double _avgConfidence(ThinkingChain c) => c.steps.isEmpty
      ? 0
      : c.steps.map((s) => s.confidence).reduce((a, b) => a + b) / c.steps.length;

  List<ThinkingStep> _removeDuplicateSteps(List<ThinkingStep> steps) {
    final seen = <String>{};
    final unique = <ThinkingStep>[];
    for (final step in steps) {
      final key = step.content.trim().toLowerCase();
      if (!seen.contains(key)) {
        seen.add(key);
        unique.add(step);
      }
    }
    return unique;
  }

  double _calculateLogicConsistency(ThinkingChain chain) {
    if (chain.steps.isEmpty) return 0;
    var score = 0.8;
    for (var i = 1; i < chain.steps.length; i++) {
      if (_hasLogicalConnection(
          chain.steps[i - 1].content, chain.steps[i].content)) {
        score += 0.05;
      } else {
        score -= 0.1;
      }
    }
    return max(0.0, min(1.0, score));
  }

  double _calculateCompleteness(ThinkingChain chain) {
    if (chain.steps.isEmpty) return 0;
    var score = 0.5;
    final types = chain.steps.map((s) => s.type).toSet();
    score += types.length * 0.1;
    if (chain.steps.any((s) => s.type == ThinkingStepType.conclusion)) {
      score += 0.2;
    }
    return min(1.0, score);
  }

  double _calculateCoherence(ThinkingChain chain) {
    if (chain.steps.length <= 1) return 1.0;
    var score = 0.7;
    var connected = 0;
    for (var i = 1; i < chain.steps.length; i++) {
      if (_hasLogicalConnection(
          chain.steps[i - 1].content, chain.steps[i].content)) {
        connected++;
      }
    }
    final ratio = connected / (chain.steps.length - 1);
    score = score * 0.5 + ratio * 0.5;
    return score;
  }

  bool _hasLogicalConnection(String content1, String content2) {
    const words = ['因此', '所以', '然后', '接下来', '基于', '根据', '由于'];
    return words.any((w) => content2.contains(w));
  }

  double _calculateComplexityScore(ThinkingChain chain) {
    if (chain.steps.isEmpty) return 0;
    var score = 0.0;
    score += min(0.3, chain.steps.length * 0.05);
    final uniqueTypes = chain.steps.map((s) => s.type).toSet().length;
    score += min(0.3, uniqueTypes * 0.05);
    final avgLen =
        chain.steps.map((s) => s.content.length).reduce((a, b) => a + b) /
            chain.steps.length;
    score += min(0.2, avgLen / 1000);
    if (chain.steps.any((s) => s.hasSubSteps)) score += 0.2;
    return min(1.0, score);
  }

  String _exportToMarkdown(ThinkingChain chain) {
    final b = StringBuffer();
    b.writeln('# ${chain.title}');
    b.writeln();
    b.writeln('**描述**: ${chain.description}');
    b.writeln('**状态**: ${chain.statusDescription}');
    b.writeln('**开始时间**: ${chain.startTime.toIso8601String()}');
    if (chain.endTime != null) {
      b.writeln('**结束时间**: ${chain.endTime!.toIso8601String()}');
      b.writeln('**持续时间**: ${chain.duration.inSeconds.toStringAsFixed(2)}秒');
    }
    b.writeln();
    b.writeln('## 思维步骤');
    for (final step in chain.steps) {
      b.writeln('### ${step.stepNumber}. ${step.title}');
      b.writeln('**类型**: ${step.typeDescription}');
      b.writeln('**置信度**: ${(step.confidence * 100).toStringAsFixed(0)}%');
      b.writeln('**状态**: ${step.statusDescription}');
      b.writeln();
      b.writeln(step.content);
      b.writeln();
    }
    if (chain.finalOutput != null && chain.finalOutput!.isNotEmpty) {
      b.writeln('## 最终输出');
      b.writeln(chain.finalOutput);
    }
    return b.toString();
  }

  String _exportToJson(ThinkingChain chain) {
    // 复用 ThinkingChain.toJson（基于 dart:convert 的手写序列化）。
    return jsonEncode(chain.toJson());
  }

  String _exportToPlainText(ThinkingChain chain) {
    final b = StringBuffer();
    b.writeln('思维链: ${chain.title}');
    b.writeln('描述: ${chain.description}');
    b.writeln('状态: ${chain.statusDescription}');
    b.writeln('开始时间: ${chain.startTime.toIso8601String()}');
    if (chain.endTime != null) {
      b.writeln('结束时间: ${chain.endTime!.toIso8601String()}');
      b.writeln('持续时间: ${chain.duration.inSeconds.toStringAsFixed(2)}秒');
    }
    b.writeln();
    b.writeln('思维步骤:');
    for (final step in chain.steps) {
      b.writeln('${step.stepNumber}. ${step.title} (${step.typeDescription})');
      b.writeln('   置信度: ${(step.confidence * 100).toStringAsFixed(0)}%');
      b.writeln('   内容: ${step.content}');
      b.writeln();
    }
    if (chain.finalOutput != null && chain.finalOutput!.isNotEmpty) {
      b.writeln('最终输出:');
      b.writeln(chain.finalOutput);
    }
    return b.toString();
  }

  void _emitChain(ThinkingChain chain, ThinkingChainUpdateType type) {
    if (!_thinkingChainUpdatedController.isClosed) {
      _thinkingChainUpdatedController
          .add(ThinkingChainUpdateEventArgs(chain, type));
    }
  }

  void _emitStep(ThinkingStep step, ThinkingStepUpdateType type) {
    if (!_stepUpdatedController.isClosed) {
      _stepUpdatedController.add(ThinkingStepUpdateEventArgs(step, type));
    }
  }
}
