// JSON 抢救扫描自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/json_scan_selftest.dart
//
// 覆盖 `lib/ai/utils/json_scan.dart`（纯 Dart）。它的四个消费方都是「模型输出
// 决定成败」的链路：设定抽取、档案归纳、拆书规则、审查留言。扫错了的后果是
// **整章产出被判为空**，而且失败是静默的 —— 所以这里把边界钉死。
//
// 本轮（2026-10-09）新增 `parseJsonArray` 与 `parseJsonPayload`。起因是审查
// 留言在模型那里有两种合法形态（`{"comments":[…]}` 与裸数组 `[{…}]`），
// 旧实现只认前者且用贪婪正则 `\{[\s\S]*\}` 取「第一个 `{` 到最后一个 `}`」，
// 正文里再出现一对花括号就整段截歪。
//
// ⚠ 关键语义（A11 / B5 / C 组专门锁这个）：
//   * `parseJsonObject` = 「任意位置找**对象**」→ `[{…}]` 会命中**内层对象**；
//   * `parseJsonArray`  = 「任意位置找**数组**」→ `{"comments":[…]}` 会命中**内层数组**；
//   * `parseJsonPayload` = 「**按最先出现的结构字符**决定顶层」→ 上两例分别拿到
//     外层对象 / 整个数组。**消费方要的是这一个**，用另两个拼 `??` 会取错层级。
import '../lib/ai/utils/json_scan.dart';

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

