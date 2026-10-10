// 项目聚合统计服务
//
// 对应 C# 版 Application/Services/ProjectService.cs 的 `GetProjectStatisticsAsync`，
// 但用强类型 [ProjectStats] 取代 `Dictionary<string, object>`（C# 原版仅返回
// Name/CreatedAt/UpdatedAt/Status/Progress，并未聚合子实体计数）。
//
// 本服务以只读聚合为主：聚合项目下全部实体类目的数量与总字数，
// 供项目概览页的分类卡片（双击可进入对应实体页）使用。
//
// 唯一例外是 `progress` —— 它是「已完成章 / 总章数」的派生量，读取时顺带
// 自愈回写 `projects.progress`（该列历史上无人写过，恒为 0）。回写只动这一列，
// 失败被吞掉，不影响统计返回。
// 异常直接上抛，由 UI 层统一处理。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/volume_repository.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/character_repository.dart';
import 'package:novelcraft/data/repositories/faction_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/data/repositories/world_setting_repository.dart';
import 'package:novelcraft/data/repositories/race_repository.dart';
import 'package:novelcraft/data/repositories/resource_repository.dart';
import 'package:novelcraft/data/repositories/secret_realm_repository.dart';
import 'package:novelcraft/data/repositories/cultivation_system_repository.dart';
import 'package:novelcraft/data/repositories/political_system_repository.dart';
import 'package:novelcraft/data/repositories/currency_system_repository.dart';
import 'package:novelcraft/data/repositories/relationship_network_repository.dart';
import 'package:novelcraft/data/repositories/timeline_event_repository.dart';
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
    required WorldSettingRepository worldSettingRepository,
    required RaceRepository raceRepository,
    required ResourceRepository resourceRepository,
    required SecretRealmRepository secretRealmRepository,
    required CultivationSystemRepository cultivationSystemRepository,
    required PoliticalSystemRepository politicalSystemRepository,
    required CurrencySystemRepository currencySystemRepository,
    required RelationshipNetworkRepository relationshipNetworkRepository,
    required TimelineEventRepository timelineEventRepository,
  })  : _volumeRepo = volumeRepository,
        _chapterRepo = chapterRepository,
        _characterRepo = characterRepository,
        _factionRepo = factionRepository,
        _plotRepo = plotRepository,
        _worldSettingRepo = worldSettingRepository,
        _raceRepo = raceRepository,
        _resourceRepo = resourceRepository,
        _secretRealmRepo = secretRealmRepository,
        _cultivationSystemRepo = cultivationSystemRepository,
        _politicalSystemRepo = politicalSystemRepository,
        _currencySystemRepo = currencySystemRepository,
        _relationshipNetworkRepo = relationshipNetworkRepository,
        _timelineEventRepo = timelineEventRepository;

  final ProjectRepository _projectRepo;
  final VolumeRepository _volumeRepo;
  final ChapterRepository _chapterRepo;
  final CharacterRepository _characterRepo;
  final FactionRepository _factionRepo;
  final PlotRepository _plotRepo;
  final WorldSettingRepository _worldSettingRepo;
  final RaceRepository _raceRepo;
  final ResourceRepository _resourceRepo;
  final SecretRealmRepository _secretRealmRepo;
  final CultivationSystemRepository _cultivationSystemRepo;
  final PoliticalSystemRepository _politicalSystemRepo;
  final CurrencySystemRepository _currencySystemRepo;
  final RelationshipNetworkRepository _relationshipNetworkRepo;
  final TimelineEventRepository _timelineEventRepo;

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
    final worldSettings = await _worldSettingRepo.getByProjectId(projectId);
    final races = await _raceRepo.getByProjectId(projectId);
    final resources = await _resourceRepo.getByProjectId(projectId);
    final secretRealms = await _secretRealmRepo.getByProjectId(projectId);
    final cultivationSystems =
        await _cultivationSystemRepo.getByProjectId(projectId);
    final politicalSystems =
        await _politicalSystemRepo.getByProjectId(projectId);
    final currencySystems = await _currencySystemRepo.getByProjectId(projectId);
    final relationshipNetworks =
        await _relationshipNetworkRepo.getByProjectId(projectId);
    final timelineEvents = await _timelineEventRepo.getByProjectId(projectId);

    final int wordCount =
        chapters.fold(0, (int sum, c) => sum + c.wordCount);

    // 完成进度是**派生量**：已完成章 / 总章数（见 [progressFromChapterCounts]）。
    //
    // ⚠ 自愈回写：此前工程里**没有任何代码**写过 `projects.progress`，
    // 概览页与项目管理页读到的恒是 0（用户实测「项目进度未随编写完成度更新」）。
    // 这里在计算的同时顺带把值写回 —— 只要打开一次概览页，项目卡片上的进度
    // 也跟着修正，不必重跑生成。回写只动 `progress` 一列，不动 `updated_at`
    // （见 [ProjectRepository.updateProgress]），免得「最近编辑」被刷成刚刚。
    final int completedChapters =
        chapters.where((ChapterRow c) => c.status == 'Completed').length;
    final double progress =
        progressFromChapterCounts(completedChapters, chapters.length);
    if (project.progress != progress.round()) {
      try {
        await _projectRepo.updateProgress(projectId, progress.round());
      } on Object {
        // 回写只是自愈收益，失败不能拖垮统计读取。
      }
    }

    return ProjectStats(
      volumeCount: volumes.length,
      chapterCount: chapters.length,
      characterCount: characters.length,
      wordCount: wordCount,
      progress: progress,
      lastEditedAt: project.updatedAt,
      factionCount: factions.length,
      plotCount: plots.length,
      worldSettingCount: worldSettings.length,
      raceCount: races.length,
      resourceCount: resources.length,
      secretRealmCount: secretRealms.length,
      cultivationSystemCount: cultivationSystems.length,
      politicalSystemCount: politicalSystems.length,
      currencySystemCount: currencySystems.length,
      relationshipNetworkCount: relationshipNetworks.length,
      timelineEventCount: timelineEvents.length,
    );
  }
}
