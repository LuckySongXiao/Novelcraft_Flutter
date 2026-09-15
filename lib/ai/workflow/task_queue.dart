// 轻量并发任务队列（基于 [Semaphore]）。
//
// 对应 C# 源文件 `Workflow/TaskQueue.cs`。
//
// 与 C# 的主要差异：
// - C# 用「取出队列 → 依赖未满足就重新入队 + `Task.Delay(1000)` 轮询」的妥协式
//   实现；本实现改为**真实拓扑依赖等待**：每个任务完成时登记一个 [Completer]，
//   下游任务在开始前 [Future.wait] 其所有依赖的完成 future，依赖真正就绪才会运行，
//   不再空转轮询。
// - 并发上限由自实现的轻量 [Semaphore] 控制（不依赖 `dart:io`）。
// - `event EventHandler<WorkflowTask>` 改为广播 [Stream<WorkflowTask>]。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../agents/agent.dart';
import '../utils/semaphore.dart';
import 'workflow.dart';

/// 任务队列状态变更回调（用于通知引擎）。
typedef TaskStateChanged = void Function(WorkflowTask task);

/// 轻量并发任务队列。
class TaskQueue {
  final int _maxConcurrentTasks;
  final Semaphore _semaphore;
  final Logger _logger;

  /// 待处理任务。
  final List<WorkflowTask> _pending = <WorkflowTask>[];

  /// 运行中任务。
  final Map<String, WorkflowTask> _running = <String, WorkflowTask>{};

  /// 已完成任务。
  final Map<String, WorkflowTask> _completed = <String, WorkflowTask>{};

  /// 每个任务的完成 future（用于真实依赖等待）。
  final Map<String, Completer<void>> _completion = <String, Completer<void>>{};

  final StreamController<WorkflowTask> _taskStatusChangedController =
      StreamController<WorkflowTask>.broadcast();

  /// 构造任务队列。
  /// 并发上限（只读）。
  ///
  /// 供上层自查配置：若它小于 `BatchAgentExecutor.maxBatchSize`，
  /// 攒批永远攒不满（PITFALLS §33.7）。
  int get maxConcurrentTasks => _maxConcurrentTasks;

  TaskQueue(this._logger, {int maxConcurrentTasks = 5})
      : _maxConcurrentTasks = maxConcurrentTasks,
        _semaphore = Semaphore(maxConcurrentTasks);

  /// 任务状态变化事件流。
  Stream<WorkflowTask> get taskStatusChanged => _taskStatusChangedController.stream;

  /// 当前队列状态快照。
  TaskQueueStatus getQueueStatus() => TaskQueueStatus(
        pendingTasks: _pending.length,
        runningTasks: _running.length,
        completedTasks: _completed.length,
        maxConcurrentTasks: _maxConcurrentTasks,
        isProcessing: _running.isNotEmpty || _pending.isNotEmpty,
      );

  /// 加入单个任务。
  void enqueue(WorkflowTask task) {
    task.status = WorkflowStatus.pending;
    _pending.add(task);
    _logger.info('任务已加入队列: ${task.name} (ID: ${task.id})');
    _notify(task);
  }

  /// 批量加入任务（按优先级、创建时间排序）。
  void enqueueAll(Iterable<WorkflowTask> tasks) {
    final sorted = tasks.toList()
      ..sort((a, b) {
        final byPriority = b.priority.compareTo(a.priority);
        if (byPriority != 0) return byPriority;
        return a.createdAt.compareTo(b.createdAt);
      });
    for (final task in sorted) {
      enqueue(task);
    }
  }

  /// 取消任务（运行中或待处理均可）。
  bool cancel(String taskId) {
    if (_running.containsKey(taskId)) {
      final task = _running.remove(taskId)!;
      task.status = WorkflowStatus.cancelled;
      task.completedAt = DateTime.now();
      task.errorMessage = '任务被用户取消';
      _completed[taskId] = task;
      _complete(taskId);
      _notify(task);
      _logger.info('任务已取消: ${task.name} (ID: $taskId)');
      return true;
    }
    final idx = _pending.indexWhere((t) => t.id == taskId);
    if (idx >= 0) {
      final task = _pending.removeAt(idx);
      task.status = WorkflowStatus.cancelled;
      task.completedAt = DateTime.now();
      task.errorMessage = '任务被用户取消';
      _completed[taskId] = task;
      _complete(taskId);
      _notify(task);
      _logger.info('队列中的任务已取消: ${task.name} (ID: $taskId)');
      return true;
    }
    return false;
  }

