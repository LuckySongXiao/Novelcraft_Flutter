// `rwkv_lightning_cuda` 的启动参数（P4-25）。
//
// 为什么要单独一个数据类：它与 llama.cpp 的 CLI **毫无重叠**，混在一处极易出错。
// 抽出来之后 ①参数可单测（`toArgs()` 纯函数）②调用点只关心语义字段
// ③文档里每条 flag 的坑都能就近写在字段注释上。
//
// 官方 CLI 参考（`docs/run.zh-CN.md`）：
// ```
// rwkv_lighting_cuda \
//   --model-path <model.pth | 目录>   [--enable-dynamic-loading] \
//   --vocab-path <rwkv_vocab_v20230424.txt> \
//   --host 127.0.0.1 --port <p> \
//   --chunk-size 128 --chunk-load \
//   [--state-db-path <a.db>] [--tune-cache <f>] [--password <pwd>]
// ```
//
// ⚠ 三个致命差异（PITFALLS §27.1 / §30.8）：
//   1. 权重是 **`.pth` / `.rwkvq`**，**不是** llama.cpp 的 `.gguf` ——
//      两种格式的 tensor 排布与序列化完全不兼容，传错必秒退。
//   2. 词表**外置且强制**：不传 `--vocab-path` 直接 startup crash
//      （llama.cpp 的 GGUF 是把词表内嵌在权重文件里的）。
//   3. 可执行文件名是 `rwkv_lighting_cuda`（**上游把 lightning 拼成了 lighting**）。
library;

/// rwkv_lightning_cuda 的启动参数。
class RwkvLightningLaunchArgs {
  /// 权重路径：**`.pth` 或 `.rwkvq` 文件**，或（配合 [enableDynamicModelLoading]）
  /// 一个**目录** —— 目录下顶层所有 `.pth`/`.rwkvq` 会成为可加载模型。
  final String modelPath;

  /// 外置词表路径（`rwkv_vocab_v20230424.txt`，实测 1.07MB）。
  /// **必填**，缺失必 crash。
  final String vocabPath;

  final String host;
  final int port;

  /// prefill 分块大小（官方默认 128）。
  ///
  /// ⚠ 别和请求体里的 `chunk_size` 搞混：那个是**流式输出刷新粒度**，
  /// 这个是 **prefill 分块**，只在本进程启动时生效。
  final int chunkSize;

  /// 开 `--chunk-load`：用常驻模型文件流 + 两块可复用 32MiB pinned 缓冲，
  /// 让磁盘读、CUDA 拷贝、预处理三者重叠；**避免把整份 `.pth` 一次性读进主机内存**
  /// （7.2B 的 `.pth` 有 13.7GB，不开这个很容易 OOM）。强烈建议保持 `true`。
  final bool chunkLoad;

  /// 会话 state 的 SQLite 路径。
  ///
  /// ⚠ **必须显式指定**：省略时默认落在**进程当前工作目录**，
  /// 而 Flutter 应用的 CWD 不可预期（可能是安装目录、也可能被系统改掉），
  /// 会导致卸载重装丢 state。
  final String? stateDbPath;

  /// W8A16 调优缓存路径；默认与 [stateDbPath] 同目录，部署时建议放一起。
  final String? tuneCachePath;

  /// 服务端口令；空 = 不鉴权。
  final String? password;

  /// 允许 `--model-path` 指向目录并在运行时切换模型。
  ///
  /// ⚠ 代价：动态加载模式**只注册** `/v1/models`、`/v1/model/load`、
  /// `/v1/tokens/count`、`/v1/chat/completions`、`/v1/batch/completions`、
  /// `/v1/server/status` —— 其余路由（`/translate/*`、`/state/*`、
  /// stop/pause/resume）**全部失效**（PITFALLS §31.6）。
  final bool enableDynamicModelLoading;

  /// `--wkv32`（官方默认 false）。除非明确知道要 32 位 WKV 累加，别开。
  final bool wkv32;

  const RwkvLightningLaunchArgs({
    required this.modelPath,
    required this.vocabPath,
    this.host = '127.0.0.1',
    this.port = 8000,
    this.chunkSize = 128,
    this.chunkLoad = true,
    this.stateDbPath,
    this.tuneCachePath,
    this.password,
    this.enableDynamicModelLoading = false,
    this.wkv32 = false,
  });

  /// 组装成命令行参数（纯函数，可单测）。
  List<String> toArgs() => <String>[
        // ⚠ 是 `--model-path` 不是 llama.cpp 的 `--model`
        '--model-path', modelPath,
        if (enableDynamicModelLoading) '--enable-dynamic-loading',
        // ⚠ 外置词表，缺失即 crash
        '--vocab-path', vocabPath,
        '--host', host,
        '--port', '$port',
        '--chunk-size', '$chunkSize',
        if (chunkLoad) '--chunk-load',
        if (stateDbPath != null && stateDbPath!.isNotEmpty)
          ...<String>['--state-db-path', stateDbPath!],
        if (tuneCachePath != null && tuneCachePath!.isNotEmpty)
          ...<String>['--tune-cache', tuneCachePath!],
        if (password != null && password!.isNotEmpty)
          ...<String>['--password', password!],
        if (wkv32) '--wkv32',
      ];

