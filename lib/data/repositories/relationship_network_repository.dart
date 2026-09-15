import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 关系网络仓储 —— 对应 Infrastructure/Data/Repositories/RelationshipNetworkRepository.cs
class RelationshipNetworkRepository extends RepositoryBase {
  static const _table = 'relationship_networks';

  RelationshipNetworkRepository(super.db);

  Future<RelationshipNetworkRow?> getById(String id) {
    return (db.select(db.relationshipNetworks)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<RelationshipNetworkRow>> getByProjectId(String projectId) {
    return (db.select(db.relationshipNetworks)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<RelationshipNetworkRow> create(
      RelationshipNetworksCompanion companion) async {
    final nowStamp = now;
    return db.into(db.relationshipNetworks).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, RelationshipNetworksCompanion companion) async {
    final rows = await (db.update(db.relationshipNetworks)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<RelationshipNetworkRow>> search(
      String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.relationshipNetworks)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.description,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.relationshipNetworks.id.count();
    final row = await (db.selectOnly(db.relationshipNetworks)
          ..addColumns([count])
          ..where(db.relationshipNetworks.projectId.equals(projectId) &
              notDeleted(db.relationshipNetworks.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<RelationshipNetworkRow>> getByType(
      String projectId, String type) {
    return (db.select(db.relationshipNetworks)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RelationshipNetworkRow>> getByStatus(
      String projectId, String status) {
    return (db.select(db.relationshipNetworks)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RelationshipNetworkRow>> getByCentralCharacter(
      String characterId) {
    return (db.select(db.relationshipNetworks)
          ..where((t) =>
              t.centralCharacterId.equals(characterId) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<RelationshipNetworkRow>> getByComplexityRange(
      String projectId, int min, int max) {
    return (db.select(db.relationshipNetworks)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.complexity.isBiggerOrEqualValue(min) &
              t.complexity.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
