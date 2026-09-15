import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 势力关系仓储 —— 对应 Infrastructure/Data/Repositories/FactionRelationshipRepository.cs
///
/// 差异：新增冗余 projectId 字段（C# 版本需经 Faction 二次 JOIN）。
class FactionRelationshipRepository extends RepositoryBase {
  static const _table = 'faction_relationships';

  FactionRelationshipRepository(super.db);

  Future<FactionRelationshipRow?> getById(String id) {
    return (db.select(db.factionRelationships)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<FactionRelationshipRow>> getByProjectId(String projectId) {
    return (db.select(db.factionRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
  }

  Future<FactionRelationshipRow> create(
      FactionRelationshipsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.factionRelationships).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, FactionRelationshipsCompanion companion) async {
    final rows = await (db.update(db.factionRelationships)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<FactionRelationshipRow>> search(
      String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.factionRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.relationshipType,
                t.relationshipName,
                t.description,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.factionRelationships.id.count();
    final row = await (db.selectOnly(db.factionRelationships)
          ..addColumns([count])
          ..where(db.factionRelationships.projectId.equals(projectId) &
              notDeleted(db.factionRelationships.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<FactionRelationshipRow>> getByFactionId(String factionId) {
    return (db.select(db.factionRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              (t.sourceFactionId.equals(factionId) |
                  t.targetFactionId.equals(factionId))))
        .get();
  }

  Future<FactionRelationshipRow?> getByFactionPair(
      String sourceId, String targetId) {
    return (db.select(db.factionRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.sourceFactionId.equals(sourceId) &
              t.targetFactionId.equals(targetId)))
        .getSingleOrNull();
  }

  Future<List<FactionRelationshipRow>> getByType(
      String projectId, String type) {
    return (db.select(db.factionRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.relationshipType.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
