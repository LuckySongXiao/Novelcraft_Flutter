// 关系网络服务
//
// 对应 C# 版 Application/Services/RelationshipNetworkService.cs。
//
// 保留的关键业务逻辑： `analyzeNetwork(networkId)` 返回强类型
// [RelationshipNetworkAnalysis]（节点数 / 边数 / 密度 / 中心角色），对应 C# 的
// `AnalyzeRelationshipAsync`（原返回 `Dictionary<string, object>`）。
//   - 节点数 = 网络内去重角色（中心角色 + 各关系涉及角色）
//   - 边数 = 归属该网络的角色关系数
//   - 密度 = 边数 / (节点数 × (节点数 − 1) / 2)（无向图，节点数 < 2 记为 0）
// 统计从弱类型字典改为强类型 [RelationshipNetworkStats]；去掉 `try/catch(rethrow)` 模板。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/relationship_network_repository.dart';
import 'package:novelcraft/data/repositories/character_relationship_repository.dart';
import 'package:novelcraft/data/repositories/character_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 关系网络服务
class RelationshipNetworkService {
  RelationshipNetworkService(
    this._repo, {
    required CharacterRelationshipRepository characterRelationshipRepository,
    required CharacterRepository characterRepository,
  })  : _relationshipRepo = characterRelationshipRepository,
        _characterRepo = characterRepository;

  final RelationshipNetworkRepository _repo;
  final CharacterRelationshipRepository _relationshipRepo;
  final CharacterRepository _characterRepo;

  Future<RelationshipNetworkRow?> getById(String id) => _repo.getById(id);

  Future<List<RelationshipNetworkRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<RelationshipNetworkRow> create(RelationshipNetworksCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, RelationshipNetworksCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<RelationshipNetworkRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<RelationshipNetworkRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<List<RelationshipNetworkRow>> getByStatus(String projectId, String status) =>
      _repo.getByStatus(projectId, status);

  Future<List<RelationshipNetworkRow>> getByCentralCharacter(
          String characterId) =>
      _repo.getByCentralCharacter(characterId);

  /// 分析关系网络：节点数 / 边数 / 密度 / 中心角色（强类型）。
  Future<RelationshipNetworkAnalysis> analyzeNetwork(String networkId) async {
    final network = await _repo.getById(networkId);
    if (network == null) {
      throw ArgumentError('关系网络不存在，ID: $networkId');
    }
    final relationships = await _relationshipRepo.getByNetworkId(networkId);
    final nodeIds = <String>{};
    for (final r in relationships) {
      nodeIds.add(r.sourceCharacterId);
      nodeIds.add(r.targetCharacterId);
    }
    String? centralId = network.centralCharacterId;
    if (centralId != null && centralId.isNotEmpty) {
      nodeIds.add(centralId);
    }
    final nodeCount = nodeIds.length;
    final edgeCount = relationships.length;
    final density = nodeCount < 2
        ? 0.0
        : edgeCount / (nodeCount * (nodeCount - 1) / 2);
    String? centralName;
    if (centralId != null && centralId.isNotEmpty) {
      final c = await _characterRepo.getById(centralId);
      centralName = c?.name;
    }
    return RelationshipNetworkAnalysis(
      networkId: networkId,
      networkName: network.name,
      nodeCount: nodeCount,
      edgeCount: edgeCount,
      density: density,
      complexity: network.complexity,
      influence: network.influence,
      type: network.type,
      status: network.status,
      centralCharacterId: centralId,
      centralCharacterName: centralName,
    );
  }

  /// 关系网络统计（按项目聚合）
  Future<RelationshipNetworkStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    var complexitySum = 0;
    var stabilitySum = 0;
    var influenceSum = 0;
    var totalRelationships = 0;
    for (final n in list) {
      final t = (n.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (n.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      complexitySum += n.complexity;
      stabilitySum += n.stability;
      influenceSum += n.influence;
      totalRelationships += (await _relationshipRepo.getByNetworkId(n.id)).length;
    }
    final avgComplexity = list.isEmpty ? 0.0 : complexitySum / list.length;
    final avgStability = list.isEmpty ? 0.0 : stabilitySum / list.length;
    final avgInfluence = list.isEmpty ? 0.0 : influenceSum / list.length;
    return RelationshipNetworkStats(
      totalNetworks: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      averageComplexity: avgComplexity,
      averageStability: avgStability,
      averageInfluence: avgInfluence,
      totalRelationships: totalRelationships,
    );
  }
}
