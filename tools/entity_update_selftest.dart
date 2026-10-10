// 设定抽取文本规则自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/entity_update_selftest.dart
//
// 覆盖 `lib/ai/utils/entity_update_text.dart`（纯 Dart）。这些规则错了的后果
// 非常具体 —— 2026-10-09 真机复现过：
//   * `evidenceSharesText` 太严（旧版要求**连续子串**）→ 7B 的拼接引用条条被判非法
//     → 整章 0 条设定，用户看到「章节写完了，人物/世界观一个字没更新」；
//   * `pipeRowCells` 不剥行首 `|` → Markdown 表格行被整行丢弃 → 行式兜底等于没跑。
import '../lib/ai/utils/entity_update_text.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, {String detail = ''}) {
  if (ok) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name${detail.isEmpty ? '' : '\n  $detail'}');
  }
}

void eqStr(String name, String got, String want) {
  check(name, got == want, detail: 'want=«$want»\n  got =«$got»');
}

void eqInt(String name, int got, int want) {
  check(name, got == want, detail: 'want=$want got=$got');
}

void main() {
  print('===== A. stripEvidencePrefix =====');

  eqStr('A1 中文冒号前缀', stripEvidencePrefix('正文：她重生回到三个月前'), '她重生回到三个月前');
  eqStr('A2 半角冒号前缀', stripEvidencePrefix('原文:林晚握紧了小刀'), '林晚握紧了小刀');
  eqStr('A3 英文前缀', stripEvidencePrefix('Evidence: 林晚握紧了小刀'), '林晚握紧了小刀');
  eqStr('A4 前缀可叠加', stripEvidencePrefix('正文：quote: 林晚握紧了小刀'), '林晚握紧了小刀');
  eqStr('A5 无前缀原样返回', stripEvidencePrefix('林晚握紧了小刀'), '林晚握紧了小刀');
  eqStr('A6 只有前缀也不崩', stripEvidencePrefix('正文：'), '正文：');
  eqStr('A7 首尾空白被裁', stripEvidencePrefix('   正文：  林晚  '), '林晚');

  print('===== B. evidenceSharesText =====');

  const String src = '夜幕降临时，林晚握紧了口袋里的小刀，她不是医生，却记得那些伤口。'
      '维克拉姆警官站在门口，脸上带着疲惫与焦虑。';

  check('B1 完整连续子串命中', evidenceSharesText('林晚握紧了口袋里的小刀', src));
  check('B2 带前缀的连续子串命中', evidenceSharesText('正文：林晚握紧了口袋里的小刀', src));
  check(
    'B3 拼接引用（7B 实际形态）命中',
    evidenceSharesText(
      '正文：夜幕降临时，林晚握紧了口袋里的小刀。[...] 维克拉姆警官站在门口，脸上带着疲惫与焦虑。',
      src,
    ),
  );
  check('B4 全部是编造内容 → 不命中',
      !evidenceSharesText('张三在纽约的实验室里调试量子计算机', src));
  check('B5 空 evidence → 不命中', !evidenceSharesText('   ', src));
  check('B6 只有前缀 → 不命中', !evidenceSharesText('正文：', src));
  // 单字碎片（<8 字）不足以作为依据 —— 防「拿一个常用词冒充证据」。
  check('B7 过短碎片不算依据', !evidenceSharesText('她不是医生', '完全不同的一段毫无关联的正文内容'));
  check('B8 中文逗号分段后命中', evidenceSharesText('毫不相关的一堆话，维克拉姆警官站在门口，又是无关内容', src));
  check('B9 换行分段后命中', evidenceSharesText('无关\n维克拉姆警官站在门口\n无关', src));

  print('===== C. pipeRowCells =====');

  List<String> r = pipeRowCells('人物|林晚|状态|成为庇护所组织者')!;
  eqInt('C1 裸行 4 段', r.length, 4);
  eqStr('C1b 首段=人物', r[0], '人物');
  eqStr('C1c 末段=变化', r[3], '成为庇护所组织者');

  // 🔴 本轮正主：7B 实际输出的 Markdown 表格行
  r = pipeRowCells('|人物|林晚|状态|成为庇护所组织者|')!;
  eqInt('C2 Markdown 表格行不再被丢弃', r.length, 4);
  eqStr('C2b 行首 | 被剥掉', r[0], '人物');
  eqStr('C2c 行尾 | 被剥掉', r[3], '成为庇护所组织者');

  eqStr('C3 表头行被剥成 4 段（由调用方按类别白名单再筛）',
      pipeRowCells('|类别|名称|字段|一句话变化|')!.first, '类别');

  check('C4 分隔线行被忽略', pipeRowCells('|---|---|---|---|') == null);
  check('C5 冒号对齐分隔线被忽略', pipeRowCells('|:---|:--:|---:|') == null);
  check('C6 空行被忽略', pipeRowCells('   ') == null);
  check('C7 表格边框空行被忽略', pipeRowCells('||') == null);

  r = pipeRowCells('- 人物｜林晚｜状态｜成为庇护所组织者')!;
  check('C8 列表符号 + 全角竖线',
      r.length == 4 && r[1] == '林晚', detail: 'got=$r');

  r = pipeRowCells('> 人物|林晚|状态|成为庇护所组织者')!;
  eqStr('C9 引用符号前缀（模型实际会吐 `>`）', r[0], '人物');

  r = pipeRowCells('3. 人物|林晚|状态|成为庇护所组织者')!;
  eqStr('C10 有序列表序号前缀', r[0], '人物');

  r = pipeRowCells('人物|林晚|||')!;
  eqInt('C11 中间空段保留（漏写字段交由调用方判非法）', r.length, 2);

  r = pipeRowCells('|人物|林晚|状态|变化里|含竖线|')!;
  eqInt('C12 变化列里的 | 由调用方 join 还原', r.length, 5);

  print('===============================');
  print('pass=$pass  fail=$fail');
  if (fail > 0) {
    print('SELFTEST FAILED');
    throw StateError('$fail case(s) failed');
  }
  print('SELFTEST OK');
}
