import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 政治体系仓储 —— 对应 Infrastructure/Data/Repositories/PoliticalSystemRepository.cs
class PoliticalSystemRepository extends RepositoryBase {
  static const _table = 'political_systems';

  PoliticalSystemRepository(super.db);

  Future<PoliticalSystemRow?> getById(String id) {
    return (db.select(db.politicalSystems)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<PoliticalSystemRow>> getByProjectId(String projectId) {
    return (db.select(db.politicalSystems)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<PoliticalSystemRow> create(
      PoliticalSystemsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.politicalSystems).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, PoliticalSystemsCompanion companion) async {
    final rows = await (db.update(db.politicalSystems)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<PoliticalSystemRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.politicalSystems)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.description,
                t.hierarchy,
                t.tags,
                t.notes
              ], lower))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.politicalSystems.id.count();
    final row = await (db.selectOnly(db.politicalSystems)
          ..addColumns([count])
          ..where(db.politicalSystems.projectId.equals(projectId) &
              notDeleted(db.politicalSystems.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<PoliticalSystemRow>> getByType(
      String projectId, String type) {
    return (db.select(db.politicalSystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<PoliticalSystemRow>> getByStabilityRange(
      String projectId, int min, int max) {
    return (db.select(db.politicalSystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.stability.isBiggerOrEqualValue(min) &
              t.stability.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<PoliticalSystemRow>> getByInfluenceRange(
      String projectId, int min, int max) {
    return (db.select(db.politicalSystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.influence.isBiggerOrEqualValue(min) &
              t.influence.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
