// 本地 RWKV 模型扫描器 —— Web 实现。
//
// Web 端没有本地文件系统，返回空列表（用户若想在 Web 端用 RWKV 需
// 走远程 HTTP OpenAI 兼容服务，走 rwkv_provider 的 HTTP 分支即可）。
library;

import 'rwkv_models.dart';

/// 模型扫描器（Web 实现：无文件系统，返回空列表）。
class RwkvModelScanner {
  /// 构造。
  RwkvModelScanner();

  /// 返回空列表（Web 端不可访问本地文件）。
  Future<List<RwkvLocalModel>> scan(String directoryPath) async =>
      const <RwkvLocalModel>[];
}
