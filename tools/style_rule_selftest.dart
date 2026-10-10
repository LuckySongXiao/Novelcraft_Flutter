// 文风规则模型自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/style_rule_selftest.dart
//
// 只覆盖**纯 Dart 部分**（规则集的渲染、序列化、库的增删启用）——
// 需要模型与数据库的拆书链路不在本脚本范围内（那部分靠
// `style_digest_selftest.dart` 覆盖采样与合并规则）。
//
// 这几个点错了的后果很具体：
//   * `toPromptBlock` 出错 → 注入提示词的是空串或乱码，模型完全收不到文风约束；
//   * `fromJson` 抛异常 → 用户点开「文风研读」页直接白屏；
//   * `active` 自愈缺失 → 界面上的「当前启用」下拉拿到一个不在候选里的值，
//     触发 DropdownButton 断言红屏（工程里已经踩过多次的坑）。
import '../lib/ai/utils/style_digest_text.dart' show kStyleAspectLabels;
import '../lib/application/services/style_rule.dart';

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

StyleRuleSet _sample() => const StyleRuleSet(
      id: 'r1',
      name: '众仙俯首',
      sourceLabel: '本地文件：众仙俯首.txt',
      createdAt: 1730000000,
      aspects: <String, String>{
        'perspective': '第三人称限知，视角紧贴主角',
        'sentence': '以短句为主，单句成段',
        'taboo': '不写「仿佛」「似乎」堆叠的模糊句',
      },
      techniques: <StyleTechnique>[
        StyleTechnique(
          category: '节奏与结构',
          title: '三段铺垫一章高潮',
          detail: '每章前两段铺陈、第三段起爆点。',
        ),
        StyleTechnique(
          category: '叙事技法',
          title: '信息差悬置',
          detail: '先给结果，再回填原因。',
        ),
      ],
      notes: '测试样本',
    );

