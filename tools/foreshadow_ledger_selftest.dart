// 离线自检：foreshadow_ledger.dart（伏笔账本 / 剧情联动纯规则层）。
//
// 运行：dart --disable-dart-dev tools/foreshadow_ledger_selftest.dart
library;

import 'package:novelcraft/ai/utils/foreshadow_ledger.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool cond) {
  if (cond) {
    _passed++;
  } else {
    _failed++;
    print('FAIL  $name');
  }
}

ForeshadowChapterSource _src(int order, String outline,
        {bool hasContent = false, String title = ''}) =>
    ForeshadowChapterSource(
        order: order, outline: outline, hasContent: hasContent, title: title);

/// 造一本 12 章的书：第1章埋 T001（→第10章，提醒第5章）；第2章埋 T002（→第3章）。
List<ForeshadowChapterSource> _book() => <ForeshadowChapterSource>[
      _src(1, '## 事件要点\n开局。\n\n## 伏笔提示\n'
          '- T001（第1章 → 第10章；提醒第5章）：一枚旧铜钱始终没被提起。'),
      _src(2, '## 伏笔提示\n- T002（第2章 → 第3章）：随口的一句承诺。'),
      for (int i = 3; i <= 12; i++) _src(i, '第 $i 章细纲。'),
    ];

