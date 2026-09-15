// 政治体系服务
//
// 对应 C# 版 Application/Services/PoliticalSystemService.cs。
//
// 差异：统计从 `Dictionary<string, object>` 改为强类型 [PoliticalSystemStats]；
// 总职位数字段通过注入的 [PoliticalPositionRepository] 按体系累加。去掉 `try/catch(rethrow)`。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/political_system_repository.dart';
import 'package:novelcraft/data/repositories/political_position_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 政治体系服务
class PoliticalSystemService {
  PoliticalSystemService(
    this._repo, {
    required PoliticalPositionRepository politicalPositionRepository,
  }) : _positionRepo = politicalPositionRepository;

  final PoliticalSystemRepository _repo;
  final PoliticalPositionRepository _positionRepo;

  Future<PoliticalSystemRow?> getById(String id) => _repo.getById(id);

  Future<List<PoliticalSystemRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<PoliticalSystemRow> create(PoliticalSystemsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, PoliticalSystemsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<PoliticalSystemRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<PoliticalSystemRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  /// 政治体系统计（按项目聚合，含各体系下职位总数）
  Future<PoliticalSystemStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    var stabilitySum = 0;
    var influenceSum = 0;
    var totalPositions = 0;
    for (final s in list) {
      final t = (s.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      stabilitySum += s.stability;
      influenceSum += s.influence;
      totalPositions += (await _positionRepo.getBySystemId(s.id)).length;
    }
    final avgStability = list.isEmpty ? 0.0 : stabilitySum / list.length;
    final avgInfluence = list.isEmpty ? 0.0 : influenceSum / list.length;
    return PoliticalSystemStats(
      totalSystems: list.length,
      typeStatistics: typeStats,
      averageStability: avgStability,
      averageInfluence: avgInfluence,
      totalPositions: totalPositions,
    );
  }
}
