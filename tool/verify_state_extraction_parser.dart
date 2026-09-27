// ignore_for_file: avoid_print
//
// AI 状态抽取解析器验证（state_extraction_parser.dart，纯 Dart 可直接跑）—— 功能 C 二级。
//
// 样本对齐 RWKV 7B 真机行为：JSON 外套话、markdown 围栏、提示词回显、
// 单引号 JSON、幻觉长名、空数组。
//
// 运行：dart run tool/verify_state_extraction_parser.dart
import 'dart:io';

import 'package:novelcraft/ai/utils/state_extraction_parser.dart';

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

const String cleanSample =
    '{"characters":[{"name":"林轩","status":"重伤","location":"青云宗后山"}],'
    '"factions":[{"name":"天魔宫","status":"蛰伏"}],'
    '"worldSettings":[{"name":"灵石经济","change":"灵石价格暴涨"}],'
    '"plots":[{"title":"青云宗覆灭","change":"伏笔埋下"}]}';

void main() {
  print('=' * 78);
  print('[1] 干净 JSON：四类全部解析');
  print('=' * 78);
  final StateExtractionResult? r1 = parseStateExtraction(cleanSample);
  check('解析成功', r1 != null, '${r1?.total}');
  check('人物 1 条', r1?.characters.length == 1, '${r1?.characters.length}');
  check('人物 status/location 正确',
      r1?.characters.single.status == '重伤' &&
          r1?.characters.single.location == '青云宗后山',
      '${r1?.characters.single.status}/${r1?.characters.single.location}');
  check('势力 1 条', r1?.factions.length == 1, '${r1?.factions.length}');
  check('设定 change 正确', r1?.worldSettings.single.change == '灵石价格暴涨',
      '${r1?.worldSettings.single.change}');
  check('剧情按 title 解析', r1?.plots.single.name == '青云宗覆灭',
      '${r1?.plots.single.name}');

  print('');
  print('=' * 78);
  print('[2] JSON 外套话 + markdown 围栏（7B 真机常态）');
  print('=' * 78);
  final StateExtractionResult? r2 = parseStateExtraction(
      '好的，以下是抽取结果：\n```json\n$cleanSample\n```\n希望对你有帮助。');
  check('围栏 + 套话仍能解析', r2?.total == 4, '${r2?.total}');

  print('');
  print('=' * 78);
  print('[3] 提示词回显污染：条目名含指令标记 → 整条丢弃');
  print('=' * 78);
  final StateExtractionResult? r3 = parseStateExtraction(
      '{"characters":[{"name":"人物名","status":"当前状态"},'
      '{"name":"林轩","status":"突破"}],'
      '"factions":[],"worldSettings":[],"plots":[]}');
  check('回显条目被滤掉，只剩真实条目', r3?.characters.length == 1 &&
      r3?.characters.single.name == '林轩',
      '${r3?.characters.length}');

  print('');
  print('=' * 78);
  print('[4] 单引号 JSON 修复');
  print('=' * 78);
  final StateExtractionResult? r4 = parseStateExtraction(
      "{'characters':[{'name':'林轩','status':'闭关'}],"
      "'factions':[],'worldSettings':[],'plots':[]}");
  check('单引号仍能解析', r4?.characters.single.status == '闭关',
      '${r4?.characters.single.status}');

  print('');
  print('=' * 78);
  print('[5] 坏输出：不崩、返回 null');
  print('=' * 78);
  check('空串 → null', parseStateExtraction('') == null, 'null');
  check('null → null', parseStateExtraction(null) == null, 'null');
  check('纯文本 → null',
      parseStateExtraction('我觉得这章写得不错。') == null, 'null');
  check('半截 JSON → null',
      parseStateExtraction('{"characters":[{"name":"林轩"') == null, 'null');

  print('');
  print('=' * 78);
  print('[6] 幻觉防护：超长名丢弃 / 装饰符剥离 / 字段截断');
  print('=' * 78);
  final StateExtractionResult? r6 = parseStateExtraction(
      '{"characters":[{"name":"> * 林轩","status":"${"长" * 300}"},'
      '{"name":"${"幻" * 60}","status":"幻觉"}],'
      '"factions":[],"worldSettings":[],"plots":[]}');
  check('首条 name 装饰符被剥离', r6?.characters.first.name == '林轩',
      '${r6?.characters.first.name}');
  check('超长 status 截断到 200',
      (r6?.characters.first.status?.length ?? 0) == 200,
      '${r6?.characters.first.status?.length}');
  check('60 字幻觉名被丢弃', r6?.characters.length == 1, '${r6?.characters.length}');

  print('');
  print('=' * 78);
  print('[7] 空数组 / 空 name');
  print('=' * 78);
  final StateExtractionResult? r7 = parseStateExtraction(
      '{"characters":[],"factions":[{"name":"","status":"x"}],'
      '"worldSettings":[],"plots":[]}');
  check('全空 → isEmpty', r7 != null && r7.isEmpty, '${r7?.total}');

  print('');
  print('=' * 78);
  print('[8] 提示词构造：正文截断 4000 字');
  print('=' * 78);
  final String prompt =
      buildStateExtractionPrompt('第一章', 'a' * 5000);
  check('正文截断到 4000', prompt.length < 5000 + 200, '${prompt.length}');
  check('提示词含 JSON 模板', prompt.contains('"characters"'), 'ok');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
