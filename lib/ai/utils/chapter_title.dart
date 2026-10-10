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

  /// 是否「像个人写的章名」：长度合理、无句读、无元信息标签。
  static bool isReliableName(String name) {
    final String n = name.trim();
    if (n.length < 2 || n.length > 20) return false;
    if (_sentencePunct.hasMatch(n)) return false;
    if (containsMetaLabel(n)) return false;
    if (n.runes.length != n.length) return false; // 含代理对（emoji 等）→ 存疑
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
    // 在**首个**元信息标签处截断：`地下交易标题：血色契约` → `地下交易`
    final int metaAt = _firstMetaLabelIndex(t);
    if (metaAt > 0) t = t.substring(0, metaAt);
    // 未闭合的中文引号：留一个「「利用“」在章名里毫无意义，直接截到引号前。
    t = _cutUnclosedQuote(t);
    t = t.replaceFirst(_leadingNoise, '');
    t = t.replaceFirst(_trailingNoise, '');
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
    for (final String rawLine in source.split(RegExp(r'\r?\n'))) {
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
      line = line.replaceAll(
        RegExp(r'^\s*第\s*\d+\s*(?:[/／]\s*\d+\s*)?章\s*[：:.、]?\s*'),
        '',
      );
      line = line.replaceAll(RegExp(r'^\s*[（(]?\s*\d+\s*[/／]\s*\d+\s*[)）]?\s*'), '');
      line = line.trim();
      if (line.isEmpty) continue;
      if (_isPureMetaLine(line)) continue;
      if (skipLine.isNotEmpty && line == skipLine) continue;
      if (buf.isNotEmpty) buf.write('');
      buf.write(line);
      if (buf.length >= maxChars) break;
    }
    String brief = buf.toString().trim();
    if (brief.isEmpty) return fallbackName;

    // 剥掉行内残留的元信息字段名（`…出场人物：薇拉、艾登` → `…`）。
    brief = _stripInlineMeta(brief);
    if (brief.isEmpty) return fallbackName;
    return _truncateGracefully(brief, maxChars, preferSentenceEnd: true);
  }

  // ---------------------------------------------------------------------------
  // 私有工具
  // ---------------------------------------------------------------------------

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
    return text.replaceAll(RegExp(r'[\s　]+$'), '').trim();
  }

  /// 优雅截断：优先在 maxChars 内的最后一个句末/顿号处收尾，其次是硬截。
  static String _truncateGracefully(
    String text,
    int maxChars, {
    bool preferSentenceEnd = false,
  }) {
    if (text.length <= maxChars) return text;
    final String head = text.substring(0, maxChars);
    final RegExp pattern = preferSentenceEnd
        ? RegExp(r'[。！？!?]')
        : RegExp(r'[，,、。:：]');
    int cut = -1;
    for (final Match m in pattern.allMatches(head)) {
      cut = m.end;
    }
    if (cut >= (maxChars * 0.45).floor()) return head.substring(0, cut);
    return head;
  }
}
