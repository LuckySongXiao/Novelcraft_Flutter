import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_version.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../pages/multi_agent_run_matrix_dialog.dart';
import '../state/multi_agent_run.dart';
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
import '../pages/prerequisite_generation_page.dart';
import '../pages/generation_archive_page.dart';
import '../pages/multi_agent_generation_dialog.dart';

/// 触控平台放宽二级导航列表项密度（安卓操控性：触控目标更大）；桌面保持紧凑。
final VisualDensity kSubNavTileDensity =
    !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)
    ? VisualDensity.standard
    : VisualDensity.compact;

/// 触屏平台判定（安卓/iOS 手机横屏时二级导航收起为图标列）。
/// 仅用于布局收窄，不影响 Web/桌面回归基线。
bool get kSubNavTouchPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

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
  /// null = 跟随屏幕宽度自动决定（<1000 逻辑宽收起为图标栏）；
  /// 用户手动切换后以手动值为准。
  bool? _extendedOverride;

  /// AppBar 右上角的写作长条：
  ///   * 运行中 → 绿色「写作中」动态长条（多智能体写书后台运行时出现，
  ///     点击打开章节矩阵实时进度视图）；
  ///   * 已结束且可回看 → 「写作结果」长条（有 NG 章时用警示色并标出数量）。
  ///
  /// 第二种形态是 2026-10-10 补的：以前运行结束状态被丢弃、窗口自动关闭，
  /// 作者之后再也无法回看「哪几章 NG 了、NG 率多少」—— 实测痛点。
  List<Widget> _buildWritingPill(BuildContext context) {
    final MultiAgentRunState? run = ref.watch(multiAgentRunProvider);
    if (run == null) return const <Widget>[];
    final l10n = ref.watch(l10nProvider);

    if (!run.running && run.hasLastRun) {
      final bool hasNg = run.failedCount > 0;
      final Color tone = hasNg ? Colors.orange : Colors.green;
      return <Widget>[
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Tooltip(
            message: run.step,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showMultiAgentRunMatrixDialog(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.14),
                  border: Border.all(color: tone, width: 1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      hasNg ? Icons.error_outline : Icons.check_circle_outline,
                      size: 12,
                      color: tone,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      hasNg
                          ? l10n.tf('MAG.ResultShortNgFmt', '写作结果 · NG {0} 章',
                              <Object>[run.failedCount])
                          : l10n.t('MAG.ResultShort', '写作结果'),
                      style: TextStyle(
                        fontSize: 12,
                        color: tone,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ];
    }

    if (!run.running) return const <Widget>[];
    final double? p = run.effectiveProgress;
    final String pct = p == null ? '' : ' ${(p * 100).round()}%';
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Tooltip(
          message: run.step,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => showMultiAgentRunMatrixDialog(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.16),
                border: Border.all(color: Colors.green, width: 1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(
                    width: 9,
                    height: 9,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: Colors.green),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    ref.watch(l10nProvider).t('MAG.WritingShort', '写作中') +
                        pct,
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.green,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(navigationProvider);
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;

    // 手机横屏逻辑宽 ~780：主侧栏展开（200px）会把内容区挤到 ~420px，
    // 二级导航再占 160px 后正文仅 ~260px。窄屏默认收起为图标栏（80px）。
    final width = MediaQuery.sizeOf(context).width;
    final phonePortrait = kSubNavTouchPlatform && width < 600;
    final extended = _extendedOverride ?? width >= 1000;
    final writingPill = _buildWritingPill(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleFor(nav.target, l10n)),
        leading: phonePortrait
            ? PopupMenuButton<NavigationTarget>(
                icon: const Icon(Icons.menu),
                tooltip: l10n.t('Shell.MorePages', '更多页面'),
                onSelected: (target) =>
                    ref.read(navigationProvider.notifier).navigateTo(target),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: NavigationTarget.projectOverview,
                    child: Text(l10n.t('Shell.PO.Title', '项目概览')),
                  ),
                  PopupMenuItem(
                    value: NavigationTarget.volumeManagement,
                    child: Text(l10n.t('Shell.VM.Title', '卷宗管理')),
                  ),
                  PopupMenuItem(
                    value: NavigationTarget.characterManagement,
                    child: Text(l10n.t('Shell.CM.Title', '人物管理')),
                  ),
                  PopupMenuItem(
                    value: NavigationTarget.timeline,
                    child: Text(l10n.t('Shell.TL.Title', '时间线')),
                  ),
                  PopupMenuItem(
                    value: NavigationTarget.settings,
                    child: Text(l10n.t('Shell.Settings', '设置')),
                  ),
                ],
              )
            : IconButton(
          icon: Icon(extended ? Icons.menu_open : Icons.menu),
          tooltip: extended
              ? l10n.t('Shell.CollapseRail', '收起侧栏')
              : l10n.t('Shell.ExpandRail', '展开侧栏'),
          onPressed: () => setState(() => _extendedOverride = !extended),
        ),
        actions: [
          // 一键生成书籍（对应 C# MainWindow 左侧栏的「一键生成书籍」按钮）。
          // 手机横屏（<720 逻辑宽）AppBar 拥挤 → 收成纯图标（tooltip 保留语义）。
          if (width < 720)
            IconButton(
              icon: const Icon(Icons.auto_awesome, size: 20),
              tooltip: l10n.t('Side.Btn.OneClick', '一键生成书籍'),
              onPressed: _oneClickGenerate,
            )
          else
            TextButton.icon(
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(l10n.t('Side.Btn.OneClick', '一键生成书籍')),
              onPressed: _oneClickGenerate,
            ),
          const SizedBox(width: 4),
          if (phonePortrait && writingPill.isNotEmpty)
            IconButton(
              tooltip: l10n.t('MAG.Running', '写作中，查看进度'),
              onPressed: () => showMultiAgentRunMatrixDialog(context),
              icon: const Icon(Icons.pending_actions, color: Colors.green),
            )
          else
            ...writingPill,
          IconButton(
            icon: Text(l10n.isEnglish ? '中' : 'EN'),
            tooltip: l10n.isEnglish
                ? l10n.t('Shell.ToggleLangZh', '切换到中文')
                : l10n.t('Shell.ToggleLangEn', 'Switch to English'),
            onPressed: () =>
                ref.read(localeControllerProvider.notifier).toggle(),
          ),
          if (!phonePortrait) PopupMenuButton<String>(
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
          // 设置入口：直达「设置 → 写作工艺 Prompt 模板 / 皮肤 / 语言 / 诊断」。
          // 此前主 GUI 顶部导航条没有设置按键，用户只能靠手机端的「更多页面」
          // 弹出菜单进入，桌面/Web 端无处可点。
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.t('Shell.Settings', '设置'),
            onPressed: () => ref
                .read(navigationProvider.notifier)
                .navigateTo(NavigationTarget.settings),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: phonePortrait
          ? NavigationBar(
              height: 64,
              selectedIndex: switch (_railIndex(nav.target)) {
                3 => 1,
                5 => 2,
                6 => 3,
                _ => 0,
              },
              onDestinationSelected: (index) =>
                  _onRailSelected(context, const [0, 3, 5, 6][index]),
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.folder_outlined),
                  label: l10n.t('Shell.PM.Title', '项目管理'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.article_outlined),
                  label: l10n.t('Shell.ChM.Title', '章节管理'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.public_outlined),
                  label: l10n.t('Shell.WS.Title', '世界观'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.smart_toy_outlined),
                  label: l10n.t('Shell.AC.Title', 'AI 助手'),
                ),
              ],
            )
          : null,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 手机横屏高度装不下 6 个目的地（第 6 个「AI 助手」整块被裁、点不到），
            // 而 NavigationRail 自身不响应滚动手势 → 包一层纵向滚动。
            // ⚠ NavigationRail 外层 Column 是 MainAxisSize.max 且含 Flexible，
            // 直接塞进滚动视图会触发 unbounded 断言，必须套 IntrinsicHeight；
            // ConstrainedBox(minHeight) 让内容不满一屏时仍撑满整列（背景不断层）。
            if (!phonePortrait) Flexible(
              child: LayoutBuilder(
                builder: (context, box) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: box.maxHeight),
                      child: IntrinsicHeight(
                        child: NavigationRail(
                          extended: extended,
                          minExtendedWidth: 200,
                          selectedIndex: _railIndex(nav.target),
                          onDestinationSelected: (i) =>
                              _onRailSelected(context, i),
                          leading: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 8),
                              Icon(Icons.auto_stories, color: scheme.primary),
                              if (extended) ...[
                                const SizedBox(height: 4),
                                const Text(
                                  'NovelCraft',
                                  style: TextStyle(fontSize: 12),
                                ),
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
                              label: Text(l10n.t('Shell.VM.Title', '卷宗管理')),
                            ),
                            NavigationRailDestination(
                              icon: const Icon(Icons.article_outlined),
                              selectedIcon: const Icon(Icons.article),
                              label: Text(l10n.t('Shell.ChM.Title', '章节管理')),
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
                    ),
                  );
                },
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

  /// 多智能体协同写书：弹向导（书名/作者/分卷/每卷章数/子智能体数）→
  /// 三级大纲 + 章节团队协作 → 成功后选中新项目并跳到项目概览。
  ///
  /// 不做「推理服务未注册」的前置拦截：真正需要判断的是"写作模型是否可达"，
  /// 由服务内部 `testConnection` 给出，比在此处猜更准确。
  Future<void> _oneClickGenerate() async {
    final l10n = ref.read(l10nProvider);
    final result = await showMultiAgentGenerationDialog(context);
    if (!mounted || result == null) return;

    if (result.projectId.isNotEmpty) {
      ref.read(currentProjectIdProvider.notifier).select(result.projectId);
      ref
          .read(navigationProvider.notifier)
          .navigateTo(NavigationTarget.projectOverview);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? l10n.t('MW.OneClickDone', '一键生成完成')
              : l10n.tf('MW.OneClickFailed', '一键生成失败：{0}', <Object>[
                  result.message,
                ]),
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
      case NavigationTarget.chapterManagement:
        return 3;
      case NavigationTarget.characterManagement:
        return 4;
      case NavigationTarget.worldSettingManagement:
      case NavigationTarget.cultivationSystem:
      case NavigationTarget.politicalSystem:
      case NavigationTarget.secretRealm:
      case NavigationTarget.resource:
      case NavigationTarget.race:
      case NavigationTarget.currencySystem:
        return 5;
      case NavigationTarget.aiCollaboration:
      case NavigationTarget.aiConfiguration:
      case NavigationTarget.dialogGeneration:
      // 修既有 bug：健康检查页此前落到 default → rail 高亮错位到「项目管理」
      case NavigationTarget.projectHealthCheck:
      case NavigationTarget.prerequisiteGeneration:
      case NavigationTarget.generationArchive:
        return 6;
      default:
        return 0;
    }
  }

  void _onRailSelected(BuildContext context, int index) {
    final target = switch (index) {
      0 => NavigationTarget.projectManagement,
      1 => NavigationTarget.projectOverview,
      2 => NavigationTarget.volumeManagement,
      3 => NavigationTarget.chapterManagement,
      4 => NavigationTarget.characterManagement,
      5 => NavigationTarget.worldSettingManagement,
      6 => NavigationTarget.aiCollaboration,
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
        error: (e, _) => Center(
          child: Text(
            l10n.tf('Common.StoreInitFailed', '存储初始化失败：{0}', [e.toString()]),
          ),
        ),
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
    if (entry.target == NavigationTarget.prerequisiteGeneration) {
      return const PrerequisiteGenerationPage();
    }
    if (entry.target == NavigationTarget.generationArchive) {
      return const GenerationArchivePage();
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
      NavigationTarget.projectManagement => l10n.t('Shell.PM.Title', '项目管理'),
      NavigationTarget.projectOverview => l10n.t('Shell.PO.Title', '项目概览'),
      NavigationTarget.volumeManagement => l10n.t('VM.Title', '卷宗管理'),
      NavigationTarget.chapterManagement =>
        l10n.t('CHM.Title', '章节管理'),
      NavigationTarget.characterManagement => l10n.t('CM.Title', '人物管理'),
      NavigationTarget.worldSettingManagement => l10n.t(
        'WSSub.WS.Title',
        '世界观设定',
      ),
      NavigationTarget.aiCollaboration => l10n.t('AISub.AC.Title', 'AI 协作创作'),
      NavigationTarget.aiConfiguration => l10n.t('AISub.AICfg.Title', 'AI 配置'),
      NavigationTarget.generationArchive => l10n.t('GAP.Title', '写作档案'),
      NavigationTarget.prerequisiteGeneration => l10n.t('PG.Title', '前置条件生成'),
      NavigationTarget.timeline => l10n.t('WSSub.TLEM.Title', '时间线'),
      NavigationTarget.relationshipNetwork => l10n.t(
        'WSSub.RELNET.Title',
        '人物关系网络',
      ),
      NavigationTarget.factionManagement => l10n.t('FM.Title', '势力管理'),
      NavigationTarget.plotManagement => l10n.t('PLM.Title', '剧情管理'),
      NavigationTarget.importExport => l10n.t('IE.Title', '导入导出'),
      NavigationTarget.settings => l10n.t('Dlg.Settings', '设置'),
      NavigationTarget.cultivationSystem => l10n.t('WSSub.CS.Title', '修炼体系'),
      NavigationTarget.politicalSystem => l10n.t('WSSub.PS.Title', '政治体系'),
      NavigationTarget.secretRealm => l10n.t('WSSub.SR.Title', '秘境'),
      NavigationTarget.resource => l10n.t('WSSub.RES.Title', '资源'),
      NavigationTarget.race => l10n.t('WSSub.RACE.Title', '种族'),
      NavigationTarget.currencySystem => l10n.t('WSSub.CUR.Title', '货币体系'),
      NavigationTarget.timelineEventManagement => l10n.t(
        'WSSub.TLEM.Title',
        '时间线事件管理',
      ),
      NavigationTarget.characterEventManagement => l10n.t(
        'WSSub.CHEV.Title',
        '人物事件管理',
      ),
      NavigationTarget.characterRelationshipManagement => l10n.t(
        'WSSub.CHREL.Title',
        '人物关系管理',
      ),
      NavigationTarget.factionRelationshipManagement => l10n.t(
        'WSSub.FACREL.Title',
        '势力关系管理',
      ),
      NavigationTarget.raceRelationshipManagement => l10n.t(
        'WSSub.RACREL.Title',
        '种族关系管理',
      ),
      NavigationTarget.cultivationLevelManagement => l10n.t(
        'WSSub.CLLV.Title',
        '修炼等级管理',
      ),
      NavigationTarget.politicalPositionManagement => l10n.t(
        'WSSub.POLP.Title',
        '政治职位管理',
      ),
      _ => 'NovelCraft',
    };
  }
}

/// 当前选中项目的名称（状态栏显示用）。
///
/// 之前直接显示 projectId（一串 UUID），用户无法确认自己在看哪本书 ——
/// 这里反查项目名；autoDispose 保证切换/改名后重新拉取，取不到时回退 id。
final currentProjectNameProvider = FutureProvider.autoDispose<String?>((
  ref,
) async {
  final String? projectId = ref.watch(currentProjectIdProvider);
  if (projectId == null || projectId.isEmpty) return null;
  try {
    final row = await ref.watch(projectRepositoryProvider).getById(projectId);
    return row?.name;
  } on Object {
    return null;
  }
});

/// 底部状态栏 —— 对应 C# MainWindow 的 StatusBar（状态/当前项目/版本）
class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.target});

  final NavigationTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final projectId = ref.watch(currentProjectIdProvider);
    final projectName = ref.watch(currentProjectNameProvider).value;
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
                    // 显示书名；名称反查失败才退回 id（诚实地至少可辨识）
                    <Object>[projectName ?? projectId],
                  ),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          Text(
            kAppVersionLabel,
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
    final jsonBacked = worldGroupTargets
        .where(SystemScopes.isJsonSystem)
        .toList();

    // 触屏窄屏（手机横屏逻辑宽 ~930 < 1000，与主侧栏收起阈值同源）：
    // 160px 标签列把内容区挤到不足 600，标签两行换行也难读 ——
    // 收起为 64px 图标列（Tooltip 显示全名）。
    final bool iconOnly = kSubNavTouchPlatform &&
        MediaQuery.sizeOf(context).width < 1000;

    return SizedBox(
      width: iconOnly ? 64 : 160,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: ListView(
          padding: EdgeInsets.symmetric(vertical: 8, horizontal: iconOnly ? 6 : 8),
          children: [
            if (!iconOnly) _groupLabel(context, l10n.t('WSSub.DbEntities', '数据库实体')),
            ...dbBacked.map((t) => _item(context, t, l10n, iconOnly: iconOnly)),
            if (!iconOnly) ...[
              const SizedBox(height: 12),
              _groupLabel(context, l10n.t('WSSub.JsonSystems', 'JSON 体系')),
            ] else
              const SizedBox(height: 10),
            ...jsonBacked.map((t) => _item(context, t, l10n, iconOnly: iconOnly)),
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

  Widget _item(
    BuildContext context,
    NavigationTarget t,
    L10n l10n, {
    required bool iconOnly,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final selected = t == current;
    if (iconOnly) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        // ListTile 必须自带 Material：外层 ColoredBox 会遮挡波纹/选中底色
        // （Flutter 3.47 起该场景直接抛断言，全局每页触发）。
        child: Material(
          type: MaterialType.transparency,
          child: Tooltip(
            message: _label(t, l10n),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelect(t),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: selected ? scheme.secondaryContainer : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _iconFor(t),
                  size: 20,
                  color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      // ListTile 必须自带 Material：外层 ColoredBox 会遮挡波纹/选中底色
      // （Flutter 3.47 起该场景直接抛断言，全局每页触发）。
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          dense: true,
          visualDensity: kSubNavTileDensity,
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
      ),
    );
  }

  static IconData _iconFor(NavigationTarget t) => switch (t) {
        NavigationTarget.worldSettingManagement => Icons.public,
        NavigationTarget.cultivationSystem => Icons.self_improvement,
        NavigationTarget.politicalSystem => Icons.account_balance,
        NavigationTarget.secretRealm => Icons.landscape,
        NavigationTarget.resource => Icons.diamond,
        NavigationTarget.race => Icons.groups,
        NavigationTarget.currencySystem => Icons.paid,
        NavigationTarget.relationshipNetwork => Icons.hub,
        NavigationTarget.timeline => Icons.schedule,
        NavigationTarget.timelineEventManagement => Icons.event,
        NavigationTarget.characterEventManagement => Icons.theater_comedy,
        NavigationTarget.characterRelationshipManagement => Icons.diversity_3,
        NavigationTarget.factionRelationshipManagement => Icons.flag,
        NavigationTarget.raceRelationshipManagement => Icons.handshake,
        NavigationTarget.cultivationLevelManagement => Icons.stairs,
        NavigationTarget.politicalPositionManagement => Icons.badge,
        _ => Icons.category,
      };

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
      NavigationTarget.worldSettingManagement => l10n.t(
        'WSSub.WS.Title',
        '世界观设定',
      ),
      NavigationTarget.cultivationSystem => l10n.t('WSSub.CS.Title', '修炼体系'),
      NavigationTarget.politicalSystem => l10n.t('WSSub.PS.Title', '政治体系'),
      NavigationTarget.secretRealm => l10n.t('WSSub.SR.Title', '秘境'),
      NavigationTarget.resource => l10n.t('WSSub.RES.Title', '资源'),
      NavigationTarget.race => l10n.t('WSSub.RACE.Title', '种族'),
      NavigationTarget.currencySystem => l10n.t('WSSub.CUR.Title', '货币体系'),
      NavigationTarget.relationshipNetwork => l10n.t(
        'WSSub.RELNET.Title',
        '关系网管理',
      ),
      NavigationTarget.timeline => l10n.t('WSSub.TLEM.Title', '时间线'),
      NavigationTarget.timelineEventManagement => l10n.t(
        'WSSub.TLEM.Title',
        '时间线事件管理',
      ),
      NavigationTarget.characterEventManagement => l10n.t(
        'WSSub.CHEV.Title',
        '人物事件管理',
      ),
      NavigationTarget.characterRelationshipManagement => l10n.t(
        'WSSub.CHREL.Title',
        '人物关系管理',
      ),
      NavigationTarget.factionRelationshipManagement => l10n.t(
        'WSSub.FACREL.Title',
        '势力关系管理',
      ),
      NavigationTarget.raceRelationshipManagement => l10n.t(
        'WSSub.RACREL.Title',
        '种族关系管理',
      ),
      NavigationTarget.cultivationLevelManagement => l10n.t(
        'WSSub.CLLV.Title',
        '修炼等级管理',
      ),
      NavigationTarget.politicalPositionManagement => l10n.t(
        'WSSub.POLP.Title',
        '政治职位管理',
      ),
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
    // 与世界观二级导航同款触屏收起逻辑（64px 图标列，Tooltip 全名）。
    final bool iconOnly = kSubNavTouchPlatform &&
        MediaQuery.sizeOf(context).width < 1000;
    return SizedBox(
      width: iconOnly ? 64 : 160,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: ListView(
          padding: EdgeInsets.symmetric(vertical: 8, horizontal: iconOnly ? 6 : 8),
          children: [
            if (!iconOnly) _groupLabel(context, l10n.t('AISub.Group', 'AI 功能')),
            _item(context, NavigationTarget.aiCollaboration, l10n, iconOnly: iconOnly),
            _item(context, NavigationTarget.aiConfiguration, l10n, iconOnly: iconOnly),
            _item(context, NavigationTarget.dialogGeneration, l10n, iconOnly: iconOnly),
            _item(context, NavigationTarget.prerequisiteGeneration, l10n, iconOnly: iconOnly),
            _item(context, NavigationTarget.projectHealthCheck, l10n, iconOnly: iconOnly),
            _item(context, NavigationTarget.generationArchive, l10n, iconOnly: iconOnly),
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

  Widget _item(
    BuildContext context,
    NavigationTarget t,
    L10n l10n, {
    required bool iconOnly,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final selected = t == current;
    if (iconOnly) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        // 同世界观二级导航：ListTile 自带 Material，避免 ColoredBox 遮挡
        child: Material(
          type: MaterialType.transparency,
          child: Tooltip(
            message: _labelForAi(t, l10n),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelect(t),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: selected ? scheme.secondaryContainer : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _iconForAi(t),
                  size: 20,
                  color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      // 同世界观二级导航：ListTile 自带 Material，避免 ColoredBox 遮挡
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          dense: true,
          visualDensity: kSubNavTileDensity,
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
      ),
    );
  }

  static IconData _iconForAi(NavigationTarget t) => switch (t) {
    NavigationTarget.aiCollaboration => Icons.forum,
    NavigationTarget.aiConfiguration => Icons.settings,
    NavigationTarget.dialogGeneration => Icons.edit_note,
    NavigationTarget.prerequisiteGeneration => Icons.checklist,
    NavigationTarget.projectHealthCheck => Icons.health_and_safety,
    NavigationTarget.generationArchive => Icons.inventory_2,
    _ => Icons.auto_awesome,
  };

  static String _labelForAi(NavigationTarget t, L10n l10n) => switch (t) {
    NavigationTarget.aiCollaboration => l10n.t('AISub.AC.Title', 'AI 协作创作'),
    NavigationTarget.aiConfiguration => l10n.t('AISub.AICfg.Title', 'AI 配置'),
    NavigationTarget.dialogGeneration => l10n.t('AISub.DG.Title', '对话生成'),
    NavigationTarget.prerequisiteGeneration => l10n.t('PG.Title', '前置条件生成'),
    NavigationTarget.projectHealthCheck => l10n.t('AISub.HC.Title', '健康检查'),
    NavigationTarget.generationArchive => l10n.t('GAP.Title', '写作档案'),
    _ => t.name,
  };
}
