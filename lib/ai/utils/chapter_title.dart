// 章节名 / 章梗概解析器 —— 从「模型产出的章节大纲文本」里提取可用的章名与一句话梗概。
//
// 为什么需要独立的解析器（用户实测 BUG，2026-10-09）：
//   写书的章节大纲是**小模型自由文本**，`Book/chapterOutline` 虽然要求
//   「第一行必须输出 标题：《本章正式章节名》」，但 G1K 实际经常给成
//   「第4章：地下交易标题：血色契约【本章目标】…」这类**单行无换行**的元信息
//   大杂烩，或者干脆是一整段散文。旧实现（`_chapterName`）只有一招：
//   找不到 `《…》` 就取首行再截 20 字 —— 于是全书 30 章标题全成了碎片：
//     《薇拉在新盟友艾登的帮助下，首次尝试利用“》   （引号未闭合）
//     《第4章：地下交易标题：血色契约【本章目标》   （元信息污染）
//     《重生之红色警戒当尤里统治全球》             （回落到书名）
//   梗概同理，被写成大纲原文的前 120 字（带 `#`、`##`、`-`、`本章目标`）。
//
// 本文件是**纯函数**，无副作用、无依赖，可直接脚本直跑做回归
// （见 `tools/chapter_title_selftest.dart`）。

/// 章名 / 梗概提取结果。
class ChapterNameResult {
  const ChapterNameResult(this.name, {required this.reliable});

  /// 清洗后的候选章名（可能为 null = 完全没有可用片段）。
  final String? name;

  /// 是否「像个人写的章名」。
  ///
  /// 不可靠（false）时调用方应当改用更聪明的兜底（例如请规划模型批量重命名），
  /// 而不是把一段散文硬塞进书名号。
  final bool reliable;

  bool get isEmpty => name == null || name!.isEmpty;
}

abstract final class ChapterTitleParser {
  /// 元信息字段标签 —— 出现在章名候选里说明截到的是大纲正文而不是章名。
  ///
  /// **按长度降序**匹配（先长后短），否则「本章目标」会被「目标」先截掉一半。
  static const List<String> _metaLabels = <String>[
    '场景与时间线', '场景与时间', '关键冲突与转折', '本章要点', '本章目标',
    '本章主题', '章节目标', '卷末状态', '卷末预告', '本卷背景', '本卷大纲',
    '承接主线', '出场人物', '登场人物', '人物设定', '人物简介', '人物表',
    '剧情事件', '关键事件', '推进脉络', '核心任务', '本卷定位', '冲突转折',
    '章末钩子', '主线大纲', '分卷大纲', '章节大纲', '卷名', '大纲', '摘要',
    '提要', '梗概', '概要', '时间线', '地点', '场景', '冲突', '转折',
    '伏笔', '悬念', '钩子', '字数', '目标', '主题', '标题', '章名',
    '章节名', '剧情', '正文', '备注', '说明', '本章', '本卷',
  ];

  /// 句读类标点 —— 章名里出现即说明候选是句子而不是名字。
  static final RegExp _sentencePunct = RegExp(r'[，,。；;！!？?：:、…]');

  /// 首尾需要剥掉的装饰（书名号 / 方括号 / 井号 / 星号 / 引号 / 括号 / 破折号 / 标点）。
  static final RegExp _leadingNoise = RegExp(
    r'''^[\s《》【】\[\]#*·・\-—–~～'"“”‘’（）(){}<>/／\\|：:，,。.、;；]+''',
  );
  static final RegExp _trailingNoise = RegExp(
    r'''[\s《》【】\[\]#*·・\-—–~～'"“”‘’（）(){}<>/／\\|：:，,。.、;；]+$''',
  );

  /// `第1章` / `第 1 章` / `第1/10章` / `第一章` 后可选 `：` `.` `、`
  static final RegExp _chapterNoPrefix = RegExp(
    r'第\s*[0-9０-９一二三四五六七八九十百千]+\s*(?:[/／]\s*[0-9０-９]+\s*)?章\s*[：:.、\-—]?\s*',
  );

