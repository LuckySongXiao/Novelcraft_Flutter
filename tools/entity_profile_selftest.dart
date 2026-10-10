// 分卷档案归纳自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/entity_profile_selftest.dart
//
// 只覆盖**纯函数**部分（流水筛选、关键事件合并、防幻觉判据、JSON 平衡扫描）——
// 需要模型与数据库的链路不在本脚本范围内。
//
// 这几个函数的正确性直接决定档案质量：
//   * `volumeEntries` 错 → 归纳到别卷的剧情，档案串味；
//   * `mergeVolumeKeyEvents` 不幂等 → 反复归纳让字段无限膨胀；
//   * `isGrounded` 失效 → 小模型编造的设定被写进正式档案。
import '../lib/ai/utils/profile_synthesis_text.dart';

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

void eqList(String name, List<String> got, List<String> want) {
  check(
    name,
    got.length == want.length &&
        List<int>.generate(got.length, (int i) => i).every(
          (int i) => got[i] == want[i],
        ),
    detail: 'want=$want\n  got =$got',
  );
}

void eqStr(String name, String got, String want) {
  check(name, got == want, detail: 'want=«$want»\n  got =«$got»');
}

void main() {
  print('===== A. volumeEntries：只取本卷流水 =====');

  const String history =
      '[c1:1 第1卷·第1章·《血色契约》] 薇拉与艾登完成地下交易\n'
      '[c2:1 第1卷·第2章·《断线》] 薇拉右臂受伤\n'
      '[c9:1 第2卷·第1章·《归途》] 薇拉晋级二阶\n'
      '散装笔记，没有章节标记\n';

  eqList(
    'A1 只抽出本卷两行（别卷行与无标记行丢弃）',
    ProfileSynthesisText.volumeEntries(history, <String>{'c1', 'c2'}),
    <String>[
    '薇拉与艾登完成地下交易',
    '薇拉右臂受伤',
  ]);

  eqList('A2 换一批章节 id → 抽出另一卷', ProfileSynthesisText.volumeEntries(
    history,
    <String>{'c9'},
  ), <String>['薇拉晋级二阶']);

  eqList(
    'A3 空 history → 空',
    ProfileSynthesisText.volumeEntries(null, <String>{'c1'}),
    <String>[],
  );

  eqList(
    'A4 章节集合为空 → 空（不把整本书的流水都算进来）',
    ProfileSynthesisText.volumeEntries(history, <String>{}),
    <String>[],
  );

  eqList(
    'A5 前缀被剥掉，只剩内容（归纳模型看不到 chapterId 噪声）',
    ProfileSynthesisText.volumeEntries(
      '[c1:3 第1卷·第1章·《血色契约》] 状态：重伤濒死',
      <String>{'c1'},
    ),
    <String>['状态：重伤濒死'],
  );

  print('');
  print('===== B. mergeVolumeKeyEvents：跨卷累积、同卷幂等 =====');

  eqStr(
    'B1 首次归纳（current 为空）',
    ProfileSynthesisText.mergeVolumeKeyEvents('', 1, <String>[
      '初见艾登',
      '拿到血色契约',
    ]),
    '【第1卷】初见艾登；拿到血色契约',
  );

  eqStr(
    'B2 第二卷累积在已有段之后',
    ProfileSynthesisText.mergeVolumeKeyEvents(
      '【第1卷】初见艾登；拿到血色契约',
      2,
      <String>['重伤逃亡'],
    ),
    '【第1卷】初见艾登；拿到血色契约\n【第2卷】重伤逃亡',
  );

  eqStr(
    'B3 同卷重复归纳 → 替换该卷段（幂等的关键，否则每跑一次长一段）',
    ProfileSynthesisText.mergeVolumeKeyEvents(
      '【第1卷】初见艾登；拿到血色契约',
      1,
      <String>['初见艾登（修订）', '契约被毁'],
    ),
    '【第1卷】初见艾登（修订）；契约被毁',
  );

  eqStr(
    'B4 重跑第一卷不影响第二卷的段',
    ProfileSynthesisText.mergeVolumeKeyEvents(
      '【第1卷】旧内容\n【第2卷】重伤逃亡',
      1,
      <String>['新内容'],
    ),
    '【第2卷】重伤逃亡\n【第1卷】新内容',
  );

  eqStr(
    'B5 空白行被清理，不产生空洞',
    ProfileSynthesisText.mergeVolumeKeyEvents(
      '【第1卷】A\n\n\n',
      2,
      <String>['B'],
    ),
    '【第1卷】A\n【第2卷】B',
  );

  print('');
  print('===== C. isGrounded：防幻觉闸门 =====');

  check(
    'C1 归纳文本能在流水里找到依据 → 放行',
    ProfileSynthesisText.isGrounded(
      '薇拉获得了血色契约',
      '薇拉与艾登完成地下交易，血色契约随即生效',
    ),
  );

  check(
    'C2 整句都是模型自创设定 → 拦下',
    !ProfileSynthesisText.isGrounded(
      '他其实是上古神族的后裔',
      '薇拉与艾登完成地下交易，血色契约随即生效',
    ),
  );

  check(
    'C3 语料为空时不误杀（新实体没有现有档案可比对）',
    ProfileSynthesisText.isGrounded('任意文本', ''),
  );

  check('C4 空文本 → 拦下', !ProfileSynthesisText.isGrounded('   ', '语料'));

  check(
    'C5 专有名词命中即可（不必整句复述）',
    ProfileSynthesisText.isGrounded(
      '具备操控影子的能力',
      '薇拉发现自己的影子可以独立行动',
    ),
  );

  print('');
  print('===== D. parseObject：平衡扫描 JSON =====');

  final Map<String, dynamic>? d1 = ProfileSynthesisText.parseJsonObject(
    '好的，以下是结果：\n'
    '{"personality":"冷静克制","key_events":["初见艾登"]}\n'
    '希望对你有帮助。',
  );
  check(
    'D1 剥掉前后废话，取出 JSON',
    d1 != null && d1['personality'] == '冷静克制',
    detail: 'got=$d1',
  );

  final Map<String, dynamic>? d2 = ProfileSynthesisText.parseJsonObject(
    '{"personality":"说话喜欢用「」括号，还有 { } 符号"}',
  );
  check(
    'D2 字符串里的花括号不破坏平衡扫描',
    d2 != null && d2['personality'] == '说话喜欢用「」括号，还有 { } 符号',
    detail: 'got=$d2',
  );

  final Map<String, dynamic>? d3 = ProfileSynthesisText.parseJsonObject(
    '{"a":"引号里有个 \\" 转义"}',
  );
  check('D3 转义引号不破坏扫描', d3 != null && d3['a'] == '引号里有个 " 转义',
      detail: 'got=$d3');

  check(
    'D4 完全没有 JSON → null',
    ProfileSynthesisText.parseJsonObject('很抱歉，我无法完成这个任务。') == null,
  );

  check(
    'D5 半截 JSON → null（不返回半个对象）',
    ProfileSynthesisText.parseJsonObject('{"personality":"冷静') == null,
  );

  print('');
  print('===== E. 字段规格自洽性 =====');

  check(
    'E1 规格表的列名都是 snake_case（写成 Dart 名会静默取不到值）',
    kProfileSpec.values
        .expand((List<String> cols) => cols)
        .every((String c) => c == c.toLowerCase() && !c.contains(RegExp(r'[A-Z]'))),
  );

  check(
    'E2 没有把 history / status 列列入归纳目标（前者是证据链，后者按章维护）',
    kProfileSpec.values.expand((List<String> c) => c).every(
          (String c) => c != 'history' && c != 'status',
        ),
  );

  check(
    'E3 关键事件列名与人物规格一致',
    !kProfileSpec.containsKey('character') ||
        kKeyEventsColumn == 'key_events',
  );

  check(
    'E4 每个可归纳列都有中文说明（否则提示词里会出现裸列名）',
    kProfileSpec.values.expand((List<String> c) => c).every(
          (String c) => (kProfileFieldLabels[c] ?? '')
              .trim()
              .isNotEmpty,
        ),
  );

  print('');
  print('===============================');
  print('pass=$pass  fail=$fail');
  if (fail > 0) {
    print('SELFTEST FAILED');
  } else {
    print('SELFTEST OK');
  }
}
