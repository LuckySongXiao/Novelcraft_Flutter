// ignore_for_file: avoid_print
//
// AI 输出字段解析原语验证（对应 C# `AiAutoFillFormatter` + 修炼体系板块解析）。
//
// `ai_text_fields.dart` 只依赖 Dart 核心库 ⇒ 纯 Dart ⇒ 能在这里真跑。
//
// 校验项：
//   [1] splitNumberedLevelBlocks：三种编号形态（`N.` 独立行 / `N. 内容` 行内 / `N)` `N、`）
//   [2] extractSection：`X：值` / `【X】` / `X ` 空格 / 整行等于 X；遇空行或下个标题即停
//   [3] 防误取：缺字段时不允许把整段首行当值（hasFieldPrefix 校验）
//   [4] parseCultivationSection：中文 / 英文完整样本；体系名缺失或等级 <2 → isValid=false
//   [5] 编号行必须**未被清洗掉**才能切块（对照组：剥掉编号后只剩 1 块）
//
// 运行：dart run tool/verify_ai_text_fields.dart
import 'dart:io';

import 'package:novelcraft/ai/utils/ai_text_fields.dart';

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

/// 中文原始输出样本（与 C# 模板要求的结构一致，含前后赘语用于验证 header 提取）。
const String zhSample = '''
好的，我为您设计了这套体系。

【修炼体系】
体系名称：九曜天罡道
体系类型：星辰修炼
修炼方法：以星辉淬体，引九曜之力入窍，逐曜点亮本命星轨。

1.
等级名：星启
描述：初引星辉入门，感应第一缕星光。
突破条件：静心三年，凝出星核。
能力特点：夜视、感知星象。

2.
等级名：曜环
描述：星核凝成曜环，气机自生。
突破条件：承受一次星潮冲击。
能力特点：星辉外放，可御星器。

3.
等级名：天罡
描述：九曜归位，罡气护体。
突破条件：点亮三曜星轨并渡一次星劫。
能力特点：星罡不灭，寿元大增。
''';

/// 英文原始输出样本。
const String enSample = '''
【Cultivation System】
System Name: Emberforge Path
System Type: Forge Cultivation
Cultivation Method: Temper the body in living embers, kindling an inner forge.

1.
Rank Name: Spark
Description: The first ember is kindled within.
Breakthrough Condition: Endure the first forge-night.
Ability Features: Heat resistance.

2.
Rank Name: Bellows
Description: Breath becomes a forge-bellows.
Breakthrough Condition: Survive a magma delve.
Ability Features: Ember exhalation.
''';

/// 行内编号形态（`1. 等级名：X`）。
const String inlineNumberedSample = '''
【修炼体系】
体系名称：云海剑典
体系类型：剑修
修炼方法：以云气养剑。

1. 等级名：听风
描述：初闻剑鸣。
突破条件：斩断一缕云气。
能力特点：剑感。

2. 等级名：御风
描述：剑气可御。
突破条件：连斩十日不歇。
能力特点：御剑飞行。
''';