  /// 生产元信息「规模提示」**带括号**形态：
  /// `（约600字）` / `（600字）` / `（1000-1200字）` / `（约10章）`。
  ///
  /// 用户真实库实锤（`081f8357` 项目 7 条污染标题）：模型把
  /// 「青铜面具的秘密（约600字）」「夜行者（约10章）」当章名回吐，
  /// `cleanFragment` 只剥了右括号、留下半截左括号，`isReliableName` 又判它可靠
  /// → 污染名直接落库成 `《青铜面具的秘密（约600字》`。
  static final RegExp _countHintParen = RegExp(
    r'[（(]\s*[约約]?\s*[0-9０-９]+\s*(?:[-~－]\s*[0-9０-９]+\s*)?'
    r'(?:字|章)\s*[）)]',
  );

  /// 裸「规模提示」（无括号）：`约600字` / `600字` / `约10章`。
  ///
  /// `约N章` 必须带 `约` 才剥 —— 否则会误伤 `第7章` 这类正常章号（那由
  /// `_pureChapterNo` 单独处理）。
  static final RegExp _countHintBare = RegExp(
    r'(?:[约約]\s*[0-9０-９]+\s*(?:[-~－]\s*[0-9０-９]+\s*)?(?:字|章)'
    r'|[0-9０-９]+\s*字)',
  );

  /// 章号里「第 N 与 M 之间」的分隔符。
  ///
  /// 实测污染值里 `/` 会被下游清洗成 `_` 或 `-`（`第10/10章` → `第10_10章`），
  /// 所以分隔符要认全：`/` `／` `_` `-` `~` `.` `．`。
  static const String _noSep = r'[/／_\-~.．]';

  /// **纯章号**（不是章名）：`第7章` / `第7/10章` / `第10_10章` / `第一章`。
  static final RegExp _pureChapterNo = RegExp(
    '^第\\s*[0-9０-９一二三四五六七八九十百千]+\\s*'
    '(?:$_noSep\\s*[0-9０-９]+\\s*)?(?:章)?\$',
  );

  /// 名字里混入 `第N/M章` 结构（实测污染值 `《第7/10章》`、`《第10_10章》`）。
  static final RegExp _chapterNoInside = RegExp(
    '第\\s*[0-9０-９一二三四五六七八九十百千]+\\s*$_noSep\\s*[0-9０-９]+\\s*章',
  );

  /// `标题：` / `章名：` / `章节名：` 这类显式字段前缀。
  static final RegExp _labelPrefix = RegExp(r'(?:章节?名|标题|章名)\s*[：:]\s*');

  /// 从大纲文本提取章名。
  ///
  /// [maxChars] 章名长度上限；[forbidden] 禁止使用的名字（通常传书名，
  /// 因为模型偶尔会把书名当章名回吐）。
  static ChapterNameResult extractName(
    String outline, {
    int maxChars = 20,
    Set<String> forbidden = const <String>{},
  }) {
    final String text = outline.trim();
    if (text.isEmpty) return const ChapterNameResult(null, reliable: false);

    // 候选按可信度从高到低尝试；每个候选都过一遍 clean + 可靠性判定。
    final List<String> rawCandidates = <String>[];
    for (final Match m in RegExp(r'《\s*([^》\n]{1,32}?)\s*》').allMatches(text)) {
      rawCandidates.add(m.group(1)!);
    }
    for (final Match m in _labelPrefix.allMatches(text)) {
      rawCandidates.add(_sliceAfter(text, m.end, 32));
    }
    for (final Match m in _chapterNoPrefix.allMatches(text)) {
      rawCandidates.add(_sliceAfter(text, m.end, 32));
    }
    rawCandidates.add(_firstNonEmptyLine(text));
    rawCandidates.addAll(text.split(RegExp(r'\r?\n')));

    ChapterNameResult? best;
    for (final String raw in rawCandidates) {
      final String cleaned = cleanFragment(raw, maxChars: maxChars);
      if (cleaned.isEmpty) continue;
      final String lower = cleaned.toLowerCase();
      if (forbidden.any((String f) => f.trim().toLowerCase() == lower)) continue;
      final bool reliable = isReliableName(cleaned);
      final ChapterNameResult candidate = ChapterNameResult(
        cleaned,
        reliable: reliable,
      );
      // 先取到可靠的直接返回；否则记住第一个不可靠的作为兜底。
      if (reliable) return candidate;
      best ??= candidate;
    }
    return best ?? const ChapterNameResult(null, reliable: false);
  }

