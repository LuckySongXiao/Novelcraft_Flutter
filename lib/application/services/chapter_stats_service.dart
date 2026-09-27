// 章节正文统计 —— 对应 C# ChapterPreviewDialog.xaml.cs 的统计面板（L137-161）。
//
// 口径与 C# 对齐：
//   段落数   = 按 `\r\n|\r|\n` 切分后的**非空**块数；
//   行数     = 切分后的总块数（含空行）；
//   阅读时长 = 字数 / 400 字每分钟，向上取整；
//   目标进度 = 字数 / 目标字数（目标缺省时不计）。
//
// 纯 Dart、零 flutter import，可被 tool/verify_*.dart 直接回归。
library;

/// 章节统计结果。
class ChapterStats {
  const ChapterStats({
    required this.charCount,
    required this.paragraphCount,
    required this.lineCount,
    required this.readingMinutes,
    this.targetProgressPercent,
  });

  /// 字符数（与落库 wordCount 口径一致：content.length）。
  final int charCount;

  /// 非空段落块数。
  final int paragraphCount;

  /// 换行切分总行数（含空行）。
  final int lineCount;

  /// 阅读时长（分钟，向上取整；空正文为 0）。
  final int readingMinutes;

  /// 目标字数进度百分比（0-999；目标缺省为 null）。
  final int? targetProgressPercent;
}

abstract final class ChapterStatsService {
  /// 每分钟阅读字数（对齐 C# 400 字/分钟）。
  static const int charsPerMinute = 400;

  static ChapterStats compute({required String? content, int? targetWordCount}) {
    final String text = content ?? '';
    final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
    final List<String> paragraphs = <String>[
      for (final String l in lines)
        if (l.trim().isNotEmpty) l.trim(),
    ];
    final int charCount = text.length;
    final int minutes =
        charCount == 0 ? 0 : (charCount / charsPerMinute).ceil();
    int? progress;
    if (targetWordCount != null && targetWordCount > 0) {
      progress = ((charCount / targetWordCount) * 100).round().clamp(0, 999);
    }
    return ChapterStats(
      charCount: charCount,
      paragraphCount: paragraphs.length,
      lineCount: lines.length,
      readingMinutes: minutes,
      targetProgressPercent: progress,
    );
  }
}
