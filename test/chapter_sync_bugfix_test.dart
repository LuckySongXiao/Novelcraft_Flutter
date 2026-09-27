// 章节状态自动更新（功能 C）深度 bug 狩猎回归：
//   ①首末出场回填——已删首出场章节不再被本章误抢
//   ②剧情状态保护——「暂停」不被自动覆盖为「已完成」
//   ③剧情进度——wordCount=0 时按正文长度兜底（手动保存路径的字数暗坑）
//   ④脏数据容错——同对双向重复关系记录不再炸全链
//
// 运行：flutter test test/chapter_sync_bugfix_test.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:novelcraft/application/services/chapter_sync_service.dart';
import 'package:novelcraft/data/database.dart';

void main() {
  const Uuid uuid = Uuid();
  late AppDatabase db;
  late String projectId;
  late String volumeId;
  late String chapterId;

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
          content: const Value('林晚持剑踏入宗门大比的擂台，夜色如墨。'),
        ));
  });

  ChapterSyncInput input({String content = ''}) => ChapterSyncInput(
        chapterId: chapterId,
        volumeId: volumeId,
        projectId: projectId,
        title: '宗门大比',
        orderIndex: 1,
        content: content.isEmpty ? '林晚持剑踏入宗门大比的擂台，夜色如墨。' : content,
        versionNumber: 1,
        eventDate: DateTime.now(),
      );

  test('剧情「暂停」不被自动覆盖为「已完成」（即使进度达标）', () async {
    final String plotId = uuid.v4();
    await db.into(db.plots).insert(PlotsCompanion.insert(
          id: plotId,
          projectId: projectId,
          title: '宗门大比',
          type: '主线',
          // estimated=0 → 走 inferred（1 章×20=20 <100）；
          // 把 estimated 设小 + 手填字数大 → progress≥100
          estimatedWordCount: const Value(10),
          status: const Value('暂停'),
        ));
    // 章节挂接：让剧情能看到本章
    await db
        .into(db.chapterPlotEntries)
        .insert(ChapterPlotEntriesCompanion.insert(
          plotId: plotId,
          chapterId: chapterId,
        ));

    // 手动把章节字数填成 500（estimated=10 → 进度 100%）
    await (db.update(db.chapters)..where((t) => t.id.equals(chapterId)))
        .write(const ChaptersCompanion(wordCount: Value(500)));

    final svc = ChapterSyncService(db: db);
    await svc.sync(input());

    final PlotRow p = await (db.select(db.plots)
          ..where((t) => t.id.equals(plotId)))
        .getSingle();
    expect(p.status, '暂停',
        reason: '自动更新不得覆盖用户手动设置的「暂停」状态');
    expect(p.progress, 100);
  });

  test('「进行中」剧情进度达标 → 自动推进为「已完成」', () async {
    final String plotId = uuid.v4();
    await db.into(db.plots).insert(PlotsCompanion.insert(
          id: plotId,
          projectId: projectId,
          title: '宗门大比',
          type: '主线',
          estimatedWordCount: const Value(10),
          status: const Value('进行中'),
        ));
    await db
        .into(db.chapterPlotEntries)
        .insert(ChapterPlotEntriesCompanion.insert(
          plotId: plotId,
          chapterId: chapterId,
        ));
    await (db.update(db.chapters)..where((t) => t.id.equals(chapterId)))
        .write(const ChaptersCompanion(wordCount: Value(500)));

    final svc = ChapterSyncService(db: db);
    await svc.sync(input());

    final PlotRow p = await (db.select(db.plots)
          ..where((t) => t.id.equals(plotId)))
        .getSingle();
    expect(p.status, '已完成');
    expect(p.progress, 100);
  });

  test('wordCount=0 时按正文长度兜底（进度不再恒 0）', () async {
    final String plotId = uuid.v4();
    // 估计字数 10，正文 20 字 → 进度应为 100（按 content 长度兜底）
    await db.into(db.plots).insert(PlotsCompanion.insert(
          id: plotId,
          projectId: projectId,
          title: '宗门大比',
          type: '主线',
          estimatedWordCount: const Value(10),
          status: const Value('进行中'),
        ));
    await db
        .into(db.chapterPlotEntries)
        .insert(ChapterPlotEntriesCompanion.insert(
          plotId: plotId,
          chapterId: chapterId,
        ));
    // 明确把 wordCount 置 0（模拟「手填字数没人填」的存量数据）
    await (db.update(db.chapters)..where((t) => t.id.equals(chapterId)))
        .write(const ChaptersCompanion(wordCount: Value(0)));

    final svc = ChapterSyncService(db: db);
    await svc.sync(input());

    final PlotRow p = await (db.select(db.plots)
          ..where((t) => t.id.equals(plotId)))
        .getSingle();
    expect(p.progress, 100,
        reason: 'wordCount=0 时应按正文长度兜底，进度不得恒 0');
  });

  test('脏数据：同对人物关系存在双向重复记录，同步不炸、取第一条追加', () async {
    final String cid = uuid.v4();
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: cid,
          projectId: projectId,
          name: '林晚',
          type: '主角',
          history: const Value(''),
        ));
    final String peerId = uuid.v4();
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: peerId,
          projectId: projectId,
          name: '苏牧云',
          type: '配角',
          history: const Value(''),
        ));
    // 故意插入两条互为镜像的关系（历史脏数据）
    await db.into(db.characterRelationships).insert(
          CharacterRelationshipsCompanion.insert(
            id: uuid.v4(),
            sourceCharacterId: cid,
            targetCharacterId: peerId,
            relationshipType: '同门',
          ),
        );
    await db.into(db.characterRelationships).insert(
          CharacterRelationshipsCompanion.insert(
            id: uuid.v4(),
            sourceCharacterId: peerId,
            targetCharacterId: cid,
            relationshipType: '同门',
          ),
        );

    final svc = ChapterSyncService(db: db);
    // 修复前：getSingleOrNull 遇两条 → StateError → 整条同步链失败
    final ChapterSyncOutcome r = await svc.sync(input());
    expect(r.skippedReason, isNull,
        reason: '脏数据不应炸掉整条同步链');
  });

  test('首出场章节已被删除时，本章不误抢首出场', () async {
    final String cid = uuid.v4();
    final String ghostChapterId = uuid.v4(); // 已删除的章节（不在 orderLookup）
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: cid,
          projectId: projectId,
          name: '林晚',
          type: '主角',
          firstAppearanceChapterId: Value(ghostChapterId),
        ));

    final svc = ChapterSyncService(db: db);
    await svc.sync(input());

    final CharacterRow c =
        await (db.select(db.characters)..where((t) => t.id.equals(cid)))
            .getSingle();
    expect(c.firstAppearanceChapterId, ghostChapterId,
        reason: '首出场指向已删章时保持原值，不误抢');
  });
}
