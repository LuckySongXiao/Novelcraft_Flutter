// 「逐章复读体检」对话框 —— 展示每章复读指标 + 截断预览，**逐章确认**采纳。
//
// 为什么是对话框而不是自动批量：正文是作者的核心资产。截断虽是有据可依的
// 最小改动，但仍是**破坏性**的（丢弃后半章文字），所以：
//   * 每章单独展示「保留多少字 / 丢弃多少字」+ 退化处上下文预览；
//   * 作者点「采纳截断」才写库，且写前二次确认；
//   * 整篇退化的章节不给截断按钮，标「需重写」（走单章重写流程）。
// 规则层见 `lib/ai/utils/repetition_repair_text.dart`（纯 Dart，可离线自检）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/chapter_repetition_repair_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

/// 打开「逐章复读体检」对话框。
Future<void> showChapterRepetitionDialog(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
}) => showDialog<void>(
  context: context,
  builder: (BuildContext ctx) =>
      ChapterRepetitionDialog(projectId: projectId),
);

class ChapterRepetitionDialog extends ConsumerStatefulWidget {
  const ChapterRepetitionDialog({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ChapterRepetitionDialog> createState() =>
      _ChapterRepetitionDialogState();
}

class _ChapterRepetitionDialogState
    extends ConsumerState<ChapterRepetitionDialog> {
  bool _loading = true;
  ChapterRepetitionPlan? _plan;
  final Set<String> _applied = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final plan = await ref
          .read(chapterRepetitionRepairServiceProvider)
          .plan(widget.projectId);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _apply(ChapterRepetitionItem item) async {
    final l10n = ref.read(l10nProvider);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('HC.RepetitionConfirmTitle', '确认截断该章正文')),
        content: Text(
          l10n.tf(
            'HC.RepetitionConfirm',
            '保留前 {keep} 字，丢弃后 {drop} 字（退化复读部分）。此操作会改写正文，'
                '且已同步版本号；如需还原请从备份恢复。',
            <String, Object>{
              'keep': item.report.keepChars,
              'drop': item.report.dropChars,
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.t('Common.Confirm', '确认')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(chapterRepetitionRepairServiceProvider)
          .applyTruncate(item);
      if (!mounted) return;
      setState(() => _applied.add(item.chapterId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.tf('HC.RepetitionApplied', '已修复：{title}', <String, Object>{
              'title': item.title,
            }),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.tf('HC.MetaCleanupFailed', '清洗失败：{error}', <String, Object>{
              'error': '$e',
            }),
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final theme = Theme.of(context);
    final plan = _plan;

    return AlertDialog(
      title: Text(l10n.t('HC.RepetitionCheck', '逐章复读体检')),
      content: SizedBox(
        width: 640,
        height: 520,
        child: _loading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(l10n.t('HC.RepetitionRunning', '正在体检正文…')),
                  ],
                ),
              )
            : _error != null
            ? Center(child: Text('$_error'))
            : plan == null || plan.isEmpty
            ? Center(
                child: Text(
                  l10n.t('HC.RepetitionEmpty', '未发现复读章节，正文健康。'),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.tf(
                      'HC.RepetitionSummary',
                      '共 {total} 章复读：{truncatable} 章可截断修复，{rewrite} 章需重写。',
                      <String, Object>{
                        'total': plan.total,
                        'truncatable': plan.truncatable,
                        'rewrite': plan.needsRewrite,
                      },
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: plan.items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (BuildContext ctx, int i) =>
                          _buildItem(plan.items[i], theme, l10n),
                    ),
                  ),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('Common.Close', '关闭')),
        ),
      ],
    );
  }

  Widget _buildItem(
    ChapterRepetitionItem item,
    ThemeData theme,
    L10n l10n,
  ) {
    final bool done = _applied.contains(item.chapterId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  item.title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (done)
                Chip(
                  label: Text(l10n.t('HC.RepetitionDone', '已修复')),
                  visualDensity: VisualDensity.compact,
                )
              else if (item.truncatable)
                FilledButton.tonal(
                  onPressed: () => _apply(item),
                  child: Text(l10n.t('HC.RepetitionTruncate', '采纳截断')),
                )
              else
                Chip(
                  label: Text(l10n.t('HC.RepetitionNeedsRewrite', '需重写')),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.tf(
              'HC.RepetitionMetrics',
              '复读率 {ngram} · 段落 {para} · 保留 {keep} 字 / 丢弃 {drop} 字',
              <String, Object>{
                'ngram': item.report.ngram.toStringAsFixed(2),
                'para': item.report.paragraph.toStringAsFixed(2),
                'keep': item.report.keepChars,
                'drop': item.report.dropChars,
              },
            ),
            style: theme.textTheme.bodySmall,
          ),
          if (item.report.preview.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                item.report.preview,
                style: theme.textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
