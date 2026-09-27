// 书籍工作流引擎（真正实现 Kahn 拓扑排序）。
//
// 对应 C# 源文件 `Workflow/NovelWorkflowEngine.cs`。
//
// 与 C# 的关键**有意改动**：
// - C# 的 `TaskQueue.AreDependenciesSatisfied` 并未做真正的拓扑排序，只是「取出队列 →
//   依赖未满足就重新入队 + `Task.Delay(1000)` 轮询」，存在潜在的活锁与顺序不确定问题。
//   本实现在 [NovelWorkflowEngine] 中显式实现 **Kahn 算法**：构建入度表、反复弹出
//   入度为 0 的节点，检测环并在发现循环依赖时直接报错；得到的拓扑序用于入队顺序，
//   再交由 [TaskQueue] 以完成 future 做真实依赖等待。
// - `event EventHandler<T>` 改为广播 [Stream]。
// - 任务的实际执行委派给已注册的 [IAgent.execute]，不再像 C# 那样 `SimulateTaskProcessingAsync`
//   模拟占位的随机延迟。
// - `ID` 用时间戳字符串；`Dictionary<string,object>` 用 [Map<String, dynamic>]。
library;

import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';

import '../agents/agent.dart';
import '../memory/memory.dart';
import '../providers/rwkv_provider.dart';
import '../rwkv/rwkv_session_archive.dart';
import 'agent_batch_settings.dart';
import 'batch_agent_executor.dart';
import 'dispatch_planner.dart';
import 'task_queue.dart';
import 'workflow.dart';

/// 书籍工作流引擎。
class NovelWorkflowEngine implements IWorkflowEngine {
  final Logger _logger;
  final TaskQueue _taskQueue;
  final RwkvProvider? _rwkvProvider;

  /// 批量 Agent 执行器（P3-22）。null = 不启用攒批，行为与改动前完全一致。
  final BatchAgentExecutor? _batchExecutor;

  /// 全局 Agent 攒批配置（P4-28）。用回调而非直接持有，避免配置变更时
  /// 重建整个引擎（引擎持有 Agent 注册表与 taskQueue）。
  final AgentBatchSettings Function()? _batchSettings;

  /// 会话存档（P4-27）。null = 不存档。
  ///
  /// ⚠ 存的是**对话转录本**，不是 state 字节 —— rwkv_lightning 没有
  /// state 导出端点，客户端的 `RwkvState.bytes` 一直是空占位（PITFALLS §39.1）。
  /// 恢复 = 把转录本重放一次进 `/state/chat/completions` 重建服务端 state。
  final RwkvSessionArchive? _sessionArchive;

  /// 功能：分派规划器 —— 跑之前探测最大并发 + 主 Agent 自主决定分派数。
  /// null = 未装配（按原并发执行）。
  final WorkflowDispatchPlanner? _dispatchPlanner;

  /// 是否让**所有**可批任务都走攒批。
  ///
  /// 默认 `false`（保守）：批量路由下 prompt 必须**自包含**，而
  /// `BaseAgent.buildPromptForBatch` 的默认实现只是把 parameters 拍平，
  /// 质量不如各 Agent 自己精心构造的单路 prompt。所以默认只对
  /// **显式写了 `useBatch: true`** 的任务生效，避免静默降低质量。
  final bool _batchAllTasks;

  final Map<String, IAgent> _registeredAgents = <String, IAgent>{};
  final Map<String, IAgent> _agentsByName = <String, IAgent>{};
  final Map<String, WorkflowDefinition> _activeWorkflows =
      <String, WorkflowDefinition>{};
  final Map<String, String> _workflowSessions = <String, String>{};

  final StreamController<WorkflowDefinition> _workflowStatusChangedController =
      StreamController<WorkflowDefinition>.broadcast();
  final StreamController<WorkflowTask> _taskStatusChangedController =
      StreamController<WorkflowTask>.broadcast();

