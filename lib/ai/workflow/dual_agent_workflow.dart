// MainAgent / SubAgent 双 Agent 写作流。
//
// 对应 C# `WPF/Services/AIAgentRoleWorkflowService.cs`。
//
// 三段式：① SubAgent 出「需求简报」→ ② MainAgent 据简报写草稿 → ③ SubAgent 净化定稿。
// 上层调用方（[AiWritingService]、一键生成书籍）按
// `final r = await dualAgent.tryExecute(T, params); if (r != null) return r;` 的方式接入：
//
//   **返回 null = 本服务不接管（任务不在白名单 / 开关关闭），调用方走原单 Agent 链路；
//     返回非 null（含失败）= 已接管，调用方不得再回退。**
//
// 已**有意不移植**的 C# 内容：
// 1. `ReportDebugEventAsync` / `FindDebugEnvPath` —— 生产代码里的调试插桩
//    （硬编码 `http://127.0.0.1:7777/event`、遍历父目录找 `.dbg/*.env`），一行都不要。
// 2. 无重试、非流式、不写缓存 —— 这是 C# 的既定行为，照搬（不要"顺手优化"：
//    加缓存会破坏"同参重生成"体验，加重试会掩盖 provider 真实状态）。
//
// 与 C# 的**唯一有意偏离**：默认 provider 由 `DeepSeek` / `LlamaCpp` 改为 `RWKV`。
// 原因见 [AgentRoleWorkflowSettings.defaults] 注释。
//
// 纯 Dart（不依赖 `package:flutter`），可由 `tool/verify_dual_agent.dart` 直跑验证。
library;

import 'package:logging/logging.dart';

import '../models/chat.dart';
import '../models/provider.dart';
import '../prompts/prompt_template.dart';
import '../rwkv/rwkv_sampling.dart';
import '../runtime_settings.dart';
import '../utils/localized_text.dart';
import '../utils/output_sanitizer.dart';

/// 归档写入回调 —— 返回机器码（`ok` / `empty` / `noProject` / `notFound` / `failed`）。
///
/// 用回调而不是直接依赖归档服务，是为了让 `lib/ai` 不反向依赖 `lib/application`。
typedef CleanContentArchiver = Future<String> Function({
  required String? projectId,
  required String taskType,
  required String content,
  String? titleHint,
  Map<String, String>? metadata,
});

/// 双 Agent 配置（对应 C# `AgentRoleWorkflowSettings`）。
class AgentRoleWorkflowSettings {
  const AgentRoleWorkflowSettings({
    this.enableDualAgentWorkflow = true,
    this.enableArchiveWrite = true,
    this.mainAgentProvider = 'RWKV',
    this.mainAgentModel = '',
    this.mainAgentRoleDescription = _defaultMainRole,
    this.subAgentProvider = 'RWKV',
    this.subAgentModel = '',
    this.subAgentRoleDescription = _defaultSubRole,
  });

  /// 默认配置。
  ///
  /// ⚠ **有意偏离 C#**：C# 默认 `MainAgentProvider="DeepSeek"`、`SubAgentProvider="LlamaCpp"`。
  /// Flutter 侧没有 `LlamaCpp`，且 `ModelManager` 只在用户进过「AI 配置」并保存/测试后才注册
  /// provider（全新会话里注册表是空的）——照抄默认值会让一键生成书籍在第 5 步硬失败。
  /// 因此默认指向 `RWKV`（一键流程第 1 步就已 `testConnection` 过的引擎），
  /// 用户可在 AI 配置页改成云端强模型。C# 的**结构语义**（两个角色、各自 System 模板、
  /// 三次调用、回显守卫）完整保留。
  static const AgentRoleWorkflowSettings defaults = AgentRoleWorkflowSettings();

  static const String _defaultMainRole = '结合 SubAgent 的需求简报撰写正式文案，专注内容创作。';
  static const String _defaultSubRole =
      '总结写作需求，整理 MainAgent 草稿，并将纯净内容写入项目档案库。';

  final bool enableDualAgentWorkflow;
  final bool enableArchiveWrite;
  final String mainAgentProvider;
  final String mainAgentModel;
  final String mainAgentRoleDescription;
  final String subAgentProvider;
  final String subAgentModel;
  final String subAgentRoleDescription;

