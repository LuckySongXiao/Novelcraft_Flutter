/// 思维链（Thinking Chain）领域模型。
///
/// 对应 C# 源文件 `Services/ThinkingChain/Models/ThinkingStep.cs` 与
/// `ThinkingChain.cs`。C# 使用 `INotifyPropertyChanged` + `event` 通知 UI，
/// Dart 端改为纯数据模型 + 可选 `StreamController`（见 `ThinkingChainProcessor`），
/// 不在此处耦合通知逻辑。
library;

/// 思维步骤类型。
///
/// 对应 C# `ThinkingStepType`。
enum ThinkingStepType {
  /// 分析。
  analysis,

  /// 规划。
  planning,

  /// 推理。
  reasoning,

  /// 评估。
  evaluation,

  /// 综合。
  synthesis,

  /// 验证。
  verification,

  /// 结论。
  conclusion,
}

/// 思维步骤状态。
///
/// 对应 C# `ThinkingStepStatus`。
enum ThinkingStepStatus {
  /// 等待中。
  pending,

  /// 处理中。
  processing,

  /// 已完成。
  completed,

  /// 失败。
  failed,

  /// 已跳过。
  skipped,
}

/// 思维链状态。
///
/// 对应 C# `ThinkingChainStatus`。
enum ThinkingChainStatus {
  /// 等待中。
  pending,

  /// 处理中。
  processing,

  /// 已完成。
  completed,

  /// 失败。
  failed,

  /// 已取消。
  cancelled,
}

/// 单条思维步骤。
///
/// 对应 C# `ThinkingStep`。保留步骤类型/状态/置信度/时间戳及子步骤结构。
class ThinkingStep {
  /// 步骤 ID。
  final String id;

  /// 步骤序号（从 1 开始）。
  int stepNumber;

  /// 步骤标题。
  String title;

  /// 步骤内容。
  String content;

  /// 步骤类型。
  ThinkingStepType type;

  /// 步骤状态。
  ThinkingStepStatus status;

  /// 置信度（0-1）。
  final double confidence;

  /// 开始时间。
  final DateTime startTime;

  /// 结束时间（可为空）。
  DateTime? endTime;

  /// 相关标签。
  final List<String> tags;

  /// 子步骤。
  final List<ThinkingStep> subSteps;

  /// 父步骤 ID（可为空）。
  String? parentStepId;

