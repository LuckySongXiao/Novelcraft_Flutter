// 伏笔账本（foreshadow ledger）—— 串行写书的「剧情联动」纯规则层。
//
// 设计参考：WeaveGrid（https://github.com/amazcuter/WeaveGrid）的「经纬」结构 ——
// **以章节之间的因果与伏笔组织长篇小说**，把每条伏笔的
// 「设定（埋线）→ 途中提醒 → 收回（回收）」三态放在**章节双轴**上，
// 用跨章核查保证「埋下的线最终被收」。
//
// ⚠ 只借鉴**思路**，不复制其代码与提示词（该项目为 PolyForm Noncommercial 1.0.0，
// 版权归 amazcutere）。本文件的解析/账本/校验/渲染全部按本工程既有风格独立实现。
//
// 与参考项目一致的两个关键取舍：
//   ① **大纲原文即唯一真相，索引是派生物**。伏笔提示写在章节细纲文本里
//      （本工程落在 `Chapters.notes`，见下），账本每次由文本重新解析 ——
//      不存在「大纲改了但伏笔表没同步」的不一致，也不需要新建表或升 schema。
//   ② **每条提示只留铺垫方向，越模糊越好**（一句、≤50 字）：
//      具体情节留到对应章节再形成，避免把后文的细节提前写死。
//
// 本工程的字段落点（与 `chapter_rewrite_service._outlineOf` 同口径）：
//   * 章细纲  → `Chapters.summary`（1000 字上限）
//   * 伏笔提示 → `Chapters.notes`（无长度上限，块状文本）
//   解析时把两者合并后再扫，所以作者把提示写在哪个字段都能识别。
//
// 章号口径：**全书序号**（按卷序 → 卷内章序展平后的 1..N），
// 与作者在细纲里写「第 50 章」时的直觉一致（本工程章节表是卷内序号，需展平）。
library;

/// 伏笔提示块的标题（解析锚点 + 生成锚点）。
const String kForeshadowSectionTitle = '伏笔提示';

/// 单条提示的推荐长度上限（仅用于提示，不做硬裁剪 —— 参考项目的取舍）。
const int kForeshadowNoteSoftLimit = 50;

/// 最小起止跨度（章）。跨度 < 2 的「伏笔」没有铺垫空间，判为配置错误。
const int kForeshadowMinSpan = 2;

/// 一章回收多少条独立伏笔即视为「剧情单元」的收束点（>4 条，即至少 5 条）。
const int kForeshadowUnitPayoffThreshold = 5;

/// 一条伏笔记录（纯数据，由细纲文本解析而来）。
class ForeshadowEntry {
  const ForeshadowEntry({
    required this.id,
    required this.setupOrder,
    required this.payoffOrder,
    required this.reminderOrders,
    required this.note,
    required this.sourceOrder,
    required this.rawLine,
  });

  /// 编号，形如 `T001`（原文省略编号时按出现顺序自动分配）。
  final String id;

  /// 埋线章（全书序号，1 起）。
  final int setupOrder;

  /// 回收章（全书序号，1 起）。
  final int payoffOrder;

  /// 途中提醒章（全书序号升序，可为空）。
  final List<int> reminderOrders;

  /// 一句话铺垫方向（可为空）。
  final String note;

  /// 这条提示是从第几章的细纲里解析出来的（用于校验「声明章 == 埋线章」）。
  final int sourceOrder;

  /// 原始行文本（排错与回显用）。
  final String rawLine;

  /// 跨度（回收章 − 埋线章）。
  int get span => payoffOrder - setupOrder;

  /// 是否包含某章（埋线 / 回收 / 提醒任一）。
  bool touches(int order) =>
      setupOrder == order ||
      payoffOrder == order ||
      reminderOrders.contains(order);

  /// 该章在这条伏笔里的角色（用于渲染）。
  ForeshadowRole? roleAt(int order) {
    if (order == setupOrder) return ForeshadowRole.setup;
    if (order == payoffOrder) return ForeshadowRole.payoff;
    if (reminderOrders.contains(order)) return ForeshadowRole.reminder;
    return null;
  }

  ForeshadowEntry copyWith({List<int>? reminderOrders, String? note}) =>
      ForeshadowEntry(
        id: id,
        setupOrder: setupOrder,
        payoffOrder: payoffOrder,
        reminderOrders: reminderOrders ?? this.reminderOrders,
        note: note ?? this.note,
        sourceOrder: sourceOrder,
        rawLine: rawLine,
      );
}

/// 某章在某条伏笔里承担的角色。
enum ForeshadowRole { setup, reminder, payoff }

/// 账本校验问题类型。
enum ForeshadowIssueKind {
  /// 跨度 < [kForeshadowMinSpan]。
  spanTooShort,

  /// 回收章早于或等于埋线章。
  payoffNotAfterSetup,

  /// 编号重复（同一编号出现多条）。
  duplicateId,

  /// 提醒章不在 (埋线章, 回收章) 开区间内。
  reminderOutOfRange,

  /// 回收章超出全书章节数。
  payoffBeyondBook,

  /// 提示行声明的埋线章与所在章不一致（例如把「第 12 章埋线」写在了第 3 章的细纲里）。
  setupMismatchWithSource,

  /// 说明文字过长（仅提醒，不算错误）。
  noteTooLong,

  /// 回收章已写完正文，但该章细纲里没有回收项记录（模型漏回收）。
  payoffNotDeclared,
}

/// 一条校验问题。
class ForeshadowIssue {
  const ForeshadowIssue({
    required this.kind,
    required this.entryId,
    required this.message,
    this.severity = ForeshadowSeverity.error,
  });

  final ForeshadowIssueKind kind;
  final String entryId;
  final String message;
  final ForeshadowSeverity severity;
}

/// 问题严重度。
enum ForeshadowSeverity { error, warning }

/// 剧情单元（一段连续的、以某个高回收入度章收束的章节区间）。
class ForeshadowStoryUnit {
  const ForeshadowStoryUnit({
    required this.index,
    required this.startOrder,
    required this.endOrder,
  });

