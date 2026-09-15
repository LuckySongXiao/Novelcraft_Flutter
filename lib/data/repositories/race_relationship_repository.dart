import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 种族关系仓储 —— 对应 Infrastructure/Data/Repositories/RaceRelationshipRepository.cs
///
/// 本实体自身带 projectId（C# 版即如此），无需冗余补字段。
class RaceRelationshipRepository extends RepositoryBase {
  static const _table = 'race_relationships';

  RaceRelationshipRepository(super.db);

  Future<RaceRelationshipRow?> getById(String id) {
    return (db.select(db.raceRelationships)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<RaceRelationshipRow>> getByProjectId(String projectId) {
    return (db.select(db.raceRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
  }

  Future<RaceRelationshipRow> create(
      RaceRelationshipsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.raceRelationships).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, RaceRelationshipsCompanion companion) async {
    final rows = await (db.update(db.raceRelationships)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<RaceRelationshipRow>> search(
      String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.raceRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.relationshipType,
                t.description,
                t.history,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.raceRelationships.id.count();
    final row = await (db.selectOnly(db.raceRelationships)
          ..addColumns([count])
          ..where(db.raceRelationships.projectId.equals(projectId) &
              notDeleted(db.raceRelationships.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<RaceRelationshipRow>> getBySourceRace(String raceId) {
    return (db.select(db.raceRelationships)
          ..where((t) =>
              t.sourceRaceId.equals(raceId) & notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RaceRelationshipRow>> getByTargetRace(String raceId) {
    return (db.select(db.raceRelationships)
          ..where((t) =>
              t.targetRaceId.equals(raceId) & notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RaceRelationshipRow>> getByRace(String raceId) {
    return (db.select(db.raceRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              (t.sourceRaceId.equals(raceId) |
                  t.targetRaceId.equals(raceId))))
        .get();
  }

  Future<List<RaceRelationshipRow>> getByType(
      String projectId, String type) {
    return (db.select(db.raceRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.relationshipType.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RaceRelationshipRow>> getByStatus(
      String projectId, String status) {
    return (db.select(db.raceRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RaceRelationshipRow>> getByStrengthRange(
      String projectId, int min, int max) {
    return (db.select(db.raceRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.strength.isBiggerOrEqualValue(min) &
              t.strength.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
