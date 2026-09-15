// 章节服务
//
// 对应 C# 版 Application/Services/ChapterService.cs。
//
// 与 C# 版差异：
// 1. 去掉 `try/catch(rethrow)` 模板。
// 2. `UpdateChapterOrderAsync` 复用 Repository 的 `updateOrder(chapterId, newIndex)`，
//    逐个写入 orderIndex。
// 3. 统计从 `Dictionary<string, object>` 改为强类型 [ChapterStats]，按 volumeId 聚合
//    （C# 侧签名即按 volumeId 统计）。
// 4. C# 的 `CountWords(string)` 只是 `text.Length` 的简单实现，字数实际由写入方维护到
//    `wordCount` 列，统计直接求和该列。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 章节服务
class ChapterService {
  ChapterService(this._repo);
  final ChapterRepository _repo;

  Future<ChapterRow?> getById(String id) => _repo.getById(id);

  Future<List<ChapterRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<ChapterRow> create(ChaptersCompanion companion) => _repo.create(companion);

  Future<bool> updateById(String id, ChaptersCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<ChapterRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<ChapterRow>> getByVolumeId(String volumeId) =>
      _repo.getByVolumeId(volumeId);

  Future<List<ChapterRow>> getByStatus(String projectId, String status) =>
      _repo.getByStatus(projectId, status);

  /// 计算新建章节的默认序号（按所属卷宗）
  Future<int> getNextOrderIndex(String volumeId) =>
      _repo.getNextOrderIndex(volumeId);

  /// 按给定顺序重排章节（幂等：仅更新出现在列表中的章节的 orderIndex）。
  ///
  /// 对应 C# `UpdateChapterOrderAsync`。
  Future<bool> updateChapterOrder(String volumeId, List<String> orderedIds) async {
    final chapters = await _repo.getByVolumeId(volumeId);
    final indexById = {for (final c in chapters) c.id: c};
    for (var i = 0; i < orderedIds.length; i++) {
      if (indexById.containsKey(orderedIds[i])) {
        await _repo.updateOrder(orderedIds[i], i + 1);
      }
    }
    return true;
  }

  /// 章节统计（按卷宗聚合）
  Future<ChapterStats> getStats(String volumeId) async {
    final chapters = await _repo.getByVolumeId(volumeId);
    final completed = chapters.where((c) => c.status == '已完成').length;
    final inProgress = chapters.where((c) => c.status == '进行中').length;
    final planned = chapters.where((c) => c.status == '计划中').length;
    final totalWords = chapters.fold(0, (sum, c) => sum + c.wordCount);
    final avg = chapters.isEmpty ? 0.0 : totalWords / chapters.length;
    final maxWords = chapters.isEmpty
        ? 0
        : chapters.map((c) => c.wordCount).reduce((a, b) => a > b ? a : b);
    final minWords = chapters.isEmpty
        ? 0
        : chapters.map((c) => c.wordCount).reduce((a, b) => a < b ? a : b);
    return ChapterStats(
      totalChapters: chapters.length,
      completedChapters: completed,
      inProgressChapters: inProgress,
      plannedChapters: planned,
      totalWordCount: totalWords,
      averageWordCount: avg,
      maxWordCount: maxWords,
      minWordCount: minWords,
    );
  }
}
