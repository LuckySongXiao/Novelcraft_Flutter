// 本地 RWKV 模型扫描器 —— Native 实现（有 dart:io）。
//
// 与 stub / web 版本保持**同名同签名**：[RwkvModelScanner]。
// 真正调用 [Directory.list] 扫描目录下 `.pth` / `.rwkvq` 文件并解析元数据。
//
// 唯一推理引擎 `rwkv_lightning_cuda` 只认这两种原生权重格式；GGUF 属
// llama.cpp 路线，已随该引擎一并移除。
library;

import 'dart:io';

import 'rwkv_models.dart';

/// 模型扫描器（Native 实现）。
class RwkvModelScanner {
  /// 构造。
  RwkvModelScanner();

  /// 扫描 [directoryPath] 及其一层子目录下的 `.pth` / `.rwkvq` 文件。
  ///
  /// - 跳过 `states/`（state 调优产物，不是可加载权重）与 `_tools/`（引擎二进制）；
  /// - 按文件体积倒序，便于 UI 默认选中最大的完整权重。
  Future<List<RwkvLocalModel>> scan(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return const <RwkvLocalModel>[];
    final out = <RwkvLocalModel>[];
    await _scanInto(out, dir, depth: 0);
    out.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    return out;
  }

  static const Set<String> _skippedDirs = <String>{'states', '_tools'};

  Future<void> _scanInto(
    List<RwkvLocalModel> out,
    Directory dir, {
    required int depth,
  }) async {
    await for (final entity in dir.list(followLinks: false)) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (entity is Directory) {
        if (depth >= 1 || _skippedDirs.contains(name.toLowerCase())) continue;
        await _scanInto(out, entity, depth: depth + 1);
        continue;
      }
      if (entity is! File) continue;
      final String lower = name.toLowerCase();
      if (!lower.endsWith('.pth') && !lower.endsWith('.rwkvq')) continue;
      final stat = await entity.stat();
      out.add(parseRwkvFileName(entity.absolute.path, name, stat.size));
    }
  }
}
