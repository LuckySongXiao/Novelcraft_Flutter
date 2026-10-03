// 章节导出根目录 —— 原生实现（Windows / 安卓 / iOS / macOS / Linux）。
//
// 目录对齐 key_value_store_native 的约定：
//   * Windows：`%APPDATA%\NovelManagement\exports`
//   * 其它：`{应用支持目录}/NovelManagement/exports`（path_provider 解析到
//     应用私有可写目录，安卓无需权限）
//
// ⚠ 不能用 `Platform.environment['APPDATA']` 一把梭：安卓上 APPDATA/HOME 均
// 为 null（真机已踩过 errno 30 的坑），非 Windows 必须走 path_provider。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 解析并创建导出根目录（`...\NovelManagement\exports`），返回绝对路径。
Future<String> exportRootDirectory() async {
  Directory base;
  if (Platform.isWindows) {
    final String appData =
        Platform.environment['APPDATA'] ?? Directory.current.path;
    base = Directory('$appData${Platform.pathSeparator}NovelManagement'
        '${Platform.pathSeparator}exports');
  } else {
    final Directory support = await getApplicationSupportDirectory();
    base = Directory('${support.path}${Platform.pathSeparator}NovelManagement'
        '${Platform.pathSeparator}exports');
  }
  if (!base.existsSync()) {
    base.createSync(recursive: true);
  }
  return base.path;
}

/// 路径分隔符（供导出服务拼路径）。
String get exportPathSeparator => Platform.pathSeparator;

/// 递归创建目录（导出服务用；Web 桩抛 UnsupportedError）。
void ensureDirSync(String path) {
  final Directory dir = Directory(path);
  if (!dir.existsSync()) dir.createSync(recursive: true);
}

/// 写文本文件（导出服务用；Web 桩抛 UnsupportedError）。
void writeTextFileSync(String path, String content) =>
    File(path).writeAsStringSync(content);
