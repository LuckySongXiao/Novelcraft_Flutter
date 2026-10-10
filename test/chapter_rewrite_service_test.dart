// 单章重写服务回归（B1）—— 覆盖四条关键行为：
//   ① 质量闸不通过 → **不覆盖原稿**（宁可失败也不写半成品）；
//   ② 通过 → 落库 + versionNumber 自增 + 草稿转「已完成」，并触发世界观同步；
//   ③ 无依据（无大纲、无前章、无额外要求）→ 直接拒绝，不浪费一次模型调用；
//   ④ 上下文装配 → 提示词里必须带上「上一章结尾」与「下一章开头」。
//
// 运行：flutter test test/chapter_rewrite_service_test.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/models/provider.dart';
import 'package:novelcraft/ai/utils/localized_text.dart';
import 'package:novelcraft/application/services/chapter_rewrite_service.dart';
import 'package:novelcraft/application/services/project_context_assembler.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/character_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/world_setting_repository.dart';

/// 脚本化假 provider：记录每次调用的 user 消息，按 [answer] 返回内容。
class _Model implements IModelProvider {
  final List<ChatRequest> requests = <ChatRequest>[];
  String Function(ChatRequest) answer = (_) => '';

  @override
  bool get isAvailable => true;

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    requests.add(request);
    return ChatResponse(content: answer(request));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 合格正文：300 个互不相同的段落（≈1.1 万字，复读率 0）。
///
/// 与 `writing_quality_gate_test.dart` 的合格稿同构 —— 已被既有质量闸用例验证过
/// 能通过 `FictionQuality.issue` / 复读率 / 大纲式输出三道判据。
String _goodText() {
  final StringBuffer sb = StringBuffer();
  for (int i = 1; i <= 300; i++) {
    sb
      ..writeln('第 $i 段：主角沿山道前行，遇见第 $i 位试炼者，剑意与心境各不相同。')
      ..writeln();
  }
  return sb.toString();
}

void main() {
  const Uuid uuid = Uuid();
  late AppDatabase db;
  late ChapterRepository chapters;
  late ProjectContextAssembler assembler;
  late _Model model;
  late String projectId, volumeId, chapterId;

  ChapterRewriteService build() => ChapterRewriteService(
        chapters: chapters,
        contextAssembler: assembler,
        texts: const StaticTextSource(),
        provider: () => model,
        // 刻意不注入 rwkv：验证「provider 可用时不依赖本地回落通道」。
      );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    projectId = uuid.v4();
    volumeId = uuid.v4();
    await db.into(db.projects).insert(ProjectsCompanion.insert(
          id: projectId,
          name: '测试书',
          type: '东方玄幻',
        ));
    await db.into(db.volumes).insert(VolumesCompanion.insert(
          id: volumeId,
          title: '第一卷',
          projectId: projectId,
        ));
    chapterId = uuid.v4();
    await db.into(db.chapters).insert(ChaptersCompanion.insert(
          id: chapterId,
          volumeId: volumeId,
          title: '宗门大比',
          projectId: Value(projectId),
          status: const Value('Draft'),
          orderIndex: const Value(1),
          summary: const Value('林晚在宗门大比上首次展露剑意。'),
          content: const Value('（旧稿）林晚站在擂台上，握紧了剑。'),
        ));
    chapters = ChapterRepository(db);
    assembler = ProjectContextAssembler(
      projects: ProjectRepository(db),
      plots: PlotRepository(db),
      characters: CharacterRepository(db),
      worldSettings: WorldSettingRepository(db),
    );
    model = _Model();
  });

  tearDown(() => db.close());

  Future<ChapterRow> reload() async => (await chapters.getById(chapterId))!;

  test('① 质量闸不通过时不覆盖原稿', () async {
    model.answer = (_) => '太短了。';
    final ChapterRewriteResult r = await build().rewrite(chapterId: chapterId);

    expect(r.isSuccess, isFalse);
    expect(r.persisted, isFalse);
    expect(r.qualityNote, isNotEmpty, reason: '必须如实给出闸门原因');
    expect(r.applied, isFalse);
    expect((await reload()).content, '（旧稿）林晚站在擂台上，握紧了剑。',
        reason: '不合格的候选稿绝不能写进数据库');
  });

  test('② 通过质量闸 → 落库 + 版本自增 + 草稿转已完成', () async {
    model.answer = (_) => _goodText();
    final ChapterRow before = await reload();
    final ChapterRewriteResult r = await build().rewrite(chapterId: chapterId);

    expect(r.isSuccess, isTrue);
    expect(r.persisted, isTrue);
    expect(r.applied, isTrue);
    final ChapterRow after = await reload();
    expect(after.content, contains('第 300 段'));
    expect(after.versionNumber, before.versionNumber + 1);
    expect(after.status, 'Completed', reason: '重写通过质量闸后应把草稿扶正');
    expect(after.wordCount, after.content!.trim().length);
  });

  test('③ 无依据时直接拒绝，不做模型调用', () async {
    // 另起一个干净项目：唯一一章，既无梗概/备注，也没有上一章
    final String p2 = uuid.v4();
    final String v2 = uuid.v4();
    final String bare = uuid.v4();
    await db.into(db.projects).insert(ProjectsCompanion.insert(
          id: p2,
          name: '空项目',
          type: '东方玄幻',
        ));
    await db.into(db.volumes).insert(VolumesCompanion.insert(
          id: v2,
          title: '第一卷',
          projectId: p2,
        ));
    await db.into(db.chapters).insert(ChaptersCompanion.insert(
          id: bare,
          volumeId: v2,
          title: '空壳章',
          projectId: Value(p2),
          orderIndex: const Value(1),
        ));
    model.answer = (_) => _goodText();

    final ChapterRewriteResult r =
        await build().rewrite(chapterId: bare, projectId: p2);
    expect(r.isSuccess, isFalse);
    expect(r.message, contains('无法重写'));
    expect(r.persisted, isFalse);
    expect(model.requests, isEmpty, reason: '没有依据就不该白白调一次模型');
  });

  test('④ 提示词必须带上上一章结尾与下一章开头', () async {
    // 上一章
    final String prev = uuid.v4();
    await db.into(db.chapters).insert(ChaptersCompanion.insert(
          id: prev,
          volumeId: volumeId,
          title: '拜入山门',
          projectId: Value(projectId),
          orderIndex: const Value(0),
          content: const Value('上一章最后一句：林晚拜别师父，独自下山。'),
        ));
    // 下一章
    final String next = uuid.v4();
    await db.into(db.chapters).insert(ChaptersCompanion.insert(
          id: next,
          volumeId: volumeId,
          title: '暗流初现',
          projectId: Value(projectId),
          orderIndex: const Value(2),
          content: const Value('下一章第一句：三年后，林晚重回宗门。'),
        ));
    // 把本章 orderIndex 挪到中间，保证排序为 拜入山门 → 宗门大比 → 暗流初现
    await chapters.updateById(
      chapterId,
      ChaptersCompanion(orderIndex: const Value(1)),
    );
    model.answer = (_) => _goodText();

    final ChapterRewriteResult r = await build().rewrite(
      chapterId: chapterId,
      projectId: projectId,
      instruction: '把打斗写得更狠一点',
    );
    expect(r.isSuccess, isTrue);
    expect(model.requests, hasLength(greaterThanOrEqualTo(1)));
    final String prompt = model.requests.first.messages.last.content;
    expect(prompt, contains('林晚拜别师父'), reason: '必须带上一章结尾以衔接');
    expect(prompt, contains('三年后，林晚重回宗门'), reason: '必须带下一章开头以防写穿');
    expect(prompt, contains('林晚在宗门大比上首次展露剑意'), reason: '必须带本章梗概');
    expect(prompt, contains('把打斗写得更狠一点'), reason: '必须带作者额外要求');
  });
}
