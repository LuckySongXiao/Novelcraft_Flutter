/// 应用层强类型统计/结果模型
///
/// 对应 C# 版 15 处 `GetXxxStatisticsAsync` 返回 `Dictionary<string, object>` 的
/// 弱类型逃生舱。Dart 侧一律改为强类型类，杜绝 `Map<String, Object?>`。
///
/// 同时承载 CharacterService 的引用检查 / 安全删除结果、RelationshipNetworkService
/// 的网络分析结果——这些也都是 C# 用 `CharacterReferenceInfo` / `CharacterDeleteResult` /
/// `AnalyzeRelationshipAsync` 字典返回的强类型化版本。
library;

/// 项目聚合统计（对应 ProjectService.GetProjectStatisticsAsync 的强类型化）
///
/// C# 原版只返回 Name/CreatedAt/UpdatedAt/Status/Progress；这里按任务要求补齐
/// 卷宗/章节/角色计数与总字数，使 UI 无需再多次往返拼装。
class ProjectStats {
  const ProjectStats({
    required this.volumeCount,
    required this.chapterCount,
    required this.characterCount,
    required this.wordCount,
    required this.progress,
    this.lastEditedAt,
    this.factionCount = 0,
    this.plotCount = 0,
    this.worldSettingCount = 0,
    this.raceCount = 0,
    this.resourceCount = 0,
    this.secretRealmCount = 0,
    this.cultivationSystemCount = 0,
    this.politicalSystemCount = 0,
    this.currencySystemCount = 0,
    this.relationshipNetworkCount = 0,
    this.timelineEventCount = 0,
  });

  final int volumeCount;
  final int chapterCount;
  final int characterCount;
  final int wordCount;

  /// 项目完成进度 0-100（来自 ProjectRow.progress）
  final double progress;
  final DateTime? lastEditedAt;

  final int factionCount;
  final int plotCount;

  // ---- 分类补全（项目概览全部实体入口）----
  final int worldSettingCount;
  final int raceCount;
  final int resourceCount;
  final int secretRealmCount;
  final int cultivationSystemCount;
  final int politicalSystemCount;
  final int currencySystemCount;
  final int relationshipNetworkCount;
  final int timelineEventCount;
}

/// 卷宗统计（对应 VolumeService.GetVolumeStatisticsAsync）
class VolumeStats {
  const VolumeStats({
    required this.totalVolumes,
    required this.completedVolumes,
    required this.inProgressVolumes,
    required this.plannedVolumes,
    required this.totalWordCount,
    required this.averageWordCount,
  });

  final int totalVolumes;
  final int completedVolumes;
  final int inProgressVolumes;
  final int plannedVolumes;
  final int totalWordCount;
  final double averageWordCount;
}

/// 章节统计（对应 ChapterService.GetChapterStatisticsAsync，按 volumeId 统计）
class ChapterStats {
  const ChapterStats({
    required this.totalChapters,
    required this.completedChapters,
    required this.inProgressChapters,
    required this.plannedChapters,
    required this.totalWordCount,
    required this.averageWordCount,
    required this.maxWordCount,
    required this.minWordCount,
  });

  final int totalChapters;
  final int completedChapters;
  final int inProgressChapters;
  final int plannedChapters;
  final int totalWordCount;
  final double averageWordCount;
  final int maxWordCount;
  final int minWordCount;
}

/// 角色统计（对应 CharacterService.GetCharacterStatisticsAsync）
class CharacterStats {
  const CharacterStats({
    required this.totalCharacters,
    required this.typeStatistics,
    required this.genderStatistics,
    required this.statusStatistics,
    required this.mainCharacters,
    required this.supportingCharacters,
    required this.minorCharacters,
    required this.averageImportance,
  });

  final int totalCharacters;

  /// 按类型分组计数（如 主角/配角/龙套）
  final Map<String, int> typeStatistics;

  /// 按性别分组计数（null/空白归为「未知」）
  final Map<String, int> genderStatistics;

  /// 按状态分组计数
  final Map<String, int> statusStatistics;

  final int mainCharacters;
  final int supportingCharacters;
  final int minorCharacters;
  final double averageImportance;
}

/// 势力统计（对应 FactionService.GetFactionStatisticsAsync 的强类型化）
class FactionStats {
  const FactionStats({
    required this.totalFactions,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.averagePowerLevel,
    required this.averageInfluence,
    required this.highPowerFactions,
  });