  /// 供 UI 展示（**不要**把 password 打进去）。
  String describeRedacted() => toArgs()
      .map((String a) => a.replaceAll(RegExp(r'\.pth$|\.rwkvq$'), '…'))
      .join(' ');

  RwkvLightningLaunchArgs copyWith({
    String? modelPath,
    String? vocabPath,
    String? host,
    int? port,
    int? chunkSize,
    bool? chunkLoad,
    String? stateDbPath,
    String? tuneCachePath,
    String? password,
    bool? enableDynamicModelLoading,
    bool? wkv32,
  }) =>
      RwkvLightningLaunchArgs(
        modelPath: modelPath ?? this.modelPath,
        vocabPath: vocabPath ?? this.vocabPath,
        host: host ?? this.host,
        port: port ?? this.port,
        chunkSize: chunkSize ?? this.chunkSize,
        chunkLoad: chunkLoad ?? this.chunkLoad,
        stateDbPath: stateDbPath ?? this.stateDbPath,
        tuneCachePath: tuneCachePath ?? this.tuneCachePath,
        password: password ?? this.password,
        enableDynamicModelLoading:
            enableDynamicModelLoading ?? this.enableDynamicModelLoading,
        wkv32: wkv32 ?? this.wkv32,
      );
}

/// 启动前的**硬校验**结果。
class RwkvLightningPreflight {
  final bool ok;

  /// 失败原因（已带可操作提示）
  final String? message;

  const RwkvLightningPreflight._(this.ok, this.message);

  static const RwkvLightningPreflight pass =
      RwkvLightningPreflight._(true, null);

  static RwkvLightningPreflight fail(String message) =>
      RwkvLightningPreflight._(false, message);
}

/// 启动前的硬校验（PITFALLS §27.1 的两条秒退原因）。
///
/// [isDirectory] / [vocabSizeBytes] 由调用方探测后传入（本文件保持纯 Dart，
/// 不 import `dart:io`，否则 Web 端编译不过）。
RwkvLightningPreflight preflightLightningArgs(
  RwkvLightningLaunchArgs args, {
  required bool isDirectory,
  required int? vocabSizeBytes,
  required int? modelSizeBytes,
}) {
  final String mp = args.modelPath.trim();
  if (mp.isEmpty) {
    return RwkvLightningPreflight.fail('未指定权重路径。');
  }
  // ① GGUF 混入 —— 最常见的错
  if (mp.toLowerCase().endsWith('.gguf')) {
    return RwkvLightningPreflight.fail(
      '格式不匹配：rwkv_lightning_cuda 只接受 .pth / .rwkvq，'
      '当前传的是 GGUF（llama.cpp 格式）。两种格式的 tensor 排布与序列化完全不兼容。'
      '请改选「下载 .pth 原生权重」，或改走 llama.cpp 路线。（PITFALLS §27.1）',
    );
  }
  if (isDirectory && !args.enableDynamicModelLoading) {
    return RwkvLightningPreflight.fail(
      '权重路径是目录，但未开启动态加载。请在启动参数里加 '
      '--enable-dynamic-loading，否则引擎会把目录当成单个权重文件。',
    );
  }
  if (!isDirectory && !mp.toLowerCase().endsWith('.pth') &&
      !mp.toLowerCase().endsWith('.rwkvq')) {
    return RwkvLightningPreflight.fail(
      '权重后缀既不是 .pth 也不是 .rwkvq（当前：$mp）。'
      'rwkv_lightning_cuda 不支持其它格式。',
    );
  }
  // ② 外置词表缺失/损坏
  const int minVocab = 500 * 1024; // 实测 1.07MB，<500KB 视为损坏
  final String vp = args.vocabPath.trim();
  if (vp.isEmpty) {
    return RwkvLightningPreflight.fail(
      '未指定外置词表 --vocab-path。引擎**不内嵌词表**，缺它直接 crash '
      '（UI 侧只会看到连接被拒，极难定位）。（PITFALLS §27.1）',
    );
  }
  if (vocabSizeBytes == null) {
    return RwkvLightningPreflight.fail(
      '外置词表不存在：$vp。请点「安装内置引擎 + 词表」自动下载，'
      '或手动把仓库 assets/rwkv_vocab_v20230424.txt 放到该路径。',
    );
  }
  if (vocabSizeBytes < minVocab) {
    return RwkvLightningPreflight.fail(
      '外置词表损坏：$vp 只有 $vocabSizeBytes 字节（应 ≥ ${minVocab ~/ 1024}KB）。'
      '请重新下载。',
    );
  }
  if (modelSizeBytes != null && modelSizeBytes <= 0) {
    return RwkvLightningPreflight.fail('权重文件为空：$mp');
  }
  return RwkvLightningPreflight.pass;
}
