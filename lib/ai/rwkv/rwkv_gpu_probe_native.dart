// GPU 显存探测（Native 实现）—— 调 `nvidia-smi`。
//
// 为什么用 nvidia-smi 而不是 WMI / DXGI：
//  1. 它就是驱动自带的那份"权威答案"，和 CUDA 运行时看到的一致；
//  2. 输出格式极稳定（`name, memory.total, memory.free`），不用引额外依赖；
//  3. 进程 spawn 在本项目已有先例（`InferenceProcessLauncher`）。
//
// ⚠ 失败必须**区分"没有 N 卡"与"探测失败"**：两者都返回 null，
//   由调用方当作"不知道"处理（而不是"显存为 0"）。
//
// ⚠ 不 import Flutter：只依赖 `dart:io`，保持与 `rwkv_file_probe_native` 同构。
import 'dart:io';

import 'rwkv_gpu_probe.dart';

/// 探测超时：nvidia-smi 正常 <200ms；卡住说明驱动异常，别拖住 UI。
const Duration _kProbeTimeout = Duration(seconds: 4);

Future<List<RwkvGpuInfo>> rwkvProbeGpusImpl() async {
  if (!Platform.isWindows && !Platform.isLinux) return const <RwkvGpuInfo>[];
  try {
    final ProcessResult r = await Process.run(
      'nvidia-smi',
      <String>[
        '--query-gpu=name,memory.total,memory.free',
        '--format=csv,noheader,nounits',
      ],
      stdoutEncoding: SystemEncoding(),
      stderrEncoding: SystemEncoding(),
    ).timeout(_kProbeTimeout);
    if (r.exitCode != 0) return const <RwkvGpuInfo>[];
    return parseNvidiaSmiOutput('${r.stdout}');
  } on Object {
    // 没装 nvidia-smi / 没 N 卡 / 超时 —— 一律当"不知道"
    return const <RwkvGpuInfo>[];
  }
}

/// 解析 nvidia-smi 的 CSV 输出（**纯函数，可单测**）。
///
/// 期望每行：`NVIDIA GeForce RTX 3070 Ti Laptop GPU, 8192, 7150`
/// （nounits 模式，单位 MB）。容忍空行与多余空白。
List<RwkvGpuInfo> parseNvidiaSmiOutput(String raw) {
  const int mb = 1024 * 1024;
  final List<RwkvGpuInfo> out = <RwkvGpuInfo>[];
  for (final String line in raw.split('\n')) {
    final String t = line.trim();
    if (t.isEmpty) continue;
    final List<String> parts = t.split(',');
    if (parts.length < 3) continue;
    final int? total = int.tryParse(parts[1].trim());
    final int? free = int.tryParse(parts[2].trim());
    if (total == null || total <= 0) continue;
    out.add(RwkvGpuInfo(
      name: parts[0].trim(),
      totalBytes: total * mb,
      freeBytes: (free ?? 0) * mb,
    ));
  }
  return out;
}