  /// 构造工作流引擎。
  ///
  /// [rwkvProvider] 为可选依赖：
  ///   - 若注入：每个 workflow 执行前自动开一个 RWKV session，并把 sessionId
  ///     注入到每个 task.parameters，让 workflow 下跨 Agent 的多步任务共享
  ///     同一个 RWKV state（世界观/人设/大纲预编码一次，后续增量）。
  ///   - 若未注入：行为与之前一致（每个 Agent 自行开 session 或降级无 state）。
  /// [batchExecutor] 注入后启用攒批（P3-22）：并发派发的独立任务会被攒成
  /// **一次** `POST /v1/batch/completions`。实测 8 个任务 → 1 次 POST、1.64s。
  ///
  /// ⚠ 两个必须知道的取舍：
  ///   1. **批量路由是无状态的** —— 走批量时不带 `rwkvSessionId` 的 state 续跑，
  ///      所以 `buildPromptForBatch` 产出的 prompt **必须自包含**上下文。
  ///   2. 攒批只对**时间上重叠**的任务有效（窗口 100ms），依赖链上的任务
  ///      仍然是串行的 —— 这是拓扑顺序决定的，不是缺陷。
  NovelWorkflowEngine(
    this._logger,
    this._taskQueue, {
    IMemoryManager? memoryManager,
    RwkvProvider? rwkvProvider,
    BatchAgentExecutor? batchExecutor,
    bool batchAllTasks = false,
    AgentBatchSettings Function()? batchSettings,
    RwkvSessionArchive? sessionArchive,
    WorkflowDispatchPlanner? dispatchPlanner,
  }) : _rwkvProvider = rwkvProvider,
       _batchExecutor = batchExecutor,
       _batchAllTasks = batchAllTasks,
       _batchSettings = batchSettings,
       _sessionArchive = sessionArchive,
       _dispatchPlanner = dispatchPlanner {
    _taskQueue.taskStatusChanged.listen(_onTaskStatusChanged);
    final ex = batchExecutor;
    if (ex != null) {
      final int conc = _taskQueue.maxConcurrentTasks;
      if (conc < ex.maxBatchSize) {
        // 这类配置错很隐蔽：攒批会「永远攒不满」，看起来像批量没生效
        _logger.warning(
          '队列并发上限 ($conc) 小于批量上限 (${ex.maxBatchSize})，'
          '攒批永远攒不满 —— 请把 TaskQueue.maxConcurrentTasks 提到 '
          '${ex.maxBatchSize} 以上（PITFALLS §33.7）',
        );
      } else {
        _logger.info(
          'WorkflowEngine 已启用攒批：maxBatchSize=${ex.maxBatchSize}, '
          '队列并发=$conc, batchAllTasks=$batchAllTasks',
        );
      }
    }
  }

  @override
  Stream<WorkflowDefinition> get workflowStatusChanged =>
      _workflowStatusChangedController.stream;

  @override
  Stream<WorkflowTask> get taskStatusChanged =>
      _taskStatusChangedController.stream;

