// 章节元数据清洗器自检（纯 Dart，离线直跑）：
//   dart --disable-dart-dev tools/chapter_meta_cleaner_selftest.dart
//
// 用例**全部取自用户真实库**（`C:\Users\Administrator\Documents\novelcraft.sqlite`，
// 2026-10-12 扫描 725 章 / 13 项目），锁死当时的污染形态。
import '../lib/ai/utils/chapter_meta_cleaner.dart';

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

void main() {
  print('===== A. 真实库污染标题（7 条） =====');
  eq(
    'A1 半截括号 + 字数提示',
    ChapterMetaCleaner.plan(
      rawTitle: '第一卷·第三章·《青铜面具的秘密（约600字》',
      rawSummary: '',
      chapterNo: 3,
    ).newTitle,
    '第一卷·第三章·《青铜面具的秘密》',
  );
  eq(
    'A2 半截括号 + 字数提示',
    ChapterMetaCleaner.plan(
      rawTitle: '第一卷·第五章·《暗流涌动（约600字》',
      rawSummary: '',
      chapterNo: 5,
    ).newTitle,
    '第一卷·第五章·《暗流涌动》',
  );
  eq(
    'A3 半截括号 + 字数提示',
    ChapterMetaCleaner.plan(
      rawTitle: '第一卷·第七章·《裂痕（700字》',
      rawSummary: '',
      chapterNo: 7,
    ).newTitle,
    '第一卷·第七章·《裂痕》',
  );
  eq(
    'A4 半截括号 + 章数提示',
    ChapterMetaCleaner.plan(
      rawTitle: '第二卷·第一章·《夜行者（约10章》',
      rawSummary: '',
      chapterNo: 1,
    ).newTitle,
    '第二卷·第一章·《夜行者》',
  );
  eq(
    'A5 半截括号 + 字数提示',
    ChapterMetaCleaner.plan(
      rawTitle: '第二卷·第三章·《暗流涌动（600字》',
      rawSummary: '',
      chapterNo: 3,
    ).newTitle,
    '第二卷·第三章·《暗流涌动》',
  );
  eq(
    'A6 括号 + 尾部字段名（开局状态）',
    ChapterMetaCleaner.plan(
      rawTitle: '第二卷·第六章·《净化仪式（约700字）开局状态：》',
      rawSummary: '',
      chapterNo: 6,
    ).newTitle,
    '第二卷·第六章·《净化仪式》',
  );
  eq(
    'A7 纯章号当章名 → 兜底「第N章」',
    ChapterMetaCleaner.plan(
      rawTitle: '第一卷·第六章·《第7/10章》',
      rawSummary: '',
      chapterNo: 6,
    ).newTitle,
    '第一卷·第六章·《第六章》',
  );
  eq(
    'A8 纯章号当章名 → 兜底「第N章」',
    ChapterMetaCleaner.plan(
      rawTitle: '第三卷·第十章·《第10_10章》',
      rawSummary: '',
      chapterNo: 10,
    ).newTitle,
    '第三卷·第十章·《第十章》',
  );

  print('\n===== B. 正常标题不得被改动 =====');
  for (final String good in <String>[
    '第一卷·第一章·《闯入者》',
    '第一卷·第二章·《猎人的阴影》',
    '第三卷·第八章·《埋下》',
  ]) {
    eq('B 不改动：$good',
        ChapterMetaCleaner.plan(rawTitle: good, rawSummary: '', chapterNo: 1).newTitle,
        null);
  }

  print('\n===== C. 非约定形态标题（老项目自由标题）不得被改动 =====');
  for (final String legacy in <String>[
    '第一章 · 少年出乡',
    '第三章 拜入剑宗',
    '第六章 妖皇将至',
    '第一章',
  ]) {
    eq('C 不改动：$legacy',
        ChapterMetaCleaner.plan(rawTitle: legacy, rawSummary: '', chapterNo: 1).newTitle,
        null);
  }

  print('\n===== D. 真实库污染梗概 =====');
  // ① 整段 Markdown 大纲原文。
  final String mdSummary = '# 第1章：祭祀夜的异常\n## 本章目标\n'
      '- **推进核心事件**：揭示“每年祭祀夜寡妇们都会消失”这一诡异现象，并让林婉清意识到这不是巧合。\n'
      '- **建立人物关系**：通过赵寡妇的求救与神秘女子的出场，初步勾勒联盟成员之间的信任危机与潜在纽带。\n'
      '## 出场人物\n| 角色 | 身份/状态 |\n|------|-----------|\n';
  {
    final String? s = ChapterMetaCleaner.plan(
      rawTitle: '第一卷·第一章·《祭祀夜的异常》',
      rawSummary: mdSummary,
      chapterNo: 1,
    ).newSummary;
    eq('D1 Markdown 大纲 → 一句话梗概（无 # / | / 字段名）',
        s != null && !RegExp(r'[#|*]').hasMatch(s) && !s.contains('本章目标') && !s.contains('出场人物'),
        true);
    print('      → "$s"');
  }
  // ② 一整行的多段污染梗概（模型把 `##`/`###` 挤在无换行的一行里）
  //    → 必须按 `#{1,6}` 切出逻辑行，清洗成一句话。
  final String oneLineSummary = '#第6/10章：觉醒的代价##核心冲突与转折'
      '###1.灵视能力彻底觉醒-主线推进：林枫在绝境中完全觉醒，看到整个宇宙网络。他发现自己身体不是普通人类，而是远古神祇留下的钥匙。'
      '###5.苏雨薇牺牲自己-内容概要：苏雨薇在绝境中完全觉醒，看到整个宇宙网络。她发现自己身体不是普通人类，而是远古神祇留下的钥匙。';
  {
    final ChapterMetaFix f = ChapterMetaCleaner.plan(
      rawTitle: '第一卷·第六章·《觉醒的代价》',
      rawSummary: oneLineSummary,
      chapterNo: 6,
    );
    final String? s = f.newSummary;
    eq(
      'D2 一行多段污染梗概 → 清洗成一句话（无 # / | / 字段名）',
      s != null &&
          !RegExp(r'[#|*]').hasMatch(s) &&
          !s.contains('本章目标') &&
          !s.contains('出场人物'),
      true,
    );
    print('      → "$s"');
  }
  // ③ 行内复读（同一句在**同一行**循环十余遍）→ 回落兜底名。
  final String inlineRepeat = '林枫在绝境中完全觉醒，看到整个宇宙网络。' * 12;
  {
    final ChapterMetaFix f = ChapterMetaCleaner.plan(
      rawTitle: '第一卷·第六章·《觉醒的代价》',
      rawSummary: inlineRepeat,
      chapterNo: 6,
    );
    eq('D3 行内复读梗概 → 回落兜底名「第六章」', f.newSummary, '第六章');
    eq('D3b 命中 summary:degenerate', f.reasons.contains('summary:degenerate'), true);
  }
  // ④ 干净梗概不动。
  eq('D4 干净梗概不改动',
      ChapterMetaCleaner.plan(
        rawTitle: '第一卷·第一章·《闯入者》',
        rawSummary: '陈九在祭祀当夜潜入祠堂，发现牌位夹层里的血书。',
        chapterNo: 1,
      ).newSummary,
      null);
  // ⑤ 空梗概不动。
  eq('D5 空梗概不改动',
      ChapterMetaCleaner.plan(rawTitle: '第一卷·第一章·《闯入者》', rawSummary: '   ', chapterNo: 1).newSummary,
      null);

  print('\n===== E. 幂等：清洗结果再洗一次应无改动 =====');
  for (final (String t, String s) in <(String, String)>[
    ('第一卷·第三章·《青铜面具的秘密（约600字》', mdSummary),
    ('第一卷·第六章·《第7/10章》', oneLineSummary),
    ('第一卷·第六章·《觉醒的代价》', inlineRepeat),
  ]) {
    final ChapterMetaFix first = ChapterMetaCleaner.plan(
        rawTitle: t, rawSummary: s, chapterNo: 3);
    final ChapterMetaFix second = ChapterMetaCleaner.plan(
      rawTitle: first.newTitle ?? t,
      rawSummary: first.newSummary ?? s,
      chapterNo: 3,
    );
    eq('E 幂等：「$t」', second.hasChange, false);
  }

  print('\n===== F. 中文章号 =====');
  for (final (int n, String want) in <(int, String)>[
    (1, '一'), (3, '三'), (9, '九'), (10, '十'), (11, '十一'),
    (15, '十五'), (20, '二十'), (21, '二十一'), (30, '三十'),
    (100, '一百'), (105, '一百零五'), (120, '一百二十'),
  ]) {
    eq('F $n → $want', ChapterMetaCleaner.chineseChapterNo(n), want);
  }
  eq('F 兜底名', ChapterMetaCleaner.fallbackNameFor(3), '第三章');
  eq('F 非法序号兜底', ChapterMetaCleaner.fallbackNameFor(0), '未命名');

  print('\n=== pass=$pass fail=$fail ===');
  if (fail > 0) {
    throw StateError('chapter_meta_cleaner_selftest FAILED: $fail');
  }
}
