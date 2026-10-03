// Agent 基础抽象：接口、状态、能力、任务结果，以及通用执行模板。
//
// 对应 C# 源文件 `Interfaces/IAgent.cs` 与 `Agents/BaseAgent.cs`。
//
// 与 C# 的主要差异：
// - `event EventHandler<T>` 改为由 `StreamController<T>.broadcast()` 暴露的只读
//   [Stream]（[statusChanged] / [taskCompleted] / [thinkingChainUpdated]）。
// - 去掉 `CancellationToken`。
// - 防递归降级标记 `_isFallbackExecution` 保留：AI 辅助失败时回退到本地执行，
//   回退路径内部再次进入 AI 辅助失败时直接返回失败，避免无限递归。
// - RWKV 本地推理通过可选 [RwkvProvider] 接入（其 `chat` 即本地 OpenAI 兼容调用），
//   优先于 ModelManager 的远程提供者；不可用时不降级到模拟数据。
// - `ID` 用基于时间戳的字符串生成（Dart 端不引 uuid）。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../memory/memory.dart';
import '../models/chat.dart';
import '../providers/model_manager.dart';
import '../providers/rwkv_provider.dart' show RwkvProvider;
import '../thinking/thinking_chain.dart';
import '../thinking/thinking_processor.dart';
import '../runtime_settings.dart';

/// Agent 状态枚举（对应 C# `AgentStatus`）。
enum AgentStatus {
  /// 空闲。
  idle,

  /// 工作中。
  working,

  /// 等待中。
  waiting,

  /// 错误。
  error,

  /// 离线。
  offline,
}

/// Agent 能力描述（对应 C# `AgentCapability`）。
class AgentCapability {
  /// 能力名称。
  final String name;

  /// 能力描述。
  final String description;

  /// 是否可用。
  final bool isAvailable;

  /// 优先级。
  final int priority;

  /// 构造能力描述。
  AgentCapability({
    this.name = '',
    this.description = '',
    this.isAvailable = true,
    this.priority = 0,
  });
}

/// Agent 状态信息（对应 C# `AgentStatusInfo`）。
class AgentStatusInfo {
  /// Agent ID。
  final String agentId;

  /// Agent 名称。
  final String name;

  /// 当前状态。
  final AgentStatus status;

  /// 状态描述。
  final String statusDescription;

  /// 当前任务。
  final String currentTask;

  /// 进度（0-100）。
  final int progress;

  /// 最后活动时间。
  final DateTime lastActivity;

  /// 错误信息。
  final String? errorMessage;

  /// 构造状态信息。
  AgentStatusInfo({
    required this.agentId,
    required this.name,
    required this.status,
    required this.statusDescription,
    required this.currentTask,
    required this.progress,
    required this.lastActivity,
    this.errorMessage,
  });
}

/// Agent 任务结果（对应 C# `AgentTaskResult`）。
class AgentTaskResult {
  /// 是否成功。
  bool isSuccess;

  /// 结果数据（任意类型）。
  dynamic data;

  /// 错误信息。
  String? errorMessage;

  /// 执行耗时。
  Duration executionTime;

  /// 附加元数据。
  final Map<String, dynamic> metadata;

  /// 构造任务结果。
  AgentTaskResult({
    this.isSuccess = false,
    this.data,
    this.errorMessage,
    this.executionTime = Duration.zero,
    Map<String, dynamic>? metadata,
  }) : metadata = metadata ?? <String, dynamic>{};
}

/// Agent 基础接口（对应 C# `IAgent`）。
abstract class IAgent {
  /// Agent 唯一标识。
  String get id;

  /// Agent 名称。
  String get name;

  /// Agent 描述。
  String get description;

  /// Agent 版本。
  String get version;

  /// 当前状态。
  AgentStatus get status;

  /// 状态变化事件流。
  Stream<AgentStatusInfo> get statusChanged;

  /// 任务完成事件流。
  Stream<AgentTaskResult> get taskCompleted;

  /// 执行任务。
  Future<AgentTaskResult> execute(String taskType, Map<String, dynamic> parameters);

  /// 获取能力列表。
  Future<List<AgentCapability>> getCapabilities();

