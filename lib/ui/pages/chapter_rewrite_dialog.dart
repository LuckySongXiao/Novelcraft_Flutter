// 单章重写的 UI 门面 —— 三处入口（章节列表行、章节编辑页、写作动态矩阵）共用。
//
// 为什么做成独立文件：`ChapterRewriteService.rewrite()` 是一次**分钟级**的
// 模型调用，任何入口都必须解决同样的三件事 ——
//   ① 运行中给出不可误解的进度反馈（否则用户会以为点了没反应，反复点击）；
//   ② 结束时如实回报成功 / 质量闸未通过 / 失败（服务层已分好，UI 不许再合并）；
//   ③ 结束后让调用方刷新自己的数据（列表 / 表单 / 矩阵）。
// 三处各写一遍必然漂移，所以收敛到这里。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/chapter_rewrite_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

export '../../application/services/chapter_rewrite_service.dart'
    show ChapterRewriteResult;

/// 发起单章重写并等待结果（含进度弹窗）。返回 null = 章节不存在或窗口被关。
///
/// [repairOutline] = true（缺省）走「先按前后章节调整大纲、再重写」的新链路
/// （[ChapterRewriteService.repairOutlineAndRewrite]）；false 才是旧版「只重写
/// 正文」。缺省改成新链路的原因：实测旧链路把污染的大纲原样喂回模型，
/// **次次重写次次失败**（详见该服务文件头的根因记录）。
///
/// 无论走哪条链，弹窗统一以 [ChapterRewriteResult] 关闭 —— 调用方只关心
/// `applied` / `message`，不需要知道里面多跑了一步大纲修订。
Future<ChapterRewriteResult?> showChapterRewriteDialog(
  BuildContext context, {
  required String chapterId,
  String instruction = '',
  bool repairOutline = true,
}) {
  return showDialog<ChapterRewriteResult>(
    context: context,
    // 任务无法中途取消（模型调用不可中断），允许点掉遮罩只会让人误以为取消了。
    barrierDismissible: false,
    builder: (BuildContext _) => ChapterRewriteDialog(
      chapterId: chapterId,
      instruction: instruction,
      repairOutline: repairOutline,
    ),
  );
}

/// 重写进度弹窗：打开即开始执行，完成后带着结果自行关闭。
class ChapterRewriteDialog extends ConsumerStatefulWidget {
  const ChapterRewriteDialog({
    super.key,
    required this.chapterId,
    this.instruction = '',
    this.repairOutline = true,
  });

  final String chapterId;
  final String instruction;

  /// true = 先调大纲再重写（缺省）；false = 旧版只重写正文。
  final bool repairOutline;

  @override
  ConsumerState<ChapterRewriteDialog> createState() =>
      _ChapterRewriteDialogState();
}

class _ChapterRewriteDialogState extends ConsumerState<ChapterRewriteDialog> {
  String _phase = 'context';