  final int totalFactions;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final double averagePowerLevel;
  final double averageInfluence;
  final int highPowerFactions;
}

/// 剧情统计（对应 PlotService 的项目级统计）
class PlotStats {
  const PlotStats({
    required this.totalPlots,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.priorityStatistics,
    required this.completedPlots,
    required this.averageProgress,
  });

  final int totalPlots;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final Map<String, int> priorityStatistics;
  final int completedPlots;
  final double averageProgress;
}

/// 种族统计（对应 RaceService.GetRaceStatisticsAsync）
class RaceStats {
  const RaceStats({
    required this.totalRaces,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.averagePowerLevel,
    required this.averageInfluence,
    required this.endangeredRaces,
  });

  final int totalRaces;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final double averagePowerLevel;
  final double averageInfluence;
  final int endangeredRaces;
}

/// 世界观设定统计（WorldSettingService 的项目级统计）
class WorldSettingStats {
  const WorldSettingStats({
    required this.totalSettings,
    required this.typeStatistics,
    required this.categoryStatistics,
    required this.rootCount,
    required this.maxDepth,
  });

  final int totalSettings;
  final Map<String, int> typeStatistics;
  final Map<String, int> categoryStatistics;

  /// 根节点（parentId 为空）数量
  final int rootCount;

  /// 树最大深度
  final int maxDepth;
}

/// 修炼体系统计（对应 CultivationSystemService.GetCultivationSystemStatisticsAsync）
class CultivationSystemStats {
  const CultivationSystemStats({
    required this.totalSystems,
    required this.typeStatistics,
    required this.averageDifficulty,
    required this.totalLevels,
    required this.averageMaxLevel,
  });

  final int totalSystems;
  final Map<String, int> typeStatistics;
  final double averageDifficulty;
  final int totalLevels;
  final double averageMaxLevel;
}

/// 修炼等级统计（CultivationLevelService 的项目级统计，按所属体系聚合）
class CultivationLevelStats {
  const CultivationLevelStats({
    required this.totalLevels,
    required this.bySystem,
    required this.averageOrderIndex,
  });

  final int totalLevels;

  /// 每个修炼体系下的等级数
  final Map<String, int> bySystem;
  final double averageOrderIndex;
}

/// 政治体系统计（对应 PoliticalSystemService.GetPoliticalSystemStatisticsAsync）
class PoliticalSystemStats {
  const PoliticalSystemStats({
    required this.totalSystems,
    required this.typeStatistics,
    required this.averageStability,
    required this.averageInfluence,
    required this.totalPositions,
  });

  final int totalSystems;
  final Map<String, int> typeStatistics;
  final double averageStability;
  final double averageInfluence;
  final int totalPositions;
}

/// 政治职位统计（PoliticalPositionService 的项目级统计）
class PoliticalPositionStats {
  const PoliticalPositionStats({
    required this.totalPositions,
    required this.bySystem,
    required this.averageLevel,
  });

  final int totalPositions;

  /// 每个政治体系下的职位数量
  final Map<String, int> bySystem;
  final double averageLevel;
}

/// 货币体系统计（对应 CurrencySystemService.GetCurrencySystemStatisticsAsync）
class CurrencySystemStats {
  const CurrencySystemStats({
    required this.totalSystems,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.activeSystems,
    required this.averageStability,
    required this.averageInflation,
    required this.averageBaseValue,
    required this.highStabilitySystems,
  });

  final int totalSystems;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final int activeSystems;
  final double averageStability;
  final double averageInflation;
  final double averageBaseValue;
  final int highStabilitySystems;
}

/// 资源统计（对应 ResourceService.GetResourceStatisticsAsync）
class ResourceStats {
  const ResourceStats({
    required this.totalResources,
    required this.typeStatistics,
    required this.rarityStatistics,
    required this.statusStatistics,
    required this.averageEconomicValue,
    required this.totalEconomicValue,
  });

  final int totalResources;
  final Map<String, int> typeStatistics;
  final Map<String, int> rarityStatistics;
  final Map<String, int> statusStatistics;
  final double averageEconomicValue;
  final int totalEconomicValue;
}

/// 秘境统计（对应 SecretRealmService.GetExplorationStatisticsAsync）
class SecretRealmStats {
  const SecretRealmStats({
    required this.totalRealms,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.averageDangerLevel,
    required this.totalExplorations,
    required this.successfulExplorations,
  });

