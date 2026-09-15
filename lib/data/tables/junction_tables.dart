import 'package:drift/drift.dart';

import 'character_tables.dart';
import 'faction_tables.dart';
import 'project_tables.dart';
import 'world_tables.dart';
import 'worldbuilding_tables.dart';

/// 多对多联结表集合
///
/// ⚠ 这些表在 C# 版本中是 **不存在的** —— EF Core 会依据导航属性
/// （如 Plot 上的 RelatedCharacters 集合）自动在迁移里建表并命名
/// （CharacterPlot / ChapterPlot / ResourceSecretRealm / CurrencySystemFaction /
/// CharacterRelationshipNetwork）。drift 不做隐式导航，必须显式定义。
///
/// 每张表都用双外键构成复合主键，天然防重复，且两侧删除都级联清理关联。

/// Plot.RelatedCharacters ↔ Character.RelatedPlots
@DataClassName('CharacterPlotEntry')
class CharacterPlotEntries extends Table {
  TextColumn get plotId =>
      text().references(Plots, #id, onDelete: KeyAction.cascade)();
  TextColumn get characterId =>
      text().references(Characters, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {plotId, characterId};
}

/// Plot.InvolvedChapters ↔ Chapter.InvolvedPlots
///
/// 注意区分：Chapter ↔ Plot 之间共存在 **3 条** 不同关系，本表只承接"涉及章节"；
/// 另外两条由 Plots.startChapterId / Plots.endChapterId 外键表达。
@DataClassName('ChapterPlotEntry')
class ChapterPlotEntries extends Table {
  TextColumn get plotId =>
      text().references(Plots, #id, onDelete: KeyAction.cascade)();
  TextColumn get chapterId =>
      text().references(Chapters, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {plotId, chapterId};
}

/// SecretRealm.RelatedResources ↔ Resource
///
/// ⚠ C# 版本中这条关系是「半残」的：SecretRealm 有 RelatedResources 导航属性，
/// 但 Resource 侧没有反向导航也没有 SecretRealmId 外键，
/// 因此原实现**无法真正持久化**这条关系。此处补一对显式联结表使其可用。
@DataClassName('ResourceSecretRealmEntry')
class ResourceSecretRealmEntries extends Table {
  TextColumn get secretRealmId =>
      text().references(SecretRealms, #id, onDelete: KeyAction.cascade)();
  TextColumn get resourceId =>
      text().references(Resources, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {secretRealmId, resourceId};
}

/// CurrencySystem.UsingFactions ↔ Faction.UsedCurrencySystems
@DataClassName('CurrencySystemFactionEntry')
class CurrencySystemFactionEntries extends Table {
  TextColumn get currencySystemId =>
      text().references(CurrencySystems, #id, onDelete: KeyAction.cascade)();
  TextColumn get factionId =>
      text().references(Factions, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {currencySystemId, factionId};
}

/// RelationshipNetwork.Members ↔ Character.ParticipatedNetworks
///
/// C# 侧中心人物还额外有一条关系：Character.CentralNetworks ↔
/// RelationshipNetwork.centralCharacterId，那条走的是外键而非本表。
@DataClassName('CharacterNetworkEntry')
class CharacterNetworkEntries extends Table {
  TextColumn get networkId =>
      text().references(RelationshipNetworks, #id, onDelete: KeyAction.cascade)();
  TextColumn get characterId =>
      text().references(Characters, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {networkId, characterId};
}
