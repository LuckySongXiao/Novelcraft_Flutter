// 「项目体检 → 一键清洗」的离线 CLI：把清洗规则跑在导出的章节 JSON 上。
//
// 为什么做成 CLI：本机 Dart VM 无法 spawn 子进程、也无法构建 GUI，但**能直跑纯 Dart**。
// 于是让 Dart 只负责「规则」（唯一真源 = lib/ai/utils/chapter_meta_cleaner.dart），
// 由外部脚本（python + sqlite3）负责 I/O，两边职责清晰、规则不会漂移。
//
// 用法：
//   dart --disable-dart-dev tools/meta_cleanup_cli.dart <in.json> <out.json>
//
// in.json : {"chapters":[{"id":"..","title":"..","summary":"..","chapterNo":3}, ...]}
// out.json: {"changes":[{"id":"..","newTitle":"..","newSummary":"..","reasons":[".."]}],
//            "stats":{"scanned":N,"titleFixes":N,"summaryFixes":N}}
//   * newTitle / newSummary 为 null 表示该字段无需改动。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/ai/utils/chapter_meta_cleaner.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: meta_cleanup_cli.dart <in.json> <out.json>');
    exit(2);
  }
  final String inPath = args[0];
  final String outPath = args[1];

  final dynamic decoded = jsonDecode(File(inPath).readAsStringSync());
  final List<dynamic> chapters =
      (decoded is Map && decoded['chapters'] is List)
          ? decoded['chapters'] as List<dynamic>
          : <dynamic>[];

  final List<Map<String, Object?>> changes = <Map<String, Object?>>[];
  int titleFixes = 0;
  int summaryFixes = 0;

  for (final dynamic raw in chapters) {
    if (raw is! Map) continue;
    final String id = (raw['id'] ?? '').toString();
    final String title = (raw['title'] ?? '').toString();
    final String summary = (raw['summary'] ?? '').toString();
    final int chapterNo = int.tryParse((raw['chapterNo'] ?? '0').toString()) ?? 0;

    final ChapterMetaFix fix = ChapterMetaCleaner.plan(
      rawTitle: title,
      rawSummary: summary,
      chapterNo: chapterNo,
    );
    if (!fix.hasChange) continue;

    if (fix.newTitle != null) titleFixes++;
    if (fix.newSummary != null) summaryFixes++;
    changes.add(<String, Object?>{
      'id': id,
      'newTitle': fix.newTitle,
      'newSummary': fix.newSummary,
      'reasons': fix.reasons,
    });
  }

  final Map<String, Object?> out = <String, Object?>{
    'changes': changes,
    'stats': <String, Object?>{
      'scanned': chapters.length,
      'changed': changes.length,
      'titleFixes': titleFixes,
      'summaryFixes': summaryFixes,
    },
  };
  File(outPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  stdout.writeln(
    'scanned=${chapters.length} changed=${changes.length} '
    'titleFixes=$titleFixes summaryFixes=$summaryFixes',
  );
}
