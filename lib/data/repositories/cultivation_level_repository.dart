import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 修炼等级仓储 —— 对应 Infrastructure/Data/Repositories/CultivationLevelRepository.cs
///
/// 无 projectId，按 cultivationSystemId 归属；共用方法省略 project 维度，仅实现体系内查询。
class CultivationLevelRepository extends RepositoryBase {
  static const _table = 'cultivation_levels';

  CultivationLevelRepository(super.db);

  Future<CultivationLevelRow?> getById(String id) {
    return (db.select(db.cultivationLevels)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<CultivationLevelRow> create(
      CultivationLevelsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.cultivationLevels).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, CultivationLevelsCompanion companion) async {
    final rows = await (db.update(db.cultivationLevels)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  /// 等级无 projectId，提供全量读取供实体页展示（按所属体系反查项目）。
  Future<List<CultivationLevelRow>> getAll() {
    return (db.select(db.cultivationLevels)
          ..where((t) => notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<List<CultivationLevelRow>> getBySystemId(String systemId) {
    return (db.select(db.cultivationLevels)
          ..where((t) =>
              t.cultivationSystemId.equals(systemId) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<CultivationLevelRow?> getNextLevel(
      String systemId, int currentOrder) {
    return (db.select(db.cultivationLevels)
          ..where((t) =>
              t.cultivationSystemId.equals(systemId) &
              t.orderIndex.isBiggerThanValue(currentOrder) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<CultivationLevelRow?> getPreviousLevel(
      String systemId, int currentOrder) {
    return (db.select(db.cultivationLevels)
          ..where((t) =>
              t.cultivationSystemId.equals(systemId) &
              t.orderIndex.isSmallerThanValue(currentOrder) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.orderIndex)])
          ..limit(1))
        .getSingleOrNull();
  }
}
