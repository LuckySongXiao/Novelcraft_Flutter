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
import '../state/multi_agent_run.dart';

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
    final scheme = Theme.of(context).colorScheme;
    final String elapsed = run?.startedAt == null
        ? ''
        : _fmtElapsed(DateTime.now().difference(run!.startedAt!));

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
                  ? '写作动态'
                  : (run.running ? '写作中 · ${run.bookTitle}' : '写作结束 · ${run.bookTitle}'),
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
            ? const Text('当前没有进行中的写书任务。')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  LinearProgressIndicator(value: run.effectiveProgress),
                  const SizedBox(height: 8),
                  Text(
                    '${run.step}'
                    '${elapsed.isEmpty ? '' : '　·　已用时 $elapsed'}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  if (run.chapters.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text('章节规划完成后，此处将实时显示各团队的写作进度',
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
                            _ChapterCell(chapter: run.chapters[i]),
                      ),
                    ),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭（后台继续）'),
        ),
      ],
    );
  }

  static String _fmtElapsed(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return m > 0 ? '$m分${s.toString().padLeft(2, '0')}秒' : '$s秒';
  }
}

/// 单章矩阵单元：标题 + 阶段徽章 + 进度条 + 明细。
class _ChapterCell extends StatelessWidget {
  const _ChapterCell({required this.chapter});

  final MultiAgentRunChapter chapter;

  @override
  Widget build(BuildContext context) {
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
                  multiAgentPhaseLabel(chapter.phase),
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
      MultiAgentChapterPhase.done => ('落库定稿', Colors.green),
      MultiAgentChapterPhase.failed => ('草稿', Colors.orange),
      MultiAgentChapterPhase.queued => ('大纲就绪', Colors.blueGrey),
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

  static (Color, Color) _phaseColors(MultiAgentChapterPhase phase, ColorScheme scheme) =>      switch (phase) {
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
        _ => (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer
          ),
      };
}
