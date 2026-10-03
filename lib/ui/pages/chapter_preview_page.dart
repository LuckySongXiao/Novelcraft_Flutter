import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContentRange;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/chapter_stats_service.dart';
import '../../core/di.dart';
import '../../core/enums/pseudo_enums.dart';
import '../../l10n/l10n.dart';
import '../state/sticky_selection.dart';
import 'chapter_ai_panel.dart';

/// 章节阅读页 —— 对应 C# `Views/ChapterPreviewDialog.xaml` 并增强：
///
/// * 选节 AI 助手：选中正文片段 → 润色 / 扩写 / 续写（带附加要求）；
/// * 智能排版：正文列宽按视口自适应（≥1600 → 960；≥1200 → 840；更窄全宽），
///   手机/桌面皆可用；字号 13-24 手动微调。
///
/// [values] 来自 entity_page 表单快照（未保存的改动也能预览），
/// 键与 `chapterEntityConfig._chapterToMap` 对齐：
/// title/summary/content/status/type/wordCount/notes/versionNumber/lastEditedAt/tags。
class ChapterPreviewPage extends ConsumerStatefulWidget {
  const ChapterPreviewPage({super.key, required this.values});

  final Map<String, dynamic> values;

  @override
  ConsumerState<ChapterPreviewPage> createState() =>
      _ChapterPreviewPageState();
}

class _ChapterPreviewPageState extends ConsumerState<ChapterPreviewPage> {
  double _fontSize = 17;
  bool _aiPanelOpen = false;

  /// 粘性选区：SelectionArea 在指针按下其子树之外（含本页 AppBar 的 AI 开关、
  /// 面板输入框）时会清空选区并回调 null —— 直接回写会让「先选中文本再点
  /// AI 助手」的选区瞬间丢失。这里只有非空新选区才覆盖，null 不清空；
  /// 显式清除走面板的「重新选择」按钮。
  final StickySelection _selection = StickySelection();

  /// 选区精确捕获（主通道）：SelectionListener + 偏移量截取。
  ///
  /// `SelectionArea.onSelectionChanged` 的 SelectedContent.plainText 存在
  /// 「反向拖拽选区返回空串」等不可靠场景（真机实录：高亮在、面板读不到）；
  /// SelectionListenerNotifier 给出选区在正文串内的 start/end 偏移，
  /// 方向无关、逐字符精确。onSelectionChanged 仅作兜底。
  final SelectionListenerNotifier _selNotifier = SelectionListenerNotifier();
  String _displayContent = '';

  /// 页面展示用的章节字段快照 —— 可被「刷新」用数据库最新值覆盖。
  late final Map<String, dynamic> _values = <String, dynamic>{
    ...widget.values,
  };

  // ---- AI 选节助手的写作大纲与上下文（进入页面后台装载）----
  String _chapterOutline = '';
  String _volumeOutline = '';
  String _prevChapterTail = '';

  /// 唤出面板后自动滚动定位用
  final GlobalKey _aiPanelKey = GlobalKey();

  static const double _minFontSize = 13;
  static const double _maxFontSize = 24;

  @override
  void initState() {
    super.initState();
    _selNotifier.addListener(_onSelectionDetails);
    _loadAiContext();
  }

  @override
  void dispose() {
    _selNotifier.removeListener(_onSelectionDetails);
    _selNotifier.dispose();
    super.dispose();
  }

  /// 由偏移量截取选中文本（方向无关），写入粘性选区。
  void _onSelectionDetails() {
    if (!_selNotifier.registered) return;
    final SelectionDetails details = _selNotifier.selection;
    final SelectedContentRange? range = details.range;
    if (range == null || range.endOffset <= range.startOffset) return;
    final String body = _displayContent;
    if (body.isEmpty) return;
    final int start = range.startOffset.clamp(0, body.length);
    final int end = range.endOffset.clamp(0, body.length);
    if (end <= start) return;
    final String text = body.substring(start, end);
    if (text.trim().isEmpty) return;
    if (text != _selection.text) {
      setState(() => _selection.update(text));
    }
  }

