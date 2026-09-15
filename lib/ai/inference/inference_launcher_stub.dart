// 本地推理进程启动器 —— 默认（stub）实现。
//
// 对应 C# 中 `Process.Start` 拉起 RWKV 本地推理服务的平台相关逻辑。
//
// 本文件作为条件导出的**回退实现**：当运行平台既不是 `dart.library.io`（Native）
// 也不是 `dart.library.js_interop`（Web）时使用。由于无法确定具体平台能力，启动
// 直接抛出 [UnsupportedError]。需要真实拉起本地进程时，请使用 Native 实现。
//
// 与另两个文件保持**同名同签名**：[InferenceProcessLauncher]。
library;

import 'dart:async';

/// 本地推理进程启动器（stub 回退实现）。
///
/// 仅声明与 native / web 一致的对外接口；本实现不支持实际启动进程。
class InferenceProcessLauncher {
  /// 当前是否在运行中（stub 恒为 false）。
  bool get isRunning => false;

  /// 最近一次退出码（stub 恒为 null）。
  int? get lastExitCode => null;

  /// 最近 200 行 stdout（stub 恒为空）。
  List<String> get recentStdout => const <String>[];

  /// 最近 200 行 stderr（stub 恒为空）。
  List<String> get recentStderr => const <String>[];

  /// stderr 实时流（stub 恒为关闭状态）。
  Stream<String> get stderrStream =>
      const Stream<String>.empty();

  /// 进程退出流（stub 恒为关闭状态）。
  Stream<int> get exitStream => const Stream<int>.empty();

  /// 启动本地推理进程。
  ///
  /// stub 实现不支持，直接抛出 [UnsupportedError]。
  Future<bool> start({
    required String executable,
    required List<String> arguments,
    String? workingDirectory,
    Duration startupTimeout = const Duration(seconds: 30),
  }) {
    throw UnsupportedError(
      '当前平台不支持直接启动本地推理进程（stub 实现）。',
    );
  }

  /// 停止本地推理进程。
  Future<void> stop() async {
    // stub 实现没有可停止的进程。
  }
}
