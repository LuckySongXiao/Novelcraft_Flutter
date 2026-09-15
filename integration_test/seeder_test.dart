import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novelcraft/core/di.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';

class _InMemoryKeyValueStore implements KeyValueStore {
  final _data = <String, Map<String, String>>{};

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
      _data[scope]?.keys.toList() ?? const [];
}

Future<Map<String, int>> _counts(AppDatabase db) async {
  final r = <String, int>{};

  Future<int> count<T extends HasResultSet, V>(
      ResultSetImplementation<T, V> table,
      Expression<int> Function(T columns) _) async {
    final countExpr = countAll();
    final q = db.selectOnly(table)..addColumns([countExpr]);
    final row = await q.getSingle();
    final val = row.read(countExpr);
    if (val is int) return val;
    return 0;
  }

  r['projects'] = await count(db.projects, (_) => countAll());
  r['volumes'] = await count(db.volumes, (_) => countAll());
  r['chapters'] = await count(db.chapters, (_) => countAll());
  r['races'] = await count(db.races, (_) => countAll());
  r['raceRelationships'] = await count(db.raceRelationships, (_) => countAll());
  r['factions'] = await count(db.factions, (_) => countAll());
  r['factionRelationships'] =
      await count(db.factionRelationships, (_) => countAll());
  r['resources'] = await count(db.resources, (_) => countAll());
  r['secretRealms'] = await count(db.secretRealms, (_) => countAll());
  r['resourceSecretRealmEntries'] =
      await count(db.resourceSecretRealmEntries, (_) => countAll());
  r['cultivationSystems'] = await count(db.cultivationSystems, (_) => countAll());
  r['cultivationLevels'] = await count(db.cultivationLevels, (_) => countAll());
  r['politicalSystems'] = await count(db.politicalSystems, (_) => countAll());
  r['politicalPositions'] = await count(db.politicalPositions, (_) => countAll());
  r['currencySystems'] = await count(db.currencySystems, (_) => countAll());
  r['currencySystemFactionEntries'] =
      await count(db.currencySystemFactionEntries, (_) => countAll());
  r['plots'] = await count(db.plots, (_) => countAll());
  r['characters'] = await count(db.characters, (_) => countAll());
  r['characterEvents'] = await count(db.characterEvents, (_) => countAll());
  r['characterRelationships'] =
      await count(db.characterRelationships, (_) => countAll());
  r['relationshipNetworks'] =
      await count(db.relationshipNetworks, (_) => countAll());
  r['characterNetworkEntries'] =
      await count(db.characterNetworkEntries, (_) => countAll());
  r['characterPlotEntries'] =
      await count(db.characterPlotEntries, (_) => countAll());
  r['chapterPlotEntries'] =
      await count(db.chapterPlotEntries, (_) => countAll());
  r['worldSettings'] = await count(db.worldSettings, (_) => countAll());
  r['timelineEvents'] = await count(db.timelineEvents, (_) => countAll());
  r['timelineEventParticipants'] =
      await count(db.timelineEventParticipants, (_) => countAll());

  return r;
}

const expected = <String, int>{
  'projects': 1,
  'volumes': 1,
  'chapters': 2,
  'races': 2,
  'raceRelationships': 1,
  'factions': 2,
  'factionRelationships': 1,
  'resources': 2,
  'secretRealms': 1,
  'resourceSecretRealmEntries': 2,
  'cultivationSystems': 1,
  'cultivationLevels': 3,
  'politicalSystems': 1,
  'politicalPositions': 2,
  'currencySystems': 1,
  'currencySystemFactionEntries': 2,
  'plots': 2,
  'characters': 3,
  'characterEvents': 2,
  'characterRelationships': 2,
  'relationshipNetworks': 1,
  'characterNetworkEntries': 3,
  'characterPlotEntries': 3,
  'chapterPlotEntries': 2,
  'worldSettings': 8,
  'timelineEvents': 2,
  'timelineEventParticipants': 2,
};

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseSeeder 集成测试（玄穹剑主模板）', () {
    late AppDatabase db;
    late _InMemoryKeyValueStore store;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = _InMemoryKeyValueStore();
      container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        keyValueStoreProvider.overrideWith((_) async => store),
      ]);
    });

    tearDown(() async {
      await db.close();
      container.dispose();
    });

    test('Round 1: 首次 ensureSeeded 真写入（return true + KV seeded-v1 + 27表 count 匹配）',
        () async {
      final seeder = container.read(databaseSeederProvider);
      final did = await seeder.ensureSeeded();
      expect(did, isTrue);

      final v = await store.readJson('internal', 'seed_version');
      expect(v, 'seeded-v1');

      final counts = await _counts(db);
      for (final e in expected.entries) {
        expect(counts[e.key], e.value, reason: '表 ${e.key} 行数 mismatch');
      }

      final demo = await (db.select(db.projects)
            ..where((p) => p.id.equals('demo-xuanqiong')))
          .getSingle();
      expect(demo.name, '示例项目 · 玄穹剑主');
      expect(demo.type, 'novel');
    });

    test('Round 2-4: 重复 ensureSeeded 三次 = false + count 不变（幂等）', () async {
      final s1 = container.read(databaseSeederProvider);
      final did1 = await s1.ensureSeeded();
      expect(did1, isTrue);

      for (var i = 2; i <= 4; i++) {
        final sN = container.read(databaseSeederProvider);
        final didN = await sN.ensureSeeded();
        expect(didN, isFalse, reason: '第 $i 次重复 seed 应为 false');
        final cN = await _counts(db);
        for (final e in expected.entries) {
          expect(cN[e.key], e.value,
              reason: '第 $i 次幂等后表 ${e.key} 不应变化');
        }
      }

      final v = await store.readJson('internal', 'seed_version');
      expect(v, 'seeded-v1');
    });

    // PITFALLS §15 双保险：清 KV 但项目表仍有行 → 不能再插一次示例项目
    test('Round 5: KV 被清空但库中已有项目 → 双保险挡住，不重复插入', () async {
      final s1 = container.read(databaseSeederProvider);
      expect(await s1.ensureSeeded(), isTrue);
      final before = await _counts(db);

      // 模拟「用户清 KV / 换 KV 存储」：删掉 seed_version 标记，但数据库还在
      await store.remove('internal', 'seed_version');
      expect(await store.readJson('internal', 'seed_version'), equals(null));

      final s2 = container.read(databaseSeederProvider);
      final did2 = await s2.ensureSeeded();
      expect(did2, isFalse, reason: '库中已有项目时双保险应挡住重复 seeding');

      final after = await _counts(db);
      for (final e in expected.entries) {
        expect(after[e.key], before[e.key],
            reason: '双保险挡住后表 ${e.key} 行数不应变化');
      }
      // 命中条件 2 时应回填 KV 标记，避免每次启动都探测
      expect(await store.readJson('internal', 'seed_version'), 'seeded-v1');
    });
  });
}
