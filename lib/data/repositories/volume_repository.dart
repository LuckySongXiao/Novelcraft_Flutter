import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 卷宗仓储 —— 对应 Infrastructure/Data/Repositories/VolumeRepository.cs
class VolumeRepository extends RepositoryBase {
  static const _table = 'volumes';

  VolumeRepository(super.db);

  Future<VolumeRow?> getById(String id) {
    return (db.select(db.volumes)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<VolumeRow>> getByProjectId(String projectId) {
    return (db.select(db.volumes)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<VolumeRow> create(VolumesCompanion companion) async {
    final nowStamp = now;
    return db.into(db.volumes).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, VolumesCompanion companion) async {
    final rows = await (db.update(db.volumes)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<VolumeRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.volumes)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn(
                  [t.title, t.description, t.type, t.tags, t.notes], lower))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.volumes.id.count();
    final row = await (db.selectOnly(db.volumes)
          ..addColumns([count])
          ..where(db.volumes.projectId.equals(projectId) &
              notDeleted(db.volumes.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<VolumeRow>> getByStatus(String projectId, String status) {
    return (db.select(db.volumes)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<int> getNextOrderIndex(String projectId) async {
    final maxOrder = db.volumes.orderIndex.max();
    final row = await (db.selectOnly(db.volumes)
          ..addColumns([maxOrder])
          ..where(db.volumes.projectId.equals(projectId) &
              notDeleted(db.volumes.isDeleted)))
        .getSingleOrNull();
    final max = row?.read(maxOrder);
    return (max ?? -1) + 1;
  }

  Future<bool> updateOrder(String volumeId, int newIndex) async {
    final rows = await (db.update(db.volumes)
          ..where((t) => t.id.equals(volumeId)))
        .write(VolumesCompanion(
          orderIndex: Value(newIndex),
          updatedAt: Value(now),
        ));
    return rows > 0;
  }
}
