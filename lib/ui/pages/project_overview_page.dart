import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/models/stats.dart';
import '../../application/services/continue_story_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';
import '../state/multi_agent_run.dart';

/// 项目概览页 —— 对应 C# 的「项目仪表盘 / 首页」
///
/// 聚合展示当前项目全部实体类目的数量与总字数、完成进度。
/// 数据来自 [ProjectStatisticsService]（强类型 [ProjectStats]），不走弱类型字典。
///
/// 交互：
/// * 双击分类卡片 → 直接进入对应实体管理页；
/// * 「继续规划剧情并续写」→ 基于最新 state 自主规划下一章（必要时自主
///   追加新分卷，卷名/章名自主命名）并完成本章正文。
final projectStatsProvider = FutureProvider.family<ProjectStats, String>(
  (ref, projectId) =>
      ref.watch(projectStatisticsServiceProvider).getStats(projectId),
);

class ProjectOverviewPage extends ConsumerWidget {
  const ProjectOverviewPage({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final stats = ref.watch(projectStatsProvider(projectId));

    // 自动刷新：后台写书任务（多智能体 / 续写）结束的瞬间失效统计缓存，
    // 概览数字（章节数/总字数/最近编辑）即刻反映最新状态，无需手动刷新。
    ref.listen<MultiAgentRunState?>(multiAgentRunProvider, (prev, next) {
      final bool wasRunning = prev?.running ?? false;
      final bool nowRunning = next?.running ?? false;
      if (wasRunning && !nowRunning) {
        ref.invalidate(projectStatsProvider(projectId));
      }
    });

    return Scaffold(
      body:Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('PO.Title', '项目概览'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            Expanded(
              child: stats.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) =>
                    Center(child: Text(l10n.tf('Common.LoadFailed', '加载失败：{0}', [e.toString()]))),
                data: (s) => _buildBody(context, ref, s),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, ProjectStats s) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final List<(_StatCard, NavigationTarget?)> cards = <(_StatCard, NavigationTarget?)>[
      (
        _StatCard(label: l10n.t('PO.Volumes', '卷宗'), value: s.volumeCount, icon: Icons.menu_book, isEnglish: l10n.isEnglish),
        NavigationTarget.volumeManagement,
      ),
      (
        _StatCard(label: l10n.t('PO.Chapters', '章节'), value: s.chapterCount, icon: Icons.article_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.chapterManagement,
      ),
      (
        _StatCard(label: l10n.t('PO.Characters', '角色'), value: s.characterCount, icon: Icons.person_outline, isEnglish: l10n.isEnglish),
        NavigationTarget.characterManagement,
      ),
      (
        _StatCard(label: l10n.t('PO.Factions', '势力'), value: s.factionCount, icon: Icons.flag_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.factionManagement,
      ),
      (
        _StatCard(label: l10n.t('PO.Plots', '剧情'), value: s.plotCount, icon: Icons.auto_stories_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.plotManagement,
      ),
      (
        _StatCard(label: l10n.t('PO.WorldSettings', '世界观设定'), value: s.worldSettingCount, icon: Icons.public_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.worldSettingManagement,
      ),
      (
        _StatCard(label: l10n.t('PO.Races', '种族'), value: s.raceCount, icon: Icons.pets_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.race,
      ),
      (
        _StatCard(label: l10n.t('PO.Resources', '资源'), value: s.resourceCount, icon: Icons.diamond_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.resource,
      ),
      (
        _StatCard(label: l10n.t('PO.SecretRealms', '秘境'), value: s.secretRealmCount, icon: Icons.landscape_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.secretRealm,
      ),
      (
        _StatCard(label: l10n.t('PO.CultivationSystems', '修炼体系'), value: s.cultivationSystemCount, icon: Icons.self_improvement_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.cultivationSystem,
      ),
      (
        _StatCard(label: l10n.t('PO.PoliticalSystems', '政治体系'), value: s.politicalSystemCount, icon: Icons.account_balance_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.politicalSystem,
      ),
      (
        _StatCard(label: l10n.t('PO.CurrencySystems', '货币体系'), value: s.currencySystemCount, icon: Icons.currency_exchange_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.currencySystem,
      ),
      (
        _StatCard(label: l10n.t('PO.RelationshipNetworks', '关系网'), value: s.relationshipNetworkCount, icon: Icons.hub_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.relationshipNetwork,
      ),
      (
        _StatCard(label: l10n.t('PO.TimelineEvents', '时间线事件'), value: s.timelineEventCount, icon: Icons.timeline_outlined, isEnglish: l10n.isEnglish),
        NavigationTarget.timelineEventManagement,
      ),
      (
        _StatCard(
          label: l10n.t('PO.TotalWords', '总字数'),
          value: s.wordCount,
          icon: Icons.text_fields,
          compact: true,
          isEnglish: l10n.isEnglish,
        ),
        null,
      ),
    ];

    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l10n.t('PO.CompletionProgress', '完成进度'), style: const TextStyle(fontSize: 14)),
                    Text(
                      '${s.progress.toStringAsFixed(0)}%',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: (s.progress.clamp(0, 100)) / 100),
                const SizedBox(height: 8),
                if (s.lastEditedAt != null)
                  Text(
                    l10n.tf('PO.LastEdited', '最近编辑：{0}', [s.lastEditedAt!.toLocal().toString().split('.')[0]]),
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _continueStory(context, ref),
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(l10n.t('PO.ContinueBtn', '继续规划剧情并续写')),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.t('PO.ContinueHint',
                      '基于主线大纲、各卷状态与最近章节的最新 state，自主规划下一章'
                      '（必要时自主追加新分卷，卷名 / 章名均自主命名）并完成本章正文。'),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (_StatCard card, NavigationTarget? target) in cards)
              target == null
                  ? card
                  : _DoubleClickCard(
                      target: target,
                      projectId: projectId,
                      child: card,
                    ),
          ],
        ),
      ],
    );
  }

  /// 继续规划剧情并续写：进度对话框 → 结果展示 → 刷新统计。
  Future<void> _continueStory(BuildContext context, WidgetRef ref) async {
    final l10n = ref.read(l10nProvider);
    final ValueNotifier<String> step = ValueNotifier<String>(
        l10n.t('PO.ContinueRunning', '正在自主规划与续写…'));
    final ValueNotifier<ContinueStoryResult?> result =
        ValueNotifier<ContinueStoryResult?>(null);

    unawaited(ref
        .read(continueStoryServiceProvider)
        .continueStory(projectId, onProgress: (String s) {
      step.value = s;
    }).then((ContinueStoryResult r) => result.value = r));

    final bool confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('PO.ContinueTitle', '继续规划剧情并续写')),
        content: SizedBox(
          width: 420,
          child: ValueListenableBuilder<ContinueStoryResult?>(
            valueListenable: result,
            builder: (BuildContext ctx, ContinueStoryResult? r, _) {
              final ColorScheme scheme = Theme.of(ctx).colorScheme;
              if (r == null) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<String>(
                      valueListenable: step,
                      builder: (_, String s, _) => Text(s),
                    ),
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        r.isSuccess
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 18,
                        color: r.isSuccess ? Colors.green : scheme.error,
                      ),
                      const SizedBox(width: 6),
                      Expanded(child: Text(r.message)),
                    ],
                  ),
                  if (r.contentPreview.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(l10n.t('PO.ContinuePreview', '正文预览'),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(r.contentPreview,
                        maxLines: 8,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, height: 1.6)),
                  ],
                ],
              );
            },
          ),
        ),
        actions: <Widget>[
          ValueListenableBuilder<ContinueStoryResult?>(
            valueListenable: result,
            builder: (BuildContext ctx, ContinueStoryResult? r, _) => r == null
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(l10n.t('Common.Confirm', '确定')),
                  ),
          ),
        ],
      ),
    ) ??
    false;
    if (!confirmed) return;

