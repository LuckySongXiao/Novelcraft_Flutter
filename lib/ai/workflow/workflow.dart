// 工作流数据模型与引擎抽象接口。
//
// 对应 C# 源文件 `Workflow/IWorkflowEngine.cs`（`WorkflowStatus`、`WorkflowTask`、
// `WorkflowDefinition`、`WorkflowExecutionResult` 以及 `IWorkflowEngine` 接口）。
//
// 与 C# 的主要差异：
// - `event EventHandler<T>` 改为由 [StreamController<T>.broadcast()] 暴露的只读
//   [Stream]（[workflowStatusChanged] / [taskStatusChanged]）。
// - 去掉 `CancellationToken`，超时由调用方用 [Future.timeout] 控制。
// - `ID` 用基于时间戳的字符串生成（Dart 端不引 uuid）。
// - `Dictionary<string, object>` 统一用 [Map<String, dynamic>]。
// - 工作流引擎的 4 个预定义工作流与 Agent 注册由具体实现类提供。
library;

import 'dart:async';

import '../agents/agent.dart';
import 'workflow_branch.dart';

/// 库级自增序号：拼进默认 id，保证同一时钟粒度内创建的实体 id 不冲突
/// （Windows 计时器粒度可达 15ms，纯时间戳会撞车）。
int _idSeq = 0;

/// 工作流状态枚举（对应 C# `WorkflowStatus`）。
enum WorkflowStatus {
  /// 待执行。
  pending,

  /// 执行中。
  running,

  /// 已完成。
  completed,

  /// 已暂停。
  paused,

  /// 已取消。
  cancelled,

  /// 执行失败。
  failed,
}

/// 工作流单个任务（对应 C# `WorkflowTask`）。
class WorkflowTask {
  /// 任务唯一标识（Dart 端用时间戳字符串）。
  ///
  /// 时间戳后拼自增序号：Windows 计时器粒度可达 15ms，同批次连续创建的
  /// 任务会拿到相同微秒值，导致 cancel 误中他人、_completed 按 id 去重
  /// 丢条目（task_queue_test 曾因此双红）。
  final String id;

  /// 任务名称。
  String name;

  /// 任务类型（与 Agent 的 taskType 对应）。
  String taskType;

  /// 目标 Agent 的 id。
  String targetAgentId;

  /// 任务参数。
  Map<String, dynamic> parameters;

  /// 任务状态。
  WorkflowStatus status;

  /// 任务进度（0-100）。
  int progress;

  /// 任务执行结果。
  AgentTaskResult? result;

  /// 创建时间。
  final DateTime createdAt;

  /// 开始时间。
  DateTime? startedAt;

  /// 完成时间。
  DateTime? completedAt;

  /// 错误信息。
  String? errorMessage;

  /// 依赖的任务 id 列表。
  final List<String> dependencies;

  /// 优先级（1-10，10 最高）。
  int priority;

  /// 世界观分支（P3-23）：同一 session 下并行推演的多条剧情线（BE/A线/B线…）。
  ///
  /// - RWKV 引擎：每条分支靠 `session_id` + `dialogue_idx` 各自持有 state，
  ///   新增分支只需一次 prefill（O(1) 分叉），不必重跑整段历史。
  /// - 非 RWKV Provider：**降级为串行重编码**，且该字段保持空列表
  ///   （调用方据此判断「本次没有真正的分叉能力」）。
  ///
  /// 详见 `workflow_branch.dart` 与 PITFALLS §33.3。
  List<WorkflowBranch>? branches;

  /// 构造一个工作流任务。
  WorkflowTask({
    String? id,
    this.name = '',
    this.taskType = '',
    this.targetAgentId = '',
    Map<String, dynamic>? parameters,
    this.status = WorkflowStatus.pending,
    this.progress = 0,
    this.result,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
    List<String>? dependencies,
    this.priority = 5,
    this.branches,
  })  : id = id ?? '${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}',
        parameters = parameters ?? <String, dynamic>{},
        dependencies = dependencies ?? <String>[],
        createdAt = DateTime.now();
}

/// 工作流定义（对应 C# `WorkflowDefinition`）。
class WorkflowDefinition {
  /// 工作流唯一标识。
  final String id;

  /// 工作流名称。
  String name;

  /// 工作流描述。
  String description;

  /// 工作流版本。
  String version;

  /// 任务列表。
  List<WorkflowTask> tasks;

  /// 工作流状态。
  WorkflowStatus status;