  @override
  Future<WorkflowExecutionResult> executeWorkflow(
    WorkflowDefinition workflowDefinition,
  ) async {
    final startTime = DateTime.now();
    String? rwkvSessionId;
    // 存档键用**稳定的业务键**（默认工作流名）——绝不能用引擎生成的 sessionId，
    // 那个每次开新会话都会变，存了也找不回来。放在 try 外层：存档点在 runAll 之后。
    final String archiveKey = _archiveKeyFor(workflowDefinition);
    try {
      _logger.info(
        '开始执行工作流: ${workflowDefinition.name} '
        '(ID: ${workflowDefinition.id})',
      );

      workflowDefinition.status = WorkflowStatus.running;
      workflowDefinition.startedAt = DateTime.now();
      _activeWorkflows[workflowDefinition.id] = workflowDefinition;

      // --- RWKV State 复用增强 ---
      // 如果配置了 RwkvProvider，把整个 workflow 包在同一个 session 里：
      // 跨 8 个 Agent 的世界观/人设/大纲 state 一次性预编码，后续只增量。
      final rp = _rwkvProvider;
      if (rp != null && rp.isAvailable) {
        rwkvSessionId = rp.openSession(
          label: 'Workflow-${workflowDefinition.name}_${workflowDefinition.id}',
        );
        _workflowSessions[workflowDefinition.id] = rwkvSessionId;
        workflowDefinition.configuration['rwkvSessionId'] = rwkvSessionId;
        for (final task in workflowDefinition.tasks) {
          task.parameters.putIfAbsent('rwkvSessionId', () => rwkvSessionId);
        }
        _logger.info(
          '工作流 ${workflowDefinition.name} 绑定 RWKV session: '
          '$rwkvSessionId',
        );

        // --- P4-27 会话存档恢复 ---
        // 模型不匹配 / 没有存档 / 为空 都会静默跳过（从零开始，绝不硬塞错误记忆）
        await _tryRestoreSession(archiveKey, rwkvSessionId, workflowDefinition);
      }
      _onWorkflowStatusChanged(workflowDefinition);

      final validation = _validate(workflowDefinition);
      if (!validation.isValid) {
        throw StateError('工作流验证失败: ${validation.errorMessage}');
      }

      // 真实 Kahn 拓扑排序：既用于入队顺序，也在存在环时报错。
      final order = _topologicalSort(workflowDefinition.tasks);

      // --- 功能：跑之前探测最大并发 + 主 Agent 自主决定分派数 ---
      final planner = _dispatchPlanner;
      if (planner != null) {
        try {
          final int parallelizable = order
              .where((WorkflowTask t) => t.dependencies.isEmpty)
              .length;
          final DispatchPlan plan = await planner.decide(
            workflowName: workflowDefinition.name,
            taskCount: workflowDefinition.tasks.length,
            parallelizable: parallelizable,
          );
          _taskQueue.setMaxConcurrentTasks(plan.effective);
          workflowDefinition.configuration['dispatchConcurrency'] =
              plan.effective;
          workflowDefinition.configuration['dispatchProbedMax'] =
              plan.probedMax;
          _logger.info(
            '主 Agent 分派决策：探测 ${plan.probedMax}'
            '（${plan.source}）· 主Agent表态 ${plan.mainAgentDecision}'
            ' → 生效并发 ${plan.effective}',
          );
        } on Object catch (e) {
          // 规划失败按原并发执行，绝不阻塞工作流
          _logger.warning('并发探测/分派决策失败（按原并发执行）: $e');
        }
      }

      _taskQueue.enqueueAll(order);
      await _taskQueue.runAll(_runTask);

      // --- P4-27 会话存档 ---
      if (rwkvSessionId != null) {
        await _archiveSession(archiveKey, rwkvSessionId, workflowDefinition);
      }

      final executionTime = DateTime.now().difference(startTime);
      final completed = workflowDefinition.tasks
          .where((t) => t.status == WorkflowStatus.completed)
          .length;
      final failed = workflowDefinition.tasks
          .where((t) => t.status == WorkflowStatus.failed)
          .length;

      workflowDefinition.status = failed > 0
          ? WorkflowStatus.failed
          : WorkflowStatus.completed;
      workflowDefinition.completedAt = DateTime.now();
      workflowDefinition.progress = 100;
      _cleanupSession(workflowDefinition.id);
      _onWorkflowStatusChanged(workflowDefinition);

      final metadata = <String, dynamic>{};
      if (rwkvSessionId != null) metadata['rwkvSessionId'] = rwkvSessionId;
      final result = WorkflowExecutionResult(
        isSuccess: failed == 0,
        workflowId: workflowDefinition.id,
        executionTime: executionTime,
        completedTasks: completed,
        failedTasks: failed,
        taskResults: workflowDefinition.tasks
            .where((t) => t.result != null)
            .map((t) => t.result!)
            .toList(),
        metadata: metadata,
      );

      _logger.info(
        '工作流执行完成: ${workflowDefinition.name}, '
        '成功: ${result.isSuccess}, '
        '耗时: ${executionTime.inMilliseconds / 1000}秒',
      );
      return result;
    } catch (e, st) {
      _logger.severe('工作流执行失败: ${workflowDefinition.name}', e, st);
      workflowDefinition.status = WorkflowStatus.failed;
      workflowDefinition.completedAt = DateTime.now();
      _cleanupSession(workflowDefinition.id);
      _onWorkflowStatusChanged(workflowDefinition);
      final errorMetadata = <String, dynamic>{};
      if (rwkvSessionId != null) errorMetadata['rwkvSessionId'] = rwkvSessionId;
      return WorkflowExecutionResult(
        isSuccess: false,
        workflowId: workflowDefinition.id,
        executionTime: DateTime.now().difference(startTime),
        errorMessage: e.toString(),
        metadata: errorMetadata,
      );
    }
  }

