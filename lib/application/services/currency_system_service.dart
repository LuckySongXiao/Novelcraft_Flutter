// 货币体系服务
//
// 对应 C# 版 Application/Services/CurrencySystemService.cs。
//
// 保留的关键业务逻辑：
// 1. `calculateExchangeRate(fromId, toId, amount)`：基于两体系 `baseValue` 比率换算金额，
//    对应 C# `CalculateExchangeRateAsync`（rate = to.BaseValue / from.BaseValue）。
// 2. `getExchangeRateTable(baseCurrencyId)`：返回 `Map<String, double>`（货币名 → 相对
//    基准的汇率），对应 C# `GetExchangeRateTableAsync`（C# 返回 `Dictionary<string, decimal>`）。
// 3. 统计从 `Dictionary<string, object>` 改为强类型 [CurrencySystemStats]。
// 4. 去掉 `try/catch(rethrow)` 模板。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/currency_system_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 货币体系服务
class CurrencySystemService {
  CurrencySystemService(this._repo);
  final CurrencySystemRepository _repo;

  Future<CurrencySystemRow?> getById(String id) => _repo.getById(id);

  Future<List<CurrencySystemRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<CurrencySystemRow> create(CurrencySystemsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, CurrencySystemsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<CurrencySystemRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  /// 计算从 fromCurrency 到 toCurrency 的换算金额。
  ///
  /// rate = to.baseValue / from.baseValue，结果 = amount * rate。
  Future<double> calculateExchangeRate(
    String fromId,
    String toId,
    double amount,
  ) async {
    final from = await _repo.getById(fromId);
    final to = await _repo.getById(toId);
    if (from == null) {
      throw ArgumentError('源货币体系不存在，ID: $fromId');
    }
    if (to == null) {
      throw ArgumentError('目标货币体系不存在，ID: $toId');
    }
    if (from.baseValue == 0) {
      throw ArgumentError('源货币体系基础价值为 0，无法换算');
    }
    final rate = to.baseValue / from.baseValue;
    return amount * rate;
  }

  /// 以 baseCurrency 为基准的汇率表（货币名 → 相对汇率）。
  Future<Map<String, double>> getExchangeRateTable(String baseCurrencyId) async {
    final base = await _repo.getById(baseCurrencyId);
    if (base == null) {
      throw ArgumentError('基础货币体系不存在，ID: $baseCurrencyId');
    }
    final all = await _repo.getByProjectId(base.projectId);
    final table = <String, double>{};
    for (final c in all) {
      if (c.id != baseCurrencyId && base.baseValue != 0) {
        table[c.name] = c.baseValue / base.baseValue;
      }
    }
    return table;
  }

  /// 货币体系统计（按项目聚合）
  Future<CurrencySystemStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    var stabilitySum = 0;
    var inflationSum = 0.0;
    var baseValueSum = 0.0;
    var highStability = 0;
    for (final c in list) {
      final t = (c.type?.trim().isEmpty ?? true) ? '未分类' : c.type!.trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (c.status?.trim().isEmpty ?? true) ? '未分类' : c.status!.trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      stabilitySum += c.stability;
      inflationSum += c.inflationRate ?? 0;
      baseValueSum += c.baseValue;
      if (c.stability >= 80) highStability++;
    }
    final avgStability = list.isEmpty ? 0.0 : stabilitySum / list.length;
    final avgInflation = list.isEmpty ? 0.0 : inflationSum / list.length;
    final avgBaseValue = list.isEmpty ? 0.0 : baseValueSum / list.length;
    return CurrencySystemStats(
      totalSystems: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      activeSystems: list.where((c) => c.status == '活跃').length,
      averageStability: avgStability,
      averageInflation: avgInflation,
      averageBaseValue: avgBaseValue,
      highStabilitySystems: highStability,
    );
  }
}