  /// 清空队列（所有未完成任务标记为已取消）。
  void clear() {
    for (final task in List<WorkflowTask>.from(_pending)) {
      task.status = WorkflowStatus.cancelled;
      task.completedAt = DateTime.now();
      task.errorMessage = '队列被清空';
      _completed[task.id] = task;
      _complete(task.id);
      _notify(task);
    }
    _pending.clear();
    _logger.info('任务队列已清空');
  }

  /// 执行全部已入队任务。
  ///
  /// [runner] 为单个任务的实际执行逻辑（通常由工作流引擎委派给对应 Agent）。
  /// 返回时所有任务均已进入终态（完成 / 失败 / 取消）。
  Future<void> runAll(
    Future<AgentTaskResult> Function(WorkflowTask task) runner,
  ) async {
    // 预先为每个任务登记完成 future，使下游任务能真实等待上游依赖就绪，
    // 避免 C# 版「取出→不满足→重新入队→轮询」的空转实现。
    for (final task in List<WorkflowTask>.from(_pending)) {
      _completion.putIfAbsent(task.id, () => Completer<void>());
    }
    final futures = <Future<void>>[];
    while (_pending.isNotEmpty) {
      final task = _pending.removeAt(0);
      futures.add(_dispatch(task, runner));
    }
    await Future.wait(futures);
  }

  /// 取指定状态的任务列表。
  List<WorkflowTask> getByStatus(WorkflowStatus status) =>
      <WorkflowTask>[..._pending, ..._running.values, ..._completed.values]
          .where((t) => t.status == status)
          .toList();

  Future<void> _dispatch(
    WorkflowTask task,
    Future<AgentTaskResult> Function(WorkflowTask task) runner,
  ) async {
    // 真实依赖等待：在其所有依赖完成后才获取并发许可。
    final deps = task.dependencies
        .where((id) => _completion.containsKey(id))
        .map((id) => _completion[id]!.future);
    if (deps.isNotEmpty) {
      try {
        await Future.wait(deps);
      } on Object {
        // 依赖失败不影响本任务调度，交由 runner / 引擎处理。
      }
    }

    await _semaphore.acquire();
    try {
      task.status = WorkflowStatus.running;
      task.startedAt = DateTime.now();
      _running[task.id] = task;
      _logger.info('开始处理任务: ${task.name} (ID: ${task.id})');
      _notify(task);

      final result = await runner(task);
      task.result = result;
      task.progress = 100;
      if (result.isSuccess) {
        task.status = WorkflowStatus.completed;
      } else {
        task.status = WorkflowStatus.failed;
        task.errorMessage = result.errorMessage;
      }
    } catch (e) {
      task.status = WorkflowStatus.failed;
      task.errorMessage = e.toString();
      _logger.severe('任务处理失败: ${task.name} (ID: ${task.id})', e);
    } finally {
      _running.remove(task.id);
      task.completedAt = DateTime.now();
      _completed[task.id] = task;
      _complete(task.id);
      _semaphore.release();
      _notify(task);
    }
  }

  void _complete(String taskId) {
    final completer = _completion[taskId];
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _notify(WorkflowTask task) {
    if (!_taskStatusChangedController.isClosed) {
      _taskStatusChangedController.add(task);
    }
  }

  /// 注册依赖完成 future（在工作流引擎做 Kahn 排序后调用，便于跨任务等待）。
  void registerDependencyFutures(Map<String, Completer<void>> completions) {
    _completion.addAll(completions);
  }

  /// 释放事件控制器。
  void dispose() {
    _taskStatusChangedController.close();
  }
}
