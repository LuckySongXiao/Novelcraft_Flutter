export 'rwkv_official_resources_stub.dart'
    if (dart.library.io) 'rwkv_official_resources_native.dart'
    if (dart.library.html) 'rwkv_official_resources_web.dart';

enum OfficialServerVariant {
  cpu,
  vulkan,
  cuda12,
  cuda13,
  hip,
  sycl,
  arm64,
}

extension OfficialServerVariantX on OfficialServerVariant {
  String get assetToken {
    switch (this) {
      case OfficialServerVariant.cpu:
        return 'cpu';
      case OfficialServerVariant.vulkan:
        return 'vulkan';
      case OfficialServerVariant.cuda12:
        return 'cuda-12';
      case OfficialServerVariant.cuda13:
        return 'cuda-13';
      case OfficialServerVariant.hip:
        return 'rocm';
      case OfficialServerVariant.sycl:
        return 'sycl';
      case OfficialServerVariant.arm64:
        return 'cpu-arm64';
    }
  }

  String get archToken {
    switch (this) {
      case OfficialServerVariant.arm64:
        return 'arm64';
      case OfficialServerVariant.cpu:
      case OfficialServerVariant.vulkan:
      case OfficialServerVariant.cuda12:
      case OfficialServerVariant.cuda13:
      case OfficialServerVariant.hip:
      case OfficialServerVariant.sycl:
        return 'x64';
    }
  }

  String get displayName {
    switch (this) {
      case OfficialServerVariant.cpu:
        return 'CPU 通用版';
      case OfficialServerVariant.vulkan:
        return 'Vulkan (任意 GPU，推荐)';
      case OfficialServerVariant.cuda12:
        return 'NVIDIA CUDA 12.x';
      case OfficialServerVariant.cuda13:
        return 'NVIDIA CUDA 13.x';
      case OfficialServerVariant.hip:
        return 'AMD ROCm';
      case OfficialServerVariant.sycl:
        return 'Intel SYCL Arc';
      case OfficialServerVariant.arm64:
        return 'Windows ARM64';
    }
  }
}

class RwkvServerBuildInfo {
  final String repo;
  final String tag;
  final OfficialServerVariant variant;
  final String assetName;
  final String downloadUrl;
  final int sizeBytes;
  final String? browserDownloadUrl;

  const RwkvServerBuildInfo({
    required this.repo,
    required this.tag,
    required this.variant,
    required this.assetName,
    required this.downloadUrl,
    required this.sizeBytes,
    this.browserDownloadUrl,
  });

  RwkvServerBuildInfo copyWith({
    String? repo,
    String? tag,
    OfficialServerVariant? variant,
    String? assetName,
    String? downloadUrl,
    int? sizeBytes,
    String? browserDownloadUrl,
  }) =>
      RwkvServerBuildInfo(
        repo: repo ?? this.repo,
        tag: tag ?? this.tag,
        variant: variant ?? this.variant,
        assetName: assetName ?? this.assetName,
        downloadUrl: downloadUrl ?? this.downloadUrl,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        browserDownloadUrl: browserDownloadUrl ?? this.browserDownloadUrl,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'repo': repo,
        'tag': tag,
        'variant': variant.name,
        'assetName': assetName,
        'downloadUrl': downloadUrl,
        'sizeBytes': sizeBytes,
        'browserDownloadUrl': browserDownloadUrl,
      };

  factory RwkvServerBuildInfo.fromJson(Map<String, Object?> map) =>
      RwkvServerBuildInfo(
        repo: map['repo'] as String,
        tag: map['tag'] as String,
        variant: OfficialServerVariant.values.byName(map['variant'] as String),
        assetName: map['assetName'] as String,
        downloadUrl: map['downloadUrl'] as String,
        sizeBytes: (map['sizeBytes'] as num).toInt(),
        browserDownloadUrl: map['browserDownloadUrl'] as String?,
      );
}

enum RwkvDownloadPhase {
  idle,
  fetchingMeta,
  downloading,
  verifying,
  extracting,
  installing,
  done,
  failed,
  cancelled,
}

