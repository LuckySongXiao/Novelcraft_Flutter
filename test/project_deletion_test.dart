// 项目删除回归测试：软删除必须触发 watch 查询流（列表即时消失）+ 级联删除。
//
// 背景：① softDeleteRow 曾用裸 SQL 且不通知 drift 查询流，导致依赖
// watchAll() 的项目列表删除后永不刷新（表现为「项目无法删除」）。
// ② deleteCascade 曾把整链塞进单个事务，且对 **没有 project_id 列** 的表
// （cultivation_levels / political_positions）按 project_id 批量软删 →
// `no such column: project_id` → 事务回滚 → 项目删不掉。
//
// 运行：flutter test test/project_deletion_test.dart
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/repository_base.dart' show notDeleted;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('软删除后 getAll/getById 立即过滤', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = ProjectRepository(db);
    await repo.create(ProjectsCompanion.insert(
      id: 'p1',
      name: '测试项目',
      type: 'Xianxia',
    ));
    expect(await repo.getById('p1'), isNotNull);
    await repo.delete('p1');
    expect(await repo.getById('p1'), isNull);
    expect(await repo.getAll(), isEmpty);
    await db.close();
  });

  test('deleteCascade：删本体 + 级联关联数据，保留角色库（回归：无 project_id 列）',
      () async {
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
    final ProjectRepository repo = ProjectRepository(db);
    const String pid = 'p-cascade';

    await repo.create(ProjectsCompanion.insert(
      id: pid,
      name: '级联测试项目',
      type: 'Xianxia',
    ));
    // 分卷 + 章节
    await db.into(db.volumes).insert(VolumesCompanion.insert(
          id: 'v1',
          title: '第一卷',
          projectId: pid,
        ));
    await db.into(db.chapters).insert(ChaptersCompanion.insert(
          id: 'c1',
          title: '第一章',
          volumeId: 'v1',
          projectId: const Value(pid),
        ));
    // 修炼体系 + 等级（等级表**没有 project_id**，走 cultivation_system_id）
    await db.into(db.cultivationSystems).insert(
        CultivationSystemsCompanion.insert(id: 'cs1', name: '炼气体系', type: '功法', projectId: pid));
    await db.into(db.cultivationLevels).insert(
        CultivationLevelsCompanion.insert(id: 'cl1', name: '炼气一层', cultivationSystemId: 'cs1'));
    // 政治体系 + 职位（职位表**没有 project_id**，走 political_system_id）
    await db.into(db.politicalSystems).insert(
        PoliticalSystemsCompanion.insert(id: 'ps1', name: '王朝制', type: '君主制', projectId: pid));
    await db.into(db.politicalPositions).insert(
        PoliticalPositionsCompanion.insert(id: 'pp1', name: '宰相', politicalSystemId: 'ps1'));
    // 时间线事件 + 参与者
    await db.into(db.timelineEvents).insert(TimelineEventsCompanion.insert(
          id: 'te1',
          title: '开篇之战',
          eventDate: DateTime.now(),
          projectId: pid,
        ));
    await db.into(db.timelineEventParticipants).insert(
        TimelineEventParticipantsCompanion.insert(
            id: 'tep1', name: '主角', timelineEventId: 'te1'));
    // 联结表：剧情 ↔ 章节
    await db.into(db.plots).insert(PlotsCompanion.insert(
          id: 'pl1',
          title: '主线',
          type: '主线',
          projectId: pid,
        ));
    await db.into(db.chapterPlotEntries).insert(
        ChapterPlotEntriesCompanion.insert(plotId: 'pl1', chapterId: 'c1'));
    // 角色库：人物 + 人物事件（必须保留）
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: 'ch1',
          name: '主角',
          type: '主角',
          projectId: pid,
        ));
    await db.into(db.characterEvents).insert(CharacterEventsCompanion.insert(
        id: 'ce1', title: '初登场', characterId: 'ch1'));

    await repo.deleteCascade(pid);

    // 项目本体必须消失
    expect(await repo.getById(pid), isNull, reason: '项目本体应被删除');
    expect(await repo.getAll(), isEmpty);

    Future<int> liveCount(String table) async => (await db
            .customSelect('SELECT COUNT(*) AS c FROM $table WHERE is_deleted = 0')
            .getSingle())
        .read<int>('c');

    expect(await liveCount('volumes'), 0, reason: '分卷级联删除');
    expect(await liveCount('chapters'), 0, reason: '章节级联删除');
    expect(await liveCount('cultivation_systems'), 0);
    expect(await liveCount('cultivation_levels'), 0, reason: '等级表按父表子查询级联');
    expect(await liveCount('political_systems'), 0);
    expect(await liveCount('political_positions'), 0, reason: '职位表按父表子查询级联');
    expect(await liveCount('timeline_events'), 0);
    expect(await liveCount('timeline_event_participants'), 0);

    // 联结表物理清理
    final int junction = (await db
            .customSelect('SELECT COUNT(*) AS c FROM chapter_plot_entries')
            .getSingle())
        .read<int>('c');
    expect(junction, 0, reason: '章节↔剧情联结行应被物理清理');

    // 角色库保留
    final List<CharacterRow> chars = await (db.select(db.characters)
          ..where((t) => notDeleted(t.isDeleted)))
        .get();
    expect(chars.length, 1, reason: '角色库必须保留（人物仍在）');
    expect(await liveCount('character_events'), 1, reason: '人物事件属角色库，保留');

    await db.close();
  });

  test('软删除触发 watchAll 查询流刷新（回归：项目无法删除）', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = ProjectRepository(db);
    await repo.create(ProjectsCompanion.insert(
      id: 'p1',
      name: '测试项目',
      type: 'Xianxia',
    ));

    final emitted = <int>[];
    final Completer<void> secondEvent = Completer<void>();
    late final StreamSubscription<List<ProjectRow>> sub;
    sub = repo.watchAll().listen((List<ProjectRow> rows) {
      emitted.add(rows.length);
      if (emitted.length >= 2 && !secondEvent.isCompleted) {
        secondEvent.complete();
      }
    });
    // 等首个快照（drift watch 立即发出当前值）
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(emitted.isNotEmpty, isTrue);

    await repo.delete('p1');
    await secondEvent.future.timeout(const Duration(seconds: 2),
        onTimeout: () {
      fail('软删除后 watchAll 未收到刷新事件（raw SQL 未通知查询流）');
    });
    expect(emitted.last, 0, reason: '删除后列表应为空');
    await sub.cancel();
    await db.close();
  });
}