  /// 单元序号（1 起）。
  final int index;
  final int startOrder;
  final int endOrder;

  bool contains(int order) => order >= startOrder && order <= endOrder;
}

/// 全书伏笔账本。
///
/// 由「章节（含细纲文本）」列表构建；构造后不可变，全部为派生数据。
class ForeshadowLedger {
  ForeshadowLedger._({
    required this.entries,
    required this.chapterCount,
    required this.issues,
    required this.writtenOrders,
  });

  /// 全部伏笔（按埋线章升序，同章按编号）。
  final List<ForeshadowEntry> entries;

  /// 全书章节数（用于越界校验与密度条）。
  final int chapterCount;

  /// 校验问题（按严重度与章号排序）。
  final List<ForeshadowIssue> issues;

  /// 已写完正文的章节序号（用于「未兑现」判定）。
  final Set<int> writtenOrders;

  bool get isEmpty => entries.isEmpty;

  List<ForeshadowIssue> get errors => <ForeshadowIssue>[
        for (final ForeshadowIssue i in issues)
          if (i.severity == ForeshadowSeverity.error) i,
      ];

  List<ForeshadowIssue> get warnings => <ForeshadowIssue>[
        for (final ForeshadowIssue i in issues)
          if (i.severity == ForeshadowSeverity.warning) i,
      ];

  /// 第 [order] 章埋下的伏笔。
  List<ForeshadowEntry> setupsAt(int order) => <ForeshadowEntry>[
        for (final ForeshadowEntry e in entries)
          if (e.setupOrder == order) e,
      ];

  /// 第 [order] 章需要回收的伏笔。
  List<ForeshadowEntry> payoffsAt(int order) => <ForeshadowEntry>[
        for (final ForeshadowEntry e in entries)
          if (e.payoffOrder == order) e,
      ];

  /// 第 [order] 章需要「提一句」的伏笔（途中提醒）。
  List<ForeshadowEntry> remindersAt(int order) => <ForeshadowEntry>[
        for (final ForeshadowEntry e in entries)
          if (e.reminderOrders.contains(order)) e,
      ];

  /// 第 [order] 章的「经纬」刻度：设定数 / 提醒数 / 回收数。
  ForeshadowTick tickAt(int order) => ForeshadowTick(
        order: order,
        setupCount: setupsAt(order).length,
        reminderCount: remindersAt(order).length,
        payoffCount: payoffsAt(order).length,
      );

  /// 全书密度（逐章刻度，1..chapterCount）。
  List<ForeshadowTick> get ticks => <ForeshadowTick>[
        for (int i = 1; i <= chapterCount; i++) tickAt(i),
      ];

  /// 剧情单元：以「回收数 ≥ [kForeshadowUnitPayoffThreshold]」的章为收束点分段。
  ///
  /// 末章强制收束（参考项目的做法：末章至少回收 5 条，不足只补差额）——
  /// 这里不「补」，只保证最后一个单元一定收在末章。
  List<ForeshadowStoryUnit> get storyUnits {
    final List<ForeshadowStoryUnit> units = <ForeshadowStoryUnit>[];
    int start = 1;
    int index = 1;
    for (int order = 1; order <= chapterCount; order++) {
      final int payoffs = payoffsAt(order).length;
      if (payoffs >= kForeshadowUnitPayoffThreshold || order == chapterCount) {
        if (order < start) continue;
        units.add(ForeshadowStoryUnit(
          index: index++,
          startOrder: start,
          endOrder: order,
        ));
        start = order + 1;
      }
    }
    return units;
  }

  /// 转折章：各剧情单元的末章（回收密度峰值 = 剧情高潮/转折点）。
  List<int> get turningOrders =>
      <int>[for (final ForeshadowStoryUnit u in storyUnits) u.endOrder];

  /// 尚未回收且已越过回收章的伏笔（= 欠债）。[currentOrder] 为当前写作位置。
  List<ForeshadowEntry> overdueAt(int currentOrder) => <ForeshadowEntry>[
        for (final ForeshadowEntry e in entries)
          if (e.payoffOrder < currentOrder &&
              writtenOrders.contains(e.payoffOrder))
            e,
      ];

  /// 未回收总数（回收章正文尚未写完的伏笔数）。
  int get openCount => entries
      .where((ForeshadowEntry e) => !writtenOrders.contains(e.payoffOrder))
      .length;

  /// 全书密度汇总。
  ForeshadowDensity get density {
    int setups = 0;
    int reminders = 0;
    int payoffs = 0;
    for (final ForeshadowEntry e in entries) {
      setups++;
      payoffs++;
      reminders += e.reminderOrders.length;
    }
    return ForeshadowDensity(
      entryCount: entries.length,
      setupCount: setups,
      reminderCount: reminders,
      payoffCount: payoffs,
      openCount: openCount,
      chapterCount: chapterCount,
    );
  }

  /// 该章在账本里的联动摘要（UI 与提示词共用）。
  ForeshadowChapterLink linkAt(int order) => ForeshadowChapterLink(
        order: order,
        setups: setupsAt(order),
        reminders: remindersAt(order),
        payoffs: payoffsAt(order),
      );
}

/// 一格的密度刻度。
class ForeshadowTick {
  const ForeshadowTick({
    required this.order,
    required this.setupCount,
    required this.reminderCount,
    required this.payoffCount,
  });

  final int order;
  final int setupCount;
  final int reminderCount;
  final int payoffCount;

  bool get isTouching => setupCount + reminderCount + payoffCount > 0;

  /// 单元内的收束章（回收密度达阈值）。
  bool get isUnitEnd => payoffCount >= kForeshadowUnitPayoffThreshold;
}

/// 全书密度汇总。
class ForeshadowDensity {
  const ForeshadowDensity({
    required this.entryCount,
    required this.setupCount,
    required this.reminderCount,
    required this.payoffCount,
    required this.openCount,
    required this.chapterCount,
  });

