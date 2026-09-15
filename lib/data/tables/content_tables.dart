import 'package:drift/drift.dart';

import 'audit.dart';
import 'character_tables.dart';
import 'project_tables.dart';
import 'world_tables.dart';
import 'worldbuilding_tables.dart';

/// 人物关系 —— 对应 Core/Entities/CharacterRelationship.cs
///
/// 与 C# 的差异：**新增 `projectId` 冗余字段**。
/// C# 实体没有 ProjectId，但仓储定义了 GetByProjectIdAsync，
/// 实现上必须经 Character 二次 JOIN。这里补冗余字段规避。
@DataClassName('CharacterRelationshipRow')
class CharacterRelationships extends Table with AuditFields {
  /// 源角色删除级联；目标角色删除 Restrict（对齐 C# Source=Cascade / Target=Restrict）
  @ReferenceName('relationshipsAsSource')
  TextColumn get sourceCharacterId =>
      text().references(Characters, #id, onDelete: KeyAction.cascade)();

  @ReferenceName('relationshipsAsTarget')
  TextColumn get targetCharacterId =>
      text().references(Characters, #id, onDelete: KeyAction.noAction)();

  TextColumn get relationshipType => text().withLength(min: 1, max: 50)();

  /// 关系强度 1-10
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

  /// 所属关系网络，网络删除置空
  TextColumn get relationshipNetworkId => text()
      .nullable()
      .references(RelationshipNetworks, #id, onDelete: KeyAction.setNull)();

  /// 冗余：所属项目（C# 版本缺失）
  TextColumn get projectId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 角色履历事件 —— 对应 Core/Entities/CharacterEvent.cs
///
/// ⚠ 原 C# 实现未把本实体加入软删除全局过滤（21 个实体中唯一的漏网之鱼），
/// 即软删的事件仍会被查出。此处按 1:1 行为保留该语义：
/// DAO 层查询 CharacterEvent 时**不**自动附加 isDeleted 过滤。
@DataClassName('CharacterEventRow')
class CharacterEvents extends Table with AuditFields {
  TextColumn get characterId =>
      text().references(Characters, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable()();

  /// 出生 / 拜师 / 突破 / 参战 / 结盟 / 离队 / 死亡 / 其他
  TextColumn get eventType =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('其他'))();

  /// 书籍世界内的时间描述（如"修炼第三年"），非真实日期
  TextColumn get storyTime => text().nullable().withLength(max: 200)();

  IntColumn get orderIndex => integer().withDefault(const Constant(0))();

  /// 关联章节，章节删除置空
  TextColumn get chapterId =>
      text().nullable().references(Chapters, #id, onDelete: KeyAction.setNull)();

  /// 关联剧情，剧情删除置空
  TextColumn get plotId =>
      text().nullable().references(Plots, #id, onDelete: KeyAction.setNull)();

  TextColumn get impact => text().nullable()();

  /// 涉及的其他角色 ID（逗号分隔字符串）。
  /// C# 侧为伪多对多，这里保留字符串形式以兼容历史数据。
  TextColumn get involvedCharacterIds =>
      text().nullable().withLength(max: 1000)();

  TextColumn get tags => text().nullable().withLength(max: 500)();

  @override
  Set<Column> get primaryKey => {id};
}
