import 'package:drift/drift.dart';

import 'audit.dart';
import 'faction_tables.dart';
import 'project_tables.dart';

/// 剧情 —— 对应 Core/Entities/Plot.cs
///
/// 与 Chapter 之间存在 3 条不同关系：
///  - 起始章节：Plot.startChapterId
///  - 结束章节：Plot.endChapterId
///  - 涉及章节：多对多，走 [ChapterPlotEntries] 联结表
@DataClassName('PlotRow')
class Plots extends Table with AuditFields {
  TextColumn get title => text().withLength(min: 1, max: 200)();

  /// 主线 / 支线 / 暗线 / 伏笔
  TextColumn get type => text().withLength(min: 1, max: 50)();

  /// 规划中 / 进行中 / 已完成 / 暂停
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('规划中'))();

  /// 高 / 中 / 低
  TextColumn get priority =>
      text().withLength(min: 1, max: 20).withDefault(const Constant('中'))();

  /// 进度百分比，C# 为 decimal
  RealColumn get progress => real().withDefault(const Constant(0.0))();

  /// 起始章节。Chapter↔Plot 共 3 条关系之一，两条外键需要不同 @ReferenceName
  /// 以免 manager 生成的反向引用重名
  @ReferenceName('plotsAsStart')
  TextColumn get startChapterId =>
      text().nullable().references(Chapters, #id, onDelete: KeyAction.setNull)();

  @ReferenceName('plotsAsEnd')
  TextColumn get endChapterId =>
      text().nullable().references(Chapters, #id, onDelete: KeyAction.setNull)();
  TextColumn get description => text().nullable()();
  TextColumn get outline => text().nullable()();
  TextColumn get conflictElements => text().nullable()();
  TextColumn get themeElements => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(5))();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  IntColumn get estimatedWordCount => integer().nullable()();
  IntColumn get actualWordCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 种族 —— 对应 Core/Entities/Race.cs
@DataClassName('RaceRow')
class Races extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// 人类 / 精灵 / 魔法 / 兽族 / 元素 / 不死 / 修罗 / 灵异 / 神族
  TextColumn get type => text().withLength(min: 1, max: 50)();

  /// 人口数。C# 为 long，Dart int 本身是 64 位
  IntColumn get population => integer().withDefault(const Constant(0))();
  TextColumn get mainTerritory => text().nullable().withLength(max: 500)();
  TextColumn get rulingArea => text().nullable()();
  IntColumn get powerLevel => integer().withDefault(const Constant(5))();
  IntColumn get influence => integer().withDefault(const Constant(5))();

  /// 繁荣 / 稳定 / 衰落 / 濒危 / 灭绝
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('稳定'))();

  TextColumn get characteristics => text().nullable()();
  TextColumn get culturalBackground => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(5))();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  IntColumn get averageLifespan => integer().nullable()();

  /// 生育率，C# 为 decimal?
  RealColumn get birthRate => real().nullable()();
  TextColumn get primaryLanguage => text().nullable().withLength(max: 100)();
  TextColumn get primaryReligion => text().nullable().withLength(max: 100)();
  TextColumn get racialAbilities => text().nullable()();
  TextColumn get racialWeaknesses => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 种族关系 —— 对应 Core/Entities/RaceRelationship.cs（本实体自带 ProjectId）
