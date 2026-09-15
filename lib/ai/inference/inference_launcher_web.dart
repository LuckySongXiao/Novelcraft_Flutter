// 本地推理进程启动器 —— Web 实现。
//
// 对应 C# 中通过 `Process.Start` 拉起 RWKV 本地推理服务的逻辑。
//
// Web 平台无法使用 `dart:io` 的 [Process]，因此本实现不导入 `dart:io`，启动方法
// 直接抛出 [UnsupportedError]。在 Web 上本地推理进程应由独立的后端服务承载，由
// [RwkvProvider] 通过 HTTP 访问。
//
// 与另两个文件保持**同名同签名**：[InferenceProcessLauncher]。
library;

import 'dart:async';

/// 本地推理进程启动器（Web 实现，不支持直接启动进程）。
class InferenceProcessLauncher {
  /// 当前是否在运行中（Web 恒为 false）。
  bool get isRunning => false;

  /// 最近一次退出码（Web 恒为 null）。
  int? get lastExitCode => null;

  /// 最近 200 行 stdout（Web 恒为空）。
  List<String> get recentStdout => const <String>[];

  /// 最近 200 行 stderr（Web 恒为空）。
  List<String> get recentStderr => const <String>[];

  /// stderr 实时流（Web 恒为关闭状态）。
  Stream<String> get stderrStream => const Stream<String>.empty();

  /// 进程退出流（Web 恒为关闭状态）。
  Stream<int> get exitStream => const Stream<int>.empty();

  /// 启动本地推理进程。
  ///
  /// Web 平台不支持直接派生进程，直接抛出 [UnsupportedError]。
  Future<bool> start({
    required String executable,
    required List<String> arguments,
    String? workingDirectory,
    Duration startupTimeout = const Duration(seconds: 30),
  }) {
    throw UnsupportedError(
      'Web 平台不支持直接启动本地推理进程，'
      '请改用独立的后端 RWKV 服务并通过 HTTP 访问。',
    );
  }

  /// 停止本地推理进程（Web 无进程可停止）。
  Future<void> stop() async {}
}