  final int entryCount;
  final int setupCount;
  final int reminderCount;
  final int payoffCount;
  final int openCount;
  final int chapterCount;
}

/// 某章的联动摘要。
class ForeshadowChapterLink {
  const ForeshadowChapterLink({
    required this.order,
    required this.setups,
    required this.reminders,
    required this.payoffs,
  });

  final int order;
  final List<ForeshadowEntry> setups;
  final List<ForeshadowEntry> reminders;
  final List<ForeshadowEntry> payoffs;

  bool get isEmpty => setups.isEmpty && reminders.isEmpty && payoffs.isEmpty;
}

/// 账本构建与解析（全部静态纯函数，可离线自检）。
abstract final class ForeshadowLedgerBuilder {
  /// 由章节文本构建账本。
  ///
  /// [chapters] 需按**全书顺序**给出（卷序 → 卷内章序），
  /// 每项含：`order`（全书序号，1 起）、`outline`（细纲文本，summary + notes 合并）、
  /// `hasContent`（正文是否已写）。
  static ForeshadowLedger build(List<ForeshadowChapterSource> chapters) {
    final List<ForeshadowEntry> entries = <ForeshadowEntry>[];
    final List<ForeshadowIssue> issues = <ForeshadowIssue>[];
    final Set<int> written = <int>{};
    int chapterCount = 0;

    for (final ForeshadowChapterSource c in chapters) {
      if (c.order > chapterCount) chapterCount = c.order;
      if (c.hasContent) written.add(c.order);
    }

    for (final ForeshadowChapterSource c in chapters) {
      final List<ForeshadowEntry> parsed = parseHints(
        text: c.outline,
        sourceOrder: c.order,
      );
      for (final ForeshadowEntry e in parsed) {
        entries.add(e);
        if (e.note.length > kForeshadowNoteSoftLimit) {
          issues.add(ForeshadowIssue(
            kind: ForeshadowIssueKind.noteTooLong,
            entryId: e.id,
            severity: ForeshadowSeverity.warning,
            message: '${e.id} 的说明 ${e.note.length} 字，'
                '超过建议的 $kForeshadowNoteSoftLimit 字（越模糊越好，'
                '具体情节留到对应章节再写）。',
          ));
        }
        if (e.setupOrder != c.order) {
          issues.add(ForeshadowIssue(
            kind: ForeshadowIssueKind.setupMismatchWithSource,
            entryId: e.id,
            severity: ForeshadowSeverity.warning,
            message: '${e.id} 声明埋线于第 ${e.setupOrder} 章，'
                '但这条提示写在「第 ${c.order} 章」的细纲里 —— '
                '请把它挪到埋线章的细纲，或改对章号。',
          ));
        }
      }
    }

    entries.sort((ForeshadowEntry a, ForeshadowEntry b) {
      final int bySetup = a.setupOrder.compareTo(b.setupOrder);
      return bySetup != 0 ? bySetup : a.id.compareTo(b.id);
    });

    // ---- 结构校验 ----
    final Map<String, int> idCount = <String, int>{};
    for (final ForeshadowEntry e in entries) {
      idCount[e.id] = (idCount[e.id] ?? 0) + 1;
    }
    idCount.forEach((String id, int n) {
      if (n > 1) {
        issues.add(ForeshadowIssue(
          kind: ForeshadowIssueKind.duplicateId,
          entryId: id,
          message: '编号 $id 重复出现 $n 次 —— 伏笔编号必须全书写唯一。',
        ));
      }
    });

    for (final ForeshadowEntry e in entries) {
      if (e.payoffOrder <= e.setupOrder) {
        issues.add(ForeshadowIssue(
          kind: ForeshadowIssueKind.payoffNotAfterSetup,
          entryId: e.id,
          message: '${e.id} 的回收章（第 ${e.payoffOrder} 章）不晚于'
              '埋线章（第 ${e.setupOrder} 章）。',
        ));
        continue;
      }
      if (e.span < kForeshadowMinSpan) {
        issues.add(ForeshadowIssue(
          kind: ForeshadowIssueKind.spanTooShort,
          entryId: e.id,
          message: '${e.id} 跨度只有 ${e.span} 章，'
              '小于最小值 $kForeshadowMinSpan 章 —— 没有铺垫空间，读者会当成同一场景。',
        ));
      }
      for (final int r in e.reminderOrders) {
        if (r <= e.setupOrder || r >= e.payoffOrder) {
          issues.add(ForeshadowIssue(
            kind: ForeshadowIssueKind.reminderOutOfRange,
            entryId: e.id,
            severity: ForeshadowSeverity.warning,
            message: '${e.id} 的提醒章第 $r 章不在埋线（${e.setupOrder}）'
                '与回收（${e.payoffOrder}）之间，提醒不会生效。',
          ));
        }
      }
      if (chapterCount > 0 && e.payoffOrder > chapterCount) {
        issues.add(ForeshadowIssue(
          kind: ForeshadowIssueKind.payoffBeyondBook,
          entryId: e.id,
          message: '${e.id} 的回收章第 ${e.payoffOrder} 章超出全书 '
              '$chapterCount 章 —— 这条线永远收不回来。',
        ));
      }
    }

    // ---- 已写完的回收章是否真的兑现（模型漏回收的确定性信号）----
    for (final ForeshadowEntry e in entries) {
      if (!written.contains(e.payoffOrder)) continue;
      final bool declared = entries.any((ForeshadowEntry o) =>
          o.payoffOrder == e.payoffOrder && o.setupOrder == e.setupOrder);
      if (!declared) {
        issues.add(ForeshadowIssue(
          kind: ForeshadowIssueKind.payoffNotDeclared,
          entryId: e.id,
          severity: ForeshadowSeverity.warning,
          message: '${e.id} 的回收章（第 ${e.payoffOrder} 章）正文已写完，'
              '但该章细纲里没有对应的回收记录。',
        ));
      }
    }

    issues.sort((ForeshadowIssue a, ForeshadowIssue b) {
      if (a.severity != b.severity) {
        return a.severity == ForeshadowSeverity.error ? -1 : 1;
      }
      return a.entryId.compareTo(b.entryId);
    });

    return ForeshadowLedger._(
      entries: entries,
      chapterCount: chapterCount,
      issues: issues,
      writtenOrders: written,
    );
  }

