// 本地 RWKV 模型扫描器 —— stub 回退实现（未知平台 / 无 dart:io）。
//
// 与 Native / Web 版本保持**同名同签名**：[RwkvModelScanner]。
// 仅通过条件导出使用，调用方直接 import rwkv_models.dart。
library;

import 'rwkv_models.dart';

/// 模型扫描器（stub，未知平台：返回空列表）。
class RwkvModelScanner {
  /// 构造。
  RwkvModelScanner();

  /// 扫描指定目录下的 .gguf / .bin 模型；stub 实现返回空列表。
  Future<List<RwkvLocalModel>> scan(String directoryPath) async =>
      const <RwkvLocalModel>[];
}