  @override
  Future<bool> pauseWorkflow(String workflowId) async {
    final workflow = _activeWorkflows[workflowId];
    if (workflow != null) {
      workflow.status = WorkflowStatus.paused;
      _onWorkflowStatusChanged(workflow);
      _logger.info('工作流已暂停: ${workflow.name} (ID: $workflowId)');
      return true;
    }
    return false;
  }

  @override
  Future<bool> resumeWorkflow(String workflowId) async {
    final workflow = _activeWorkflows[workflowId];
    if (workflow != null) {
      workflow.status = WorkflowStatus.running;
      _onWorkflowStatusChanged(workflow);
      _logger.info('工作流已恢复: ${workflow.name} (ID: $workflowId)');
      return true;
    }
    return false;
  }

  @override
  Future<bool> cancelWorkflow(String workflowId) async {
    final workflow = _activeWorkflows[workflowId];
    if (workflow != null) {
      workflow.status = WorkflowStatus.cancelled;
      workflow.completedAt = DateTime.now();
      for (final task in workflow.tasks.where(
        (t) =>
            t.status == WorkflowStatus.pending ||
            t.status == WorkflowStatus.running,
      )) {
        _taskQueue.cancel(task.id);
      }
      _cleanupSession(workflowId);
      _onWorkflowStatusChanged(workflow);
      _logger.info('工作流已取消: ${workflow.name} (ID: $workflowId)');
      return true;
    }
    return false;
  }

  @override
  Future<WorkflowDefinition?> getWorkflowStatus(String workflowId) async =>
      _activeWorkflows[workflowId];

  @override
  Future<List<WorkflowDefinition>> getActiveWorkflows() async =>
      _activeWorkflows.values.toList();

  @override
  Future<bool> registerAgent(IAgent agent) async {
    if (_registeredAgents.containsKey(agent.id)) return false;
    _registeredAgents[agent.id] = agent;
    _agentsByName[agent.name.toLowerCase()] = agent;
    _logger.info('Agent 已注册: ${agent.name} (ID: ${agent.id})');
    return true;
  }

  @override
  Future<bool> unregisterAgent(String agentId) async {
    final agent = _registeredAgents.remove(agentId);
    if (agent != null) {
      _agentsByName.remove(agent.name.toLowerCase());
      _logger.info('Agent 已注销: ${agent.name} (ID: $agentId)');
      return true;
    }
    return false;
  }

  @override
  Future<List<IAgent>> getRegisteredAgents() async =>
      _registeredAgents.values.toList();

  @override
  Future<WorkflowDefinition> createPredefinedWorkflow(
    String workflowType,
    Map<String, dynamic> parameters,
  ) async {
    switch (workflowType) {
      case 'ProjectInitialization':
        return _createProjectInitializationWorkflow(parameters);
      case 'ChapterCreation':
        return _createChapterCreationWorkflow(parameters);
      case 'ContentReview':
        return _createContentReviewWorkflow(parameters);
      case 'ConsistencyCheck':
        return _createConsistencyCheckWorkflow(parameters);
      default:
        throw ArgumentError('不支持的工作流类型: $workflowType');
    }
  }

  // ----- 执行与验证 -----