@DataClassName('RaceRelationshipRow')
class RaceRelationships extends Table with AuditFields {
  @ReferenceName('relationshipsAsSource')
  TextColumn get sourceRaceId =>
      text().references(Races, #id, onDelete: KeyAction.cascade)();

  @ReferenceName('relationshipsAsTarget')
  TextColumn get targetRaceId =>
      text().references(Races, #id, onDelete: KeyAction.noAction)();

  /// 盟友 / 敌对 / 中立 / 附庸 / 宗主
  TextColumn get relationshipType => text().withLength(min: 1, max: 50)();

  /// 关系强度 1-10
  IntColumn get strength => integer().withDefault(const Constant(5))();

  /// 稳定 / 紧张 / 恶化 / 改善 / 破裂
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('稳定'))();

  TextColumn get description => text().nullable()();
  TextColumn get history => text().nullable()();
  TextColumn get keyEvents => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(5))();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get establishedDate => dateTime().nullable()();
  DateTimeColumn get lastUpdatedDate => dateTime().nullable()();
  BoolColumn get isPublic => boolean().withDefault(const Constant(true))();
  BoolColumn get isMutual => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 资源 —— 对应 Core/Entities/Resource.cs
@DataClassName('ResourceRow')
class Resources extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 200)();

  /// 矿脉 / 灵脉 / 龙脉 / 草药 / 灵兽 / 水源 / 人口 / 装备 / 灵宝
  TextColumn get type => text().withLength(min: 1, max: 50)();
  TextColumn get location => text().nullable().withLength(max: 500)();

  /// 控制势力，势力删除置空
  TextColumn get controllingFactionId => text()
      .nullable()
      .references(Factions, #id, onDelete: KeyAction.setNull)();

  /// 普通 / 不常见 / 稀有 / 史诗 / 传说
  TextColumn get rarity =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('普通'))();

  IntColumn get extractionDifficulty =>
      integer().withDefault(const Constant(5))();
  IntColumn get economicValue => integer().withDefault(const Constant(5))();

  /// 极慢 / 缓慢 / 中等 / 快速 / 极快
  TextColumn get regenerationSpeed =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('中等'))();

  /// 活跃 / 濒临枯竭 / 枯竭 / 废弃 / 受保护 / 争夺中
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('活跃'))();

  TextColumn get description => text().nullable()();
  TextColumn get extractionMethod => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(5))();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();

  /// 以下三个储量字段 C# 为 long?
  IntColumn get currentReserves => integer().nullable()();
  IntColumn get maxReserves => integer().nullable()();
  IntColumn get annualOutput => integer().nullable()();

  DateTimeColumn get discoveryDate => dateTime().nullable()();
  DateTimeColumn get lastExtractionDate => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 秘境 —— 对应 Core/Entities/SecretRealm.cs（全项目字段最多的实体，27 个）
@DataClassName('SecretRealmRow')
class SecretRealms extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 200)();

  /// 地下城 / 豢兽乐园 / 祭天法坛 / 野兽森林 / 海妖诞生地 / 天庭碎片 / 佛陀道场 / 菩萨道场 / 小酆都
  TextColumn get type => text().withLength(min: 1, max: 50)();
  TextColumn get location => text().nullable().withLength(max: 500)();

  /// 发现者势力，势力删除置空
  TextColumn get discovererFactionId => text()
      .nullable()
      .references(Factions, #id, onDelete: KeyAction.setNull)();

  IntColumn get dangerLevel => integer().withDefault(const Constant(5))();
  IntColumn get capacityLimit => integer().nullable()();

  /// 时间限制（小时）
  IntColumn get timeLimit => integer().nullable()();
  TextColumn get recommendedCultivation =>
      text().nullable().withLength(max: 100)();

  /// 开放 / 封印 / 毁坏 / 隐藏
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('隐藏'))();

  TextColumn get explorationConditions => text().nullable()();
  TextColumn get explorationRewards => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get strategy => text().nullable()();
  DateTimeColumn get lastExplorationDate => dateTime().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(5))();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get discoveryDate => dateTime().nullable()();
  DateTimeColumn get openDate => dateTime().nullable()();
  DateTimeColumn get closeDate => dateTime().nullable()();
  IntColumn get explorationCount => integer().withDefault(const Constant(0))();
  IntColumn get successfulExplorationCount =>
      integer().withDefault(const Constant(0))();
  TextColumn get dimensionInfo => text().nullable().withLength(max: 200)();
  TextColumn get entranceInfo => text().nullable()();
  TextColumn get internalStructure => text().nullable()();
  TextColumn get specialRules => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
