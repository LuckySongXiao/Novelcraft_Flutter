// 种族服务
//
// 对应 C# 版 Application/Services/RaceService.cs。
//
// 差异：统计从 `Dictionary<string, object>` 改为强类型 [RaceStats]；
// 去掉 `try/catch(rethrow)` 模板。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/race_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 种族服务
class RaceService {
  RaceService(this._repo);
  final RaceRepository _repo;

  Future<RaceRow?> getById(String id) => _repo.getById(id);

  Future<List<RaceRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<RaceRow> create(RacesCompanion companion) => _repo.create(companion);

  Future<bool> updateById(String id, RacesCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<RaceRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<RaceRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<List<RaceRow>> getByStatus(String projectId, String status) =>
      _repo.getByStatus(projectId, status);

  Future<RaceRow?> getByName(String projectId, String name) =>
      _repo.getByName(projectId, name);

  /// 种族统计（按项目聚合）
  Future<RaceStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    var powerSum = 0;
    var influenceSum = 0;
    var endangered = 0;
    for (final r in list) {
      final t = (r.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (r.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      powerSum += r.powerLevel;
      influenceSum += r.influence;
      if (r.status == '濒危' || r.status == '灭绝') endangered++;
    }
    final avgPower = list.isEmpty ? 0.0 : powerSum / list.length;
    final avgInfluence = list.isEmpty ? 0.0 : influenceSum / list.length;
    return RaceStats(
      totalRaces: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      averagePowerLevel: avgPower,
      averageInfluence: avgInfluence,
      endangeredRaces: endangered,
    );
  }
}
