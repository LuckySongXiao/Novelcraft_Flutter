import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 修炼体系仓储 —— 对应 Infrastructure/Data/Repositories/CultivationSystemRepository.cs
class CultivationSystemRepository extends RepositoryBase {
  static const _table = 'cultivation_systems';

  CultivationSystemRepository(super.db);

  Future<CultivationSystemRow?> getById(String id) {
    return (db.select(db.cultivationSystems)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<CultivationSystemRow>> getByProjectId(String projectId) {
    return (db.select(db.cultivationSystems)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<CultivationSystemRow> create(
      CultivationSystemsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.cultivationSystems).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, CultivationSystemsCompanion companion) async {
    final rows = await (db.update(db.cultivationSystems)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<CultivationSystemRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.cultivationSystems)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.description,
                t.cultivationMethod,
                t.tags,
                t.notes
              ], lower))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.cultivationSystems.id.count();
    final row = await (db.selectOnly(db.cultivationSystems)
          ..addColumns([count])
          ..where(db.cultivationSystems.projectId.equals(projectId) &
              notDeleted(db.cultivationSystems.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<CultivationSystemRow>> getByType(
      String projectId, String type) {
    return (db.select(db.cultivationSystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CultivationSystemRow>> getByDifficultyRange(
      String projectId, int min, int max) {
    return (db.select(db.cultivationSystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.difficulty.isBiggerOrEqualValue(min) &
              t.difficulty.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
