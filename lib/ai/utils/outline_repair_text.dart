// 章节大纲「净化 + 结构化」纯函数集 —— 「按前后章内容调整大纲，再重写本章」的前置层。
//
// 为什么需要它（2026-10-10 实测定位，证据链见 `.workbuddy/memory/2026-10-10.md` §11）：
//
//   读用户真实库 `novelcraft.sqlite`：`夜闯寡妇村` 30 章 = 21 已完成 / **9 草稿**，
//   按定稿质量闸复算 NG 率 **30%**；其中 6 章正文**完全为空**、3 章字数不足
//   （1176 / 2231 / 3075，闸线 3200）。这 9 章的 `summary` / `title` 长这样：
//
//     summary = '第一章：祭祀之夜（700字）##'
//     summary = '暗流涌动（约500字）##'
//     summary = '大纲：夜闯寡妇村（全卷第5章）##'
//     title   = '第一卷·第五章·《暗流涌动（约600字》'
//     title   = '第一卷·第六章·《第7/10章》'
//
//   用工程里真实的 `ChapterTitleParser` 对同一批输入跑一遍，输出与库里**逐字一致**
//   —— 也就是说这些「生产元信息」是被**当成正文大纲**一路带下来的。
//
//   后果是闭环的：大纲里的「（约700字）」→ 写手只写 ~700–3000 字 → 过不了
//   `minFinalWords = 3200` 的定稿质量闸 → 判 NG、按 Draft 落库 → 作者点「重写」，
//   而 `ChapterRewriteService` 把同一份 `summary` 原样再喂给模型 → **照着坏大纲
//   再写一遍坏正文** → 二次三次照样 NG。
//
// 因此「修大纲」这一步必须做两件事：
//   1. **把生产元信息清干净**（字数提示 / 章号括号 / Markdown 残留 / 行首「第N章：」）；
//   2. **目标字数由程序给出并写死**，绝不交给模型在文里写「（约600字）」。
//
// 本文件**纯 Dart、零 import**，可直接用 dart 脚本直跑回归：
//   dart --disable-dart-dev tools/outline_repair_selftest.dart

/// 修订后的结构化本章大纲。
///
/// 字段全部可空 —— 模型给不全时，[OutlineRepairText.parse] 只填它给出来的那些，
/// 调用方按「有则用、无则略」渲染，不做任何编造。
class RepairedOutline {
  const RepairedOutline({
    this.goal = '',
    this.carryOver = '',
    this.conflict = '',
    this.turn = '',
    this.hook = '',
    this.timeNode = '',
    this.characters = '',
  });

  /// 本章目标（这一章要推进到哪儿）。
  final String goal;

  /// 承接上文（紧接上一章结尾的什么状态 / 事件）。
  final String carryOver;

  /// 核心冲突。
  final String conflict;

  /// 关键转折。
  final String turn;

  /// 章末钩子（结尾停在哪，给下一章留什么）。
  final String hook;

  /// **故事内时间节点**（如「第三日黄昏」「祭祀当夜」）。
  ///
  /// 这是「该章对应时间节点的履历」的取值来源 —— 见
  /// `ChapterSyncInput.storyTime` 与 `ChapterSyncService` 的时间线写入。
  final String timeNode;

  /// 本章出场 / 涉及的人物（逗号或顿号分隔）。
  final String characters;

  /// 是否一个字段都没解析出来。
  bool get isEmpty =>
      goal.isEmpty &&
      carryOver.isEmpty &&
      conflict.isEmpty &&
      turn.isEmpty &&
      hook.isEmpty &&
      timeNode.isEmpty &&
      characters.isEmpty;

  /// 是否存在「够用」的核心字段 —— 只要求目标 + 至少一个推进性字段。
  ///
  /// 判据刻意宽松：小模型常常只给三四个字段，只要方向清楚就值得继续写。
  bool get isUsable =>
      goal.isNotEmpty &&
      (carryOver.isNotEmpty ||
          conflict.isNotEmpty ||
          turn.isNotEmpty ||
          hook.isNotEmpty);
}

/// 大纲净化 / 结构化的纯函数集合。
abstract final class OutlineRepairText {
  /// 定稿质量闸的字数下限（与 `MultiAgentBookGenerationService.kDefaultMinFinalWords`
  /// 保持一致；此处重复一个常量是为了让本文件**零 import**）。
  static const int defaultMinWords = 3200;

  // ---------------------------------------------------------------------------
  // 1. 生产元信息清洗
  // ---------------------------------------------------------------------------

