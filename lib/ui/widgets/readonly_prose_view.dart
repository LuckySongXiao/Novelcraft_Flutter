import 'package:flutter/material.dart';

/// 段落分块只读阅读视图 —— 功能 A（章节预览）与功能 B（生成档案详情）共用。
///
/// 切分口径与 [ChapterStatsService] 一致：按 `\r\n|\r|\n` 切分、剔空行，
/// 每个非空块渲染为一个可选择/复制的段落。
class ReadonlyProseView extends StatelessWidget {
  const ReadonlyProseView({super.key, required this.content, this.fontSize = 16});

  final String content;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final List<String> paragraphs = <String>[
      for (final String l in content.split(RegExp(r'\r\n|\r|\n')))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          SelectableText(
            paragraphs[i],
            style: TextStyle(
              fontSize: fontSize,
              height: 1.7,
              color: scheme.onSurface,
            ),
          ),
        ],
      ],
    );
  }
}