  /// 获取状态信息。
  Future<AgentStatusInfo> getStatus();

  /// 初始化 Agent。
  Future<bool> initialize(Map<String, dynamic> configuration);

  /// 停止 Agent。
  Future<bool> stop();

  /// 重置 Agent。
  Future<bool> reset();

  /// 健康检查。
  Future<bool> healthCheck();
}

/// Agent 基础实现类（对应 C# `BaseAgent`）。
///
/// 提供统一的执行编排：创建思维链 → 调用具体任务（RWKV → 远程模型 → 本地回退）
/// → 记录记忆 → 触发完成事件。子类只需实现 [executeTask] 与 [supportedCapabilities]。
abstract class BaseAgent implements IAgent {
  @override
  final String id;

  final Logger _logger;
  final IMemoryManager? memoryManager;
  final IThinkingChainProcessor? thinkingChainProcessor;
  final ModelManager? modelManager;
  final RwkvProvider? rwkvService;

  /// RWKV 会话 ID：同一个 Agent 生命周期内多次 execute 自动共享同一个
  /// RWKV state 演化链，世界观/人设跨任务留存；调用方（WorkflowEngine）
  /// 也可在参数里显式覆盖 `parameters['rwkvSessionId']` 实现更大范围共享。
  String? _rwkvSessionId;

  @override
  String get version => '1.0.0';

  AgentStatus _status = AgentStatus.offline;
  String _currentTask = '';
  int _progress = 0;
  DateTime _lastActivity = DateTime.now();
  ThinkingChain? _currentThinkingChain;
  var _isFallbackExecution = false;

  final StreamController<AgentStatusInfo> _statusChangedController =
      StreamController<AgentStatusInfo>.broadcast();
  final StreamController<AgentTaskResult> _taskCompletedController =
      StreamController<AgentTaskResult>.broadcast();
  final StreamController<ThinkingChain> _thinkingChainUpdatedController =
      StreamController<ThinkingChain>.broadcast();

  /// 构造基础 Agent。
  BaseAgent({
    required Logger logger,
    this.memoryManager,
    this.thinkingChainProcessor,
    this.modelManager,
    this.rwkvService,
  }) : _logger = logger,
       id = DateTime.now().microsecondsSinceEpoch.toString();

  @override
  Stream<AgentStatusInfo> get statusChanged => _statusChangedController.stream;

  @override
  Stream<AgentTaskResult> get taskCompleted => _taskCompletedController.stream;

  /// 思维链更新事件流。
  Stream<ThinkingChain> get thinkingChainUpdated =>
      _thinkingChainUpdatedController.stream;

  /// 当前思维链。
  ThinkingChain? get currentThinkingChain => _currentThinkingChain;

  @override
  AgentStatus get status => _status;

  /// 设置状态（自动触发状态变更事件）。
  set status(AgentStatus value) {
    if (_status != value) {
      _status = value;
      _lastActivity = DateTime.now();
      _onStatusChanged();
    }
  }

  // ----- IAgent 实现 -----

  @override
  Future<AgentTaskResult> execute(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    final startTime = DateTime.now();
    try {
      _logger.info('Agent $name 开始执行任务: $taskType');
      status = AgentStatus.working;
      _currentTask = taskType;
      _progress = 0;

      ThinkingChain? thinkingChain;
      if (thinkingChainProcessor != null && shouldUseThinkingChain(taskType)) {
        thinkingChain = ThinkingChain(
          title: '$name - $taskType',
          description: '执行任务: $taskType',
          taskId: id,
          agentId: id,
        );
        thinkingChain.start();
        currentThinkingChain = thinkingChain;
      }

      final result = await executeTaskWithThinking(taskType, parameters, thinkingChain);
      result.executionTime = DateTime.now().difference(startTime);

      if (thinkingChain != null) {
        thinkingChain.finalOutput = result.data?.toString() ?? '';
        thinkingChain.complete();
      }

      _progress = 100;
      status = AgentStatus.idle;
      _currentTask = '';
      currentThinkingChain = null;

      _logger.info('Agent $name 完成任务: $taskType, 耗时: '
          '${(result.executionTime.inMilliseconds / 1000).toStringAsFixed(2)}秒');
      _onTaskCompleted(result);
      return result;
    } catch (e, st) {
      _logger.severe('Agent $name 执行任务失败: $taskType', e, st);
      currentThinkingChain?.fail();
      status = AgentStatus.error;
      currentThinkingChain = null;
      final errorResult = AgentTaskResult(
        isSuccess: false,
        errorMessage: e.toString(),
        executionTime: DateTime.now().difference(startTime),
      );
      _onTaskCompleted(errorResult);
      return errorResult;
    }
  }

