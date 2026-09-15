import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 货币体系仓储 —— 对应 Infrastructure/Data/Repositories/CurrencySystemRepository.cs
class CurrencySystemRepository extends RepositoryBase {
  static const _table = 'currency_systems';

  CurrencySystemRepository(super.db);

  Future<CurrencySystemRow?> getById(String id) {
    return (db.select(db.currencySystems)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<CurrencySystemRow>> getByProjectId(String projectId) {
    return (db.select(db.currencySystems)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<CurrencySystemRow> create(
      CurrencySystemsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.currencySystems).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, CurrencySystemsCompanion companion) async {
    final rows = await (db.update(db.currencySystems)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<CurrencySystemRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.currencySystems)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.monetarySystem,
                t.type,
                t.baseCurrency,
                t.description,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.currencySystems.id.count();
    final row = await (db.selectOnly(db.currencySystems)
          ..addColumns([count])
          ..where(db.currencySystems.projectId.equals(projectId) &
              notDeleted(db.currencySystems.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<CurrencySystemRow>> getByMonetarySystem(
      String projectId, String system) {
    return (db.select(db.currencySystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.monetarySystem.equals(system) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CurrencySystemRow>> getByBaseCurrency(
      String projectId, String currency) {
    return (db.select(db.currencySystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.baseCurrency.equals(currency) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CurrencySystemRow>> getActiveSystems(String projectId) {
    return (db.select(db.currencySystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.isActive.equals(true) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CurrencySystemRow>> getByInflationRateRange(
      String projectId, double min, double max) {
    return (db.select(db.currencySystems)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.inflationRate.isBiggerOrEqualValue(min) &
              t.inflationRate.isSmallerOrEqualValue(max) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