  /// 该任务是否走攒批（P3-22）。
  ///
  /// 判定顺序（任一不满足即走单路 `agent.execute`）：
  ///   1. 注入了 [_batchExecutor]
  ///   2. Agent 是 [BaseAgent]（`buildPromptForBatch` 定义在它上面）
  ///   3. 任务**显式声明** `useBatch: true`，或引擎级 [_batchAllTasks] 已开
  ///   4. 任务**没有**显式 `useBatch: false`（单条任务可强制退出攒批）
  bool _shouldBatch(WorkflowTask task, IAgent agent) {
    if (_batchExecutor == null) return false;
    if (agent is! BaseAgent) return false;
    final Object? flag = task.parameters['useBatch'];
    if (flag == false) return false;
    bool wanted;
    if (flag == true) {
      wanted = true;
    } else {
      // 任务上没显式声明 → 查全局配置（P4-28：用户在设置页逐个 Agent 开的）
      final AgentBatchSettings cfg =
          _batchSettings?.call() ?? AgentBatchSettings.empty;
      wanted = _batchAllTasks || cfg.isEnabledFor(agent.name);
    }
    if (!wanted) return false;
    // ⚠ 能力闸：`buildPromptForBatch` 默认返回 null（= 未实现自包含 prompt）。
    //   没有它就直接走单路 —— 绝不拿兜底文本去透支成文质量。
    //   （上面的 `agent is! BaseAgent` 守卫已保证类型已收窄，无需再 cast）
    return agent.buildPromptForBatch(task.taskType, task.parameters) != null;
  }

  /// 存档键：优先用工作流配置里的显式 `archiveKey`，否则用工作流名。
  String _archiveKeyFor(WorkflowDefinition w) {
    final Object? k = w.configuration['archiveKey'];
    if (k is String && k.trim().isNotEmpty) return k.trim();
    return w.name.trim().isEmpty ? 'workflow-${w.id}' : w.name.trim();
  }

  /// 尝试从存档恢复会话（模型不匹配 / 没有存档 / 为空 都直接跳过）。
  Future<void> _tryRestoreSession(
    String archiveKey,
    String sessionId,
    WorkflowDefinition w,
  ) async {
    final RwkvSessionArchive? archive = _sessionArchive;
    final rp = _rwkvProvider;
    if (archive == null || rp == null) return;
    try {
      final (
        RwkvSessionArchiveEntry? entry,
        RwkvArchiveMismatch? why,
      ) = await archive.loadCompatible(
        archiveKey: archiveKey,
        currentModelId: rp.modelId,
      );
      if (entry == null) {
        if (why == RwkvArchiveMismatch.modelMismatch) {
          _logger.warning(
            '跳过会话恢复：存档是用模型「${entry?.modelId}」产生的，'
            '与当前模型「${rp.modelId}」不一致 —— 重放会得到另一个模型的记忆，'
            '故从零开始',
          );
        }
        return;
      }
      final engine = rp.engine;
      final ok = await engine.replayTranscript(sessionId, entry.turns);
      if (ok) {
        w.configuration['sessionRestored'] = true;
        w.configuration['sessionRestoredTurns'] = entry.turns.length;
        _logger.info(
          '工作流 ${w.name} 已从存档恢复会话'
          '（${entry.turns.length} 轮 / ${entry.totalChars} 字）',
        );
      }
    } on Object catch (e) {
      _logger.warning('会话恢复失败（不影响本次执行，从零开始）：$e');
    }
  }

  /// 把当前会话历史存档（崩溃后可恢复，不用重编码整段历史）。
  Future<void> _archiveSession(
    String archiveKey,
    String sessionId,
    WorkflowDefinition w,
  ) async {
    final RwkvSessionArchive? archive = _sessionArchive;
    final rp = _rwkvProvider;
    if (archive == null || rp == null) return;
    try {
      final session = rp.engine.sessionManager.get(sessionId);
      if (session == null || session.history.isEmpty) return;
      final entry = RwkvSessionArchiveEntry(
        archiveKey: archiveKey,
        modelId: rp.modelId,
        archivedAtMs: DateTime.now().millisecondsSinceEpoch,
        turns: <RwkvArchivedTurn>[
          for (final m in session.history)
            RwkvArchivedTurn(role: m.role.name, content: m.content),
        ],
      );
      await archive.save(entry);
      _logger.info(
        '工作流 ${w.name} 已存档会话'
        '（${entry.turns.length} 轮 / ${entry.totalChars} 字，key=$archiveKey）',
      );
    } on Object catch (e) {
      _logger.warning('会话存档失败（不影响本次执行）：$e');
    }
  }

