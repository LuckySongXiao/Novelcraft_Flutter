// 修炼体系服务
//
// 对应 C# 版 Application/Services/CultivationSystemService.cs。
//
// 差异：
// 1. 统计从 `Dictionary<string, object>` 改为强类型 [CultivationSystemStats]；
//    总等级数通过注入的 [CultivationLevelRepository] 按体系累加。
// 2. 去掉 `try/catch(rethrow)` 模板；原 C# 的 `CopyAsync` 由 WorldSetting 之类承担，
//    本服务仅做标准 CRUD + 统计。C# CultivationSystemService 统计里 `TotalLevels`
//    来自仓储 `GetStatisticsAsync`，这里显式遍历各体系下等级数。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/cultivation_system_repository.dart';
import 'package:novelcraft/data/repositories/cultivation_level_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 修炼体系服务
class CultivationSystemService {
  CultivationSystemService(
    this._repo, {
    required CultivationLevelRepository cultivationLevelRepository,
  }) : _levelRepo = cultivationLevelRepository;

  final CultivationSystemRepository _repo;
  final CultivationLevelRepository _levelRepo;

  Future<CultivationSystemRow?> getById(String id) => _repo.getById(id);

  Future<List<CultivationSystemRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<CultivationSystemRow> create(CultivationSystemsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, CultivationSystemsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<CultivationSystemRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<CultivationSystemRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  /// 修炼体系统计（按项目聚合，含各体系下等级总数）
  Future<CultivationSystemStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    var difficultySum = 0;
    var maxLevelSum = 0;
    var totalLevels = 0;
    for (final s in list) {
      final t = (s.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      difficultySum += s.difficulty;
      maxLevelSum += s.maxLevel;
      totalLevels += (await _levelRepo.getBySystemId(s.id)).length;
    }
    final avgDifficulty = list.isEmpty ? 0.0 : difficultySum / list.length;
    final avgMaxLevel = list.isEmpty ? 0.0 : maxLevelSum / list.length;
    return CultivationSystemStats(
      totalSystems: list.length,
      typeStatistics: typeStats,
      averageDifficulty: avgDifficulty,
      totalLevels: totalLevels,
      averageMaxLevel: avgMaxLevel,
    );
  }
}