  AgentRoleWorkflowSettings copyWith({
    bool? enableDualAgentWorkflow,
    bool? enableArchiveWrite,
    String? mainAgentProvider,
    String? mainAgentModel,
    String? mainAgentRoleDescription,
    String? subAgentProvider,
    String? subAgentModel,
    String? subAgentRoleDescription,
  }) {
    return AgentRoleWorkflowSettings(
      enableDualAgentWorkflow:
          enableDualAgentWorkflow ?? this.enableDualAgentWorkflow,
      enableArchiveWrite: enableArchiveWrite ?? this.enableArchiveWrite,
      mainAgentProvider: mainAgentProvider ?? this.mainAgentProvider,
      mainAgentModel: mainAgentModel ?? this.mainAgentModel,
      mainAgentRoleDescription:
          mainAgentRoleDescription ?? this.mainAgentRoleDescription,
      subAgentProvider: subAgentProvider ?? this.subAgentProvider,
      subAgentModel: subAgentModel ?? this.subAgentModel,
      subAgentRoleDescription:
          subAgentRoleDescription ?? this.subAgentRoleDescription,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'enableDualAgentWorkflow': enableDualAgentWorkflow,
        'enableArchiveWrite': enableArchiveWrite,
        'mainAgentProvider': mainAgentProvider,
        'mainAgentModel': mainAgentModel,
        'mainAgentRoleDescription': mainAgentRoleDescription,
        'subAgentProvider': subAgentProvider,
        'subAgentModel': subAgentModel,
        'subAgentRoleDescription': subAgentRoleDescription,
      };

  /// 对应 C# `LoadSettings()` —— 字段缺失即回落默认值。
  factory AgentRoleWorkflowSettings.fromJson(Map<String, Object?> json) {
    String str(String key, String fallback) {
      final Object? v = json[key];
      if (v is String && v.isNotEmpty) return v;
      return fallback;
    }

    bool flag(String key, bool fallback) {
      final Object? v = json[key];
      return v is bool ? v : fallback;
    }

    return AgentRoleWorkflowSettings(
      enableDualAgentWorkflow: flag('enableDualAgentWorkflow', true),
      enableArchiveWrite: flag('enableArchiveWrite', true),
      mainAgentProvider: str('mainAgentProvider', defaults.mainAgentProvider),
      // 模型名允许为空（空 = 用 provider 侧默认模型）
      mainAgentModel: (json['mainAgentModel'] as String?) ?? '',
      mainAgentRoleDescription:
          str('mainAgentRoleDescription', _defaultMainRole),
      subAgentProvider: str('subAgentProvider', defaults.subAgentProvider),
      subAgentModel: (json['subAgentModel'] as String?) ?? '',
      subAgentRoleDescription: str('subAgentRoleDescription', _defaultSubRole),
    );
  }
}

/// 双 Agent 执行结果（对应 C# `AIAgentRoleWorkflowResult`）。
class AIAgentRoleWorkflowResult {
  const AIAgentRoleWorkflowResult({
    required this.isSuccess,
    required this.content,
    required this.message,
    this.metadata = const <String, String>{},
  });

  /// 已接管但执行失败。
  const AIAgentRoleWorkflowResult.failed(
    this.message, {
    this.metadata = const <String, String>{},
  })  : isSuccess = false,
        content = '';

  final bool isSuccess;
  final String content;
  final String message;
  final Map<String, String> metadata;

  /// 失败原因分类（仅 `providerMissing` 会被上层用来决定"是否回退单 Agent"）。
  String? get failureKind => metadata['failureKind'];
}

/// MainAgent / SubAgent 双 Agent 写作流。
class DualAgentWorkflowService {
  DualAgentWorkflowService({
    required Logger logger,
    required AgentRoleWorkflowSettings Function() settings,
    required Map<String, IModelProvider> Function() providers,
    required AiTextSource texts,
    required PromptTemplateRegistry Function() templates,
    CleanContentArchiver? archiver,
  })  : _logger = logger,
        _settings = settings,
        _providers = providers,
        _texts = texts,
        _templates = templates,
        _archiver = archiver;

