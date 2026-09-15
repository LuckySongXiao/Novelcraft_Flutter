import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/models/stats.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

/// 项目概览页 —— 对应 C# 的「项目仪表盘 / 首页」
///
/// 聚合展示当前项目的卷宗 / 章节 / 角色 / 势力 / 剧情数量与总字数、完成进度。
/// 数据来自 [ProjectStatisticsService]（强类型 [ProjectStats]），不走弱类型字典。
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
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatCard(label: l10n.t('PO.Volumes', '卷宗'), value: s.volumeCount, icon: Icons.menu_book, isEnglish: l10n.isEnglish),
            _StatCard(label: l10n.t('PO.Chapters', '章节'), value: s.chapterCount, icon: Icons.article_outlined, isEnglish: l10n.isEnglish),
            _StatCard(label: l10n.t('PO.Characters', '角色'), value: s.characterCount, icon: Icons.person_outline, isEnglish: l10n.isEnglish),
            _StatCard(label: l10n.t('PO.Factions', '势力'), value: s.factionCount, icon: Icons.flag_outlined, isEnglish: l10n.isEnglish),
            _StatCard(label: l10n.t('PO.Plots', '剧情'), value: s.plotCount, icon: Icons.auto_stories_outlined, isEnglish: l10n.isEnglish),
            _StatCard(
              label: l10n.t('PO.TotalWords', '总字数'),
              value: s.wordCount,
              icon: Icons.text_fields,
              compact: true,
              isEnglish: l10n.isEnglish,
            ),
          ],
        ),
      ],
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
