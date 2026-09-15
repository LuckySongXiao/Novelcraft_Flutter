// 秘境服务
//
// 对应 C# 版 Application/Services/SecretRealmService.cs。
//
// 差异：统计从 `Dictionary<string, object>` 改为强类型 [SecretRealmStats]；
// 去掉 `try/catch(rethrow)` 模板。原 C# `GetExplorationStatisticsAsync` 仅统计探索次数，
// 这里额外带上危险度均值与成功探索次数。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/secret_realm_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 秘境服务
class SecretRealmService {
  SecretRealmService(this._repo);
  final SecretRealmRepository _repo;

  Future<SecretRealmRow?> getById(String id) => _repo.getById(id);

  Future<List<SecretRealmRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<SecretRealmRow> create(SecretRealmsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, SecretRealmsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<SecretRealmRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<SecretRealmRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<List<SecretRealmRow>> getByStatus(String projectId, String status) =>
      _repo.getByStatus(projectId, status);

  /// 秘境统计（按项目聚合，对应 C# GetExplorationStatisticsAsync 的强类型化）
  Future<SecretRealmStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    var dangerSum = 0;
    var explorations = 0;
    var successful = 0;
    for (final r in list) {
      final t = (r.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (r.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      dangerSum += r.dangerLevel;
      explorations += r.explorationCount;
      successful += r.successfulExplorationCount;
    }
    final avgDanger = list.isEmpty ? 0.0 : dangerSum / list.length;
    return SecretRealmStats(
      totalRealms: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      averageDangerLevel: avgDanger,
      totalExplorations: explorations,
      successfulExplorations: successful,
    );
  }
}
