import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 秘境仓储 —— 对应 Infrastructure/Data/Repositories/SecretRealmRepository.cs
class SecretRealmRepository extends RepositoryBase {
  static const _table = 'secret_realms';

  SecretRealmRepository(super.db);

  Future<SecretRealmRow?> getById(String id) {
    return (db.select(db.secretRealms)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<SecretRealmRow>> getByProjectId(String projectId) {
    return (db.select(db.secretRealms)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<SecretRealmRow> create(SecretRealmsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.secretRealms).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, SecretRealmsCompanion companion) async {
    final rows = await (db.update(db.secretRealms)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<SecretRealmRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.secretRealms)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.location,
                t.description,
                t.recommendedCultivation,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.secretRealms.id.count();
    final row = await (db.selectOnly(db.secretRealms)
          ..addColumns([count])
          ..where(db.secretRealms.projectId.equals(projectId) &
              notDeleted(db.secretRealms.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<SecretRealmRow>> getByType(String projectId, String type) {
    return (db.select(db.secretRealms)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<SecretRealmRow>> getByStatus(String projectId, String status) {
    return (db.select(db.secretRealms)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<SecretRealmRow>> getByDangerLevelRange(
      String projectId, int min, int max) {
    return (db.select(db.secretRealms)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.dangerLevel.isBiggerOrEqualValue(min) &
              t.dangerLevel.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<SecretRealmRow>> getByRecommendedCultivation(
      String projectId, String level) {
    return (db.select(db.secretRealms)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.recommendedCultivation.equals(level) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<SecretRealmRow>> getByDiscovererFaction(String factionId) {
    return (db.select(db.secretRealms)
          ..where((t) =>
              t.discovererFactionId.equals(factionId) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