  /// 是否「像个人写的章名」：长度合理、无句读、无元信息标签、无生产元信息。
  ///
  /// ⚠ +47 补判据（用户真实库实锤，见 `_countHintParen` 注释）：此前
  /// 「青铜面具的秘密（约600字」「第7/10章」「裂痕（700字」全部被判 **可靠**
  /// → 污染名落库、全书标题变成碎片。四条新判据：
  ///   ① 残留字数提示（`约600字`）；② 纯章号（`第7/10章`）；
  ///   ③ 名字里混入 `第N/M章`；④ 括号不配对 / 含 `/`。
  static bool isReliableName(String name) {
    final String n = name.trim();
    if (n.length < 2 || n.length > 20) return false;
    if (_sentencePunct.hasMatch(n)) return false;
    if (containsMetaLabel(n)) return false;
    if (n.runes.length != n.length) return false; // 含代理对（emoji 等）→ 存疑
    // ① 残留的字数提示（`约600字` / `600字`）—— 章名里不可能有。
    if (_countHintBare.hasMatch(n)) return false;
    // ② 纯章号不是章名。
    if (_pureChapterNo.hasMatch(n)) return false;
    // ③ 名字里混进 `第N/M章`（`第7/10章` 变体）。
    if (_chapterNoInside.hasMatch(n)) return false;
    // ④ 括号不配对（半截括号）或含斜杠 —— 半截括号是「字数提示被切掉一半」
    //    的典型残骸，斜杠几乎只出现在章号/分数里。
    final int open = RegExp(r'[（(]').allMatches(n).length;
    final int close = RegExp(r'[）)]').allMatches(n).length;
    if (open != close) return false;
    if (n.contains('/') || n.contains('／')) return false;
    return true;
  }

  /// 候选中是否混进了元信息字段名。
  static bool containsMetaLabel(String value) {
    final String v = value.toLowerCase();
    return _metaLabels.any((String label) => v.contains(label));
  }

  /// 清洗一个候选片段：截到首行、剥装饰、在首个元信息标签处截断、去掉未闭合引号、限长。
  static String cleanFragment(String raw, {int maxChars = 20}) {
    String t = raw;
    // ⚠ 候选永远是**单行**的：`_sliceAfter` 会向后多取 32 字，若不在换行处
    // 先截断，后面「把 \s+ 折叠成一个空格」会把下一行**粘**进章名 ——
    // 实测产物 `末世降临薇拉醒来发现世界已变。` 就是这么来的。
    final int lineBreak = t.indexOf('\n');
    if (lineBreak >= 0) t = t.substring(0, lineBreak);
    // 折叠空白 + 去掉 Markdown / 括号标记（章名里不可能出现这些）。
    t = t.replaceAll(RegExp(r'[《》【】\[\]#*]+'), '');
    t = t.replaceAll(RegExp(r'\s+'), '');
    // 生产元信息：字数提示（`（约600字）` 先于裸形态，避免吃掉括号后留半个括号）。
    t = t.replaceAll(_countHintParen, '');
    t = t.replaceAll(_countHintBare, '');
    // 括号内容被清掉后可能留下**落单的半边括号**（实测 `青铜面具的秘密（约600字`
    // 就是这么来的）—— 一律删掉，不做配对补全（与 `OutlineRepairText` 同策）。
    t = _dropUnpairedBrackets(t);
    // 在**首个**元信息标签处截断：`地下交易标题：血色契约` → `地下交易`
    final int metaAt = _firstMetaLabelIndex(t);
    if (metaAt > 0) t = t.substring(0, metaAt);
    // 未闭合的中文引号：留一个「「利用“」在章名里毫无意义，直接截到引号前。
    t = _cutUnclosedQuote(t);
    t = t.replaceFirst(_leadingNoise, '');
    t = t.replaceFirst(_trailingNoise, '');
    // 尾部残留的元信息词（实测 `净化仪式开局状态` → `净化仪式`）。
    t = _stripTrailingMetaWords(t);
    if (t.isEmpty) return '';
    if (t.length > maxChars) t = _truncateGracefully(t, maxChars);
    return t.trim();
  }

