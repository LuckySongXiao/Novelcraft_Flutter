// 章节元数据清洗 —— 「项目体检 → 一键清洗」的纯规则层。
//
// 为什么需要它（2026-10-12 用户真实库取证，725 章 / 13 项目）：
//
//   扫描 `C:\Users\Administrator\Documents\novelcraft.sqlite` 发现三类**存量污染**，
//   全部是「历史版本把模型原始输出直接落库」留下的：
//
//     ① 章名污染（7 条，全在未删除的《夜闯寡妇村》项目）：
//        `第一卷·第三章·《青铜面具的秘密（约600字》`
//        `第一卷·第六章·《第7/10章》`
//        `第二卷·第六章·《净化仪式（约700字）开局状态：》`
//     ② 梗概污染（260+ 条，跨 7 个项目）：整段 Markdown 大纲原文
//        （`# 第1章：…\n## 本章目标\n- **推进核心事件**：…`）、
//        表格行（`| 角色 | 身份/状态 |`）混进一句话梗概；
//     ③ 梗概复读（100+ 条）：「同一句在绝境中完全觉醒…」循环十余遍。
//
//   ① 由 `chapter_title.dart` 的 +47 判据解决；②③ 由本文件 + `RepetitionGuard`
//   解决。**清洗只动 `title` / `summary` 两个元数据列，绝不碰 `content`** ——
//   正文复读（150+ 章）属于内容问题，必须逐章确认或重写，不做批量自动改写。
//
// 本文件**纯 Dart、零外部依赖**（只 import 同目录的三个纯函数文件），可离线直跑：
//   dart --disable-dart-dev tools/chapter_meta_cleaner_selftest.dart

import 'chapter_title.dart';
import 'outline_repair_text.dart';
import 'repetition_guard.dart';

/// 单章的清洗决定（幂等：无改动时两个 new* 均为 null）。
class ChapterMetaFix {
  const ChapterMetaFix({
    this.newTitle,
    this.newSummary,
    this.reasons = const <String>[],
  });

  /// 清洗后的完整标题；null = 无需改动（或不是可识别的标题形态）。
  final String? newTitle;

  /// 清洗后的梗概；null = 无需改动。
  final String? newSummary;

  /// 命中的规则标签（供体检报告展示 / 排查）。
  final List<String> reasons;

  bool get hasChange => newTitle != null || newSummary != null;
}

/// 章节元数据清洗器。
abstract final class ChapterMetaCleaner {
  /// 梗概的复读判定阈值。
  ///
  /// 比 `RepetitionGuard` 的通用 0.30 更低：梗概是**短文本**（≤120 字），
  /// 实测真实退化梗概 ngram=0.271（通用阈值会漏网），而正常梗概 ngram≈0.00，
  /// 0.20 仍有充足安全边距。
  static const double kSummaryRepeatThreshold = 0.20;

  /// 梗概长度上限（与 `ChapterTitleParser.extractBrief` 默认一致）。
  static const int kSummaryMaxChars = 120;

  /// 章名兜底名（解析不出可靠章名时用它）。
  ///
  /// 与整书生成链路的约定一致（`multi_agent_book_generation_service` 里
  /// `name = resolved.isEmpty ? '第${_cn(cIdx)}章' : resolved`）。
  static String fallbackNameFor(int chapterNo) =>
      chapterNo <= 0 ? '未命名' : '第${chineseChapterNo(chapterNo)}章';

  /// 规划一次清洗。[rawTitle] 形如 `第一卷·第三章·《青铜面具的秘密（约600字》`；
  /// [rawSummary] 任意（可能含 Markdown / 表格 / 复读）；[chapterNo] 为章序号
  /// （来自 `chapters.order_index`，用于生成兜底名）。
  static ChapterMetaFix plan({
    required String rawTitle,
    required String rawSummary,
    required int chapterNo,
    int summaryMaxChars = kSummaryMaxChars,
  }) {
    final List<String> reasons = <String>[];
    final String fallback = fallbackNameFor(chapterNo);
    final String? title = _planTitle(rawTitle, fallback, reasons);
    final String? summary = _planSummary(
      rawSummary,
      fallback,
      summaryMaxChars,
      reasons,
    );
    return ChapterMetaFix(
      newTitle: title,
      newSummary: summary,
      reasons: reasons,
    );
  }