void main() {
  print('===== A. parseJsonObject（任意位置找对象）=====');

  check('A1 纯对象', parseJsonObject('{"a":1}')?['a'] == 1);
  check('A2 前后有散文',
      parseJsonObject('好的，以下是结果：\n{"a":2}\n希望对你有帮助')?['a'] == 2);
  check('A3 Markdown 围栏（无需预剥）',
      parseJsonObject('```json\n{"a":3}\n```')?['a'] == 3);
  check('A4 引用前缀 `>`', parseJsonObject('>{ "a": 4 }')?['a'] == 4);
  check(
      'A5 字符串里的花括号不干扰深度',
      parseJsonObject('{"text":"正文里出现 { 啊 } 还有 \\"引号\\"","ok":true}')?['ok'] ==
          true);
  check('A6 前面有非法平衡片段时换下一个起点',
      parseJsonObject('{a:1} 然后 {"b":5}')?['b'] == 5);
  check('A7 嵌套对象',
      (parseJsonObject('{"outer":{"inner":6}}')?['outer'] as Map?)?['inner'] == 6);
  check('A8 数组字段（混合括号）',
      (parseJsonObject('{"list":[1,2,{"x":7}]}')?['list'] as List?)?.length == 3);
  check('A9 半截 JSON → null', parseJsonObject('{"a":1') == null);
  check('A10 纯说明文字 → null', parseJsonObject('这里没有 JSON') == null);
  // 语义钉死：对象入口**只**认 `{}`，所以裸数组里会命中内层对象。
  // 需要「整个数组」请用 parseJsonPayload。
  check('A11 裸数组命中的是内层对象（语义如此）',
      parseJsonObject('[{"a":1}]')?['a'] == 1);
  check('A12 对象里包数组时取的是外层对象',
      parseJsonObject('{"comments":[{"a":1}]}')?['comments'] is List);
  // 非法片段里的 `[1]` 不该影响 `{}` 深度统计。
  check('A13 非法片段含方括号也不干扰对象扫描',
      parseJsonObject('{a: [1]} {"b":9}')?['b'] == 9);

  print('===== B. parseJsonArray（任意位置找数组）=====');

  check('B1 裸数组', parseJsonArray('[1,2,3]')?.length == 3);
  check('B2 对象数组', parseJsonArray('[{"a":1},{"a":2}]')?.length == 2);
  check('B3 前后有散文',
      parseJsonArray('结果如下：\n[{"severity":"error"}]\n以上')?.length == 1);
  check('B4 Markdown 围栏', parseJsonArray('```json\n[{"a":1}]\n```')?.length == 1);
  // 语义钉死：数组入口**只**认 `[]`，所以对象里包的数组会被它拿到。
  // 需要「外层对象」请用 parseJsonPayload。
  check('B5 对象里包数组时命中内层数组（语义如此）',
      parseJsonArray('{"comments":[{"a":1}]}')?.length == 1);
  check('B6 字符串里的方括号不干扰深度',
      parseJsonArray('["[ 不是数组 ]","x"]')?.length == 2);
  check('B7 半截数组 → null', parseJsonArray('[1,2') == null);
  check('B8 空数组合法', parseJsonArray('[]')?.isEmpty == true);
  check('B9 非法片段在前、真数组在后',
      parseJsonArray('{a:1} [2,3]')?.length == 2);
  check('B10 多维数组',
      (parseJsonArray('[[1,[2]]]')?.first as List?)?.length == 2);

  print('===== C. parseJsonPayload（按最先出现的结构字符定顶层）=====');

  Object? p(String raw) => parseJsonPayload(raw);

  // C1 是本轮的核心：模型给 `{"comments":[…]}` 时**必须**拿到外层对象，
  // 若被内层数组抢走，`decoded['comments']` 取不到 → 整章留言判「未产出」。
  final Object? c1 = p('{"comments":[]}');
  check('C1 对象形态拿到外层对象（不被内层数组抢走）',
      c1 is Map && ((c1)['comments'] as List?)?.isEmpty == true);

  // C2 反向：裸数组必须拿到**整个数组**，而不是它的第 0 个元素。
  final Object? c2 = p('[{"severity":"error"}]');
  check('C2 裸数组形态拿到整个数组（不被内层对象抢走）',
      c2 is List && c2.length == 1);

  final Object? c3 =
      p('{"comments":[{"quote":"他写下 { x } 这个符号"}]}');
  check('C3 正文里带花括号仍取到外层对象',
      c3 is Map && c3['comments'] is List && (c3['comments'] as List).length == 1);

  final Object? c4 = p('分析如下：\n{"comments":[{"a":1}]}\n完毕');
  check('C4 前后散文（对象）', c4 is Map && (c4['comments'] as List).length == 1);

  final Object? c5 = p('```json\n[{"a":1},{"a":2}]\n```');
  check('C5 围栏 + 裸数组', c5 is List && c5.length == 2);

  check('C6 完全没有 JSON → null', p('这里没有 JSON，只有一段说明。') == null);

  final Object? c7 = p('{a:1} 然后 [{"b":2}]');
  check('C7 非法片段在前时跳到下一个结构字符',
      c7 is List && c7.length == 1);

  final Object? c8 = p('{"a":{"b":[{"c":1}]}}');
  check('C8 深嵌套取最外层对象',
      c8 is Map &&
          ((c8['a'] as Map)['b'] as List).length == 1 &&
          (((c8['a'] as Map)['b'] as List).first as Map)['c'] == 1);

  final Object? c9 = p('{"note":"用 [ ] 与 { } 都行","n":1}');
  check('C9 字符串内同时含两种括号不影响顶层判定',
      c9 is Map && c9['n'] == 1);

  check('C10 空数组 → 空 List', p('[]') is List && (p('[]') as List).isEmpty);
  check('C11 空对象 → 空 Map', p('{}') is Map && (p('{}') as Map).isEmpty);

  final Object? c12 = p('[{"tags":["a","b"]}]');
  check('C12 数组里对象的数组字段不越级',
      c12 is List &&
          ((c12.first as Map)['tags'] as List).length == 2);

  print('===== D. 审查留言链路真实形态回归 =====');

  /// 复刻 `BookContentReviewService._parseComments` 的取值方式。
  List? comments(String raw) {
    final Object? decoded = parseJsonPayload(raw);
    if (decoded is List) return decoded;
    if (decoded is Map && decoded['comments'] is List) {
      return decoded['comments'] as List;
    }
    return null;
  }

  check('D1 对象包数组（3B 常见）', comments('{"comments":[{"a":1}]}')?.length == 1);
  check('D2 裸数组（13B 常见）',
      comments('[{"severity":"error","problem":"p","suggestion":"s"}]')?.length == 1);
  check(
      'D3 围栏 + 前置说明 + 反引号',
      comments('好的，以下是我的审读意见：\n```json\n'
                  '{"comments":[{"problem":"p","suggestion":"s"}]}\n```\n'
                  '希望有帮助')?.length == 1);
  check(
      'D4 quote 内花括号不影响整条留言解析',
      comments('{"comments":[{"problem":"p","suggestion":"s",'
              '"quote":"他说 { 这里有问题 }"}]}')?.length == 1);
  check('D5 拿不到列表时确实返回 null', comments('抱歉，我无法完成。') == null);

  print('===============================');
  print('pass=$pass  fail=$fail');
  if (fail > 0) {
    print('SELFTEST FAILED');
    throw StateError('$fail case(s) failed');
  }
  print('SELFTEST OK');
}
