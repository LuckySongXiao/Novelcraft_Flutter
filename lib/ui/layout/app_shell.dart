import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import 'navigation.dart';
import '../pages/placeholder_page.dart';
import '../pages/project_management_page.dart';
import '../pages/settings_page.dart';
import '../pages/project_overview_page.dart';
import '../pages/timeline_page.dart';
import '../pages/import_export_page.dart';
import '../pages/entity_configs.dart';
import '../pages/entity_page.dart';
import '../pages/system_configs.dart';
import '../pages/world_system_page.dart';
import '../pages/ai_configuration_page.dart';
import '../pages/ai_collaboration_page.dart';
import '../pages/dialog_generation_page.dart';
import '../pages/project_health_check_page.dart';

/// 应用外壳 —— 对应 C# 的 MainWindow.xaml
///
/// C# 版结构：3 行 Grid = 标题栏 / (侧边栏 300px + GridSplitter + 内容区 + Copilot抽屉) / StatusBar。
/// Dart 侧用 NavigationRail + Expanded 实现等价布局；
/// GridSplitter 的手工拖拽换成了固定宽度 + 折叠按钮（移动端与 Web 更友好）。
///
/// ⚠ C# 版侧边栏展开状态用 `sidebar_state.json` + VisualTreeHelper 遍历可视树来持久化。
/// Flutter 没有可视树查询，因此改为**显式的状态模型** + shared_preferences 保存。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _extended = true;

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(navigationProvider);
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleFor(nav.target, l10n)),
        leading: IconButton(
          icon: Icon(_extended ? Icons.menu_open : Icons.menu),
          tooltip: _extended
              ? l10n.t('Shell.CollapseRail', '收起侧栏')
              : l10n.t('Shell.ExpandRail', '展开侧栏'),
          onPressed: () => setState(() => _extended = !_extended),
        ),
        actions: [
          IconButton(
            icon: Text(l10n.isEnglish ? '中' : 'EN'),
            tooltip: l10n.isEnglish
                ? l10n.t('Shell.ToggleLangZh', '切换到中文')
                : l10n.t('Shell.ToggleLangEn', 'Switch to English'),
            onPressed: () =>
                ref.read(localeControllerProvider.notifier).toggle(),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.palette_outlined),
            tooltip: l10n.t('Shell.Theme', '主题'),
            onSelected: (id) =>
                ref.read(themeControllerProvider.notifier).selectSkin(id),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: SkinIds.light,
                child: Text(l10n.t('Shell.ThemeLight', '白昼')),
              ),
              PopupMenuItem(
                value: SkinIds.dark,
                child: Text(l10n.t('Shell.ThemeDark', '黑夜')),
              ),
              PopupMenuItem(
                value: SkinIds.pink,
                child: Text(l10n.t('Shell.ThemePink', '花漾少女')),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: NavigationRail(
                extended: _extended,
                minExtendedWidth: 200,
                selectedIndex: _railIndex(nav.target),
                onDestinationSelected: (i) => _onRailSelected(context, i),
                leading: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Icon(Icons.auto_stories, color: scheme.primary),
                    if (_extended) ...[
                      const SizedBox(height: 4),
                      const Text('NovelCraft', style: TextStyle(fontSize: 12)),
                    ],
                  ],
                ),
                destinations: [
                  NavigationRailDestination(
                    icon: const Icon(Icons.folder_outlined),
                    selectedIcon: const Icon(Icons.folder),
                    label: Text(l10n.t('Shell.PM.Title', '项目管理')),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.dashboard_outlined),
                    selectedIcon: const Icon(Icons.dashboard),
                    label: Text(l10n.t('Shell.PO.Title', '项目概览')),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.menu_book_outlined),
                    selectedIcon: const Icon(Icons.menu_book),
                    label: Text(l10n.t('Shell.VM.Title', '卷宗章节')),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.people_outline),
                    selectedIcon: const Icon(Icons.people),
                    label: Text(l10n.t('Shell.CM.Title', '人物管理')),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.public_outlined),
                    selectedIcon: const Icon(Icons.public),
                    label: Text(l10n.t('Shell.WS.Title', '世界观')),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.smart_toy_outlined),
                    selectedIcon: const Icon(Icons.smart_toy),
                    label: Text(l10n.t('Shell.AC.Title', 'AI 助手')),
                  ),
                ],
              ),
            ),
            if (worldGroupTargets.contains(nav.target))
              Flexible(
                child: _WorldSubNav(
                  current: nav.target,
                  onSelect: (t) =>
                      ref.read(navigationProvider.notifier).navigateTo(t),
                ),
              ),
            if (aiGroupTargets.contains(nav.target))
              Flexible(
                child: _AiSubNav(
                  current: nav.target,
                  onSelect: (t) =>
                      ref.read(navigationProvider.notifier).navigateTo(t),
                ),
              ),
            const VerticalDivider(width: 1),
            Expanded(
              flex: 6,
              child: Column(
                children: [
                  Expanded(child: _buildPage(nav, ref)),
                  _StatusBar(target: nav.target),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _railIndex(NavigationTarget t) {
    switch (t) {
      case NavigationTarget.projectManagement:
        return 0;
      case NavigationTarget.projectOverview:
        return 1;
      case NavigationTarget.volumeManagement:
        return 2;
      case NavigationTarget.characterManagement:
        return 3;
      case NavigationTarget.worldSettingManagement:
      case NavigationTarget.cultivationSystem:
      case NavigationTarget.politicalSystem:
      case NavigationTarget.secretRealm:
      case NavigationTarget.resource:
      case NavigationTarget.race:
      case NavigationTarget.currencySystem:
        return 4;
      case NavigationTarget.aiCollaboration:
      case NavigationTarget.aiConfiguration:
      case NavigationTarget.dialogGeneration:
        return 5;
      default:
        return 0;
    }
  }

  void _onRailSelected(BuildContext context, int index) {
    final target = switch (index) {
      0 => NavigationTarget.projectManagement,
      1 => NavigationTarget.projectOverview,
      2 => NavigationTarget.volumeManagement,
      3 => NavigationTarget.characterManagement,
      4 => NavigationTarget.worldSettingManagement,
      5 => NavigationTarget.aiCollaboration,
      _ => NavigationTarget.projectManagement,
    };
    ref.read(navigationProvider.notifier).navigateTo(target);
  }

  Widget _buildPage(NavigationHistoryEntry entry, WidgetRef ref) {
    if (entry.target == NavigationTarget.projectManagement) {
      return const ProjectManagementPage();
    }

    // 数据库实体页：人物 / 卷宗 / 剧情 / 势力 / 世界观设定
    final entityCfg = entityConfigByTarget[entry.target];
    if (entityCfg != null) {
      final projectId =
          entry.context.projectId ?? ref.watch(currentProjectIdProvider);
      if (projectId == null) return const _NoProjectHint();
      return EntityPage(
        key: ValueKey(entry.target),
        config: entityCfg,
        projectId: projectId,
      );
    }

    // 聚合 / 工具页
    if (entry.target == NavigationTarget.settings) {
      return const SettingsPage();
    }
    if (entry.target == NavigationTarget.projectOverview ||
        entry.target == NavigationTarget.timeline ||
        entry.target == NavigationTarget.importExport) {
      final projectId =
          entry.context.projectId ?? ref.watch(currentProjectIdProvider);
      if (projectId == null) return const _NoProjectHint();
      if (entry.target == NavigationTarget.projectOverview) {
        return ProjectOverviewPage(projectId: projectId);
      }
      if (entry.target == NavigationTarget.timeline) {
        return TimelinePage(projectId: projectId);
      }
      return ImportExportPage(projectId: projectId);
    }

    // 10 个「JSON 文件存储」的体系页：统一由泛型模板渲染
    final scope = SystemScopes.of(entry.target);
    if (scope != null) {
      // 导航上下文里没带 projectId 时，回退到全局「当前选中项目」
      final projectId =
          entry.context.projectId ?? ref.watch(currentProjectIdProvider);
      if (projectId == null) {
        return const _NoProjectHint();
      }
      final storeAsync = ref.watch(keyValueStoreProvider);
      final l10n = ref.watch(l10nProvider);
      return storeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(l10n.tf('Common.StoreInitFailed', '存储初始化失败：{0}', [e.toString()]))),
        data: (store) {
          final config = wSystemConfigs.firstWhere(
            (c) => c.scope == scope,
            orElse: () => wSystemConfigs.first,
          );
          return WorldSystemPage(
            key: ValueKey(scope),
            config: config,
            projectId: projectId,
            store: store,
          );
        },
      );
    }

    // AI 助手：协作创作 / 配置
    if (entry.target == NavigationTarget.aiCollaboration) {
      return const AICollaborationPage();
    }
    if (entry.target == NavigationTarget.aiConfiguration) {
      return const AIConfigurationPage();
    }
    if (entry.target == NavigationTarget.dialogGeneration) {
      return const DialogGenerationPage();
    }
    if (entry.target == NavigationTarget.projectHealthCheck) {
      return const ProjectHealthCheckPage();
    }

    return PlaceholderPage(target: entry.target);
  }

  String _titleFor(NavigationTarget t, L10n l10n) {
    // 10 个 JSON 体系页的标题直接取自体系配置，避免再写一张重复表
    final scope = SystemScopes.of(t);
    if (scope != null) {
      return wSystemConfigs
          .firstWhere(
            (c) => c.scope == scope,
            orElse: () => wSystemConfigs.first,
          )
          .titleFor(l10n.isEnglish);
    }
    return switch (t) {
      NavigationTarget.projectManagement =>
        l10n.t('Shell.PM.Title', '项目管理'),
      NavigationTarget.projectOverview =>
        l10n.t('Shell.PO.Title', '项目概览'),
      NavigationTarget.volumeManagement => l10n.t('VM.Title', '卷宗章节'),
      NavigationTarget.characterManagement => l10n.t('CM.Title', '人物管理'),
      NavigationTarget.worldSettingManagement =>
        l10n.t('WSSub.WS.Title', '世界观设定'),
      NavigationTarget.aiCollaboration =>
        l10n.t('AISub.AC.Title', 'AI 协作创作'),
      NavigationTarget.aiConfiguration =>
        l10n.t('AISub.AICfg.Title', 'AI 配置'),
      NavigationTarget.timeline =>
        l10n.t('WSSub.TLEM.Title', '时间线'),
      NavigationTarget.relationshipNetwork =>
        l10n.t('WSSub.RELNET.Title', '人物关系网络'),
      NavigationTarget.factionManagement => l10n.t('FM.Title', '势力管理'),
      NavigationTarget.plotManagement =>
        l10n.t('PLM.Title', '剧情管理'),
      NavigationTarget.importExport => l10n.t('IE.Title', '导入导出'),
      NavigationTarget.settings =>
        l10n.t('Dlg.Settings', '设置'),
      NavigationTarget.cultivationSystem => l10n.t('WSSub.CS.Title', '修炼体系'),
      NavigationTarget.politicalSystem => l10n.t('WSSub.PS.Title', '政治体系'),
      NavigationTarget.secretRealm => l10n.t('WSSub.SR.Title', '秘境'),
      NavigationTarget.resource => l10n.t('WSSub.RES.Title', '资源'),
      NavigationTarget.race => l10n.t('WSSub.RACE.Title', '种族'),
      NavigationTarget.currencySystem => l10n.t('WSSub.CUR.Title', '货币体系'),
      NavigationTarget.timelineEventManagement =>
        l10n.t('WSSub.TLEM.Title', '时间线事件管理'),
      NavigationTarget.characterEventManagement =>
        l10n.t('WSSub.CHEV.Title', '人物事件管理'),
      NavigationTarget.characterRelationshipManagement =>
        l10n.t('WSSub.CHREL.Title', '人物关系管理'),
      NavigationTarget.factionRelationshipManagement =>
        l10n.t('WSSub.FACREL.Title', '势力关系管理'),
      NavigationTarget.raceRelationshipManagement =>
        l10n.t('WSSub.RACREL.Title', '种族关系管理'),
      NavigationTarget.cultivationLevelManagement =>
        l10n.t('WSSub.CLLV.Title', '修炼等级管理'),
      NavigationTarget.politicalPositionManagement =>
        l10n.t('WSSub.POLP.Title', '政治职位管理'),
      _ => 'NovelCraft',
    };
  }
}