  /// 从大纲文本提取一句话梗概（≤[maxChars] 字，尽量收在句末）。
  ///
  /// 与章名不同，梗概**允许**是句子，但要剥掉：
  ///   * 行首节标题（`#第6/10章：…`、`##一、本章目标（推进什么）-…`）；
  ///   * 元信息字段名（`本章目标` / `出场人物：` / `时间线：`）；
  ///   * 列表符号与 Markdown 强调符。
  static String extractBrief(
    String outline,
    String fallbackName, {
    int maxChars = 120,
  }) {
    final String source = outline.trim();
    if (source.isEmpty) return fallbackName;

    final StringBuffer buf = StringBuffer();
    // 章节标题行（`#第6/10章：地下交易`）只交代章名、不是梗概内容 ——
    // 不排除它，梗概会变成「地下交易薇拉与艾登完成交易，…」这种粘连串。
    final String skipLine = fallbackName.trim();
    for (final String rawLine in _logicalLines(source)) {
      String line = rawLine;
      line = line.replaceAll(RegExp(r'^\s*#{1,6}\s*'), '');
      line = line.replaceAll(RegExp(r'^\s*[-*+·•]\s*'), '');
      // 序号：`1.` / `1、` / `一、` / `（1）` —— 中文序号同样要剥，
      // 否则梗概会以「一、」开头（实测 `##一、本章目标（推进主线）`）。
      line = line.replaceAll(
        RegExp(r'^\s*(?:\d+|[一二三四五六七八九十]+)\s*[.、．)]\s*'),
        '',
      );
      line = line.replaceAll(RegExp(r'^\s*[（(]\s*\d+\s*[)）]\s*'), '');
      line = line.replaceAll(RegExp(r'\*\*'), '');
      line = line.replaceAll(RegExp(r'^\s*(?:标题|章名|章节名)\s*[：:]'), '');
      // 行首字段标签（`本章目标：…` / `【核心任务】…`）—— 剥标签、留内容。
      // 实测残留：`本章目标：建立“夜袭”计划的初步框架，…` 整句被当成梗概。
      line = _stripLeadingMetaLabel(line);
      // 章节规模提示（`（11-15章）`）与残留星号（`**核心` 被切一半剩 `*核心`）。
      line = line.replaceAll(_countHintParen, '');
      line = line.replaceAll(_countHintBare, '');
      line = line.replaceAll(RegExp(r'\*+'), '');
      line = line.replaceAll(
        RegExp(r'^\s*第\s*\d+\s*(?:[/／]\s*\d+\s*)?章\s*[：:.、]?\s*'),
        '',
      );
      line = line.replaceAll(RegExp(r'^\s*[（(]?\s*\d+\s*[/／]\s*\d+\s*[)）]?\s*'), '');
      line = line.trim();
      if (line.isEmpty) continue;
      // Markdown 表格行（`| 角色 | 身份/状态 |`）与分隔行（`|---|---|`）——
      // 实测用户库的梗概末尾会把「出场人物」表的行整行带进来
      //（`…潜在纽带。| 角色 | 身份/状态 |`），必须整行丢弃，否则梗概里出现管道符。
      if (_isTableRow(line)) continue;
      if (_isPureMetaLine(line)) continue;
      if (skipLine.isNotEmpty && line == skipLine) continue;
      if (buf.isNotEmpty) buf.write('');
      buf.write(line);
      if (buf.length >= maxChars) break;
    }
    String brief = buf.toString().trim();
    if (brief.isEmpty) return fallbackName;

    // 兜底剥掉行内残留的 Markdown 表格管道符（表格行已在循环里跳过，
    // 但「一句话里混进一个 `|`」的形态仍可能出现）。
    brief = brief.replaceAll(RegExp(r'\s*\|\s*'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ');
    // 剥掉行内残留的元信息字段名（`…出场人物：薇拉、艾登` → `…`）。
    brief = _stripInlineMeta(brief);
    // 再兜一层：模型把标签与正文**粘在一起**（`本章目标-陈三…` /
    // `核心事件：主角…` / `本卷开局状态与目标 核心冲突…`），行首/行内截断都抓不住。
    brief = _stripInlineMetaTokens(brief);
    if (brief.isEmpty) return fallbackName;
    return _truncateGracefully(brief, maxChars, preferSentenceEnd: true);
  }

  // ---------------------------------------------------------------------------
  // 私有工具
  // ---------------------------------------------------------------------------

  /// 「逻辑行」：先按换行切，再把行内的 `#{1,6}` 当分隔符切开。
  ///
  /// 用户真实库实锤：`421e4a69` / `cf949155` 等项目的 `summary` 是**一整行**
  /// —— 模型把整个大纲的 `##本章目标` / `###1.…` 挤在无换行的一行里。
  /// 只按换行切的话，`##核心冲突与转折` 这类字段名会原样混进梗概
  ///（实测产物 `觉醒的代价#核心冲突与转折##1.灵视能力彻底觉醒-主线推进：…`）。
  static List<String> _logicalLines(String text) {
    final List<String> out = <String>[];
    for (final String line in text.split(RegExp(r'\r?\n'))) {
      for (final String part in line.split(RegExp(r'#{1,6}'))) {
        out.add(part);
      }
    }
    return out;
  }

  static int _firstMetaLabelIndex(String value) {
    final String v = value.toLowerCase();
    int best = -1;
    for (final String label in _metaLabels) {
      final int at = v.indexOf(label);
      if (at < 0) continue;
      if (best < 0 || at < best) best = at;
    }
    return best;
  }

  /// 章名**尾部**残留的元信息词（按长度降序匹配，长的先剥）。
  ///
  /// 实测污染值 `净化仪式（约700字）开局状态：` 去掉括号/标点后是
  /// `净化仪式开局状态` —— 前段的「净化仪式」是有效章名，尾部的「开局状态」
  /// 是模型泄漏的字段名。这里循环剥尾，直到不再是这些词结尾。
  ///
  /// 只剥**尾部**（`_firstMetaLabelIndex` 已负责行内截断），且要求剩余长度
  /// 仍 ≥ 2，避免把 `正文` 这种恰好同名的短名清空。
  static const List<String> _trailingMetaWords = <String>[
    '开局状态', '起始状态', '结束状态', '卷末状态', '本章状态', '初始状态',
    '状态', '目标', '大纲', '摘要', '提要', '梗概', '概要', '说明', '备注',
    '正文', '章名', '章节名', '本章', '本卷',
  ];

  static String _stripTrailingMetaWords(String s) {
    String t = s;
    bool changed = true;
    while (changed) {
      changed = false;
      for (final String w in _trailingMetaWords) {
        if (t.length > w.length + 1 && t.endsWith(w)) {
          t = t.substring(0, t.length - w.length);
          changed = true;
          break;
        }
      }
    }
    return t;
  }

  /// 删掉落单的圆括号（左括号多于右括号时从右往左删 `（`，反之从左往右删 `）`）。
  ///
  /// 只处理**圆括号**：书名号 / 方括号 / 引号在文本里成对性更宽松，动了反而危险。
  static String _dropUnpairedBrackets(String s) {
    String t = s;
    int open = RegExp(r'[（(]').allMatches(t).length;
    int close = RegExp(r'[）)]').allMatches(t).length;
    while (open > close) {
      final int at = t.lastIndexOf(RegExp(r'[（(]'));
      if (at < 0) break;
      t = t.substring(0, at) + t.substring(at + 1);
      open--;
    }
    while (close > open) {
      final int at = t.indexOf(RegExp(r'[）)]'));
      if (at < 0) break;
      t = t.substring(0, at) + t.substring(at + 1);
      close--;
    }
    return t;
  }

  /// `s = "（代号“先知”），展现"` → 截到未配对的 `“` 之前。
  static String _cutUnclosedQuote(String s) {
    final int open = '“'.allMatches(s).length;
    final int close = '”'.allMatches(s).length;
    if (open > close) {
      final int at = s.lastIndexOf('“');
      if (at > 0) return s.substring(0, at);
    }
    // 半角引号同理（只处理成对出现的“直引号”很罕见，保守只在计数为奇数时切）
    if (s.split('"').length.isEven) {
      final int at = s.lastIndexOf('"');
      if (at > 0) return s.substring(0, at);
    }
    return s;
  }

  static String _sliceAfter(String text, int start, int max) {
    if (start >= text.length) return '';
    final int end = (start + max).clamp(0, text.length);
    return text.substring(start, end);
  }

  static String _firstNonEmptyLine(String text) {
    for (final String line in text.split(RegExp(r'\r?\n'))) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return '';
  }

  /// 整行只有「序号 + 元信息字段名（可带一句括注）」时判为纯元信息行。
  ///
  /// 覆盖实测形态：`本章目标：` / `##一、本章目标（推进主线）` / `1. 出场人物`。
  /// 冒号**可省** —— 括注形态（`本章目标（推进主线）`）本身已是强证据，
  /// 而正文里不会有一整行只剩下字段名。
  static final RegExp _pureMetaLineRegex = RegExp(
    '^(?:#{1,6}\\s*)?'
    '(?:第\\s*[0-9０-９一二三四五六七八九十]+\\s*'
    '(?:[/／]\\s*[0-9０-９]+\\s*)?章\\s*[：:]?\\s*)?'
    '(?:(?:[0-9]+|[一二三四五六七八九十]+)\\s*[.、．)]\\s*'
    '|[（(]\\s*[0-9]+\\s*[)）]\\s*)?'
    '(?:标题|章名|章节名|本章目标|本章要点|出场人物|登场人物|场景与时间线?|'
    '时间线|地点|关键冲突(?:与转折)?|冲突|转折|章末钩子|伏笔|悬念|'
    '本卷背景|本卷大纲|大纲|摘要|提要|梗概|字数)'
    '(?:[（(][^）)\\n]{0,30}[）)])?'
    '\\s*[：:]?\\s*\$',
  );

  static bool _isPureMetaLine(String line) =>
      _pureMetaLineRegex.hasMatch(line.trim());

  /// 行首字段标签（`本章目标：` / `【核心任务】` / `核心事件：`）—— 剥标签、留内容。
  ///
  /// 与 [_pureMetaLineRegex]（整行只有标签 → 整行丢弃）互补：这里处理
  /// 「标签 + 内容在同一行」的形态。实测残留值：
  /// `本章目标：建立“夜袭”计划的初步框架，并埋下村长与族长联手反扑的伏笔。`
  static final RegExp _leadingMetaLabelRegex = RegExp(
    '^(?:#{1,6}\\s*)?(?:[【\\[]\\s*)?'
    '(?:标题|章名|章节名|本章目标|本章要点|本章主题|章节目标|'
    '出场人物|登场人物|涉及人物|场景与时间线?|时间线|地点|'
    '关键冲突(?:与转折)?|核心冲突|主要冲突|冲突|关键转折|转折|'
    '章末钩子|结尾钩子|钩子|伏笔|悬念|'
    '推进脉络|推进主线|主线推进|核心任务|核心事件|关键事件|'
    '本卷目标|本卷背景|本卷大纲|本章核心|大纲|摘要|提要|梗概|概要|字数)'
    '(?:[】\\]])?\\s*[：:]\\s*',
  );

  static String _stripLeadingMetaLabel(String line) =>
      line.replaceFirst(_leadingMetaLabelRegex, '');

  /// **长且无歧义**的字段名 —— 出现在梗概里一律删除（不论后面跟什么）。
  ///
  /// 这些词长到不可能是小说叙述的一部分，且实测残留率最高
  ///（`本卷开局状态与目标` / `本章正式章名` / `推进核心事件` …）。
  static final RegExp _unambiguousMetaTokens = RegExp(
    '本卷开局状态与目标|开局状态与目标|本章正式(?:章名|章节名)?|'
    '本章目标|本章要点|本章核心|推进核心事件|推进核心冲突|推进主线|推进脉络|主线推进|'
    '核心事件|关键事件|核心任务|本卷目标|本卷背景|本卷大纲|'
    '出场人物|登场人物|涉及人物|章末钩子|结尾钩子|场景与时间线|关键冲突与转折',
  );

  /// **有歧义**的字段名 —— 只有后面紧跟分隔符（冒号/逗号/顿号/破折号/星号/空白）
  /// 时才删，避免误伤 `核心冲突在于……` 这类正常叙述。
  static final RegExp _boundedMetaTokens = RegExp(
    '(?:关键冲突|核心冲突|主要冲突|关键转折|场景与时间|时间线|'
    '大纲|摘要|提要|梗概|概要|字数)(?=\\s*[：:，,、\\-—*\\s])',
  );

  /// 行内元信息标签清洗（幂等）。
  static String _stripInlineMetaTokens(String text) {
    String t = text.replaceAll(_unambiguousMetaTokens, '');
    t = t.replaceAll(_boundedMetaTokens, '');
    // 删完标签常留下孤零零的分隔符/空白。
    t = t.replaceAll(RegExp(r'^[\s：:，,、\-—*]+'), '');
    t = t.replaceAll(RegExp(r'[\s：:，,、\-—*]+$'), '');
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ');
    return t.trim();
  }

  /// Markdown 表格行 / 分隔行：`| 角色 | 身份/状态 |`、`|---|---|`、`| --- | :---: |`。
  ///
  /// 用户真实库实锤：梗概被表格行污染成 `…潜在纽带。| 角色 | 身份/状态 |`。
  static bool _isTableRow(String line) {
    final String t = line.trim();
    if (!t.startsWith('|') && !t.endsWith('|')) return false;
    // 纯分隔行（`|---|:--:|`）：整行只有 `|`、`-`、`:`、空白。
    if (RegExp(r'^\|?[\s:|-]+\|?$').hasMatch(t) && t.contains('-')) return true;
    return t.contains('|');
  }

  /// 去掉行内残留的元信息字段：`出场人物：…` / `【出场人物】…` / `时间线：…`。
  ///
  /// 两道阈值刻意不同：
  ///   * **方括号形态**（`【出场人物】`）是强结构化证据，位置阈值放到 1；
  ///   * **冒号形态**（`出场人物：`）的字段名可能本就是正常叙述的一部分，
  ///     阈值收紧到 12，宁可少切。
  /// 取**最早**出现的位置切，只保留字段之前的内容。
  static String _stripInlineMeta(String text) {
    for (final bool bracketed in <bool>[true, false]) {
      int cut = -1;
      for (final String label in _metaLabels) {
        final Match? m = (bracketed
                ? RegExp('[【\\[]\\s*$label\\s*[】\\]]')
                : RegExp('$label\\s*[：:]'))
            .firstMatch(text);
        if (m == null) continue;
        if (m.start <= (bracketed ? 0 : 12)) continue;
        if (cut < 0 || m.start < cut) cut = m.start;
      }
      if (cut > 0) text = text.substring(0, cut);
    }
    // 切点常落在**句中**：字段名前那半截词会变成尾巴（实测 `…潜在纽带。埋下`
    // —— `埋下伏笔：…` 被从 `伏笔` 处切开，留下孤零零的 `埋下`）。
    // 尾巴很短（≤20 字）时回退到上一个句末；长尾巴说明是正常叙述，保留。
    final int lastEnd = text.lastIndexOf(RegExp(r'[。！？!?…]'));
    if (lastEnd >= 0 && text.length - lastEnd - 1 <= 20) {
      text = text.substring(0, lastEnd + 1);
    }
    return text.replaceAll(RegExp(r'[\s　]+$'), '').trim();
  }

  /// 优雅截断：按「句末 → 分句（逗号/顿号/分号）→ 硬截」三级回落收尾。
  ///
  /// 梗概必须收在**可读边界**上：实测只按 `。` 收尾时，一段全是逗号的长句会被
  /// 硬切在半句（产物 `…初步勾勒联盟成员之间的信任危机与潜在纽带。埋下`），
  /// 读起来像被截断的残句。加一级分句回落即可避免。
  static String _truncateGracefully(
    String text,
    int maxChars, {
    bool preferSentenceEnd = false,
  }) {
    if (text.length <= maxChars) return text;
    final String head = text.substring(0, maxChars);

    int cutAt(RegExp pattern, double minRatio) {
      int cut = -1;
      for (final Match m in pattern.allMatches(head)) {
        cut = m.end;
      }
      return cut >= (maxChars * minRatio).floor() ? cut : -1;
    }

    if (preferSentenceEnd) {
      final int s = cutAt(RegExp(r'[。！？!?]'), 0.45);
      if (s > 0) return head.substring(0, s);
      final int c = cutAt(RegExp(r'[，,、；;]'), 0.30);
      if (c > 0) return head.substring(0, c);
      return head;
    }
    final int c = cutAt(RegExp(r'[，,、。:：]'), 0.45);
    return c > 0 ? head.substring(0, c) : head;
  }
}
