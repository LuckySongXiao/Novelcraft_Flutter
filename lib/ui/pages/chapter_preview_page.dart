import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/chapter_stats_service.dart';
import '../../core/enums/pseudo_enums.dart';
import '../../l10n/l10n.dart';
import '../widgets/readonly_prose_view.dart';

/// 章节只读预览页 —— 对应 C# `Views/ChapterPreviewDialog.xaml`。
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

  static const double _minFontSize = 13;
  static const double _maxFontSize = 24;

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

    final String title = (widget.values['title'] as String?)?.trim().isNotEmpty == true
        ? widget.values['title'] as String
        : l10n.t('Common.Unnamed', '未命名');
    final String content = (widget.values['content'] as String?) ?? '';
    final String? summary = (widget.values['summary'] as String?)?.trim();
    final String? notes = (widget.values['notes'] as String?)?.trim();
    final String? status = widget.values['status'] as String?;
    final String? type = (widget.values['type'] as String?)?.trim();
    final Object? version = widget.values['versionNumber'];
    final Object? editedAt = widget.values['lastEditedAt'];
    final Object? tagsRaw = widget.values['tags'];
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
          : ListView(
              padding: const EdgeInsets.all(16),
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
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _stat(l10n.t('CPV.WordCount', '字数'), '${stats.charCount}'),
                        _stat(l10n.t('CPV.Paragraphs', '段落'), '${stats.paragraphCount}'),
                        _stat(
                          l10n.t('CPV.ReadingTime', '阅读时长'),
                          l10n.tf('CPV.ReadingMinutesFmt', '约 {0} 分钟',
                              [stats.readingMinutes]),
                        ),
                        if (version != null)
                          _stat(l10n.t('CPV.VersionLabel', '版本'), '$version'),
                        if (editedAt != null && '$editedAt'.isNotEmpty)
                          _stat(l10n.t('CPV.LastEdited', '最后修改'), '$editedAt'),
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
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // ---- 正文阅读视图 ----
                ReadonlyProseView(content: content, fontSize: _fontSize),
                if (notes != null && notes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Card(
                    margin: EdgeInsets.zero,
                    color: scheme.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
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