  /// 白名单 —— 只有这 4 个任务类型会被接管（对应 C# `IsSupportedTask`）。
  static const Set<String> supportedTasks = <String>{
    'GenerateChapterContent',
    'ContinueChapter',
    'PolishText',
    'GenerateOutline',
  };

  final Logger _logger;
  final AgentRoleWorkflowSettings Function() _settings;
  final Map<String, IModelProvider> Function() _providers;
  final AiTextSource _texts;
  final PromptTemplateRegistry Function() _templates;
  final CleanContentArchiver? _archiver;

  bool get _genEn => _texts.isEnglish;

  /// 对应 C# `TryExecuteAsync`。返回 null = 不接管。
  Future<AIAgentRoleWorkflowResult?> tryExecute(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    // 闸门 1：任务白名单
    if (!supportedTasks.contains(taskType)) return null;

    final AgentRoleWorkflowSettings s = _settings();
    // 闸门 2：总开关
    if (!s.enableDualAgentWorkflow) return null;

    // 闸门 3：两个 provider 都要按**指名**解析到且可用
    // ⚠ 刻意不用 `ModelManager.resolvePreferredProviderName`：它有"首个可用者兜底"，
    //   会掩盖"用户指名的 provider 没配对"并做出与 C# 不同的接管决策。
    final Map<String, IModelProvider> pool = _providers();
    final IModelProvider? mainProvider = _resolveExact(pool, s.mainAgentProvider);
    final IModelProvider? subProvider = _resolveExact(pool, s.subAgentProvider);
    if (mainProvider == null || subProvider == null) {
      _logger.warning(
        '双代理流程缺少可用提供者：main=${s.mainAgentProvider} / sub=${s.subAgentProvider}'
        '（taskType=$taskType）',
      );
      return AIAgentRoleWorkflowResult.failed(
        _texts.t('DWS.ProviderMissing',
            'MainAgent/SubAgent 未找到可用模型提供者。请在「AI 配置」中启用双代理提供者。'),
        metadata: const <String, String>{'failureKind': 'providerMissing'},
      );
    }

    try {
      // ① SubAgent：需求简报
      final ChatResponse briefResp = await _runStage(
        provider: subProvider,
        model: s.subAgentModel,
        systemPrompt: _buildSubAgentRequirementSystemPrompt(s),
        userPrompt: _buildSubAgentRequirementUserPrompt(taskType, parameters),
        temperature: 0.35,
        maxTokens: 4000,
      );
      if (!briefResp.isSuccess || briefResp.content.trim().isEmpty) {
        return AIAgentRoleWorkflowResult.failed(_texts.tf(
            'DWS.RequirementFailed',
            'SubAgent 需求总结失败：{0}',
            <Object>[_errorOf(briefResp)]));
      }
      final String requirementBrief = briefResp.content;

      // ② MainAgent：正文草稿
      final ChatResponse draftResp = await _runStage(
        provider: mainProvider,
        model: s.mainAgentModel,
        systemPrompt: _buildMainAgentSystemPrompt(taskType, s),
        userPrompt: _buildMainAgentUserPrompt(taskType, requirementBrief),
        temperature: taskType == 'PolishText' ? 0.55 : 0.85,
        maxTokens: 6000,
      );
      if (!draftResp.isSuccess || draftResp.content.trim().isEmpty) {
        return AIAgentRoleWorkflowResult.failed(_texts.tf(
            'DWS.DraftFailed',
            'MainAgent 文案生成失败：{0}',
            <Object>[_errorOf(draftResp)]));
      }
      final String mainDraft = draftResp.content;

      // ③ SubAgent：净化定稿
      final ChatResponse refineResp = await _runStage(
        provider: subProvider,
        model: s.subAgentModel,
        systemPrompt: _buildSubAgentRefineSystemPrompt(taskType, s),
        userPrompt:
            _buildSubAgentRefineUserPrompt(taskType, requirementBrief, mainDraft),
        temperature: 0.25,
        maxTokens: 6000,
      );
      if (!refineResp.isSuccess || refineResp.content.trim().isEmpty) {
        return AIAgentRoleWorkflowResult.failed(_texts.tf(
            'DWS.RefineFailed',
            'SubAgent 定稿整理失败：{0}',
            <Object>[_errorOf(refineResp)]));
      }

      String finalContent =
          AIOutputSanitizer.extractCleanOutput(refineResp.content);
      if (finalContent.trim().isEmpty) {
        return AIAgentRoleWorkflowResult.failed(
            _texts.t('DWS.EmptyResult', 'SubAgent 定稿结果为空。'));
      }

      // 守卫 A：小模型在定稿阶段可能复刻「简报结构」而非正文。
      // 英文模式下会把 "SubAgent requirement brief: … MainAgent draft: …" 整段复刻，
      // 先尝试从回显里截取 draft 之后的正文；截不出再回退草稿。
      final ({bool found, String draft}) extracted =
          tryExtractMainAgentDraft(finalContent);
      if (extracted.found &&
          extracted.draft.length >= 200 &&
          !looksLikeRequirementBrief(extracted.draft)) {
        finalContent = extracted.draft;
        _logger.info('SubAgent 定稿为简报回显，已提取 MainAgent draft 正文（$taskType）');
      } else if (looksLikeRequirementBrief(finalContent) &&
          !looksLikeRequirementBrief(mainDraft)) {
        finalContent = AIOutputSanitizer.extractCleanOutput(mainDraft);
        _logger.info('SubAgent 定稿疑似简报回显，已回退为 MainAgent 草稿（$taskType）');
      }

      // 守卫 B：语言/跑题。英文模式下输出大量中文，或以 Markdown 说明文档开头，
      // 视为模型跑题（实测 13B 会把简报模板解释成「用途说明」文档），回退 MainAgent 草稿。
      final String trimFinal = finalContent.trimLeft();
      final bool offTopic = trimFinal.startsWith('#') ||
          trimFinal.contains('用途说明') ||
          (_genEn && computeCjkRatio(trimFinal) > 0.08);
      if (offTopic && !looksLikeRequirementBrief(mainDraft)) {
        final String sanitizedDraft =
            AIOutputSanitizer.extractCleanOutput(mainDraft);
        if (sanitizedDraft.trim().isNotEmpty) {
          finalContent = sanitizedDraft;
          _logger.info('SubAgent 定稿跑题或语言错误，已回退为 MainAgent 草稿（$taskType）');
        }
      }

      final String mainModel = s.mainAgentModel.isNotEmpty
          ? s.mainAgentModel
          : draftResp.model;
      final String subModel =
          s.subAgentModel.isNotEmpty ? s.subAgentModel : briefResp.model;

      final Map<String, String> metadata = <String, String>{
        'WorkflowMode': 'DualAgent',
        'TaskType': taskType,
        'RequirementBrief': requirementBrief,
        'MainDraft': mainDraft,
        'MainAgentProvider': mainProvider.providerName,
        'SubAgentProvider': subProvider.providerName,
        'MainAgentModel': mainModel,
        'SubAgentModel': subModel,
      };

      // 落档（对应 C# `EnableArchiveWrite`）
      final CleanContentArchiver? archiver = _archiver;
      if (s.enableArchiveWrite && archiver != null) {
        final String code = await archiver(
          projectId: _resolveProjectId(parameters),
          taskType: taskType,
          content: finalContent,
          titleHint: buildTitleHint(taskType, parameters),
          metadata: <String, String>{
            'MainAgentProvider': mainProvider.providerName,
            'SubAgentProvider': subProvider.providerName,
            'MainAgentModel': mainModel,
            'SubAgentModel': subModel,
          },
        );
        metadata['ArchiveWriteCode'] = code;
      }

      return AIAgentRoleWorkflowResult(
        isSuccess: true,
        content: finalContent,
        message: _texts.t(
            'DWS.Success', '已通过 MainAgent/SubAgent 双代理流程生成内容。'),
        metadata: metadata,
      );
    } on Object catch (e, st) {
      _logger.severe('执行双代理写作流程失败: $taskType', e, st);
      return AIAgentRoleWorkflowResult.failed(_texts.tf(
          'DWS.Exception', '双代理流程执行失败：{0}', <Object>['$e']));
    }
  }

