import 'package:drift/drift.dart';

import 'audit.dart';
import 'project_tables.dart';
import 'world_tables.dart';

/// 时间线事件 —— 对应 Core/Entities/TimelineEvent.cs
///
/// 备注：该实体在 C# 版本中是最后才从「项目级 JSON 文件」迁移到数据库的
/// （原路径 AppData/Roaming/NovelManagement/timelines/{projectId}.json），
/// 因此保留了 `legacyId` 字段用于一次性去重迁移。
@DataClassName('TimelineEventRow')
class TimelineEvents extends Table with AuditFields {
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text().withLength(min: 1, max: 200)();

  /// 历史事件 / 剧情事件 / 角色事件 / 势力事件 / 世界事件 / 修炼事件
  TextColumn get category =>
      text().nullable().withLength(max: 50).withDefault(const Constant('历史事件'))();

  /// 事件发生日期（唯一非可空的业务日期字段）
  DateTimeColumn get eventDate => dateTime()();
  TextColumn get location => text().nullable().withLength(max: 200)();

  /// 极高 / 高 / 中 / 低（注意是字符串而非 int）
  TextColumn get importance => text().nullable().withLength(max: 50)();

  /// 已完成 / 进行中 / 计划中 / 已取消
  TextColumn get status => text().nullable().withLength(max: 50)();
  TextColumn get description => text().nullable()();
  TextColumn get impact => text().nullable()();

  /// 显示排序序号（同日事件的稳定排序）
  IntColumn get displayOrder => integer().withDefault(const Constant(0))();

  TextColumn get chapterId =>
      text().nullable().references(Chapters, #id, onDelete: KeyAction.setNull)();
  TextColumn get plotId =>
      text().nullable().references(Plots, #id, onDelete: KeyAction.setNull)();
  TextColumn get tags => text().nullable().withLength(max: 500)();

  /// 迁移来源标识（旧 JSON 中的整数 Id），仅用于去重
  TextColumn get legacyId => text().nullable().withLength(max: 50)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 时间线事件参与者 —— 对应 Core/Entities/TimelineEventParticipant.cs
///
/// 参与者优先用 `characterId` 与项目内角色建立强关联；
/// 匹配不到时仍保留 `name` 文本，避免历史数据丢失。
@DataClassName('TimelineEventParticipantRow')
class TimelineEventParticipants extends Table with AuditFields {
  TextColumn get timelineEventId =>
      text().references(TimelineEvents, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// 角色 / 势力 / 其他
  TextColumn get type => text().nullable().withLength(max: 50)();

  /// 在事件中的角色定位
  TextColumn get role => text().nullable().withLength(max: 200)();

  /// 关联角色 ID（弱关联，不做 FK 约束）
  TextColumn get characterId => text().nullable()();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