  /// 从一段细纲文本里解析「伏笔提示」。
  ///
  /// 容错范围（实测过的模型输出形态）：
  ///   * 标题：`## 伏笔提示` / `**伏笔提示**` / `伏笔提示：` / 无标题；
  ///   * 列表符：`-` `*` `•` 或 `1.`；
  ///   * 括号：全角 `（）` 或半角 `()`；
  ///   * 箭头：`→` `->` `—>` `–>` `=>` `~>`；
  ///   * 章号：`第12章` / `第 12 章` / `12章` / 裸数字；
  ///   * 提醒：`提醒第30章` / `提醒：30、38` / 省略。
  ///
  /// 识别不到任何提示时返回空表（**不报错** —— 没写伏笔是合法状态）。
  static List<ForeshadowEntry> parseHints({
    required String text,
    required int sourceOrder,
  }) {
    final List<ForeshadowEntry> out = <ForeshadowEntry>[];
    if (text.trim().isEmpty) return out;

    final bool inSection = _hasSectionTitle(text);
    final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
    int autoIndex = 0;

    for (final String raw in lines) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      // 跳过标题行自身
      if (_isSectionTitleLine(line)) continue;
      // 只在「伏笔提示」小节内解析普通行；小节外只认带 T 编号的行，
      // 避免把正文里出现的「第12章 → 第50章」误判成伏笔。
      final bool hasExplicitId = _idPattern.hasMatch(line);
      if (!inSection && !hasExplicitId) continue;
      // 小节内也要能识别「不是提示」的行（例如下一节的 `## 事件要点`）
      if (line.startsWith('#')) continue;

      final ForeshadowEntry? e = _parseLine(
        line: line,
        sourceOrder: sourceOrder,
        inSection: inSection,
        fallbackId: () => 'T${(++autoIndex).toString().padLeft(3, '0')}',
      );
      if (e != null) out.add(e);
    }
    return out;
  }

  static final RegExp _idPattern = RegExp(r'(?:^|[^\w])T\s*0*\d{1,4}\b',
      caseSensitive: false);
  static final RegExp _sectionTitle = RegExp(
    r'伏\s*笔\s*提\s*示',
  );
  static final RegExp _arrow = RegExp(r'→|->|—>|–>|=>|~>|➜|⇒');

  static bool _hasSectionTitle(String text) => _sectionTitle.hasMatch(text);

  static bool _isSectionTitleLine(String line) {
    final String bare = line
        .replaceAll(RegExp(r'^[#*\s>\-—]+'), '')
        .replaceAll(RegExp(r'[：:]+$'), '')
        .trim();
    return bare == kForeshadowSectionTitle || bare == '伏笔' && line.startsWith('#');
  }

  static ForeshadowEntry? _parseLine({
    required String line,
    required int sourceOrder,
    required bool inSection,
    required String Function() fallbackId,
  }) {
    // 去掉列表符
    String body = line.replaceFirst(RegExp(r'^\s*(?:[-*•]|[0-9]+[.、)])\s*'), '');
    if (body.trim().isEmpty) return null;

    // 编号（可省略）
    String id = '';
    final RegExpMatch? idMatch =
        RegExp(r'^\s*T\s*0*(\d{1,4})\b', caseSensitive: false).firstMatch(body);
    if (idMatch != null) {
      id = 'T${(int.tryParse(idMatch.group(1) ?? '') ?? 0).toString().padLeft(3, '0')}';
      body = body.substring(idMatch.end);
    }

    // 括号内容：埋线章 → 回收章（；提醒…）
    final RegExpMatch? paren =
        RegExp(r'[（(]\s*([^）)]*)\s*[）)]').firstMatch(body);
    if (paren == null) {
      // 没有括号。三种情形：
      //   ① 带编号且能抽出章号 → 当作提示（`T004 第4章 → 第20章：说明`）；
      //   ② 在「伏笔提示」小节内且含箭头 → 无编号也认（作者手写时常省括号）；
      //   ③ 其余 → 不是结构化提示行（可能是说明性文字）。
      final bool hasArrow = _arrow.hasMatch(body);
      if (!(inSection && hasArrow) && id.isEmpty) return null;
      final List<int> nums = _numbersIn(body);
      if (nums.isEmpty) {
        if (id.isEmpty) return null;
        // 只有编号没有章号：记为「自埋自收」的占位，交由校验报错。
        return ForeshadowEntry(
          id: id,
          setupOrder: sourceOrder,
          payoffOrder: sourceOrder,
          reminderOrders: const <int>[],
          note: body.replaceAll(RegExp(r'^[：:\-—\s]+'), '').trim(),
          sourceOrder: sourceOrder,
          rawLine: line,
        );
      }
      final int setup = nums.first;
      final int payoff = nums.length > 1 ? nums[1] : setup;
      final String rest = body
          .replaceFirst(RegExp(r'^[^：:]*[：:]'), '')
          .trim();
      return ForeshadowEntry(
        id: id.isEmpty ? fallbackId() : id,
        setupOrder: setup,
        payoffOrder: payoff,
        reminderOrders: const <int>[],
        note: rest == body ? '' : rest,
        sourceOrder: sourceOrder,
        rawLine: line,
      );
    }
    final String inner = paren.group(1)!.trim();
    final String after = body.substring(paren.end);

    // 拆「两端」与「提醒」。
    // 分隔符不一定是 `；`：实测模型还会写 `（第12章 → 第50章，提醒第30章）`，
    // 所以**优先按「提醒」二字切**，没有再退回按分号切。
    final String ends;
    final String reminderPart;
    final int remindIdx = inner.indexOf('提醒');
    if (remindIdx > 0) {
      ends = inner.substring(0, remindIdx);
      reminderPart = inner.substring(remindIdx);
    } else {
      final List<String> parts = inner.split(RegExp(r'[；;]'));
      ends = parts.first;
      reminderPart = parts.length > 1 ? parts.sublist(1).join('；') : '';
    }

    final List<int> ends2 = _numbersIn(ends);
    if (ends2.isEmpty) return null;
    final int setup = ends2.first;
    final int payoff = ends2.length > 1 ? ends2[1] : setup;

    final List<int> reminders = <int>[];
    if (reminderPart.isNotEmpty) {
      for (final int n in _numbersIn(reminderPart)) {
        if (!reminders.contains(n)) reminders.add(n);
      }
      reminders.sort();
    }

    final String note =
        after.replaceAll(RegExp(r'^[：:\-—\s]+'), '').trim();

    return ForeshadowEntry(
      id: id.isEmpty ? fallbackId() : id,
      setupOrder: setup,
      payoffOrder: payoff,
      reminderOrders: reminders,
      note: note,
      sourceOrder: sourceOrder,
      rawLine: line,
    );
  }

  /// 抽出文本里的全部章号（按出现顺序，去重）。
  ///
  /// 依次尝试三种形态，命中即止：
  ///   ① `第12章` / `第12、30章`（带「第」的中文章号，最常见）
  ///   ② `12章` / `12、30章`（省略「第」）
  ///   ③ 裸数字 `12、30`（完全没写「章」字时的兜底）
  static List<int> _numbersIn(String text) {
    final List<int> out = <int>[];
    // 形态一 / 二：一次匹配「数字（、数字）*章」，再按顿号拆开。
    for (final String pattern in <String>[
      r'第\s*(\d{1,5}(?:\s*[、,，]\s*\d{1,5})*)\s*章',
      r'(\d{1,5}(?:\s*[、,，]\s*\d{1,5})*)\s*章',
    ]) {
      for (final RegExpMatch m in RegExp(pattern).allMatches(text)) {
        for (final String piece in m.group(1)!.split(RegExp(r'[、,，]'))) {
          final int? n = int.tryParse(piece.trim());
          if (n != null && n > 0 && !out.contains(n)) out.add(n);
        }
      }
      if (out.isNotEmpty) return out;
    }
    // 形态三：裸数字兜底。
    for (final RegExpMatch m in RegExp(r'\d{1,5}').allMatches(text)) {
      final int? n = int.tryParse(m.group(0) ?? '');
      if (n != null && n > 0 && !out.contains(n)) out.add(n);
    }
    return out;
  }

  /// 判断一行是否是「伏笔提示」小节标题（供渲染层剥离小节用）。
  static bool isSectionTitleLine(String line) => _isSectionTitleLine(line);

  /// 剥离「伏笔提示」小节，只留其余细纲内容。
  ///
  /// 用途：给**正文写作 / 润色**链路喂「本章大纲」时不要把提示块一起喂进去
  ///（提示是给编排看的元信息，混进正文提示词会被模型当成剧情照抄）。
  static String stripSection(String outline) {
    if (!_hasSectionTitle(outline)) return outline;
    final List<String> kept = <String>[];
    bool inSection = false;
    for (final String raw in outline.split(RegExp(r'\r\n|\r|\n'))) {
      final String line = raw.trimRight();
      if (_isSectionTitleLine(line)) {
        inSection = true;
        continue;
      }
      if (inSection) {
        if (line.trimLeft().startsWith('#')) {
          inSection = false; // 下一个标题 → 离开小节，这一行要保留
        } else {
          continue;
        }
      }
      kept.add(line);
    }
    return kept.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 生成一条标准提示行（供 UI / 生成链路写入）。
  static String formatHint({
    required String id,
    required int setupOrder,
    required int payoffOrder,
    List<int> reminderOrders = const <int>[],
    String note = '',
  }) {
    final StringBuffer b = StringBuffer('- $id（第$setupOrder章 → 第$payoffOrder章');
    if (reminderOrders.isNotEmpty) {
      b.write('；提醒第${reminderOrders.join('、')}章');
    }
    b.write('）');
    if (note.trim().isNotEmpty) b.write('：${note.trim()}');
    return b.toString();
  }

  /// 生成完整的「伏笔提示」小节（无提示时返回空串 —— 不写空标题）。
  static String renderSection(List<ForeshadowEntry> entries) {
    if (entries.isEmpty) return '';
    final List<ForeshadowEntry> sorted = List<ForeshadowEntry>.of(entries)
      ..sort((ForeshadowEntry a, ForeshadowEntry b) =>
          a.setupOrder.compareTo(b.setupOrder));
    final StringBuffer b = StringBuffer('## $kForeshadowSectionTitle\n');
    for (final ForeshadowEntry e in sorted) {
      b.writeln(formatHint(
        id: e.id,
        setupOrder: e.setupOrder,
        payoffOrder: e.payoffOrder,
        reminderOrders: e.reminderOrders,
        note: e.note,
      ));
    }
    return b.toString().trimRight();
  }

  /// 在细纲文本里替换 / 追加「伏笔提示」小节，其余内容原样保留。
  ///
  /// 这是「作者只维护一处」的落地：细纲正文不动，只更新提示块。
  static String upsertSection(String outline, List<ForeshadowEntry> entries) {
    final String rendered = renderSection(entries);
    final List<String> lines = outline.split(RegExp(r'\r\n|\r|\n'));
    final int start = lines.indexWhere(_isSectionTitleLine);
    if (start < 0) {
      if (rendered.isEmpty) return outline;
      final String head = outline.trimRight();
      return head.isEmpty ? rendered : '$head\n\n$rendered';
    }
    // 找到小节结束：下一个标题行
    int end = lines.length;
    for (int i = start + 1; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('#')) {
        end = i;
        break;
      }
    }
    final List<String> before = lines.sublist(0, start);
    final List<String> after = lines.sublist(end);
    final List<String> merged = <String>[
      ...before,
      if (rendered.isNotEmpty) ...rendered.split('\n'),
      ...after,
    ];
    return merged.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trimRight();
  }
}

