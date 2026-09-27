// ignore_for_file: avoid_print
//
// MainAgent / SubAgent 双 Agent 写作流验证。
//
// `dual_agent_workflow.dart` 纯 Dart（只依赖 logging / 自身 ai 子模块）⇒ 能在这里真跑。
//
// 校验项：
//   [1] 三道闸门：白名单外 → null；开关关 → null；provider 缺失 → Failed(providerMissing)
//   [2] 成功路径：三段调用 + metadata 完整 + 定稿内容
//   [3] serializeParameters：剔除 ProjectId（忽略大小写）、全角冒号、key 升序、禁止 \uXXXX 转义
//   [4] 回显守卫：looksLikeRequirementBrief（中 ≥2 / 英 1）/ tryExtractMainAgentDraft（空格外）
//   [5] 守卫回退：定稿为简报回显 → 提取 draft；定稿为纯简报 → 回退草稿
//   [6] CJK 比例 / 任务展示名 / 格式指令（中英）
//
// 运行：dart run tool/verify_dual_agent.dart
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/models/provider.dart';
import 'package:novelcraft/ai/prompts/prompt_template.dart';
import 'package:novelcraft/ai/utils/localized_text.dart';
import 'package:novelcraft/ai/workflow/dual_agent_workflow.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $name — $detail');
  } else {
    fail++;
    print('  ❌ $name — $detail');
  }
}

/// 可编排的假 provider：按 `chat()` 调用顺序吐出预设内容。
class FakeProvider implements IModelProvider {
  FakeProvider({
    required this.providerName,
    this.isAvailable = true,
    List<String>? replies,
  }) : _replies = replies ?? const <String>[];

  @override
  final String providerName;

  @override
  final bool isAvailable;

  final List<String> _replies;
  final List<ChatRequest> calls = <ChatRequest>[];

  @override
  ModelProviderType get providerType => ModelProviderType.local;

  @override
  Stream<ModelConfigurationChangedEventArgs> get configurationChanged =>
      const Stream<ModelConfigurationChangedEventArgs>.empty();

  @override
  Stream<ConnectionStatusChangedEventArgs> get connectionStatusChanged =>
      const Stream<ConnectionStatusChangedEventArgs>.empty();

  @override
  Future<bool> initialize(IModelConfiguration configuration) async => true;

  @override
  Future<ConnectionTestResult> testConnection() async => ConnectionTestResult(
        isSuccess: true,
        serverInfo: const <String, Object?>{},
      );

  @override
  Future<List<ModelInfo>> getAvailableModels() async => const <ModelInfo>[];

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    calls.add(request);
    final int i = calls.length - 1;
    final String content = i < _replies.length ? _replies[i] : '';
    return ChatResponse(
      id: 'r$i',
      model: 'fake-model',
      content: content,
      isSuccess: true,
    );
  }

  @override
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk chunk) onChunkReceived,
  ) async =>
      chat(request);

  @override
  Future<ProviderStatistics> getStatistics() async =>
      const ProviderStatistics();

  @override
  void dispose() {}
}

/// 由假 provider 表 + 配置构造服务。
DualAgentWorkflowService buildService({
  required Map<String, IModelProvider> pool,
  AgentRoleWorkflowSettings? settings,
  bool isEnglish = false,
  List<String>? archived,
}) {
  Logger.root.level = Level.OFF;
  return DualAgentWorkflowService(
    logger: Logger('Verify'),
    settings: () => settings ?? AgentRoleWorkflowSettings.defaults,
    providers: () => pool,
    texts: StaticTextSource(isEnglish: isEnglish),
    templates: () => const PromptTemplateRegistry.empty(),
    archiver: archived == null
        ? null
        : ({
            required String? projectId,
            required String taskType,
            required String content,
            String? titleHint,
            Map<String, String>? metadata,
          }) async {
            archived.add('$taskType|${projectId ?? ''}|${titleHint ?? ''}');
            return 'ok';
          },
  );
}

