// 「边聊边写」章节关联改稿的**落库闭环**回归测试。
//
// 背景（用户报的 BUG）：边聊界面里的 Agent 只能"聊"，产出不会落到项目文件 ——
// 续写和修改都对章节无效。这个测试锁定的就是修复后的契约：
//   意见进 → Agent 处理 → `Chapter.Content` 真的被改写 → 字数/版本/编辑时间同步。
//
// 放 `integration_test/` 的原因同 seeder_test：需要真实 sqlite3（drift）。
//
// 运行：`flutter test -d windows integration_test/chapter_revision_test.dart`
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'package:novelcraft/ai/agents/agent.dart';
import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/models/provider.dart';
import 'package:novelcraft/ai/prompts/prompt_template.dart';
import 'package:novelcraft/ai/utils/localized_text.dart';
import 'package:novelcraft/ai/utils/segment_rewrite.dart';
import 'package:novelcraft/ai/workflow/dual_agent_workflow.dart';
import 'package:novelcraft/application/services/ai_writing_service.dart';
import 'package:novelcraft/application/services/chapter_revision_service.dart';
import 'package:novelcraft/application/services/project_context_assembler.dart';
import 'package:novelcraft/core/di.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/character_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/world_setting_repository.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';
import 'package:novelcraft/ui/pages/ai_collaboration_page.dart';
import 'package:novelcraft/ui/state/copilot_chat_log.dart';

/// Dart 的 String 没有 `*` 运算符，长文夹具用这个拼重复文本。
String repeat(String unit, int times) =>
    List<String>.filled(times, unit).join();

/// 内存 KVStore（同 `seeder_test.dart` 的实现）。
///
/// ⚠ 组件测试**必须**覆盖 `keyValueStoreProvider`：真实实现会读写 App 数据目录，
/// 既污染真机数据，也会让用例之间互相串（上次跑残留的关联被读进来）。
class _MemoryKv implements KeyValueStore {
  final Map<String, Map<String, String>> _data = <String, Map<String, String>>{};

  @override
  Future<void> init() async {}

  @override
  Future<String?> readJson(String scope, String key) async =>
      _data[scope]?[key];

  @override
  Future<void> writeJson(String scope, String key, String json) async {
    _data.putIfAbsent(scope, () => <String, String>{})[key] = json;
  }

  @override
  Future<void> remove(String scope, String key) async {
    _data[scope]?.remove(key);
  }

  @override
  Future<List<String>> listKeys(String scope) async =>
      _data[scope]?.keys.toList() ?? const <String>[];
}

/// 真装配（打桩范围之外的那部分）用同一个装配器，保证与 DI 里的用法一致。
ProjectContextAssembler _assembler(AppDatabase db) => ProjectContextAssembler(
      projects: ProjectRepository(db),
      plots: PlotRepository(db),
      characters: CharacterRepository(db),
      worldSettings: WorldSettingRepository(db),
    );

/// 打桩的写作门面：只验证「服务怎么调它、拿到结果怎么落库」，
/// 不碰任何真实模型（真机推理另有验证，见 HANDOFF §9）。
class _StubWritingService extends AiWritingService {
  _StubWritingService(AppDatabase db)
      : super(
          dualAgent: DualAgentWorkflowService(
            logger: Logger('StubDualAgent'),
            settings: () => AgentRoleWorkflowSettings.defaults,
            providers: () => const <String, IModelProvider>{},
            texts: const StaticTextSource(),
            templates: () => const PromptTemplateRegistry.empty(),
          ),
          contextAssembler: _assembler(db),
          texts: const StaticTextSource(),
          agents: () => const <BaseAgent>[],
        );

  /// 下一次调用的返回内容。
  String reply = '默认改写正文';

  /// 下一次调用是否成功。
  bool success = true;

  /// 模拟「模型调用失败 → BaseAgent 静默回退到内置示例文本」。
  bool fallback = false;

  /// 最近一次任务类型 / 入参。
  String lastTask = '';
  Map<String, dynamic> lastParams = <String, dynamic>{};

  /// 全部调用记录（用于断言"根本没调用模型"）。
  final List<String> calls = <String>[];

  Map<String, dynamic> get lastSnapshot =>
      Map<String, dynamic>.of(lastParams);

  AIAssistantResult _reply(String task, Map<String, dynamic> parameters) {
    lastTask = task;
    lastParams = Map<String, dynamic>.of(parameters);
    calls.add(task);
    return AIAssistantResult(
      isSuccess: success,
      data: success ? reply : '',
      message: success ? 'ok' : '模型不可用',
      metadata: <String, String>{
        'WorkflowMode': 'SingleAgent',
        if (fallback) 'Fallback': 'true',
      },
    );
  }

