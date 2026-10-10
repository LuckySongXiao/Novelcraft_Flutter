// 写作动态矩阵 —— 多智能体写书后台运行时的实时进度视图。
//
// 入口：AppBar 右上角绿色「写作中」长条（点击打开）。矩阵化显示每个并行
// 章节团队的阶段（排队/派活/成稿/验收/返工/补写/定稿/失败）与章内进度，
// 状态经 multiAgentRunProvider 实时推送，无需轮询刷新。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/multi_agent_book_generation_service.dart'
    show MultiAgentChapterPhase;
import '../../l10n/l10n.dart';
import '../state/multi_agent_run.dart';
import 'chapter_rewrite_dialog.dart';

/// 打开写作动态矩阵对话框（可随时关闭，后台任务不受影响）。
Future<void> showMultiAgentRunMatrixDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => const _MultiAgentRunMatrixDialog(),
  );
}

class _MultiAgentRunMatrixDialog extends ConsumerStatefulWidget {
  const _MultiAgentRunMatrixDialog();

  @override
  ConsumerState<_MultiAgentRunMatrixDialog> createState() =>
      _MultiAgentRunMatrixDialogState();
}

class _MultiAgentRunMatrixDialogState
    extends ConsumerState<_MultiAgentRunMatrixDialog> {
  // 1s 心跳仅用于刷新「已用时」；章节进度由 provider 推送。
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MultiAgentRunState? run = ref.watch(multiAgentRunProvider);
    final L10n l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    // 运行中用实时差值；结束后冻结在 finishedAt —— 不然关掉重开，
    // 「已用时」还在走，看起来像仍在写作。
    final String elapsed = run?.startedAt == null
        ? ''
        : formatElapsed(
            (run!.finishedAt ?? DateTime.now()).difference(run.startedAt!),
            l10n,
          );

    return AlertDialog(
      title: Row(
        children: <Widget>[
          if (run?.running == true)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              run != null && run.chapters.any((MultiAgentRunChapter c) =>
                      c.phase == MultiAgentChapterPhase.failed)
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              size: 18,
              color: scheme.primary,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              run == null
                  ? l10n.t('MAG.Matrix.Title', '写作动态')
                  : (run.running
                      ? l10n.tf('MAG.Matrix.RunningFmt', '写作中 · {0}',
                          <Object>[run.bookTitle])
                      : l10n.tf('MAG.Matrix.DoneFmt', '写作结束 · {0}',
                          <Object>[run.bookTitle])),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: run == null
            ? Text(l10n.t('MAG.Matrix.None', '当前没有进行中的写书任务。'))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  LinearProgressIndicator(value: run.effectiveProgress),
                  const SizedBox(height: 8),
                  Text(
                    '${run.step}'
                    '${elapsed.isEmpty ? '' : l10n.tf('MAG.Matrix.ElapsedFmt', '　·　已用时 {0}', <Object>[elapsed])}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  // ---- 统计行：作者此前只能自己数红格（实测痛点）----
                  if (run.chapters.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    _RunStatsRow(run: run),
                  ],
                  const SizedBox(height: 12),
                  if (run.chapters.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                            l10n.t('MAG.Matrix.Hint',
                                '章节规划完成后，此处将实时显示各团队的写作进度'),
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant)),
                      ),
                    )
                  else
                    Flexible(
                      child: GridView.builder(
                        shrinkWrap: true,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.55,
                        ),
                        itemCount: run.chapters.length,
                        itemBuilder: (BuildContext ctx, int i) =>
                            _ChapterCell(chapter: run.chapters[i], l10n: l10n),
                      ),
                    ),
                ],
              ),
      ),
      actions: <Widget>[
        // B2 入口①：一键修复本次运行里**所有未落库定稿**的章节。
        // 实测里「30 章有 3 章被质量闸降级成草稿」是常态，逐章点太累。
        // 2026-10-10 起走「先调大纲、再重写」的新链路 —— 只重写正文不动大纲
        // 的旧做法，面对被污染的大纲会次次失败（详见 chapter_rewrite_service.dart）。
        if (run != null && _rewritable(run).isNotEmpty)
          TextButton.icon(
            onPressed: () => _rewriteAll(context, run, l10n),
            icon: const Icon(Icons.auto_fix_high, size: 16),
            label: Text(l10n.t('CRW.RepairAllDrafts', '智能修复全部草稿章')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            run?.running == true
                ? l10n.t('MAG.Matrix.Close', '关闭（后台继续）')
                : l10n.t('MAG.Matrix.CloseDone', '关闭'),
          ),
        ),
      ],
    );
  }

  /// 本次运行里「值得重写」的章节：阶段为「失败（降级草稿）」的那些。
  ///
  /// 只收 `failed` —— `queued` 是「大纲就绪、还没轮到写」，不是失败；
  /// 正在写 / 已定稿的更不能动。
  static List<MultiAgentRunChapter> _rewritable(MultiAgentRunState run) =>
      run.chapters
          .where((MultiAgentRunChapter c) =>
              c.phase == MultiAgentChapterPhase.failed && c.id.isNotEmpty)
          .toList();

  Future<void> _rewriteAll(
    BuildContext context,
    MultiAgentRunState run,
    L10n l10n,
  ) async {
    final List<MultiAgentRunChapter> targets = _rewritable(run);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('CRW.NoneToRewrite', '没有需要重写的章节。'))),
      );
      return;
    }
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(
          l10n.tf('CRW.ConfirmBatchFmt',
              '将先按前后章节调整 {0} 个章节的大纲，再逐章重写（每章一次模型调用，可能要较长时间）。是否继续？',
              <Object>[targets.length]),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.t('CRW.ButtonRowDraft', '重写')),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;

    final ({int ok, int failed}) r = await rewriteChaptersSequentially(
      context,
      chapterIds: <String>[
        for (final MultiAgentRunChapter c in targets) c.id,
      ],
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.tf('CRW.BatchDoneFmt', '批量重写完成：成功 {0} 章，失败 {1} 章。',
            <Object>[r.ok, r.failed])),
      ),
    );
  }
}

