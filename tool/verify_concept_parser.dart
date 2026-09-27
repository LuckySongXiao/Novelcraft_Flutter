// ignore_for_file: avoid_print
//
// 新书概念解析验证（`concept_parser.dart`，纯 Dart 可直接跑）。
//
// 样本全部来自**真机 / 真云端实测**，不是臆造：
//  - 2026-09-17 `api-7b.rwkvos.com` 实测返回（含 markdown 引用符号 `>`）
//  - 一键生成书籍真机验收时书名退化成《AI新书》的真实故障样本
//
// 运行：dart run tool/verify_concept_parser.dart
import 'dart:io';

import 'package:novelcraft/ai/utils/concept_parser.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $name — $detail');
  } else {
    fail++;
    print('  ❌ $name — $detail');
  }
}

/// 真机实测原始返回（注意首行的 `>`）。
const String liveSample =
    '>书名：异界战神\n类型：东方玄幻\n简介：一个被贬下凡的上古战神，意外穿越到修真世界，却发现自己成了最弱小的废柴。';

void main() {
  print('=' * 78);
  print('[1] 真机样本：行首 `>`（C# 漏了这个装饰符，导致书名丢失）');
  print('=' * 78);
  final ParsedBookConcept live = parseBookConcept(liveSample, isEnglish: false);
  check('书名被正确解析（不是兜底值）', live.title == '异界战神', live.title);
  check('类型被正确解析', live.genre == '东方玄幻', live.genre);
  check('简介被正确解析', live.premise.startsWith('一个被贬下凡的上古战神'), 'len=${live.premise.length}');
  check('书名不是 AI新书 兜底', !live.title.startsWith('AI新书'), live.title);

  print('');
  print('=' * 78);
  print('[2] 行首装饰符全集（C#: 空格/tab/-/*/•/# ；新增 > ）');
  print('=' * 78);
  for (final String deco in <String>[' ', '\t', '-', '*', '•', '#', '>', '>> ']) {
    final ParsedBookConcept r =
        parseBookConcept('$deco书名：云海剑典\n$deco类型：剑修', isEnglish: false);
    check('前缀「$deco」被剥掉', r.title == '云海剑典' && r.genre == '剑修', r.title);
  }

  print('');
  print('=' * 78);
  print('[3] 冒号形态：全角「：」+ 半角「:」（C# 只认全角）');
  print('=' * 78);
  final ParsedBookConcept full = parseBookConcept(
      '书名：星轨之外\n类型：科幻\n简介：一句话。', isEnglish: false);
  check('全角冒号', full.title == '星轨之外' && full.genre == '科幻', full.title);
  final ParsedBookConcept half = parseBookConcept(
      '书名: 星轨之外\n类型: 科幻\n简介: 一句话。', isEnglish: false);
  check('半角冒号', half.title == '星轨之外' && half.genre == '科幻', half.title);
  final ParsedBookConcept mixed = parseBookConcept(
      '书名：混合冒号\n类型: 都市', isEnglish: false);
  check('混用也能解析', mixed.title == '混合冒号' && mixed.genre == '都市', mixed.title);

  print('');
  print('=' * 78);
  print('[4] 兜底不能退化成常量（真机踩到的故障）');
  print('=' * 78);
  final DateTime fixed = DateTime(2026, 9, 17, 14, 5);
  final ParsedBookConcept empty =
      parseBookConcept('', isEnglish: false, now: fixed);
  check('空输出 → 带时间戳占位', empty.title == 'AI新书09171405', empty.title);
  check('英文空输出 → New Book 占位',
      parseBookConcept('', isEnglish: true, now: fixed).title == 'New Book 09171405',
      'ok');
  check('占位不被 firstNonEmptyConcept 降级（修复前会被替换成常量 AI新书）',
      firstNonEmptyConcept(empty.title,
              conceptPlaceholderTitle(false, fixed)) ==
          'AI新书09171405',
      'ok');
  check('两次占位不同（时间戳带来唯一性）',
      conceptPlaceholderTitle(false, fixed) !=
          conceptPlaceholderTitle(false, DateTime(2026, 9, 17, 14, 6)),
      'ok');

  print('');
  print('=' * 78);
  print('[5] 防提示词回显：不得把指令行当书名');
  print('=' * 78);
  const String echo = '书名：（不超过12个字的中文书名，不要书名号）\n类型：（如：东方玄幻 等）';
  final ParsedBookConcept e = parseBookConcept(echo, isEnglish: false, now: fixed);
  check('指令回显 → 不采信，走占位', e.title == 'AI新书09171405', e.title);
  check('containsConceptInstructionMarker 命中「书名」',
      containsConceptInstructionMarker('书名：x'), 'ok');
  check('containsConceptInstructionMarker 命中 EXACTLY',
      containsConceptInstructionMarker('Output EXACTLY three lines'), 'ok');
  check('containsConceptInstructionMarker 命中 Assistant 前缀',
      containsConceptInstructionMarker('Assistant: 好的'), 'ok');
  check('普通正文不误判',
      !containsConceptInstructionMarker('异界战神'), 'ok');

  print('');
  print('=' * 78);
  print('[6] 清洗规则（合法字符集 / 截断 60 / 非法文件名字符）');
  print('=' * 78);
  check('书名号《》被剥',
      cleanConceptValue('《异界战神》') == '异界战神', cleanConceptValue('《异界战神》'));
  check('斜杠换下划线（真机「东方玄幻 / 末世重生」）',
      cleanConceptValue('东方玄幻 / 末世重生') == '东方玄幻 _ 末世重生',
      cleanConceptValue('东方玄幻 / 末世重生'));
  check('冒号换下划线',
      cleanConceptValue('A:B') == 'A_B', cleanConceptValue('A:B'));
  check('超 60 字截断',
      cleanConceptValue('甲' * 80).length == 60,
      '${cleanConceptValue('甲' * 80).length}');
  check('行首装饰符被剥（cleanConceptValue 自身也要能剥 >）',
      cleanConceptValue('>异界战神') == '异界战神', cleanConceptValue('>异界战神'));

  print('');
  print('=' * 78);
  print('[7] labelValue 语义边界');
  print('=' * 78);
  check('命中返回值', labelValue('书名：甲', <String>['书名']) == '甲', 'ok');
  check('label 后无冒号 → null',
      labelValue('书名 甲', <String>['书名']) == null, 'null');
  check('label 在中间 → null（必须行首）',
      labelValue('新书名：甲', <String>['书名']) == null, 'null');
  check('多 label 候选（简介/梗概）',
      labelValue('梗概：乙', <String>['简介', '梗概']) == '乙', 'ok');
  check('空值 → 空串（不是 null）',
      labelValue('书名：', <String>['书名']) == '', 'ok');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}