/// 构建账本所需的一章输入。
class ForeshadowChapterSource {
  const ForeshadowChapterSource({
    required this.order,
    required this.outline,
    this.title = '',
    this.hasContent = false,
  });

  /// 全书序号（1 起）。
  final int order;

  /// 细纲文本（`Chapters.summary` + `Chapters.notes` 合并）。
  final String outline;

  /// 章节标题（渲染参考时用）。
  final String title;

  /// 正文是否已写。
  final bool hasContent;
}

/// 展平前的单章原始信息（卷内序号未展平）。
class ForeshadowFlatChapter {
  const ForeshadowFlatChapter({
    required this.id,
    required this.volumeId,
    this.title = '',
    this.outline = '',
    this.hasContent = false,
  });

  final String id;
  final String volumeId;
  final String title;

  /// 细纲文本（`summary` + `notes` 合并，调用方负责合并）。
  final String outline;
  final bool hasContent;
}

/// 展平结果。
class ForeshadowFlattenResult {
  const ForeshadowFlattenResult({
    required this.sources,
    required this.orderByChapterId,
  });

  /// 全书顺序的账本输入（1..N）。
  final List<ForeshadowChapterSource> sources;

  /// 章 id → 全书序号。
  final Map<String, int> orderByChapterId;

  /// 全书章节数。
  int get chapterCount => sources.length;