  /// 构造一条思维步骤；[status] 默认 [ThinkingStepStatus.pending]。
  ThinkingStep({
    String? id,
    this.stepNumber = 0,
    this.title = '',
    this.content = '',
    this.type = ThinkingStepType.reasoning,
    this.status = ThinkingStepStatus.pending,
    this.confidence = 0.5,
    DateTime? startTime,
    this.endTime,
    List<String>? tags,
    List<ThinkingStep>? subSteps,
    this.parentStepId,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        startTime = startTime ?? DateTime.now(),
        tags = tags ?? <String>[],
        subSteps = subSteps ?? <ThinkingStep>[];

  /// 步骤类型的中文描述。
  String get typeDescription {
    switch (type) {
      case ThinkingStepType.analysis:
        return '分析';
      case ThinkingStepType.planning:
        return '规划';
      case ThinkingStepType.reasoning:
        return '推理';
      case ThinkingStepType.evaluation:
        return '评估';
      case ThinkingStepType.synthesis:
        return '综合';
      case ThinkingStepType.verification:
        return '验证';
      case ThinkingStepType.conclusion:
        return '结论';
    }
  }

  /// 步骤状态的中文描述。
  String get statusDescription {
    switch (status) {
      case ThinkingStepStatus.pending:
        return '等待中';
      case ThinkingStepStatus.processing:
        return '处理中';
      case ThinkingStepStatus.completed:
        return '已完成';
      case ThinkingStepStatus.failed:
        return '失败';
      case ThinkingStepStatus.skipped:
        return '已跳过';
    }
  }

  /// 是否正在处理。
  bool get isProcessing => status == ThinkingStepStatus.processing;

  /// 是否已完成。
  bool get isCompleted => status == ThinkingStepStatus.completed;

  /// 是否有子步骤。
  bool get hasSubSteps => subSteps.isNotEmpty;

  /// 标记步骤开始。
  void start() {
    startTime;
    status = ThinkingStepStatus.processing;
  }

  /// 标记步骤完成。
  void complete() {
    endTime = DateTime.now();
    status = ThinkingStepStatus.completed;
  }

  /// 标记步骤失败。
  void fail() {
    endTime = DateTime.now();
    status = ThinkingStepStatus.failed;
  }

  /// 添加子步骤。
  void addSubStep(ThinkingStep subStep) {
    subStep.parentStepId = id;
    subStep.stepNumber = subSteps.length + 1;
    subSteps.add(subStep);
  }

  /// 从 JSON 解析（宽松解析，字段缺失用默认值）。
  factory ThinkingStep.fromJson(Map<String, dynamic> json) => ThinkingStep(
        id: json['id'] as String?,
        stepNumber: json['stepNumber'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        type: _stepTypeFromString(json['type'] as String?),
        status: _stepStatusFromString(json['status'] as String?),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.5,
        startTime: json['startTime'] == null
            ? DateTime.now()
            : DateTime.tryParse(json['startTime'] as String) ?? DateTime.now(),
        endTime: json['endTime'] == null
            ? null
            : DateTime.tryParse(json['endTime'] as String),
        tags: (json['tags'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            <String>[],
        subSteps: (json['subSteps'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(ThinkingStep.fromJson)
                .toList() ??
            <ThinkingStep>[],
        parentStepId: json['parentStepId'] as String?,
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'id': id,
        'stepNumber': stepNumber,
        'title': title,
        'content': content,
        'type': type.name,
        'status': status.name,
        'confidence': confidence,
        'startTime': startTime.toIso8601String(),
        if (endTime != null) 'endTime': endTime!.toIso8601String(),
        'tags': tags,
        'subSteps': subSteps.map((s) => s.toJson()).toList(),
        if (parentStepId != null) 'parentStepId': parentStepId,
      };
}

/// 思维链。
///
/// 对应 C# `ThinkingChain`。提供步骤增删、进度统计与生命周期方法。
class ThinkingChain {
  /// 思维链 ID。
  final String id;

  /// 标题。
  String title;

  /// 描述。
  String description;

  /// 状态。
  ThinkingChainStatus status;

  /// 进度（0-1）。
  double progress;

  /// 开始时间。
  DateTime startTime;

  /// 结束时间（可为空）。
  DateTime? endTime;

  /// 思维步骤列表。
  final List<ThinkingStep> steps;

  /// 相关任务 ID。
  final String? taskId;

  /// 相关 Agent ID。
  final String? agentId;

  /// 原始输入文本。
  final String? originalInput;

  /// 最终输出文本。
  String? finalOutput;

  /// 元数据。
  final Map<String, dynamic> metadata;

  /// 构造思维链。
  ThinkingChain({
    String? id,
    this.title = '',
    this.description = '',
    this.status = ThinkingChainStatus.pending,
    this.progress = 0,
    DateTime? startTime,
    this.endTime,
    List<ThinkingStep>? steps,
    this.taskId,
    this.agentId,
    this.originalInput,
    this.finalOutput,
    Map<String, dynamic>? metadata,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        startTime = startTime ?? DateTime.now(),
        steps = steps ?? <ThinkingStep>[],
        metadata = metadata ?? <String, dynamic>{};

  /// 状态中文描述。
  String get statusDescription {
    switch (status) {
      case ThinkingChainStatus.pending:
        return '等待中';
      case ThinkingChainStatus.processing:
        return '处理中';
      case ThinkingChainStatus.completed:
        return '已完成';
      case ThinkingChainStatus.failed:
        return '失败';
      case ThinkingChainStatus.cancelled:
        return '已取消';
    }
  }

  /// 是否正在处理。
  bool get isProcessing => status == ThinkingChainStatus.processing;

  /// 是否已完成。
  bool get isCompleted => status == ThinkingChainStatus.completed;

  /// 是否失败。
  bool get isFailed => status == ThinkingChainStatus.failed;

  /// 总步骤数。
  int get totalSteps => steps.length;

  /// 已完成步骤数。
  int get completedSteps =>
      steps.where((s) => s.status == ThinkingStepStatus.completed).length;

  /// 当前正在处理的步骤（若有）。
  ThinkingStep? get currentStep =>
      steps.where((s) => s.status == ThinkingStepStatus.processing).firstOrNull;

  /// 持续时间。
  Duration get duration {
    if (endTime != null) return endTime!.difference(startTime);
    return DateTime.now().difference(startTime);
  }

  /// 添加步骤（自动编号）并更新进度。
  void addStep(ThinkingStep step) {
    step.stepNumber = steps.length + 1;
    steps.add(step);
    updateProgress();
  }

  /// 开始处理。
  void start() {
    startTime = DateTime.now();
    status = ThinkingChainStatus.processing;
  }

  /// 完成处理。
  void complete() {
    endTime = DateTime.now();
    status = ThinkingChainStatus.completed;
    progress = 1;
  }

  /// 标记失败。
  void fail() {
    endTime = DateTime.now();
    status = ThinkingChainStatus.failed;
  }

  /// 取消处理。
  void cancel() {
    endTime = DateTime.now();
    status = ThinkingChainStatus.cancelled;
  }

  /// 按已完成步骤比例更新进度。
  void updateProgress() {
    if (totalSteps > 0) {
      progress = completedSteps / totalSteps;
    }
  }

  /// 从 JSON 解析。
  factory ThinkingChain.fromJson(Map<String, dynamic> json) => ThinkingChain(
        id: json['id'] as String?,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        status: _chainStatusFromString(json['status'] as String?),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        startTime: json['startTime'] == null
            ? DateTime.now()
            : DateTime.tryParse(json['startTime'] as String) ?? DateTime.now(),
        endTime: json['endTime'] == null
            ? null
            : DateTime.tryParse(json['endTime'] as String),
        steps: (json['steps'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(ThinkingStep.fromJson)
                .toList() ??
            <ThinkingStep>[],
        taskId: json['taskId'] as String?,
        agentId: json['agentId'] as String?,
        originalInput: json['originalInput'] as String?,
        finalOutput: json['finalOutput'] as String?,
        metadata: (json['metadata'] as Map<String, dynamic>?) ??
            <String, dynamic>{},
      );

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'status': status.name,
        'progress': progress,
        'startTime': startTime.toIso8601String(),
        if (endTime != null) 'endTime': endTime!.toIso8601String(),
        'steps': steps.map((s) => s.toJson()).toList(),
        if (taskId != null) 'taskId': taskId,
        if (agentId != null) 'agentId': agentId,
        if (originalInput != null) 'originalInput': originalInput,
        if (finalOutput != null) 'finalOutput': finalOutput,
        'metadata': metadata,
      };
}

/// 由字符串解析 [ThinkingStepType]。
ThinkingStepType _stepTypeFromString(String? value) {
  if (value == null) return ThinkingStepType.reasoning;
  return ThinkingStepType.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ThinkingStepType.reasoning,
  );
}

/// 由字符串解析 [ThinkingStepStatus]。
ThinkingStepStatus _stepStatusFromString(String? value) {
  if (value == null) return ThinkingStepStatus.pending;
  return ThinkingStepStatus.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ThinkingStepStatus.pending,
  );
}

/// 由字符串解析 [ThinkingChainStatus]。
ThinkingChainStatus _chainStatusFromString(String? value) {
  if (value == null) return ThinkingChainStatus.pending;
  return ThinkingChainStatus.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ThinkingChainStatus.pending,
  );
}
