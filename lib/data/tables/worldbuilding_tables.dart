import 'package:drift/drift.dart';

import 'audit.dart';
import 'character_tables.dart';
import 'project_tables.dart';

/// 世界设定 —— 对应 Core/Entities/WorldSetting.cs（自引用树形层级）
///
/// ⚠ 关键陷阱：C# 版本用 `public new string? Version { get; set; }`
/// **隐藏**了 BaseEntity 的 `byte[] Version`（EF 行版本）。
/// Dart 没有成员隐藏语义，因此这里必须改名为 `settingVersion`，
/// 否则会与 [AuditFields.version]（乐观锁整数）产生不可预期的冲突。
@DataClassName('WorldSettingRow')
class WorldSettings extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get type => text().withLength(min: 1, max: 50)();
  TextColumn get category => text().nullable().withLength(max: 50)();
  TextColumn get description => text().nullable()();
  TextColumn get content => text().nullable()();
  TextColumn get rules => text().nullable()();
  TextColumn get history => text().nullable()();
  TextColumn get relatedSettings => text().nullable()();
  IntColumn get importance => integer().withDefault(const Constant(1))();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  /// 父级设定（自引用树），删除父级时 Restrict
  TextColumn get parentId => text()
      .nullable()
      .references(WorldSettings, #id, onDelete: KeyAction.noAction)();

  TextColumn get imagePath => text().nullable().withLength(max: 500)();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  TextColumn get status =>
      text().withLength(max: 50).withDefault(const Constant('Active'))();

  /// 排序索引（C# 为 `Order`）
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();
  BoolColumn get isPublic => boolean().withDefault(const Constant(true))();

  /// 设定版本标签。C# 中为隐藏基类的 `new string? Version`
  TextColumn get settingVersion => text().nullable().withLength(max: 20)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 修炼体系 —— 对应 Core/Entities/CultivationSystem.cs
@DataClassName('CultivationSystemRow')
class CultivationSystems extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get type => text().withLength(min: 1, max: 50)();
  IntColumn get difficulty => integer().withDefault(const Constant(50))();
  IntColumn get maxLevel => integer().withDefault(const Constant(10))();
  TextColumn get description => text().nullable()();
  TextColumn get cultivationMethod => text().nullable()();
  TextColumn get realmDivision => text().nullable()();
  TextColumn get breakthroughConditions => text().nullable()();
  TextColumn get cultivationResources => text().nullable()();
  TextColumn get characteristics => text().nullable()();
  TextColumn get risks => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(1))();
  TextColumn get imagePath => text().nullable().withLength(max: 500)();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  TextColumn get status =>
      text().withLength(max: 50).withDefault(const Constant('Active'))();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 修炼等级 —— 对应 Core/Entities/CultivationLevel.cs
@DataClassName('CultivationLevelRow')
class CultivationLevels extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();
  TextColumn get description => text().nullable()();
  TextColumn get breakthroughCondition => text().nullable()();
  TextColumn get abilities => text().nullable()();

  /// 修炼所需时间描述（自然语言，非数值）
  TextColumn get cultivationTime => text().nullable()();

  TextColumn get cultivationSystemId =>
      text().references(CultivationSystems, #id, onDelete: KeyAction.cascade)();

  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 政治体系 —— 对应 Core/Entities/PoliticalSystem.cs
@DataClassName('PoliticalSystemRow')
class PoliticalSystems extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get type => text().withLength(min: 1, max: 50)();
  TextColumn get hierarchy => text().nullable()();
  IntColumn get stability => integer().withDefault(const Constant(50))();
  IntColumn get influence => integer().withDefault(const Constant(50))();
  TextColumn get description => text().nullable()();
  TextColumn get structure => text().nullable()();
  TextColumn get powerDistribution => text().nullable()();
  TextColumn get legalSystem => text().nullable()();
  TextColumn get electionSystem => text().nullable()();
  TextColumn get administrativeSystem => text().nullable()();
  TextColumn get militarySystem => text().nullable()();
  TextColumn get economicSystem => text().nullable()();
  TextColumn get socialHierarchy => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(1))();
  TextColumn get imagePath => text().nullable().withLength(max: 500)();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  TextColumn get status =>
      text().withLength(max: 50).withDefault(const Constant('Active'))();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 政治职位 —— 对应 Core/Entities/PoliticalPosition.cs