extension RwkvDownloadPhaseX on RwkvDownloadPhase {
  String get label {
    switch (this) {
      case RwkvDownloadPhase.idle:
        return '准备中';
      case RwkvDownloadPhase.fetchingMeta:
        return '查询官方资源';
      case RwkvDownloadPhase.downloading:
        return '正在下载';
      case RwkvDownloadPhase.verifying:
        return '校验数据';
      case RwkvDownloadPhase.extracting:
        return '正在解压';
      case RwkvDownloadPhase.installing:
        return '安装中';
      case RwkvDownloadPhase.done:
        return '完成';
      case RwkvDownloadPhase.failed:
        return '失败';
      case RwkvDownloadPhase.cancelled:
        return '已取消';
    }
  }

  bool get isTerminal =>
      this == RwkvDownloadPhase.done ||
      this == RwkvDownloadPhase.failed ||
      this == RwkvDownloadPhase.cancelled;
}

class RwkvDownloadProgress {
  final RwkvDownloadPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final double speedMbps;
  final int etaSeconds;
  final String? message;
  final Object? error;
  final StackTrace? stackTrace;

  const RwkvDownloadProgress({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedMbps = 0,
    this.etaSeconds = 0,
    this.message,
    this.error,
    this.stackTrace,
  });

  bool get isTerminal => phase.isTerminal;

  double get fractionComplete {
    if (totalBytes <= 0) return 0;
    if (receivedBytes >= totalBytes) return 1;
    return receivedBytes / totalBytes;
  }

  RwkvDownloadProgress copyWith({
    RwkvDownloadPhase? phase,
    int? receivedBytes,
    int? totalBytes,
    double? speedMbps,
    int? etaSeconds,
    String? message,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      RwkvDownloadProgress(
        phase: phase ?? this.phase,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        speedMbps: speedMbps ?? this.speedMbps,
        etaSeconds: etaSeconds ?? this.etaSeconds,
        message: message ?? this.message,
        error: error ?? this.error,
        stackTrace: stackTrace ?? this.stackTrace,
      );
}

enum RwkvModelQuant {
  fp16,
  bf16,
  q80,
  q6K,
  q5KM,
  q4KM,
  q3KM,
  q2K,
  unknown,
}

extension RwkvModelQuantX on RwkvModelQuant {
  String get canonicalToken {
    switch (this) {
      case RwkvModelQuant.fp16:
        return 'fp16';
      case RwkvModelQuant.bf16:
        return 'bf16';
      case RwkvModelQuant.q80:
        return 'q8_0';
      case RwkvModelQuant.q6K:
        return 'q6_k';
      case RwkvModelQuant.q5KM:
        return 'q5_k_m';
      case RwkvModelQuant.q4KM:
        return 'q4_k_m';
      case RwkvModelQuant.q3KM:
        return 'q3_k_m';
      case RwkvModelQuant.q2K:
        return 'q2_k';
      case RwkvModelQuant.unknown:
        return 'unknown';
    }
  }

  String get displayLabel {
    switch (this) {
      case RwkvModelQuant.fp16:
        return 'FP16 (原生无损，~13 GB)';
      case RwkvModelQuant.bf16:
        return 'BF16 (原生无损，~13 GB)';
      case RwkvModelQuant.q80:
        return 'Q8_0 (接近无损，~8 GB)';
      case RwkvModelQuant.q6K:
        return 'Q6_K (高画质，~5 GB)';
      case RwkvModelQuant.q5KM:
        return 'Q5_K_M (均衡画质，~4.3 GB)';
      case RwkvModelQuant.q4KM:
        return 'Q4_K_M (均衡速度，~3.6 GB)';
      case RwkvModelQuant.q3KM:
        return 'Q3_K_M (低显存，~2.8 GB)';
      case RwkvModelQuant.q2K:
        return 'Q2_K (极致压缩，~2 GB)';
      case RwkvModelQuant.unknown:
        return '未知量化';
    }
  }

  static RwkvModelQuant fromFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.contains('fp16')) return RwkvModelQuant.fp16;
    if (lower.contains('bf16')) return RwkvModelQuant.bf16;
    if (lower.contains('q8_0')) return RwkvModelQuant.q80;
    if (lower.contains('q6_k')) return RwkvModelQuant.q6K;
    if (lower.contains('q5_k_m')) return RwkvModelQuant.q5KM;
    if (lower.contains('q4_k_m')) return RwkvModelQuant.q4KM;
    if (lower.contains('q3_k_m')) return RwkvModelQuant.q3KM;
    if (lower.contains('q2_k')) return RwkvModelQuant.q2K;
    return RwkvModelQuant.unknown;
  }
}