  // ---------------------------------------------------------------------------
  // 标题
  // ---------------------------------------------------------------------------

  /// 标题里 `《…》` 之外的前缀（`第一卷·第三章·`）与书名号内的章名。
  static final RegExp _titledRegex = RegExp(r'^(.*?)《\s*([^》]*?)\s*》\s*$');

  /// 只处理**约定形态** `前缀《章名》`。
  ///
  /// 老项目里还有 `第一章 · 少年出乡`、`第一章 雪夜惊变` 这类自由形态标题
  /// （示例项目），它们本来就没有污染 —— **不动**（宁可不改，不可乱改）。
  static String? _planTitle(
    String rawTitle,
    String fallback,
    List<String> reasons,
  ) {
    final String t = rawTitle.trim();
    if (t.isEmpty) return null;
    final Match? m = _titledRegex.firstMatch(t);
    if (m == null) return null;

    final String prefix = m.group(1)!;
    final String name = m.group(2)!.trim();
    final String cleaned = ChapterTitleParser.cleanFragment(name);

    final String target;
    if (cleaned.isNotEmpty && ChapterTitleParser.isReliableName(cleaned)) {
      target = cleaned;
    } else {
      // 章名不可靠（半截括号 / 字数提示 / 纯章号 …）→ 兜底名。
      target = fallback;
      reasons.add('title:unreliable');
    }
    if (target == name) return null;

    final String rebuilt = '$prefix《$target》';
    if (rebuilt == t) return null;
    reasons.add('title:fixed');
    return rebuilt;
  }

  // ---------------------------------------------------------------------------
  // 梗概
  // ---------------------------------------------------------------------------

  /// 梗概：去 Markdown / 元信息 / 表格 → 复读兜底 → 与原文比较。
  static String? _planSummary(
    String rawSummary,
    String fallback,
    int maxChars,
    List<String> reasons,
  ) {
    final String raw = rawSummary.trim();
    if (raw.isEmpty) return null;

    final String brief = ChapterTitleParser.extractBrief(
      raw,
      fallback,
      maxChars: maxChars,
    );
    if (brief.isEmpty) return null;

    // 复读梗概不可用 —— 回落兜底名（宁可信息少，不可投毒）。
    if (RepetitionGuard.isDegenerate(
      brief,
      threshold: kSummaryRepeatThreshold,
    )) {
      if (fallback.isEmpty || fallback == raw) return null;
      reasons.add('summary:degenerate');
      return fallback;
    }

    // 清洗后仍有生产元信息残渣 → 也回落兜底名（防漏网）。
    if (OutlineRepairText.hasMetaDirt(brief)) {
      if (fallback.isEmpty || fallback == raw) return null;
      reasons.add('summary:metaDirt');
      return fallback;
    }

    if (brief == raw) return null; // 本来就干净
    reasons.add('summary:cleaned');
    return brief;
  }

  // ---------------------------------------------------------------------------
  // 中文章号
  // ---------------------------------------------------------------------------

  static const List<String> _digits = <String>[
    '零', '一', '二', '三', '四', '五', '六', '七', '八', '九',
  ];

  /// 阿拉伯数字 → 中文（1→一，10→十，11→十一，20→二十，21→二十一，100→一百）。
  ///
  /// 章节序号实际不会超过几百；超出范围直接回落到阿拉伯数字（不猜）。
  static String chineseChapterNo(int n) {
    if (n <= 0 || n > 999) return '$n';
    if (n < 10) return _digits[n];
    if (n == 10) return '十';
    if (n < 20) return '十${_digits[n % 10]}';
    final int tens = n ~/ 10;
    final int ones = n % 10;
    if (n < 100) {
      return '${_digits[tens]}十${ones == 0 ? '' : _digits[ones]}';
    }
    final int hundreds = n ~/ 100;
    final int rest = n % 100;
    if (rest == 0) return '${_digits[hundreds]}百';
    if (rest < 10) return '${_digits[hundreds]}百零${_digits[rest]}';
    return '${_digits[hundreds]}百${chineseChapterNo(rest)}';
  }
}