const String brief = '核心目标：主角逆天改命；风格：东方仙侠。';
final String longDraft = '玄穹山下，云海翻涌。' * 30; // 足够长，不会被 200 字门槛拦掉

Future<void> main() async {
  print('=' * 78);
  print('[1] 三道闸门');
  print('=' * 78);
  final Map<String, IModelProvider> pool = <String, IModelProvider>{
    'RWKV': FakeProvider(providerName: 'RWKV'),
  };
  final DualAgentWorkflowService svc = buildService(pool: pool);
  check('白名单外（SummarizeChapter）→ null（不接管）',
      await svc.tryExecute('SummarizeChapter', <String, dynamic>{}) == null, 'null');
  check('空任务类型 → null',
      await svc.tryExecute('', <String, dynamic>{}) == null, 'null');
  final DualAgentWorkflowService off = buildService(
    pool: pool,
    settings: const AgentRoleWorkflowSettings(enableDualAgentWorkflow: false),
  );
  check('总开关关闭 → null（不接管）',
      await off.tryExecute('GenerateOutline', <String, dynamic>{}) == null, 'null');

  final DualAgentWorkflowService missing = buildService(
    pool: const <String, IModelProvider>{},
  );
  final AIAgentRoleWorkflowResult? missRes =
      await missing.tryExecute('GenerateOutline', <String, dynamic>{});
  check('provider 缺失 → 已接管但失败', missRes != null && !missRes.isSuccess,
      'isSuccess=${missRes?.isSuccess}');
  check('provider 缺失 → failureKind=providerMissing',
      missRes?.failureKind == 'providerMissing', '${missRes?.failureKind}');
  check('provider 不可用（isAvailable=false）也判缺失',
      (await buildService(pool: <String, IModelProvider>{
        'RWKV': FakeProvider(providerName: 'RWKV', isAvailable: false),
      }).tryExecute('GenerateOutline', <String, dynamic>{})) !=
          null,
      'ok');
  check('provider 名大小写不敏感（rwkv → RWKV）',
      (await buildService(pool: <String, IModelProvider>{
        'RWKV': FakeProvider(providerName: 'RWKV', replies: <String>[
          brief,
          longDraft,
          longDraft,
        ]),
      }, settings: const AgentRoleWorkflowSettings(mainAgentProvider: 'rwkv'))
              .tryExecute('GenerateOutline', <String, dynamic>{}))
              ?.isSuccess ==
          true,
      'ok');

  print('');
  print('=' * 78);
  print('[2] 成功路径（三段调用 + metadata）');
  print('=' * 78);
  final FakeProvider mainProv =
      FakeProvider(providerName: 'RWKV', replies: <String>[brief, longDraft, longDraft]);
  final List<String> archived = <String>[];
  final DualAgentWorkflowService ok = buildService(
    pool: <String, IModelProvider>{'RWKV': mainProv},
    archived: archived,
  );
  final AIAgentRoleWorkflowResult? res = await ok.tryExecute(
    'GenerateChapterContent',
    <String, dynamic>{
      'ProjectId': 'proj-1',
      'ChapterTitle': '第一章 云海',
      'Outline': '大纲内容',
    },
  );
  check('接管且成功', res != null && res.isSuccess, 'isSuccess=${res?.isSuccess}');
  check('三段各调用一次', mainProv.calls.length == 3, '${mainProv.calls.length}');
  check('段① temperature=0.35 / maxTokens=4000',
      mainProv.calls[0].temperature == 0.35 && mainProv.calls[0].maxTokens == 4000,
      '${mainProv.calls[0].temperature}/${mainProv.calls[0].maxTokens}');
  check('段② temperature=0.85（非 PolishText）',
      mainProv.calls[1].temperature == 0.85, '${mainProv.calls[1].temperature}');
  check('段③ temperature=0.25 / maxTokens=6000',
      mainProv.calls[2].temperature == 0.25 && mainProv.calls[2].maxTokens == 6000,
      '${mainProv.calls[2].temperature}/${mainProv.calls[2].maxTokens}');
  check('PolishText 时段② temperature=0.55',
      await () async {
        final FakeProvider p = FakeProvider(
            providerName: 'RWKV', replies: <String>[brief, longDraft, longDraft]);
        await buildService(pool: <String, IModelProvider>{'RWKV': p})
            .tryExecute('PolishText', <String, dynamic>{'Title': 't'});
        return p.calls[1].temperature == 0.55;
      }(),
      'ok');
  check('每段都带 systemPrompt',
      mainProv.calls.every((ChatRequest c) =>
          (c.systemPrompt ?? '').isNotEmpty),
      'ok');
  check('metadata: WorkflowMode=DualAgent',
      res?.metadata['WorkflowMode'] == 'DualAgent', '${res?.metadata['WorkflowMode']}');
  check('metadata: 含 RequirementBrief / MainDraft',
      (res?.metadata['RequirementBrief'] ?? '').isNotEmpty &&
          (res?.metadata['MainDraft'] ?? '').isNotEmpty,
      'ok');
  check('metadata: TaskType / Provider 名',
      res?.metadata['TaskType'] == 'GenerateChapterContent' &&
          res?.metadata['MainAgentProvider'] == 'RWKV' &&
          res?.metadata['SubAgentProvider'] == 'RWKV',
      '${res?.metadata['TaskType']}');
  check('metadata: 模型名回落到响应 model',
      res?.metadata['MainAgentModel'] == 'fake-model',
      '${res?.metadata['MainAgentModel']}');
  check('落档被调用且带 titleHint=ChapterTitle',
      archived.length == 1 && archived.first.endsWith('|第一章 云海'),
      archived.join('; '));
  check('metadata: ArchiveWriteCode=ok',
      res?.metadata['ArchiveWriteCode'] == 'ok', '${res?.metadata['ArchiveWriteCode']}');
  check('enableArchiveWrite=false 不落档',
      await () async {
        final List<String> a = <String>[];
        await buildService(
          pool: <String, IModelProvider>{
            'RWKV': FakeProvider(
                providerName: 'RWKV', replies: <String>[brief, longDraft, longDraft]),
          },
          settings: const AgentRoleWorkflowSettings(enableArchiveWrite: false),
          archived: a,
        ).tryExecute('GenerateOutline', <String, dynamic>{});
        return a.isEmpty;
      }(),
      'ok');
  check('段①失败 → 整链路失败且不调段②', await () async {
    final FakeProvider p = FakeProvider(providerName: 'RWKV', replies: <String>['']);
    final AIAgentRoleWorkflowResult? r =
        await buildService(pool: <String, IModelProvider>{'RWKV': p})
            .tryExecute('GenerateOutline', <String, dynamic>{});
    return r != null && !r.isSuccess && p.calls.length == 1;
  }(), 'ok');

  print('');
  print('=' * 78);
  print('[3] serializeParameters');
  print('=' * 78);
  final String serialized = DualAgentWorkflowService.serializeParameters(
    <String, dynamic>{
      'Title': '云海',
      'ProjectId': 'should-be-dropped',
      'theme': '修仙：逆天改命',
      'projectid': 'also-dropped',
      'Alpha': 'a',
    },
  );
  check('剔除 ProjectId（含大小写变体）',
      !serialized.contains('should-be-dropped') &&
          !serialized.contains('also-dropped'),
      serialized.replaceAll('\n', ' / '));
  check('key 升序排列',
      serialized.startsWith('Alpha：a\nTitle：云海\ntheme：修仙：逆天改命'),
      serialized.replaceAll('\n', ' / '));
  check('使用全角冒号', serialized.contains('：') && !serialized.contains('Title: '),
      'ok');
  check('中文未被转义为 \\uXXXX', !serialized.contains('\\u'), 'ok');
  check('无尾随换行', !serialized.endsWith('\n'), 'ok');
  check('空参数 → 空串',
      DualAgentWorkflowService.serializeParameters(<String, dynamic>{}).isEmpty,
      'ok');

  print('');
  print('=' * 78);
  print('[4] 回显守卫（简报识别 / draft 提取）');
  print('=' * 78);
  check('中文简报：命中 2 个特征词 → true',
      DualAgentWorkflowService.looksLikeRequirementBrief('核心目标：x\n必须保留的信息：y'),
      'ok');
  check('中文简报：只命中 1 个 → false',
      !DualAgentWorkflowService.looksLikeRequirementBrief('核心目标：x\n普通正文'),
      'ok');
  check('英文简报：任意 1 个特征词 → true',
      DualAgentWorkflowService.looksLikeRequirementBrief('MainAgent Draft: hello'),
      'ok');
  check('英文简报：大小写不敏感',
      DualAgentWorkflowService.looksLikeRequirementBrief('TASKTYPE:CHAPTERWRITING'),
      'ok');
  check('空串 → false',
      !DualAgentWorkflowService.looksLikeRequirementBrief('   '), 'ok');
  check('普通正文 → false',
      !DualAgentWorkflowService.looksLikeRequirementBrief(longDraft), 'ok');

  // 回显样本：故意在标记处插入空格 + 换行，模拟流式分词丢空格
  final String echo =
      'SubAgent requirement brief:\n$brief\n\nMainAgent draft:\n$longDraft';
  final ({bool found, String draft}) ex =
      DualAgentWorkflowService.tryExtractMainAgentDraft(echo);
  check('能从回显中提取 draft', ex.found && ex.draft.isNotEmpty, 'len=${ex.draft.length}');
  check('提取结果 = 正文（不含标记与前缀）',
      ex.draft == longDraft.trim(), '${ex.draft.length}/${longDraft.trim().length}');
  check('提取长度 ≥200（守卫门槛）', ex.draft.length >= 200, '${ex.draft.length}');
  check('空格丢失形态（MainAgentdraft:）也能定位',
      DualAgentWorkflowService
          .tryExtractMainAgentDraft(
              'requirement brief\nMainAgentdraft:${longDraft.replaceAll(' ', '')}')
          .found,
      'ok');
  check("MainAgent's draft 变体",
      DualAgentWorkflowService
          .tryExtractMainAgentDraft("x\nMainAgent's draft:\n$longDraft")
          .found,
      'ok');
  check('无标记 → not found',
      !DualAgentWorkflowService.tryExtractMainAgentDraft(longDraft).found, 'ok');

  print('');
  print('=' * 78);
  print('[5] 守卫回退（定稿为简报回显 / 纯简报 / 跑题）');
  print('=' * 78);
  // 定稿 = 简报回显（含 draft）→ 应替换为 draft
  final AIAgentRoleWorkflowResult? g1 = await buildService(
    pool: <String, IModelProvider>{
      'RWKV': FakeProvider(providerName: 'RWKV', replies: <String>[brief, longDraft, echo]),
    },
  ).tryExecute('GenerateOutline', <String, dynamic>{});
  check('定稿为简报回显 → 结果被替换为 draft',
      g1?.content == longDraft.trim(), 'len=${g1?.content.length}');

  // 定稿 = 纯简报（无 draft 标记）+ 草稿是正文 → 回退草稿
  final AIAgentRoleWorkflowResult? g2 = await buildService(
    pool: <String, IModelProvider>{
      'RWKV': FakeProvider(providerName: 'RWKV', replies: <String>[
        brief,
        longDraft,
        '核心目标：a\n必须保留的信息：b\n输出格式要求：c',
      ]),
    },
  ).tryExecute('GenerateOutline', <String, dynamic>{});
  check('定稿为纯简报 → 回退 MainAgent 草稿',
      g2?.content == longDraft.trim(), 'len=${g2?.content.length}');

  // 定稿以 Markdown 说明文档开头 → 跑题守卫回退草稿
  final AIAgentRoleWorkflowResult? g3 = await buildService(
    pool: <String, IModelProvider>{
      'RWKV': FakeProvider(providerName: 'RWKV', replies: <String>[
        brief,
        longDraft,
        '# 用途说明\n这是解释文档',
      ]),
    },
  ).tryExecute('GenerateOutline', <String, dynamic>{});
  check('定稿以 # 开头 → 回退草稿', g3?.content == longDraft.trim(),
      'len=${g3?.content.length}');

  // 英文模式 + 定稿大量中文 → 语言守卫回退草稿
  final AIAgentRoleWorkflowResult? g4 = await buildService(
    pool: <String, IModelProvider>{
      'RWKV': FakeProvider(providerName: 'RWKV', replies: <String>[
        brief,
        longDraft,
        '这是模型跑题输出的中文内容，应当被语言守卫拦下并回退到英文草稿。',
      ]),
    },
    isEnglish: true,
  ).tryExecute('GenerateOutline', <String, dynamic>{});
  check('英文模式定稿大量中文 → 回退草稿', g4?.content == longDraft.trim(),
      'len=${g4?.content.length}');

  // 草稿本身也是简报时不允许回退（否则会拿简报当正文）
  final AIAgentRoleWorkflowResult? g5 = await buildService(
    pool: <String, IModelProvider>{
      'RWKV': FakeProvider(providerName: 'RWKV', replies: <String>[
        brief,
        '核心目标：a\n必须保留的信息：b\n输出格式要求：c',
        '核心目标：x\n必须保留的信息：y',
      ]),
    },
  ).tryExecute('GenerateOutline', <String, dynamic>{});
  check('草稿也是简报 → 不回退（保留定稿）',
      g5?.content.contains('核心目标：x') == true, '${g5?.content}');

  print('');
  print('=' * 78);
  print('[6] CJK 比例 / 任务名 / 格式指令');
  print('=' * 78);
  check('computeCjkRatio 全中文 = 1.0',
      DualAgentWorkflowService.computeCjkRatio('中文') == 1.0, '1.0');
  check('computeCjkRatio 全英文 = 0.0',
      DualAgentWorkflowService.computeCjkRatio('abcd') == 0.0, '0.0');
  check('computeCjkRatio 空串 = 0',
      DualAgentWorkflowService.computeCjkRatio('') == 0, '0');
  final double mixed = DualAgentWorkflowService.computeCjkRatio('中文ab');
  check('computeCjkRatio 混合 = 2/4', (mixed - 0.5).abs() < 1e-9, '$mixed');
  check('任务名：中文',
      DualAgentWorkflowService.taskDisplayName('GenerateChapterContent',
              isEnglish: false) ==
          '章节生成',
      'ok');
  check('任务名：英文',
      DualAgentWorkflowService.taskDisplayName('GenerateChapterContent',
              isEnglish: true) ==
          'chapter writing',
      'ok');
  check('任务名：未登记类型原样返回',
      DualAgentWorkflowService.taskDisplayName('Xyz', isEnglish: false) == 'Xyz',
      'ok');
  check('格式指令：中文要求不少于500字',
      DualAgentWorkflowService.taskFormatInstruction('GenerateChapterContent',
              isEnglish: false)
          .contains('不少于500字'),
      'ok');
  check('格式指令：英文要求 at least 400 words',
      DualAgentWorkflowService.taskFormatInstruction('GenerateChapterContent',
              isEnglish: true)
          .contains('at least 400 words'),
      'ok');
  check('格式指令：禁止写成说明书（中文）',
      DualAgentWorkflowService.taskFormatInstruction('GenerateChapterContent',
              isEnglish: false)
          .contains('严禁写成说明书'),
      'ok');
  check('titleHint：GenerateOutline 取 theme',
      DualAgentWorkflowService.buildTitleHint('GenerateOutline',
              <String, dynamic>{'theme': '主题A', 'Title': 'T'}) ==
          '主题A',
      'ok');
  check('titleHint：PolishText 取 Title',
      DualAgentWorkflowService.buildTitleHint('PolishText',
              <String, dynamic>{'Title': 'T', 'DocumentTitle': 'D'}) ==
          'T',
      'ok');
  check('titleHint：无候选键 → null',
      DualAgentWorkflowService.buildTitleHint('PolishText', <String, dynamic>{}) ==
          null,
      'null');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}