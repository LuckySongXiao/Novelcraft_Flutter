// 势力服务
//
// 对应 C# 版 Application/Services/FactionService.cs。
//
// 差异：去掉 `try/catch(rethrow)` 模板；统计从 `Dictionary<string, object>` 改为
// 强类型 [FactionStats]。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/faction_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 势力服务
class FactionService {
  FactionService(this._repo);
  final FactionRepository _repo;

  Future<FactionRow?> getById(String id) => _repo.getById(id);

  Future<List<FactionRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<FactionRow> create(FactionsCompanion companion) => _repo.create(companion);

  Future<bool> updateById(String id, FactionsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<FactionRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<FactionRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<FactionRow?> getByName(String projectId, String name) =>
      _repo.getByName(projectId, name);

  Future<List<FactionRow>> getByPowerLevelRange(
          String projectId, int min, int max) =>
      _repo.getByPowerLevelRange(projectId, min, max);

  /// 势力统计（按项目聚合）
  Future<FactionStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    var powerSum = 0;
    var influenceSum = 0;
    var highPower = 0;
    for (final f in list) {
      final t = (f.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (f.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      powerSum += f.powerLevel;
      influenceSum += f.influence;
      if (f.powerLevel >= 80) highPower++;
    }
    final avgPower = list.isEmpty ? 0.0 : powerSum / list.length;
    final avgInfluence = list.isEmpty ? 0.0 : influenceSum / list.length;
    return FactionStats(
      totalFactions: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      averagePowerLevel: avgPower,
      averageInfluence: avgInfluence,
      highPowerFactions: highPower,
    );
  }
}