void main() {
  print('===== A. toPromptBlock：注入提示词的渲染 =====');

  eqStr('A1 空规则集 → 空串（不能注入一堆空标题）',
      const StyleRuleSet().toPromptBlock(), '');

  final String block = _sample().toPromptBlock();
  check(
    'A2 维度行含中文维度名，不含裸键名',
    block.contains('叙事视角与人称：第三人称限知') && !block.contains('perspective：'),
    detail: block,
  );
  check(
    'A3 技法按大类分节且带【】标题',
    block.contains('【节奏与结构】') &&
        block.contains('- 三段铺垫一章高潮：每章前两段铺陈、第三段起爆点。'),
    detail: block,
  );
  check(
    'A4 分节顺序跟随 kStyleTechniqueCategories（叙事技法在节奏与结构之前）',
    block.indexOf('【叙事技法】') < block.indexOf('【节奏与结构】'),
    detail: block,
  );

  final String truncated = _sample().toPromptBlock(maxChars: 20);
  check(
    'A5 maxChars 截断生效（切在行边界，不留半句）',
    truncated.length <= 20 &&
        !truncated.endsWith('：') &&
        (truncated.isEmpty || !truncated.contains('\n') || !truncated.endsWith(' ')),
    detail: 'len=${truncated.length} got=«$truncated»',
  );

  final String en = _sample().toPromptBlock(
    labels: const <String, String>{'perspective': 'Perspective'},
  );
  check(
    'A6 labels 可覆盖（英文界面），未覆盖的键退回键名而不是丢失',
    en.contains('Perspective：') && en.contains('sentence：'),
    detail: en,
  );

  final String brief = _sample().toPromptBlockBrief();
  check(
    'A7 精简版不提技法清单，且把「禁忌表达」提到最前（截断时先保住它）',
    !brief.contains('【') && brief.trimLeft().startsWith('- 禁忌表达'),
    detail: brief,
  );
  final String briefLong = StyleRuleSet(
    aspects: <String, String>{
      for (final String k in kStyleAspectLabels.keys) k: '这一项写得非常长' * 40,
    },
  ).toPromptBlockBrief();
  check(
    'A8 精简版超长时仍保住首个维度（禁忌表达）而不是被切空',
    briefLong.contains('禁忌表达') && briefLong.length <= 800,
    detail: 'len=${briefLong.length}',
  );

  print('===== B. JSON 往返与容错解析 =====');

  final StyleRuleSet decoded =
      StyleRuleSet.fromJson(Map<String, dynamic>.from(_sample().toJson() as Map));
  eqStr('B1 往返保真：id/name/createdAt',
      '${decoded.id}|${decoded.name}|${decoded.createdAt}', 'r1|众仙俯首|1730000000');
  eqInt('B2 往返保真：维度数与技法数',
      decoded.aspects.length + decoded.techniques.length, 5);
  eqStr('B3 往返保真：技法 detail 未丢',
      decoded.techniques.first.detail, '每章前两段铺陈、第三段起爆点。');

  final StyleRuleSet unknown = StyleRuleSet.fromJson(<String, dynamic>{
    'id': 'x',
    'aspects': <String, Object?>{'perspective': '有值', 'madeUpKey': '应被丢弃'},
    'techniques': <Object?>[
      <String, Object?>{'title': '有效技法', 'detail': 'd', 'category': '叙事技法'},
      <String, Object?>{'title': '', 'detail': '无标题'},
      'not-a-map',
      <String, Object?>{'title': '无分类技法', 'detail': 'd'},
    ],
  });
  eqInt('B4 未知维度键被丢弃（否则 UI 出现无中文名的一级标题）',
      unknown.aspects.length, 1);
  eqInt('B5 空标题 / 非 Map 技法被丢弃', unknown.techniques.length, 2);
  eqInt('B6 createdAt 缺失 → 0（不抛异常）', unknown.createdAt, 0);

  final StyleRuleSet messy = StyleRuleSet.fromJson(<String, dynamic>{
    'id': 123,
    'aspects': 'not-a-map',
    'techniques': 'not-a-list',
    'createdAt': 'not-a-number',
  });
  check('B7 类型全错也不抛异常，且 id/index 降级为空',
      messy.id.isEmpty && messy.aspects.isEmpty && messy.techniques.isEmpty,
      detail: 'id=«${messy.id}» aspects=${messy.aspects} techniques=${messy.techniques}');

  eqInt('B8 techniquesByCategory 顺序跟随大类表（叙事技法排在节奏与结构前）',
      _sample().techniquesByCategory.keys.toList().indexOf('叙事技法'), 0);

  print('===== C. StyleRuleLibrary：增删启用 =====');

  const StyleRuleLibrary empty = StyleRuleLibrary();
  check('C1 空库 activeSetFor → null', empty.activeSetFor('p1') == null);

  final StyleRuleLibrary one = empty.upsert(_sample());
  eqInt('C2 upsert 新增', one.sets.length, 1);

  final StyleRuleSet other = _sample().copyWith(id: 'r2', name: '另一本');
  final StyleRuleLibrary two = one.upsert(other);
  eqStr('C3 upsert 新规则排最前（最近拆的在上面）', two.sets.first.id, 'r2');

  final StyleRuleLibrary replaced = two.upsert(_sample().copyWith(name: '改名'));
  eqInt('C4 同 id upsert 是替换而不是追加', replaced.sets.length, 2);
  eqStr('C5 替换后名字生效', replaced.byId('r1')!.name, '改名');

  final StyleRuleLibrary activated = two.activate('p1', 'r1');
  eqStr('C6 activate 后 activeSetFor 命中', activated.activeSetFor('p1')!.id, 'r1');
  eqStr('C7 activate 到别的规则会覆盖', activated.activate('p1', 'r2').activeSetFor('p1')!.id, 'r2');
  check('C8 activate 空串 = 取消启用', activated.activate('p1', '').activeSetFor('p1') == null);
  check('C9 activeSetFor 空 projectId → null', activated.activeSetFor('') == null);

  final StyleRuleLibrary removed = activated.remove('r1');
  eqInt('C10 remove 后 sets 减一', removed.sets.length, 1);
  check('C11 remove 同时清掉指向它的 active（否则悬空启用）',
      removed.activeSetFor('p1') == null && !removed.active.containsKey('p1'));

  final StyleRuleSet unusable =
      const StyleRuleSet(id: 'r9', name: '空规则集');
  check('C12 空规则集不算「已启用」（isUsable 为 false）',
      two.activate('p1', 'r9').upsert(unusable).activeSetFor('p1') == null);

  print('===== D. fromJson 自愈与规范化 =====');

  final StyleRuleLibrary healed = StyleRuleLibrary.fromJson(<String, dynamic>{
    'sets': <Object?>[_sample().toJson(), <String, Object?>{'name': '没有 id 的规则'}],
    'active': <String, Object?>{'p1': 'r1', 'p2': 'ghost', '': 'r1'},
  });
  eqInt('D1 没有 id 的规则被丢弃（无法被启用/删除）', healed.sets.length, 1);
  eqStr('D2 有效启用标记保留', healed.active['p1'] ?? '', 'r1');
  check('D3 指向不存在规则的启用标记被清掉', !healed.active.containsKey('p2'));
  check('D4 空 projectId 的启用标记被清掉', !healed.active.containsKey(''));

  final StyleRuleLibrary roundTrip = StyleRuleLibrary.fromJson(
      Map<String, dynamic>.from(two.toJson() as Map));
  eqInt('D5 库往返：sets 数一致', roundTrip.sets.length, 2);
  eqStr('D6 库往返：名称一致', roundTrip.sets.first.name, '另一本');
  eqInt('D7 normalized 幂等', two.normalized().sets.length, two.sets.length);
  eqStr('D8 normalized 保留 active', activated.normalized().active['p1'] ?? '', 'r1');

  print('===== E. isEmpty / isUsable 约定 =====');

  check('E1 全空 → isEmpty 且 !isUsable',
      const StyleRuleSet().isEmpty && !const StyleRuleSet().isUsable);
  check('E2 只有维度没有技法也算可用',
      const StyleRuleSet(aspects: <String, String>{'perspective': '有'}).isUsable);
  check('E3 只有技法也算可用',
      const StyleRuleSet(techniques: <StyleTechnique>[
        StyleTechnique(category: '叙事技法', title: 't', detail: 'd'),
      ]).isUsable);
  check('E4 维度值为空白 → 仍算空',
      const StyleRuleSet(aspects: <String, String>{'perspective': '   '}).isEmpty);

  print('===============================');
  print('pass=$pass  fail=$fail');
  if (fail > 0) {
    print('SELFTEST FAILED');
    throw StateError('$fail case(s) failed');
  }
  print('SELFTEST OK');
}