void main() {
  print('=' * 78);
  print('[1] splitNumberedLevelBlocks（三种编号形态）');
  print('=' * 78);
  final List<String> blocks = AiTextFields.splitNumberedLevelBlocks(zhSample);
  // 注意：样本没有「独立编号行」，所以整段（含 header）都算 levelsPart，
  // 于是切出「1 个 header 块 + 3 个等级块」= 4。这与 C# 行为一致
  // （C# 的正则也只认独立编号行），等级块靠"没有等级名"被 parse 自然丢弃。
  check('中文样本切出 4 块（1 个 header 块 + 3 个等级块）', blocks.length == 4,
      '${blocks.length}');
  check('第 2 块以「等级名：星启」开头（header 块之后）',
      blocks.length >= 2 && blocks[1].startsWith('等级名：星启'),
      blocks.length < 2 ? '-' : blocks[1].split('\n').first);
  check('第 4 块含「能力特点」',
      blocks.length >= 4 && blocks[3].contains('能力特点'), 'ok');

  final List<String> inlineBlocks =
      AiTextFields.splitNumberedLevelBlocks(inlineNumberedSample);
  check('行内编号样本切出 3 块（header 块 + 2 等级块）', inlineBlocks.length == 3,
      '${inlineBlocks.length}');
  check('行内编号内容被保留在块首（第 2 块）',
      inlineBlocks.length >= 2 && inlineBlocks[1].startsWith('等级名：听风'),
      inlineBlocks.length < 2 ? '-' : inlineBlocks[1].split('\n').first);

  final List<String> parenBlocks = AiTextFields.splitNumberedLevelBlocks(
      '1) 等级名：甲\n描述：d\n\n2、等级名：乙\n描述：e');
  check('N) 与 N、 形态都识别', parenBlocks.length == 2, '${parenBlocks.length}');

  check('空输入 → 空列表',
      AiTextFields.splitNumberedLevelBlocks(null).isEmpty &&
          AiTextFields.splitNumberedLevelBlocks('   ').isEmpty,
      'ok');

  print('');
  print('=' * 78);
  print('[2] extractSection（四种命中形态 + 终止条件）');
  print('=' * 78);
  check('`X：值` 形态',
      AiTextFields.extractSection('体系名称：九曜天罡道', <String>['体系名称']) ==
          '九曜天罡道',
      'ok');
  check('`【X】` 形态 + 值在下一行',
      AiTextFields.extractSection('【体系名称】\n九曜天罡道', <String>['体系名称']) ==
          '九曜天罡道',
      'ok');
  check('`X ` 空格形态',
      AiTextFields.extractSection('System Name Emberforge Path',
              <String>['System Name']) ==
          'Emberforge Path',
      'ok');
  check('整行等于 X（返回空串 → extractSection 判 null）',
      AiTextFields.extractSection('体系名称', <String>['体系名称']) == null,
      'null');
  check('多行值收集到下一个标题为止',
      AiTextFields
              .extractSection('描述：第一行\n第二行\n等级名：甲', <String>['描述']) ==
          '第一行\n第二行',
      'ok');
  check('遇空行停止收集',
      AiTextFields.extractSection('描述：第一行\n\n第二行', <String>['描述']) == '第一行',
      'ok');
  check('未命中 → null',
      AiTextFields.extractSection('无关文本', <String>['描述']) == null, 'null');
  check('空输入 → null',
      AiTextFields.extractSection('', <String>['描述']) == null, 'null');
  check('候选标题按顺序命中第一个存在的',
      AiTextFields.extractSection('名称：甲', <String>['体系名称', '名称']) == '甲',
      'ok');
  check('逐行扫描：先出现的行优先，不是候选顺序优先',
      AiTextFields.extractSection('类型：乙\n体系名称：甲',
              <String>['体系名称', '类型']) ==
          '乙',
      '乙');

  print('');
  print('=' * 78);
  print('[3] 防误取（hasFieldPrefix / cleanFieldValue）');
  print('=' * 78);
  check('hasFieldPrefix 命中',
      AiTextFields.hasFieldPrefix('体系名称：甲', <String>['体系名称']), 'ok');
  check('hasFieldPrefix 未命中（整段首行不该当值）',
      !AiTextFields.hasFieldPrefix('随便一段文字', <String>['体系名称']), 'ok');
  check('cleanFieldValue 剥掉 `体系名称：` 前缀',
      AiTextFields.cleanFieldValue('体系名称：甲', <String>['体系名称']) == '甲',
      'ok');
  check('cleanFieldValue 剥掉 `【体系名称】：` 前缀',
      AiTextFields.cleanFieldValue('【体系名称】：甲', <String>['体系名称']) == '甲',
      'ok');
  check('cleanFieldValue 剥掉行首装饰符',
      AiTextFields.cleanFieldValue('- 甲', <String>['体系名称']) == '甲', 'ok');
  check('extractSingleLineValue 取首个非空行',
      AiTextFields.extractSingleLineValue('体系名称：甲\n乙',
              <String>['体系名称']) ==
          '甲',
      'ok');

  print('');
  print('=' * 78);
  print('[4] parseCultivationSection（中文 / 英文 / 行内编号 / 失败样本）');
  print('=' * 78);
  final ParsedCultivationSection zh =
      AiTextFields.parseCultivationSection(zhSample, isEnglish: false);
  check('中文：体系名', zh.name == '九曜天罡道', zh.name);
  check('中文：体系类型', zh.type == '星辰修炼', zh.type);
  check('中文：修炼方法非空', (zh.method ?? '').contains('星辉'), '${zh.method}');
  check('中文：等级数 = 3', zh.levels.length == 3, '${zh.levels.length}');
  check('中文：等级名顺序正确',
      zh.levels.map((ParsedCultivationLevel l) => l.name).join(',') ==
          '星启,曜环,天罡',
      zh.levels.map((ParsedCultivationLevel l) => l.name).join(','));
  check('中文：首级描述/突破/能力齐全',
      zh.levels[0].description == '初引星辉入门，感应第一缕星光。' &&
          zh.levels[0].breakthrough == '静心三年，凝出星核。' &&
          zh.levels[0].abilities == '夜视、感知星象。',
      'ok');
  check('中文：isValid', zh.isValid, 'ok');

  final ParsedCultivationSection en =
      AiTextFields.parseCultivationSection(enSample, isEnglish: true);
  check('英文：体系名', en.name == 'Emberforge Path', en.name);
  check('英文：等级数 = 2 / 等级名正确',
      en.levels.length == 2 && en.levels[1].name == 'Bellows',
      '${en.levels.length}')
  ;
  check('英文：isValid', en.isValid, 'ok');

  final ParsedCultivationSection inline =
      AiTextFields.parseCultivationSection(inlineNumberedSample,
          isEnglish: false);
  check('行内编号样本：等级数 = 2', inline.levels.length == 2,
      '${inline.levels.length}');
  check('行内编号样本：首级名 = 听风',
      inline.levels.isNotEmpty && inline.levels[0].name == '听风', 'ok');

  final ParsedCultivationSection noName = AiTextFields.parseCultivationSection(
      '1.\n等级名：甲\n\n2.\n等级名：乙',
      isEnglish: false);
  check('体系名缺失 → name 为空（调用方判失败）', noName.name.isEmpty, '空');
  check('体系名缺失 → isValid=false', !noName.isValid, 'false');
  check('体系类型缺失 → 回落默认（中文「通用」）', noName.type == '通用', noName.type);

  final ParsedCultivationSection oneLevel =
      AiTextFields.parseCultivationSection('体系名称：甲\n\n1.\n等级名：乙',
          isEnglish: false);
  check('等级数 <2 → isValid=false', !oneLevel.isValid, '${oneLevel.levels.length}');

  check('英文模式类型缺失 → 回落 General',
      AiTextFields.parseCultivationSection('System Name: X', isEnglish: true)
              .type ==
          'General',
      'ok');

  print('');
  print('=' * 78);
  print('[5] 对照：编号被清洗掉 → 只剩 1 块（证明"必须用原始文本"）');
  print('=' * 78);
  final String stripped = zhSample
      .split('\n')
      .map((String l) => l.replaceFirst(RegExp(r'^\d+[.)、]\s*'), ''))
      .where((String l) => l.trim().isNotEmpty)
      .join('\n');
  final List<String> strippedBlocks =
      AiTextFields.splitNumberedLevelBlocks(stripped);
  check('剥掉编号行后只切出 1 块（等级 1..3 结构丢失）',
      strippedBlocks.length == 1, '${strippedBlocks.length}');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}