  /// 装载扩写/续写所需的大纲与上下文：
  /// 本章梗概 + 所属卷宗大纲 + 前一章结尾（同卷按序取上一章）。
  /// 失败不阻塞阅读与润色 —— 扩写静默降级为无大纲模式。
  Future<void> _loadAiContext() async {
    final String? id = widget.values['id']?.toString();
    if (id == null || id.isEmpty) return;
    try {
      final row = await ref.read(chapterServiceProvider).getById(id);
      if (row == null) return;
      String outline =
          (row.summary ?? '').trim().isNotEmpty
              ? row.summary!.trim()
              : (widget.values['summary'] ?? '').toString().trim();
      String volOutline = '';
      String tail = '';
      final String vid = row.volumeId;
      if (vid.isNotEmpty) {
        final vol = await ref.read(volumeServiceProvider).getById(vid);
        volOutline = (vol?.description ?? '').trim();
        final all =
            await ref.read(chapterServiceProvider).getByProjectId(row.projectId ?? '');
        final List<dynamic> sameVolume = all.where((dynamic c) => c.volumeId == vid).toList()
          ..sort((dynamic a, dynamic b) => a.orderIndex.compareTo(b.orderIndex));
        final int idx = sameVolume.indexWhere((dynamic c) => c.id == id);
        if (idx > 0) {
          final String prev = (sameVolume[idx - 1].content ?? '').toString();
          tail = prev.length > 600 ? prev.substring(prev.length - 600) : prev;
        }
      }
      if (!mounted) return;
      setState(() {
        _chapterOutline = outline;
        _volumeOutline = volOutline;
        _prevChapterTail = tail;
      });
    } catch (_) {
      // 静默降级：AI 面板仍可用（扩写/续写少大纲上下文）
    }
  }

