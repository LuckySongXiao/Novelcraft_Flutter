// 本地推理进程启动器 —— Native 实现（桌面 / 移动）。
//
// 对应 C# 中通过 `Process.Start` 拉起 RWKV 本地推理服务的逻辑
// （C# 版 `Services/RWKV/` 下进程启动部分）。
//
// 本文件**是唯一允许 `import 'dart:io'`** 的 inference 实现，仅通过条件导出在
// Native 平台被选中，因此不会导致 Web 编译失败。使用 `dart:io` 的 [Process.start]
// 真正拉起本地 RWKV 服务进程，并持有其句柄以便优雅停止。
//
// 与另两个文件保持**同名同签名**：[InferenceProcessLauncher]。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// 本地推理进程启动器（Native 实现）。
class InferenceProcessLauncher {
  Process? _process;
  bool _running = false;
  int? _lastExitCode;
  final ListQueue<String> _stdoutLines = ListQueue<String>(200);
  final ListQueue<String> _stderrLines = ListQueue<String>(200);
  final StreamController<String> _stderrController =
      StreamController<String>.broadcast();
  final StreamController<int> _exitController =
      StreamController<int>.broadcast();

  /// 当前是否在运行中。
  bool get isRunning => _running;

  /// 最近一次退出码（进程未启动或仍在运行时为 null）。
  int? get lastExitCode => _lastExitCode;

  /// 环形缓冲区中最近 200 行 stdout。
  List<String> get recentStdout => _stdoutLines.toList(growable: false);

  /// 环形缓冲区中最近 200 行 stderr。
  List<String> get recentStderr => _stderrLines.toList(growable: false);

  /// 进程 stderr 的实时流（用于外部显示诊断）。
  Stream<String> get stderrStream => _stderrController.stream;

  /// 进程退出事件流（携带 exitCode）。
  Stream<int> get exitStream => _exitController.stream;

  /// 启动本地推理进程。
  ///
  /// [executable] 为 RWKV 可执行文件路径，[arguments] 为其启动参数
  /// （如 `--model`、`--host`、`--port`）。[startupTimeout] 为等待进程就绪的最长
  /// 时间（此处仅做进程成功派生判断，不做端口探活）。返回是否成功启动。
  ///
  /// 与 C# 差异：C# 用 `Process.Start` 同步派生；Dart 用 `Process.start` 异步派生，
  /// 并通过监听进程退出流更新 [isRunning] 状态。
  Future<bool> start({
    required String executable,
    required List<String> arguments,
    String? workingDirectory,
    Duration startupTimeout = const Duration(seconds: 30),
  }) async {
    if (_running) return true;
    _lastExitCode = null;
    _stdoutLines.clear();
    _stderrLines.clear();
    try {
      final execFile = File(executable);
      if (!execFile.existsSync()) {
        throw StateError('可执行文件不存在：$executable');
      }
      _process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        runInShell: false,
      );
      _running = true;
      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (String line) {
          if (_stdoutLines.length >= 200) _stdoutLines.removeFirst();
          _stdoutLines.add(line);
        },
        cancelOnError: true,
      );
      _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (String line) {
          if (_stderrLines.length >= 200) _stderrLines.removeFirst();
          _stderrLines.add(line);
          _stderrController.add(line);
        },
        cancelOnError: true,
      );
      _process!.exitCode.then((int code) {
        _lastExitCode = code;
        _running = false;
        _process = null;
        _exitController.add(code);
      });
      return true;
    } catch (e) {
      _running = false;
      _process = null;
      rethrow;
    }
  }

  /// 停止本地推理进程（发送 SIGTERM / kill）。
  Future<void> stop() async {
    if (_process != null) {
      try {
        _process!.kill(ProcessSignal.sigterm);
        await _process!.exitCode
            .timeout(const Duration(seconds: 5))
            .catchError((_) => 0);
      } catch (_) {
        _process?.kill();
      }
      _process = null;
    }
    _running = false;
  }
}