/// 底部状态栏 —— 对应 C# MainWindow 的 StatusBar（状态/当前项目/版本）
class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.target});

  final NavigationTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final projectId = ref.watch(currentProjectIdProvider);
    final l10n = ref.watch(l10nProvider);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Text(
            l10n.t('Status.Ready', '就绪'),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Text(
            projectId == null
                ? l10n.t('Status.NoProject', '未选择项目')
                : l10n.tf(
                    'Status.CurrentProjectFmt',
                    '当前项目：{0}',
                    [projectId],
                  ),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          Text(
            'v1.0.0',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 世界观二级导航 —— 17 个体系页的入口
///
/// C# 版这些页面分散在 MainWindow 的约 20 个 `xxx_Click` 事件里，
/// 没有统一入口也没有高亮状态。这里统一为一张可滚动列表。
class _WorldSubNav extends ConsumerWidget {
  const _WorldSubNav({required this.current, required this.onSelect});

  final NavigationTarget current;
  final ValueChanged<NavigationTarget> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    final dbBacked = dbEntityTargets;
    final jsonBacked =
        worldGroupTargets.where(SystemScopes.isJsonSystem).toList();

    return SizedBox(
      width: 160,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          children: [
            _groupLabel(context, l10n.t('WSSub.DbEntities', '数据库实体')),
            ...dbBacked.map((t) => _item(context, t, l10n)),
            const SizedBox(height: 12),
            _groupLabel(context, l10n.t('WSSub.JsonSystems', 'JSON 体系')),
            ...jsonBacked.map((t) => _item(context, t, l10n)),
          ],
        ),
      ),
    );
  }

  Widget _groupLabel(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _item(BuildContext context, NavigationTarget t, L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    final selected = t == current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        selected: selected,
        selectedTileColor: scheme.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(
          _label(t, l10n),
          softWrap: true,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: selected ? scheme.onSecondaryContainer : null,
          ),
        ),
        onTap: () => onSelect(t),
      ),
    );
  }

  static String _label(NavigationTarget t, L10n l10n) {
    final scope = SystemScopes.of(t);
    if (scope != null) {
      return wSystemConfigs
          .firstWhere(
            (c) => c.scope == scope,
            orElse: () => wSystemConfigs.first,
          )
          .titleFor(l10n.isEnglish);
    }
    return switch (t) {
      NavigationTarget.worldSettingManagement => l10n.t('WSSub.WS.Title', '世界观设定'),
      NavigationTarget.cultivationSystem => l10n.t('WSSub.CS.Title', '修炼体系'),
      NavigationTarget.politicalSystem => l10n.t('WSSub.PS.Title', '政治体系'),
      NavigationTarget.secretRealm => l10n.t('WSSub.SR.Title', '秘境'),
      NavigationTarget.resource => l10n.t('WSSub.RES.Title', '资源'),
      NavigationTarget.race => l10n.t('WSSub.RACE.Title', '种族'),
      NavigationTarget.currencySystem => l10n.t('WSSub.CUR.Title', '货币体系'),
      NavigationTarget.relationshipNetwork => l10n.t('WSSub.RELNET.Title', '关系网管理'),
      NavigationTarget.timeline => l10n.t('WSSub.TLEM.Title', '时间线'),
      NavigationTarget.timelineEventManagement => l10n.t('WSSub.TLEM.Title', '时间线事件管理'),
      NavigationTarget.characterEventManagement => l10n.t('WSSub.CHEV.Title', '人物事件管理'),
      NavigationTarget.characterRelationshipManagement => l10n.t('WSSub.CHREL.Title', '人物关系管理'),
      NavigationTarget.factionRelationshipManagement => l10n.t('WSSub.FACREL.Title', '势力关系管理'),
      NavigationTarget.raceRelationshipManagement => l10n.t('WSSub.RACREL.Title', '种族关系管理'),
      NavigationTarget.cultivationLevelManagement => l10n.t('WSSub.CLLV.Title', '修炼等级管理'),
      NavigationTarget.politicalPositionManagement => l10n.t('WSSub.POLP.Title', '政治职位管理'),
      _ => t.name,
    };
  }
}

