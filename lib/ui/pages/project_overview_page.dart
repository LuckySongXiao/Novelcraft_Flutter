import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/models/stats.dart';
import '../../application/services/continue_story_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';
import '../state/multi_agent_run.dart';
import 'multi_agent_run_matrix_dialog.dart';

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
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () => _auditArchive(context, ref),
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(
                        l10n.t('PO.AuditArchive', '审查并校准项目档案'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _reviewBook(context, ref),
                      icon: const Icon(Icons.rate_review_outlined),
                      label: Text(l10n.t('PO.ReviewBook', '7B 全书审查并改进')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _showReviewComments(context, ref),
                      icon: const Icon(Icons.forum_outlined),
                      label: Text(
                        l10n.t('PO.ViewReviewComments', '查看审查留言'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 上次写作的回看入口（见 _LastRunBanner 的说明）。
                _LastRunBanner(projectId: projectId),
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

  Future<void> _auditArchive(BuildContext context, WidgetRef ref) async {
    final l10n = ref.read(l10nProvider);
    final service = ref.read(projectArchiveAuditServiceProvider);
    final report = await service.audit(projectId);
    if (report == null || !context.mounted) return;
    final changed = report.isConsistent ? 0 : await service.calibrate(projectId);
    final after = changed == 0 ? report : await service.audit(projectId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(report.isConsistent
          ? l10n.tf(
              'PO.AuditConsistentFmt',
              '项目与写作档案一致：{0} 条',
              <Object>[report.archiveEntries],
            )
          : l10n.tf(
              'PO.AuditCalibratedFmt',
              '档案校准完成：修正/移除 {0} 条，剩余异常 {1} 条',
              <Object>[changed, after?.mismatchCount ?? 0],
            )),
    ));
  }

  Future<void> _reviewBook(BuildContext context, WidgetRef ref) async {
    final l10n = ref.read(l10nProvider);
    final chapters = await ref.read(chapterRepositoryProvider).getByProjectId(projectId);
    if (!context.mounted) return;
    if (chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('PO.NoChapters', '项目暂无章节正文'))),
      );
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('PO.ReviewBook', '7B 全书审查并改进')),
        content: Text(
          l10n.tf(
            'PO.ReviewDialogBodyFmt',
            '将逐章读取 {0} 章正文、大纲和上下文。7B 先写审查留言，发现异常后交给 3B 改写并回写版本。',
            <Object>[chapters.length],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.t('PO.Start', '开始')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // ⚠ 这里必须给进度：一次全书审查是「章数 × (N 位客座读者 + 7B + 13B + 3B)」
    // 串行模型调用，30 章就是上百次往返、几十分钟。旧实现**没有任何反馈**，
    // 点下去界面像死掉，用户自然会认为「审查功能没生效」。
    final ValueNotifier<int> doneCount = ValueNotifier<int>(0);
    final ValueNotifier<String> currentTitle = ValueNotifier<String>('');
    final ValueNotifier<({int reviewed, int applied, int failed})?> finished =
        ValueNotifier<({int reviewed, int applied, int failed})?>(null);
    bool cancelled = false;

    // 后台逐章跑，句柄留着：关窗后要 await 它，否则「取消」那条分支读到的
    // `finished.value` 还是 null（当前那一章尚在飞），取消文案与统计都出不来。
    final Future<void> task = () async {
      int reviewed = 0;
      int applied = 0;
      int failed = 0;
      final service = ref.read(bookContentReviewServiceProvider);
      for (final chapter in chapters) {
        if (cancelled) break;
        currentTitle.value = chapter.title;
        try {
          final report = await service.reviewChapter(
            projectId: projectId,
            chapterId: chapter.id,
            apply: true,
          );
          if (report == null) {
            failed++;
          } else {
            reviewed++;
            if (report.applied) applied++;
          }
        } on Object {
          failed++;
        }
        doneCount.value = doneCount.value + 1;
      }
      finished.value = (reviewed: reviewed, applied: applied, failed: failed);
    }();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('PO.ReviewBook', '7B 全书审查并改进')),
        content: SizedBox(
          width: 440,
          child: ValueListenableBuilder<({int reviewed, int applied, int failed})?>(
            valueListenable: finished,
            builder: (BuildContext ctx2, r, _) {
              if (r != null) {
                // 收工 → 自动关窗（下一帧，避免在 build 里 pop）
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (Navigator.of(ctx2).canPop()) Navigator.of(ctx2).pop();
                });
                return Text(
                  l10n.tf(
                    'PO.ReviewSummaryFmt',
                    '已审查 {0} 章，其中 3B 已改进 {1} 章，{2} 章未产出结果。',
                    <Object>[r.reviewed, r.applied, r.failed],
                  ),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ValueListenableBuilder<int>(
                    valueListenable: doneCount,
                    builder: (_, int d, _) => LinearProgressIndicator(
                      value: chapters.isEmpty ? null : d / chapters.length,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<int>(
                    valueListenable: doneCount,
                    builder: (_, int d, _) => Text(
                      l10n.tf('PO.ReviewProgressFmt', '正在审查第 {0}/{1} 章',
                          <Object>[d + 1 > chapters.length ? chapters.length : d + 1, chapters.length]),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ValueListenableBuilder<String>(
                    valueListenable: currentTitle,
                    builder: (_, String title, _) => Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actions: <Widget>[
          ValueListenableBuilder<({int reviewed, int applied, int failed})?>(
            valueListenable: finished,
            builder: (BuildContext ctx2, r, _) => r != null
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () {
                      cancelled = true;
                      Navigator.of(ctx2).pop();
                    },
                    child: Text(l10n.t('Common.Cancel', '取消')),
                  ),
          ),
        ],
      ),
    );

    // 取消时对话框立刻关闭，但「当前那一章」还在飞 —— 等它落地再读统计。
    await task;

    ref.invalidate(projectStatsProvider(projectId));
    final ({int reviewed, int applied, int failed})? r = finished.value;
    if (!context.mounted || r == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        cancelled
            ? l10n.tf('PO.ReviewCancelledFmt', '已取消：到停止为止审查了 {0} 章。',
                <Object>[r.reviewed])
            : l10n.tf(
                'PO.ReviewDoneFmt',
                '审查完成：已审查 {0} 章，3B 已改进 {1} 章。留言已保存。',
                <Object>[r.reviewed, r.applied],
              ),
      ),
    ));
  }

  Future<void> _showReviewComments(BuildContext context, WidgetRef ref) async {
    final l10n = ref.read(l10nProvider);
    final chapters = await ref.read(chapterRepositoryProvider).getByProjectId(projectId);
    final service = ref.read(bookContentReviewServiceProvider);
    final List<(String, String, String, String)> rows = <(String, String, String, String)>[];
    for (final chapter in chapters) {
      for (final comment in await service.commentsFor(projectId, chapter.id)) {
        rows.add((
          chapter.title,
          comment.author,
          comment.severity,
          l10n.tf(
            'PO.CommentBodyFmt',
            '{0}\n建议：{1}',
            <Object>[comment.problem, comment.suggestion],
          ),
        ));
      }
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('PO.ReviewComments', '7B 审查留言')),
        content: SizedBox(
          width: 560,
          height: 420,
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    l10n.t('PO.NoComments', '暂无留言，请先运行全书审查'),
                  ),
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (BuildContext context, int index) {
                    return const Divider();
                  },
                  itemBuilder: (BuildContext _, int i) {
                    final (String title, String author, String severity, String body) = rows[i];
                    return ListTile(
                      dense: true,
                      title: Text('[$severity] $title · $author'),
                      subtitle: Text(body),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.t('Common.Close', '关闭')),
          ),
        ],
      ),
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

/// 「上次写作详情」入口 —— 运行结束后仍能回看章节矩阵与 NG 统计。
///
/// 以前矩阵悬浮窗写完自动关闭、运行状态被丢弃，作者想再看看「哪几章 NG 了」
/// 就只能重跑一次（实测痛点）。现在运行状态保留在内存里，这里按 [projectId]
/// 匹配 —— 只在本项目的概览页出现，A 项目不会显示 B 项目的结果。
class _LastRunBanner extends ConsumerWidget {
  const _LastRunBanner({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MultiAgentRunState? run = ref.watch(multiAgentRunProvider);
    // 只有「已结束且本项目的运行」才显示；运行中交给 AppBar 的绿色长条。
    if (run == null || !run.hasLastRun) return const SizedBox.shrink();
    if (run.projectId.trim().isEmpty || run.projectId != projectId) {
      return const SizedBox.shrink();
    }
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final bool hasNg = run.failedCount > 0;
    final double? ng = run.ngRate;
    final String pct = ng == null ? '' : '${(ng * 100).round()}%';
    final Color tone = hasNg ? scheme.error : scheme.primary;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            hasNg ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: tone,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasNg
                  ? l10n.tf('PO.LastRunNgFmt',
                      '上次写作：{0} 章里 {1} 章 NG（NG 率 {2}）',
                      <Object>[run.chapters.length, run.failedCount, pct])
                  : l10n.tf('PO.LastRunOkFmt', '上次写作：{0} 章全部定稿',
                      <Object>[run.chapters.length]),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => showMultiAgentRunMatrixDialog(context),
            icon: const Icon(Icons.grid_view_outlined, size: 16),
            label: Text(
              l10n.t('PO.LastRunOpen', '查看本次写作详情'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
