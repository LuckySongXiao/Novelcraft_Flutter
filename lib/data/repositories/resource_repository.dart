import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 资源仓储 —— 对应 Infrastructure/Data/Repositories/ResourceRepository.cs
class ResourceRepository extends RepositoryBase {
  static const _table = 'resources';

  ResourceRepository(super.db);

  Future<ResourceRow?> getById(String id) {
    return (db.select(db.resources)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<ResourceRow>> getByProjectId(String projectId) {
    return (db.select(db.resources)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<ResourceRow> create(ResourcesCompanion companion) async {
    final nowStamp = now;
    return db.into(db.resources).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, ResourcesCompanion companion) async {
    final rows = await (db.update(db.resources)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<ResourceRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.resources)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.location,
                t.rarity,
                t.description,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.resources.id.count();
    final row = await (db.selectOnly(db.resources)
          ..addColumns([count])
          ..where(db.resources.projectId.equals(projectId) &
              notDeleted(db.resources.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<ResourceRow>> getByType(String projectId, String type) {
    return (db.select(db.resources)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<ResourceRow>> getByRarity(String projectId, String rarity) {
    return (db.select(db.resources)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.rarity.equals(rarity) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<ResourceRow>> getByStatus(String projectId, String status) {
    return (db.select(db.resources)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<ResourceRow>> getByControllingFaction(String factionId) {
    return (db.select(db.resources)
          ..where((t) =>
              t.controllingFactionId.equals(factionId) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<ResourceRow>> getByEconomicValueRange(
      String projectId, int min, int max) {
    return (db.select(db.resources)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.economicValue.isBiggerOrEqualValue(min) &
              t.economicValue.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
