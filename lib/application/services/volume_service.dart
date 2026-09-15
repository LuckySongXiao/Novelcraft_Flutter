// 卷宗服务
//
// 对应 C# 版 Application/Services/VolumeService.cs。
//
// 与 C# 版差异：
// 1. 去掉 `try/catch(rethrow)` 模板，异常上抛。
// 2. 原 `UpdateVolumeOrderAsync` 依赖 EF 跟踪实体逐个 `Update`；Dart 侧复用
//    Repository 的 `updateOrder(volumeId, newIndex)` 批量写入 orderIndex。
// 3. 统计从 `Dictionary<string, object>` 改为强类型 [VolumeStats]。
// 4. C# 的 `WordCount` 在 Dart 表为 `actualWordCount`，统计总字数用该字段。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/volume_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 卷宗服务
class VolumeService {
  VolumeService(this._repo);
  final VolumeRepository _repo;

  Future<VolumeRow?> getById(String id) => _repo.getById(id);

  Future<List<VolumeRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<VolumeRow> create(VolumesCompanion companion) => _repo.create(companion);

  Future<bool> updateById(String id, VolumesCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<VolumeRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<VolumeRow>> getByStatus(String projectId, String status) =>
      _repo.getByStatus(projectId, status);

  /// 计算新建卷宗的默认序号
  Future<int> getNextOrderIndex(String projectId) =>
      _repo.getNextOrderIndex(projectId);

  /// 按给定顺序重排卷宗（幂等：仅更新出现在列表中的卷宗的 orderIndex）。
  ///
  /// 对应 C# `UpdateVolumeOrderAsync` —— 把列表下标 +1 写入 orderIndex。
  Future<bool> updateVolumeOrder(String projectId, List<String> orderedIds) async {
    final volumes = await _repo.getByProjectId(projectId);
    final indexById = {for (final v in volumes) v.id: v};
    for (var i = 0; i < orderedIds.length; i++) {
      if (indexById.containsKey(orderedIds[i])) {
        await _repo.updateOrder(orderedIds[i], i + 1);
      }
    }
    return true;
  }

  /// 卷宗统计（按项目聚合）
  Future<VolumeStats> getStats(String projectId) async {
    final volumes = await _repo.getByProjectId(projectId);
    final completed = volumes.where((v) => v.status == '已完成').length;
    final inProgress = volumes.where((v) => v.status == '进行中').length;
    final planned = volumes.where((v) => v.status == '计划中').length;
    final totalWords = volumes.fold(0, (sum, v) => sum + v.actualWordCount);
    final avg = volumes.isEmpty
        ? 0.0
        : totalWords / volumes.length;
    return VolumeStats(
      totalVolumes: volumes.length,
      completedVolumes: completed,
      inProgressVolumes: inProgress,
      plannedVolumes: planned,
      totalWordCount: totalWords,
      averageWordCount: avg,
    );
  }
}