void main() {
  // =========================================================================
  // A 组：解析（容错）
  // =========================================================================
  {
    final e = ForeshadowLedgerBuilder.parseHints(
      text: '## 伏笔提示\n'
          '- T001（第12章 → 第50章；提醒第30章）：一件旧物留下未解疑问。',
      sourceOrder: 12,
    );
    _check('A1 解析出 1 条', e.length == 1);
    _check('A2 编号', e.first.id == 'T001');
    _check('A3 埋线章', e.first.setupOrder == 12);
    _check('A4 回收章', e.first.payoffOrder == 50);
    _check('A5 提醒章', e.first.reminderOrders.length == 1 &&
        e.first.reminderOrders.first == 30);
    _check('A6 说明', e.first.note == '一件旧物留下未解疑问。');
    _check('A7 跨度', e.first.span == 38);
  }
  {
    // 全角/半角括号 + 各种箭头 + 无编号（自动分配）
    final e = ForeshadowLedgerBuilder.parseHints(
      text: '## 伏笔提示\n'
          '* (第3章 -> 第9章) 半角括号与箭头\n'
          '• 第4章 —> 第20章 破折号箭头\n'
          '1. T007(第5章 => 第8章)：等号箭头\n',
      sourceOrder: 3,
    );
    _check('A8 三条都能解析', e.length == 3);
    _check('A9 半角括号', e[0].setupOrder == 3 && e[0].payoffOrder == 9);
    _check('A10 自动编号', e[0].id == 'T001' && e[1].id == 'T002');
    _check('A11 破折号箭头', e[1].setupOrder == 4 && e[1].payoffOrder == 20);
    _check('A12 等号箭头 + 显式编号', e[2].id == 'T007' &&
        e[2].setupOrder == 5 && e[2].payoffOrder == 8);
  }
  {
    // 「第20、30章」并列提醒 + 「，提醒」分隔符（不是分号）
    final e = ForeshadowLedgerBuilder.parseHints(
      text: '## 伏笔提示\n'
          '- T003（第2章 → 第40章，提醒第20、30章）：族谱上被涂掉的名字。',
      sourceOrder: 2,
    );
    _check('A13 逗号分隔也能识别提醒', e.length == 1 &&
        e.first.reminderOrders.length == 2);
    _check('A14 并列提醒章', e.first.reminderOrders.join(',') == '20,30');
  }
  {
    // 无「## 伏笔提示」标题时，只认带 T 编号的行（避免正文误判）
    final e = ForeshadowLedgerBuilder.parseHints(
      text: '第12章 → 第50章 这是正文里的一句对比，不是伏笔。\n'
          'T005（第6章 → 第9章）：带编号的行应当被识别。',
      sourceOrder: 6,
    );
    _check('A15 正文里的「第A章 → 第B章」不误判', e.length == 1);
    _check('A16 带编号的行被识别', e.first.id == 'T005');
  }
  {
    final e = ForeshadowLedgerBuilder.parseHints(
        text: '## 事件要点\n就是一段普通大纲。', sourceOrder: 1);
    _check('A17 无伏笔 → 空表（不报错）', e.isEmpty);
    _check('A18 空文本 → 空表',
        ForeshadowLedgerBuilder.parseHints(text: '   ', sourceOrder: 1).isEmpty);
  }
  {
    // 标题变体
    for (final String t in <String>[
      '**伏笔提示**\n- T001（第1章 → 第5章）：x',
      '伏笔提示：\n- T001（第1章 → 第5章）：x',
      '### 伏笔提示\n- T001（第1章 → 第5章）：x',
    ]) {
      final e = ForeshadowLedgerBuilder.parseHints(text: t, sourceOrder: 1);
      _check('A19 标题变体可解析（${t.split('\n').first}）', e.length == 1);
    }
  }

  // =========================================================================
  // B 组：账本查询
  // =========================================================================
  {
    final ledger = ForeshadowLedgerBuilder.build(_book());
    _check('B1 两条伏笔', ledger.entries.length == 2);
    _check('B2 全书章数', ledger.chapterCount == 12);
    _check('B3 setupsAt(1) = T001',
        ledger.setupsAt(1).length == 1 && ledger.setupsAt(1).first.id == 'T001');
    _check('B4 remindersAt(5) = T001', ledger.remindersAt(5).length == 1);
    _check('B5 payoffsAt(10) = T001', ledger.payoffsAt(10).length == 1);
    _check('B6 payoffsAt(3) = T002', ledger.payoffsAt(3).length == 1 &&
        ledger.payoffsAt(3).first.id == 'T002');
    _check('B7 tick 汇总', ledger.tickAt(1).setupCount == 1 &&
        ledger.tickAt(5).reminderCount == 1 &&
        ledger.tickAt(10).payoffCount == 1);
    _check('B8 ticks 长度 = 章数', ledger.ticks.length == 12);
    _check('B9 密度汇总', ledger.density.entryCount == 2 &&
        ledger.density.reminderCount == 1);
    _check('B10 linkAt(1) 非空', !ledger.linkAt(1).isEmpty);
    _check('B11 linkAt(7) 为空（无联动）', ledger.linkAt(7).isEmpty);
  }

  // =========================================================================
  // C 组：校验问题
  // =========================================================================
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第2章）：跨度不足。'),
    ]);
    _check('C1 跨度 <2 → spanTooShort',
        ledger.errors.any((ForeshadowIssue i) =>
            i.kind == ForeshadowIssueKind.spanTooShort));
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第5章 → 第3章）：回收早于埋线。'),
    ]);
    _check('C2 回收不晚于埋线 → payoffNotAfterSetup',
        ledger.errors.any((ForeshadowIssue i) =>
            i.kind == ForeshadowIssueKind.payoffNotAfterSetup));
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第9章）：a'),
      _src(2, '## 伏笔提示\n- T001（第2章 → 第8章）：b'),
    ]);
    _check('C3 编号重复 → duplicateId',
        ledger.errors.any((ForeshadowIssue i) =>
            i.kind == ForeshadowIssueKind.duplicateId));
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第9章；提醒第20章）：提醒越界。'),
    ]);
    _check('C4 提醒越界 → reminderOutOfRange',
        ledger.warnings.any((ForeshadowIssue i) =>
            i.kind == ForeshadowIssueKind.reminderOutOfRange));
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第99章）：回收越界。'),
      _src(2, 'x'),
    ]);
    _check('C5 回收越界 → payoffBeyondBook',
        ledger.errors.any((ForeshadowIssue i) =>
            i.kind == ForeshadowIssueKind.payoffBeyondBook));
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(3, '## 伏笔提示\n- T001（第1章 → 第9章）：写错章的细纲。'),
      for (int i = 1; i <= 9; i++) if (i != 3) _src(i, 'x'),
    ]);
    _check('C6 声明章与所在章不一致 → setupMismatchWithSource',
        ledger.warnings.any((ForeshadowIssue i) =>
            i.kind == ForeshadowIssueKind.setupMismatchWithSource));
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第3章）：'
          '${'很长的说明' * 20}'),
      _src(2, 'x'),
      _src(3, 'x', hasContent: true),
    ]);
    _check('C7 说明过长 → noteTooLong（warning）',
        ledger.warnings.any((ForeshadowIssue i) =>
            i.kind == ForeshadowIssueKind.noteTooLong));
    _check('C8 结构性问题与提示性问题的分级正确', ledger.errors.isEmpty);
  }
  {
    // 已写完的回收章 → 未回收欠债
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第3章）：该收的线。'),
      _src(2, 'x'),
      _src(3, 'x', hasContent: true),
    ]);
    _check('C9 回收章已写 → openCount 减少', ledger.openCount == 0);
    _check('C10 overdueAt(5) 抓到欠债',
        ledger.overdueAt(5).length == 1 &&
            ledger.overdueAt(5).first.id == 'T001');
    _check('C11 overdueAt(2) 尚未越过 → 空', ledger.overdueAt(2).isEmpty);
  }

  // =========================================================================
  // D 组：剧情单元 / 转折章
  // =========================================================================
  {
    // 第5章回收 5 条 → 单元 1..5；第10章回收 1 条但为末章 → 单元 6..10
    final List<ForeshadowChapterSource> book = <ForeshadowChapterSource>[];
    final StringBuffer hints5 = StringBuffer('## 伏笔提示\n');
    for (int i = 1; i <= 5; i++) {
      hints5.writeln('- T00$i（第1章 → 第5章）：线 $i');
    }
    book.add(_src(1, hints5.toString()));
    book.add(_src(5, ''));
    book.add(_src(10, '## 伏笔提示\n- T009（第1章 → 第10章）：收尾线'));
    for (int i = 2; i <= 10; i++) {
      if (i == 5 || i == 10) continue;
      book.add(_src(i, 'x'));
    }
    final ledger = ForeshadowLedgerBuilder.build(book);
    final units = ledger.storyUnits;
    _check('D1 两个剧情单元', units.length == 2);
    _check('D2 单元 1 = 1..5',
        units[0].startOrder == 1 && units[0].endOrder == 5);
    _check('D3 单元 2 = 6..10（末章强制收束）',
        units[1].startOrder == 6 && units[1].endOrder == 10);
    _check('D4 转折章 = 单元末章',
        ledger.turningOrders.join(',') == '5,10');
    _check('D5 tickAt(5) 达阈值', ledger.tickAt(5).isUnitEnd);
    _check('D6 tickAt(3) 未达阈值', !ledger.tickAt(3).isUnitEnd);
  }
  {
    // 无伏笔 → 只有一个「整本」单元，转折章 = 末章
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      for (int i = 1; i <= 4; i++) _src(i, 'x'),
    ]);
    _check('D7 无伏笔仍有一个单元', ledger.storyUnits.length == 1);
    _check('D8 单元覆盖全书',
        ledger.storyUnits.first.startOrder == 1 &&
            ledger.storyUnits.first.endOrder == 4);
  }

  // =========================================================================
  // E 组：格式化 / 写入（作者只维护一处）
  // =========================================================================
  {
    final String line = ForeshadowLedgerBuilder.formatHint(
      id: 'T001', setupOrder: 12, payoffOrder: 50,
      reminderOrders: <int>[30], note: '一件旧物留下未解疑问。',
    );
    _check('E1 标准格式',
        line == '- T001（第12章 → 第50章；提醒第30章）：一件旧物留下未解疑问。');
    final String noRemind = ForeshadowLedgerBuilder.formatHint(
      id: 'T002', setupOrder: 3, payoffOrder: 18, note: '随口的一句承诺。');
    _check('E2 无提醒时的格式',
        noRemind == '- T002（第3章 → 第18章）：随口的一句承诺。');
    // 往返：格式化 → 解析 → 一致
    final parsed = ForeshadowLedgerBuilder.parseHints(
        text: '## 伏笔提示\n$line', sourceOrder: 12);
    _check('E3 往返一致', parsed.length == 1 &&
        parsed.first.setupOrder == 12 &&
        parsed.first.payoffOrder == 50 &&
        parsed.first.reminderOrders.join(',') == '30' &&
        parsed.first.note == '一件旧物留下未解疑问。');
  }
  {
    final entries = <ForeshadowEntry>[
      const ForeshadowEntry(
        id: 'T002', setupOrder: 3, payoffOrder: 18,
        reminderOrders: <int>[], note: 'b', sourceOrder: 3, rawLine: ''),
      const ForeshadowEntry(
        id: 'T001', setupOrder: 1, payoffOrder: 9,
        reminderOrders: <int>[5], note: 'a', sourceOrder: 1, rawLine: ''),
    ];
    final section = ForeshadowLedgerBuilder.renderSection(entries);
    _check('E4 按埋线章排序', section.indexOf('T001') < section.indexOf('T002'));
    _check('E5 带小节标题', section.startsWith('## 伏笔提示'));
    _check('E6 空表 → 空串',
        ForeshadowLedgerBuilder.renderSection(const <ForeshadowEntry>[]).isEmpty);
  }
  {
    // upsert：无小节 → 追加；原有内容不动
    const outline = '## 事件要点\n开局的一章。';
    final merged = ForeshadowLedgerBuilder.upsertSection(outline, <ForeshadowEntry>[
      const ForeshadowEntry(
        id: 'T001', setupOrder: 1, payoffOrder: 9,
        reminderOrders: <int>[], note: 'a', sourceOrder: 1, rawLine: ''),
    ]);
    _check('E7 追加小节', merged.contains('## 事件要点') &&
        merged.contains('## 伏笔提示') && merged.contains('T001'));
    _check('E8 顺序正确（事件要点在前）',
        merged.indexOf('事件要点') < merged.indexOf('伏笔提示'));
  }
  {
    // upsert：已有小节 → 原地替换，后续小节保留
    const outline = '## 事件要点\n开局。\n\n## 伏笔提示\n- T001（第1章 → 第3章）：旧\n\n'
        '## 章末钩子\n门闩上了。';
    final merged = ForeshadowLedgerBuilder.upsertSection(outline, <ForeshadowEntry>[
      const ForeshadowEntry(
        id: 'T009', setupOrder: 1, payoffOrder: 9,
        reminderOrders: <int>[], note: '新', sourceOrder: 1, rawLine: ''),
    ]);
    _check('E9 替换小节内容', merged.contains('T009') && !merged.contains('T001'));
    _check('E10 后续小节保留', merged.contains('## 章末钩子') &&
        merged.contains('门闩上了。'));
    _check('E11 事件要点保留', merged.contains('开局。'));
    _check('E12 无三连空行', !merged.contains('\n\n\n'));
  }
  {
    // upsert：空表 → 移除小节
    const outline = '## 事件要点\n开局。\n\n## 伏笔提示\n- T001（第1章 → 第3章）：旧';
    final merged = ForeshadowLedgerBuilder.upsertSection(
        outline, const <ForeshadowEntry>[]);
    _check('E13 空表移除小节', !merged.contains('伏笔提示'));
    _check('E14 其余内容保留', merged.contains('事件要点'));
  }

  // =========================================================================
  // F 组：提示词渲染
  // =========================================================================
  {
    final ledger = ForeshadowLedgerBuilder.build(_book());
    final block = ForeshadowPrompt.build(
      ledger: ledger,
      order: 10,
      titleAt: (int o) => '第$o章标题',
      outlineAt: (int o) => '## 事件要点\n第$o章的事件。\n## 伏笔提示\n- T001（第1章 → 第10章）：x',
    );
    _check('F1 回收块非空', block.isNotEmpty);
    _check('F2 含「本章需要**回收**」', block.contains('回收'));
    _check('F3 含埋线章大纲参考', block.contains('埋线于第 1 章'));
    _check('F4 不含「## 伏笔提示」原文（避免把提示当正文）',
        !block.contains('## 伏笔提示'));
    final empty = ForeshadowPrompt.build(ledger: ledger, order: 7);
    _check('F5 无联动 → 空串', empty.isEmpty);
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第4章）：x'),
      for (int i = 2; i <= 4; i++) _src(i, 'x'),
    ]);
    final block = ForeshadowPrompt.build(ledger: ledger, order: 4);
    _check('F6 对面章节无细纲 → 标「待补」不虚构',
        block.contains('待补') || block.contains('未写说明'));
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(_book());
    final audit = ForeshadowPrompt.buildPayoffAudit(ledger: ledger, order: 10);
    _check('F7 回收自查块', audit.contains('回收自查') && audit.contains('T001'));
    _check('F8 无回收 → 空串',
        ForeshadowPrompt.buildPayoffAudit(ledger: ledger, order: 7).isEmpty);
  }
  {
    final ledger = ForeshadowLedgerBuilder.build(<ForeshadowChapterSource>[
      _src(1, '## 伏笔提示\n- T001（第1章 → 第3章）：该收的线'),
      _src(2, 'x'),
      _src(3, 'x', hasContent: true),
      _src(4, 'x'),
    ]);
    final debt = ForeshadowPrompt.buildDebtReport(ledger, 5);
    _check('F9 欠债报告', debt.contains('未兑现') && debt.contains('T001'));
    _check('F10 无欠债 → 空串',
        ForeshadowPrompt.buildDebtReport(ledger, 2).isEmpty);
  }
  {
    // 提醒 / 新埋也要出现在提示块里
    final ledger = ForeshadowLedgerBuilder.build(_book());
    final atReminder = ForeshadowPrompt.build(ledger: ledger, order: 5);
    _check('F11 提醒章块含提醒项', atReminder.contains('顺带提醒'));
    final atSetup = ForeshadowPrompt.build(ledger: ledger, order: 1);
    _check('F12 埋线章块含新埋项', atSetup.contains('新埋'));
  }

  // =========================================================================
  // G 组：经纬生成器（纯规则、确定性）
  // =========================================================================
  {
    final gen = ForeshadowGenerator.generate(chapterCount: 50, seed: 7);
    _check('G1 50 章生成非空', gen.isNotEmpty);
    _check('G2 编号唯一', gen.map((e) => e.id).toSet().length == gen.length);
    _check('G3 编号按埋线章有序', () {
      for (int i = 1; i < gen.length; i++) {
        if (gen[i].setupOrder < gen[i - 1].setupOrder) return false;
      }
      return true;
    }());
    _check('G4 跨度全部 ≥ 最小跨度',
        gen.every((e) => e.span >= kForeshadowMinSpan));
    _check('G5 回收章不超全书', gen.every((e) => e.payoffOrder <= 50));
    _check('G6 埋线章 ≥ 1', gen.every((e) => e.setupOrder >= 1));
    _check('G7 提醒章严格在两端之间', gen.every((e) => e.reminderOrders
        .every((r) => r > e.setupOrder && r < e.payoffOrder)));
    _check('G8 note 一律留空（不生成剧情内容）',
        gen.every((e) => e.note.isEmpty));
    // 单元末章回收密度达标
    final payoffCount = <int, int>{};
    for (final e in gen) {
      payoffCount[e.payoffOrder] = (payoffCount[e.payoffOrder] ?? 0) + 1;
    }
    _check('G9 末章至少回收 5 条', (payoffCount[50] ?? 0) >= 5);
    _check('G10 每个单元末章都 ≥5 条',
        <int>[10, 20, 30, 40, 50].every((o) => (payoffCount[o] ?? 0) >= 5));
  }
  {
    // 确定性：同 seed 同结果；不同 seed 结构不同（埋线章位置变）
    final a = ForeshadowGenerator.generate(chapterCount: 30, seed: 7);
    final b = ForeshadowGenerator.generate(chapterCount: 30, seed: 7);
    final c = ForeshadowGenerator.generate(chapterCount: 30, seed: 99);
    String sig(List<ForeshadowEntry> l) => l
        .map((e) => '${e.setupOrder}-${e.payoffOrder}-${e.reminderOrders.join(".")}')
        .join('|');
    _check('G11 同 seed 完全一致', sig(a) == sig(b));
    _check('G12 不同 seed 结构不同', sig(a) != sig(c));
  }
  {
    _check('G13 章数过少 → 空表',
        ForeshadowGenerator.generate(chapterCount: 3).isEmpty);
    final small = ForeshadowGenerator.generate(chapterCount: 12, seed: 3);
    _check('G14 短篇也能生成', small.isNotEmpty);
    _check('G15 短篇结构合法', small.every((e) =>
        e.span >= kForeshadowMinSpan && e.payoffOrder <= 12));
    final one = ForeshadowGenerator.generate(chapterCount: 5, seed: 1);
    _check('G16 单单元（5 章）合法',
        one.every((e) => e.payoffOrder == 5 && e.setupOrder <= 3));
  }
  {
    // 生成结果直接喂账本 → 零结构错误（这是生成器的验收标准）
    for (final int n in <int>[5, 12, 30, 50, 120]) {
      final gen = ForeshadowGenerator.generate(chapterCount: n, seed: 11);
      final book = <ForeshadowChapterSource>[
        for (int i = 1; i <= n; i++) _src(i, '第 $i 章细纲。'),
      ];
      // 把生成结果按「埋线章」写回各章细纲，再重建账本
      final hints = ForeshadowGenerator.hintsByChapter(gen, n);
      final withHints = <ForeshadowChapterSource>[
        for (int i = 1; i <= n; i++)
          _src(i, hints.containsKey(i)
              ? '${book[i - 1].outline}\n\n${hints[i]}'
              : book[i - 1].outline),
      ];
      final ledger = ForeshadowLedgerBuilder.build(withHints);
      _check('G17-$n 章 生成→写回→重建 无结构错误',
          ledger.errors.isEmpty);
      _check('G18-$n 章 条数一致', ledger.entries.length == gen.length);
      _check('G19-$n 章 跨度与提醒保真', () {
        for (int i = 0; i < gen.length; i++) {
          final ForeshadowEntry a = gen[i];
          final ForeshadowEntry? b = ledger.entries
              .where((ForeshadowEntry x) => x.id == a.id)
              .firstOrNull;
          if (b == null) return false;
          if (b.setupOrder != a.setupOrder || b.payoffOrder != a.payoffOrder) {
            return false;
          }
          if (b.reminderOrders.join(',') != a.reminderOrders.join(',')) {
            return false;
          }
        }
        return true;
      }());
    }
  }
  {
    final gen = ForeshadowGenerator.generate(chapterCount: 50, seed: 7);
    final hints = ForeshadowGenerator.hintsByChapter(gen, 50);
    _check('G20 提示块只落在埋线章',
        hints.keys.every((o) => gen.any((e) => e.setupOrder == o)));
    _check('G21 每块都带小节标题',
        hints.values.every((v) => v.startsWith('## 伏笔提示')));
    _check('G22 摘要非空',
        ForeshadowGenerator.describe(gen, 50).contains('条伏笔'));
    _check('G23 空表摘要',
        ForeshadowGenerator.describe(const <ForeshadowEntry>[], 10) == '（未生成）');
  }

  print('foreshadow_ledger_selftest: $_passed passed, $_failed failed');
  if (_failed > 0) {
    throw StateError('foreshadow_ledger_selftest FAILED: $_failed assertion(s)');
  }
}
