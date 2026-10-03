// 章节写作并发计算 —— 由「分卷数 × 每卷章节数 + 目标预留团队数 + 档位」
// 自动算出同步写作所需的并发（= 并行章节团队数，每队 1 组长 + 9 写手）。
//
// 两个档位：
//   * 高速模式（turbo）：全部章节同时开工 —— 并发 = 总章节数，不设团队上限
//     （仅受服务层绝对上限 9999 收口）；
//   * 普通模式（normal）：并发 = min(总章节数, 目标预留团队数)，
//     且硬上限 100 个团队（防 CF 429 / 推理端点过载）。
//
// 纯 Dart，便于单测（formula 变化频繁且容易算错）。
library;

/// 并发档位。
enum MultiAgentSpeedMode {
  /// 普通：min(总章节数, 预留团队数)，硬上限 100。
  normal,

  /// 高速：全部章节同时开工，并发 = 总章节数（不设团队上限）。
  turbo,
}

/// 并发计算（纯函数集合）。
class ConcurrencyPlanner {
  const ConcurrencyPlanner._();

  /// 普通模式的硬上限（团队数）。
  static const int kNormalModeMaxTeams = 100;

  /// 服务层绝对上限（与 MultiAgentBookConfig.normalize 对齐）。
  static const int kAbsoluteMaxTeams = 9999;

  /// 总章节数 = 分卷数 × 每卷章节数。
  static int totalChapters(int volumes, int chaptersPerVolume) {
    final int v = volumes < 0 ? 0 : volumes;
    final int c = chaptersPerVolume < 0 ? 0 : chaptersPerVolume;
    return v * c;
  }

  /// 计算并发（= 并行章节团队数）。
  ///
  /// [reservedTeams] 为目标预留团队数，仅在普通模式生效（<=0 表示不限制，
  /// 由 100 的硬上限兜底）。
  static int compute({
    required int volumes,
    required int chaptersPerVolume,
    required int reservedTeams,
    MultiAgentSpeedMode mode = MultiAgentSpeedMode.normal,
  }) {
    final int total = totalChapters(volumes, chaptersPerVolume);
    if (total <= 0) return 1;
    if (mode == MultiAgentSpeedMode.turbo) {
      return total > kAbsoluteMaxTeams ? kAbsoluteMaxTeams : total;
    }
    int n = total;
    if (reservedTeams > 0 && reservedTeams < n) n = reservedTeams;
    return n > kNormalModeMaxTeams ? kNormalModeMaxTeams : n;
  }

  /// 人类可读的计算说明（UI 展示公式与结果）。
  static String describe({
    required int volumes,
    required int chaptersPerVolume,
    required int reservedTeams,
    required MultiAgentSpeedMode mode,
  }) {
    final int total = totalChapters(volumes, chaptersPerVolume);
    final int n = compute(
      volumes: volumes,
      chaptersPerVolume: chaptersPerVolume,
      reservedTeams: reservedTeams,
      mode: mode,
    );
    final String rule = mode == MultiAgentSpeedMode.turbo
        ? '高速模式：并发 = 全部分卷章节数 $total（无团队上限）'
        : '普通模式：并发 = min(总章节数 $total, 预留团队 ${reservedTeams <= 0 ? '不限' : reservedTeams})，硬上限 $kNormalModeMaxTeams';
    return '$rule → 并发 $n（$n 个章节团队并行写 $n 章）';
  }
}
