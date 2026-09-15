import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../data/database.dart';

/// 首启动种子数据服务。一次写入，幂等可重入。
///
/// 版本标记写在 KeyValueStore(scope=internal, key=seed_version)。
/// 版本值变化时会跳过已有库再次插入，不影响「已种过一次」的老用户。
///
/// 策略：每表至少 1 行，多态 2-3 行，严格按 database.g.dart 每张表的
/// `XxxCompanion.insert({required String a, this.b=const Value.absent()})`
/// 签名构造 —— 裸值 required 字段直接传，可选字段不写让它走 Value.absent()。
class DatabaseSeeder {
  DatabaseSeeder(this.ref);

  final Ref ref;
  static const kSeedVersion = 'seeded-v1';
  static const kScope = 'internal';
  static const kSeedKey = 'seed_version';

  /// 执行一次幂等的种子数据写入；返回 true 表示本次真的写入了。
  ///
  /// PITFALLS §15 双保险：**两个条件同时为假**才写入 ——
  ///   1. KVStore(internal/seed_version) != 'seeded-v1'（已成功 seed 过 → 跳过）
  ///   2. 项目表活跃行数 == 0（用户自己建过项目 / 已有任何项目 → 跳过）
  /// 只做 KV 标记，一旦用户删库+清 KV（卸载重装 / Web 清 localStorage）
  /// 就会重复插入示例项目；只做项目计数，用户首启动没等 seeding 跑完
  /// 就手建项目会跳过 seeding。二者缺一不可。
  Future<bool> ensureSeeded() async {
    final store = await ref.watch(keyValueStoreProvider.future);
    final existing = await store.readJson(kScope, kSeedKey);
    if (existing == kSeedVersion) return false;

    // 双保险条件 2：库里已有任何项目（无论示例还是用户自建）就不再 seed
    final projectRepo = ref.watch(projectRepositoryProvider);
    if ((await projectRepo.countActive()) > 0) {
      // 已有项目但无 KV 标记（老库升级 / 用户手删 KV）→ 补写标记，避免每次启动都探测
      await store.writeJson(kScope, kSeedKey, kSeedVersion);
      return false;
    }

    final db = ref.watch(databaseProvider);
    await db.transaction(() async {
      await db.batch((batch) {

      // ------------------------------------------------------------------
      // 0. 项目根（1 条）—— 其他所有实体引用的 projectId 都指向它
      // ------------------------------------------------------------------
      const pid = 'demo-xuanqiong';
      batch.insert(db.projects, ProjectsCompanion.insert(
        id: pid,
        name: '示例项目 · 玄穹剑主',
        type: 'novel',
      ));

      // ------------------------------------------------------------------
      // 1. 卷宗 / 章节（卷 1 + 章 2）
      // ------------------------------------------------------------------
      const vid = 'demo-xuanqiong-v1';
      batch.insert(db.volumes, VolumesCompanion.insert(
        id: vid,
        title: '第一卷 · 玄穹初启',
        projectId: pid,
      ));

      const cid1 = 'demo-xuanqiong-c1';
      const cid2 = 'demo-xuanqiong-c2';
      batch.insert(db.chapters, ChaptersCompanion.insert(
        id: cid1,
        title: '第一章 · 少年出乡',
        volumeId: vid,
      ));
      batch.insert(db.chapters, ChaptersCompanion.insert(
        id: cid2,
        title: '第二章 · 古洞奇遇',
        volumeId: vid,
      ));

      // ------------------------------------------------------------------
      // 2. 种族（人族 + 妖族 + 关系对立）
      // ------------------------------------------------------------------
      const ridHuman = 'demo-race-human';
      const ridYao = 'demo-race-yao';
      batch.insert(db.races, RacesCompanion.insert(
        id: ridHuman,
        name: '人族',
        type: 'mortal',
        projectId: pid,
      ));
      batch.insert(db.races, RacesCompanion.insert(
        id: ridYao,
        name: '妖族',
        type: 'celestial',
        projectId: pid,
      ));
      batch.insert(db.raceRelationships, RaceRelationshipsCompanion.insert(
        id: 'demo-rrel-hy',
        sourceRaceId: ridHuman,
        targetRaceId: ridYao,
        relationshipType: 'rivalry',
        projectId: pid,
      ));

      // ------------------------------------------------------------------
      // 3. 势力（玄穹剑宗 + 万妖盟 + 关系敌对）
      // ------------------------------------------------------------------
      const fidXqjz = 'demo-fac-xqjz';
      const fidWym = 'demo-fac-wym';
      batch.insert(db.factions, FactionsCompanion.insert(
        id: fidXqjz,
        name: '玄穹剑宗',
        type: 'sect',
        projectId: pid,
      ));
      batch.insert(db.factions, FactionsCompanion.insert(
        id: fidWym,
        name: '万妖盟',
        type: 'alliance',
        projectId: pid,
      ));
      batch.insert(db.factionRelationships, FactionRelationshipsCompanion.insert(
        id: 'demo-frel-xq-wy',
        sourceFactionId: fidXqjz,
        targetFactionId: fidWym,
        relationshipType: 'hostile',
      ));

      // ------------------------------------------------------------------
      // 4. 资源 + 秘境 + 关联
      // ------------------------------------------------------------------
      const rLingshi = 'demo-res-lingshi';
      const rTietie = 'demo-res-tietie';
      batch.insert(db.resources, ResourcesCompanion.insert(
        id: rLingshi,
        name: '灵石',
        type: 'currency_material',
        projectId: pid,
      ));
      batch.insert(db.resources, ResourcesCompanion.insert(
        id: rTietie,
        name: '玄铁',
        type: 'forge_material',
        projectId: pid,
      ));
      const sTaixu = 'demo-sr-taixu';
      batch.insert(db.secretRealms, SecretRealmsCompanion.insert(
        id: sTaixu,
        name: '太虚秘境',
        type: 'ruins',
        projectId: pid,
      ));
      batch.insert(db.resourceSecretRealmEntries, ResourceSecretRealmEntriesCompanion.insert(
        secretRealmId: sTaixu,
        resourceId: rLingshi,
      ));
      batch.insert(db.resourceSecretRealmEntries, ResourceSecretRealmEntriesCompanion.insert(
        secretRealmId: sTaixu,
        resourceId: rTietie,
      ));

      // ------------------------------------------------------------------
      // 5. 修炼体系 + 三层境界
      // ------------------------------------------------------------------
      const sysXuanqiong = 'demo-cs-xuanqiong';
      batch.insert(db.cultivationSystems, CultivationSystemsCompanion.insert(
        id: sysXuanqiong,
        name: '玄穹剑道',
        type: 'sword',
        projectId: pid,
      ));
      const lvQi = 'demo-cl-lianqi';
      const lvZhu = 'demo-cl-zhuji';
      const lvJin = 'demo-cl-jindan';
      batch.insert(db.cultivationLevels, CultivationLevelsCompanion.insert(
        id: lvQi,
        name: '练气期',
        cultivationSystemId: sysXuanqiong,
      ));
      batch.insert(db.cultivationLevels, CultivationLevelsCompanion.insert(
        id: lvZhu,
        name: '筑基期',
        cultivationSystemId: sysXuanqiong,
      ));
      batch.insert(db.cultivationLevels, CultivationLevelsCompanion.insert(
        id: lvJin,
        name: '金丹期',
        cultivationSystemId: sysXuanqiong,
      ));

      // ------------------------------------------------------------------
      // 6. 政治体系 + 两官职
      // ------------------------------------------------------------------
      const psXuanhuang = 'demo-ps-xuanhuang';
      batch.insert(db.politicalSystems, PoliticalSystemsCompanion.insert(
        id: psXuanhuang,
        name: '玄皇朝',
        type: 'empire',
        projectId: pid,
      ));
      batch.insert(db.politicalPositions, PoliticalPositionsCompanion.insert(
        id: 'demo-pp-emperor',
        name: '皇帝',
        politicalSystemId: psXuanhuang,
      ));
      batch.insert(db.politicalPositions, PoliticalPositionsCompanion.insert(
        id: 'demo-pp-general',
        name: '镇国大将军',
        politicalSystemId: psXuanhuang,
      ));

      // ------------------------------------------------------------------
      // 7. 货币体系 + 两势力挂载
      // ------------------------------------------------------------------
      const csLingqian = 'demo-cs-lingqian';
      batch.insert(db.currencySystems, CurrencySystemsCompanion.insert(
        id: csLingqian,
        name: '灵钱通宝',
        monetarySystem: 'commodity_standard',
        projectId: pid,
      ));
      batch.insert(db.currencySystemFactionEntries, CurrencySystemFactionEntriesCompanion.insert(
        currencySystemId: csLingqian,
        factionId: fidXqjz,
      ));
      batch.insert(db.currencySystemFactionEntries, CurrencySystemFactionEntriesCompanion.insert(
        currencySystemId: csLingqian,
        factionId: fidWym,
      ));

      // ------------------------------------------------------------------
      // 8. 情节主线 / 副线
      // ------------------------------------------------------------------
      const plMain = 'demo-plot-main';
      const plSub = 'demo-plot-sub';
      batch.insert(db.plots, PlotsCompanion.insert(
        id: plMain,
        title: '少年复仇 · 剑宗崛起',
        type: 'main',
        projectId: pid,
      ));
      batch.insert(db.plots, PlotsCompanion.insert(
        id: plSub,
        title: '太虚秘境寻宝',
        type: 'sub',
        projectId: pid,
      ));

      // ------------------------------------------------------------------
      // 9. 人物 3 位 + 事件 2 + 人物关系 2
      // ------------------------------------------------------------------
      const cLinYue = 'demo-ch-linyue';
      const cYeChen = 'demo-ch-yechen';
      const cYaoHuang = 'demo-ch-yaohuang';
      batch.insert(db.characters, CharactersCompanion.insert(
        id: cLinYue,
        name: '林月',
        type: 'protagonist',
        projectId: pid,
      ));
      batch.insert(db.characters, CharactersCompanion.insert(
        id: cYeChen,
        name: '叶辰',
        type: 'mentor',
        projectId: pid,
      ));
      batch.insert(db.characters, CharactersCompanion.insert(
        id: cYaoHuang,
        name: '妖皇',
        type: 'antagonist',
        projectId: pid,
      ));

      batch.insert(db.characterEvents, CharacterEventsCompanion.insert(
        id: 'demo-ce-ly-1',
        characterId: cLinYue,
        title: '林月拜入玄穹剑宗',
      ));
      batch.insert(db.characterEvents, CharacterEventsCompanion.insert(
        id: 'demo-ce-yh-1',
        characterId: cYaoHuang,
        title: '妖皇破关·兵临剑宗',
      ));

      batch.insert(db.characterRelationships, CharacterRelationshipsCompanion.insert(
        id: 'demo-crel-ly-yc',
        sourceCharacterId: cLinYue,
        targetCharacterId: cYeChen,
        relationshipType: 'master_apprentice',
      ));
      batch.insert(db.characterRelationships, CharacterRelationshipsCompanion.insert(
        id: 'demo-crel-ly-yh',
        sourceCharacterId: cLinYue,
        targetCharacterId: cYaoHuang,
        relationshipType: 'enemy',
      ));

      // ------------------------------------------------------------------
      // 10. 关系网络 + 3 角色入网
      // ------------------------------------------------------------------
      const netMain = 'demo-rn-main';
      batch.insert(db.relationshipNetworks, RelationshipNetworksCompanion.insert(
        id: netMain,
        name: '玄穹三界关系网',
        type: 'social',
        projectId: pid,
      ));
      batch.insert(db.characterNetworkEntries, CharacterNetworkEntriesCompanion.insert(
        networkId: netMain,
        characterId: cLinYue,
      ));
      batch.insert(db.characterNetworkEntries, CharacterNetworkEntriesCompanion.insert(
        networkId: netMain,
        characterId: cYeChen,
      ));
      batch.insert(db.characterNetworkEntries, CharacterNetworkEntriesCompanion.insert(
        networkId: netMain,
        characterId: cYaoHuang,
      ));

      // ------------------------------------------------------------------
      // 11. 情节联结：人物×情节、章节×情节
      // ------------------------------------------------------------------
      batch.insert(db.characterPlotEntries, CharacterPlotEntriesCompanion.insert(
        plotId: plMain,
        characterId: cLinYue,
      ));
      batch.insert(db.characterPlotEntries, CharacterPlotEntriesCompanion.insert(
        plotId: plMain,
        characterId: cYaoHuang,
      ));
      batch.insert(db.characterPlotEntries, CharacterPlotEntriesCompanion.insert(
        plotId: plSub,
        characterId: cLinYue,
      ));
      batch.insert(db.chapterPlotEntries, ChapterPlotEntriesCompanion.insert(
        plotId: plMain,
        chapterId: cid1,
      ));
      batch.insert(db.chapterPlotEntries, ChapterPlotEntriesCompanion.insert(
        plotId: plSub,
        chapterId: cid2,
      ));

      // ------------------------------------------------------------------
      // 12. 世界观设定 8 条（对应 10 JSON 体系页里的 8 条，走数据库 WorldSettings）
      // ------------------------------------------------------------------
      final worlds = <({String id, String name, String type})>[
        (id: 'demo-ws-world', name: '三界概览', type: 'geography'),
        (id: 'demo-ws-power', name: '力量体系', type: 'cultivation'),
        (id: 'demo-ws-force', name: '势力分布', type: 'factions'),
        (id: 'demo-ws-race', name: '万族林立', type: 'races'),
        (id: 'demo-ws-money', name: '货币制度', type: 'economy'),
        (id: 'demo-ws-map', name: '玄黄大陆地图', type: 'map'),
        (id: 'demo-ws-pet', name: '灵兽录', type: 'pets'),
        (id: 'demo-ws-treasure', name: '灵宝谱', type: 'treasures'),
      ];
      for (final w in worlds) {
        batch.insert(db.worldSettings, WorldSettingsCompanion.insert(
          id: w.id,
          name: w.name,
          type: w.type,
          projectId: pid,
        ));
      }

      // ------------------------------------------------------------------
      // 13. 时间线 2 件大事 + 参与者
      // ------------------------------------------------------------------
      const te1 = 'demo-te-c1';
      const te2 = 'demo-te-c2';
      batch.insert(db.timelineEvents, TimelineEventsCompanion.insert(
        id: te1,
        projectId: pid,
        title: '林月拜入剑宗',
        eventDate: DateTime(321, 1, 15),
      ));
      batch.insert(db.timelineEvents, TimelineEventsCompanion.insert(
        id: te2,
        projectId: pid,
        title: '妖皇破关大战',
        eventDate: DateTime(321, 9, 9),
      ));
      batch.insert(db.timelineEventParticipants, TimelineEventParticipantsCompanion.insert(
        id: 'demo-tep-ly',
        timelineEventId: te1,
        name: '林月',
      ));
      batch.insert(db.timelineEventParticipants, TimelineEventParticipantsCompanion.insert(
        id: 'demo-tep-yh',
        timelineEventId: te2,
        name: '妖皇',
      ));

      });
    });

    await store.writeJson(kScope, kSeedKey, kSeedVersion);
    return true;
  }
}
