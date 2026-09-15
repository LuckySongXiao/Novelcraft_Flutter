import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 剧情仓储 —— 对应 Infrastructure/Data/Repositories/PlotRepository.cs
class PlotRepository extends RepositoryBase {
  static const _table = 'plots';

  PlotRepository(super.db);

  Future<PlotRow?> getById(String id) {
    return (db.select(db.plots)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<PlotRow>> getByProjectId(String projectId) {
    return (db.select(db.plots)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<PlotRow> create(PlotsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.plots).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, PlotsCompanion companion) async {
    final rows = await (db.update(db.plots)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<PlotRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.plots)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.title,
                t.type,
                t.description,
                t.outline,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.plots.id.count();
    final row = await (db.selectOnly(db.plots)
          ..addColumns([count])
          ..where(db.plots.projectId.equals(projectId) &
              notDeleted(db.plots.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<PlotRow>> getByType(String projectId, String type) {
    return (db.select(db.plots)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<PlotRow>> getByStatus(String projectId, String status) {
    return (db.select(db.plots)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<PlotRow>> getByPriority(String projectId, String priority) {
    return (db.select(db.plots)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.priority.equals(priority) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<PlotRow>> getByChapterId(String chapterId) {
    return (db.select(db.plots)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              (t.startChapterId.equals(chapterId) |
                  t.endChapterId.equals(chapterId))))
        .get();
  }
}
