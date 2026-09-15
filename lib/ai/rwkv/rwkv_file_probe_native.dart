// 文件探测 —— Native 实现（有 dart:io）。
//
// 与 stub 版保持**同名同签名**：[rwkvFileSizeOrNull]。
library;

import 'dart:io';

/// 返回 [path] 的字节数；文件不存在或不可读时返回 `null`。
///
/// 用于启动内置引擎前校验外置词表 / 权重的落地情况。
int? rwkvFileSizeOrNull(String path) {
  if (path.isEmpty) return null;
  try {
    final File f = File(path);
    if (!f.existsSync()) return null;
    return f.lengthSync();
  } on FileSystemException {
    return null;
  }
}

/// [path] 是否是一个已存在的目录（`--enable-dynamic-loading` 时 `--model-path` 传目录）。
bool rwkvPathIsDirectory(String path) {
  if (path.isEmpty) return false;
  try {
    return Directory(path).existsSync();
  } on FileSystemException {
    return false;
  }
}
