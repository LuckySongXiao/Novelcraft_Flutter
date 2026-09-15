// 剧情服务
//
// 对应 C# 版 Application/Services（Plot 在 C# 中由 PlotService 管理，Dart 侧按任务要求
// 落在 application 层）。
//
// 差异：统计从弱类型字典改为强类型 [PlotStats]。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 剧情服务
class PlotService {
  PlotService(this._repo);
  final PlotRepository _repo;

  Future<PlotRow?> getById(String id) => _repo.getById(id);

  Future<List<PlotRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<PlotRow> create(PlotsCompanion companion) => _repo.create(companion);

  Future<bool> updateById(String id, PlotsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<PlotRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<PlotRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<List<PlotRow>> getByStatus(String projectId, String status) =>
      _repo.getByStatus(projectId, status);

  Future<List<PlotRow>> getByPriority(String projectId, String priority) =>
      _repo.getByPriority(projectId, priority);

  Future<List<PlotRow>> getByChapterId(String chapterId) =>
      _repo.getByChapterId(chapterId);

  /// 剧情统计（按项目聚合）
  Future<PlotStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final statusStats = <String, int>{};
    final priorityStats = <String, int>{};
    var completed = 0;
    var progressSum = 0.0;
    for (final p in list) {
      final t = (p.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final s = (p.status).trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      final pr = (p.priority).trim();
      priorityStats[pr] = (priorityStats[pr] ?? 0) + 1;
      if (p.status == '已完成') completed++;
      progressSum += p.progress;
    }
    final avgProgress = list.isEmpty ? 0.0 : progressSum / list.length;
    return PlotStats(
      totalPlots: list.length,
      typeStatistics: typeStats,
      statusStatistics: statusStats,
      priorityStatistics: priorityStats,
      completedPlots: completed,
      averageProgress: avgProgress,
    );
  }
}