  @override
  Future<AIAssistantResult> polishText(Map<String, dynamic> parameters) async =>
      _reply('PolishText', parameters);

  @override
  Future<AIAssistantResult> continueChapter(
          Map<String, dynamic> parameters) async =>
      _reply('ContinueChapter', parameters);

  @override
  Future<AIAssistantResult> generateChapterContent(
          Map<String, dynamic> parameters) async =>
      _reply('GenerateChapterContent', parameters);
}

/// 记录请求并按序返回预设结果的假 provider（分段路径的单段通道）。
///
/// 用真实的 [IModelProvider] 契约而不是绕过接口，才能顺带验证
/// 「防复读采样参数是否只发给 RWKV 家族」「maxTokens 是否为分段预算」。
class _FakeSliceProvider implements IModelProvider {
  _FakeSliceProvider(this._replies, {this.providerName = 'FakeCloud'});

  /// 按调用顺序取用；用尽后一直重复最后一项。
  final List<({bool ok, String text})> _replies;

  @override
  final String providerName;

  final List<ChatRequest> requests = <ChatRequest>[];
  int _index = 0;

  @override
  ModelProviderType get providerType => ModelProviderType.cloudApi;

  @override
  bool get isAvailable => true;

  @override
  Stream<ModelConfigurationChangedEventArgs> get configurationChanged =>
      const Stream<ModelConfigurationChangedEventArgs>.empty();

  @override
  Stream<ConnectionStatusChangedEventArgs> get connectionStatusChanged =>
      const Stream<ConnectionStatusChangedEventArgs>.empty();

  @override
  Future<bool> initialize(IModelConfiguration configuration) async => true;

  @override
  Future<ConnectionTestResult> testConnection() async =>
      ConnectionTestResult(isSuccess: true);

  @override
  Future<List<ModelInfo>> getAvailableModels() async => <ModelInfo>[];