  /// 创建时间。
  final DateTime createdAt;

  /// 开始时间。
  DateTime? startedAt;

  /// 完成时间。
  DateTime? completedAt;

  /// 总进度（0-100）。
  int progress;

  /// 工作流配置。
  final Map<String, dynamic> configuration;

  /// 构造工作流定义。
  WorkflowDefinition({
    String? id,
    this.name = '',
    this.description = '',
    this.version = '1.0.0',
    List<WorkflowTask>? tasks,
    this.status = WorkflowStatus.pending,
    this.startedAt,
    this.completedAt,
    this.progress = 0,
    Map<String, dynamic>? configuration,
  })  : id = id ?? '${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}',
        tasks = tasks ?? <WorkflowTask>[],
        configuration = configuration ?? <String, dynamic>{},
        createdAt = DateTime.now();
}

/// 工作流执行结果（对应 C# `WorkflowExecutionResult`）。
class WorkflowExecutionResult {
  /// 是否成功。
  final bool isSuccess;

  /// 工作流 ID。
  final String workflowId;

  /// 执行耗时。
  final Duration executionTime;

  /// 完成的任务数量。
  final int completedTasks;

  /// 失败的任务数量。
  final int failedTasks;

  /// 任务结果列表。
  final List<AgentTaskResult> taskResults;

  /// 错误信息。
  final String? errorMessage;

  /// 附加信息。
  final Map<String, dynamic> metadata;

  /// 构造工作流执行结果。
  WorkflowExecutionResult({
    this.isSuccess = false,
    this.workflowId = '',
    this.executionTime = Duration.zero,
    this.completedTasks = 0,
    this.failedTasks = 0,
    List<AgentTaskResult>? taskResults,
    this.errorMessage,
    Map<String, dynamic>? metadata,
  })  : taskResults = taskResults ?? <AgentTaskResult>[],
        metadata = metadata ?? <String, dynamic>{};
}

/// 工作流验证结果（对应 C# 内部类 `WorkflowValidationResult`）。
class WorkflowValidationResult {
  /// 是否有效。
  final bool isValid;

  /// 错误信息。
  final String? errorMessage;

  /// 构造验证结果。
  const WorkflowValidationResult({this.isValid = true, this.errorMessage});
}

/// 任务队列状态（对应 C# `TaskQueueStatus`）。
class TaskQueueStatus {
  /// 待处理任务数。
  final int pendingTasks;

  /// 运行中任务数。
  final int runningTasks;

  /// 已完成任务数。
  final int completedTasks;

  /// 最大并发任务数。
  final int maxConcurrentTasks;

  /// 是否正在处理。
  final bool isProcessing;

  /// 构造队列状态。
  const TaskQueueStatus({
    this.pendingTasks = 0,
    this.runningTasks = 0,
    this.completedTasks = 0,
    this.maxConcurrentTasks = 5,
    this.isProcessing = false,
  });
}

/// 工作流引擎抽象接口（对应 C# `IWorkflowEngine`）。
///
/// 与 C# 差异：事件改为只读 [Stream]，方法返回 [Future]，去掉
/// `CancellationToken`。
abstract class IWorkflowEngine {
  /// 工作流状态变化事件流。
  Stream<WorkflowDefinition> get workflowStatusChanged;

  /// 任务状态变化事件流。
  Stream<WorkflowTask> get taskStatusChanged;

  /// 执行工作流。
  Future<WorkflowExecutionResult> executeWorkflow(WorkflowDefinition workflowDefinition);

  /// 暂停工作流。
  Future<bool> pauseWorkflow(String workflowId);

  /// 恢复工作流。
  Future<bool> resumeWorkflow(String workflowId);

  /// 取消工作流。
  Future<bool> cancelWorkflow(String workflowId);

  /// 获取工作流状态。
  Future<WorkflowDefinition?> getWorkflowStatus(String workflowId);

  /// 获取活动工作流列表。
  Future<List<WorkflowDefinition>> getActiveWorkflows();

  /// 注册 Agent。
  Future<bool> registerAgent(IAgent agent);

  /// 注销 Agent。
  Future<bool> unregisterAgent(String agentId);

  /// 获取已注册的 Agent 列表。
  Future<List<IAgent>> getRegisteredAgents();

  /// 创建预定义工作流。
  Future<WorkflowDefinition> createPredefinedWorkflow(
    String workflowType,
    Map<String, dynamic> parameters,
  );
}
