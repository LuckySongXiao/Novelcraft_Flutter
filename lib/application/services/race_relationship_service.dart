// 种族关系服务
//
// 对应 C# 版 Application/Services（RaceRelationship 在 C# 中由 RaceService 内聚管理；
// Dart 侧按任务要求拆为独立服务）。
//
// 差异：统计从弱类型字典改为强类型 [RaceRelationshipStats]。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/race_relationship_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 种族关系服务
class RaceRelationshipService {
  RaceRelationshipService(this._repo);
  final RaceRelationshipRepository _repo;

  Future<RaceRelationshipRow?> getById(String id) => _repo.getById(id);

  Future<List<RaceRelationshipRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<RaceRelationshipRow> create(RaceRelationshipsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, RaceRelationshipsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<RaceRelationshipRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<RaceRelationshipRow>> getByRace(String raceId) =>
      _repo.getByRace(raceId);

  /// 种族关系统计（按项目聚合）
  Future<RaceRelationshipStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    var strengthSum = 0;
    for (final r in list) {
      final t = (r.relationshipType).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (r.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      strengthSum += r.strength;
    }
    final avgStrength = list.isEmpty ? 0.0 : strengthSum / list.length;
    return RaceRelationshipStats(
      totalRelationships: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      averageStrength: avgStrength,
    );
  }
}