  @override
  Future<List<AgentCapability>> getCapabilities() async =>
      supportedCapabilities();

  @override
  Future<AgentStatusInfo> getStatus() async => AgentStatusInfo(
        agentId: id,
        name: name,
        status: status,
        statusDescription: statusDescription,
        currentTask: _currentTask,
        progress: _progress,
        lastActivity: _lastActivity,
        errorMessage: status == AgentStatus.error ? 'Agent执行出错' : null,
      );

  @override
  Future<bool> initialize(Map<String, dynamic> configuration) async {
    try {
      _logger.info('初始化 Agent: $name');
      final result = await initializeAgent(configuration);
      status = result ? AgentStatus.idle : AgentStatus.error;
      return result;
    } catch (e, st) {
      _logger.severe('初始化 Agent $name 异常', e, st);
      status = AgentStatus.error;
      return false;
    }
  }

  @override
  Future<bool> stop() async {
    final result = await stopAgent();
    if (result) {
      status = AgentStatus.offline;
      closeRwkvSession();
    }
    return result;
  }

  @override
  Future<bool> reset() async {
    final result = await resetAgent();
    if (result) {
      status = AgentStatus.idle;
      _currentTask = '';
      _progress = 0;
      closeRwkvSession();
    }
    return result;
  }

  @override
  Future<bool> healthCheck() async => performHealthCheck();

  // ----- 抽象 / 可覆写方法 -----