  /// 单段调用：`chat()` → 立即 `extractCleanOutput`（对应 C# 每段返回后立刻清洗）。
  ///
  /// 对 RWKV 家族 provider 追加**防复读采样参数**（`kRwkvAntiRepeatSampling`）：
  /// 长文生成最容易踩的坑就是整段/换词复读，而这套参数是官方推荐值 + 社区实测值；
  /// 非 RWKV 家族**不下发**（严格 API 会因未知字段 400）。
  Future<ChatResponse> _runStage({
    required IModelProvider provider,
    required String model,
    required String systemPrompt,
    required String userPrompt,
    required double temperature,
    required int maxTokens,
  }) async {
    final Map<String, dynamic> parameters = isRwkvFamilyProvider(provider.providerName)
        ? Map<String, dynamic>.of(aiRuntimeSettings.longFormSamplingParams())
        : <String, dynamic>{};
    final ChatRequest request = ChatRequest(
      model: model,
      systemPrompt: systemPrompt,
      messages: <ChatMessage>[ChatMessage.user(userPrompt)],
      temperature: temperature,
      maxTokens: maxTokens,
      parameters: parameters,
    );
    final ChatResponse resp = await provider.chat(request);
    if (!resp.isSuccess) return resp;
    return ChatResponse(
      id: resp.id,
      model: resp.model,
      content: AIOutputSanitizer.extractCleanOutput(resp.content),
      finishReason: resp.finishReason,
      usage: resp.usage,
      responseTime: resp.responseTime,
      isSuccess: resp.isSuccess,
      errorMessage: resp.errorMessage,
    );
  }

