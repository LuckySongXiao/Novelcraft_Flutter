// 资源服务
//
// 对应 C# 版 Application/Services/ResourceService.cs。
//
// 差异：统计从 `Dictionary<string, object>` 改为强类型 [ResourceStats]；
// 去掉 `try/catch(rethrow)` 模板。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/resource_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 资源服务
class ResourceService {
  ResourceService(this._repo);
  final ResourceRepository _repo;

  Future<ResourceRow?> getById(String id) => _repo.getById(id);

  Future<List<ResourceRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<ResourceRow> create(ResourcesCompanion companion) => _repo.create(companion);

  Future<bool> updateById(String id, ResourcesCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<ResourceRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<ResourceRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<List<ResourceRow>> getByRarity(String projectId, String rarity) =>
      _repo.getByRarity(projectId, rarity);

  Future<List<ResourceRow>> getByStatus(String projectId, String status) =>
      _repo.getByStatus(projectId, status);

  /// 资源统计（按项目聚合）
  Future<ResourceStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final rarityStats = <String, int>{};
    final statusStats = <String, int>{};
    var economicSum = 0;
    var economicValueSum = 0;
    for (final r in list) {
      final t = (r.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final rr = (r.rarity).trim();
      rarityStats[rr] = (rarityStats[rr] ?? 0) + 1;
      final s = (r.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      economicSum += r.economicValue;
      economicValueSum += r.economicValue;
    }
    final avgEconomic = list.isEmpty ? 0.0 : economicSum / list.length;
    return ResourceStats(
      totalResources: list.length,
      typeStatistics: typeStats,
      rarityStatistics: rarityStats,
      statusStatistics: statusStats,
      averageEconomicValue: avgEconomic,
      totalEconomicValue: economicValueSum,
    );
  }
}
