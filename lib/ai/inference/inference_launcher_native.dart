// 本地推理进程启动器 —— Native 实现（桌面 / 移动）。
//
// 对应 C# 中通过 `Process.Start` 拉起 RWKV 本地推理服务的逻辑
// （C# 版 `Services/RWKV/` 下进程启动部分）。
//
// 本文件**是唯一允许 `import 'dart:io'`** 的 inference 实现，仅通过条件导出在
// Native 平台被选中，因此不会导致 Web 编译失败。使用 `dart:io` 的 [Process.start]
// 真正拉起本地 RWKV 服务进程，并持有其句柄以便优雅停止。
//
// 显存泄漏治理（本文件承担一半职责）：
// 1. **启动成功即把 pid 落盘**（`<系统临时目录>/novelcraft_inference_server.pid.json`），
//    进程退出 / 手动停止时清除。App 被强杀时文件会残留，供下次启动精确回收。
// 2. [stop] 在 `SIGTERM` 超时后**强杀**，并在最后按 pid 兜底补刀 —— 早期实现
//    `timeout(...).catchError((_) => 0)` 之后就把句柄扔掉，进程其实还活着，
//    GPU 显存一直被占（PITFALLS：显存被上一轮模型顶掉）。
// 3. [reclaimOrphaned] 静态方法：读 pid 记录 → 校验镜像名确实是我们的推理进程
//    → 终止。App 启动时与退出时各调一次（见 `main.dart`）。
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

  /// pid 记录文件路径（进程间共享，跨 App 生命周期有效）。
  static String get pidRecordPath =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}$_pidFileName';

  static const String _pidFileName = 'novelcraft_inference_server.pid.json';

  /// 当前是否在运行中。
  bool get isRunning => _running;

  /// 进程 pid（未运行时为 null）。用于「停止」时的日志与 UI 展示。
  int? get pid => _process?.pid;

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
      final int startedPid = _process!.pid;
      // 落盘 pid：App 异常退出后靠它精确回收，避免显存被孤儿进程长期占用。
      unawaited(_writePidRecord(startedPid, executable));
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
        unawaited(_clearPidRecord(startedPid));
        _exitController.add(code);
      });
      return true;
    } catch (e) {
      _running = false;
      _process = null;
      rethrow;
    }
  }

  /// 停止本地推理进程（SIGTERM → 超时强杀 → 按 pid 兜底）。
  Future<void> stop() async {
    final Process? p = _process;
    if (p != null) {
      final int stoppedPid = p.pid;
      try {
        p.kill(ProcessSignal.sigterm);
        bool exited = true;
        try {
          await p.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          exited = false;
        } on Object {
          exited = false;
        }
        if (!exited) {
          // ⚠ 关键修复：超时后必须强杀。早期实现此处直接放弃，进程继续占显存。
          try {
            p.kill(ProcessSignal.sigkill);
          } on Object {
            // 句柄可能已失效，走下面的 pid 兜底
          }
          try {
            await p.exitCode.timeout(const Duration(seconds: 3));
          } on Object {
            // 忽略：交给 pid 兜底
          }
        }
      } on Object {
        try {
          p.kill();
        } on Object {
          // 忽略
        }
      }
      // 兜底：句柄失效但进程仍在（Windows 上 SIGTERM 不总是生效）
      if (await _queryProcessImageName(stoppedPid) != null) {
        try {
          Process.killPid(stoppedPid, ProcessSignal.sigkill);
        } on Object {
          // 忽略
        }
      }
      _process = null;
      await _clearPidRecord(stoppedPid);
    }
    _running = false;
  }

  /// 回收**遗留**的本地推理进程（App 上次异常退出 / 引擎重建后残留的孤儿）。
  ///
  /// 返回真正终止的进程数。安全性：只终止 pid 记录文件里登记过、且镜像名
  /// 确实是推理服务的进程 —— 避免 pid 被系统回收后误杀无关程序。
  static Future<int> reclaimOrphaned() async {
    try {
      final File f = File(pidRecordPath);
      if (!f.existsSync()) return 0;
      final String raw = await f.readAsString();
      // 先删记录：即使后面终止失败，也不再反复尝试同一个失效 pid。
      try {
        await f.delete();
      } on Object {
        // 忽略
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return 0;
      final int? recordedPid = (decoded['pid'] as num?)?.toInt();
      if (recordedPid == null || recordedPid <= 0) return 0;
      final String recordedExe = '${decoded['exe'] ?? ''}';

      final String? image = await _queryProcessImageName(recordedPid);
      if (image == null) return 0; // 进程已不在，pid 记录不过是残留文件
      if (!_looksLikeInferenceProcess(image, recordedExe)) return 0;

      Process.killPid(recordedPid, ProcessSignal.sigterm);
      for (int i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (await _queryProcessImageName(recordedPid) == null) return 1;
      }
      Process.killPid(recordedPid, ProcessSignal.sigkill);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return await _queryProcessImageName(recordedPid) == null ? 1 : 0;
    } on Object {
      return 0;
    }
  }

  /// 查询进程镜像名（进程不存在时返回 null）。
  static Future<String?> _queryProcessImageName(int pid) async {
    try {
      if (Platform.isWindows) {
        final ProcessResult r = await Process.run(
          'tasklist',
          <String>['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH'],
        );
        final String out = '${r.stdout}'.trim();
        if (out.isEmpty) return null;
        // CSV 首列即镜像名：`"llama-server.exe","1234","Console",...`
        final RegExpMatch? m = RegExp(r'^"([^"]+)"').firstMatch(out);
        return m?.group(1)?.toLowerCase();
      }
      final ProcessResult r =
          await Process.run('ps', <String>['-p', '$pid', '-o', 'comm=']);
      final String out = '${r.stdout}'.trim().toLowerCase();
      return out.isEmpty ? null : out.split('\n').first.trim();
    } on Object {
      return null;
    }
  }

  /// 镜像名是否属于我们的推理服务（避免误杀 pid 被回收后的无关进程）。
  static bool _looksLikeInferenceProcess(String image, String recordedExe) {
    final String name = image.toLowerCase();
    final String exe = recordedExe
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase()
        .trim();
    if (exe.isNotEmpty && name == exe) return true;
    return name.contains('llama') || name.contains('rwkv');
  }

  static Future<void> _writePidRecord(int pid, String executable) async {
    try {
      await File(pidRecordPath).writeAsString(jsonEncode(<String, Object?>{
        'pid': pid,
        'exe': executable,
        'at': DateTime.now().toIso8601String(),
      }));
    } on Object {
      // 记录失败不影响推理：只是失去"下次启动回收"的能力
    }
  }

  static Future<void> _clearPidRecord(int pid) async {
    try {
      final File f = File(pidRecordPath);
      if (!f.existsSync()) return;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is Map && (decoded['pid'] as num?)?.toInt() != pid) {
        return; // 已被新进程覆盖，别误删
      }
      await f.delete();
    } on Object {
      // 忽略
    }
  }
}