  final int totalRealms;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final double averageDangerLevel;
  final int totalExplorations;
  final int successfulExplorations;
}

/// 关系网络统计（对应 RelationshipNetworkService.GetNetworkStatisticsAsync）
class RelationshipNetworkStats {
  const RelationshipNetworkStats({
    required this.totalNetworks,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.averageComplexity,
    required this.averageStability,
    required this.averageInfluence,
    required this.totalRelationships,
  });

  final int totalNetworks;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final double averageComplexity;
  final double averageStability;
  final double averageInfluence;
  final int totalRelationships;
}

/// 角色关系统计（CharacterRelationshipService 的项目级统计）
class CharacterRelationshipStats {
  const CharacterRelationshipStats({
    required this.totalRelationships,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.bidirectionalCount,
    required this.averageIntensity,
  });

  final int totalRelationships;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final int bidirectionalCount;
  final double averageIntensity;
}

/// 势力关系统计（FactionRelationshipService 的项目级统计）
class FactionRelationshipStats {
  const FactionRelationshipStats({
    required this.totalRelationships,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.bidirectionalCount,
    required this.averageIntensity,
  });

  final int totalRelationships;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final int bidirectionalCount;
  final double averageIntensity;
}

/// 种族关系统计（RaceRelationshipService 的项目级统计）
class RaceRelationshipStats {
  const RaceRelationshipStats({
    required this.totalRelationships,
    required this.typeStatistics,
    required this.statusStatistics,
    required this.averageStrength,
  });

  final int totalRelationships;
  final Map<String, int> typeStatistics;
  final Map<String, int> statusStatistics;
  final double averageStrength;
}

/// 时间线事件统计（TimelineEventService 的项目级统计）
class TimelineEventStats {
  const TimelineEventStats({
    required this.totalEvents,
    required this.categoryStatistics,
    required this.statusStatistics,
    required this.participantCount,
  });

  final int totalEvents;
  final Map<String, int> categoryStatistics;
  final Map<String, int> statusStatistics;
  final int participantCount;
}

/// 角色引用检查结果（对应 C# CharacterReferenceInfo，强类型化）
///
/// C# 版仅给 `References` 一串中文描述文本；这里额外保留结构化计数，
/// 方便 UI 直接展示「被 N 个关系 / M 个事件引用」而无需再解析字符串。
class CharacterReferenceInfo {
  const CharacterReferenceInfo({
    required this.characterId,
    required this.isReferenced,
    required this.references,
    required this.relationshipCount,
    required this.eventCount,
    required this.timelineParticipantCount,
    this.factionName,
  });

  final String characterId;
  final bool isReferenced;

  /// 人类可读的引用描述列表（例如「存在 3 个角色关系」）
  final List<String> references;

  /// 作为源/目标的角色关系数
  final int relationshipCount;

  /// 角色履历事件数
  final int eventCount;

  /// 作为参与者的时间线事件数
  final int timelineParticipantCount;

  /// 所属势力名称（若角色归属于某势力，视为一种引用）
  final String? factionName;
}

/// 角色安全删除结果（对应 C# CharacterDeleteResult）
class CharacterDeleteResult {
  const CharacterDeleteResult({
    required this.success,
    required this.message,
    this.referenceInfo,
  });

  final bool success;
  final String message;
  final CharacterReferenceInfo? referenceInfo;
}

/// 关系网络分析结果（对应 C# AnalyzeRelationshipAsync 的字典返回，强类型化）
///
/// 节点数 = 网络内去重角色数（中心角色 + 各关系涉及角色）；
/// 边数 = 归属该网络的角色关系数；
/// 密度 = 边数 / (节点数 × (节点数 − 1) / 2)（无向图，节点数 < 2 时记为 0）。
class RelationshipNetworkAnalysis {
  const RelationshipNetworkAnalysis({
    required this.networkId,
    required this.networkName,
    required this.nodeCount,
    required this.edgeCount,
    required this.density,
    required this.complexity,
    required this.influence,
    this.type,
    this.status,
    this.centralCharacterId,
    this.centralCharacterName,
  });

  final String networkId;
  final String networkName;
  final int nodeCount;
  final int edgeCount;
  final double density;
  final int complexity;
  final int influence;
  final String? type;
  final String? status;
  final String? centralCharacterId;
  final String? centralCharacterName;
}
