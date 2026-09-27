// AI 写作门面 —— 对应 C# `WPF/Services/AIAssistantService.cs` 的 4 个创作入口。
//
// 职责：**先让双 Agent 流程决定是否接管，不接管才走原单 Agent 链路**。
// C# 是在每个入口前插一层 `if (workflowResult != null) return …`；这里收敛成一个 [_run]。
//
// 与 C# 的差异（唯一一处有意兜底，见 [AiWritingService._run] 注释）：
// 当双 Agent 因「指名的 provider 不可用」失败时，Flutter 侧会继续走单 Agent，
// 避免用户没进过 AI 配置页就完全用不了润色/大纲；其余失败一律原样返回，不掩盖问题。
//
// 注：本服务不持有 Logger（与 `ProjectService` / `CharacterService` 的层内约定一致），
// 失败原因通过 `metadata['DualAgentFailureKind']` 暴露给调用方自行展示。
library;

import '../../ai/agents/agent.dart';
import '../../ai/utils/localized_text.dart';
import '../../ai/workflow/dual_agent_workflow.dart';
import 'project_context_assembler.dart';

/// 单次 AI 创作调用的结果。
class AIAssistantResult {
  const AIAssistantResult({
    required this.isSuccess,
    required this.data,
    required this.message,
    this.metadata = const <String, String>{},
    this.executionTime = Duration.zero,
  });

  final bool isSuccess;

  /// 生成内容（正文 / 大纲 / 润色结果）。
  final String data;

  /// 面向用户的结果说明。
  final String message;

  /// 附加信息，含 `WorkflowMode`（`DualAgent` / `SingleAgent`）。
  final Map<String, String> metadata;

  final Duration executionTime;

  /// 本次是否由双 Agent 流程产出。
  bool get isDualAgent => metadata['WorkflowMode'] == 'DualAgent';
}

/// AI 写作门面（4 个创作入口与 C# 一一对应）。
class AiWritingService {
  AiWritingService({
    required DualAgentWorkflowService dualAgent,
    required ProjectContextAssembler contextAssembler,
    required AiTextSource texts,
    required List<BaseAgent> Function() agents,
  })  : _dualAgent = dualAgent,
        _contextAssembler = contextAssembler,
        _texts = texts,
        _agents = agents;

  final DualAgentWorkflowService _dualAgent;
  final ProjectContextAssembler _contextAssembler;
  final AiTextSource _texts;
  final List<BaseAgent> Function() _agents;

  /// 对应 C# `GenerateOutlineAsync`。
  Future<AIAssistantResult> generateOutline(Map<String, dynamic> parameters) =>
      _run('GenerateOutline', parameters,
          subsystem: _texts.isEnglish ? 'outline' : '大纲');

  /// 对应 C# `GenerateChapterAsync`。
  Future<AIAssistantResult> generateChapterContent(
          Map<String, dynamic> parameters) =>
      _run('GenerateChapterContent', parameters,
          subsystem: _texts.isEnglish ? 'chapter' : '章节');

  /// 对应 C# `ContinueChapterAsync`。
  Future<AIAssistantResult> continueChapter(Map<String, dynamic> parameters) =>
      _run('ContinueChapter', parameters,
          subsystem: _texts.isEnglish ? 'chapter' : '章节');

  /// 对应 C# `PolishTextAsync`。
  Future<AIAssistantResult> polishText(Map<String, dynamic> parameters) =>
      _run('PolishText', parameters,
          subsystem: _texts.isEnglish ? 'polishing' : '润色');

  Future<AIAssistantResult> _run(
    String taskType,
    Map<String, dynamic> parameters, {
    required String subsystem,
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    final Map<String, dynamic> params = Map<String, dynamic>.of(parameters);

    // 项目级上下文注入：参数里没有 PromptSummary 时补上（对应 C# 各页面自行塞入 parameters）
    final String projectId = '${params['ProjectId'] ?? ''}'.trim();
    if (projectId.isNotEmpty && !params.containsKey('PromptSummary')) {
      final String ctx = await _contextAssembler.buildSubsystemPromptContext(
        projectId,
        subsystem,
      );
      if (ctx.isNotEmpty) params['PromptSummary'] = ctx;
    }

    final AIAgentRoleWorkflowResult? dual =
        await _dualAgent.tryExecute(taskType, params);
    if (dual != null) {
      // 双 Agent 已接管：只有「指名 provider 不可用」这一种失败允许回退单 Agent
      // （用户没进过 AI 配置页 / 没启用双代理提供者时，仍然能用单 Agent 完成创作）
      if (!dual.isSuccess && dual.failureKind == 'providerMissing') {
        return _singleAgent(taskType, params, sw,
            extraMetadata: <String, String>{
              'DualAgentFailureKind': 'providerMissing',
            });
      }
      return AIAssistantResult(
        isSuccess: dual.isSuccess,
        data: dual.content,
        message: dual.message,
        metadata: dual.metadata,
        executionTime: sw.elapsed,
      );
    }

    // 双 Agent 不接管（任务不在白名单 / 总开关关闭）→ 原单 Agent 链路
    return _singleAgent(taskType, params, sw);
  }

  /// 单 Agent 回退：按 `supportedCapabilities()` 的能力名匹配第一个可执行的 Agent。
  Future<AIAssistantResult> _singleAgent(
    String taskType,
    Map<String, dynamic> params,
    Stopwatch sw, {
    Map<String, String> extraMetadata = const <String, String>{},
  }) async {
    for (final BaseAgent agent in _agents()) {
      final bool canHandle = agent.supportedCapabilities().any(
            (AgentCapability c) =>
                c.name.toLowerCase() == taskType.toLowerCase(),
          );
      if (!canHandle) continue;

      final AgentTaskResult r = await agent.execute(taskType, params);
      return AIAssistantResult(
        isSuccess: r.isSuccess,
        data: r.data?.toString() ?? '',
        message: r.isSuccess
            ? _texts.t('DWS.SuccessSingle', '已通过单 Agent 流程生成内容。')
            : (r.errorMessage ?? ''),
        metadata: <String, String>{
          'WorkflowMode': 'SingleAgent',
          'TaskType': taskType,
          'Agent': agent.name,
          // ⚠ 必须透传 `Fallback`：`BaseAgent` 在模型调用失败时会**静默回退**到
          // `executeTask`，那里返回的是内置示例文本且 `isSuccess = true`。
          // 调用方（章节改稿）据此拒绝落库，否则示例文本会覆盖作者正文。
          if (r.metadata['Fallback'] == true) 'Fallback': 'true',
          ...extraMetadata,
        },
        executionTime: sw.elapsed,
      );
    }

    return AIAssistantResult(
      isSuccess: false,
      data: '',
      message: _texts.tf(
        'AIW.AgentMissing',
        '未找到可执行「{0}」任务的 Agent。',
        <Object>[taskType],
      ),
      metadata: <String, String>{
        'WorkflowMode': 'SingleAgent',
        'TaskType': taskType,
        ...extraMetadata,
      },
      executionTime: sw.elapsed,
    );
  }
}