  @override
  Future<ProviderStatistics> getStatistics() async =>
      const ProviderStatistics();

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    requests.add(request);
    final ({bool ok, String text}) r =
        _replies[_index < _replies.length ? _index : _replies.length - 1];
    _index++;
    return ChatResponse(
      content: r.ok ? r.text : '',
      model: 'fake-model',
      isSuccess: r.ok,
      errorMessage: r.ok ? null : 'fake failure',
    );
  }

  @override
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk) onChunkReceived,
  ) =>
      chat(request);

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const Uuid uuid = Uuid();
  late AppDatabase db;
  late ChapterRepository chapters;
  late _StubWritingService writing;
  late String projectId;
  late String volumeId;

  ChapterRevisionService build({bool hasWriter = true, IModelProvider? provider}) =>
      ChapterRevisionService(
        writing: writing,
        chapters: chapters,
        contextAssembler: _assembler(db),
        texts: const StaticTextSource(),
        hasWriter: () => hasWriter,
        sliceProvider: () => provider,
        // 测试里不回落本地 RWKV：分段用例必须显式提供 provider，
        // 否则就该走"单段失败"分支（`_generateSliceOnce` 会捕获这里抛出的异常）。
        rwkv: () => throw UnsupportedError('test: 不回落本地 RWKV'),
      );

  Future<ChapterRow> makeChapter({String? content, String? summary}) {
    return chapters.create(ChaptersCompanion.insert(
      id: uuid.v4(),
      title: '第一章 试炼',
      volumeId: volumeId,
      projectId: Value(projectId),
      content: Value(content),
      summary: Value(summary),
      wordCount: Value(content?.length ?? 0),
    ));
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chapters = ChapterRepository(db);
    writing = _StubWritingService(db);
    projectId = uuid.v4();
    volumeId = uuid.v4();
    await db.into(db.projects).insert(ProjectsCompanion.insert(
          id: projectId,
          name: '测试书',
          type: 'novel',
        ));
    await db.into(db.volumes).insert(VolumesCompanion.insert(
          id: volumeId,
          title: '第一卷',
          projectId: projectId,
        ));
  });

  tearDown(() async => db.close());

  group('章节关联改稿：Agent 产出必须真正写回 Chapter.Content', () {
    test('按意见改写：覆盖正文 + 同步字数/版本/编辑时间，且不改状态', () async {
      final ChapterRow before = await makeChapter(content: '原本的正文内容');
      writing.reply = '改写后的第一章正文，冲突更尖锐。';

      final ChapterRevisionResult r = await build().revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '重写开头，加强冲突',
      );

      expect(r.isSuccess, isTrue);
      expect(r.persisted, isTrue, reason: '必须真的落库，不能只回消息');
      expect(r.workflowMode, 'SingleAgent');
      expect(r.originalLength, '原本的正文内容'.length);
      expect(r.revisedLength, writing.reply.length);

      // 关键：Agent 拿到的是「原文 + 作者意见」，不是空上下文
      expect(writing.lastTask, 'PolishText');
      expect(writing.lastSnapshot['Content'], '原本的正文内容');
      expect(writing.lastSnapshot['Instruction'], '重写开头，加强冲突');
      expect(writing.lastSnapshot['ChapterTitle'], '第一章 试炼');
      // 项目上下文由本服务自注入（不含「不得输出正文」这类子系统约束）
      expect(writing.lastSnapshot['PromptSummary'], contains('测试书'));

      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, writing.reply);
      expect(after.wordCount, writing.reply.length);
      expect(after.versionNumber, before.versionNumber + 1);
      expect(after.lastEditedAt, isNotNull);
      expect(after.status, before.status, reason: '改稿不应把「已完成」打回草稿');
      expect(r.message.contains('已按你的要求更新'), isTrue);
    });

    test('按意见续写：产出追加在原文之后（空行分隔）', () async {
      final ChapterRow before = await makeChapter(content: '开头段落。');
      writing.reply = '他一剑劈开了云海。';

      final ChapterRevisionResult r = await build().continueWriting(
        projectId: projectId,
        chapterId: before.id,
        instruction: '接着写一场打斗',
      );

      expect(writing.lastTask, 'ContinueChapter');
      expect(writing.lastSnapshot['Instruction'], '接着写一场打斗');
      expect(r.persisted, isTrue);

      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, '开头段落。\n\n他一剑劈开了云海。');
      expect(after.wordCount, after.content!.length);
      expect(after.content!.startsWith('开头段落。'), isTrue,
          reason: '续写不得丢掉原文');
    });

    test('无正文章节：按梗概 + 作者意见成文（GenerateChapterContent）', () async {
      final ChapterRow before =
          await makeChapter(content: '', summary: '主角初入宗门');
      writing.reply = '山门高耸入云。';

      final ChapterRevisionResult r = await build().revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '要有打斗',
      );

      expect(writing.lastTask, 'GenerateChapterContent');
      expect(writing.lastSnapshot['Outline'], '主角初入宗门\n要有打斗');
      expect(r.persisted, isTrue);

      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, '山门高耸入云。');
      expect(after.wordCount, '山门高耸入云。'.length);
    });

    test('无可用写作模型：明确失败、不调模型、不污染章节', () async {
      final ChapterRow before = await makeChapter(content: '原文');

      final ChapterRevisionResult r = await build(hasWriter: false).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '随便改改',
      );

      expect(r.isSuccess, isFalse);
      expect(r.persisted, isFalse);
      expect(r.message.contains('未找到可用的写作模型'), isTrue);
      expect(writing.calls, isEmpty, reason: '闸门必须在调用模型之前');
      expect((await chapters.getById(before.id))!.content, '原文');
    });

    test('模型返回空内容：失败且不改库', () async {
      final ChapterRow before = await makeChapter(content: '原文');
      writing.success = false;
      writing.reply = '';

      final ChapterRevisionResult r = await build().revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '改',
      );

      expect(r.isSuccess, isFalse);
      expect(r.persisted, isFalse);
      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, '原文');
      expect(after.versionNumber, before.versionNumber);
    });

    test('占位文本闸门：模型调用失败触发 Fallback 时拒绝落库', () async {
      final ChapterRow before = await makeChapter(content: '作者的正文');
      writing.fallback = true;
      writing.reply = '【本地回退章节示例】叶知秋背负玄铁古剑……';

      final ChapterRevisionResult r = await build().revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '润色',
      );

      expect(r.isSuccess, isFalse);
      expect(r.persisted, isFalse);
      expect(r.message.contains('没有真正返回内容'), isTrue);
      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, '作者的正文', reason: '内置示例文本绝不能覆盖作者正文');
      expect(after.versionNumber, before.versionNumber);
    });

    test('章节问答：带章节上下文作答且完全不改库', () async {
      final ChapterRow before = await makeChapter(content: '主角抬头，望向山门。');
      final _FakeSliceProvider provider =
          _FakeSliceProvider(<({bool ok, String text})>[
        (ok: true, text: '1. 节奏偏慢\n2. 冲突可以更早出现'),
      ]);

      final ChapterRevisionResult r = await build(provider: provider)
          .askAboutChapter(
        projectId: projectId,
        chapterId: before.id,
        question: '这章的节奏有什么问题？',
      );

      expect(r.isSuccess, isTrue);
      expect(r.persisted, isFalse, reason: '问答不落库');
      expect(r.workflowMode, 'ChapterQa');
      expect(r.message, isEmpty, reason: '没改正文就不该有"已更新"汇报');
      // 列表型答复不能被当成"结构行"删掉（问答路径不清结构行）
      expect(r.content.startsWith('1.'), isTrue);

      final String prompt = provider.requests.single.messages.last.content;
      expect(prompt.contains('主角抬头，望向山门。'), isTrue);
      expect(prompt.contains('这章的节奏有什么问题？'), isTrue);
      expect(prompt.contains('不要改写'), isTrue);

      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, '主角抬头，望向山门。');
      expect(after.versionNumber, before.versionNumber);
      expect(writing.calls, isEmpty, reason: '问答不该走双 Agent 改稿链路');
    });

    test('章节不存在：返回失败信息且不抛异常', () async {
      final ChapterRevisionResult r = await build().revise(
        projectId: projectId,
        chapterId: 'not-exist',
        instruction: '改',
      );

      expect(r.isSuccess, isFalse);
      expect(r.message.contains('目标章节不存在'), isTrue);
      expect(writing.calls, isEmpty);
    });
  });

  group('长文分段改写（C# 分段滚动工艺）', () {
    const int seg = SegmentRewrite.segmentChars; // 1800

    test('长文自动分段：逐段携带上一段结尾，拼接后整体落库', () async {
      final String original = '${repeat('一', seg)}${repeat('二', seg)}'
          '${repeat('三', 400)}'; // 4000 字 → 3 段
      final ChapterRow before = await makeChapter(content: original);

      final _FakeSliceProvider provider = _FakeSliceProvider(
        <({bool ok, String text})>[
          (ok: true, text: '改写一'),
          (ok: true, text: '改写二'),
          (ok: true, text: '改写三'),
        ],
        // RWKV 家族才该拿到防复读采样参数 —— 顺带验证这条分支
        providerName: 'RWKV Cloud',
      );

      final List<String> progress = <String>[];
      final ChapterRevisionResult r = await build(provider: provider).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '把节奏加快',
        onProgress: (int done, int total) => progress.add('$done/$total'),
      );

      expect(r.isSuccess, isTrue);
      expect(r.persisted, isTrue);
      expect(r.segments, 3);
      expect(r.isSegmented, isTrue);
      expect(r.workflowMode, 'Segmented');
      expect(provider.requests.length, 3, reason: '每段一次请求，无多余重试');

      final String p1 = provider.requests[0].messages.last.content;
      final String p2 = provider.requests[1].messages.last.content;
      final String p3 = provider.requests[2].messages.last.content;
      expect(p1.contains('【原文片段 1/3】'), isTrue);
      expect(p1.contains('（本段为开头）'), isTrue);
      expect(p2.contains('【原文片段 2/3】'), isTrue);
      expect(p2.contains('改写一'), isTrue, reason: '第二段必须带上第一段的结尾');
      expect(p2.contains('衔接连贯'), isTrue);
      expect(p3.contains('【原文片段 3/3】'), isTrue);
      expect(p1.contains('【处理要求】把节奏加快'), isTrue);
      expect(p1.contains('《测试书》'), isTrue, reason: '提示词带书名定位');
      expect(p1.contains('第一章 试炼'), isTrue);

      // 单段预算与防复读采样参数
      expect(provider.requests[0].maxTokens, SegmentRewrite.sliceTokens);
      expect(provider.requests[0].parameters['top_k'], 50);
      expect(provider.requests[0].parameters['alpha_presence'], 2.0);

      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, '改写一\n改写二\n改写三');
      expect(after.wordCount, '改写一\n改写二\n改写三'.length);
      expect(after.versionNumber, before.versionNumber + 1);
      expect(r.message.contains('分段改写'), isTrue);
      expect(r.message.contains('3 段'), isTrue);
      expect(progress, <String>['0/3', '1/3', '2/3', '3/3']);
    });

    test('非 RWKV 家族不下发防复读采样参数', () async {
      final ChapterRow before = await makeChapter(
          content: '${repeat('甲', seg)}${repeat('乙', 200)}');
      final _FakeSliceProvider provider = _FakeSliceProvider(
        <({bool ok, String text})>[
          (ok: true, text: '新版一'),
          (ok: true, text: '新版二'),
        ],
      );

      await build(provider: provider).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '精简',
      );

      expect(provider.requests.first.parameters, isEmpty,
          reason: 'DeepSeek/Zhipu 等严格 API 收到未知字段会 400');
    });

    test('段落复读 → 换更强提示词重试，不把原文抄回去', () async {
      final String s1 = repeat('甲', seg);
      final ChapterRow before =
          await makeChapter(content: '$s1${repeat('乙', 200)}');
      final _FakeSliceProvider provider = _FakeSliceProvider(
        <({bool ok, String text})>[
          (ok: true, text: s1), // 第 1 次：原样抄回 → 触发复读检测
          (ok: true, text: '真正改写后的第一段'),
          (ok: true, text: '改写后的第二段'),
        ],
      );

      final ChapterRevisionResult r = await build(provider: provider).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '重写',
      );

      expect(provider.requests.length, 3);
      expect(provider.requests[1].messages.last.content.contains('与原文几乎相同'),
          isTrue,
          reason: '第二枪必须是"更强提示词"');
      expect(r.persisted, isTrue);
      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, '真正改写后的第一段\n改写后的第二段');
      expect(after.content, isNot(contains(s1)), reason: '原文不得原样写回');
    });

    test('中途某段失败：整体不落库（不留半个章节）', () async {
      final String original = '${repeat('甲', seg)}${repeat('乙', 200)}';
      final ChapterRow before = await makeChapter(content: original);
      final _FakeSliceProvider provider = _FakeSliceProvider(
        <({bool ok, String text})>[
          (ok: true, text: '第一段改写'),
          (ok: false, text: ''), // 第 2 段两次尝试都失败
        ],
      );

      final ChapterRevisionResult r = await build(provider: provider).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '重写',
      );

      expect(r.isSuccess, isFalse);
      expect(r.persisted, isFalse);
      expect(r.content, isEmpty);
      expect(r.message.contains('第 2/2 段失败'), isTrue);
      expect(r.message.contains('正文未改动'), isTrue);
      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, original, reason: '失败路径一个字节都不该写');
      expect(after.versionNumber, before.versionNumber);
    });

    test('短文不分段：仍走双 Agent 一次成稿', () async {
      final ChapterRow before = await makeChapter(content: '短文正文');
      writing.reply = '双 Agent 改写结果';
      final _FakeSliceProvider provider =
          _FakeSliceProvider(<({bool ok, String text})>[
        (ok: true, text: '不该被调用'),
      ]);

      final ChapterRevisionResult r = await build(provider: provider).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '润色',
      );

      expect(r.segments, 1);
      expect(r.isSegmented, isFalse);
      expect(writing.lastTask, 'PolishText');
      expect(provider.requests, isEmpty, reason: '短文不该走分段通道');
      expect(r.message.contains('分段改写'), isFalse);
    });

    test('超长章（段数超上限）：做任何模型调用前就拒绝，正文一字未动', () async {
      // 上限 = 12 段 × 1800 字；多一个字就是第 13 段
      final String huge =
          '文' * (SegmentRewrite.segmentChars * SegmentRewrite.maxSegments + 1);
      final ChapterRow before = await makeChapter(content: huge);
      final _FakeSliceProvider provider =
          _FakeSliceProvider(<({bool ok, String text})>[
        (ok: true, text: '不该被调用'),
      ]);

      final ChapterRevisionResult r = await build(provider: provider).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '压缩节奏',
      );

      expect(r.isSuccess, isFalse);
      expect(r.persisted, isFalse);
      expect(provider.requests, isEmpty, reason: '闸门必须在任何模型调用之前拦下');
      expect(writing.calls, isEmpty, reason: '双 Agent 通道也不该被触发');
      // 提示要能指导作者人工介入：字数、所需段数、上限
      expect(r.message.contains('${huge.length} 字'), isTrue, reason: r.message);
      expect(r.message.contains('超过上限 ${SegmentRewrite.maxSegments} 段'), isTrue,
          reason: r.message);
      final ChapterRow? after = await chapters.getById(before.id);
      expect(after!.content, huge, reason: '正文一字未动');
      expect(after.versionNumber, before.versionNumber);
    });

    test('恰好到上限（12 段）：放行，走分段工艺', () async {
      final String atLimit =
          '文' * (SegmentRewrite.segmentChars * SegmentRewrite.maxSegments);
      final ChapterRow before = await makeChapter(content: atLimit);
      final _FakeSliceProvider provider =
          _FakeSliceProvider(<({bool ok, String text})>[
        (ok: true, text: '第 1 段产出'),
      ]);

      final ChapterRevisionResult r = await build(provider: provider).revise(
        projectId: projectId,
        chapterId: before.id,
        instruction: '压缩节奏',
      );

      expect(r.segments, SegmentRewrite.maxSegments);
      expect(r.isSegmented, isTrue);
      expect(r.persisted, isTrue);
      expect(provider.requests, isNotEmpty);
    });
  });

  group('聊天记录落 KVStore（限长）', () {
    ProviderContainer logContainer(_MemoryKv kv) => ProviderContainer(
          overrides: [keyValueStoreProvider.overrideWith((_) async => kv)],
        );

    test('条数上限：只保留最新 60 条', () async {
      final ProviderContainer c = logContainer(_MemoryKv());
      addTearDown(c.dispose);
      // 等首次 _restore（补开场白）落地，避免与后面的写入抢时序
      await pumpEventQueue();
      final CopilotChatLogController log = c.read(copilotChatLogProvider.notifier);

      for (int i = 0; i < 80; i++) {
        await log.append(ChatMessage.user('第 $i 条'));
      }

      final List<ChatMessage> kept = c.read(copilotChatLogProvider).messages;
      expect(kept.length, CopilotChatLogController.maxEntries);
      expect(kept.first.content, '第 20 条', reason: '丢最旧的，留最新的');
      expect(kept.last.content, '第 79 条');
    });

    test('字数上限：2000 字 × 70 条 → 只留 30 条（6 万上限）', () async {
      final ProviderContainer c = logContainer(_MemoryKv());
      addTearDown(c.dispose);
      await pumpEventQueue();
      final CopilotChatLogController log = c.read(copilotChatLogProvider.notifier);

      for (int i = 0; i < 70; i++) {
        await log.append(ChatMessage.user(repeat('甲', 2000)));
      }

      expect(c.read(copilotChatLogProvider).messages.length, 30);
    });

    test('单条超上限也至少保留最新一条（不在内容中间截断）', () async {
      final ProviderContainer c = logContainer(_MemoryKv());
      addTearDown(c.dispose);
      await pumpEventQueue();
      final CopilotChatLogController log = c.read(copilotChatLogProvider.notifier);

      final String huge = repeat('乙', CopilotChatLogController.maxTotalChars + 5000);
      await log.append(ChatMessage.user(huge));

      final List<ChatMessage> kept = c.read(copilotChatLogProvider).messages;
      expect(kept.length, 1);
      expect(kept.single.content, huge, reason: '不允许截断成半句话');
    });

    test('落盘后能在新容器里完整恢复（含角色与时间戳）', () async {
      final _MemoryKv kv = _MemoryKv();
      final ProviderContainer c1 = logContainer(kv);
      c1.read(copilotChatLogProvider); // 实例化 → 触发 _restore
      await pumpEventQueue(); // 等恢复（补开场白）落地
      final CopilotChatLogController log = c1.read(copilotChatLogProvider.notifier);
      await log.append(ChatMessage.user('改一下开头'));
      await log.append(ChatMessage.assistant('已改写'));
      c1.dispose();

      final ProviderContainer c2 = logContainer(kv);
      addTearDown(c2.dispose);
      c2.read(copilotChatLogProvider); // 实例化 → 触发 _restore
      await pumpEventQueue();
      final List<ChatMessage> restored = c2.read(copilotChatLogProvider).messages;
      expect(restored.map((ChatMessage m) => m.role).toList(),
          containsAll(<ChatRole>[ChatRole.user, ChatRole.assistant]));
      expect(restored.map((ChatMessage m) => m.content).toList(),
          containsAll(<String>['改一下开头', '已改写']));
    });
  });

  group('边聊界面接线：关联 → 提意见 → 回写（UI 级）', () {
    /// 把页面挂起来（关联面板用真实页面状态，写作链路用打桩服务）。
    Future<void> pumpPage(
      WidgetTester tester,
      ChapterRevisionService service,
    ) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          chapterRevisionServiceProvider.overrideWithValue(service),
          // 页面只用到「有多少个 Agent 待命」这个计数，无需真装配 8 个 Agent
          allAgentsProvider.overrideWithValue(const <BaseAgent>[]),
          // 关联状态会落 KVStore：用例里换成内存实现，别碰真机数据
          keyValueStoreProvider.overrideWith((_) async => _MemoryKv()),
        ],
        child: const MaterialApp(home: AICollaborationPage()),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, int index, String option) async {
      await tester.tap(find.byType(DropdownButton<String>).at(index));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    /// 展开面板 → 选书籍/分卷/章节 → 点「关联」。
    Future<void> linkFirstChapter(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      await pick(tester, 0, '测试书');
      await pick(tester, 1, '第1卷 第一卷');
      await pick(tester, 2, '第1章 《第一章 试炼》');
      await tester.tap(find.text('关联'));
      await tester.pumpAndSettle();
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
    }

    testWidgets('未点「关联」前输入仍是普通问答；关联后输入即改写并落库',
        (WidgetTester tester) async {
      final ChapterRow chapter = await makeChapter(content: '原始正文');
      writing.reply = '被意见改写后的正文';
      await pumpPage(tester, build());

      // ① 初始未关联
      expect(find.textContaining('未关联章节'), findsOneWidget,
          reason: '未关联时必须明确告知"不会改动项目文件"');

      // ② 只"选中"还不算关联（防止误把普通聊天当成改稿指令）
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      await pick(tester, 0, '测试书');
      await pick(tester, 1, '第1卷 第一卷');
      await pick(tester, 2, '第1章 《第一章 试炼》');
      expect(find.textContaining('未关联章节'), findsOneWidget,
          reason: '只挑章节不点「关联」不应进入改写模式');

      await tester.tap(find.text('关联'));
      await tester.pumpAndSettle();
      // 状态栏与消息流各出现一次
      expect(find.textContaining('已关联《测试书》'), findsWidgets);
      // 关联后模式切换器必须仍在（改稿模式要在关联后还能改）
      expect(find.textContaining('按意见改写'), findsWidgets);

      // ③ 输入改进意见并发送
      await send(tester, '重写开头，加强冲突');

      // ④ 章节正文真的被改写
      final ChapterRow? after = await chapters.getById(chapter.id);
      expect(after!.content, '被意见改写后的正文');
      expect(after.wordCount, '被意见改写后的正文'.length);
      expect(writing.lastTask, 'PolishText');
      expect(writing.lastSnapshot['Instruction'], '重写开头，加强冲突');
      expect(find.textContaining('已按你的要求更新'), findsOneWidget);
    });

    testWidgets('关联后提问：只作答，绝不改动章节', (WidgetTester tester) async {
      final ChapterRow chapter = await makeChapter(content: '原始正文');
      final _FakeSliceProvider provider =
          _FakeSliceProvider(<({bool ok, String text})>[
        (ok: true, text: '节奏偏慢，建议冲突提前。'),
      ]);
      await pumpPage(tester, build(provider: provider));
      await linkFirstChapter(tester);

      await send(tester, '这章的节奏有什么问题？');

      final ChapterRow? after = await chapters.getById(chapter.id);
      expect(after!.content, '原始正文', reason: '提问不该改正文（这是本次修的 BUG）');
      expect(after.versionNumber, chapter.versionNumber);
      expect(writing.calls, isEmpty, reason: '提问不该走改稿链路');
      expect(provider.requests.length, 1);
      expect(find.textContaining('节奏偏慢'), findsOneWidget);
      expect(find.textContaining('已按你的要求更新'), findsNothing);
      expect(find.textContaining('已关联《测试书》'), findsWidgets, reason: '提问后仍保持关联');
    });

    testWidgets('切到别的页面再回来：关联与处理模式都还在（跨页面保持）',
        (WidgetTester tester) async {
      final ChapterRow chapter = await makeChapter(content: '原始正文');
      writing.reply = '续写片段';
      // 手工持有容器，模拟 AppShell 只换页面、不换 ProviderScope
      final ProviderContainer container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        chapterRevisionServiceProvider.overrideWithValue(build()),
        allAgentsProvider.overrideWithValue(const <BaseAgent>[]),
        keyValueStoreProvider.overrideWith((_) async => _MemoryKv()),
      ]);
      addTearDown(container.dispose);

      Future<void> show(Widget page) => tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(home: page),
            ),
          );

      await show(const AICollaborationPage());
      await tester.pumpAndSettle();
      await linkFirstChapter(tester);

      // 关联后切到「续写」模式（模式切换器在关联后必须仍可见）
      await tester.tap(find.text('按意见续写'));
      await tester.pumpAndSettle();

      // 导航离开：页面 State 被销毁（AppShell._buildPage 每次只挂一个页面）
      await show(const Scaffold(body: Center(child: Text('其他页面'))));
      await tester.pumpAndSettle();
      expect(find.byType(AICollaborationPage), findsNothing);

      // 回来
      await show(const AICollaborationPage());
      await tester.pumpAndSettle();

      // 状态栏 + 恢复出来的聊天记录（聊天记录现在也跨页面保持）
      expect(find.textContaining('已关联《测试书》'), findsWidgets,
          reason: '关联状态必须跨页面保持（这是提到 Riverpod 的目的）');
      expect(find.textContaining('这里是 NovelCraft'), findsOneWidget,
          reason: '开场白不得因切页面而重复追加');

      // 而且能直接接着改稿，且模式（续写）也一起保住了
      await send(tester, '接着写结尾');
      expect(writing.lastTask, 'ContinueChapter', reason: '处理模式也应保持');
      final ChapterRow? after = await chapters.getById(chapter.id);
      expect(after!.content, '原始正文\n\n续写片段');
    });

    testWidgets('App 重启后从 KVStore 恢复上次关联的章节与模式',
        (WidgetTester tester) async {
      final ChapterRow chapter = await makeChapter(content: '原始正文');
      writing.reply = '续写片段';
      final _MemoryKv kv = _MemoryKv();

      /// 起一次 App：全新容器（内存态全空），只有 KVStore 是同一份。
      Future<ProviderContainer> boot() async {
        final ProviderContainer c = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(db),
          chapterRevisionServiceProvider.overrideWithValue(build()),
          allAgentsProvider.overrideWithValue(const <BaseAgent>[]),
          keyValueStoreProvider.overrideWith((_) async => kv),
        ]);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AICollaborationPage()),
        ));
        await tester.pumpAndSettle();
        return c;
      }

      // 第一次启动：关联章节 + 切「续写」模式 + 说一句（留下聊天记录）
      final ProviderContainer first = await boot();
      await linkFirstChapter(tester);
      await tester.tap(find.text('按意见续写'));
      await tester.pumpAndSettle();
      expect(await kv.readJson('copilot', 'chapter_referral'), isNotNull,
          reason: '关联后必须落 KVStore');
      await send(tester, '接着写结尾');
      expect(await kv.readJson('copilot', 'chat_log'), contains('接着写结尾'),
          reason: '聊天记录也要落 KVStore');

      // 关掉 App：先卸载页面，再销毁容器（等价于进程退出）
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Center(child: Text('退出')))));
      first.dispose();

      // 第二次启动
      final ProviderContainer second = await boot();
      addTearDown(second.dispose);

      expect(find.textContaining('已关联《测试书》'), findsWidgets,
          reason: '重启后应从 KVStore 恢复关联（状态栏 + 恢复出来的聊天记录）');
      expect(find.textContaining('这里是 NovelCraft'), findsOneWidget,
          reason: '开场白不得重复');
      // 界面确实把恢复出来的记录渲染了出来（底部几条可能不在视口内，故只断言首屏可见的）
      expect(find.textContaining('接着写结尾'), findsWidgets,
          reason: '用户那句要从 KVStore 恢复出来');
      // 完整内容以 provider 状态为准：AI 回复与"已更新正文"的汇报也都在
      final String restoredLog = second
          .read(copilotChatLogProvider)
          .messages
          .map((ChatMessage m) => m.content)
          .join('\n');
      expect(restoredLog, contains('续写片段'), reason: 'AI 回复也要恢复');
      expect(restoredLog, contains('已按你的要求更新'), reason: '汇报消息也要恢复');

      // 能直接接着改稿，且模式（续写）也一起恢复
      await send(tester, '续写第二段');
      expect(writing.lastTask, 'ContinueChapter', reason: '处理模式也要一起恢复');
      final ChapterRow? after = await chapters.getById(chapter.id);
      expect(after!.content, '原始正文\n\n续写片段\n\n续写片段');
    });

    testWidgets('恢复时自愈：KVStore 里的目标章节已被删除则清掉悬空关联',
        (WidgetTester tester) async {
      await makeChapter(content: '原始正文');
      final _MemoryKv kv = _MemoryKv();
      // 手工造一条"指向已删除章节"的关联记录
      await kv.writeJson(
        'copilot',
        'chapter_referral',
        jsonEncode(<String, Object?>{
          'projectId': projectId,
          'volumeId': volumeId,
          'pickedChapterId': 'deleted-chapter',
          'linkedChapterId': 'deleted-chapter',
          'reviseMode': true,
          'expanded': true,
        }),
      );

      final ProviderContainer c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        chapterRevisionServiceProvider.overrideWithValue(build()),
        allAgentsProvider.overrideWithValue(const <BaseAgent>[]),
        keyValueStoreProvider.overrideWith((_) async => kv),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AICollaborationPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('未关联章节'), findsOneWidget,
          reason: '章节已不存在：不能显示一个悬空的关联');
      final String? raw = await kv.readJson('copilot', 'chapter_referral');
      expect(raw, contains('"linkedChapterId":null'),
          reason: '自愈后要把清理结果写回 KVStore');
    });

    testWidgets('输入「取消关联」即解除，恢复普通问答', (WidgetTester tester) async {
      final ChapterRow chapter = await makeChapter(content: '原始正文');
      final _FakeSliceProvider provider =
          _FakeSliceProvider(<({bool ok, String text})>[
        (ok: true, text: '不该被调用'),
      ]);
      await pumpPage(tester, build(provider: provider));
      await linkFirstChapter(tester);

      await send(tester, '取消关联');

      // 状态栏回到「未关联」（聊天记录里那条"已关联"提示仍会保留，故用输入框提示语判定）
      expect(find.textContaining('输入问题或请求'), findsOneWidget,
          reason: '解除后输入框提示应回到普通问答');
      expect(find.textContaining('未关联章节'), findsWidgets);
      final ChapterRow? after = await chapters.getById(chapter.id);
      expect(after!.content, '原始正文');
      expect(provider.requests, isEmpty, reason: '解除关联不该调用模型');
      expect(writing.calls, isEmpty);
    });
  });
}