class RwkvOfficialModel {
  final String id;
  final String displayName;
  final String repo;
  final String subFolder;
  final String fileName;
  final String? revision;
  final String downloadUrl;
  final int sizeBytes;
  final RwkvModelQuant quant;
  final String paramsLabel;

  const RwkvOfficialModel({
    required this.id,
    required this.displayName,
    required this.repo,
    required this.subFolder,
    required this.fileName,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.quant,
    required this.paramsLabel,
    this.revision,
  });

  String get qualifiedRemotePath =>
      subFolder.isEmpty ? fileName : '$subFolder/$fileName';

  String get sizeHumanReadable {
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var size = sizeBytes.toDouble();
    var idx = 0;
    while (size >= 1024 && idx < units.length - 1) {
      size /= 1024;
      idx += 1;
    }
    return '${size.toStringAsFixed(2)} ${units[idx]}';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'displayName': displayName,
        'repo': repo,
        'subFolder': subFolder,
        'fileName': fileName,
        'revision': revision,
        'downloadUrl': downloadUrl,
        'sizeBytes': sizeBytes,
        'quant': quant.canonicalToken,
        'paramsLabel': paramsLabel,
      };

  factory RwkvOfficialModel.fromJson(Map<String, Object?> map) {
    final rawQuant = map['quant'];
    RwkvModelQuant quant;
    if (rawQuant is String) {
      try {
        quant = RwkvModelQuant.values.byName(rawQuant);
      } on ArgumentError {
        quant = RwkvModelQuantX.fromFileName('x-$rawQuant-x');
      }
    } else {
      quant = RwkvModelQuant.unknown;
    }
    return RwkvOfficialModel(
      id: map['id'] as String,
      displayName: map['displayName'] as String,
      repo: map['repo'] as String,
      subFolder: (map['subFolder'] as String?) ?? '',
      fileName: map['fileName'] as String,
      revision: map['revision'] as String?,
      downloadUrl: map['downloadUrl'] as String,
      sizeBytes: (map['sizeBytes'] as num).toInt(),
      quant: quant,
      paramsLabel: map['paramsLabel'] as String,
    );
  }
}

// ---------------------------------------------------------------------------
// rwkv_lightning_cuda（albatross 引擎）—— 内置推理引擎
// ---------------------------------------------------------------------------

/// 官方仓库：预编译 CUDA 服务端发布在此
const String kRwkvLightningRepo = 'Alic-Li/rwkv_lightning_cuda';

/// RWKV7 **原生 `.pth`** 权重仓库。
///
/// ⚠ 引擎**只吃 `.pth` / `.rwkvq`，不吃 GGUF**（见 PITFALLS §27.1）。
/// `BlinkDL/rwkv7-g1` 下每个文件的下载地址形如：
/// `https://huggingface.co/BlinkDL/rwkv7-g1/resolve/main/<file>.pth`
const String kRwkvLightningWeightsRepo = 'BlinkDL/rwkv7-g1';

/// 引擎**强制外置**的词表文件名（版本号钉死，所有 RWKV7 模型共用同一份，约 2.5 MB）。
/// 与 llama.cpp/GGUF 把词表内嵌进权重文件完全不同 —— 漏传会秒退（PITFALLS §27.1）。
const String kRwkvVocabFileName = 'rwkv_vocab_v20230424.txt';

const String kRwkvVocabDownloadUrl =
    'https://raw.githubusercontent.com/Alic-Li/rwkv_lightning_cuda/main/assets/rwkv_vocab_v20230424.txt';

/// 引擎可执行文件名。
///
/// ⚠ 上游 CMake 目标名把 `lightning` 拼成了 `lighting`（少一个 n），
/// 打包出来的二进制就叫 `rwkv_lighting_cuda`。定位时可执行文件时两种拼写都要兜。
const String kRwkvLightningExeName = 'rwkv_lighting_cuda.exe';

