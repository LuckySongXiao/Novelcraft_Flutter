// 关联改稿的**真模型**端到端验收（人工验收用）。
//
// 与 `chapter_revision_test.dart` 的分工：
//   * `chapter_revision_test.dart` —— AI 全部打桩，快、可离线，做回归；
//   * 本文件 —— **一个桩都不打**，真打 `api-7b.rwkvos.com`，
//     验的就是「关联章节 → 提意见 → 真云端 RWKV 改写 → 回写 Chapter.Content」。
//
// 运行（需外网 + 那台 GPU 在线；每个用例会给到 8 分钟）：
//   flutter test -d windows integration_test/chapter_revision_live_test.dart
// 凭证与 `rwkv_cloud_live_test.dart` 同源，可用 --dart-define 覆盖：
//   --dart-define=RWKV_CF_ID=xxx.access --dart-define=RWKV_CF_SECRET=yyy
//
// ⚠ 只写内存数据库，**不碰作者的真实书稿**。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'package:novelcraft/ai/agents/agent.dart';
import 'package:novelcraft/ai/models/provider.dart';
import 'package:novelcraft/ai/prompts/prompt_template.dart';
import 'package:novelcraft/ai/providers/rwkv_cloud_provider.dart';
import 'package:novelcraft/ai/utils/localized_text.dart';
import 'package:novelcraft/ai/workflow/dual_agent_workflow.dart';
import 'package:novelcraft/application/services/ai_writing_service.dart';
import 'package:novelcraft/application/services/chapter_revision_service.dart';
import 'package:novelcraft/application/services/project_context_assembler.dart';
import 'package:novelcraft/core/prompt_template_loader.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/character_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/world_setting_repository.dart';

const String _cfId = String.fromEnvironment('RWKV_CF_ID');
const String _cfSecret = String.fromEnvironment('RWKV_CF_SECRET');

