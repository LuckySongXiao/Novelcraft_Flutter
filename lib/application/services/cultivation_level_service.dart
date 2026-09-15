// 修炼等级服务
//
// 对应 C# 版 Application/Services（CultivationLevel 在 C# 中由 CultivationLevelBackfillService
// 与 CultivationSystemService 内聚管理；Dart 侧按任务要求拆为独立服务）。
//
// 差异：等级实体本身不带 projectId，需经所属修炼体系反查；统计通过注入的
// [CultivationSystemRepository] 枚举项目内体系，再按体系聚合等级。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/cultivation_level_repository.dart';
import 'package:novelcraft/data/repositories/cultivation_system_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 修炼等级服务
class CultivationLevelService {
  CultivationLevelService(
    this._repo, {
    required CultivationSystemRepository cultivationSystemRepository,
  }) : _systemRepo = cultivationSystemRepository;

  final CultivationLevelRepository _repo;
  final CultivationSystemRepository _systemRepo;

  Future<CultivationLevelRow?> getById(String id) => _repo.getById(id);

  Future<CultivationLevelRow> create(CultivationLevelsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, CultivationLevelsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  /// 等级实体无 projectId，提供全量读取供实体页聚合展示。
  Future<List<CultivationLevelRow>> getAll() => _repo.getAll();

  Future<List<CultivationLevelRow>> getBySystemId(String systemId) =>
      _repo.getBySystemId(systemId);

  Future<CultivationLevelRow?> getNextLevel(String systemId, int orderIndex) =>
      _repo.getNextLevel(systemId, orderIndex);

  Future<CultivationLevelRow?> getPreviousLevel(String systemId, int orderIndex) =>
      _repo.getPreviousLevel(systemId, orderIndex);

  /// 修炼等级统计（按项目聚合：遍历项目内体系，累加各体系等级）
  Future<CultivationLevelStats> getStats(String projectId) async {
    final systems = await _systemRepo.getByProjectId(projectId);
    final bySystem = <String, int>{};
    var total = 0;
    var orderSum = 0;
    for (final sys in systems) {
      final levels = await _repo.getBySystemId(sys.id);
      bySystem[sys.id] = levels.length;
      total += levels.length;
      for (final l in levels) {
        orderSum += l.orderIndex;
      }
    }
    final avgOrder = total == 0 ? 0.0 : orderSum / total;
    return CultivationLevelStats(
      totalLevels: total,
      bySystem: bySystem,
      averageOrderIndex: avgOrder,
    );
  }
}
