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

import '../../application/services/chapter_ai_model_resolver.dart'
    show ChapterAiModel, chapterAiModelProvider;
import '../../application/services/selection_edit_service.dart';
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
    this.foreshadowBlock = '',
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

  /// 本章的**伏笔联动**块（+49）—— 由全书细纲的「伏笔提示」派生，
  /// 说明本章要回收 / 提醒 / 新埋哪些线。默认只读展示，但同样允许手改。
  final String foreshadowBlock;

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

  /// AI 参考内容（卷大纲 / 章细纲 / 上一章结尾）的**可编辑副本**。
  ///
  /// 用户要求（+48）：「AI参考内容允许手动修改」。默认值来自宿主页从库里
  /// 读出的上下文；一旦用户手改过（[_refDirty]），就不再被宿主页的新值覆盖，
  /// 否则异步回填会把手打字冲掉。
  late final TextEditingController _refVolumeCtrl;
  late final TextEditingController _refChapterCtrl;
  late final TextEditingController _refTailCtrl;
  late final TextEditingController _refForeshadowCtrl;
  bool _refDirty = false;
  bool _refOpen = false;

  /// 上一次从宿主页拿到的参考内容（用于判断「用户是否改过」）。
  late final String _wVolume;
  late final String _wChapter;
  late final String _wTail;
  late final String _wForeshadow;

  final TextEditingController _resultCtrl = TextEditingController();
  ChapterAiAction? _runningAction;

  /// 当前结果由哪个动作产出（采纳应用时要区分「续写插入」与「替换」）。
  ChapterAiAction? _resultAction;
  String? _error;
  String? _sourceText;

  /// 本次解析到的模型（null = 还没跑过），供标题栏回显。
  ChapterAiModel? _model;

  @override
  void initState() {
    super.initState();
    _wVolume = widget.volumeOutline;
    _wChapter = widget.chapterOutline;
    _wTail = widget.prevChapterTail;
    _wForeshadow = widget.foreshadowBlock;
    _refVolumeCtrl = TextEditingController(text: _wVolume);
    _refChapterCtrl = TextEditingController(text: _wChapter);
    _refTailCtrl = TextEditingController(text: _wTail);
    _refForeshadowCtrl = TextEditingController(text: _wForeshadow);
  }

  @override
  void didUpdateWidget(covariant ChapterAiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主页异步装载上下文后会重发新值：用户没手改过才回填，否则手打的字
    // 会被异步回填冲掉（这正是「参考内容可手改」必须处理的竞态）。
    if (!_refDirty) {
      if (_refVolumeCtrl.text == _wVolume) {
        _refVolumeCtrl.text = widget.volumeOutline;
      }
      if (_refChapterCtrl.text == _wChapter) {
        _refChapterCtrl.text = widget.chapterOutline;
      }
      if (_refTailCtrl.text == _wTail) {
        _refTailCtrl.text = widget.prevChapterTail;
      }
      if (_refForeshadowCtrl.text == _wForeshadow) {
        _refForeshadowCtrl.text = widget.foreshadowBlock;
      }
    }
    _wVolume = widget.volumeOutline;
    _wChapter = widget.chapterOutline;
    _wTail = widget.prevChapterTail;
    _wForeshadow = widget.foreshadowBlock;
  }

  @override
  void dispose() {
    _requireCtrl.dispose();
    _refVolumeCtrl.dispose();
    _refChapterCtrl.dispose();
    _refTailCtrl.dispose();
    _refForeshadowCtrl.dispose();
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
        ChapterAiAction.deleteSelection => l10n.t('RAI.Delete', '删除'),
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
    // 删除所选文本是纯本地手术，不调模型、不需要 provider。
    if (action == ChapterAiAction.deleteSelection) {
      await _confirmDelete();
      return;
    }
    final l10n = ref.read(l10nProvider);
    final selected = _selectedText();
    if (selected.isEmpty) {
      setState(() => _error = l10n.t('RAI.NeedSelection',
          '请先在正文中选中一段文字，再使用 AI 操作'));
      return;
    }

    // 默认 13B（用户要求 +48）→ 拿不到再回落双 Agent / 默认 provider。
    // FutureProvider：首次（含一次 /models 探活）后缓存，之后不再探活。
    final ChapterAiModel? resolved =
        await ref.read(chapterAiModelProvider.future);
    if (!mounted) return;
    if (resolved == null) {
      setState(() => _error = l10n.t('RAI.NoProvider',
          '没有可用的 AI 服务，请先到「AI 配置」注册并设置默认模型'));
      return;
    }

    setState(() {
      _runningAction = action;
      _error = null;
      _resultCtrl.clear();
      _sourceText = selected;
      _model = resolved;
    });

    try {
      final text = await SelectionEditService.edit(
        provider: resolved.provider,
        model: resolved.model,
        action: action,
        selected: selected,
        fullContent: widget.fullContent,
        instruction: _requireCtrl.text.trim(),
        chapterOutline: _refChapterCtrl.text.trim(),
        volumeOutline: _refVolumeCtrl.text.trim(),
        prevChapterTail: _refTailCtrl.text.trim(),
        foreshadowBlock: _refForeshadowCtrl.text.trim(),
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

  /// 删除所选文本前的确认（本地手术，不走模型）。
  Future<void> _confirmDelete() async {
    final l10n = ref.read(l10nProvider);
    final String selected = _selectedText();
    if (selected.isEmpty) {
      if (!mounted) return;
      setState(() => _error = l10n.t('RAI.NeedSelection',
          '请先在正文中选中一段文字，再使用 AI 操作'));
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogCtx) => AlertDialog(
        title: Text(l10n.t('RAI.DeleteTitle', '删除所选文本')),
        content: Text(l10n.tf('RAI.DeleteConfirmFmt',
            '将从正文中删除选中的 {0} 字文本（章节版本号 +1，可在版本历史中追溯）。'
            '此操作不调用模型，删除后无法在本地撤销，请确认。',
            <Object>[selected.length])),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(l10n.t('RAI.Delete', '删除')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.onApply?.call('', ChapterAiAction.deleteSelection);
  }

  /// AI 参考内容（可手动修改）—— 卷大纲 / 章细纲 / 上一章结尾。
  ///
  /// 用户要求（+48）：「AI参考内容允许手动修改」。这三项原本是宿主页从库里
  /// 只读装载后原样注入提示词；现在给编辑入口，作者可以在不回头改库的前提下
  /// 临时微调本次生成的参考（例如把章细纲改成另一条走向再扩写）。
  Widget _buildReferenceEditor(L10n l10n, ColorScheme scheme) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            onTap: () => setState(() => _refOpen = !_refOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: <Widget>[
                  Icon(
                    _refOpen ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      l10n.t('RAI.RefContent', 'AI 参考内容（可手动修改）'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_refDirty)
                    Text(
                      '·',
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                  Text(
                    l10n.t('RAI.RefHint', '留空即不注入该项；改动立即对后续生成生效'),
                    style: TextStyle(
                        fontSize: 10, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          if (_refOpen) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _refField(l10n.t('RAI.RefVolume', '卷大纲'), _refVolumeCtrl),
                  const SizedBox(height: 8),
                  _refField(l10n.t('RAI.RefChapter', '章细纲'), _refChapterCtrl),
                  const SizedBox(height: 8),
                  _refField(l10n.t('RAI.RefTail', '上一章结尾'), _refTailCtrl),
                  const SizedBox(height: 8),
                  _refField(
                      l10n.t('RAI.RefForeshadow', '伏笔联动（本章需回收/提醒）'),
                      _refForeshadowCtrl),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _refField(String label, TextEditingController ctrl) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            Text(
              '${ctrl.text.characters.length}',
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 3),
        TextField(
          controller: ctrl,
          maxLines: 3,
          minLines: 1,
          style: const TextStyle(fontSize: 12, height: 1.5),
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() => _refDirty = true),
        ),
      ],
    );
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
        // ---- 模型回显：默认 13B（+48 用户要求）；回落时如实说明 ----
        Row(
          children: <Widget>[
            Icon(Icons.cloud_outlined, size: 13, color: scheme.primary),
            const SizedBox(width: 5),
            Text(
              '${l10n.t('RAI.ModelLabel', '当前模型')}：',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            Flexible(
              child: Text(
                _model == null
                    ? 'RWKV 13B'
                    : (_model!.fallback
                        ? l10n.tf('RAI.ModelFallbackFmt', '{0}（13B 不可用，已回落）',
                            <Object>[_model!.endpointLabel])
                        : _model!.endpointLabel),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color:
                      _model != null && _model!.fallback ? scheme.error : scheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: l10n.t('RAI.AntiRepeatTip',
                  '续写/重写/扩写已固定使用最严防重复采样（惩罚衰减 0.999 + 存在/频率惩罚 + DRY 全开）'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.shield_outlined,
                        size: 11, color: scheme.primary),
                    const SizedBox(width: 3),
                    Text(
                      l10n.t('RAI.AntiRepeat', '最严防重复'),
                      style: TextStyle(
                          fontSize: 10,
                          color: scheme.primary,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // ---- AI 参考内容（可手动修改，+48）----
        _buildReferenceEditor(l10n, scheme),
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
              if (action != ChapterAiAction.deleteSelection)
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
                          ChapterAiAction.deleteSelection =>
                            const Icon(Icons.delete_outline, size: 16),
                        },
                  label: Text(_actionLabel(action, l10n)),
                ),
            // 删除所选文本：**本地手术**（不调模型），所以不做成 tonal 按钮，
            // 也不用 loading 态 —— 与上面几个「AI 动作」在视觉上区分开。
            OutlinedButton.icon(
              onPressed: _runningAction != null ? null : _confirmDelete,
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
              ),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: Text(l10n.t('RAI.Delete', '删除')),
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