    final ContinueStoryResult? r = result.value;
    // 刷新统计（invalidate 后 FutureProvider 重新取数）
    ref.invalidate(projectStatsProvider(projectId));
    if (context.mounted && r != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.tf('PO.ContinueDoneFmt',
            '续写完成：《{0}》·《{1}》（{2} 字）',
            <Object>[r.volumeName, r.chapterTitle, r.wordCount])),
      ));
    }
  }
}

/// 双击分类卡片 → 进入对应实体管理页。
class _DoubleClickCard extends ConsumerWidget {
  const _DoubleClickCard({
    required this.target,
    required this.projectId,
    required this.child,
  });

  final NavigationTarget target;
  final String projectId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onDoubleTap: () {
        ref.read(navigationProvider.notifier).navigateTo(
              target,
              context: NavigationContext(projectId: projectId),
            );
      },
      borderRadius: BorderRadius.circular(12),
      child: child,
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    this.compact = false,
    this.isEnglish = false,
  });

  final String label;
  final int value;
  final IconData icon;
  final bool compact;
  final bool isEnglish;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = compact ? _formatCount(value, isEnglish) : '$value';
    return SizedBox(
      width: 150,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(height: 10),
              Text(
                display,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCount(int n, bool isEnglish) {
    if (isEnglish) {
      if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
      if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    } else {
      if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
      if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    }
    return '$n';
  }
}