  /// 手动刷新：从数据库重读本章最新正文与元信息，并重载 AI 上下文
  ///（此前本页只有 initState 一次性加载 —— 别处改完章节回来看不到更新）。
  Future<void> _refresh() async {
    final String? id = _values['id']?.toString();
    if (id == null || id.isEmpty) return;
    try {
      final row = await ref.read(chapterServiceProvider).getById(id);
      if (row != null && mounted) {
        setState(() {
          _values
            ..['title'] = row.title
            ..['content'] = row.content ?? ''
            ..['summary'] = row.summary
            ..['notes'] = row.notes
            ..['status'] = row.status
            ..['type'] = row.type
            ..['tags'] = row.tags
            ..['wordCount'] = row.wordCount
            ..['versionNumber'] = row.versionNumber
            ..['lastEditedAt'] = row.lastEditedAt;
        });
      }
    } catch (_) {
      // 读取失败保持原快照，不打断阅读
    }
    await _loadAiContext();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ref.read(l10nProvider).t('Common.Refreshed', '已刷新')),
    ));
  }

  /// 唤出/收起 AI 面板；唤出后自动滚动到面板（长章下面板在正文之后，
  /// 不滚动的话用户会以为「点了没反应」）。
  void _toggleAiPanel() {
    setState(() => _aiPanelOpen = !_aiPanelOpen);
    if (!_aiPanelOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? ctx = _aiPanelKey.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.05,
        );
      }
    });
  }

  /// 智能排版：视口宽度 → 正文列最大宽（最佳阅读行长约 35-45 字）。
  double _contentMaxWidth(double viewportWidth) {
    if (viewportWidth >= 1600) return 960;
    if (viewportWidth >= 1200) return 840;
    if (viewportWidth >= 900) return 760;
    return double.infinity; // 窄屏全宽（留 padding）
  }

  String _statusLabel(L10n l10n, String? status) {
    final String s = (status ?? '').trim();
    for (final OptionEntry o in PseudoEnums.chapterStatuses) {
      if (o.value == s) return o.labelFor(l10n.isEnglish);
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;

    final Map<String, dynamic> values = _values;
    final String title = (values['title'] as String?)?.trim().isNotEmpty == true
        ? values['title'] as String
        : l10n.t('Common.Unnamed', '未命名');
    final String content = (values['content'] as String?) ?? '';
    final String? summary = (values['summary'] as String?)?.trim();
    final String? notes = (values['notes'] as String?)?.trim();
    final String? status = values['status'] as String?;
    final String? type = (values['type'] as String?)?.trim();
    final Object? version = values['versionNumber'];
    final Object? editedAt = values['lastEditedAt'];
    final Object? tagsRaw = values['tags'];
    final List<String> tags = (tagsRaw is String && tagsRaw.trim().isNotEmpty)
        ? tagsRaw.split(RegExp(r'[,，;；]')).map((t) => t.trim()).where((t) => t.isNotEmpty).toList()
        : const <String>[];

    final ChapterStats stats = ChapterStatsService.compute(content: content);

    return Scaffold(
      appBar: AppBar(
        // 复用 C# 移植死键：CPV.TitleFmt = '章节预览 - {0}'
        title: Text(l10n.tf('CPV.TitleFmt', '章节预览 - {0}', [title])),
        actions: [
          IconButton(
            tooltip: l10n.t('Common.Refresh', '刷新'),
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: l10n.t('CPV.FontSmaller', '缩小字号'),
            icon: const Icon(Icons.text_decrease),
            onPressed: () => setState(() {
              _fontSize = (_fontSize - 1).clamp(_minFontSize, _maxFontSize);
            }),
          ),
          IconButton(
            tooltip: l10n.t('CPV.FontLarger', '放大字号'),
            icon: const Icon(Icons.text_increase),
            onPressed: () => setState(() {
              _fontSize = (_fontSize + 1).clamp(_minFontSize, _maxFontSize);
            }),
          ),
          const SizedBox(width: 4),
          // 选节 AI 助手开关：选中正文片段后唤出润色/去重/扩写/续写面板
          IconButton(
            tooltip: l10n.t('RAI.Toggle', 'AI 选节助手'),
            isSelected: _aiPanelOpen,
            selectedIcon: const Icon(Icons.auto_awesome),
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: content.trim().isEmpty ? null : _toggleAiPanel,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: content.trim().isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book_outlined,
                      size: 48, color: scheme.outline),
                  const SizedBox(height: 12),
                  Text(l10n.t('CPV.Empty', '正文为空')),
                ],
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // 智能排版：正文列宽随视口自适应，居中呈现
                final double maxW = _contentMaxWidth(
                  MediaQuery.sizeOf(context).width,
                );
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxW),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: maxW),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 12),
                              // ---- 统计面板（对齐 C# L137-161）----
                              Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Wrap(
                                    spacing: 20,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      _stat(l10n.t('CPV.WordCount', '字数'),
                                          '${stats.charCount}'),
                                      _stat(
                                          l10n.t('CPV.Paragraphs', '段落'),
                                          '${stats.paragraphCount}'),
                                      _stat(
                                          l10n.t('CPV.ReadingTime', '阅读时长'),
                                          l10n.tf('CPV.ReadingMinutesFmt',
                                              '约 {0} 分钟',
                                              [stats.readingMinutes])),
                                      if (version != null)
                                        _stat(l10n.t('CPV.VersionLabel', '版本'),
                                            '$version'),
                                      if (editedAt != null &&
                                          '$editedAt'.isNotEmpty)
                                        _stat(l10n.t('CPV.LastEdited', '最后修改'),
                                            '$editedAt'),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              // ---- 元信息 Chip：状态 / 类型 / 标签 ----
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (status != null && status.isNotEmpty)
                                    Chip(
                                      avatar: Icon(Icons.flag_outlined,
                                          size: 16, color: scheme.primary),
                                      label: Text(_statusLabel(l10n, status)),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  if (type != null && type.isNotEmpty)
                                    Chip(
                                      avatar: Icon(Icons.category_outlined,
                                          size: 16, color: scheme.primary),
                                      label: Text(type),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  for (final String t in tags)
                                    Chip(
                                      avatar: Icon(Icons.sell_outlined,
                                          size: 16, color: scheme.primary),
                                      label: Text(t),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                ],
                              ),
                              if (summary != null && summary.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Card(
                                  margin: EdgeInsets.zero,
                                  color: scheme.surfaceContainerLow,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          l10n.t('CPV.Summary', '梗概'),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        SelectableText(summary,
                                            style: const TextStyle(
                                                fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 16),
                              // ---- 正文阅读视图（选节 AI 助手的目标区域）----
                              // SelectionListener 精确捕获（主）+ onSelectionChanged 粘性（兜底）。
                              // 正文合并为单一 Text：偏移量即纯文本下标，方向无关。
                              Builder(builder: (BuildContext proseCtx) {
                                final List<String> paragraphs = <String>[
                                  for (final String l
                                      in content.split(RegExp(r'\r\n|\r|\n')))
                                    if (l.trim().isNotEmpty) l.trim(),
                                ];
                                _displayContent = paragraphs.join('\n\n');
                                return SelectionArea(
                                  onSelectionChanged: (sel) => setState(
                                      () => _selection.update(sel?.plainText)),
                                  child: SelectionListener(
                                    selectionNotifier: _selNotifier,
                                    child: Text(
                                      _displayContent,
                                      style: TextStyle(
                                        fontSize: _fontSize,
                                        height: 1.7,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                  ),
                                );
                              }),
                              // ---- 选节 AI 助手面板 ----
                              if (_aiPanelOpen) ...[
                                const SizedBox(height: 16),
                                Container(
                                  key: _aiPanelKey,
                                  child: ChapterAiPanel(
                                    selectedText: _selection.text,
                                    fullContent: content,
                                    chapterOutline: _chapterOutline,
                                    volumeOutline: _volumeOutline,
                                    prevChapterTail: _prevChapterTail,
                                    onClearSelection: () =>
                                        setState(_selection.clear),
                                  ),
                                ),
                              ],
                              if (notes != null && notes.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                Card(
                                  margin: EdgeInsets.zero,
                                  color: scheme.surfaceContainerLow,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          l10n.t('CPV.Notes', '备注'),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        SelectableText(notes,
                                            style: const TextStyle(
                                                fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _stat(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        Text(value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