/// 验收用章（约 350 字，短于分段阈值 → 走双 Agent 一次成稿）。
const String _originalText =
    '清晨的雾还没散，叶知秋已经站在演武场的石阶下。他握剑的手很稳，心里却翻着浪。'
    '昨夜长老会的那句话像根刺——「你若败了，青云山的脸面便由你一人担着」。'
    '对手是谢青山，同门里出了名的快剑。锣声一响，两道人影同时掠出，剑光在雾里交成一线。'
    '第一招，叶知秋只守不攻；第二招，他退了半步；第三招，他忽然不退了。'
    '玄铁古剑贴着地面掀起一道尘浪，谢青山的剑尖在离他咽喉三寸处停住，'
    '而他的剑已经抵在对方腰侧。场边一片死寂，随后才爆出喝彩。';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const Uuid uuid = Uuid();
  late AppDatabase db;
  late RwkvCloudProvider cloud;
  late ChapterRevisionService service;
  late ChapterRepository chapters;
  late String projectId;
  late String volumeId;
  late PromptTemplateRegistry templates;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chapters = ChapterRepository(db);
    projectId = uuid.v4();
    volumeId = uuid.v4();
    templates = await _loadTemplates();

    await db.into(db.projects).insert(ProjectsCompanion.insert(
          id: projectId,
          name: '验收样书',
          type: '东方玄幻',
          description: const Value('真机验收用的临时项目，只存在于内存数据库。'),
        ));
    await db.into(db.volumes).insert(VolumesCompanion.insert(
          id: volumeId,
          title: '第一卷',
          projectId: projectId,
        ));

    // 真云端 provider（与「AI 配置」页保存的配置一致）
    cloud = RwkvCloudProvider(client: http.Client());
    await cloud.initialize(RwkvCloudConfiguration(
      cfAccessClientId: _cfId,
      cfAccessClientSecret: _cfSecret,
      baseUrl: 'https://api-7b.rwkvos.com/v1',
      defaultModel: kRwkvCloudDefaultModel,
      timeoutSeconds: 300,
    ));

    final ProjectContextAssembler assembler = ProjectContextAssembler(
      projects: ProjectRepository(db),
      plots: PlotRepository(db),
      characters: CharacterRepository(db),
      worldSettings: WorldSettingRepository(db),
    );

    // 双代理：两个角色都指向云端（与真机上保存的 agent.dual_settings 一致）
    final DualAgentWorkflowService dual = DualAgentWorkflowService(
      logger: Logger('LiveDualAgent'),
      settings: () => const AgentRoleWorkflowSettings(
        mainAgentProvider: 'RWKV Cloud',
        subAgentProvider: 'RWKV Cloud',
      ),
      providers: () => <String, IModelProvider>{'RWKV Cloud': cloud},
      texts: const StaticTextSource(),
      templates: () => templates,
    );

    final AiWritingService writing = AiWritingService(
      dualAgent: dual,
      contextAssembler: assembler,
      texts: const StaticTextSource(),
      agents: () => const <BaseAgent>[],
    );

    service = ChapterRevisionService(
      writing: writing,
      chapters: chapters,
      contextAssembler: assembler,
      texts: const StaticTextSource(),
      // 与真机同判据：provider 不可用就不该动稿
      hasWriter: () => cloud.isAvailable,
      sliceProvider: () => cloud,
      rwkv: () => throw UnsupportedError('真机验收不回落本地 RWKV'),
    );
  });

  tearDown(() {
    cloud.dispose();
    return db.close();
  });

  Future<ChapterRow> makeChapter({required String content}) =>
      chapters.create(ChaptersCompanion.insert(
        id: uuid.v4(),
        title: '第一章 演武场',
        volumeId: volumeId,
        projectId: Value(projectId),
        content: Value(content),
        summary: const Value('主角在演武场击败同门快剑，取得长老会认可。'),
        wordCount: Value(content.length),
      ));

  test('连通性：云端 RWKV 可达（CF 头正确）', () async {
    final ConnectionTestResult r = await cloud.testConnection();
    expect(r.isSuccess, isTrue,
        reason: '失败信息：${r.errorMessage}\n'
            '若返回 HTML 登录页，说明 CF-Access-Client-Id/Secret 拼错或过期');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('验收①：关联章节 → 提意见 → 真模型改写 → 回写 Chapter.Content', () async {
    final ChapterRow before = await makeChapter(content: _originalText);
    final Stopwatch sw = Stopwatch()..start();

    final ChapterRevisionResult r = await service.revise(
      projectId: projectId,
      chapterId: before.id,
      instruction: '重写开头，把冲突提前，让第一招就有火星味',
    );
    sw.stop();

    final ChapterRow? after = await chapters.getById(before.id);
    final String revised = after?.content ?? '';
    final String head = revised.length > 500 ? revised.substring(0, 500) : revised;
    // 便于人工核对：把真实产出打出来
    // ignore: avoid_print
    print('=== 真模型改写结果（${sw.elapsed.inSeconds}s）===\n'
        '${r.message}\n'
        'workflowMode=${r.workflowMode} persisted=${r.persisted}\n'
        '--- 正文（前 500 字）---\n$head');

    expect(r.isSuccess, isTrue, reason: r.message);
    expect(r.persisted, isTrue, reason: '必须真的写回章节');
    expect(r.workflowMode, 'DualAgent', reason: '双代理两个角色都应接管');
    expect(after!.content, isNot(_originalText), reason: '正文必须被改写');
    expect(after.content, isNot(contains('本地回退章节示例')),
        reason: '绝不能落内置占位文本');
    expect(after.wordCount, after.content!.length);
    expect(after.versionNumber, before.versionNumber + 1);
    expect(after.status, before.status, reason: '改稿不动状态');
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('验收②：关联下提问 → 真模型只作答，一字不改正文', () async {
    final ChapterRow before = await makeChapter(content: _originalText);

    final ChapterRevisionResult r = await service.askAboutChapter(
      projectId: projectId,
      chapterId: before.id,
      question: '这一章的节奏有什么问题？',
    );

    final ChapterRow? after = await chapters.getById(before.id);
    // ignore: avoid_print
    print('=== 真模型问答结果（${r.workflowMode}）===\n${r.content}');

    expect(r.isSuccess, isTrue, reason: r.message);
    expect(r.persisted, isFalse, reason: '问答不落库');
    expect(r.workflowMode, 'ChapterQa');
    expect(after!.content, _originalText, reason: '提问绝不能改正文');
    expect(after.versionNumber, before.versionNumber);
    expect(r.content.length, greaterThan(10), reason: '应当有真实答复内容');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// 真机上的提示词模板（rootBundle 取不到就退化为代码内置提示词，不阻断验收）。
Future<PromptTemplateRegistry> _loadTemplates() async {
  try {
    return await loadPromptTemplateRegistry();
  } on Object {
    return const PromptTemplateRegistry.empty();
  }
}