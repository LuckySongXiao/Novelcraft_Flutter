// 项目聚合统计服务
//
// 对应 C# 版 Application/Services/ProjectService.cs 的 `GetProjectStatisticsAsync`，
// 但用强类型 [ProjectStats] 取代 `Dictionary<string, object>`（C# 原版仅返回
// Name/CreatedAt/UpdatedAt/Status/Progress，并未聚合子实体计数）。
//
// 本服务只读、不写：聚合项目下卷宗 / 章节 / 角色 / 势力 / 剧情的数量与总字数。
// 异常直接上抛，由 UI 层统一处理。
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/volume_repository.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/character_repository.dart';
import 'package:novelcraft/data/repositories/faction_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 项目聚合统计服务
class ProjectStatisticsService {
  ProjectStatisticsService(
    this._projectRepo, {
    required VolumeRepository volumeRepository,
    required ChapterRepository chapterRepository,
    required CharacterRepository characterRepository,
    required FactionRepository factionRepository,
    required PlotRepository plotRepository,
  })  : _volumeRepo = volumeRepository,
        _chapterRepo = chapterRepository,
        _characterRepo = characterRepository,
        _factionRepo = factionRepository,
        _plotRepo = plotRepository;

  final ProjectRepository _projectRepo;
  final VolumeRepository _volumeRepo;
  final ChapterRepository _chapterRepo;
  final CharacterRepository _characterRepo;
  final FactionRepository _factionRepo;
  final PlotRepository _plotRepo;

  /// 聚合计算项目统计信息
  Future<ProjectStats> getStats(String projectId) async {
    final project = await _projectRepo.getById(projectId);
    if (project == null) {
      throw ArgumentError('项目不存在，ID: $projectId');
    }
    final volumes = await _volumeRepo.getByProjectId(projectId);
    final chapters = await _chapterRepo.getByProjectId(projectId);
    final characters = await _characterRepo.getByProjectId(projectId);
    final factions = await _factionRepo.getByProjectId(projectId);
    final plots = await _plotRepo.getByProjectId(projectId);

    final wordCount =
        chapters.fold(0, (sum, c) => sum + c.wordCount);

    return ProjectStats(
      volumeCount: volumes.length,
      chapterCount: chapters.length,
      characterCount: characters.length,
      wordCount: wordCount,
      progress: project.progress.toDouble(),
      lastEditedAt: project.updatedAt,
      factionCount: factions.length,
      plotCount: plots.length,
    );
  }
}