/// 尚未选择项目时的提示
class _NoProjectHint extends ConsumerWidget {
  const _NoProjectHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off_outlined, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(l10n.t('Common.PleaseSelectProjectFirst', '请先在「项目管理」中选择一个项目')),
        ],
      ),
    );
  }
}

/// AI 助手二级导航 —— 协作 / 配置 / 对话生成 / 健康检查
class _AiSubNav extends ConsumerWidget {
  const _AiSubNav({required this.current, required this.onSelect});

  final NavigationTarget current;
  final ValueChanged<NavigationTarget> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    return SizedBox(
      width: 160,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          children: [
            _groupLabel(context, l10n.t('AISub.Group', 'AI 功能')),
            _item(context, NavigationTarget.aiCollaboration, l10n),
            _item(context, NavigationTarget.aiConfiguration, l10n),
            _item(context, NavigationTarget.dialogGeneration, l10n),
            _item(context, NavigationTarget.projectHealthCheck, l10n),
          ],
        ),
      ),
    );
  }

  Widget _groupLabel(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _item(BuildContext context, NavigationTarget t, L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    final selected = t == current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        selected: selected,
        selectedTileColor: scheme.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(
          _labelForAi(t, l10n),
          softWrap: true,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: selected ? scheme.onSecondaryContainer : null,
          ),
        ),
        onTap: () => onSelect(t),
      ),
    );
  }

  static String _labelForAi(NavigationTarget t, L10n l10n) => switch (t) {
        NavigationTarget.aiCollaboration => l10n.t('AISub.AC.Title', 'AI 协作创作'),
        NavigationTarget.aiConfiguration => l10n.t('AISub.AICfg.Title', 'AI 配置'),
        NavigationTarget.dialogGeneration => l10n.t('AISub.DG.Title', '对话生成'),
        NavigationTarget.projectHealthCheck => l10n.t('AISub.HC.Title', '健康检查'),
        _ => t.name,
      };
}