  /// 第 [order] 章的细纲（越界返回空串）。
  String outlineAt(int order) =>
      order >= 1 && order <= sources.length ? sources[order - 1].outline : '';

  /// 第 [order] 章的标题（越界返回空串）。
  String titleAt(int order) =>
      order >= 1 && order <= sources.length ? sources[order - 1].title : '';
}

/// 把「卷 → 章」两层结构展平成全书顺序（1..N）。
///
/// 本工程的 `Chapters.orderIndex` 是**卷内**序号，而作者在细纲里写
/// 「第 50 章」时说的是**全书**序号 —— 两者必须在这里对齐，
/// 否则伏笔两端会指向错误的章节。
abstract final class ForeshadowFlattener {
  static ForeshadowFlattenResult flatten({
    required List<ForeshadowFlatChapter> chapters,
    required Map<String, int> volumeOrderById,
  }) {
    // 卷序优先；同卷内保持调用方给的相对顺序（调用方已按卷内章序排好）。
    // 用「卷序 + 卷内出现次序」组成稳定排序键（不拼大整数，避免溢出与硬上限）。
    final Map<String, int> withinVolume = <String, int>{};
    final List<({ForeshadowFlatChapter c, int volOrder, int seq})> keyed =
        <({ForeshadowFlatChapter c, int volOrder, int seq})>[];
    for (final ForeshadowFlatChapter c in chapters) {
      final int seq = (withinVolume[c.volumeId] ?? 0) + 1;
      withinVolume[c.volumeId] = seq;
      keyed.add((
        c: c,
        volOrder: volumeOrderById[c.volumeId] ?? 1 << 20,
        seq: seq,
      ));
    }
    keyed.sort((({ForeshadowFlatChapter c, int volOrder, int seq}) a,
        ({ForeshadowFlatChapter c, int volOrder, int seq}) b) {
      final int byVol = a.volOrder.compareTo(b.volOrder);
      return byVol != 0 ? byVol : a.seq.compareTo(b.seq);
    });

    final List<ForeshadowChapterSource> sources = <ForeshadowChapterSource>[];
    final Map<String, int> orderById = <String, int>{};
    for (int i = 0; i < keyed.length; i++) {
      final ForeshadowFlatChapter c = keyed[i].c;
      sources.add(ForeshadowChapterSource(
        order: i + 1,
        outline: c.outline,
        title: c.title,
        hasContent: c.hasContent,
      ));
      orderById[c.id] = i + 1;
    }
    return ForeshadowFlattenResult(
      sources: sources,
      orderByChapterId: orderById,
    );
  }

  /// 合并「细纲」与「备注」为账本输入文本（与 `chapter_rewrite_service._outlineOf`
  /// 同口径：两者基本相同就只留一份，避免重复扫描）。
  static String mergeOutline(String? summary, String? notes) {
    final String s = (summary ?? '').trim();
    final String n = (notes ?? '').trim();
    if (s.isEmpty) return n;
    if (n.isEmpty) return s;
    if (n.contains(s)) return n;
    if (s.contains(n)) return s;
    return '$s\n$n';
  }
}

