// 规则同步验证（chapter_sync_service.dart，drift 内存库、不联网）—— 功能 C 一级。
//
// ⚠ 放 test/ 而不是 tool/：database.dart 经 drift_flutter 依赖 dart:ui，
//   纯 `dart run` 跑不了；flutter test 可以。断言面：
//   人物/势力/人物关系/剧情/世界设定/时间线 六类同步 + 幂等 + 跳过码。
//
// 运行：flutter test test/chapter_sync_test.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:novelcraft/application/services/chapter_sync_service.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/repository_base.dart'
    show notDeleted;

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
          wordCount: const Value(150),
          content: const Value(
              '林轩与张伟在青云宗大比上联手，击退了天魔宫的偷袭。灵石经济随之波动，青云宗覆灭的阴影暂时散去。'),
        ));
  });

  tearDown(() async => db.close());

  ChapterSyncInput buildInput({int versionNumber = 1}) => ChapterSyncInput(
        chapterId: chapterId,
        volumeId: volumeId,
        projectId: projectId,
        title: '宗门大比',
        orderIndex: 0,
        content:
            '林轩与张伟在青云宗大比上联手，击退了天魔宫的偷袭。灵石经济随之波动，青云宗覆灭的阴影暂时散去。',
        status: 'Draft',
        versionNumber: versionNumber,
      );

  Future<CharacterRow> character(String id) =>
      (db.select(db.characters)..where((t) => t.id.equals(id))).getSingle();

  test('首次同步：六类计数全为正，单字名不参与匹配', () async {
    final ChapterSyncService service = ChapterSyncService(db: db);
    final String charAId = uuid.v4();
    final String charBId = uuid.v4();
    final String charCId = uuid.v4();
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: charAId, name: '林轩', type: '主角', projectId: projectId));
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: charBId, name: '张伟', type: '配角', projectId: projectId));
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: charCId, name: '影', type: '配角', projectId: projectId));

    final ChapterSyncOutcome r = await service.sync(buildInput());

    expect(r.applied, isTrue, reason: '${r.skippedReason}');
    expect(r.counts.characters, 2, reason: '单字名「影」不该命中：${r.counts}');
    expect(r.counts.timelineEvents, 1);
    final CharacterRow a = await character(charAId);
    expect(a.history, contains('第1章《宗门大比》'));
    expect(a.firstAppearanceChapterId, chapterId);
    expect(a.lastAppearanceChapterId, chapterId);
    final CharacterRow c = await character(charCId);
    expect(c.history ?? '', isEmpty, reason: '「影」不该被误伤');
  });

  test('人物履历事件 / 势力 / 剧情进度 / 世界设定 / 时间线与参与者', () async {
    final ChapterSyncService service = ChapterSyncService(db: db);
    final String charAId = uuid.v4();
    final String factionAId = uuid.v4();
    await db.into(db.factions).insert(FactionsCompanion.insert(
          id: factionAId, name: '青云宗', type: '宗门', projectId: projectId));
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: charAId,
          name: '林轩',
          type: '主角',
          projectId: projectId,
          factionId: Value(factionAId),
        ));
    await db.into(db.plots).insert(PlotsCompanion.insert(
          id: uuid.v4(),
          title: '青云宗覆灭',
          type: '主线',
          projectId: projectId,
          estimatedWordCount: const Value(1000),
        ));
    await db.into(db.worldSettings).insert(WorldSettingsCompanion.insert(
          id: uuid.v4(),
          name: '灵石经济',
          type: '经济',
          projectId: projectId,
        ));

    final ChapterSyncOutcome r = await service.sync(buildInput());
    expect(r.applied, isTrue);
    expect(r.counts.factions, 1, reason: '${r.counts}');
    expect(r.counts.plots, 1);
    expect(r.counts.settings, 1);
    expect(r.counts.characterRelationships, 0, reason: '只命中 1 个角色，无配对');

    final FactionRow faction =
        await (db.select(db.factions)..where((t) => t.id.equals(factionAId)))
            .getSingle();
    expect(faction.memberCount, 1);
    expect(faction.notes, contains('同步更新'));

    final PlotRow plot = await (db.select(db.plots)
          ..where((t) => t.title.equals('青云宗覆灭')))
        .getSingle();
    expect(plot.startChapterId, chapterId);
    expect(plot.endChapterId, chapterId);
    expect(plot.progress, greaterThan(0));
    expect(plot.status, '进行中', reason: '规划中 → 进行中');

    final WorldSettingRow setting = await (db.select(db.worldSettings)
          ..where((t) => t.name.equals('灵石经济')))
        .getSingle();
    expect(setting.history, contains('章节推进同步'));

    final TimelineEventRow event = await (db.select(db.timelineEvents)
          ..where((t) => t.projectId.equals(projectId)))
        .getSingle();
    expect(event.category, '剧情事件');
    expect(event.chapterId, chapterId);
    final List<TimelineEventParticipantRow> participants = await (db.select(
            db.timelineEventParticipants)
          ..where((t) => t.timelineEventId.equals(event.id)))
        .get();
    expect(participants.map((TimelineEventParticipantRow p) => p.type),
        containsAll(<String>['角色', '势力']));
  });

  test('幂等：同章重复同步不重复追加 / 不重复建事件与关系', () async {
    final ChapterSyncService service = ChapterSyncService(db: db);
    final String charAId = uuid.v4();
    final String charBId = uuid.v4();
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: charAId, name: '林轩', type: '主角', projectId: projectId));
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: charBId, name: '张伟', type: '配角', projectId: projectId));

    await service.sync(buildInput());
    await service.sync(buildInput());

    final CharacterRow a = await character(charAId);
    expect(a.history!.split('\n').length, 1, reason: 'History 去重：${a.history}');
    final List<CharacterEventRow> events = await (db.select(db.characterEvents)
          ..where((t) => t.characterId.equals(charAId)))
        .get();
    expect(events, hasLength(1), reason: '履历事件 upsert');
    final List<CharacterRelationshipRow> rels = await (db.select(
            db.characterRelationships)
          ..where((t) => notDeleted(t.isDeleted)))
        .get();
    expect(rels, hasLength(1), reason: '同章互动关系只建一次');
  });

  test('跳过码：无项目 / 空内容', () async {
    final ChapterSyncService service = ChapterSyncService(db: db);
    final ChapterSyncOutcome noProject = await service.sync(ChapterSyncInput(
      chapterId: uuid.v4(),
      volumeId: '',
      projectId: '',
      title: '孤儿章',
      orderIndex: 0,
      content: '无项目归属。',
    ));
    expect(noProject.skippedReason, 'noProject');
    final ChapterSyncOutcome empty = await service.sync(ChapterSyncInput(
      chapterId: uuid.v4(),
      volumeId: volumeId,
      projectId: projectId,
      title: '空章',
      orderIndex: 0,
      content: '   ',
    ));
    expect(empty.skippedReason, 'emptyContent');
  });
}
