// 正文**复读修复** —— 「逐章体检卡片」的纯规则层。
//
// 与 `repetition_guard.dart` 的分工：
//   * `RepetitionGuard` 负责**判定**（这段文本是不是退化复读）；
//   * 本文件负责**定位与修复**（退化从哪开始、截断后长什么样）。
//
// 为什么需要它（2026-10-12 用户真实库取证）：725 章里有 150+ 章正文是复读的
// （`421e4a69` 项目 ngram 高达 0.916）。这类稿子**不能自动整章重写**（成本高、
// 结果不可控），但绝大多数是「前半章健康 + 后半章陷入循环」——**在退化起点截断**
// 就能把一章救回来，且是有据可依的最小改动。
//
// 退化起点算法移植自整书生成链路的 `_degenerationOnset`（经 +18 实测修正：
// 必须找**连续的退化后缀**，而不是「第一个低窗口」，否则章中间一段对白就会
// 把后半章腰斩）。移植而非调用，是为了让本文件保持**纯 Dart、零依赖**，可离线自检：
//   dart --disable-dart-dev tools/repetition_repair_selftest.dart

import 'repetition_guard.dart';

/// 单章复读体检报告。
class RepetitionReport {
  const RepetitionReport({
    required this.degenerate,
    required this.ngram,
    required this.paragraph,
    required this.consecutiveLines,
    required this.onset,
    required this.length,
    required this.repaired,
    required this.preview,
  });

  /// 是否判为退化复读（`RepetitionGuard.isDegenerate`）。
  final bool degenerate;

  /// 字符级 12-gram 重复率。
  final double ngram;

  /// 段落级重复率。
  final double paragraph;

  /// 是否存在紧邻重复行。
  final bool consecutiveLines;

  /// 退化起点（字符下标）；**0 = 未检出可截断的退化后缀**。
  final int onset;

  /// 原文长度。
  final int length;

  /// 修复后的正文（截断到退化起点并清理）。
  ///
  /// 空串 = **无法靠截断救回**（整篇都在退化），调用方应引导「重写」而非采纳。
  final String repaired;

  /// 退化处上下文预览（`…前 60 字【⟵ 从这里开始复读】后 60 字…`），供 UI 展示。
  final String preview;

  /// 是否可通过截断修复（有退化后缀，且截断后仍有可观正文）。
  bool get canTruncate => repaired.isNotEmpty && onset > 0;

  /// 截断后保留的字符数。
  int get keepChars => repaired.length;

  /// 截断丢弃的字符数。
  int get dropChars => length - keepChars;
}

abstract final class RepetitionRepair {
  /// 截断后正文的**最小可接受长度**：太短的「修复稿」没有意义，不如整章重写。
  static const int kMinRepairedChars = 800;

  /// 体检单章正文。
  static RepetitionReport analyze(String content) {
    final String text = content;
    final bool degenerate = RepetitionGuard.isDegenerate(text);
    final int onset = degenerationOnset(text);

    String repaired = '';
    if (onset > 0) {
      final String candidate = cleanTruncated(text.substring(0, onset));
      if (candidate.length >= kMinRepairedChars) repaired = candidate;
    }

    return RepetitionReport(
      degenerate: degenerate,
      ngram: RepetitionGuard.charNgramRepeatRatio(text),
      paragraph: RepetitionGuard.paragraphRepeatRatio(text),
      consecutiveLines: RepetitionGuard.hasConsecutiveDuplicateLines(text),
      onset: onset,
      length: text.length,
      repaired: repaired,
      preview: _preview(text, onset),
    );
  }

  /// 直接把正文修好（不可截断时返回空串）。
  static String repair(String content) => analyze(content).repaired;

