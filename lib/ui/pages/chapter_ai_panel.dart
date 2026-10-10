// 章节阅读 · 选节 AI 助手 —— 选中正文片段后按要求润色 / 扩写 / 续写。
//
// 设计：
//   * 选区来源：阅读页用 SelectionArea 包正文，经 onSelectionChanged
//     回调拿到纯文本选区（SelectedContent.plainText），以参数传入本面板。
//   * 调用链：走 modelManager 默认 provider（与 AI 协作页同源），
//     非流式单次请求（长选段 + 指令一次出结果，阅读页不需要打字机）。
//   * 三种操作各有独立提示词；附加要求来自输入框（可空）。
//   * 结果以对照卡呈现（原文 / 结果）。
//   * **采纳应用**（2026-10-10 用户实测补充）：结果先经用户确认，再由阅读页
//     写回章节正文 —— 续写插到所选段落的下一段，润色 / 扩写 / 重写替换选中文本
//     （纯文本规则见 `selection_apply_text.dart`）。本面板只负责「确认 + 上报」，
//     不直接碰数据库；[onApply] 为 null 时不显示采纳按钮（旧行为：仅复制）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/selection_edit_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

export '../../application/services/selection_edit_service.dart' show ChapterAiAction;

/// 选节 AI 助手面板：由阅读页传入当前选中文本（SelectionArea.onSelectionChanged）。
class ChapterAiPanel extends ConsumerStatefulWidget {
  const ChapterAiPanel({
    super.key,
    required this.selectedText,
    required this.fullContent,
    this.chapterOutline = '',
    this.volumeOutline = '',
    this.prevChapterTail = '',
    this.onClearSelection,
    this.onApply,
  });

  /// 当前选中的正文片段（空 = 未选节，按钮将提示）。
  final String selectedText;

  /// 整章正文（续写场景需要上文语境）。
  final String fullContent;

  /// 本章梗概（写作大纲的一部分，扩写时贴合）。
  final String chapterOutline;

  /// 所属卷宗的大纲/简介（扩写时贴合）。
  final String volumeOutline;

  /// 前一章结尾片段（跨章上下文，扩写/续写时保持衔接）。
  final String prevChapterTail;

  /// 显式清除粘性选区（面板「重新选择」按钮；null = 不显示清除入口）。
  ///
  /// 粘性选区下点击面板按钮不会丢选区，因此提供手动清除让用户重新框选。
  final VoidCallback? onClearSelection;

  /// **采纳应用回调**（null = 不显示采纳按钮，退回「仅复制」旧行为）。
  ///
  /// 用户在确认对话框里点了「应用」后触发；写库 / 刷新由宿主页完成。
  /// 语义：`continueWrite` → 结果插到所选文本的下一段；其余动作 → 结果替换
  /// 所选文本。
  final void Function(String result, ChapterAiAction action)? onApply;

  @override
  ConsumerState<ChapterAiPanel> createState() => _ChapterAiPanelState();
}

class _ChapterAiPanelState extends ConsumerState<ChapterAiPanel> {
  final TextEditingController _requireCtrl = TextEditingController();
  final TextEditingController _resultCtrl = TextEditingController();
  ChapterAiAction? _runningAction;

  /// 当前结果由哪个动作产出（采纳应用时要区分「续写插入」与「替换」）。
  ChapterAiAction? _resultAction;
  String? _error;
  String? _sourceText;

  @override
  void dispose() {
    _requireCtrl.dispose();
    _resultCtrl.dispose();
    super.dispose();
  }

  String _selectedText() => widget.selectedText.trim();

  String _actionLabel(ChapterAiAction a, L10n l10n) => switch (a) {
        ChapterAiAction.rewrite => l10n.t('RAI.Rewrite', '重写'),
        ChapterAiAction.polish => l10n.t('RAI.Polish', '润色'),
        ChapterAiAction.dedupePolish =>
          l10n.t('RAI.Dedupe', '去重润色'),
        ChapterAiAction.expand => l10n.t('RAI.Expand', '扩写'),
        ChapterAiAction.continueWrite => l10n.t('RAI.Continue', '续写'),
      };