  /// 行首章号：`第4章：` / `第 4 章.` / `第4/10章` / `第一章：`。
  ///
  /// ⚠ 中文数字必须一起认 —— 实测污染值正是 `第一章：祭祀之夜（700字）##`，
  /// 而 `ChapterTitleParser.extractBrief` 的行首剥离只认阿拉伯数字（`\d+`）。
  static final RegExp chapterNoPrefix = RegExp(
    r'^\s*第\s*[0-9０-９一二三四五六七八九十百千]+\s*'
    r'(?:[/／]\s*[0-9０-９]+\s*)?章\s*[：:.、\-—]?\s*',
  );

  /// 括号字数提示：`（700字）` / `(约500字)` / `（约 600 字）` / `（約５００字）`。
  static final RegExp wordCountParen = RegExp(
    r'[（(]\s*[约約]?\s*[0-9０-９]+\s*字\s*[）)]',
  );

  /// 裸字数提示：`约600字` / `目标字数：4200字` / `字数 3200 字`。
  ///
  /// 刻意**不加括号限定** —— 大纲里的「约N字」永远是生产元信息，而正文梗概里
  /// 出现「约600字」这种表述的概率极低，为彻底断掉「模型照着字数提示写短」这条
  /// 因果链，宁可稍微激进。
  static final RegExp wordCountBare = RegExp(
    r'(?:(?:目标|设定)?字数\s*[：:]?\s*)?[约約]?\s*[0-9０-９]+\s*字',
  );

  /// 括号章号：`（全卷第5章）` / `(第 7/10 章)`。
  static final RegExp chapterNoParen = RegExp(
    r'[（(]\s*(?:全卷)?第\s*[0-9０-９一二三四五六七八九十百千]+\s*'
    r'(?:[/／]\s*[0-9０-９]+\s*)?章\s*[）)]',
  );

  /// 行首 Markdown 装饰。
  static final RegExp _leadingMd = RegExp(r'^\s*(?:#{1,6}|[-*+·•]|>)\s*');

  /// 把一段大纲/梗概文本里的**生产元信息残渣**清掉（幂等）。
  ///
  /// 清理项：行首 Markdown / 行首章号 / 括号或裸字数提示 / 括号章号 /
  /// 行内 `#` 与强调符 / 多余空白。逐行处理并丢弃空行。
  static String stripMeta(String raw) {
    final StringBuffer out = StringBuffer();
    for (final String line in raw.split(RegExp(r'\r?\n'))) {
      String t = line.trim();
      if (t.isEmpty) continue;
      t = t.replaceFirst(_leadingMd, '');
      t = t.replaceFirst(chapterNoPrefix, '');
      // 括号形态先于裸形态，避免 `（700字）` 被裸规则吃掉括号后留下半个括号。
      t = t.replaceAll(wordCountParen, '');
      t = t.replaceAll(chapterNoParen, '');
      t = t.replaceAll(wordCountBare, '');
      t = t.replaceAll(RegExp(r'#+'), '');
      t = t.replaceAll('**', '').replaceAll('__', '');
      t = t.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
      // 括号内容被上面清掉后可能留下**落单的半边括号** —— 实测标题
      // `《暗流涌动（约600字》` 就是这么来的（`（约600字）` 的右括号被
      // 别的规则先吃掉，只剩左括号）。落单括号一律删掉，不做配对补全。
      t = _dropUnpairedBrackets(t);
      // 清洗后可能只剩下冒号 / 括号一类的空壳行，直接丢。
      t = t.trim();
      t = t.replaceAll(RegExp(r'^[：:，,。.、；;）)】\]]+$'), '');
      if (t.isEmpty) continue;
      if (out.isNotEmpty) out.write('\n');
      out.write(t);
    }
    return out.toString().trim();
  }

  /// 删掉落单的圆括号（左括号多于右括号时从右往左删 `（`，反之从左往右删 `）`）。
  ///
  /// 只处理**圆括号**：中文书名号 / 方括号 / 引号在文学文本里成对性更宽松，
  /// 动了反而危险。
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

  /// 条目里是否还残留「章号 / 字数」这类生产元信息（供自检与防回归用）。
  static bool hasMetaDirt(String text) =>
      wordCountParen.hasMatch(text) ||
      chapterNoParen.hasMatch(text) ||
      wordCountBare.hasMatch(text);

  // ---------------------------------------------------------------------------
  // 2. 结构化解析
  // ---------------------------------------------------------------------------