/// `rwkv_lightning_cuda` 的一条官方 release 资产（Windows/Linux × CUDA 12.9/13.2）
class RwkvLightningRelease {
  /// 版本 tag，如 `v1.6.0`
  final String tag;

  /// 只支持 CUDA 12 / 13 两档预编译包
  final OfficialServerVariant variant;

  /// `windows-x64` / `linux-x64`
  final String platformToken;

  /// `cuda12.9` / `cuda13.2`
  final String cudaToken;

  final String assetName;
  final String downloadUrl;

  /// 同目录的 `.sha256` 校验文件（下载后校验，缺失则跳过校验并记录）
  final String sha256Url;
  final int sizeBytes;

  const RwkvLightningRelease({
    required this.tag,
    required this.variant,
    required this.platformToken,
    required this.cudaToken,
    required this.assetName,
    required this.downloadUrl,
    required this.sha256Url,
    required this.sizeBytes,
  });

  String get sizeHumanReadable {
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var size = sizeBytes.toDouble();
    var idx = 0;
    while (size >= 1024 && idx < units.length - 1) {
      size /= 1024;
      idx += 1;
    }
    return '${size.toStringAsFixed(1)} ${units[idx]}';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'tag': tag,
        'variant': variant.name,
        'platformToken': platformToken,
        'cudaToken': cudaToken,
        'assetName': assetName,
        'downloadUrl': downloadUrl,
        'sha256Url': sha256Url,
        'sizeBytes': sizeBytes,
      };

  factory RwkvLightningRelease.fromJson(Map<String, Object?> map) =>
      RwkvLightningRelease(
        tag: map['tag'] as String,
        variant: OfficialServerVariant.values.byName(map['variant'] as String),
        platformToken: map['platformToken'] as String,
        cudaToken: map['cudaToken'] as String,
        assetName: map['assetName'] as String,
        downloadUrl: map['downloadUrl'] as String,
        sha256Url: map['sha256Url'] as String,
        sizeBytes: (map['sizeBytes'] as num).toInt(),
      );
}

abstract class RwkvOfficialResourcesBridge {
  Future<RwkvServerBuildInfo> fetchLatestServerBuild({
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    String? repo,
    void Function(RwkvDownloadProgress)? onProgress,
  });

  Future<String> installLlamaServer({
    RwkvServerBuildInfo? buildInfo,
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  });

  Future<List<RwkvOfficialModel>> listOfficialRwkvModels({
    void Function(RwkvDownloadProgress)? onProgress,
  });

  Future<String> downloadOfficialModel(
    RwkvOfficialModel model, {
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  });

  // ---------- 内置推理引擎：rwkv_lightning_cuda ----------

  /// 查询官方最新 release 里本机可用的预编译包（下载 URL + `.sha256` URL）。
  Future<RwkvLightningRelease> fetchLatestLightningRelease({
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    String? repo,
    void Function(RwkvDownloadProgress)? onProgress,
  });

  /// 下载 → 校验 sha256 → 解压 → 定位可执行文件；返回 exe 绝对路径。
  Future<String> installLightningServer({
    RwkvLightningRelease? release,
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  });

  /// 确保外置词表 `rwkv_vocab_v20230424.txt` 就位；返回其绝对路径。
  Future<String> ensureLightningVocab({
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  });

  /// 列出可下载的官方 **`.pth`** 权重（引擎原生格式，非 GGUF）。
  Future<List<RwkvOfficialModel>> listLightningPthModels({
    void Function(RwkvDownloadProgress)? onProgress,
  });
}

/// 下载/安装任务的取消句柄：UI 拿到句柄后可随时调用 cancel()。
abstract class RwkvCancelHandle {
  bool get isCancelled;
  Future<void> cancel([String? reason]);
}

class RwkvDownloadCancelledException implements Exception {
  final String? message;
  const RwkvDownloadCancelledException([this.message]);

  @override
  String toString() =>
      message == null ? 'RwkvDownloadCancelled' : 'RwkvDownloadCancelled: $message';
}