  /// 退化起点的字符下标；0 = 未检出。
  ///
  /// 按 [window] 字滑窗统计 4-gram 去重率，从尾部往前找**连续**低于
  /// [threshold] 的区间；退化起点取该区间之后的第一个窗口边界。
  /// 只在前半健康、后半退化时才返回（避免误伤正常文本）。
  static int degenerationOnset(
    String text, {
    double threshold = 0.55,
    int window = 400,
  }) {
    final String t = text.replaceAll(RegExp(r'\s'), '');
    if (t.length < window * 4) return 0;
    const int n = 4;

    double distinctAt(int start) {
      final String seg = t.substring(start, start + window);
      final List<String> grams = <String>[
        for (int i = 0; i + n <= seg.length; i++) seg.substring(i, i + n),
      ];
      if (grams.isEmpty) return 1;
      return grams.toSet().length / grams.length;
    }

    final int step = window ~/ 2;
    // 必须找「连续的退化后缀」：章中间一段对白造成的低窗口不能腰斩后半章。
    int onset = -1;
    bool anyDegenerate = false;
    for (int s = t.length - window; s >= 0; s -= step) {
      if (distinctAt(s) < threshold) {
        onset = s;
        anyDegenerate = true;
      } else {
        break;
      }
    }
    if (!anyDegenerate || onset <= 0) return 0;
    // 健康前缀必须够长（≥ 全文 30%）：否则是「整篇都在退化」，应重写而非截残篇。
    if (onset < (t.length * 0.30).floor()) return 0;
    // 退化后缀同理必须够长（≥ 全文 25%）；零星低窗口视为噪声。
    if (t.length - onset < (t.length * 0.25).floor()) return 0;
    // ⚠ `onset` 是**去空白串**里的下标，必须精确映射回原文下标 ——
    // 直接 `substring(0, onset)` 会切在错误位置（原文的空白没算进去）。
    return _mapStrippedToOriginal(text, onset);
  }

  /// 把「去空白串」的下标映射回原文下标（精确，不用比例估算）。
  static int _mapStrippedToOriginal(String original, int strippedIndex) {
    int count = 0;
    for (int i = 0; i < original.length; i++) {
      if (_isWhitespace(original.codeUnitAt(i))) continue;
      if (count == strippedIndex) return i;
      count++;
    }
    return original.length;
  }

  /// 与 RegExp `\s` 等价的白名单（含全角空格 U+3000 / NBSP U+00A0）。
  static bool _isWhitespace(int cu) =>
      cu == 0x20 ||
      cu == 0x09 ||
      cu == 0x0A ||
      cu == 0x0B ||
      cu == 0x0C ||
      cu == 0x0D ||
      cu == 0xA0 ||
      cu == 0x1680 ||
      cu == 0x2028 ||
      cu == 0x2029 ||
      cu == 0x202F ||
      cu == 0x205F ||
      cu == 0x3000 ||
      (cu >= 0x2000 && cu <= 0x200A);

  /// 截断后的收尾清理：剥折叠重复段、收在句末、去多余空行。
  static String cleanTruncated(String prefix) {
    String t = _dropAdjacentDuplicateParagraphs(prefix);
    t = t.replaceAll(RegExp(r'[ \t]+$', multiLine: true), '');
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    // 收在句末：末尾若吊着半句（≤30 字且无句末符），回退到上一个句末。
    final int last = _lastSentenceBoundaryIndex(t);
    if (last >= 0 && t.length - last - 1 <= 30 && t.length - last - 1 > 0) {
      t = t.substring(0, last + 1).trimRight();
    }
    return t;
  }

  /// 退化处的上下文预览。
  static String _preview(String text, int onset) {
    if (onset <= 0) return '';
    const int span = 60;
    final int a = (onset - span).clamp(0, text.length);
    final int b = (onset + span).clamp(0, text.length);
    final String before = text.substring(a, onset).replaceAll(RegExp(r'\s+'), ' ');
    final String after = text.substring(onset, b).replaceAll(RegExp(r'\s+'), ' ');
    return '…$before【⟵ 从这里开始复读】$after…';
  }

  // -------------------------------------------------------------------------
  // 私有工具（与 multi_agent_book_generation_service 同口径）
  // -------------------------------------------------------------------------

  static final RegExp _sentenceBoundary = RegExp(r'[。！？!?…；;”』」）)\]】]');

  static int _lastSentenceBoundaryIndex(String text) {
    int last = -1;
    for (final Match m in _sentenceBoundary.allMatches(text)) {
      last = m.end - 1;
    }
    return last;
  }

  /// 折叠「与前一段完全相同」的段落，并丢弃重复空段。
  static String _dropAdjacentDuplicateParagraphs(String text) {
    final List<String> paras = text.split(RegExp(r'\n\s*\n'));
    final StringBuffer sb = StringBuffer();
    String prev = '';
    for (final String raw in paras) {
      final String cur = raw.trim();
      if (cur.isEmpty) continue;
      if (cur == prev) continue;
      if (sb.isNotEmpty) sb.write('\n\n');
      sb.write(cur);
      prev = cur;
    }
    return sb.toString();
  }
}
