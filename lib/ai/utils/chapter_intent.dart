// 「关联章节」输入意图判定 —— 对应 C#
// `Services/Copilot/CopilotSessionService.LooksLikeChapterQuestion` /
// `ChapterOpKeywords` 与输入区的「取消关联」命令。
//
// 为什么这件事必须单独判定：关联章节后，输入框有两种截然不同的语义 ——
//   **处理要求**（改写/续写…）→ 会产生确认卡并**改正文**
//   **问题**（"这章节奏有什么问题？"）→ 只解答，**绝不能动正文**
// 早期实现把两者一律当处理要求，结果是"作者随口问一句，章节就被重写了"。
//
// 判据与 C# 一致：先看有没有处理类关键词，有就当处理要求；没有且带问号
// （中文另有"…吗"结尾）才当提问。
//
// 本文件是**纯函数**：不 import Flutter，`tool/verify_chapter_intent.dart` 可直跑。
library;

/// 关联章节的输入意图。
enum ChapterRefIntent {
  /// 处理要求（改写 / 续写 / 扩写…）→ 走改稿并回写。
  operation,

  /// 针对本章的提问 → 只解答，不改动正文。
  question,

  /// 解除关联命令（输入「取消关联」）。
  unlink,
}

/// 意图判定（纯函数）。
abstract final class ChapterIntent {
  /// 处理类关键词（中文，对应 C# `ChapterOpKeywords`）。
  static const List<String> zhOpKeywords = <String>[
    '润色', '重写', '改写', '扩写', '续写', '缩写', '精简', '优化',
    '补全', '删减', '修改', '处理', '翻译', '调整', '换一版', '改得', '写得更',
  ];

  /// 处理类关键词（英文）—— 与中文表语义对齐。
  static const List<String> enOpKeywords = <String>[
    'polish', 'rewrite', 're-write', 'expand', 'continue', 'shorten',
    'condense', 'optimize', 'optimise', 'complete', 'trim', 'revise',
    'edit', 'proofread', 'process', 'translate', 'adjust', 'another version',
    'make it', 'write it',
  ];

  /// 解除关联命令（中英）—— C# 用 `input.Contains("取消关联")`，
  /// 这里收严成「整句就是命令」（容忍尾部语气词/标点）：
  /// ① 意见里**顺便提到**"取消关联"不该解除关联；
  /// ② 但"取消关联吧"这类带语气词的命令必须认出来 —— 否则会被当成改稿要求改写正文。
  static const List<String> unlinkCommands = <String>[
    '取消关联', '解除关联', '取消章节关联', '撤销关联',
    'unlink', 'cancel link', 'cancel link.', 'detach',
  ];

  /// 判定一条输入在关联模式下的意图。
  static ChapterRefIntent resolve(String input, {required bool isEnglish}) {
    final String text = input.trim();
    if (text.isEmpty) return ChapterRefIntent.operation;
    if (isUnlinkCommand(text)) return ChapterRefIntent.unlink;
    if (_looksLikeQuestion(text, isEnglish: isEnglish)) {
      return ChapterRefIntent.question;
    }
    return ChapterRefIntent.operation;
  }

  /// 是否是解除关联命令（整句匹配，容忍标点与尾部语气词）。
  static bool isUnlinkCommand(String input) {
    final String text = _normalizeCommand(input);
    // 命令都是短句；长句子即使整句匹配也不该解除关联（防误伤）
    if (text.isEmpty || text.length > 14) return false;
    for (final String c in unlinkCommands) {
      if (text == _normalizeCommand(c)) return true;
    }
    return false;
  }

  /// 命令归一化：去空白/标点、去尾部语气词（吧/呗/啊/哦），英文转小写。
  static String _normalizeCommand(String input) => input
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s。．.!！?？,，、~～]'), '')
      .replaceAll(RegExp(r'[吧呗啊哦呀]+$'), '');

  /// 是否命中处理类关键词。
  static bool hasOperationKeyword(String input, {required bool isEnglish}) {
    final String text = input.toLowerCase();
    final List<String> pool = isEnglish
        ? <String>[...enOpKeywords, ...zhOpKeywords]
        : <String>[...zhOpKeywords, ...enOpKeywords];
    for (final String k in pool) {
      if (text.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  static bool _looksLikeQuestion(String input, {required bool isEnglish}) {
    if (hasOperationKeyword(input, isEnglish: isEnglish)) return false;
    if (input.contains('？') || input.contains('?')) return true;
    // 中文疑问句常以「吗」结尾而不带问号
    return !isEnglish && input.endsWith('吗');
  }
}