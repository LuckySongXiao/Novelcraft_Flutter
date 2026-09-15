// 角色关系服务
//
// 对应 C# 版 Application/Services/CharacterRelationshipService.cs。
//
// 差异：去掉 `try/catch(rethrow)` 模板；统计从 `Dictionary<string, object>` 改为
// 强类型 [CharacterRelationshipStats]。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/character_relationship_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 角色关系服务
class CharacterRelationshipService {
  CharacterRelationshipService(this._repo);
  final CharacterRelationshipRepository _repo;

  Future<CharacterRelationshipRow?> getById(String id) => _repo.getById(id);

  Future<List<CharacterRelationshipRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<CharacterRelationshipRow> create(
          CharacterRelationshipsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, CharacterRelationshipsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<CharacterRelationshipRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<CharacterRelationshipRow>> getByCharacterId(String characterId) =>
      _repo.getByCharacterId(characterId);

  Future<CharacterRelationshipRow?> getByCharacterPair(
          String sourceId, String targetId) =>
      _repo.getByCharacterPair(sourceId, targetId);

  Future<List<CharacterRelationshipRow>> getByNetworkId(String networkId) =>
      _repo.getByNetworkId(networkId);

  /// 角色关系统计（按项目聚合）
  Future<CharacterRelationshipStats> getStats(String projectId) async {
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
    final avgIntensity =
        list.isEmpty ? 0.0 : intensitySum / list.length;
    return CharacterRelationshipStats(
      totalRelationships: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      bidirectionalCount: bidirectional,
      averageIntensity: avgIntensity,
    );
  }
}
