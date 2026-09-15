// 政治职位服务
//
// 对应 C# 版 Application/Services（PoliticalPosition 在 C# 中由 PoliticalSystemService
// 内聚管理；Dart 侧按任务要求拆为独立服务）。
//
// 差异：职位实体经所属政治体系反查项目；统计通过注入的 [PoliticalSystemRepository]
// 枚举项目内体系聚合。强类型 [PoliticalPositionStats]。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/political_position_repository.dart';
import 'package:novelcraft/data/repositories/political_system_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 政治职位服务
class PoliticalPositionService {
  PoliticalPositionService(
    this._repo, {
    required PoliticalSystemRepository politicalSystemRepository,
  }) : _systemRepo = politicalSystemRepository;

  final PoliticalPositionRepository _repo;
  final PoliticalSystemRepository _systemRepo;

  Future<PoliticalPositionRow?> getById(String id) => _repo.getById(id);

  Future<PoliticalPositionRow> create(PoliticalPositionsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, PoliticalPositionsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  /// 职位实体无 projectId，提供全量读取供实体页聚合展示。
  Future<List<PoliticalPositionRow>> getAll() => _repo.getAll();

  Future<List<PoliticalPositionRow>> getBySystemId(String systemId) =>
      _repo.getBySystemId(systemId);

  Future<PoliticalPositionRow?> getByLevel(String systemId, int level) =>
      _repo.getByLevel(systemId, level);

  Future<PoliticalPositionRow?> getHighestLevel(String systemId) =>
      _repo.getHighestLevel(systemId);

  Future<PoliticalPositionRow?> getLowestLevel(String systemId) =>
      _repo.getLowestLevel(systemId);

  /// 政治职位统计（按项目聚合）
  Future<PoliticalPositionStats> getStats(String projectId) async {
    final systems = await _systemRepo.getByProjectId(projectId);
    final bySystem = <String, int>{};
    var total = 0;
    var levelSum = 0;
    for (final sys in systems) {
      final positions = await _repo.getBySystemId(sys.id);
      bySystem[sys.id] = positions.length;
      total += positions.length;
      for (final p in positions) {
        levelSum += p.level;
      }
    }
    final avgLevel = total == 0 ? 0.0 : levelSum / total;
    return PoliticalPositionStats(
      totalPositions: total,
      bySystem: bySystem,
      averageLevel: avgLevel,
    );
  }
}
