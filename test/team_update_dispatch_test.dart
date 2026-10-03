// 验收后更新分派服务测试：固定模板解析 / 轮转分派 / 防幻觉应用 / 封顶。
//
// 运行：flutter test test/team_update_dispatch_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:novelcraft/application/services/team_update_dispatch_service.dart';
import 'package:novelcraft/data/database.dart';

const Uuid _uuid = Uuid();

void main() {
  late AppDatabase db;
  late String projectId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    projectId = _uuid.v4();
    await db.into(db.projects).insert(ProjectsCompanion.insert(
          id: projectId,
          name: '测试书',
          type: '东方玄幻',
        ));
    // 预置既有实体：人物 / 世界设定 / 势力 / 剧情 / 时间线
    await db.into(db.characters).insert(CharactersCompanion.insert(
          id: _uuid.v4(), name: '叶知秋', type: '主角', projectId: projectId,
        ));
    await db.into(db.worldSettings).insert(WorldSettingsCompanion.insert(
          id: _uuid.v4(), name: '玄穹宗', type: '设定', projectId: projectId,
        ));
    await db.into(db.factions).insert(FactionsCompanion.insert(
          id: _uuid.v4(), name: '玄穹宗', type: '门派', projectId: projectId,
        ));
    await db.into(db.plots).insert(PlotsCompanion.insert(
          id: _uuid.v4(), title: '入门试炼', type: '支线', projectId: projectId,
        ));
    await db.into(db.timelineEvents).insert(TimelineEventsCompanion.insert(
          id: _uuid.v4(),
          projectId: projectId,
          title: '入门试炼',
          eventDate: DateTime(2026, 1, 1),
        ));
  });

  tearDown(() async => db.close());

  Future<List<CharacterRow>> chars() =>
      (db.select(db.characters)..where((t) => t.projectId.equals(projectId))).get();
  Future<List<WorldSettingRow>> worlds() => (db.select(db.worldSettings)
        ..where((t) => t.projectId.equals(projectId)))
      .get();
  Future<List<FactionRow>> factions() =>
      (db.select(db.factions)..where((t) => t.projectId.equals(projectId))).get();
  Future<List<PlotRow>> plots() =>
      (db.select(db.plots)..where((t) => t.projectId.equals(projectId))).get();
  Future<List<TimelineEventRow>> events() =>
      (db.select(db.timelineEvents)..where((t) => t.projectId.equals(projectId)))
          .get();

  TeamUpdateDispatchService svc({int maxItems = 20}) =>
      TeamUpdateDispatchService(db: db, maxItems: maxItems);

  test('update 精确匹配：人物履历追加 / 世界设定履历追加 / 势力备注 / 剧情备注 / 时间线描述', () async {
    final List<String> issues = await svc().dispatchUpdates(
      projectId: projectId,
      items: <Map<String, Object?>>[
        <String, Object?>{
          'target': 'character', 'action': 'update', 'name': '叶知秋',
          'field': 'history', 'content': '拜入玄穹宗，成为外门弟子',
        },
        <String, Object?>{
          'target': 'world', 'action': 'update', 'name': '玄穹宗',
          'field': 'history', 'content': '宗门禁地开启',
        },
        <String, Object?>{
          'target': 'faction', 'action': 'update', 'name': '玄穹宗',
          'field': 'notes', 'content': '外门新增十名弟子',
        },
        <String, Object?>{
          'target': 'plot', 'action': 'update', 'name': '入门试炼',
          'field': 'notes', 'content': '试炼完成，主角通过',
        },
        <String, Object?>{
          'target': 'timeline', 'action': 'update', 'name': '入门试炼',
          'field': 'description', 'content': '主角以末位成绩通过试炼',
        },
      ],
      writerChat: (int slot, String prompt) async {
        final RegExpMatch? m =
            RegExp(r'原始变更：(.+)$').firstMatch(prompt);
        return '写手$slot 登记：${m?.group(1) ?? prompt}';
      },
    );
    expect(issues, isEmpty, reason: '全部精确命中，不应有 issue：$issues');

    expect((await chars()).single.history, contains('拜入玄穹宗'));
    expect((await chars()).single.history, contains('[团队更新]'));
    expect((await worlds()).single.history, contains('宗门禁地开启'));
    expect((await factions()).single.notes, contains('外门新增十名弟子'));
    expect((await plots()).single.notes, contains('试炼完成'));
    expect((await events()).single.description, contains('末位成绩通过试炼'));
  });

  test('update 名称不精确匹配 → 防幻觉跳过并记录', () async {
    final List<String> issues = await svc().dispatchUpdates(
      projectId: projectId,
      items: <Map<String, Object?>>[
        <String, Object?>{
          'target': 'character', 'action': 'update', 'name': '叶知秋儿',
          'field': 'status', 'content': '重伤',
        },
        <String, Object?>{
          'target': 'faction', 'action': 'create', 'name': '魔渊教',
          'field': 'notes', 'content': '新势力',
        },
      ],
      writerChat: (int slot, String prompt) async => '任意产出',
    );
    expect(issues, hasLength(2));
    expect(issues[0], contains('防幻觉'));
    expect(issues[1], contains('人工确认'), reason: '势力不开放 create');
    expect((await factions()).length, 1, reason: '魔渊教不应被插入');
  });

  test('create：新人物 / 新世界设定 / 新时间线（剧情事件）', () async {
    final List<String> issues = await svc().dispatchUpdates(
      projectId: projectId,
      items: <Map<String, Object?>>[
        <String, Object?>{
          'target': 'character', 'action': 'create', 'name': '苏轻语',
          'field': 'notes', 'content': '宗门师姐，剑道天才',
        },
        <String, Object?>{
          'target': 'world', 'action': 'create', 'name': '藏经阁',
          'field': 'content', 'content': '宗门藏典之地，共九层',
        },
        <String, Object?>{
          'target': 'timeline', 'action': 'create', 'name': '藏经阁选典',
          'field': 'description', 'content': '主角入选第一批观典弟子',
        },
      ],
      writerChat: (int slot, String prompt) async => '',
    );
    expect(issues, isEmpty, reason: 'create 不需要精确匹配：$issues');

    expect((await chars()).map((CharacterRow c) => c.name), contains('苏轻语'));
    expect((await worlds()).map((WorldSettingRow w) => w.name), contains('藏经阁'));
    final List<TimelineEventRow> evts = await events();
    expect(evts.map((TimelineEventRow e) => e.title), contains('藏经阁选典'));
    expect(evts.where((TimelineEventRow e) => e.title == '藏经阁选典').single.category,
        '剧情事件');
  });

  test('非法项跳过 + 条数封顶 + 写手空产出回落组长 content', () async {
    final List<Map<String, Object?>> items = <Map<String, Object?>>[
      <String, Object?>{
        'target': 'character', 'action': 'update', 'name': '', 'field': 'notes',
        'content': '空名非法',
      },
      <String, Object?>{
        'target': 'magic', 'action': 'update', 'name': 'x', 'field': 'notes',
        'content': '未知目标',
      },
    ];
    for (int i = 1; i <= 5; i++) {
      items.add(<String, Object?>{
        'target': 'character', 'action': 'create', 'name': '新弟子$i',
        'field': 'notes', 'content': '第 $i 位新弟子',
      });
    }
    final List<String> issues = await svc(maxItems: 3).dispatchUpdates(
      projectId: projectId,
      items: items,
      writerChat: (int slot, String prompt) async => '',
    );
    expect(issues.join('；'), contains('格式非法'));
    expect(issues.join('；'), contains('超上限 3'));
    final List<CharacterRow> rows = await chars();
    expect(rows.length, 4, reason: '原有 1 人 + 截断后 3 条 create');
    expect(rows.map((CharacterRow c) => c.name), contains('新弟子3'),
        reason: '写手空产出时回落组长 content 落库');
  });
}
