import 'package:drift/drift.dart';

import 'audit.dart';
import 'project_tables.dart';

/// 势力 —— 对应 Core/Entities/Faction.cs
@DataClassName('FactionRow')
class Factions extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get type => text().withLength(min: 1, max: 50)();

  /// 势力等级。注意：C# 的 `Level` 是 string，`PowerLevel` 才是 int
  TextColumn get level => text().nullable().withLength(max: 50)();

  /// 领袖角色 ID（C# 为无外键的裸 Guid，此处保留弱引用）
  TextColumn get leaderId => text().nullable()();

  /// 父势力 ID（同上，弱引用）
  TextColumn get parentFactionId => text().nullable()();

  IntColumn get powerLevel => integer().withDefault(const Constant(50))();
  IntColumn get influence => integer().withDefault(const Constant(50))();
  IntColumn get importance => integer().withDefault(const Constant(5))();
  IntColumn get memberCount => integer().nullable()();
  IntColumn get powerRating => integer().nullable()();
  IntColumn get influenceRating => integer().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get history => text().nullable()();
  TextColumn get specialAbilities => text().nullable()();
  TextColumn get resources => text().nullable()();

  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  TextColumn get emblemPath => text().nullable().withLength(max: 500)();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  TextColumn get status =>
      text().withLength(max: 50).withDefault(const Constant('Active'))();
  TextColumn get headquarters => text().nullable().withLength(max: 200)();
  TextColumn get territory => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 势力关系 —— 对应 Core/Entities/FactionRelationship.cs
///
/// 与 C# 的差异：**新增 `projectId` 冗余字段**。
/// C# 实体没有 ProjectId，但仓储定义了 GetByProjectIdAsync，
/// 实现上必须经 Faction 二次 JOIN。这里补冗余字段规避。
@DataClassName('FactionRelationshipRow')
class FactionRelationships extends Table with AuditFields {
  /// 源势力删除级联；目标势力删除 Restrict（对齐 C# Source=Cascade / Target=Restrict）
  @ReferenceName('relationshipsAsSource')
  TextColumn get sourceFactionId =>
      text().references(Factions, #id, onDelete: KeyAction.cascade)();

  @ReferenceName('relationshipsAsTarget')
  TextColumn get targetFactionId =>
      text().references(Factions, #id, onDelete: KeyAction.noAction)();

  TextColumn get relationshipType => text().withLength(min: 1, max: 50)();
  IntColumn get intensity => integer().withDefault(const Constant(1))();
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('Active'))();
  TextColumn get relationshipName => text().nullable().withLength(max: 100)();
  TextColumn get description => text().nullable()();
  TextColumn get developmentHistory => text().nullable()();
  TextColumn get keyEvents => text().nullable()();
  TextColumn get impact => text().nullable()();
  DateTimeColumn get startDate => dateTime().nullable()();
  DateTimeColumn get endDate => dateTime().nullable()();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  BoolColumn get isBidirectional =>
      boolean().withDefault(const Constant(true))();
  IntColumn get importance => integer().withDefault(const Constant(1))();
  TextColumn get militaryComparison => text().nullable()();
  TextColumn get economicRelations => text().nullable()();

  /// 冗余：所属项目（C# 版本缺失）
  TextColumn get projectId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
