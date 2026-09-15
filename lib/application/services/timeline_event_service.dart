// 时间线事件服务
//
// 对应 C# 版 Application/Services（TimelineEvent 在 C# 中由 ProjectService 等内聚管理；
// Dart 侧按任务要求拆为独立服务）。
//
// 差异：统计从弱类型字典改为强类型 [TimelineEventStats]；参与者计数通过注入的
// [TimelineEventParticipantRepository] 累加。去掉 `try/catch(rethrow)` 模板。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/timeline_event_repository.dart';
import 'package:novelcraft/data/repositories/timeline_event_participant_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 时间线事件服务
class TimelineEventService {
  TimelineEventService(
    this._repo, {
    required TimelineEventParticipantRepository participantRepository,
  }) : _participantRepo = participantRepository;

  final TimelineEventRepository _repo;
  final TimelineEventParticipantRepository _participantRepo;

  Future<TimelineEventRow?> getById(String id) => _repo.getById(id);

  Future<List<TimelineEventRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<TimelineEventRow> create(TimelineEventsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, TimelineEventsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<TimelineEventRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<TimelineEventRow>> getByCategory(String projectId, String category) =>
      _repo.getByCategory(projectId, category);

  Future<List<TimelineEventRow>> getByDateRange(
          String projectId, DateTime start, DateTime end) =>
      _repo.getByDateRange(projectId, start, end);

  /// 时间线事件统计（按项目聚合，含参与者总数）
  Future<TimelineEventStats> getStats(String projectId) async {
    final list = await _repo.getByProjectId(projectId);
    final categoryStats = <String, int>{};
    final statusStats = <String, int>{};
    var participantCount = 0;
    for (final e in list) {
      final c = (e.category?.trim().isEmpty ?? true) ? '未分类' : e.category!.trim();
      categoryStats[c] = (categoryStats[c] ?? 0) + 1;
      final s = (e.status?.trim().isEmpty ?? true) ? '未分类' : e.status!.trim();
      statusStats[s] = (statusStats[s] ?? 0) + 1;
      participantCount += (await _participantRepo.getByEventId(e.id)).length;
    }
    return TimelineEventStats(
      totalEvents: list.length,
      categoryStatistics: categoryStats,
      statusStatistics: statusStats,
      participantCount: participantCount,
    );
  }
}
