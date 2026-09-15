import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 势力仓储 —— 对应 Infrastructure/Data/Repositories/FactionRepository.cs
class FactionRepository extends RepositoryBase {
  static const _table = 'factions';

  FactionRepository(super.db);

  Future<FactionRow?> getById(String id) {
    return (db.select(db.factions)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<FactionRow>> getByProjectId(String projectId) {
    return (db.select(db.factions)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<FactionRow> create(FactionsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.factions).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, FactionsCompanion companion) async {
    final rows = await (db.update(db.factions)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<FactionRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.factions)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.description,
                t.tags,
                t.notes,
                t.level,
                t.headquarters
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.factions.id.count();
    final row = await (db.selectOnly(db.factions)
          ..addColumns([count])
          ..where(db.factions.projectId.equals(projectId) &
              notDeleted(db.factions.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<FactionRow>> getByType(String projectId, String type) {
    return (db.select(db.factions)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<FactionRow?> getByName(String projectId, String name) {
    return (db.select(db.factions)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.name.equals(name) &
              notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<FactionRow>> getByPowerLevelRange(
      String projectId, int min, int max) {
    return (db.select(db.factions)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.powerLevel.isBiggerOrEqualValue(min) &
              t.powerLevel.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
