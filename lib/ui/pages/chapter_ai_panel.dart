// 章节阅读 · 选节 AI 助手 —— 选中正文片段后按要求润色 / 扩写 / 续写。
//
// 设计：
//   * 选区来源：阅读页用 SelectionArea 包正文，经 onSelectionChanged
//     回调拿到纯文本选区（SelectedContent.plainText），以参数传入本面板。
//   * 调用链：走 modelManager 默认 provider（与 AI 协作页同源），
//     非流式单次请求（长选段 + 指令一次出结果，阅读页不需要打字机）。
//   * 三种操作各有独立提示词；附加要求来自输入框（可空）。
//   * 结果以对照卡呈现（原文 / 结果），提供「复制结果」——预览页是
//     只读快照，不写回章节正文（写回走章节编辑表单，职责分离）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/models/chat.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

/// 选节 AI 操作类型。
enum ChapterAiAction {
  /// 润色（保持原意，提升文笔）。
  polish,

  /// 去重润色 —— 专治选中片段内的重复句式 / 复读段落。
  dedupePolish,

  /// 扩写（结合写作大纲与上下文）。
  expand,

  /// 续写（紧接选区结尾）。
  continueWrite,
}

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

  @override
  ConsumerState<ChapterAiPanel> createState() => _ChapterAiPanelState();
}

class _ChapterAiPanelState extends ConsumerState<ChapterAiPanel> {
  final TextEditingController _requireCtrl = TextEditingController();
  final TextEditingController _resultCtrl = TextEditingController();
  ChapterAiAction? _runningAction;
  String? _error;
  String? _sourceText;

  @override
  void dispose() {
    _requireCtrl.dispose();
    _resultCtrl.dispose();
    super.dispose();
  }

  String _selectedText() => widget.selectedText.trim();

  String _buildPrompt(ChapterAiAction action, String selected, L10n l10n) {
    final extra = _requireCtrl.text.trim();
    final extraLine =
        extra.isEmpty ? '' : '\n用户附加要求：$extra\n';
    final contextHead = widget.fullContent.length > 1200
        ? '【上文节选】\n${widget.fullContent.substring(widget.fullContent.length - 1200)}\n\n'
        : (widget.fullContent.isEmpty
            ? ''
            : '【上文节选】\n${widget.fullContent}\n\n');
    final String outlineBlock = _outlineBlock();
    final String prevTail = widget.prevChapterTail.trim().isEmpty
        ? ''
        : '【前一章结尾】\n${widget.prevChapterTail.trim()}\n\n';
    switch (action) {
      case ChapterAiAction.polish:
        return '你是资深网文编辑。请润色以下正文片段：保持原意、人物与情节'
            '完全不变，提升文笔流畅度与画面感，禁止新增情节或设定。$extraLine'
            '【待润色片段】\n$selected\n\n只输出润色后的片段本身。';
      case ChapterAiAction.dedupePolish:
        return '你是资深网文编辑。以下片段存在重复内容（重复句式、复读段落或'
            '语义雷同的表述）。请先去重：每层意思只保留表达最自然、信息量最足'
            '的一处，删除其余；再对保留文本做轻度润色，使行文连贯自然。保持原意、'
            '人物与情节完全不变，禁止新增情节或设定，篇幅只减不增。$extraLine'
            '【待处理片段】\n$selected\n\n只输出去重润色后的片段本身。';
      case ChapterAiAction.expand:
        return '你是资深网文作者。请结合写作大纲与上下文，对以下正文片段进行'
            '扩写：补充环境细节、动作拆解与心理描写，篇幅扩至约 2-3 倍；'
            '人物性格与既定情节不得改变，不得与大纲冲突或提前泄露后续情节。'
            '$outlineBlock$prevTail$extraLine'
            '【待扩写片段】\n$selected\n\n只输出扩写后的片段。';
      case ChapterAiAction.continueWrite:
        return '你是资深网文作者。请紧接以下片段自然续写约 600 字：保持'
            '叙事视角与文风连贯，推进情节但不要在本轮结束故事。'
            '$outlineBlock$contextHead$extraLine【待续写片段（结尾处续写）】\n$selected\n\n'
            '只输出续写的新增内容。';
    }
  }

  /// 组装【写作大纲】块：本章梗概 + 卷宗大纲（都为空时返回空串）。
  String _outlineBlock() {
    final List<String> parts = <String>[
      if (widget.chapterOutline.trim().isNotEmpty)
        '本章梗概：${widget.chapterOutline.trim()}',
      if (widget.volumeOutline.trim().isNotEmpty)
        '卷宗大纲：${widget.volumeOutline.trim()}',
    ];
    if (parts.isEmpty) return '';
    return '【写作大纲（创作须贴合，不得冲突）】\n${parts.join('\n')}\n\n';
  }

  String _actionLabel(ChapterAiAction a, L10n l10n) => switch (a) {
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
    final l10n = ref.read(l10nProvider);
    final selected = _selectedText();
    if (selected.isEmpty) {
      setState(() => _error = l10n.t('RAI.NeedSelection',
          '请先在正文中选中一段文字，再使用 AI 操作'));
      return;
    }

    final provider = ref.read(modelManagerProvider).getDefaultProvider();
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
      final resp = await provider.chat(
        ChatRequest(
          systemPrompt: '你是 NovelCraft 的章节 AI 助手，严格按用户指令处理'
              '小说正文片段，只输出结果文本本身，不要解释、不要 Markdown 包装。',
          messages: <ChatMessage>[ChatMessage.user(_buildPrompt(action, selected, l10n))],
          temperature: 0.8,
          maxTokens: 2048,
        ),
      );
      final text = resp.content.trim();
      if (!resp.isSuccess || text.isEmpty) {
        setState(() {
          _error = resp.errorMessage ?? l10n.t('RAI.EmptyResult', 'AI 返回空结果');
          _runningAction = null;
        });
        return;
      }
      setState(() {
        _resultCtrl.text = text;
        _runningAction = null;
      });
    } on Object catch (e) {
      setState(() {
        _error = e.toString();
        _runningAction = null;
      });
    }
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
            if (hasResult)
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