  Future<AgentTaskResult> _runTask(WorkflowTask task) async {
    final agent = _resolveAgent(task.targetAgentId);
    if (agent == null) {
      throw StateError(
        '任务 ${task.name} 的目标 Agent '
        '${task.targetAgentId} 未注册',
      );
    }
    final BatchAgentExecutor? ex = _batchExecutor;
    if (ex != null && _shouldBatch(task, agent)) {
      // 分组优先取任务上的显式值，其次取全局配置（P4-28）
      if (!task.parameters.containsKey('batchGroupId')) {
        final String? g = _batchSettings?.call().groupIdFor(agent.name);
        if (g != null) task.parameters['batchGroupId'] = g;
      }
      final String group = task.parameters['batchGroupId']?.toString() ?? '-';
      _logger.info(
        '执行任务 ${task.name} 委派给 Agent ${agent.name}'
        '（走攒批，group=$group）',
      );
      try {
        return await ex.submit(agent as BaseAgent, task);
      } on Object catch (e) {
        // 攒批失败**不静默降级为串行** —— 否则用户会以为批量生效了却在付串行的代价。
        // 明确把它标成失败，带上可诊断的信息。
        _logger.severe('任务 ${task.name} 攒批执行失败（不自动降级为单路）：$e');
        return AgentTaskResult(
          isSuccess: false,
          errorMessage:
              '攒批执行失败：$e\n'
              '（如需退回单路，请在该任务参数里设 useBatch: false）',
          metadata: <String, dynamic>{'batch': true, 'batchGroupId': group},
        );
      }
    }
    _logger.info('执行任务 ${task.name} 委派给 Agent ${agent.name}');
    return agent.execute(task.taskType, task.parameters);
  }

  IAgent? _resolveAgent(String targetAgentId) {
    // 先按 name（大小写不敏感）匹配，再按 id 匹配。
    final byName = _agentsByName[targetAgentId.toLowerCase()];
    if (byName != null) return byName;
    return _registeredAgents[targetAgentId];
  }

  WorkflowValidationResult _validate(WorkflowDefinition workflow) {
    for (final task in workflow.tasks) {
      if (_resolveAgent(task.targetAgentId) == null) {
        return WorkflowValidationResult(
          isValid: false,
          errorMessage:
              '任务 ${task.name} 的目标 Agent '
              '${task.targetAgentId} 未注册',
        );
      }
    }
    return const WorkflowValidationResult(isValid: true);
  }

  /// 基于 Kahn 算法的拓扑排序。
  ///
  /// 返回满足全部依赖的执行顺序；若存在循环依赖则抛出 [StateError]。
  List<WorkflowTask> _topologicalSort(List<WorkflowTask> tasks) {
    final idToTask = <String, WorkflowTask>{};
    final inDegree = <String, int>{};
    final dependents = <String, List<String>>{};
    for (final task in tasks) {
      idToTask[task.id] = task;
      inDegree.putIfAbsent(task.id, () => 0);
      dependents.putIfAbsent(task.id, () => <String>[]);
    }
    for (final task in tasks) {
      for (final depId in task.dependencies) {
        if (!idToTask.containsKey(depId)) continue; // 外部依赖忽略
        inDegree[task.id] = (inDegree[task.id] ?? 0) + 1;
        dependents[depId]!.add(task.id);
      }
    }

    final queue = Queue<String>();
    // 稳定排序：优先级高者先入队。
    final zeroInDegree =
        inDegree.entries
            .where((e) => e.value == 0)
            .map((e) => idToTask[e.key]!)
            .toList()
          ..sort((a, b) => b.priority.compareTo(a.priority));
    for (final t in zeroInDegree) {
      queue.addLast(t.id);
    }

    final ordered = <WorkflowTask>[];
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      ordered.add(idToTask[current]!);
      for (final next in dependents[current]!) {
        inDegree[next] = inDegree[next]! - 1;
        if (inDegree[next] == 0) queue.addLast(next);
      }
    }

