// 章节写作并发计算 —— 由「分卷数 × 每卷章节数 + 并行章节上限 + 档位」
// 自动算出同步写作所需的并发。
//
// 唯一写作工艺是「主笔分段串行」（WritingCraft.duo）：
//   * 单章内严格串行：章纲 → 2200 字/段的正文续写 → 润色定稿 → 设定抽取；
//   * 章与章之间零依赖：每章一条独立管线、一条独立 state 链，可并行；
//   * 因此「并发」的语义是**并行章节管线数**，也就是同时在途的生成请求数
//     （每章同一时刻只有 1 个请求在飞）。
//
// 两个档位：
//   * 高速模式（turbo）：全部章节同时开工 —— 并发 = 总章节数（仅受 9999 收口）；
//   * 普通模式（normal）：并发 = min(总章节数, 并行章节上限)，
//     上限填 0 时按模型规模自动取「最佳并发」（见 [recommendedParallelChapters]）。
//
// 纯 Dart，便于单测（formula 变化频繁且容易算错）。
library;

/// 并发档位。
enum MultiAgentSpeedMode {
  /// 普通：min(总章节数, 并行章节上限)；上限 0 = 按模型规模自动推荐。
  normal,

  /// 高速：全部章节同时开工，并发 = 总章节数（不设模型规模上限）。
  turbo,
}

/// 并发计算（纯函数集合）。
class ConcurrencyPlanner {
  const ConcurrencyPlanner._();

  /// 普通模式的硬上限（并行章节管线数）。
  ///
  /// 这是客户端安全阀，不是「最佳并发」；真正的最佳值由
  /// [recommendedParallelChapters] 给出。100 只用于防误填（0 以外的极端值）。
  static const int kNormalModeMaxPipelines = 100;

  /// 服务层绝对上限（与 MultiAgentBookConfig.normalize 对齐）。
  static const int kAbsoluteMaxPipelines = 9999;

  /// 解析不到模型参数量时的保守推荐值。
  static const int kFallbackRecommendedPipelines = 4;

  /// 总章节数 = 分卷数 × 每卷章节数。
  static int totalChapters(int volumes, int chaptersPerVolume) {
    final int v = volumes < 0 ? 0 : volumes;
    final int c = chaptersPerVolume < 0 ? 0 : chaptersPerVolume;
    return v * c;
  }

  /// 按模型参数量给出「单卡吞吐最佳」的并行章节管线数。
  ///
  /// 依据：串行管线的单段提示词约 2200 字（≈1500~2500 token），
  /// 在这类长上下文请求下，单卡聚合吞吐在 3B 模型约 6 条管线后进入平台期，
  /// 再提高并发只会增加单章延迟与超时概率，不提升整书墙钟时间。
  ///
  /// 档位（保守值，可在 UI 手动覆盖）：
  ///   * ≤1.6B → 8
  ///   * ≤3.5B → 6
  ///   * ≤8B   → 3
  ///   * ≤15B  → 2
  ///   * 更大   → 1
  /// 解析不到参数量（如自定义模型名）→ [kFallbackRecommendedPipelines]。
  static int recommendedParallelChapters(String modelName) {
    final RegExpMatch? m = RegExp(
      r'(\d+(?:\.\d+)?)\s*[bB](?![a-zA-Z0-9])',
    ).firstMatch(modelName);
    final double? paramsB = m == null ? null : double.tryParse(m.group(1)!);
    if (paramsB == null) return kFallbackRecommendedPipelines;
    if (paramsB <= 1.6) return 8;
    if (paramsB <= 3.5) return 6;
    if (paramsB <= 8.0) return 3;
    if (paramsB <= 15.0) return 2;
    return 1;
  }

  /// 计算并发（= 并行章节管线数）。
  ///
  /// [maxParallelChapters] 为并行章节上限，仅普通模式生效；
  /// `<=0` 表示按 [modelName] 自动取最佳并发。
  static int compute({
    required int volumes,
    required int chaptersPerVolume,
    required int maxParallelChapters,
    MultiAgentSpeedMode mode = MultiAgentSpeedMode.normal,
    String modelName = '',
  }) {
    final int total = totalChapters(volumes, chaptersPerVolume);
    if (total <= 0) return 1;
    if (mode == MultiAgentSpeedMode.turbo) {
      return total > kAbsoluteMaxPipelines ? kAbsoluteMaxPipelines : total;
    }
    final int cap = maxParallelChapters > 0
        ? maxParallelChapters
        : recommendedParallelChapters(modelName);
    final int n = total < cap ? total : cap;
    return n > kNormalModeMaxPipelines ? kNormalModeMaxPipelines : n;
  }

  /// 人类可读的计算说明（UI 展示公式与结果）。
  static String describe({
    required int volumes,
    required int chaptersPerVolume,
    required int maxParallelChapters,
    required MultiAgentSpeedMode mode,
    String modelName = '',
  }) {
    final int total = totalChapters(volumes, chaptersPerVolume);
    final int n = compute(
      volumes: volumes,
      chaptersPerVolume: chaptersPerVolume,
      maxParallelChapters: maxParallelChapters,
      mode: mode,
      modelName: modelName,
    );
    final String rule = mode == MultiAgentSpeedMode.turbo
        ? '高速模式：并发 = 全部章节 $total（每章 1 条串行管线）'
        : '普通模式：并发 = min(总章节数 $total, '
              '${maxParallelChapters > 0 ? '并行章节上限 $maxParallelChapters' : '自动推荐 ${recommendedParallelChapters(modelName)}（$modelName）'})，'
              '硬上限 $kNormalModeMaxPipelines';
    return '$rule → 并发 $n（$n 条章节管线并行，单章内严格串行）';
  }
}
