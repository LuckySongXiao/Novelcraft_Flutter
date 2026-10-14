// 正文复读**只读扫描** CLI（不改任何数据）：
//   dart --disable-dart-dev tools/repetition_scan_cli.dart <in.json> <out.json>
//
// in.json : {"chapters":[{"id","title","status","content"}, ...]}
// out.json: {"items":[{id,title,status,ngram,para,consecutive,onset,length,
//                       keep,drop,truncatable,preview}], "stats":{...}}
//
// 与 `meta_cleanup_cli.dart` 同构：Dart 只跑规则（唯一真源），I/O 交给外部脚本。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/ai/utils/repetition_repair_text.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: repetition_scan_cli.dart <in.json> <out.json>');
    exit(2);
  }
  final dynamic decoded = jsonDecode(File(args[0]).readAsStringSync());
  final List<dynamic> chapters =
      (decoded is Map && decoded['chapters'] is List)
          ? decoded['chapters'] as List<dynamic>
          : <dynamic>[];

  final List<Map<String, Object?>> items = <Map<String, Object?>>[];
  int scanned = 0;
  int degenerate = 0;
  int truncatable = 0;

  for (final dynamic raw in chapters) {
    if (raw is! Map) continue;
    final String content = (raw['content'] ?? '').toString();
    if (content.trim().isEmpty) continue;
    scanned++;
    final RepetitionReport r = RepetitionRepair.analyze(content);
    if (!r.degenerate) continue;
    degenerate++;
    if (r.canTruncate) truncatable++;
    items.add(<String, Object?>{
      'id': (raw['id'] ?? '').toString(),
      'title': (raw['title'] ?? '').toString(),
      'status': (raw['status'] ?? '').toString(),
      'ngram': double.parse(r.ngram.toStringAsFixed(4)),
      'para': double.parse(r.paragraph.toStringAsFixed(4)),
      'consecutive': r.consecutiveLines,
      'onset': r.onset,
      'length': r.length,
      'keep': r.keepChars,
      'drop': r.dropChars,
      'truncatable': r.canTruncate,
      'preview': r.preview,
    });
  }

  items.sort(
    (Map<String, Object?> a, Map<String, Object?> b) =>
        (b['ngram']! as double).compareTo(a['ngram']! as double),
  );

  File(args[1]).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'items': items,
      'stats': <String, Object?>{
        'scanned': scanned,
        'degenerate': degenerate,
        'truncatable': truncatable,
        'needsRewrite': degenerate - truncatable,
      },
    }),
  );
  stdout.writeln(
    'scanned=$scanned degenerate=$degenerate truncatable=$truncatable '
    'needsRewrite=${degenerate - truncatable}',
  );
}
