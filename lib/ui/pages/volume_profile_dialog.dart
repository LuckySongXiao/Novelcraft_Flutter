// 分卷档案归纳的 UI 门面。
//
// 与单章重写（`chapter_rewrite_dialog.dart`）同构，因为两者面临同样三个问题：
//   ① 归纳是一次**分钟级**模型调用，必须有不可误解的进度反馈；
//   ② 结束时如实回报（服务层已分好「成功 / 无可归纳 / 失败」，UI 不许再合并）；
//   ③ 结束后让调用方刷新自己的列表。
//
// 入口目前有两处：卷宗管理列表的行按钮（手动触发），以及整书生成流程的
// 卷末自动触发（走服务层，不经过本文件的弹窗）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/entity_profile_synthesizer.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

export '../../application/services/entity_profile_synthesizer.dart'
    show EntityProfileResult;

/// 发起分卷档案归纳并等待结果（含进度弹窗）。返回 null = 窗口被关。
Future<EntityProfileResult?> showVolumeProfileDialog(
  BuildContext context, {
  required String volumeId,
}) {
  return showDialog<EntityProfileResult>(
    context: context,
    // 模型调用不可中断，允许点掉遮罩只会让人误以为取消了。
    barrierDismissible: false,
    builder: (BuildContext _) => VolumeProfileDialog(volumeId: volumeId),
  );
}

/// 归纳进度弹窗：打开即开始执行，完成后带着结果自行关闭。
class VolumeProfileDialog extends ConsumerStatefulWidget {
  const VolumeProfileDialog({super.key, required this.volumeId});

  final String volumeId;

  @override
  ConsumerState<VolumeProfileDialog> createState() =>
      _VolumeProfileDialogState();
}

class _VolumeProfileDialogState extends ConsumerState<VolumeProfileDialog> {
  String _step = '';

  @override
  void initState() {
    super.initState();
    // 必须放在 build 之后 —— pop 需要 Navigator，initState 里 context 尚不稳定。
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    try {
      final EntityProfileResult r = await ref
          .read(entityProfileSynthesizerProvider)
          .synthesizeVolume(
            volumeId: widget.volumeId,
            onProgress: (String step) {
              if (mounted) setState(() => _step = step);
            },
          );
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } on Object catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(
        EntityProfileResult(
          isSuccess: false,
          message: ref
              .read(l10nProvider)
              .tf('PRF.UnexpectedFmt', '档案归纳未完成：{0}', <Object>[e]),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(l10n.t('PRF.Title', '归纳本卷档案'),
              style: const TextStyle(fontSize: 16)),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _step.isEmpty ? l10n.t('PRF.Sub', '正在把本卷的设定流水收敛成档案…') : _step,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 归纳按钮（卷宗列表行尾用）。
///
/// [compact] = true 时退化为紧凑图标按钮，不撑高行高。
class VolumeProfileButton extends ConsumerStatefulWidget {
  const VolumeProfileButton({
    super.key,
    required this.volumeId,
    this.icon = Icons.menu_book_outlined,
    this.compact = true,
    this.onDone,
  });

  final String volumeId;
  final IconData icon;
  final bool compact;

  /// 归纳结束（无论成败）后的回调 —— 调用方据此刷新列表。
  final VoidCallback? onDone;

  @override
  ConsumerState<VolumeProfileButton> createState() =>
      _VolumeProfileButtonState();
}

class _VolumeProfileButtonState extends ConsumerState<VolumeProfileButton> {
  bool _running = false;

  Future<void> _press() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final EntityProfileResult? r = await showVolumeProfileDialog(
        context,
        volumeId: widget.volumeId,
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
    final String label = l10n.t('PRF.Button', '归纳本卷档案');
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
