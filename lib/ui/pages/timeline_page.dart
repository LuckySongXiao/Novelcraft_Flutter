import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../data/database.dart';
import '../../l10n/l10n.dart';

/// 时间线页 —— 对应 C# 的「时间线视图」
///
/// 把当前项目下的时间线事件按 [TimelineEventRow.eventDate] 升序排布为竖向时间轴，
/// 直观呈现「事件 → 时间」的叙事脉络。数据来自 [TimelineEventService]。
final timelineEventsProvider = FutureProvider.family<List<TimelineEventRow>, String>(
  (ref, projectId) async {
    final list =
        await ref.watch(timelineEventServiceProvider).getByProjectId(projectId);
    list.sort((a, b) => a.eventDate.compareTo(b.eventDate));
    return list;
  },
);

class TimelinePage extends ConsumerWidget {
  const TimelinePage({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final events = ref.watch(timelineEventsProvider(projectId));

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('TL.Title', '时间线'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: events.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text(l10n.tf('Common.LoadFailed', '加载失败：{0}', [e.toString()]))),
                data: (list) {
                  if (list.isEmpty) {
                    return Center(child: Text(l10n.t('TL.Empty', '暂无时间线事件')));
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) => _TimelineItem(row: list[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineItem extends ConsumerWidget {
  const _TimelineItem({required this.row});

  final TimelineEventRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final date = row.eventDate.toLocal();
    final dateLabel =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 92,
            child: Column(
              children: [
                Text(
                  dateLabel,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: scheme.outlineVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Card(
              margin: const EdgeInsets.only(bottom: 14),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (row.status != null && row.status!.isNotEmpty)
                          Chip(
                            label: Text(row.status!),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                    if (row.category != null && row.category!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        l10n.tf('TL.Category', '分类：{0}', [row.category!]),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    if (row.location != null && row.location!.isNotEmpty) ...[
                      Text(
                        l10n.tf('TL.Location', '地点：{0}', [row.location!]),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    if (row.description != null && row.description!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        row.description!,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