/// 统计行：总章数 / 已定稿 / 草稿(NG) / 待写 / NG 率。
///
/// 为什么要有这一行：作者此前只能自己数红格来算「NG 率」（实测反馈），
/// 而这个数是判断「这一轮能不能用、要不要点修复」的第一指标。
/// NG 率的分母是**已出结果**的章 —— 排队中的章不计入，避免开局就显示 0%。
class _RunStatsRow extends ConsumerWidget {
  const _RunStatsRow({required this.run});

  final MultiAgentRunState run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final L10n l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final int total = run.chapters.length;
    final int done = run.completedCount;
    final int failed = run.failedCount;
    final int pending = (total - done - failed).clamp(0, total);
    final double? ng = run.ngRate;

    String pct(double v) => '${(v * 100).round()}%';

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: <Widget>[
        _stat(
          l10n.tf('MAG.Stats.TotalFmt', '共 {0} 章', <Object>[total]),
          scheme.onSurfaceVariant,
          scheme.surfaceContainerHighest,
        ),
        _stat(
          l10n.tf('MAG.Stats.DoneFmt', '已定稿 {0}', <Object>[done]),
          Colors.green,
          Colors.green.withValues(alpha: 0.12),
        ),
        _stat(
          l10n.tf('MAG.Stats.FailedFmt', '草稿/失败 {0}', <Object>[failed]),
          failed > 0 ? scheme.error : scheme.onSurfaceVariant,
          failed > 0
              ? scheme.error.withValues(alpha: 0.12)
              : scheme.surfaceContainerHighest,
        ),
        if (pending > 0)
          _stat(
            l10n.tf('MAG.Stats.PendingFmt', '待写 {0}', <Object>[pending]),
            scheme.onSurfaceVariant,
            scheme.surfaceContainerHighest,
          ),
        if (ng != null)
          _stat(
            l10n.tf('MAG.Stats.NgRateFmt', 'NG 率 {0}', <Object>[pct(ng)]),
            ng > 0 ? scheme.error : Colors.green,
            ng > 0
                ? scheme.error.withValues(alpha: 0.12)
                : Colors.green.withValues(alpha: 0.12),
          ),
      ],
    );
  }

  Widget _stat(String label, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

/// 单章矩阵单元：标题 + 阶段徽章 + 进度条 + 明细。
///
/// 失败（质量闸降级为草稿）的格子额外给一个「重写」小徽章 —— B2 入口①的单章版。
class _ChapterCell extends ConsumerWidget {
  const _ChapterCell({required this.chapter, required this.l10n});

  final MultiAgentRunChapter chapter;
  final L10n l10n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = _phaseColors(chapter.phase, scheme);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: chapter.phase == MultiAgentChapterPhase.done
              ? Colors.green.withValues(alpha: 0.5)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 章节号 = 卷号前缀 + 章名 + 状态后缀（多卷多章重名时一眼可辨）
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  chapter.volumeTitle.trim().isEmpty
                      ? chapter.title
                      : '${chapter.volumeTitle} · ${chapter.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              _statusSuffix(chapter),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  multiAgentPhaseLabel(chapter.phase, l10n),
                  style: TextStyle(fontSize: 10, color: fg),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${(chapter.progress * 100).round()}%',
                  style: TextStyle(
                      fontSize: 10, color: scheme.onSurfaceVariant),
                ),
              ),
              if (chapter.phase == MultiAgentChapterPhase.failed &&
                  chapter.id.isNotEmpty)
                _RewriteCellBadge(chapterId: chapter.id),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: chapter.progress,
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Text(
              chapter.detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 状态后缀徽章：落库定稿 / 草稿 / 大纲就绪（进行中阶段由阶段徽章表达）。
  Widget _statusSuffix(MultiAgentRunChapter chapter) {
    final (String label, Color color) = switch (chapter.phase) {
      MultiAgentChapterPhase.done => (
          l10n.t('MAG.Suffix.Done', '落库定稿'),
          Colors.green
        ),
      MultiAgentChapterPhase.failed => (
          l10n.t('MAG.Suffix.Draft', '草稿'),
          Colors.orange
        ),
      MultiAgentChapterPhase.queued => (
          l10n.t('MAG.Suffix.OutlineReady', '大纲就绪'),
          Colors.blueGrey
        ),
      _ => ('', Colors.transparent),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(label, style: TextStyle(fontSize: 9, color: color)),
    );
  }

  static (Color, Color) _phaseColors(MultiAgentChapterPhase phase, ColorScheme scheme) =>
      switch (phase) {
        MultiAgentChapterPhase.done => (
            Colors.green.withValues(alpha: 0.2),
            Colors.green
          ),
        MultiAgentChapterPhase.failed => (
            scheme.errorContainer,
            scheme.error
          ),
        MultiAgentChapterPhase.writing => (
            scheme.primaryContainer,
            scheme.onPrimaryContainer
          ),
        MultiAgentChapterPhase.queued => (
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant
          ),
        // 收尾自动修复阶段（调大纲 + 重写）用紫色，与「拼接定稿」区分开 ——
        // 作者要能一眼看出「这是系统在补，不是正常写作流程」。
        MultiAgentChapterPhase.outlineRepair => (
            Colors.deepPurple.withValues(alpha: 0.2),
            Colors.deepPurple,
          ),
        _ => (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer
          ),
      };
}