    if (ordered.length != tasks.length) {
      throw StateError('工作流存在循环依赖，无法进行拓扑排序');
    }
    return ordered;
  }

  // ----- 预定义工作流（对 C# 简化版做了等价保留，并为后两个补充了可执行的编辑任务）-----

  WorkflowDefinition _createProjectInitializationWorkflow(
    Map<String, dynamic> parameters,
  ) {
    final theme = WorkflowTask(
      name: '主题分析',
      taskType: 'AnalyzeTheme',
      targetAgentId: 'director',
      parameters: parameters,
      priority: 10,
    );
    final outline = WorkflowTask(
      name: '生成大纲',
      taskType: 'GenerateOutline',
      targetAgentId: 'director',
      parameters: parameters,
      priority: 9,
    );
    final world = WorkflowTask(
      name: '创建世界设定',
      taskType: 'CreateWorldSetting',
      targetAgentId: 'director',
      parameters: parameters,
      priority: 8,
    );
    outline.dependencies.add(theme.id);
    world.dependencies.add(outline.id);

    return WorkflowDefinition(
      name: '项目初始化工作流',
      description: '创建新项目时的初始化流程',
      tasks: [theme, outline, world],
    );
  }

  WorkflowDefinition _createChapterCreationWorkflow(
    Map<String, dynamic> parameters,
  ) {
    final generate = WorkflowTask(
      name: '生成章节内容',
      taskType: 'GenerateChapterContent',
      targetAgentId: 'writer',
      parameters: parameters,
      priority: 10,
    );
    final summarize = WorkflowTask(
      name: '章节总结',
      taskType: 'SummarizeChapter',
      targetAgentId: 'summarizer',
      parameters: parameters,
      priority: 8,
    );
    final evaluate = WorkflowTask(
      name: '章节评价',
      taskType: 'EvaluateChapter',
      targetAgentId: 'reader',
      parameters: parameters,
      priority: 7,
    );
    summarize.dependencies.add(generate.id);
    evaluate.dependencies.add(generate.id);

    return WorkflowDefinition(
      name: '章节创建工作流',
      description: '创建新章节的完整流程',
      tasks: [generate, summarize, evaluate],
    );
  }

  WorkflowDefinition _createContentReviewWorkflow(
    Map<String, dynamic> parameters,
  ) => WorkflowDefinition(
    name: '内容审查工作流',
    description: '对内容进行全面审查',
    tasks: [
      WorkflowTask(
        name: '内容审查',
        taskType: 'ContentReview',
        targetAgentId: 'editor',
        parameters: parameters,
        priority: 10,
      ),
    ],
  );

  WorkflowDefinition _createConsistencyCheckWorkflow(
    Map<String, dynamic> parameters,
  ) => WorkflowDefinition(
    name: '一致性检查工作流',
    description: '检查内容的一致性',
    tasks: [
      WorkflowTask(
        name: '一致性检查',
        taskType: 'ConsistencyCheck',
        targetAgentId: 'editor',
        parameters: parameters,
        priority: 10,
      ),
    ],
  );

  // ----- 事件 -----

  void _onTaskStatusChanged(WorkflowTask task) {
    if (!_taskStatusChangedController.isClosed) {
      _taskStatusChangedController.add(task);
    }
  }

  void _onWorkflowStatusChanged(WorkflowDefinition workflow) {
    if (!_workflowStatusChangedController.isClosed) {
      _workflowStatusChangedController.add(workflow);
    }
  }

  /// 清理 workflow 绑定的 RWKV session（无论成功/失败/取消都要清）。
  void _cleanupSession(String workflowId) {
    final sid = _workflowSessions.remove(workflowId);
    final rp = _rwkvProvider;
    if (sid != null && rp != null) {
      rp.closeSession(sid);
      _logger.fine('工作流 $workflowId 的 RWKV session 已回收: $sid');
    }
  }

  /// 释放事件控制器。
  void dispose() {
    for (final wid in List<String>.from(_workflowSessions.keys)) {
      _cleanupSession(wid);
    }
    _workflowStatusChangedController.close();
    _taskStatusChangedController.close();
    _taskQueue.dispose();
  }
}
