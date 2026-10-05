// 用 analyzer 包在**同进程内**跑一次真正的类型检查。
//
// 背景：本机 Dart VM 无法 spawn 任何子进程（`CreateFile failed 231`），
// 所以 `flutter analyze` / `dart analyze` / `dart run` 全挂。
// 但 `dart --disable-dart-dev <file>` 能跑（绕过 dartdev 的 native-assets build hook），
// 于是可以直接调用 `package:analyzer` 的 AnalysisContextCollection —— 全程同 isolate。
//
// 用法（必须带 --disable-dart-dev）：
//   dart --disable-dart-dev tools/analyze_inprocess.dart [lib 或具体文件...]
//
// 退出码：0 = 无 error/warning；1 = 有；2 = 自身异常。
//
// 覆盖范围（2026-10-05 实测）：
//   ✓ 编译错误（如 `const` 上下文里的非恒定表达式）—— 与 `flutter run` 报的错同类
//   ✓ analyzer 默认诊断（未使用变量 / 未引用声明 / 类型不匹配 …）
//   ✗ `include: package:flutter_lints/flutter.yaml` 里的 lint 规则**不生效**
//     （本 harness 不会注册 linter 插件）。所以「0 warning」不含 flutter_lints 的
//     prefer_const_constructors 之类 —— 那些不会让 `flutter run` 失败，可忽略。
//   自检方法：写一个故意违规的临时文件喂给它，确认能报错再信任结果。
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';

/// analyzer 要求「绝对且已归一化」的路径：Windows 上必须是反斜杠、无尾分隔符。
String _norm(String path) {
  String abs = File(path).absolute.path;
  if (Platform.isWindows) {
    abs = abs.replaceAll('/', r'\');
  }
  while (abs.length > 3 && (abs.endsWith(r'\') || abs.endsWith('/'))) {
    abs = abs.substring(0, abs.length - 1);
  }
  return abs;
}

Future<void> main(List<String> args) async {
  final String root = _norm(Directory.current.path);
  final List<String> targets = args.isEmpty
      ? <String>['$root${Platform.pathSeparator}lib']
      : args.map(_norm).toList(growable: false);

  final AnalysisContextCollection collection = AnalysisContextCollection(
    includedPaths: targets,
    excludedPaths: <String>[
      '$root${Platform.pathSeparator}build',
      '$root${Platform.pathSeparator}.dart_tool',
    ],
  );

  final List<String> lines = <String>[];
  int scanned = 0;
  int errors = 0;
  int warnings = 0;

  try {
    for (final dynamic context in collection.contexts) {
      final Iterable<String> files =
          (context.contextRoot as dynamic).analyzedFiles() as Iterable<String>;
      for (final String path in files) {
        if (!path.endsWith('.dart')) continue;
        scanned++;
        final dynamic session = context.currentSession;
        final dynamic result = await session.getResolvedUnit(path);
        if (result == null) continue;
        final dynamic diags = result.diagnostics;
        if (diags == null) continue;
        final dynamic lineInfo = result.lineInfo;
        for (final dynamic d in diags as Iterable<dynamic>) {
          final String sev = '${d.severity}';
          final bool isErr = sev.endsWith('.ERROR') || sev.endsWith('.error');
          final bool isWarn =
              sev.endsWith('.WARNING') || sev.endsWith('.warning');
          if (!isErr && !isWarn) continue;
          final int offset = (d.offset as int?) ?? 0;
          final int line =
              (lineInfo.getLocation(offset) as dynamic).lineNumber as int;
          final String rel = path.startsWith(root)
              ? path.substring(root.length + 1)
              : path;
          lines.add('${isErr ? "ERROR" : "WARN "} $rel:$line '
              '${d.message}');
          if (isErr) {
            errors++;
          } else {
            warnings++;
          }
        }
      }
    }
  } on Object catch (e, st) {
    stderr.writeln('分析器自身异常: $e\n$st');
    exit(2);
  } finally {
    try {
      (collection as dynamic).dispose();
    } on Object {
      // dispose 在旧版本里可能不存在
    }
  }

  stdout.writeln('已解析 $scanned 个文件');
  for (final String l in lines) {
    stdout.writeln(l);
  }
  stdout.writeln('error: $errors   warning: $warnings');
  exit(errors > 0 || warnings > 0 ? 1 : 0);
}
