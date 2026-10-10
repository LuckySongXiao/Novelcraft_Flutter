// 章名 / 章梗概解析器自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/chapter_title_selftest.dart
//
// 输入取材于 1.0.0+36 实测导出产物（3 卷 30 章，标题全是碎片）：
//   《薇拉在新盟友艾登的帮助下，首次尝试利用“》   → 引号未闭合
//   《第4章：地下交易标题：血色契约【本章目标》   → 元信息污染
//   《重生之红色警戒当尤里统治全球》             → 回落到书名
//   《末世降临薇拉醒来发现世界已变。》           → 多行被粘成一行
import '../lib/ai/utils/chapter_title.dart';

int pass = 0;
int fail = 0;

void eq(String name, Object? got, Object? want) {
  if ('$got' == '$want') {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name\n  want: $want\n  got : $got');
  }
}

/// 断言「拿到了可靠的章名，且等于 [want]」。
void nameIs(String name, String outline, String want) {
  final ChapterNameResult r = ChapterTitleParser.extractName(outline);
  if (r.name == want && r.reliable) {
    pass++;
    print('PASS  $name  →  $want');
  } else {
    fail++;
    print('FAIL  $name\n  want: "$want" (reliable)\n  got : "${r.name}" (reliable=${r.reliable})');
  }
}

/// 断言「拿不到可靠章名」（调用方应当改走 LLM 批量重命名 / 「第N章」兜底）。
void nameUnreliable(String name, String outline) {
  final ChapterNameResult r = ChapterTitleParser.extractName(outline);
  if (!r.reliable) {
    pass++;
    print('PASS  $name  →  不可靠（落兜底）');
  } else {
    fail++;
    print('FAIL  $name\n  expected unreliable, got "${r.name}"');
  }
}

void main() {
  print('===== 章名提取 =====');

  // ① 显式 `标题：` 字段 + 后续元信息污染（单行无换行，实测最常见形态）。
  nameIs(
    'C1 「第4章：地下交易标题：血色契约【本章目标】…」→ 血色契约',
    '第4章：地下交易标题：血色契约【本章目标】薇拉在地下黑市与艾登达成交易。【出场人物】薇拉、艾登',
    '血色契约',
  );

  // ② `第N章：` 前缀 + 换行后的元信息块。
  nameIs(
    'C2 「第4章：地下交易」+ 换行元信息块 → 地下交易',
    '第4章：地下交易\n\n【本章目标】薇拉在地下黑市与艾登达成交易。\n【出场人物】薇拉、艾登',
    '地下交易',
  );

  // ③ 第一行是书名（模型偶发把书名当章名回吐）→ 必须用 forbidden 排除。
  nameIs(
    'C3 首行是书名 → 由 forbidden 排除，取第一章名',
    '重生之红色警戒\n第1章：末世降临\n薇拉醒来发现世界已变。',
    '末世降临',
  );

  // ④ `《…》` 形态（模型按要求输出的正常形态）。
  nameIs(
    'C4 「《血色契约》…」→ 血色契约',
    '标题：《血色契约》\n【本章目标】薇拉与艾登在地下黑市完成交易。',
    '血色契约',
  );

  // ⑤ 多行文本被粘成一行 —— 修复前会得到「末世降临薇拉醒来发现世界已变。」。
  nameIs(
    'C5 候选不得跨行粘连',
    '第1章：末世降临\n薇拉醒来发现世界已变。',
    '末世降临',
  );

  // ⑥ 未闭合引号 + 长散文 → **不可靠**（宁可落兜底，也不写半截书名号）。
  nameUnreliable(
    'C6 未闭合引号的长散文 → 不可靠',
    '薇拉在新盟友艾登的帮助下，首次尝试利用“代号：先知”的力量发动反击。',
  );

  // ⑦ 纯散文、无任何结构 → 不可靠。
  nameUnreliable(
    'C7 纯散文 → 不可靠',
    '薇拉醒来时发现自己躺在一片废墟之中，四周是烧焦的旗帜与断裂的枪管。',
  );

  // ⑧ 空输入。
  eq(
    'C8 空输入 → null',
    ChapterTitleParser.extractName('   ').name,
    null,
  );

  print('\n===== 可靠性判定 =====');
  eq('R1 正常章名可靠', ChapterTitleParser.isReliableName('血色契约'), true);
  eq('R2 含逗号不可靠', ChapterTitleParser.isReliableName('薇拉，艾登'), false);
  eq('R3 含元信息标签不可靠', ChapterTitleParser.isReliableName('本章目标'), false);
  eq('R4 超长不可靠', ChapterTitleParser.isReliableName('一' * 21), false);
  eq('R5 单字不可靠', ChapterTitleParser.isReliableName('序'), false);

  print('\n===== 梗概提取 =====');
  eq(
    'B1 剥掉节标题 / 列表符 / 字段名',
    ChapterTitleParser.extractBrief(
      '#第6/10章：地下交易\n\n##一、本章目标（推进主线）\n- 薇拉与艾登完成交易，拿到代号「先知」的线索。\n【出场人物】薇拉、艾登',
      '地下交易',
    ),
    '薇拉与艾登完成交易，拿到代号「先知」的线索。',
  );
  eq(
    'B2 大纲为空 → 回落章名',
    ChapterTitleParser.extractBrief('   ', '地下交易'),
    '地下交易',
  );
  eq(
    'B3 超出上限时优先收在句末',
    ChapterTitleParser.extractBrief(
      '一、薇拉与艾登完成交易。二、她拿到代号「先知」的线索，并发现艾登其实另有身份。三、追兵赶到。',
      '地下交易',
      maxChars: 20,
    ),
    '薇拉与艾登完成交易。',
  );
  eq(
    'B4 中文序号 + 元信息标题行不得混进梗概',
    ChapterTitleParser.extractBrief(
      '#第6/10章：地下交易\n\n##一、本章目标（推进主线）\n薇拉拿到线索。\n【出场人物】薇拉',
      '地下交易',
    ),
    '薇拉拿到线索。',
  );

  print('\n=== pass=$pass fail=$fail ===');
  if (fail > 0) print('!!! 有失败用例，请修规则后再提交 !!!');
}