/// 写作链路用的提示词渲染（把账本变成模型可读的「本章必须处理什么」）。
abstract final class ForeshadowPrompt {
  /// 本章的联动指令块。
  ///
  /// [outlineAt] 用于取「对面章节」的细纲（可为空 —— 参考项目明确要求
  /// **对面章节尚未编写时标为待安排，不虚构原文**）。
  static String build({
    required ForeshadowLedger ledger,
    required int order,
    String Function(int order)? outlineAt,
    String Function(int order)? titleAt,
    int neighbourChars = 160,
  }) {
    final ForeshadowChapterLink link = ledger.linkAt(order);
    if (link.isEmpty) return '';

    final List<String> lines = <String>[];
    lines.add('【伏笔联动（本章必须处理，不要遗漏）】');

    if (link.payoffs.isNotEmpty) {
      lines.add('本章需要**回收**的伏笔（埋线时的铺垫要在本章兑现）：');
      for (final ForeshadowEntry e in link.payoffs) {
        final String setupTitle = titleAt?.call(e.setupOrder) ?? '';
        final String setupOutline =
            _clip(outlineAt?.call(e.setupOrder) ?? '', neighbourChars);
        lines.add('- ${e.id}：${e.note.isEmpty ? '（埋线时未写说明）' : e.note}');
        lines.add('  埋线于第 ${e.setupOrder} 章'
            '${setupTitle.isEmpty ? '' : '《$setupTitle》'}'
            '${setupOutline.isEmpty ? '（该章细纲待补，不要虚构其原文）' : '，该章细纲：$setupOutline'}');
      }
    }

    if (link.reminders.isNotEmpty) {
      lines.add('本章需要**顺带提醒**的伏笔（只提一句，不要展开、不要提前回收）：');
      for (final ForeshadowEntry e in link.reminders) {
        lines.add('- ${e.id}：${e.note.isEmpty ? '（未写说明）' : e.note}'
            '（第 ${e.setupOrder} 章埋下，将在第 ${e.payoffOrder} 章回收）');
      }
    }

    if (link.setups.isNotEmpty) {
      lines.add('本章**新埋**的伏笔（只留方向，不要写死细节）：');
      for (final ForeshadowEntry e in link.setups) {
        lines.add('- ${e.id}：${e.note.isEmpty ? '（未写说明）' : e.note}'
            '（将在第 ${e.payoffOrder} 章回收）');
      }
    }

    lines.add('要求：回收要落到具体情节上（不是提一句就算），提醒要轻（一句话带过），'
        '新埋的线要模糊（具体情节留到回收章再形成）。不要新增未经批准的伏笔编号。');
    return lines.join('\n');
  }

  /// 回收自查块：让模型在定稿前逐条核对本章承诺的回收是否真的落地。
  static String buildPayoffAudit({
    required ForeshadowLedger ledger,
    required int order,
  }) {
    final List<ForeshadowEntry> payoffs = ledger.payoffsAt(order);
    if (payoffs.isEmpty) return '';
    final StringBuffer b = StringBuffer('【本章回收自查（逐条确认后再定稿）】\n');
    for (final ForeshadowEntry e in payoffs) {
      b.writeln('- ${e.id}：${e.note.isEmpty ? '（未写说明）' : e.note} —— '
          '正文里是否已用**具体情节**兑现？若只提了一句，请补写兑现段落。');
    }
    return b.toString().trimRight();
  }

  /// 欠债清单：已越过回收章但仍未回收的伏笔（供跨章核查与 UI 提醒）。
  static String buildDebtReport(ForeshadowLedger ledger, int currentOrder) {
    final List<ForeshadowEntry> overdue = ledger.overdueAt(currentOrder);
    if (overdue.isEmpty) return '';
    final StringBuffer b = StringBuffer('【未兑现伏笔（已越过回收章）】\n');
    for (final ForeshadowEntry e in overdue) {
      b.writeln('- ${e.id}（应于第 ${e.payoffOrder} 章回收，'
          '埋线第 ${e.setupOrder} 章）：${e.note.isEmpty ? '（未写说明）' : e.note}');
    }
    b.write('请在后续章节安排回收，或明确废弃并更新细纲。');
    return b.toString();
  }

  static String _clip(String text, int max) {
    // ⚠ 必须先**按行**剥离「伏笔提示」小节，再压空白 ——
    // 反过来的话换行已被压成空格，`^…$` 锚点再也匹配不到小节标题。
    final String s = ForeshadowLedgerBuilder.stripSection(text)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.isEmpty) return '';
    return s.length <= max ? s : '${s.substring(0, max)}…';
  }
}

