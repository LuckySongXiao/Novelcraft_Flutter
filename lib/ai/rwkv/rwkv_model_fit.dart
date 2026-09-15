// 模型 ↔ 显存的适配判定。
//
// 纯 Dart、零平台依赖 ⇒ 可用 `dart run tool/verify_model_fit.dart` 真跑验证。
//
// 为什么需要：模型选择器里 12 个 `.pth` 从 0.4GB 到 24.7GB 一字排开，
// 而 **RTX 3070 Ti 只有 8GB** —— 7.2B 那个要 13.4GB，是当前云端在用的型号，
// 也是最容易被顺手点下去的那个。不判适配就会变成
// **"下载 10 分钟、启动失败 1 秒"** 的挫败路径。
//
// 估算依据来自官方文档 §11（服务端的显存估算口径）：
//   "估算包含 recurrent state、按 --chunk-size 计算的 prefill 激活、logits、
//    128 MiB cuBLASLt workspace，并保留 max(512 MiB, free VRAM 的 10%) 安全空间"
//   ⇒ 权重之外还要留 状态 + 激活 + logits + workspace + 安全空间。
//   实测（云端 7.2B 已加载时）：total 23.5GB / free 9.8GB，
//   即 13.4GB 权重之外仍有可观的常驻开销与预留。
//
// 这里取一个**简单可解释**的近似：`权重 × 1.15 + 1GiB`。
// 它不追求 μs 级精确，只要能可靠地把"明显放不下"挡在下载之前。
library;

/// 模型相对某张 GPU 的适配判定。
enum RwkvModelFit {
  /// 余量充足，推荐
  fits,

  /// 能跑但余量很薄（其他进程抢显存 / 长上下文时可能 OOM）
  tight,

  /// 放不下
  tooLarge,

  /// 不知道（探不到 GPU）—— 此时**不做任何拦截**，只显示体积让用户自己判断
  unknown,
}

extension RwkvModelFitX on RwkvModelFit {
  /// 是否至少"能跑"。
  bool get isUsable => this == RwkvModelFit.fits || this == RwkvModelFit.tight;

  /// 是否应当**阻止**下载（放不下）。
  bool get shouldBlock => this == RwkvModelFit.tooLarge;
}

/// 运行该权重所需的显存估算（字节）。
int estimateRequiredVramBytes(int weightsBytes) {
  if (weightsBytes <= 0) return 0;
  const int gib = 1024 * 1024 * 1024;
  return (weightsBytes * 1.15).round() + gib;
}

/// 判定模型是否适配给定显存。
///
/// ⚠ **应当传「空闲」显存，而不是总显存。** 实测本机（RTX 3070 Ti Laptop）：
/// 总 8.0GB 但空闲只有 6.6GB —— 桌面/浏览器已经吃掉 1.4GB。
/// 用总量判定会把一个实际加载不进去的模型标成"可用"，
/// 而用户看到的是"下载 10 分钟、启动 OOM"。
/// 若只拿得到总量，也能用，但结果偏乐观（调用方可据此降一档阈值）。
///
/// [vramAvailableBytes] 为 null / ≤0 时返回 [RwkvModelFit.unknown]
/// —— **绝不能当成"显存为 0"**，否则会把所有模型都标成放不下。
RwkvModelFit judgeModelFit({
  required int modelSizeBytes,
  required int? vramAvailableBytes,
}) {
  if (modelSizeBytes <= 0) return RwkvModelFit.unknown;
  final int? avail = vramAvailableBytes;
  if (avail == null || avail <= 0) return RwkvModelFit.unknown;

  final int need = estimateRequiredVramBytes(modelSizeBytes);
  // 留 15% 余量才算"舒适"：显存不是独占的，推理过程本身还会有峰值
  if (need <= avail * 0.85) return RwkvModelFit.fits;
  if (need <= avail) return RwkvModelFit.tight;
  return RwkvModelFit.tooLarge;
}