@DataClassName('PoliticalPositionRow')
class PoliticalPositions extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  IntColumn get level => integer().withDefault(const Constant(0))();
  TextColumn get description => text().nullable()();
  TextColumn get powers => text().nullable()();
  TextColumn get responsibilities => text().nullable()();
  TextColumn get requirements => text().nullable()();
  TextColumn get term => text().nullable()();

  TextColumn get politicalSystemId =>
      text().references(PoliticalSystems, #id, onDelete: KeyAction.cascade)();

  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 货币体系 —— 对应 Core/Entities/CurrencySystem.cs
///
/// 含 5 个 JSON 字符串列：CurrencyTypes / ExchangeRates / FinancialServices /
/// EconomicIndicators，以及 Relations 由联结表承接。
@DataClassName('CurrencySystemRow')
class CurrencySystems extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// 金本位制 / 银本位制 / 信用货币制 / 物物交换制 / 灵石货币制 / 混合货币制
  TextColumn get monetarySystem => text().withLength(min: 1, max: 50)();
  TextColumn get type => text().nullable().withLength(max: 50)();
  TextColumn get status => text().nullable().withLength(max: 50)();
  IntColumn get stability => integer().withDefault(const Constant(50))();

  /// 基础价值，C# 为 decimal（默认 1.0m）
  RealColumn get baseValue => real().withDefault(const Constant(1.0))();
  TextColumn get baseCurrency => text().nullable().withLength(max: 100)();

  /// 货币种类（JSON）
  TextColumn get currencyTypes => text().nullable()();

  /// 汇率体系（JSON）
  TextColumn get exchangeRates => text().nullable()();

  TextColumn get issuingAuthority => text().nullable().withLength(max: 200)();

  /// 通胀率，C# 为 decimal?
  RealColumn get inflationRate => real().nullable()();

  /// 利率水平
  RealColumn get interestRate => real().nullable()();

  /// 货币供应量，C# 为 long?
  IntColumn get moneySupply => integer().nullable()();

  /// 汇率波动
  RealColumn get exchangeRateVolatility => real().nullable()();

  /// 金融服务（JSON）
  TextColumn get financialServices => text().nullable()();

  TextColumn get description => text().nullable()();
  TextColumn get historicalBackground => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(5))();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get establishedDate => dateTime().nullable()();
  DateTimeColumn get lastUpdatedDate => dateTime().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get usageScope => text().nullable().withLength(max: 500)();
  TextColumn get regulatoryAuthority =>
      text().nullable().withLength(max: 200)();
  TextColumn get legalFramework => text().nullable()();

  /// 经济指标（JSON）
  TextColumn get economicIndicators => text().nullable()();
  TextColumn get riskAssessment => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 关系网络 —— 对应 Core/Entities/RelationshipNetwork.cs
@DataClassName('RelationshipNetworkRow')
class RelationshipNetworks extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 200)();

  /// 家族网络 / 势力网络 / 朋友圈 / 敌对网络 / 师承网络
  TextColumn get type => text().withLength(min: 1, max: 50)();
  TextColumn get description => text().nullable()();

  /// 中心人物，角色删除置空
  TextColumn get centralCharacterId => text()
      .nullable()
      .references(Characters, #id, onDelete: KeyAction.setNull)();

  IntColumn get complexity => integer().withDefault(const Constant(5))();
  IntColumn get stability => integer().withDefault(const Constant(5))();
  IntColumn get influence => integer().withDefault(const Constant(5))();

  /// 活跃 / 衰落 / 重组 / 解散
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('活跃'))();

  TextColumn get keyEvents => text().nullable()();
  TextColumn get developmentHistory => text().nullable()();
  TextColumn get networkRules => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  IntColumn get importance => integer().withDefault(const Constant(5))();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get establishedDate => dateTime().nullable()();
  DateTimeColumn get lastUpdatedDate => dateTime().nullable()();
  BoolColumn get isPublic => boolean().withDefault(const Constant(true))();
  IntColumn get hierarchyLevel => integer().nullable()();
  IntColumn get memberCount => integer().withDefault(const Constant(0))();
  IntColumn get relationshipCount =>
      integer().withDefault(const Constant(0))();

  /// 网络密度，C# 为 decimal?
  RealColumn get networkDensity => real().nullable()();

  /// 网络图数据（JSON）
  TextColumn get networkGraphData => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
