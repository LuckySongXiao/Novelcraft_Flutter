// 本地 RWKV 模型扫描器 —— Native 实现（有 dart:io）。
//
// 与 stub / web 版本保持**同名同签名**：[RwkvModelScanner]。
// 真正调用 [Directory.list] 扫描目录下 .gguf / .bin 文件并解析元数据。
library;

import 'dart:io';

import 'rwkv_models.dart';

/// 模型扫描器（Native 实现）。
class RwkvModelScanner {
  /// 构造。
  RwkvModelScanner();

  /// 扫描 [directoryPath] 下所有 .gguf / .bin 文件，按文件名解析元数据。
  Future<List<RwkvLocalModel>> scan(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return const <RwkvLocalModel>[];
    final out = <RwkvLocalModel>[];
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      final lower = name.toLowerCase();
      if (!lower.endsWith('.gguf') && !lower.endsWith('.bin')) continue;
      final stat = await entity.stat();
      out.add(parseRwkvFileName(entity.absolute.path, name, stat.size));
    }
    out.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    return out;
  }
}
