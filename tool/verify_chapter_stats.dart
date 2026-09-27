// ignore_for_file: avoid_print
//
// 章节统计口径验证（chapter_stats_service.dart，纯 Dart 可直接跑）。
//
// 口径对齐 C# ChapterPreviewDialog 统计面板：段落=按 \r\n|\r|\n 切分后的非空块，
// 阅读时长=字数/400 字每分钟向上取整，目标进度=字数/目标字数百分比。
//
// 运行：dart run tool/verify_chapter_stats.dart
import 'dart:io';

import 'package:novelcraft/application/services/chapter_stats_service.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $name — $detail');
  } else {
    fail++;
    print('  ❌ $name — $detail');
  }
}

void main() {
  print('=' * 78);
  print('[1] 空正文 / null：全 0、阅读时长 0、无目标进度');
  print('=' * 78);
  final ChapterStats empty = ChapterStatsService.compute(content: '');
  check('空正文字数为 0', empty.charCount == 0, '${empty.charCount}');
  check('空正文段落为 0', empty.paragraphCount == 0, '${empty.paragraphCount}');
  check('空正文阅读时长为 0', empty.readingMinutes == 0, '${empty.readingMinutes}');
  final ChapterStats nullContent = ChapterStatsService.compute(content: null);
  check('null 内容等同空正文', nullContent.charCount == 0, '${nullContent.charCount}');

  print('');
  print('=' * 78);
  print('[2] 换行口径：\\r\\n / \\r / \\n 三种换行 + 空行剔除');
  print('=' * 78);
  final ChapterStats crlf = ChapterStatsService.compute(
      content: '第一段\r\n第二段\r\n\r\n第三段');
  check('CRLF 段落数=3（空行剔除）', crlf.paragraphCount == 3, '${crlf.paragraphCount}');
  check('CRLF 行数=4（含空行）', crlf.lineCount == 4, '${crlf.lineCount}');
  final ChapterStats cr = ChapterStatsService.compute(content: '甲\r乙\r丙');
  check('CR 段落数=3', cr.paragraphCount == 3, '${cr.paragraphCount}');
  final ChapterStats lf = ChapterStatsService.compute(content: '甲\n乙\n\n\n丙');
  check('LF 段落数=3（连续空行剔除）', lf.paragraphCount == 3, '${lf.paragraphCount}');

  print('');
  print('=' * 78);
  print('[3] 阅读时长：400 字/分钟向上取整');
  print('=' * 78);
  final String fourHundred = 'a' * 400;
  final ChapterStats exact = ChapterStatsService.compute(content: fourHundred);
  check('恰好 400 字 → 1 分钟', exact.readingMinutes == 1, '${exact.readingMinutes}');
  final ChapterStats oneMore = ChapterStatsService.compute(content: '${fourHundred}a');
  check('401 字 → 2 分钟（向上取整）', oneMore.readingMinutes == 2,
      '${oneMore.readingMinutes}');
  final ChapterStats short1 = ChapterStatsService.compute(content: '短');
  check('1 字 → 1 分钟（非 0 即整）', short1.readingMinutes == 1,
      '${short1.readingMinutes}');

  print('');
  print('=' * 78);
  print('[4] 目标进度：百分比四舍五入、clamp 0-999、目标缺省/非法');
  print('=' * 78);
  final ChapterStats half = ChapterStatsService.compute(
      content: 'a' * 500, targetWordCount: 1000);
  check('500/1000 → 50%', half.targetProgressPercent == 50,
      '${half.targetProgressPercent}');
  final ChapterStats over = ChapterStatsService.compute(
      content: 'a' * 3000, targetWordCount: 100);
  check('3000/100 → clamp 999', over.targetProgressPercent == 999,
      '${over.targetProgressPercent}');
  final ChapterStats noTarget =
      ChapterStatsService.compute(content: 'a' * 100);
  check('目标缺省 → null 进度', noTarget.targetProgressPercent == null,
      '${noTarget.targetProgressPercent}');
  final ChapterStats badTarget = ChapterStatsService.compute(
      content: 'a' * 100, targetWordCount: 0);
  check('目标 0 → null 进度', badTarget.targetProgressPercent == null,
      '${badTarget.targetProgressPercent}');

  print('');
  print('=' * 78);
  print('[5] 中英混排与空白块');
  print('=' * 78);
  final ChapterStats mixed = ChapterStatsService.compute(
      content: '  \n中文段落 with English words。\n   \n\t\n另一个段落');
  check('纯空白行不算段落', mixed.paragraphCount == 2, '${mixed.paragraphCount}');
  check('字数含空白字符（与 wordCount 口径一致）', mixed.charCount > 0,
      '${mixed.charCount}');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
