// 退化复读守卫 —— 「模型输出整段复读」的纯 Dart 检测器。
//
// 为什么需要它（+46，证据见 docs/交接-复读问题-外援接入指南.md）：
//
//   2026-10-11 用户真机实测：严格惩罚参数（strong 档 alpha_presence 3.0）下
//   大纲修订调用仍整段复读，且开头出现「本章目标：本章目标：」双层前缀；
//   这份复读内容穿过 `OutlineRepairText` 的全部清洗后，被兜底路径
//   （`cleanedRaw.length >= 20` 就当大纲用）**原样持久化进 chapters.notes**。
//
//   复读产生的原因在采样/服务端层面（另有文档专述），但**持久化层必须自保**：
//   无论上游多烂，复读内容都不该写进库 —— 否则坏大纲会像病毒一样在后续
//   每一次「按大纲重写」里传染（ChapterRewriteService 把 notes 原样喂给模型）。
//
// 三层检测（互相独立，命中任意一层即判退化）：
//   1. **字符级 n-gram 重复率**：归一化后滑窗取 n 字 shingle，重复 shingle 占比。
//      专治「同一句话循环输出」。正常中文散文 12 字 shingle 几乎不重复（<5%），
//      复读样本实测可达 70%+。
//   2. **连续重复行**：同一行（≥8 字）紧挨着出现 ≥2 次。专治「一行复读成墙」。
//   3. **段落级重复率**：与 `MultiAgentBookGenerationService._repeatRatio` 同口径
//      （1 - 去重段落/总段落，只统计 ≥12 字段落），专治「隔段复读」。
//
// 本文件**纯 Dart、零 import**，可直接用 dart 脚本直跑回归：
//   dart --disable-dart-dev tools/repetition_guard_selftest.dart
library;

abstract final class RepetitionGuard {
  /// n-gram 重复率判定的默认阈值。
  ///
  /// 取值依据：正常大纲/正文实测 0.00~0.08；复读样本（截图存档）>0.55。
  /// 0.30 留出足够安全边距，宁缺勿滥 —— 误杀一份正常大纲的代价（作者重点一次）
  /// 远小于放进一份复读大纲（污染后续所有重写）。
  static const double defaultThreshold = 0.30;

  /// 字符级 n-gram 重复率（[0,1]，越高越复读）。
  ///
  /// 归一化：剥全部空白与常见标点（复读样本常混入换行/空格打断 n-gram）。
  /// 文本有效长度不足 [n]*2 时返回 0（证据不足，不判）。
  static double charNgramRepeatRatio(String text, {int n = 12}) {
    final String s = _normalize(text);
    if (s.length < n * 2) return 0;
    final Set<String> seen = <String>{};
    int total = 0;
    int dup = 0;
    for (int i = 0; i + n <= s.length; i++) {
      total++;
      if (!seen.add(s.substring(i, i + n))) dup++;
    }
    return total == 0 ? 0 : dup / total;
  }

  /// 是否存在「同一行（≥[minLineLength] 字）紧挨着重复 ≥[minRuns] 次」。
  ///
  /// 只看**紧邻**行：隔段复读交给段落级检测，这里不越权（正常文本里
  /// 「副歌式」隔段呼应是文学手法，紧邻重复则几乎必然是退化）。
  static bool hasConsecutiveDuplicateLines(
    String text, {
    int minLineLength = 8,
    int minRuns = 2,
  }) {
    final List<String> lines = text
        .split(RegExp(r'\r?\n'))
        .map((String l) => _squash(l))
        .where((String l) => l.length >= minLineLength)
        .toList(growable: false);
    int run = 1;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i] == lines[i - 1]) {
        run++;
        if (run >= minRuns) return true;
      } else {
        run = 1;
      }
    }
    return false;
  }

  /// 段落级重复率（与 `MultiAgentBookGenerationService._repeatRatio` 同口径）。
  ///
  /// 独立实现（零 import 铁律）：1 - 去重段落 / 总段落，只统计 ≥12 字段落，
  /// 少于 4 段返回 0。
  static double paragraphRepeatRatio(String text) {
    final List<String> paras = text
        .split(RegExp(r'\n+'))
        .map((String p) => p.trim())
        .where((String p) => p.length >= 12)
        .toList(growable: false);
    if (paras.length < 4) return 0;
    final int uniq = paras.toSet().length;
    return 1 - uniq / paras.length;
  }

  /// 综合判定：这段文本是否属于「退化复读」，不该被当作可用产出。
  ///
  /// [minLength] 以下不判（太短的文本三条检测都没证据；短文本的清洗层
  /// 自有 ≥20 字门槛兜着）。[threshold] 为 n-gram 重复率阈值。
  static bool isDegenerate(
    String text, {
    int minLength = 60,
    double threshold = defaultThreshold,
  }) {
    final String t = text.trim();
    if (t.length < minLength) return false;
    if (hasConsecutiveDuplicateLines(t)) return true;
    if (charNgramRepeatRatio(t) > threshold) return true;
    if (paragraphRepeatRatio(t) > 0.5) return true;
    return false;
  }

  /// 面向日志/报错的诊断串（三条检测的数值一览）。
  static String diagnose(String text) =>
      'ngram=${charNgramRepeatRatio(text).toStringAsFixed(3)} '
      'para=${paragraphRepeatRatio(text).toStringAsFixed(3)} '
      'consecutiveLines=${hasConsecutiveDuplicateLines(text)}';

  /// 归一化：剥空白与中英文标点，保留实义字符（汉字/字母/数字）。
  ///
  /// 复读样本里常混着换行与空格（同一句被折行打断），不归一化就抓不住。
  static String _normalize(String text) => text
      .replaceAll(RegExp(r'[\s\u3000]+'), '')
      .replaceAll(
        RegExp(
          r'[，。、；：？！「」『』【】（）""'
          '…—·,.;:?!()\[\]{}<>"\x27-]',
        ),
        '',
      );

  /// 行内归一化：压空白但不剥标点（行级比较保留原始形态更稳）。
  static String _squash(String line) =>
      line.replaceAll(RegExp(r'\s+'), ' ').trim();
}