/// 矩阵格子里的「重写」小徽章（形态与状态徽章一致，不撑高行）。
///
/// 点它 -> 走 `ChapterRewriteService` 按上下文重写这一章；成功后把本格改标为
/// 已定稿（`MultiAgentRunController.markChapterDone`），免得红标看起来像没生效。
class _RewriteCellBadge extends ConsumerStatefulWidget {
  const _RewriteCellBadge({required this.chapterId});

  final String chapterId;

  @override
  ConsumerState<_RewriteCellBadge> createState() => _RewriteCellBadgeState();
}

class _RewriteCellBadgeState extends ConsumerState<_RewriteCellBadge> {
  bool _running = false;

  Future<void> _press() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final ChapterRewriteResult? r = await showChapterRewriteDialog(
        context,
        chapterId: widget.chapterId,
      );
      if (!mounted) return;
      if (r != null) {
        if (r.applied) {
          ref
              .read(multiAgentRunProvider.notifier)
              .markChapterDone(widget.chapterId, detail: r.message);
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(r.message)));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _running ? null : _press,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_running)
              SizedBox(
                width: 9,
                height: 9,
                child: CircularProgressIndicator(
                    strokeWidth: 1.4, color: scheme.primary),
              )
            else
              Icon(Icons.auto_fix_high, size: 10, color: scheme.primary),
            const SizedBox(width: 2),
            Text(
              l10n.t('CRW.ButtonRowDraft', '重写'),
              style: TextStyle(
                  fontSize: 9,
                  color: scheme.primary,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}