/// 从模型名里解析「参数规模等级」（用于排序，**不是**用文件体积排序）。
///
/// ⚠ 为什么必须按参数量而不是体积排序：真实清单里
/// `rwkv7b-g1b-0.1b-20250822-ctx4096` 只有 0.1B 却有 **3.4GB**
/// （另一套架构变体），而 `rwkv7-g1j-2.9b` 是 **2.9B / 5.5GB**。
/// 按体积挑会挑到前者 —— **明显的降智选择**。
///
/// 返回值为「参数量的 10 倍整数」：`0.1b`→1, `1.5b`→15, `2.9b`→29,
/// `7.2b`→72, `13.3b`→133；解析不到返回 -1。
int parseParamRankFromName(String name) {
  // ⚠ 必须用**边界**匹配 `-<num>b-`，不能只写 `(\d+)b`：
  //   `rwkv7b-g1b-0.1b-...` 里家族前缀 `rwkv7b` 会被 `(\d+)b` 先命中，
  //   得到 7 → rank 70，**反而压过真正的 2.9B（rank 29）**，
  //   于是"按参数量挑"退化成"挑到那个 0.1B 的架构变体"。
  //   要求前后都是 `-`（或结尾）才能命中真正的参数段。
  final RegExpMatch? m = RegExp(r'[-_](\d+(?:\.\d+)?)b(?=[-_]|$)',
          caseSensitive: false)
      .firstMatch(name);
  if (m == null) return -1;
  final double? v = double.tryParse(m.group(1)!);
  if (v == null) return -1;
  return (v * 10).round();
}

/// 给 UI 用的一行结论（含数字，避免用户自己换算）。
///
/// 示例：`需要约 4.2GB 显存 · 本机 8.0GB → 可用`
String describeModelFit({
  required int modelSizeBytes,
  required int? vramAvailableBytes,
}) {
  const int gib = 1024 * 1024 * 1024;
  final double needGb = estimateRequiredVramBytes(modelSizeBytes) / gib;
  final RwkvModelFit fit = judgeModelFit(
      modelSizeBytes: modelSizeBytes, vramAvailableBytes: vramAvailableBytes);
  final String needTxt = '需要约 ${needGb.toStringAsFixed(1)}GB 显存';
  switch (fit) {
    case RwkvModelFit.unknown:
      return '权重 ${(modelSizeBytes / gib).toStringAsFixed(1)}GB'
          '（未探测到显卡显存，请自行确认能否加载）';
    case RwkvModelFit.fits:
      return '$needTxt · 本机空闲 ${(vramAvailableBytes! / gib).toStringAsFixed(1)}GB → 可用';
    case RwkvModelFit.tight:
      return '$needTxt · 本机空闲 ${(vramAvailableBytes! / gib).toStringAsFixed(1)}GB '
          '→ 余量很薄，长上下文可能显存不足';
    case RwkvModelFit.tooLarge:
      return '$needTxt · 本机空闲 ${(vramAvailableBytes! / gib).toStringAsFixed(1)}GB '
          '→ **放不下**（建议改选更小的模型，或改用云端/llama.cpp 路线）';
  }
}

/// 在候选里挑**最适合本机**的那个。
///
/// 选择规则（按优先级）：
///   1. 在 `fits` 里挑**参数规模最大**的 —— 显存够就上大模型，能力优先；
///   2. 没有 fits 就退到 `tight` 里挑参数规模最大的（勉强能跑的最大能力）；
///   3. 都没有 → null。
///
/// ⚠ **按参数量排序，不是按文件体积**（见 [parseParamRankFromName] 的说明：
///   0.1B 的变体反而比 2.9B 的文件更大）。
///   若没提供 [rankOf]，才退化为按体积排序。
T? pickBestFittingModel<T>(
  List<T> candidates, {
  required int Function(T) sizeOf,
  int Function(T)? rankOf,
  required int? vramAvailableBytes,
}) {
  if (candidates.isEmpty) return null;

  int rank(T c) => rankOf?.call(c) ?? sizeOf(c);

  T? bestIn(RwkvModelFit want) {
    T? best;
    int bestRank = -1;
    for (final T c in candidates) {
      final RwkvModelFit f = judgeModelFit(
          modelSizeBytes: sizeOf(c), vramAvailableBytes: vramAvailableBytes);
      if (f != want) continue;
      final int r = rank(c);
      if (r > bestRank) {
        bestRank = r;
        best = c;
      }
    }
    return best;
  }

  return bestIn(RwkvModelFit.fits) ?? bestIn(RwkvModelFit.tight);
}