  /// 执行具体任务（子类实现）。
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  );

  /// 返回支持的能力列表（子类实现）。
  List<AgentCapability> supportedCapabilities();

  /// 初始化 Agent（子类可覆写）。
  Future<bool> initializeAgent(Map<String, dynamic> configuration) async => true;

  /// 停止 Agent（子类可覆写）。
  Future<bool> stopAgent() async => true;

  /// 重置 Agent（子类可覆写）。
  Future<bool> resetAgent() async => true;

  /// 健康检查（子类可覆写）。
  Future<bool> performHealthCheck() async => status != AgentStatus.error;

  // ----- 记忆辅助 -----

  Future<MemoryContext?> getMemoryContext(
    String taskType,
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  }) async {
    if (memoryManager == null) {
      _logger.warning('记忆管理器未配置，无法获取记忆上下文');
      return null;
    }
    try {
      return await memoryManager!.getContext(
        taskType,
        scope,
        projectId,
        volumeId: volumeId,
        chapterId: chapterId,
      );
    } catch (e, st) {
      _logger.severe('获取记忆上下文失败', e, st);
      return null;
    }
  }

  Future<bool> updateMemory(
    String content,
    int importanceScore,
    MemoryScope scope,
    String projectId, {
    String? volumeId,
    String? chapterId,
  }) async {
    if (memoryManager == null) return true;
    try {
      return await memoryManager!.updateMemory(
        content,
        importanceScore,
        scope,
        projectId,
        volumeId: volumeId,
        chapterId: chapterId,
      );
    } catch (e, st) {
      _logger.severe('更新记忆失败', e, st);
      return false;
    }
  }

  Future<List<MemoryItem>> searchMemory(
    String query,
    MemoryScope scope,
    String projectId, {
    int maxResults = 10,
  }) async {
    if (memoryManager == null) return const [];
    try {
      return await memoryManager!.searchMemory(
        query,
        scope,
        projectId,
        maxResults: maxResults,
      );
    } catch (e, st) {
      _logger.severe('搜索记忆失败', e, st);
      return const [];
    }
  }

  Future<bool> recordExecutionResult(
    String taskType,
    AgentTaskResult result,
    String projectId, {
    String? volumeId,
    String? chapterId,
  }) async {
    if (memoryManager == null || !result.isSuccess) return true;
    final content = '$name 执行任务 $taskType：${result.data?.toString() ?? "无结果"}';
    final scope = chapterId != null
        ? MemoryScope.chapter
        : (volumeId != null ? MemoryScope.volume : MemoryScope.global);
    return updateMemory(content, 6, scope, projectId,
        volumeId: volumeId, chapterId: chapterId);
  }

  // ----- 执行编排 -----

  /// 是否对指定任务使用思维链（受 AI 配置页「思维链开关 + 思考强度」控制）。
  ///
  /// - 开关关闭：一律不启用（此前 processor 注入即启用的行为由开关接管）；
  /// - 低：仅核心长文任务（正文/大纲/续写/角色设计）；
  /// - 中：默认复杂任务集合（与历史行为一致）；
  /// - 高：所有任务。
  bool shouldUseThinkingChain(String taskType) {
    final AiRuntimeSettings settings = aiRuntimeSettings;
    if (!settings.thinkingEnabled) return false;
    const coreTasks = {
      'GenerateChapterContent',
      'GenerateOutline',
      'ContinueChapter',
      'DesignCharacters',
    };
    switch (settings.thinkingIntensity) {
      case ThinkingIntensity.low:
        return coreTasks.contains(taskType);
      case ThinkingIntensity.high:
        return true;
      case ThinkingIntensity.medium:
        break;
    }
    const complexTasks = {
      'GenerateOutline',
      'CreateWorldSetting',
      'DesignCharacters',
      'GenerateChapterContent',
      'AnalyzeTheme',
      'OptimizeOutline',
      'EvaluateChapter',
      'SuggestImprovements',
    };
    return complexTasks.contains(taskType);
  }

  // ---------- 批量协作钩子（供 BatchAgentExecutor 使用）----------
  //
  // ⚠ 这里刻意用 (taskType, parameters) 而不是直接收 WorkflowTask：
  // `workflow.dart` 已经 `import 'agents/agent.dart'`，反向 import 会形成循环依赖。
  // 语义等价，`BatchAgentExecutor` 调时传 `task.taskType` / `task.parameters` 即可。

  /// 构造**批量 prompt**（纯文本）—— 会被攒进一次
  /// `POST /v1/batch/completions` 的 `contents[]` 里。
  ///
  /// **默认返回 `null` = 「本 Agent 不支持攒批」，这是刻意的**。
  ///
  /// 为什么不像早期版本那样返回一个「把 parameters 拍平」的兜底文本：
  /// 批量路由是**无状态**的（不带 `rwkvSessionId` 的 state 续跑），prompt 必须
  /// **自包含**上下文；而单路路径靠 Agent 自己精心构造的 prompt + 会话 state。
  /// 一个「拍平参数」的兜底文本在单路上看起来能跑通，批量下却会**静默降质**
  /// —— 用户只会觉得"开了攒批之后文笔变差了"，根本定位不到原因。
  ///
  /// ⇒ 想让某个 Agent 参与攒批，**必须覆写本方法**并返回与单路等价的 prompt
  ///   （含 system 指令、世界观上下文、输出格式约束）。
  ///   `undefined` 之外的情况（例如 `parameters['batchPrompt']` 由调用方给定时）
  ///   由子类自己决定要不要透传。
  ///
  /// 判定「支持攒批」的唯一依据就是本方法是否返回非 null —— `AgentBatchSettings`
  /// 与 `AsyncAgentExecutor` 都以此为准，所以**不会出现"开关打开了但没效果"**。
  String? buildPromptForBatch(
    String taskType,
    Map<String, dynamic> parameters,
  ) {
    // 调用方显式给定的批量 prompt 视为「已提供自包含 prompt」，可以直接用
    final Object? explicit = parameters['batchPrompt'];
    if (explicit is String && explicit.trim().isNotEmpty) {
      return explicit;
    }
    if (!supportsBatchPrompt) return null;
    return buildSelfContainedPrompt(taskType, parameters);
  }

  /// 本 Agent 的 prompt 是否可安全地拼成**自包含**的批量 prompt。
  ///
  /// 默认 `false`（保守）。内置 8 个 Agent 都覆写为 `true` —— 因为它们的单路
  /// 请求就是 `ChatRequest(systemPrompt: buildSystemPrompt(taskType),
  /// messages: [user(buildUserPrompt(...))])`（见 [executeTaskWithAI]），
  /// **只有 system + 一条 user**，所以直接拼接即与单路**同源**。
  ///
  /// ⚠ 若某个子类在 `buildSystemPrompt` / `buildUserPrompt` 之外还依赖别处状态
  /// （例如自己拼了多轮消息、依赖外部变量），**不要**置 true，而是自己覆写
  /// [buildPromptForBatch] 把上下文完整带上。
  bool get supportsBatchPrompt => false;

  /// 把 `system` + `user` 两段拼成一条自包含 prompt（经典 RWKV 格式）。
  ///
  /// **为什么必须内联 system**：批量路由 `/v1/batch/completions` 是无状态的
  /// （只吃 `contents: string[]`，没有 system/messages 概念），而单路路径
  /// 靠 `ChatRequest.systemPrompt` + 会话 state 承载上下文。
  /// 不内联就等于把这些约束**丢掉**，结果就是"开了攒批之后文笔变差"。
  String buildSelfContainedPrompt(
    String taskType,
    Map<String, dynamic> parameters,
  ) {
    final String sys = buildSystemPrompt(taskType).trim();
    final String user = buildUserPrompt(taskType, parameters).trim();
    final StringBuffer b = StringBuffer();
    if (sys.isNotEmpty) b.write('System: $sys\n\n');
    b.write('User: $user\n\n');
    b.write('Assistant:');
    return b.toString();
  }

  /// 把批量返回的**原始文本**结构化成 [AgentTaskResult]。
  ///
  /// 默认实现原样包进 `data`；**子类可覆写**以做 JSON 解析、字段校验、
  /// 失败判定（批量场景下单个槽位出错不应该让整批失败）。
  AgentTaskResult processBatchResponse(
    String taskType,
    Map<String, dynamic> parameters,
    String rawText,
  ) {
    final String text = rawText.trim();
    return AgentTaskResult(
      isSuccess: text.isNotEmpty,
      data: text,
      errorMessage: text.isEmpty ? '批量返回内容为空（$taskType）' : null,
      metadata: <String, dynamic>{'batch': true, 'taskType': taskType},
    );
  }

  Future<AgentTaskResult> executeTaskWithThinking(
    String taskType,
    Map<String, dynamic> parameters,
    ThinkingChain? thinkingChain,
  ) async {
    final rwkvResult = await tryExecuteWithRwkv(taskType, parameters, thinkingChain);
    if (rwkvResult != null) return rwkvResult;

    if (thinkingChain != null && (modelManager != null || rwkvService != null)) {
      return executeTaskWithAI(taskType, parameters, thinkingChain);
    }
    return executeTask(taskType, parameters);
  }

  Future<AgentTaskResult> executeTaskWithAI(
    String taskType,
    Map<String, dynamic> parameters,
    ThinkingChain thinkingChain,
  ) async {
    try {
      final rwkvResult = await tryExecuteWithRwkv(taskType, parameters, thinkingChain);
      if (rwkvResult != null) return rwkvResult;

      final systemPrompt = buildSystemPrompt(taskType);
      final userPrompt = buildUserPrompt(taskType, parameters);

      final defaultProvider = modelManager?.getDefaultProvider();
      String aiResponse;
      if (modelManager != null &&
          defaultProvider != null &&
          defaultProvider.isAvailable) {
        _logger.info('使用模型提供者 ${defaultProvider.providerName} 执行任务: $taskType');
        final request = ChatRequest(
          systemPrompt: systemPrompt,
          messages: [ChatMessage.user(userPrompt)],
          temperature: 0.7,
          maxTokens: 4000,
        );
        final response =
            await modelManager!.chatWith(request, defaultProvider.providerName);
        if (!response.isSuccess) {
          throw Exception('${defaultProvider.providerName} 模型调用失败: '
              '${response.errorMessage}');
        }
        aiResponse = response.content;
        if (aiResponse.trim().isEmpty) {
          throw Exception('${defaultProvider.providerName} 模型返回空响应');
        }
      } else if (rwkvService != null && rwkvService!.isAvailable) {
        final sessionId = _resolveRwkvSessionId(parameters);
        final response = await rwkvService!.chatInSession(
          ChatRequest(
            systemPrompt: systemPrompt,
            messages: [ChatMessage.user(userPrompt)],
            temperature: 0.7,
            maxTokens: resolveRwkvMaxTokens(taskType),
          ),
          sessionId: sessionId,
          sessionLabel: '$name-${taskType}_$id',
        );
        if (!response.isSuccess || response.content.trim().isEmpty) {
          throw Exception('RWKV 推理失败: ${response.errorMessage}');
        }
        aiResponse = response.content;
      } else {
        throw Exception('没有可用的 AI 服务');
      }

      // 必须先 await：直接 return Future 会绕过本 catch —— processAIResponse
      // 内部的异步解析异常将成为未处理异步错误，精心设计的降级/回退链全部失效。
      return await processAIResponse(taskType, aiResponse, parameters);
    } catch (e, st) {
      _logger.severe('AI 辅助执行任务失败: $taskType', e, st);
      if (_isFallbackExecution) {
        return AgentTaskResult(
          isSuccess: false,
          errorMessage: 'AI 服务不可用且回退执行失败: ${e.toString()}',
        );
      }
      _isFallbackExecution = true;
      try {
        return await executeTask(taskType, parameters);
      } finally {
        _isFallbackExecution = false;
      }
    }
  }

  /// 尝试用本地 RWKV 推理执行；服务不可用返回 null（调用方继续其他链路）。
  ///
  /// 支持 State 复用：同一 Agent 或同一 workflow 的多次调用会在同一个
  /// RWKV 会话内派生 state，世界观/人设/大纲不需要每次重新 prefill。
  Future<AgentTaskResult?> tryExecuteWithRwkv(
    String taskType,
    Map<String, dynamic> parameters,
    ThinkingChain? thinkingChain,
  ) async {
    if (rwkvService == null || !rwkvService!.isAvailable) return null;
    _logger.info('使用本地 RWKV 推理执行任务: $taskType');
    if (thinkingChain != null) {
      addThinkingStep('调用本地模型', '使用本地 RWKV 推理服务生成内容（含 State 复用）',
          ThinkingStepType.synthesis, 0.9);
    }
    try {
      final systemPrompt = buildSystemPrompt(taskType);
      final userPrompt = buildUserPrompt(taskType, parameters);
      final sessionId = _resolveRwkvSessionId(parameters);
      final response = await rwkvService!.chatInSession(
        ChatRequest(
          systemPrompt: systemPrompt,
          messages: [ChatMessage.user(userPrompt)],
          temperature: 0.7,
          maxTokens: resolveRwkvMaxTokens(taskType),
        ),
        sessionId: sessionId,
        sessionLabel: '$name-${taskType}_$id',
      );
      if (!response.isSuccess || response.content.trim().isEmpty) {
        return AgentTaskResult(
          isSuccess: false,
          errorMessage: response.errorMessage ?? 'RWKV 推理返回空结果',
        );
      }
      // 同上：await 后异步解析异常才能落入下方 catch 统一兜底。
      return await processAIResponse(taskType, response.content, parameters);
    } catch (e, st) {
      _logger.severe('RWKV 推理任务 $taskType 异常', e, st);
      return AgentTaskResult(
        isSuccess: false,
        errorMessage: 'RWKV 推理失败: ${e.toString()}',
      );
    }
  }

  /// 解析 RWKV 会话 ID：
  /// 1. 调用方通过 parameters['rwkvSessionId'] 显式传入时优先（workflow 跨任务共享）
  /// 2. Agent 级 `_rwkvSessionId` 存在则用
  /// 3. 否则新建一个并写入 Agent 级字段
  String _resolveRwkvSessionId(Map<String, dynamic> parameters) {
    if (rwkvService == null) return '';
    final fromParam = parameters['rwkvSessionId'] as String?;
    if (fromParam != null && fromParam.isNotEmpty) {
      return fromParam;
    }
    _rwkvSessionId ??= rwkvService!.openSession(
      label: '$name-Agent_$id',
    );
    return _rwkvSessionId!;
  }

  /// 关闭 Agent 绑定的 RWKV 会话（state 从缓存移除）。
  void closeRwkvSession() {
    if (rwkvService != null && _rwkvSessionId != null) {
      rwkvService!.closeSession(_rwkvSessionId!);
      _rwkvSessionId = null;
    }
  }

  /// 按任务类型解析 RWKV 生成的最大 token 数。
  int resolveRwkvMaxTokens(String taskType) {
    switch (taskType) {
      case 'GenerateOutline':
      case 'CreateWorldSetting':
      case 'GenerateChapterContent':
      case 'ContinueChapter':
        return 2048;
      case 'PolishText':
      case 'OptimizeOutline':
      case 'OptimizePlot':
        return 1800;
      case 'GenerateCharacter':
      case 'OptimizeCharacter':
      case 'GeneratePlot':
      case 'GetPlotSuggestions':
        return 1200;
      case 'SummarizeChapter':
      case 'SummarizeVolume':
        return 800;
      default:
        return 1200;
    }
  }

  /// 构建系统提示（子类可覆写）。
  String buildSystemPrompt(String taskType) =>
      '你是一个专业的$name，负责$description。请根据用户的要求执行$taskType任务，'
      '并提供详细的思考过程。';

  /// 构建用户提示（子类可覆写）。
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final buffer = StringBuffer('请执行$taskType任务。');
    if (parameters.isNotEmpty) {
      buffer.write('\n参数信息：');
      parameters.forEach((key, value) {
        buffer.write('\n- $key: $value');
      });
    }
    return buffer.toString();
  }

  /// 处理 AI 响应（默认原样返回）。
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async {
    return AgentTaskResult(
      isSuccess: true,
      data: aiResponse,
      metadata: {
        'Message': 'AI辅助完成任务: $taskType',
        'TaskType': taskType,
      },
    );
  }

  /// 向当前思维链追加一个已完成的步骤。
  void addThinkingStep(
    String title,
    String content, [
    ThinkingStepType type = ThinkingStepType.reasoning,
    double confidence = 0.8,
  ]) {
    if (_currentThinkingChain != null) {
      final step = ThinkingStep(
        title: title,
        content: content,
        type: type,
        confidence: confidence,
      );
      step.start();
      _currentThinkingChain!.addStep(step);
      step.complete();
      _currentThinkingChain!.updateProgress();
    }
  }

  // ----- 状态辅助 -----

  String get statusDescription {
    switch (status) {
      case AgentStatus.idle:
        return '空闲中';
      case AgentStatus.working:
        return '执行中: $_currentTask';
      case AgentStatus.waiting:
        return '等待中';
      case AgentStatus.error:
        return '错误状态';
      case AgentStatus.offline:
        return '离线';
    }
  }

  /// 更新进度（0-100）。
  void updateProgress(int progress) {
    _progress = progress.clamp(0, 100);
    _lastActivity = DateTime.now();
    _onStatusChanged();
  }

  set currentThinkingChain(ThinkingChain? value) {
    if (_currentThinkingChain != value) {
      _currentThinkingChain = value;
      if (value != null) _thinkingChainUpdatedController.add(value);
    }
  }

  void _onStatusChanged() {
    if (_statusChangedController.isClosed) return;
    _statusChangedController.add(AgentStatusInfo(
      agentId: id,
      name: name,
      status: status,
      statusDescription: statusDescription,
      currentTask: _currentTask,
      progress: _progress,
      lastActivity: _lastActivity,
      errorMessage: status == AgentStatus.error ? 'Agent执行出错' : null,
    ));
  }

  void _onTaskCompleted(AgentTaskResult result) {
    if (!_taskCompletedController.isClosed) {
      _taskCompletedController.add(result);
    }
  }

  /// 释放事件控制器。
  void dispose() {
    _statusChangedController.close();
    _taskCompletedController.close();
    _thinkingChainUpdatedController.close();
    closeRwkvSession();
  }
}