  static String _errorOf(ChatResponse resp) {
    final String? msg = resp.errorMessage;
    if (msg != null && msg.trim().isNotEmpty) return msg;
    return resp.isSuccess ? '内容为空' : '未知错误';
  }

  /// 对应 C# `ResolveProvider`：名字忽略大小写精确匹配，且必须 `isAvailable`。
  static IModelProvider? _resolveExact(
    Map<String, IModelProvider> pool,
    String configuredProvider,
  ) {
    if (configuredProvider.trim().isEmpty) return null;
    final String target = configuredProvider.trim().toLowerCase();
    for (final MapEntry<String, IModelProvider> e in pool.entries) {
      if (e.key.toLowerCase() == target) {
        return e.value.isAvailable ? e.value : null;
      }
    }
    return null;
  }

  /// 对应 C# `TryResolveProjectId`。
  static String? _resolveProjectId(Map<String, dynamic> parameters) {
    final Object? v = parameters['ProjectId'];
    if (v == null) return null;
    final String s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  /// 对应 C# `BuildTitleHint`（按键优先级取标题）。
  static String? buildTitleHint(
    String taskType,
    Map<String, dynamic> parameters,
  ) {
    final List<String> preferredKeys = switch (taskType) {
      'GenerateChapterContent' => <String>['ChapterTitle', 'Title'],
      'ContinueChapter' => <String>['ChapterTitle', 'Title'],
      'GenerateOutline' => <String>['theme', 'Title'],
      'PolishText' => <String>['Title', 'DocumentTitle'],
      _ => const <String>[],
    };
    for (final String key in preferredKeys) {
      final Object? v = parameters[key];
      final String s = v?.toString() ?? '';
      if (s.trim().isNotEmpty) return s;
    }
    return null;
  }

  // ---------------------------------------------------------------- 提示词构建

  /// 对应 C# `BuildSubAgentRequirementSystemPrompt`。
  String _buildSubAgentRequirementSystemPrompt(AgentRoleWorkflowSettings s) {
    final String? template =
        _templates().get('Workflow/SubAgentRequirement.System', isEnglish: _genEn);
    if (template != null) {
      return template.replaceAll('{RoleDescription}', s.subAgentRoleDescription);
    }
    if (_genEn) {
      return 'You are SubAgent. Duty: ${s.subAgentRoleDescription}'
          'First summarize the writing requirements into a clean, actionable brief for MainAgent to write from.'
          'Internal thinking is allowed, but the final output must not contain thinking, tags, JSON, code blocks, or explanatory prefixes/suffixes.';
    }
    return '你是 SubAgent。职责：${s.subAgentRoleDescription}'
        '你需要先总结写作需求，输出一份纯净、可执行的需求简报，供 MainAgent 直接写作使用。'
        '允许内部 thinking，但最终输出中不得包含思考过程、标签、JSON、代码块、解释性前后缀。';
  }

  /// 对应 C# `BuildMainAgentSystemPrompt`。
  String _buildMainAgentSystemPrompt(
    String taskType,
    AgentRoleWorkflowSettings s,
  ) {
    final String? template =
        _templates().get('Workflow/MainAgent.System', isEnglish: _genEn);
    if (template != null) {
      return template
          .replaceAll('{RoleDescription}', s.mainAgentRoleDescription)
          .replaceAll('{TaskName}', taskDisplayName(taskType, isEnglish: _genEn));
    }
    final String taskName = taskDisplayName(taskType, isEnglish: _genEn);
    if (_genEn) {
      return 'You are MainAgent. Duty: ${s.mainAgentRoleDescription}'
          'The current task is $taskName.'
          "Based solely on SubAgent's requirement brief, produce the content draft."
          'Internal thinking is allowed, but output only the draft content, no explanations.';
    }
    return '你是 MainAgent。职责：${s.mainAgentRoleDescription}'
        '当前任务是 $taskName。'
        '你只需基于 SubAgent 的需求简报完成正文草稿。'
        '允许内部 thinking，但最终只输出草稿正文，不要解释过程。';
  }

  /// 对应 C# `BuildSubAgentRefineSystemPrompt`。
  String _buildSubAgentRefineSystemPrompt(
    String taskType,
    AgentRoleWorkflowSettings s,
  ) {
    final String? template =
        _templates().get('Workflow/SubAgentRefine.System', isEnglish: _genEn);
    if (template != null) {
      return template
          .replaceAll('{RoleDescription}', s.subAgentRoleDescription)
          .replaceAll('{TaskName}', taskDisplayName(taskType, isEnglish: _genEn));
    }
    final String taskName = taskDisplayName(taskType, isEnglish: _genEn);
    if (_genEn) {
      return 'You are SubAgent. Duty: ${s.subAgentRoleDescription}'
          'Finalize the output for task $taskName.'
          "Strip thinking, explanations, prompt residue, tags, redundant headings, and verbal filler from MainAgent's draft; keep only publication-ready content."
          'The final output must be strictly clean.';
    }
    return '你是 SubAgent。职责：${s.subAgentRoleDescription}'
        '当前任务是 $taskName 的定稿整理。'
        '请清理 MainAgent 草稿中的思考、解释、提示词残留、标签、多余标题和口头说明，只保留可直接入库的正式内容。'
        '最终输出必须严格纯净。';
  }

  /// 对应 C# `BuildSubAgentRequirementUserPrompt`（代码内联，不是模板）。
  String _buildSubAgentRequirementUserPrompt(
    String taskType,
    Map<String, dynamic> parameters,
  ) {
    final String taskName = taskDisplayName(taskType, isEnglish: _genEn);
    final List<String> lines = <String>[];
    if (_genEn) {
      lines.add('Task type: $taskName');
      lines.add(
          'Organize the raw requirements below into a short writing brief (max 8 lines, plain text, no section headings):');
      lines.add('- Line 1: the story goal in one sentence;');
      lines.add('- Line 2: style and tone;');
      lines.add(
          '- Up to three more lines: characters and settings that must appear.');
      lines.add(
          'All content must be written in English. Do not output JSON, tags, code blocks, or any explanation.');
      lines.add('');
      lines.add('Raw parameters:');
      lines.add(serializeParameters(parameters));
      return lines.join('\n');
    }
    lines.add('任务类型：$taskName');
    lines.add('请将以下原始需求整理成一份简短的写作简报（不超过8行，纯文本，不要分节标题）：');
    lines.add('- 第一行：一句话故事目标；');
    lines.add('- 第二行：风格与语气；');
    lines.add('- 其后最多三行：必须出现的人物与设定要点。');
    lines.add('不要输出 JSON、标签、代码块或任何解释。');
    lines.add('');
    lines.add('原始参数：');
    lines.add(serializeParameters(parameters));
    return lines.join('\n');
  }

  /// 对应 C# `BuildMainAgentUserPrompt`。
  String _buildMainAgentUserPrompt(String taskType, String requirementBrief) {
    final String taskName = taskDisplayName(taskType, isEnglish: _genEn);
    final String instruction =
        taskFormatInstruction(taskType, isEnglish: _genEn);
    if (_genEn) {
      return 'Task type: $taskName\n'
          "Below is SubAgent's requirement brief. Write a high-quality content draft from it directly. No explanations.\n"
          '$instruction\n\n$requirementBrief';
    }
    return '任务类型：$taskName\n'
        '以下是 SubAgent 输出的需求简报，请据此直接生成高质量文案草稿。不要输出解释。\n'
        '$instruction\n\n$requirementBrief';
  }

  /// 对应 C# `BuildSubAgentRefineUserPrompt`。
  String _buildSubAgentRefineUserPrompt(
    String taskType,
    String requirementBrief,
    String mainDraft,
  ) {
    final String taskName = taskDisplayName(taskType, isEnglish: _genEn);
    final String instruction =
        taskFormatInstruction(taskType, isEnglish: _genEn);
    final List<String> lines = <String>[];
    if (_genEn) {
      lines.add('Task type: $taskName');
      lines.add(
          "Based on the requirement brief and MainAgent's draft, output the final clean version.");
      lines.add(instruction);
      lines.add('');
      lines.add('Requirement brief:');
      lines.add(requirementBrief);
      lines.add('');
      lines.add('MainAgent draft:');
      lines.add(mainDraft);
      return lines.join('\n');
    }
    lines.add('任务类型：$taskName');
    lines.add('请基于需求简报与 MainAgent 草稿，输出最终纯净定稿。');
    lines.add(instruction);
    lines.add('');
    lines.add('需求简报：');
    lines.add(requirementBrief);
    lines.add('');
    lines.add('MainAgent 草稿：');
    lines.add(mainDraft);
    return lines.join('\n');
  }

  // ------------------------------------------------------------ 公开静态工具
  // 以下方法在 C# 里是 private，这里公开以便 `tool/verify_dual_agent.dart` 直接断言。

  /// 对应 C# `SerializeParameters`。
  ///
  /// ⚠ **禁止 `jsonEncode`**：其输出会把中文转义成 `\uXXXX`，
  /// 小参数量本地模型（如 RWKV-1.5B）会照抄转义序列污染产出。
  /// 因此改为纯文本行；`ProjectId` 等系统字段对创作无意义，剔除。
  static String serializeParameters(Map<String, dynamic> parameters) {
    final List<String> keys = parameters.keys.toList()
      ..sort((String a, String b) => a.compareTo(b));
    final StringBuffer sb = StringBuffer();
    for (final String key in keys) {
      if (key.toLowerCase() == 'projectid') continue;
      sb.writeln('$key：${parameters[key]}');
    }
    return sb.toString().trimRight();
  }

  /// 对应 C# `ComputeCjkRatio`（CJK 字符数 / 全部字符数）。
  static double computeCjkRatio(String text) {
    if (text.isEmpty) return 0;
    int cjk = 0;
    for (final int c in text.codeUnits) {
      if (c >= 0x4E00 && c <= 0x9FFF) cjk++;
    }
    return cjk / text.length;
  }

  /// 对应 C# `LooksLikeRequirementBrief`。
  static bool looksLikeRequirementBrief(String content) {
    if (content.trim().isEmpty) return false;

    const List<String> zhMarkers = <String>[
      '核心目标',
      '必须保留的信息',
      '输出格式要求',
      '需求简报',
      '写作简报',
      '禁止项',
    ];
    int hit = 0;
    for (final String m in zhMarkers) {
      if (content.contains(m)) hit++;
      if (hit >= 2) return true;
    }

    // 英文回显必然携带双代理结构标签（实测英文模式踩坑）
    const List<String> enMarkers = <String>[
      'SubAgent requirement brief',
      'Requirement brief:',
      'Requirement Brief:',
      'MainAgent draft',
      'MainAgent Draft',
      "MainAgent's draft",
      'tasktype:chapterwriting',
      'Tasktype:chapterwriting',
      'chapterwriting',
    ];
    final String lower = content.toLowerCase();
    for (final String m in enMarkers) {
      if (lower.contains(m.toLowerCase())) return true;
    }
    return false;
  }

  /// 对应 C# `TryExtractMainAgentDraft`：从简报回显中提取 `MainAgent draft:` 之后的正文。
  ///
  /// 回显可能丢失空格（流式分词缺陷），因此先在**去空格**的形式上找标记，
  /// 再按字符比例反推原文位置，最后在原文窗口内用正则精确定位。
  static ({bool found, String draft}) tryExtractMainAgentDraft(String content) {
    if (content.trim().isEmpty) return (found: false, draft: '');

    final String compact =
        content.replaceAll(' ', '').replaceAll('\n', '').replaceAll('\r', '');
    const List<String> markers = <String>[
      'MainAgentdraft:',
      "MainAgent'sdraft:",
      'MainAgentDraft:',
    ];
    int idx = -1;
    int markerLen = 0;
    final String compactLower = compact.toLowerCase();
    for (final String marker in markers) {
      final int pos = compactLower.indexOf(marker.toLowerCase());
      if (pos >= 0 && (idx < 0 || pos < idx)) {
        idx = pos;
        markerLen = marker.length;
      }
    }
    if (idx < 0) return (found: false, draft: '');

    // 压缩只删除了空格/换行，按比例近似定位是安全的
    final double ratio = idx / (compact.isEmpty ? 1 : compact.length);
    final int rawIdx = (content.length * ratio).toInt();
    final int windowEnd =
        (rawIdx + markerLen + 120) < content.length
            ? (rawIdx + markerLen + 120)
            : content.length;
    if (rawIdx >= windowEnd) return (found: false, draft: '');

    final String slice = content.substring(rawIdx, windowEnd);
    final RegExpMatch? m =
        RegExp(r"MainAgent('s)?\s*[Dd]raft\s*:\s*").firstMatch(slice);
    if (m == null) return (found: false, draft: '');

    final String draft =
        content.substring(rawIdx + m.end).trim();
    return (found: draft.isNotEmpty, draft: draft);
  }

  /// 对应 C# `GetTaskDisplayName`。
  static String taskDisplayName(String taskType, {required bool isEnglish}) {
    if (isEnglish) {
      return switch (taskType) {
        'GenerateChapterContent' => 'chapter writing',
        'ContinueChapter' => 'chapter continuation',
        'PolishText' => 'text polishing',
        'GenerateOutline' => 'book outline generation',
        _ => taskType,
      };
    }
    return switch (taskType) {
      'GenerateChapterContent' => '章节生成',
      'ContinueChapter' => '章节续写',
      'PolishText' => '文本润色',
      'GenerateOutline' => '书籍大纲生成',
      _ => taskType,
    };
  }

  /// 对应 C# `GetTaskFormatInstruction`。
  static String taskFormatInstruction(
    String taskType, {
    required bool isEnglish,
  }) {
    if (isEnglish) {
      return switch (taskType) {
        'GenerateChapterContent' =>
          'Format: output only the chapter prose (narrative story content starting from scene and character action, with dialogue and plot progression, at least 400 words), no explanations, no title prefix, no extra notes; never write it as a manual, technical document, or bullet list. All content must be in English.',
        'ContinueChapter' =>
          'Format: output only the continued prose, no explanations, no labels such as "Continued".',
        'PolishText' =>
          'Format: output only the polished full text, no reviews, no diff notes.',
        'GenerateOutline' =>
          'Format: output only the story outline (core conflict, volume/stage-based plot progression, main character arcs) in narrative form; no explanations, no self-description; never write it as a project plan or technical document. All content must be in English.',
        _ => 'Format: output only clean, publication-ready content.',
      };
    }
    return switch (taskType) {
      'GenerateChapterContent' =>
        '格式要求：只输出书籍章节正文（叙事性故事内容，从场景与人物动作切入，含对话与情节推进，篇幅不少于500字），不要解释，不要标题前缀，不要额外备注；严禁写成说明书、技术文档或要点罗列。',
      'ContinueChapter' => '格式要求：只输出续写后的正文内容，不要解释，不要加“续写内容”等标签。',
      'PolishText' => '格式要求：只输出润色后的完整文本，不要评价，不要差异说明。',
      'GenerateOutline' =>
        '格式要求：只输出书籍故事大纲（核心冲突、分卷或分阶段剧情推进、主要角色走向），使用叙事性描述，不要解释，不要自我说明；严禁写成项目方案或技术文档。',
      _ => '格式要求：只输出纯净正式内容。',
    };
  }
}