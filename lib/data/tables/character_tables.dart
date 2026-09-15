import 'package:drift/drift.dart';

import 'audit.dart';
import 'faction_tables.dart';
import 'project_tables.dart';
import 'world_tables.dart';

/// 人物角色 —— 对应 Core/Entities/Character.cs
///
/// C# 原实体有 21 个数据字段 + 9 个导航属性，
/// 其中与 Plot / RelationshipNetwork 的两组多对多迁到
/// [CharacterPlotEntries] / [CharacterNetworkEntries] 两张显式联结表。
@DataClassName('CharacterRow')
class Characters extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get type => text().withLength(min: 1, max: 50)();
  TextColumn get gender => text().nullable().withLength(max: 20)();
  IntColumn get age => integer().nullable()();
  TextColumn get cultivationLevel => text().nullable().withLength(max: 100)();

  /// 所属势力，势力删除时置空（对齐 C# 的 SetNull）
  TextColumn get factionId => text()
      .nullable()
      .references(Factions, #id, onDelete: KeyAction.setNull)();

  /// 所属种族，种族删除时置空
  TextColumn get raceId => text()
      .nullable()
      .references(Races, #id, onDelete: KeyAction.setNull)();

  IntColumn get importance => integer().withDefault(const Constant(1))();
  TextColumn get appearance => text().nullable()();
  TextColumn get personality => text().nullable()();
  TextColumn get background => text().nullable()();
  TextColumn get abilities => text().nullable()();

  /// 所属项目，删除项目级联删除角色
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  TextColumn get avatarPath => text().nullable().withLength(max: 500)();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  TextColumn get status =>
      text().withLength(max: 50).withDefault(const Constant('Active'))();

  /// 首次/最后出场章节。C# 中为无外键约束的裸 Guid，此处保留弱引用语义
  TextColumn get firstAppearanceChapterId => text().nullable()();
  TextColumn get lastAppearanceChapterId => text().nullable()();

  TextColumn get history => text().nullable()();
  TextColumn get keyEvents => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
