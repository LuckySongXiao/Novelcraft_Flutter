import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 政治职位仓储 —— 对应 Infrastructure/Data/Repositories/PoliticalPositionRepository.cs
///
/// 无 projectId，按 politicalSystemId 归属。
class PoliticalPositionRepository extends RepositoryBase {
  static const _table = 'political_positions';

  PoliticalPositionRepository(super.db);

  Future<PoliticalPositionRow?> getById(String id) {
    return (db.select(db.politicalPositions)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<PoliticalPositionRow> create(
      PoliticalPositionsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.politicalPositions).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, PoliticalPositionsCompanion companion) async {
    final rows = await (db.update(db.politicalPositions)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  /// 职位无 projectId，提供全量读取供实体页展示（按所属体系反查项目）。
  Future<List<PoliticalPositionRow>> getAll() {
    return (db.select(db.politicalPositions)
          ..where((t) => notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.level)]))
        .get();
  }

  Future<List<PoliticalPositionRow>> getBySystemId(String systemId) {
    return (db.select(db.politicalPositions)
          ..where((t) =>
              t.politicalSystemId.equals(systemId) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<PoliticalPositionRow?> getByLevel(String systemId, int level) {
    return (db.select(db.politicalPositions)
          ..where((t) =>
              t.politicalSystemId.equals(systemId) &
              t.level.equals(level) &
              notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<PoliticalPositionRow?> getHighestLevel(String systemId) {
    return (db.select(db.politicalPositions)
          ..where((t) =>
              t.politicalSystemId.equals(systemId) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.level)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<PoliticalPositionRow?> getLowestLevel(String systemId) {
    return (db.select(db.politicalPositions)
          ..where((t) =>
              t.politicalSystemId.equals(systemId) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.level)])
          ..limit(1))
        .getSingleOrNull();
  }
}