  /// 字段标签 → [RepairedOutline] 的归属。
  ///
  /// **按长度降序**匹配，否则「本章目标」会被「目标」先吃掉一半。
  static const List<(String, String)> _labels = <(String, String)>[
    ('故事时间节点', 'timeNode'),
    ('本章时间节点', 'timeNode'),
    ('时间节点', 'timeNode'),
    ('故事时间', 'timeNode'),
    ('本章目标', 'goal'),
    ('章节目标', 'goal'),
    ('目标', 'goal'),
    ('承接上文', 'carryOver'),
    ('承接前文', 'carryOver'),
    ('承接', 'carryOver'),
    ('核心冲突', 'conflict'),
    ('主要冲突', 'conflict'),
    ('冲突', 'conflict'),
    ('关键转折', 'turn'),
    ('转折', 'turn'),
    ('章末钩子', 'hook'),
    ('结尾钩子', 'hook'),
    ('钩子', 'hook'),
    ('悬念', 'hook'),
    ('出场人物', 'characters'),
    ('登场人物', 'characters'),
    ('涉及人物', 'characters'),
    ('人物', 'characters'),
  ];

  /// 解析模型给出的**结构化**修订大纲。
  ///
  /// 宽容度刻意拉满（小模型爱变形）：
  ///   * 标签可带 `【】` / `[]` / `**` 装饰，冒号可全角半角、可缺失；
  ///   * 行首可有 `1.` / `一、` / `-` 等序号与列表符；
  ///   * 同一字段出现多次时**取首次**（后出现的通常是模型自我复述）；
  ///   * 标签自身被复读（「本章目标：本章目标：…」，+46 实测形态）时循环剥净
  ///     —— [render] 还要在前面再加一层标签，不剥净就会双层前缀落库。
  ///
  /// 一个字段都没认出来时返回 null —— 调用方据此回落到「把清洗后的原文当大纲」，
  /// 而不是拿一个空壳去写正文。
  static RepairedOutline? parse(String raw) {
    if (raw.trim().isEmpty) return null;

    final String cleaned = stripMeta(raw);
    final Map<String, String> fields = <String, String>{};

    for (final String rawLine in cleaned.split(RegExp(r'\r?\n'))) {
      String line = rawLine.trim();
      if (line.isEmpty) continue;
      // 行首序号：`1.` / `1、` / `一、` / `（1）`
      line = line.replaceFirst(
        RegExp(
          r'^\s*(?:(?:[0-9]+|[一二三四五六七八九十]+)\s*[.、．)]'
          r'|[（(]\s*[0-9]+\s*[)）])\s*',
        ),
        '',
      );
      line = line.replaceAll(RegExp(r'^[【\[]\s*'), '');
      line = line.replaceAll('**', '').trim();
      if (line.isEmpty) continue;

      final (String field, String tail)? m = _matchFieldLabel(line);
      if (m == null) continue;
      final String tail = _stripRepeatedLabels(m.$2);
      if (tail.isEmpty) continue;
      fields.putIfAbsent(m.$1, () => tail);
    }

    if (fields.isEmpty) return null;
    final RepairedOutline outline = RepairedOutline(
      goal: fields['goal'] ?? '',
      carryOver: fields['carryOver'] ?? '',
      conflict: fields['conflict'] ?? '',
      turn: fields['turn'] ?? '',
      hook: fields['hook'] ?? '',
      timeNode: fields['timeNode'] ?? '',
      characters: fields['characters'] ?? '',
    );
    return outline.isEmpty ? null : outline;
  }

  /// 单行 → (字段名, 标签后的内容)。不是字段行返回 null。
  ///
  /// 标签后面**必须**紧跟分隔符（冒号 / 空白 / 右括号 / 行尾）—— 否则
  /// `目标人物是陈三` 会被误当成 `目标：人物是陈三`（「目标」二字在中文里
  /// 本来就常见，实测小模型爱把字段名写进正文句子）。
  static (String field, String tail)? _matchFieldLabel(String line) {
    final String head = line.replaceAll(RegExp(r'^[【\[]'), '');
    for (final (String label, String field) in _labels) {
      if (!head.startsWith(label)) continue;
      final String rest = head.substring(label.length);
      final bool separatorOk =
          rest.isEmpty ||
          RegExp(r'^\s').hasMatch(rest) ||
          rest.startsWith('：') ||
          rest.startsWith(':') ||
          rest.startsWith('】') ||
          rest.startsWith(']');
      if (!separatorOk) continue;
      final String tail = rest
          .replaceFirst(RegExp(r'^\s*[：:]\s*'), '')
          .replaceFirst(RegExp(r'^\s*[】\]]\s*[：:]?\s*'), '')
          .trim();
      if (tail.isEmpty) continue;
      return (field, tail);
    }
    return null;
  }

