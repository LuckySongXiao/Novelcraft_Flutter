// 大纲净化 / 结构化模块自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/outline_repair_selftest.dart
//
// 用例全部取材于 2026-10-10 实测：读用户真实库 `novelcraft.sqlite` 得到的污染值
// （`夜闯寡妇村` 9 个 NG 章的 summary / title），以及用真实解析器复现出来的同形串。
import '../lib/ai/utils/outline_repair_text.dart';

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

void ok(String name, bool cond, [String note = '']) {
  if (cond) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name${note.isEmpty ? '' : '  ($note)'}');
  }
}

void main() {
  print('=== A. stripMeta：剔除生产元信息 ===');

  // A1 —— 库里实际值：`第一章：祭祀之夜（700字）##`
  eq(
    'A1 行首中文数字章号 + 括号字数 + 行尾 ##',
    OutlineRepairText.stripMeta('第一章：祭祀之夜（700字）##'),
    '祭祀之夜',
  );

  // A2 —— 库里实际值：`暗流涌动（约500字）##`
  eq('A2 括号「约N字」+ 行尾 ##', OutlineRepairText.stripMeta('暗流涌动（约500字）##'), '暗流涌动');

  // A3 —— 库里实际值：`大纲：夜闯寡妇村（全卷第5章）##`
  eq(
    'A3 括号章号 + 行尾 ##',
    OutlineRepairText.stripMeta('大纲：夜闯寡妇村（全卷第5章）##'),
    '大纲：夜闯寡妇村',
  );

  // A4 —— 库里实际值：`第四章：新秩序之争（约500字）##`
  eq(
    'A4 阿拉伯章号 + 约N字',
    OutlineRepairText.stripMeta('第四章：新秩序之争（约500字）##'),
    '新秩序之争',
  );

  // A5 —— title 里的污染形态（`《暗流涌动（约600字` 去掉书名号后）
  eq(
    'A5 半截括号（约600字 —— 连左括号一起清掉',
    OutlineRepairText.stripMeta('暗流涌动（约600字'),
    '暗流涌动',
  );

  // A6 —— title 里的污染形态：`《第7/10章》`
  eq('A6 括号「第N/M章」', OutlineRepairText.stripMeta('（第7/10章）暗流涌动'), '暗流涌动');

  // A7 —— 裸字数提示（模型在大纲正文里写「约600字」）
  eq('A7 裸「约600字」', OutlineRepairText.stripMeta('本章推进主线，约600字'), '本章推进主线，');

  // A8 —— 「目标字数：4200字」这类显式字段
  eq('A8 目标字数字段', OutlineRepairText.stripMeta('目标字数：4200字'), '');

  // A9 —— Markdown 列表符 / 强调符 / 引用符一次清掉
  eq(
    'A9 Markdown 装饰',
    OutlineRepairText.stripMeta('- **本章目标**：陈三发出合作邀请\n> 备注：暗流'),
    '本章目标：陈三发出合作邀请\n备注：暗流',
  );

  // A10 —— 幂等：清两遍结果一致
  const String dirty = '## 第一章：祭祀之夜（700字）##';
  eq(
    'A10 幂等',
    OutlineRepairText.stripMeta(OutlineRepairText.stripMeta(dirty)),
    OutlineRepairText.stripMeta(dirty),
  );

  // A11 —— 全角括号 / 全角数字也要认
  eq('A11 全角括号与全角数字', OutlineRepairText.stripMeta('（約５００字）冲突'), '冲突');

  // A12 —— 正常文学文本不被误伤
  const String prose = '陈三在村长安排下向主角发出「合作」邀请，但主角识破其真实意图。';
  eq('A12 正常梗概不误伤', OutlineRepairText.stripMeta(prose), prose);

  print('');
  print('=== B. hasMetaDirt：残留检测 ===');
  ok('B1 括号字数被识别', OutlineRepairText.hasMetaDirt('X（约500字）'));
  ok('B2 括号章号被识别', OutlineRepairText.hasMetaDirt('X（全卷第5章）'));
  ok('B3 裸字数被识别', OutlineRepairText.hasMetaDirt('推进主线，约600字'));
  ok('B4 干净文本不报脏', !OutlineRepairText.hasMetaDirt('祭祀之夜：主角独自潜入祠堂'));

  print('');
  print('=== C. parse：结构化修订大纲 ===');

  const String typical = '''
【本章目标】主角识破陈三借刀杀人的意图，与猎人长老当面对质。
承接上文：上一章结尾主角拿到青铜面具的碎片。
2. 核心冲突：陈三掌握主角的把柄，用族人安危施压。
关键转折：小梅暗中递出陈三与村长勾结的证据。
章末钩子：村长的亲信在门外出现。
故事时间节点：第三日黄昏
出场人物：主角、陈三、小梅、猎人长老
''';
  final RepairedOutline? c1 = OutlineRepairText.parse(typical);
  ok('C1 典型输出可解析', c1 != null);
  eq('C1 goal', c1?.goal, '主角识破陈三借刀杀人的意图，与猎人长老当面对质。');
  eq('C1 carryOver', c1?.carryOver, '上一章结尾主角拿到青铜面具的碎片。');
  eq('C1 conflict', c1?.conflict, '陈三掌握主角的把柄，用族人安危施压。');
  eq('C1 turn', c1?.turn, '小梅暗中递出陈三与村长勾结的证据。');
  eq('C1 hook', c1?.hook, '村长的亲信在门外出现。');
  eq('C1 timeNode', c1?.timeNode, '第三日黄昏');
  eq('C1 characters', c1?.characters, '主角、陈三、小梅、猎人长老');
  eq('C1 isUsable', c1?.isUsable, true);

  // C2 —— 中文序号 + 括号序号 + 无冒号
  final RepairedOutline? c2 = OutlineRepairText.parse(
    '一、本章目标 主角逃出地窖\n（1）核心冲突 追兵堵住唯一出口',
  );
  eq('C2 中文序号/括号序号/无冒号 goal', c2?.goal, '主角逃出地窖');
  eq('C2 conflict', c2?.conflict, '追兵堵住唯一出口');

  // C3 —— 标签后面不是字段（`目标人物是X`）不能被误判成 goal
  final RepairedOutline? c3 = OutlineRepairText.parse('目标人物是陈三');
  ok(
    'C3 「目标人物是X」不作为字段行',
    c3 == null || c3.goal.isEmpty,
    'got goal=${c3?.goal}',
  );

  // C4 —— 同字段出现两次取首次
  final RepairedOutline? c4 = OutlineRepairText.parse('本章目标：A\n本章目标：B');
  eq('C4 重复字段取首次', c4?.goal, 'A');

  // C5 —— 一个字都没认出来 → null（调用方回落原文）
  ok('C5 纯散文返回 null', OutlineRepairText.parse('主角在地窖里醒来，四周一片漆黑。') == null);

  // C6 —— 只有一个 goal → 不可用（缺推进性字段）
  final RepairedOutline? c6 = OutlineRepairText.parse('本章目标：闯进祠堂');
  eq('C6 isUsable=false', c6?.isUsable, false);

  // C7 —— 解析前先清洗：标签行里带「（约600字）」不应污染字段值
  final RepairedOutline? c7 = OutlineRepairText.parse('本章目标：闯进祠堂（约600字）');
  eq('C7 字段值内不含字数提示', c7?.goal, '闯进祠堂');

  // C8 —— 空格分隔（无冒号）也要认
  final RepairedOutline? c8 = OutlineRepairText.parse('本章目标 闯进祠堂');
  eq('C8 空格分隔可解析', c8?.goal, '闯进祠堂');

  print('');
  print('=== D. render：渲染成写手可用的本章大纲 ===');
  final String rendered = OutlineRepairText.render(
    RepairedOutline(
      goal: '识破陈三的意图',
      conflict: '陈三以族人安危施压',
      hook: '村长亲信出现',
      timeNode: '第三日黄昏',
    ),
    targetWords: 3200,
  );
  ok('D1 含本章目标', rendered.contains('本章目标：识破陈三的意图'));
  ok('D2 含故事时间节点', rendered.contains('故事时间节点：第三日黄昏'));
  ok('D3 目标字数由程序写死且 ≥ 闸线', rendered.contains('不少于 3200 字'));
  ok('D4 空字段不渲染', !rendered.contains('关键转折：'));
  // 提示词用的渲染版本刻意带「篇幅」行，那一行本身就是元信息 —— 所以
  // 「无残渣」要在**写进 notes 的版本**（targetWords=0）上判。
  ok(
    'D5 落 notes 的版本无元信息残渣',
    !OutlineRepairText.hasMetaDirt(
      OutlineRepairText.render(RepairedOutline(goal: '识破陈三'), targetWords: 0),
    ),
  );

  final String renderedEn = OutlineRepairText.render(
    RepairedOutline(goal: 'Expose Chen San'),
    targetWords: 3200,
    english: true,
  );
  ok(
    'D6 英文模板',
    renderedEn.contains('Goal：Expose Chen San') &&
        renderedEn.contains('at least 3200 characters'),
  );

  // D7 —— targetWords <= 0 时不追加篇幅行（纯渲染场景）
  final String noLen = OutlineRepairText.render(
    RepairedOutline(goal: 'A'),
    targetWords: 0,
  );
  ok('D7 targetWords=0 不追加篇幅行', !noLen.contains('篇幅'));

  // D8 —— 渲染时二次净化：字段值里混进字数提示也要清掉
  final String dirtyField = OutlineRepairText.render(
    RepairedOutline(goal: '识破陈三（约600字）'),
    targetWords: 0,
  );
  ok(
    'D8 字段值二次净化',
    dirtyField.contains('本章目标：识破陈三') &&
        !OutlineRepairText.hasMetaDirt(dirtyField),
  );

  print('');
  print('=== E. toBrief：写入 chapters.summary 的一句话梗概 ===');
  eq(
    'E1 清洗 + 折叠空白',
    OutlineRepairText.toBrief('第一章：祭祀之夜（700字）##\n本章推进祭祀异象'),
    '祭祀之夜 本章推进祭祀异象',
  );
  eq(
    'E2 空串回落 fallback',
    OutlineRepairText.toBrief('   ', fallback: '第3章'),
    '第3章',
  );
  final String brief = OutlineRepairText.toBrief(
    '主角在祠堂里发现了刻着血脉纹路的青铜面具，并意识到这与自己的身世直接相关，'
    '随后被陈三的人发现。',
    maxChars: 40,
  );
  ok(
    'E3 限长且收在标点处',
    brief.length <= 40 && RegExp(r'[，,。！？；;、]$').hasMatch(brief),
    'got="$brief"',
  );
  ok(
    'E4 梗概里没有元信息残渣',
    !OutlineRepairText.hasMetaDirt(
      OutlineRepairText.toBrief('第四章：新秩序之争（约500字）## 小梅起义'),
    ),
  );

  print('');
  print('=== F. 标签复读剥净（+46：「本章目标：本章目标：」双层前缀） ===');

  // F1 —— parse 循环剥净复读标签：goal 值里不能再有「本章目标：」
  final RepairedOutline? f1 = OutlineRepairText.parse(
    '本章目标：本章目标：推进祭祀之夜的揭露\n核心冲突：族规与真相的撕扯',
  );
  ok(
    'F1 parse 剥净复读标签',
    f1 != null && f1.goal == '推进祭祀之夜的揭露',
    'got=${f1?.goal}',
  );

  // F2 —— parse 后 render 不产生双层前缀
  if (f1 != null) {
    final String f2 = OutlineRepairText.render(f1, targetWords: 0);
    ok(
      'F2 render 无双层前缀',
      f2.startsWith('本章目标：推进祭祀之夜的揭露') && !f2.contains('本章目标：本章目标：'),
      'got=$f2',
    );
  }

  // F3 —— 三层复读也剥净
  final RepairedOutline? f3 = OutlineRepairText.parse(
    '本章目标：本章目标：本章目标：推进揭露\n钩子：门在身后闩上',
  );
  ok('F3 三层复读剥净', f3 != null && f3.goal == '推进揭露', 'got=${f3?.goal}');

  // F4 —— stripFieldLabels：兜底路径整段清洗
  eq(
    'F4 兜底整段剥标签',
    OutlineRepairText.stripFieldLabels('本章目标：本章目标：推进祭祀之夜的揭露\n这一章要写祠堂夹层里的血书'),
    '推进祭祀之夜的揭露\n这一章要写祠堂夹层里的血书',
  );

  // F5 —— stripFieldLabels 幂等（剥过一遍再剥不变）
  final String f5in = '本章目标：推进揭露\n承接上文：香灰落在地';
  eq(
    'F5 stripFieldLabels 幂等',
    OutlineRepairText.stripFieldLabels(
      OutlineRepairText.stripFieldLabels(f5in),
    ),
    OutlineRepairText.stripFieldLabels(f5in),
  );

  // F6 —— 普通句子里的「目标」二字不被误剥（分隔符纪律仍在）
  eq(
    'F6 「目标明确：」不误剥',
    OutlineRepairText.stripFieldLabels('目标明确：要推进揭露'),
    '目标明确：要推进揭露',
  );

  // F7 —— 复读标签跨装饰形态（【本章目标】：本章目标：…）
  final RepairedOutline? f7 = OutlineRepairText.parse(
    '【本章目标】本章目标：推进揭露\n核心冲突：撕扯',
  );
  ok('F7 带装饰的复读标签剥净', f7 != null && f7.goal == '推进揭露', 'got=${f7?.goal}');

  print('');
  print('=== 结果：$pass 通过 / $fail 失败 ===');
  if (fail > 0) {
    // 非零退出码，方便串进门禁脚本。
    throw StateError('outline_repair_selftest: $fail failed');
  }
}
