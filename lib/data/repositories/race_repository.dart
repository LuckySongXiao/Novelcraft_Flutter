import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 种族仓储 —— 对应 Infrastructure/Data/Repositories/RaceRepository.cs
class RaceRepository extends RepositoryBase {
  static const _table = 'races';

  RaceRepository(super.db);

  Future<RaceRow?> getById(String id) {
    return (db.select(db.races)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<RaceRow>> getByProjectId(String projectId) {
    return (db.select(db.races)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<RaceRow> create(RacesCompanion companion) async {
    final nowStamp = now;
    return db.into(db.races).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, RacesCompanion companion) async {
    final rows = await (db.update(db.races)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<RaceRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.races)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.characteristics,
                t.culturalBackground,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.races.id.count();
    final row = await (db.selectOnly(db.races)
          ..addColumns([count])
          ..where(db.races.projectId.equals(projectId) &
              notDeleted(db.races.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<RaceRow>> getByType(String projectId, String type) {
    return (db.select(db.races)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RaceRow>> getByStatus(String projectId, String status) {
    return (db.select(db.races)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RaceRow>> getByPowerLevelRange(
      String projectId, int min, int max) {
    return (db.select(db.races)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.powerLevel.isBiggerOrEqualValue(min) &
              t.powerLevel.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RaceRow>> getByInfluenceRange(
      String projectId, int min, int max) {
    return (db.select(db.races)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.influence.isBiggerOrEqualValue(min) &
              t.influence.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<RaceRow?> getByName(String projectId, String name) {
    return (db.select(db.races)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.name.equals(name) &
              notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }
}