  /// 循环剥掉内容开头被复读的字段标签（「本章目标：本章目标：…」→「…」）。
  static String _stripRepeatedLabels(String tail) {
    String cur = tail;
    while (true) {
      final (String _, String next)? m = _matchFieldLabel(cur);
      if (m == null || m.$2.isEmpty || m.$2 == cur) break;
      cur = m.$2;
    }
    return cur;
  }

  /// 把多行文本里**每行**开头被复读/残留的字段标签剥掉（幂等）。
  ///
  /// 供兜底路径（模型没按结构化格式输出、清洗后整段当大纲用）使用：
  /// 直接把 `cleanedRaw` 塞进 `RepairedOutline(goal: …)` 的话，行内残留的
  /// 「本章目标：」会被 [render] 再包一层 → 双层前缀落库（+46 实测 BUG）。
  static String stripFieldLabels(String raw) {
    final List<String> out = <String>[];
    for (final String rawLine in raw.split(RegExp(r'\r?\n'))) {
      String line = rawLine.trim();
      if (line.isEmpty) continue;
      line = line.replaceFirst(
        RegExp(
          r'^\s*(?:(?:[0-9]+|[一二三四五六七八九十]+)\s*[.、．)]'
          r'|[（(]\s*[0-9]+\s*[)）])\s*',
        ),
        '',
      );
      line = line.replaceAll(RegExp(r'^[【\[]\s*'), '');
      line = line.replaceAll('**', '').trim();
      if (line.isEmpty) continue;
      final String stripped = _stripRepeatedLabels(line);
      if (stripped.isNotEmpty) out.add(stripped);
    }
    return out.join('\n');
  }

  // ---------------------------------------------------------------------------
  // 3. 渲染成「写手可用的本章大纲」
  // ---------------------------------------------------------------------------

  /// 把结构化大纲渲染成一段紧凑文本，供写手/重写提示词使用。
  ///
  /// [targetWords] **由程序写死**（调用方传质量闸下限），并显式声明它是硬要求 ——
  /// 这条是断掉「大纲写 700 字 → 正文只出 700 字 → 过不了闸」因果链的关键一步。
  /// [targetWords] <= 0 时不追加该行。
  static String render(
    RepairedOutline outline, {
    int targetWords = defaultMinWords,
    bool english = false,
  }) {
    final List<String> lines = <String>[];
    void add(String label, String value, String labelEn) {
      final String v = stripMeta(value).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (v.isEmpty) return;
      lines.add('${english ? labelEn : label}：$v');
    }

    add('本章目标', outline.goal, 'Goal');
    add('承接上文', outline.carryOver, 'Picks up from');
    add('核心冲突', outline.conflict, 'Core conflict');
    add('关键转折', outline.turn, 'Key turn');
    add('章末钩子', outline.hook, 'End hook');
    add('出场人物', outline.characters, 'Characters');
    add('故事时间节点', outline.timeNode, 'Story time');

    if (targetWords > 0) {
      lines.add(
        english
            ? 'Length: at least $targetWords characters of finished prose. '
                  'This is a hard requirement; ignore any smaller length hint.'
            : '篇幅：不少于 $targetWords 字的成稿正文。这是硬要求，'
                  '以本行为准，忽略任何更小的字数提示。',
      );
    }
    return lines.join('\n');
  }

  /// 把任一大纲文本（可能是模型的散文输出）整理成可直接写入 `chapters.summary` 的
  /// **一句话梗概**：清洗 → 拼行 → 限长。
  ///
  /// 与 [render] 的区别：这里要的是「章节记录里的一句话梗概」，不是给模型的
  /// 结构化任务书 —— 所以不分字段、不留换行。
  static String toBrief(
    String raw, {
    int maxChars = 120,
    String fallback = '',
  }) {
    final String cleaned = stripMeta(
      raw,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return fallback;
    if (cleaned.length <= maxChars) return cleaned;
    final String head = cleaned.substring(0, maxChars);
    // 尽量收在句末；收不到就收在逗号；都没有才硬截。
    for (final RegExp p in <RegExp>[RegExp(r'[。！？!?]'), RegExp(r'[，,、；;]')]) {
      int cut = -1;
      for (final Match m in p.allMatches(head)) {
        cut = m.end;
      }
      if (cut >= (maxChars * 0.45).floor()) return head.substring(0, cut);
    }
    return head;
  }
}
