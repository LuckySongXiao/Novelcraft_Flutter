import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 导航目标 —— 对应 C# WPF 的 Services/NavigationService.cs 里的 NavigationTarget
///
/// ⚠ C# 版本存在**两套并行导航**：新的 NavigationService 只覆盖这 14 个目标，
/// 而 MainWindow 里另有约 20 处 `xxx_Click` 直接往 MainContentArea 塞控件
/// （世界观各体系页全走老路径）。Dart 侧统一为一套，全部目标都走这里。
enum NavigationTarget {
  projectManagement,
  projectOverview,
  volumeManagement,
  characterManagement,
  timeline,
  relationshipNetwork,
  factionManagement,
  plotManagement,
  aiCollaboration,
  aiConfiguration,
  importExport,
  worldSettingManagement,
  dialogGeneration,
  projectHealthCheck,
  // 世界观体系页（C# 侧走老 Click 路径，Dart 侧纳入统一导航）
  cultivationSystem,
  politicalSystem,
  secretRealm,
  resource,
  race,
  currencySystem,
  settings,

  // ---------- 14 个数据库实体页（世界观 + 关系/事件/层级）----------
  // race/resource/secretRealm/cultivationSystem/politicalSystem/
  // currencySystem/relationshipNetwork 复用上方已定义的枚举值，以下 7 个为新增。
  timelineEventManagement,
  characterEventManagement,
  characterRelationshipManagement,
  factionRelationshipManagement,
  raceRelationshipManagement,
  cultivationLevelManagement,
  politicalPositionManagement,

  // ---------- 10 个「JSON 文件存储」的体系 ----------
  // 这 10 项在 C# 版里连数据库表都没有，数据以 JSON 文件存于
  // %AppData%\NovelManagement\{scope}\{projectId}.json，且只能从 MainWindow 的
  // 老式 Click 事件进入。Dart 侧统一收编为导航目标。
  techniques, // 功法体系
  equipment, // 装备体系
  pets, // 灵宠体系
  treasures, // 灵宝体系
  businesses, // 商业体系
  professions, // 职业体系
  judicial, // 司法体系
  population, // 生民体系
  maps, // 地图体系
  dimensions, // 维度体系
}

/// 导航目标 → JSON 体系 scope 的映射
///
/// 返回 null 表示该目标不是「JSON 文件存储」的体系
/// （即它有数据库表，或根本不是体系页）。
abstract final class SystemScopes {
  static const _map = <NavigationTarget, String>{
    NavigationTarget.techniques: 'techniques',
    NavigationTarget.equipment: 'equipment',
    NavigationTarget.pets: 'pets',
    NavigationTarget.treasures: 'treasures',
    NavigationTarget.businesses: 'businesses',
    NavigationTarget.professions: 'professions',
    NavigationTarget.judicial: 'judicial',
    NavigationTarget.population: 'population',
    NavigationTarget.maps: 'maps',
    NavigationTarget.dimensions: 'dimensions',
  };

  static String? of(NavigationTarget t) => _map[t];

  static bool isJsonSystem(NavigationTarget t) => _map.containsKey(t);
}

/// 14 个「数据库表」支撑的实体页（区别于 10 个 JSON 文件体系）。
///
/// 这些目标统一走 [entityConfigByTarget] → [EntityPage]，
/// 并收纳进侧边栏「世界观」分组的二级导航。
const dbEntityTargets = <NavigationTarget>[
  NavigationTarget.worldSettingManagement,
  NavigationTarget.race,
  NavigationTarget.resource,
  NavigationTarget.secretRealm,
  NavigationTarget.cultivationSystem,
  NavigationTarget.politicalSystem,
  NavigationTarget.currencySystem,
  NavigationTarget.relationshipNetwork,
  NavigationTarget.timelineEventManagement,
  NavigationTarget.characterEventManagement,
  NavigationTarget.characterRelationshipManagement,
  NavigationTarget.factionRelationshipManagement,
  NavigationTarget.raceRelationshipManagement,
  NavigationTarget.cultivationLevelManagement,
  NavigationTarget.politicalPositionManagement,
];

/// 属于「世界观」分组的目标（用于侧边栏二级导航）：
/// 数据库实体 + 10 个 JSON 文件体系。
const worldGroupTargets = <NavigationTarget>[
  ...dbEntityTargets,
  NavigationTarget.techniques,
  NavigationTarget.equipment,
  NavigationTarget.pets,
  NavigationTarget.treasures,
  NavigationTarget.businesses,
  NavigationTarget.professions,
  NavigationTarget.judicial,
  NavigationTarget.population,
  NavigationTarget.maps,
  NavigationTarget.dimensions,
];

/// 属于「AI 助手」分组的目标（侧边栏二级导航）。
const aiGroupTargets = <NavigationTarget>[
  NavigationTarget.aiCollaboration,
  NavigationTarget.aiConfiguration,
  NavigationTarget.dialogGeneration,
  NavigationTarget.projectHealthCheck,
];

/// 导航上下文 —— 对应 C# 的 NavigationContext
class NavigationContext {
  const NavigationContext({
    this.projectId,
    this.projectName,
    this.payload,
  });

  final String? projectId;
  final String? projectName;

  /// 传递给目标页的附加数据（如要定位到的卷宗/章节/实体）
  final Object? payload;
}

/// 导航历史项
class NavigationHistoryEntry {
  NavigationHistoryEntry(this.target, this.context);

  final NavigationTarget target;
  final NavigationContext context;
}

/// 导航服务
///
/// 与 C# 版的差异：C# 的 `RenderNavigationView` 每次 new 一个 UserControl 且不做缓存；
/// Dart 侧同样每次重建页面 Widget，但由 Riverpod 管理状态，
/// 避免 C# 里"导航回来后列表重新加载"的问题。
class NavigationService extends Notifier<NavigationHistoryEntry> {
  @override
  NavigationHistoryEntry build() {
    return NavigationHistoryEntry(
      NavigationTarget.projectManagement,
      const NavigationContext(),
    );
  }

  final List<NavigationHistoryEntry> _history = [];

  bool get canGoBack => _history.isNotEmpty;

  void navigateTo(NavigationTarget target, {NavigationContext? context}) {
    _history.add(state);
    state = NavigationHistoryEntry(target, context ?? state.context);
  }

  /// 在保持当前目标的情况下更新上下文（例如切换当前项目）
  void updateContext(NavigationContext context) {
    state = NavigationHistoryEntry(state.target, context);
  }

  void goBack() {
    if (_history.isEmpty) return;
    state = _history.removeLast();
  }
}

final navigationProvider =
    NotifierProvider<NavigationService, NavigationHistoryEntry>(
  NavigationService.new,
);

/// 当前选中的项目 ID —— 全局共享
///
/// C# 版把当前项目存在 ConfigurationService 的运行时状态里；
/// Dart 侧由 Riverpod 托管，侧边栏与所有页面共享同一份状态。
class CurrentProjectId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;

  void clear() => state = null;
}

final currentProjectIdProvider =
    NotifierProvider<CurrentProjectId, String?>(CurrentProjectId.new);