/// **伏笔经纬生成器**（纯规则、确定性、零模型调用）。
///
/// 参考项目的核心机制是「先生成经纬结构（伏笔的设定/提醒/收回），再据此编纲与写正文」——
/// 本类把这套结构生成独立出来，用确定性算法产出：
///
///   ① **剧情单元**：每 [chaptersPerUnit] 章一个单元，单元末章为该单元的**转折章**；
///   ② **回收入度**：每个单元末章至少回收 [minPayoffsPerUnitEnd] 条（参考项目的
///      「一章回收 >4 条即结束当前单元」与「末章强制至少回收 5 条」）；
///   ③ **跨度纪律**：每条伏笔跨度 ≥ [kForeshadowMinSpan]，回收章固定落在单元末章，
///      使「转折章 = 回收密度峰值」这条语义成立；
///   ④ **途中提醒**：跨度 ≥8 章给 1 个提醒、≥16 章给 2 个（提醒章严格在两端之间）；
///   ⑤ **跨单元长线**：相邻单元之间再埋 1 条跨 2 个单元回收的长线，制造「全书呼应」。
///
/// ⚠ **不生成任何剧情内容**：`note` 一律留空。参考项目在生成阶段会**删掉**随机事件、
/// 线索名称与题材类型，只留「埋线章 → 回收章」的骨架 —— 具体是什么线，由作者或模型
/// 在对应章节的细纲里再形成（这正是「越模糊越好」的落地）。
///
/// 确定性：内部用显式 LCG（不依赖 `Random` 的实现细节），同 seed 同章数必得同结果。
abstract final class ForeshadowGenerator {
  /// 生成一组伏笔骨架。
  ///
  /// [chapterCount] 全书章数（< 4 返回空表 —— 太短的书没有铺垫空间）。
  /// [seed] 随机种子（决定埋线章在单元内的具体位置）。
  /// [chaptersPerUnit] 每个剧情单元的章数（默认 10）。
  /// [minPayoffsPerUnitEnd] 每个单元末章至少回收几条（默认 5）。
  /// [extraLongSpanPerGap] 相邻单元之间额外埋几条跨单元长线（默认 1）。
  static List<ForeshadowEntry> generate({
    required int chapterCount,
    int seed = 7,
    int chaptersPerUnit = 10,
    int minPayoffsPerUnitEnd = 5,
    int extraLongSpanPerGap = 1,
  }) {
    if (chapterCount < kForeshadowMinSpan * 2) return const <ForeshadowEntry>[];
    final int perUnit = chaptersPerUnit < 3 ? 3 : chaptersPerUnit;
    final int minPay = minPayoffsPerUnitEnd < 1 ? 1 : minPayoffsPerUnitEnd;
    final _Lcg rnd = _Lcg(seed);

    // ---- ① 剧情单元边界（最后一个单元一定收在末章）----
    final List<int> unitEnds = <int>[];
    for (int end = perUnit; end < chapterCount; end += perUnit) {
      unitEnds.add(end);
    }
    unitEnds.add(chapterCount);
    final List<int> unitStarts = <int>[
      1,
      for (int i = 1; i < unitEnds.length; i++) unitEnds[i - 1] + 1,
    ];

    final List<({int setup, int payoff, List<int> reminders})> raw =
        <({int setup, int payoff, List<int> reminders})>[];

    // ---- ② 单元内伏笔：回收章 = 单元末章 ----
    for (int u = 0; u < unitEnds.length; u++) {
      final int start = unitStarts[u];
      final int end = unitEnds[u];
      final int span = end - start;
      // 单元太短：埋线章只能取 start，且跨度不足时直接跳过（不生成非法结构）。
      if (span < kForeshadowMinSpan) continue;
      // 埋线章候选区间 [start, end - kForeshadowMinSpan]
      final int hi = end - kForeshadowMinSpan;
      final int lo = start;
      final int count = minPay + rnd.next(0, 2); // 5~6 条
      for (int k = 0; k < count; k++) {
        final int setup = lo + rnd.next(0, hi - lo);
        raw.add((setup: setup, payoff: end, reminders: <int>[]));
      }
    }

    // ---- ③ 跨单元长线：setup 在第 u 单元，payoff 在第 u+2 单元的末章 ----
    for (int u = 0; u + 2 < unitEnds.length; u++) {
      final int start = unitStarts[u];
      final int hi = unitEnds[u] - kForeshadowMinSpan;
      if (hi < start) continue;
      for (int k = 0; k < extraLongSpanPerGap; k++) {
        final int setup = start + rnd.next(0, hi - start);
        raw.add((setup: setup, payoff: unitEnds[u + 2], reminders: <int>[]));
      }
    }

    // ---- ④ 途中提醒（只给长跨度）----
    final List<({int setup, int payoff, List<int> reminders})> withReminders =
        <({int setup, int payoff, List<int> reminders})>[];
    for (final ({int setup, int payoff, List<int> reminders}) e in raw) {
      final int span = e.payoff - e.setup;
      final List<int> rem = <int>[];
      if (span >= 16) {
        final int a = e.setup + (span ~/ 3);
        final int b = e.setup + (span * 2 ~/ 3);
        if (a > e.setup && a < e.payoff) rem.add(a);
        if (b > e.setup && b < e.payoff && b != a) rem.add(b);
      } else if (span >= 8) {
        final int a = e.setup + (span ~/ 2);
        if (a > e.setup && a < e.payoff) rem.add(a);
      }
      rem.sort();
      withReminders.add((setup: e.setup, payoff: e.payoff, reminders: rem));
    }

    // ---- ⑤ 排序 + 编号（按埋线章，同章按回收章）----
    withReminders.sort(
        (({int setup, int payoff, List<int> reminders}) a,
            ({int setup, int payoff, List<int> reminders}) b) {
      final int bySetup = a.setup.compareTo(b.setup);
      return bySetup != 0 ? bySetup : a.payoff.compareTo(b.payoff);
    });

    final List<ForeshadowEntry> out = <ForeshadowEntry>[];
    for (int i = 0; i < withReminders.length; i++) {
      final ({int setup, int payoff, List<int> reminders}) e =
          withReminders[i];
      out.add(ForeshadowEntry(
        id: 'T${(i + 1).toString().padLeft(3, '0')}',
        setupOrder: e.setup,
        payoffOrder: e.payoff,
        reminderOrders: e.reminders,
        note: '',
        sourceOrder: e.setup,
        rawLine: '',
      ));
    }
    return out;
  }

  /// 把生成结果按「埋线章」分组，产出「每章要写入的提示块」（供写入各章细纲）。
  ///
  /// 返回：章序号 → 该章细纲要追加的 `## 伏笔提示` 小节文本（无内容的章不出现在表里）。
  static Map<int, String> hintsByChapter(
    List<ForeshadowEntry> entries,
    int chapterCount,
  ) {
    final Map<int, List<ForeshadowEntry>> bySetup =
        <int, List<ForeshadowEntry>>{};
    for (final ForeshadowEntry e in entries) {
      (bySetup[e.setupOrder] ??= <ForeshadowEntry>[]).add(e);
    }
    final Map<int, String> out = <int, String>{};
    for (final MapEntry<int, List<ForeshadowEntry>> e in bySetup.entries) {
      if (e.key < 1 || e.key > chapterCount) continue;
      out[e.key] = ForeshadowLedgerBuilder.renderSection(e.value);
    }
    return out;
  }

  /// 结构摘要（UI 预览用）。
  static String describe(List<ForeshadowEntry> entries, int chapterCount) {
    if (entries.isEmpty) return '（未生成）';
    final Set<int> payoffChapters =
        <int>{for (final ForeshadowEntry e in entries) e.payoffOrder};
    int reminders = 0;
    for (final ForeshadowEntry e in entries) {
      reminders += e.reminderOrders.length;
    }
    final List<int> sortedPayoff = payoffChapters.toList()..sort();
    return '${entries.length} 条伏笔 · 回收章 ${sortedPayoff.length} 个'
        '（${sortedPayoff.join('、')}） · 提醒 $reminders 处 · 全书 $chapterCount 章';
  }
}

/// 显式线性同余伪随机（确定性，不依赖 `Random` 的实现细节）。
class _Lcg {
  _Lcg(int seed) : _state = (seed & 0x7fffffff) + 1;
  int _state;

  /// 返回 [min, max] 闭区间内的整数。
  int next(int min, int max) {
    if (max <= min) return min;
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return min + (_state % (max - min + 1));
  }
}
