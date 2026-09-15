// 势力关系服务
//
// 对应 C# 版 Application/Services/FactionRelationshipService.cs（在 C# 中未单列服务，
// 由 FactionService 内聚处理；Dart 侧按任务要求拆为独立服务）。
//
// 差异：统计从弱类型字典改为强类型 [FactionRelationshipStats]。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/faction_relationship_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 势力关系服务
class FactionRelationshipService {
  FactionRelationshipService(this._repo);
  final FactionRelationshipRepository _repo;

  Future<FactionRelationshipRow?> getById(String id) => _repo.getById(id);

  Future<List<FactionRelationshipRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<FactionRelationshipRow> create(
          FactionRelationshipsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, FactionRelationshipsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<FactionRelationshipRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<FactionRelationshipRow>> getByFactionId(String factionId) =>
      _repo.getByFactionId(factionId);

  Future<FactionRelationshipRow?> getByFactionPair(
          String sourceId, String targetId) =>
      _repo.getByFactionPair(sourceId, targetId);

  /// 势力关系统计（按项目聚合）
  Future<FactionRelationshipStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    var bidirectional = 0;
    var intensitySum = 0;
    for (final r in list) {
      final t = (r.relationshipType).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (r.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      if (r.isBidirectional) bidirectional++;
      intensitySum += r.intensity;
    }
    final avgIntensity = list.isEmpty ? 0.0 : intensitySum / list.length;
    return FactionRelationshipStats(
      totalRelationships: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      bidirectionalCount: bidirectional,
      averageIntensity: avgIntensity,
    );
  }
}