  @override
  void initState() {
    super.initState();
    // 必须放在 build 之后 —— pop 需要 Navigator，initState 里还没有稳定的 context。
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    try {
      final ChapterRewriteResult r;
      if (widget.repairOutline) {
        final ChapterOutlineRepairResult res = await ref
            .read(chapterRewriteServiceProvider)
            .repairOutlineAndRewrite(
              chapterId: widget.chapterId,
              instruction: widget.instruction,
              onProgress: (String phase) {
                if (mounted) setState(() => _phase = phase);
              },
            );
        // 统一关窗形态：正文结果 + 组合后的完整说明（含「已调整大纲」抬头）。
        r = res.rewrite.copyWith(message: res.message);
      } else {
        r = await ref
            .read(chapterRewriteServiceProvider)
            .rewrite(
              chapterId: widget.chapterId,
              instruction: widget.instruction,
              onProgress: (String phase) {
                if (mounted) setState(() => _phase = phase);
              },
            );
      }
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } on Object catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(
        ChapterRewriteResult(
          isSuccess: false,
          content: '',
          message: ref
              .read(l10nProvider)
              .tf('CRW.UnexpectedFmt', '重写过程中出现异常：{0}', <Object>[e]),
        ),
      );
    }
  }

  String _phaseLabel(L10n l10n) => switch (_phase) {
        'outline' => l10n.t('CRW.PhaseOutline', '正在按前后章节调整本章大纲…'),
        'plan' => l10n.t('CRW.PhasePlan', '正在规划续写切片与目标字数…'),
        'write' => l10n.t('CRW.PhaseWrite', '正在按规划逐片续写正文…'),
        'polish' => l10n.t('CRW.PhasePolish', '主模型正在逐段审查润色…'),
        'generate' => l10n.t('CRW.PhaseGenerate', '正在重写正文…'),
        'gate' => l10n.t('CRW.PhaseGate', '正在校验正文质量…'),
        'sync' => l10n.t('CRW.PhaseSync', '正在同步世界观与人物档案…'),
        'progress' => l10n.t('CRW.PhaseProgress', '正在刷新项目进度…'),
        _ => l10n.t('CRW.PhaseContext', '正在装配上下文…'),
      };

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(l10n.t('CRW.Title', '重写本章'),
              style: const TextStyle(fontSize: 16)),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _phaseLabel(l10n),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 重写按钮（列表行 / 表单区共用）。
///
/// [compact] = true 时退化为紧凑图标按钮（列表行尾部用，不撑高行高）。
class ChapterRewriteButton extends ConsumerStatefulWidget {
  const ChapterRewriteButton({
    super.key,
    required this.chapterId,
    this.instruction = '',
    this.labelKey = 'CRW.Button',
    this.labelFallback = '重写本章',
    this.icon = Icons.auto_fix_high,
    this.compact = false,
    this.repairOutline = true,
    this.onDone,
  });

  final String chapterId;
  final String instruction;
  final String labelKey;
  final String labelFallback;
  final IconData icon;
  final bool compact;

  /// true（缺省）= 先按前后章节调整大纲再重写；false = 旧版只重写正文。
  final bool repairOutline;

  /// 重写结束（无论成败）后的回调 —— 调用方据此刷新列表 / 表单。
  final VoidCallback? onDone;

  @override
  ConsumerState<ChapterRewriteButton> createState() =>
      _ChapterRewriteButtonState();
}

class _ChapterRewriteButtonState extends ConsumerState<ChapterRewriteButton> {
  bool _running = false;

  Future<void> _press() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final ChapterRewriteResult? r = await showChapterRewriteDialog(
        context,
        chapterId: widget.chapterId,
        instruction: widget.instruction,
        repairOutline: widget.repairOutline,
      );
      if (!mounted) return;
      if (r != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(r.message)));
      }
      widget.onDone?.call();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final String label = l10n.t(widget.labelKey, widget.labelFallback);
    if (widget.compact) {
      return IconButton(
        tooltip: label,
        visualDensity: VisualDensity.compact,
        onPressed: _running ? null : _press,
        icon: _running
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(widget.icon, size: 18),
      );
    }
    return OutlinedButton.icon(
      onPressed: _running ? null : _press,
      icon: _running
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(widget.icon, size: 18),
      label: Text(label),
    );
  }
}

/// 批量重写一组章节（串行 —— 模型通道是单机瓶颈，并发只会互相拖慢）。
///
/// 返回 `(ok, failed)` 计数。每章都会弹一次进度窗，作者能看清进度。
/// [repairOutline] 语义同 [showChapterRewriteDialog]（缺省 = 先调大纲再重写）。
Future<({int ok, int failed})> rewriteChaptersSequentially(
  BuildContext context, {
  required List<String> chapterIds,
  bool repairOutline = true,
}) async {
  int ok = 0;
  int failed = 0;
  for (final String id in chapterIds) {
    if (!context.mounted) break;
    final ChapterRewriteResult? r = await showChapterRewriteDialog(
      context,
      chapterId: id,
      repairOutline: repairOutline,
    );
    if (r != null && r.applied) {
      ok++;
    } else {
      failed++;
    }
  }
  return (ok: ok, failed: failed);
}
