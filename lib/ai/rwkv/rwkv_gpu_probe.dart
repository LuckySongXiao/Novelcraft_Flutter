// GPU 显存探测（条件导入：Native 走 nvidia-smi，Web 走 stub）。
//
// 为什么需要它：模型选择器如果不显示显存适配，用户会下载 13.4GB 的
// `rwkv7-g1j-7.2b-*.pth` 然后启动失败 —— 而 RTX 3070 Ti 只有 8GB。
// 这是"下载 10 分钟、失败 1 秒"的典型挫败路径，必须在下载前拦住。
//
// ⚠ 本文件是条件导入的门面，**保持零平台依赖**；平台实现放
// `_native` / `_stub`（与 `rwkv_file_probe.dart` 同一模式）。
library;

import 'rwkv_gpu_probe_stub.dart'
    if (dart.library.io) 'rwkv_gpu_probe_native.dart' as impl;

/// 一张 GPU 的显存信息。
class RwkvGpuInfo {
  /// 显卡名（如 `NVIDIA GeForce RTX 3070 Ti Laptop GPU`）
  final String name;

  /// 总显存（字节）
  final int totalBytes;

  /// 当前空闲显存（字节）
  final int freeBytes;

  const RwkvGpuInfo({
    required this.name,
    required this.totalBytes,
    required this.freeBytes,
  });

  double get totalGb => totalBytes / (1024 * 1024 * 1024);
  double get freeGb => freeBytes / (1024 * 1024 * 1024);

  @override
  String toString() =>
      '$name · 总 ${totalGb.toStringAsFixed(1)}GB / 空闲 ${freeGb.toStringAsFixed(1)}GB';
}

/// 探测本机 NVIDIA GPU 显存。
///
/// 返回 null = 探不到（非 Windows / 无 N 卡 / 没装驱动 / 是 Web）。
/// **调用方必须把 null 当作"不知道"，而不是"没有显存"** —— 此时应关闭
/// 适配提示，而不是把所有模型标成放不下。
Future<List<RwkvGpuInfo>> rwkvProbeGpus() => impl.rwkvProbeGpusImpl();