  /// 已捕获选区预览卡：选中文本快照 + 字数 + 「重新选择」清除按钮。
  /// 未捕获时展示引导文案（选区为空时按钮仍会提示，这里是前置引导）。
  Widget _buildSelectionPreview(L10n l10n, ColorScheme scheme) {
    final String selected = _selectedText();
    final bool has = selected.isNotEmpty;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: has
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: has ? scheme.primary.withValues(alpha: 0.4) : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                has ? Icons.select_all_outlined : Icons.pan_tool_outlined,
                size: 14,
                color: has ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  has
                      ? l10n.tf('RAI.SelectionCapturedFmt', '已捕获选区 · {0} 字',
                          <Object>[selected.trim().length])
                      : l10n.t('RAI.SelectionNone', '尚未捕获选区'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: has ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (has && widget.onClearSelection != null)
                _ReselectButton(
                  tooltip: l10n.t('RAI.ReselectTooltip', '清除当前选区，重新框选'),
                  label: l10n.t('RAI.Reselect', '重新选择'),
                  onPressed: widget.onClearSelection!,
                ),
            ],
          ),
          if (has) ...[
            const SizedBox(height: 4),
            SelectableText(
              selected,
              maxLines: 3,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ] else ...[
            const SizedBox(height: 2),
            Text(
              l10n.t('RAI.SelectionGuide',
                  '回到正文拖动鼠标选中一段文字，选区会自动捕获到这里（点击面板不会丢失）'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _run(ChapterAiAction action) async {
    if (_runningAction != null) return;
    final l10n = ref.read(l10nProvider);
    final selected = _selectedText();
    if (selected.isEmpty) {
      setState(() => _error = l10n.t('RAI.NeedSelection',
          '请先在正文中选中一段文字，再使用 AI 操作'));
      return;
    }

    final settings = ref.read(dualAgentSettingsProvider);
    final provider = settings.enableDualAgentWorkflow
        ? ref.read(agentProviderResolverProvider)(settings.mainAgentProvider)
        : ref.read(modelManagerProvider).getDefaultProvider();
    if (provider == null || !provider.isAvailable) {
      setState(() => _error = l10n
          .t('RAI.NoProvider', '没有可用的 AI 服务，请先到「AI 配置」注册并设置默认模型'));
      return;
    }

    setState(() {
      _runningAction = action;
      _error = null;
      _resultCtrl.clear();
      _sourceText = selected;
    });

    try {
      final text = await SelectionEditService.edit(
        provider: provider,
        model: settings.enableDualAgentWorkflow ? settings.mainAgentModel : '',
        action: action,
        selected: selected,
        fullContent: widget.fullContent,
        instruction: _requireCtrl.text.trim(),
        chapterOutline: widget.chapterOutline,
        volumeOutline: widget.volumeOutline,
        prevChapterTail: widget.prevChapterTail,
      );
      if (!mounted) return;
      if (_selectedText() != selected) {
        setState(() {
          _error = l10n.t('RAI.StaleSelection', '选区已改变，已丢弃过期结果，请重新处理。');
          _runningAction = null;
        });
        return;
      }
      setState(() {
        _resultCtrl.text = text;
        _resultAction = action;
        _runningAction = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = l10n.tf(
          'RAI.ValidationFailedFmt',
          '处理未通过校验，原文未修改：{0}',
          <Object>[e],
        );
        _runningAction = null;
      });
    }
  }

  /// 采纳应用前的**确认对话框** —— 用户实测要求「让用户确认是否应用」。
  ///
  /// 语义说明因动作而异：续写 = 插到所选文本的下一段（原文保留）；
  /// 润色 / 去重润色 / 扩写 / 重写 = 替换所选文本（原文被覆盖）。
  Future<void> _confirmApply() async {
    final l10n = ref.read(l10nProvider);
    final ChapterAiAction? action = _resultAction;
    if (action == null || widget.onApply == null) return;
    final bool insertAfter = action == ChapterAiAction.continueWrite;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogCtx) => AlertDialog(
        title: Text(l10n.t('RAI.ApplyTitle', '应用 AI 结果')),
        content: Text(
          insertAfter
              ? l10n.tf('RAI.ApplyInsertFmt',
                  '将把 AI 结果作为「下一段」插入到所选文本之后（原选中文本保留）。\n\n'
                  '选中文本：{0} 字\nAI 结果：{1} 字',
                  <Object>[_sourceText?.length ?? 0, _resultCtrl.text.length])
              : l10n.tf('RAI.ApplyReplaceFmt',
                  '将用 AI 结果替换当前选中的文本段（原选中文本被覆盖，'
                  '章节版本号 +1，可在版本历史中追溯）。\n\n'
                  '选中文本：{0} 字\nAI 结果：{1} 字',
                  <Object>[_sourceText?.length ?? 0, _resultCtrl.text.length]),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(l10n.t('RAI.Apply', '采纳应用')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.onApply!.call(_resultCtrl.text, action);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final hasResult = _resultCtrl.text.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 已捕获选区预览（粘性选区的可见性保障：用户能确认选中文本被识别）----
        _buildSelectionPreview(l10n, scheme),
        // ---- 要求输入 + 操作按钮 ----
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _requireCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.t('RAI.RequireHint',
                      '附加要求（可空），如：更凝练 / 加入雨景 / 对话多一点'),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _run(ChapterAiAction.polish),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final action in ChapterAiAction.values)
              FilledButton.tonalIcon(
                onPressed:
                    _runningAction != null ? null : () => _run(action),
                icon: _runningAction == action
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : switch (action) {
                        ChapterAiAction.rewrite =>
                          const Icon(Icons.edit_note, size: 16),
                        ChapterAiAction.polish =>
                          const Icon(Icons.auto_fix_high, size: 16),
                        ChapterAiAction.dedupePolish =>
                          const Icon(Icons.cleaning_services_outlined, size: 16),
                        ChapterAiAction.expand =>
                          const Icon(Icons.unfold_more, size: 16),
                        ChapterAiAction.continueWrite =>
                          const Icon(Icons.arrow_forward_outlined, size: 16),
                      },
                label: Text(_actionLabel(action, l10n)),
              ),
            if (hasResult) ...[
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: _resultCtrl.text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(l10n.t('RAI.Copied', '已复制 AI 结果')),
                    ));
                  }
                },
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: Text(l10n.t('RAI.CopyResult', '复制结果')),
              ),
              if (widget.onApply != null && _resultAction != null)
                FilledButton.icon(
                  onPressed:
                      _runningAction != null ? null : () => _confirmApply(),
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: Text(l10n.t('RAI.Apply', '采纳应用')),
                ),
            ],
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(fontSize: 12, color: scheme.error),
          ),
        ],
        if (hasResult) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.tf('RAI.ResultTitle', '{0} 结果',
                      [_runningAction == null
                          ? (ref.read(l10nProvider).t('RAI.Result', 'AI'))
                          : '…']),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 6),
                if (_sourceText != null && _sourceText!.isNotEmpty) ...[
                  Text(
                    l10n.t('RAI.Original', '原文'),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    _sourceText!,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                  const SizedBox(height: 8),
                ],
                SelectableText(
                  _resultCtrl.text,
                  style: const TextStyle(fontSize: 14, height: 1.7),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 「重新选择」紧凑按钮 —— 清除粘性选区让用户重新框选。
class _ReselectButton extends StatelessWidget {
  const _ReselectButton({
    required this.tooltip,
    required this.label,
    required this.onPressed,
  });

  final String tooltip;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.restart_alt, size: 13, color: scheme.primary),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
