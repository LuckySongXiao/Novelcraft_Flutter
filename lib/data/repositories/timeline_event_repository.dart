import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 时间线事件仓储 —— 对应 Infrastructure/Data/Repositories/TimelineEventRepository.cs
///
/// 含 legacyId 去重迁移支持；importance 在本实体是 **文本** 字段（极高/高/中/低），
/// 而非 int，调用方注意。
class TimelineEventRepository extends RepositoryBase {
  static const _table = 'timeline_events';

  TimelineEventRepository(super.db);

  Future<TimelineEventRow?> getById(String id) {
    return (db.select(db.timelineEvents)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<TimelineEventRow>> getByProjectId(String projectId) {
    return (db.select(db.timelineEvents)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.eventDate)]))
        .get();
  }

  Future<TimelineEventRow> create(TimelineEventsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.timelineEvents).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, TimelineEventsCompanion companion) async {
    final rows = await (db.update(db.timelineEvents)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<TimelineEventRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.timelineEvents)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.title,
                t.category,
                t.location,
                t.description,
                t.impact,
                t.tags
              ], lower))
          ..orderBy([(t) => OrderingTerm.asc(t.eventDate)]))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.timelineEvents.id.count();
    final row = await (db.selectOnly(db.timelineEvents)
          ..addColumns([count])
          ..where(db.timelineEvents.projectId.equals(projectId) &
              notDeleted(db.timelineEvents.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> countByProjectId(String projectId) => countByProject(projectId);

  Future<List<TimelineEventRow>> getByCategory(
      String projectId, String category) {
    return (db.select(db.timelineEvents)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.category.equals(category) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<TimelineEventRow>> getByDateRange(
      String projectId, DateTime from, DateTime to) {
    return (db.select(db.timelineEvents)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.eventDate.isBetweenValues(from, to) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.eventDate)]))
        .get();
  }

  /// 找出已存在于库中的 legacyId（用于一次性 JSON → DB 去重迁移）。
  Future<List<TimelineEventRow>> filterExistingLegacyIds(
      String projectId, List<String> legacyIds) {
    if (legacyIds.isEmpty) return Future.value(<TimelineEventRow>[]);
    return (db.select(db.timelineEvents)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.legacyId.isIn(legacyIds) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<void> deleteByProjectId(String projectId) =>
      softDeleteByProject(_table, projectId);
}
