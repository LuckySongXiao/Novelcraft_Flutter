// 拆书（文风研读）纯文本规则自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/style_digest_selftest.dart
//
// 覆盖四组规则。它们直接决定拆书质量的上限：
//   * `paragraphs` 切错 → 整本书被当成一个巨型段落，章节边界全丢；
//   * `sampleChunks` 只取开头 → 结论被「黄金三章」带偏（网文开头是作者最用力的部分）；
//   * `cleanSample` 不清洗 → 站点水印句混进句式统计；
//   * `mergeObservations` 不去重 → 技法列表全是重复项，注入提示词只会稀释指令。
import '../lib/ai/utils/style_digest_text.dart';

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
  print('===== A. paragraphs：段落切分 =====');

  final String blankSplit = List<String>.generate(
    8,
    (int i) => '第$i段内容',
  ).join('\n\n');
  check(
    'A1 空行分段（≥4 段）按空行切',
    StyleDigestText.paragraphs(blankSplit).length == 8,
    detail: 'got=${StyleDigestText.paragraphs(blankSplit).length}',
  );

  final String lineSplit = List<String>.generate(
    8,
    (int i) => '第$i行内容',
  ).join('\n');
  check(
    'A2 每行一段、无空行 → 退化为按行切（否则整本成一个巨型段落）',
    StyleDigestText.paragraphs(lineSplit).length == 8,
    detail: 'got=${StyleDigestText.paragraphs(lineSplit).length}',
  );

  check(
    'A3 空输入 → 空',
    StyleDigestText.paragraphs('   \n\n  ').isEmpty,
  );

  print('');
  print('===== B. cleanSample：样本清洗 =====');

  final String dirty = '\uFEFF第一章 起始\n'
      '请记住本站域名 www.example.com\n'
      '正文第一段，写得很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长。\n'
      '\n'
      '\n'
      '正文第二段。';
  final String cleaned = StyleDigestText.cleanSample(dirty);
  check('B1 去 BOM', !cleaned.startsWith('\uFEFF'));
  check('B2 短行站点水印被删除', !cleaned.contains('请记住本站'));
  check('B3 章节标题保留（分析节奏要用）', cleaned.contains('第一章 起始'));
  check(
    'B4 连续空行折叠为一个',
    !cleaned.contains('\n\n\n'),
    detail: 'got=${cleaned.replaceAll('\n', '\\n')}',
  );
  final String longLine =
      '他打开终端，输入 https://example.com ${'等待' * 40}。';
  check(
    'B5 长行里出现网址不算水印（只有短行才判；本行 ${longLine.length} 字）',
    longLine.length > 60 &&
        StyleDigestText.cleanSample(longLine).contains('https://example.com'),
  );

  print('');
  print('===== C. sampleChunks：分块与均匀采样 =====');

  const String head = '开头标记ABCDEFG';
  const String tail = '结尾标记ZYXWVUT';
  final String longText = <String>[
    head,
    for (int i = 0; i < 60; i++) '第$i段内容${'字' * 200}',
    tail,
  ].join('\n\n');

  check(
    'C1 短文本 → 单块（不切）',
    StyleDigestText.sampleChunks('很短的一段话').length == 1,
  );

  final List<String> chunks = StyleDigestText.sampleChunks(
    longText,
    chunkChars: 1000,
    maxChunks: 5,
  );
  check(
    'C2 长文本按 maxChunks 截断',
    chunks.length == 5,
    detail: 'got=${chunks.length}',
  );
  check('C3 首块必留（含开头）', chunks.first.contains(head));
  check(
    'C4 尾块必留（含结尾，代表作者成熟期写法）',
    chunks.last.contains(tail),
    detail: 'last=${chunks.last.substring(0, 40)}…',
  );
  check(
    'C5 每块不超过 chunkChars（除硬切边界外）',
    chunks.every((String c) => c.length <= 1000),
    detail: 'lens=${chunks.map((String c) => c.length).toList()}',
  );

  final List<String> hard = StyleDigestText.sampleChunks(
    '字' * 10000,
    chunkChars: 1000,
    maxChunks: 4,
  );
  check(
    'C6 无分段的整块 → 硬切（否则永远塞不进上下文）',
    hard.length == 4 && hard.every((String c) => c.length == 1000),
    detail: 'n=${hard.length} lens=${hard.map((String c) => c.length).toList()}',
  );

  check(
    'C7 空文本 → 空',
    StyleDigestText.sampleChunks('  ').isEmpty,
  );

  print('');
  print('===== D. mergeObservations：多块观察合并 =====');

  final Map<String, dynamic> merged = StyleDigestText.mergeObservations(
    <Map<String, dynamic>>[
      <String, dynamic>{
        'perspective': '第三人称限知视角',
        'sentence': '短句为主',
        'techniques': <Map<String, dynamic>>[
          <String, dynamic>{
            'category': '叙事技法',
            'title': '多线叙事',
            'detail': '主线 + 暗线 + 交汇线',
          },
        ],
      },
      <String, dynamic>{
        'perspective': '第三人称限知视角',
        'sentence': '段落偏短，常以单句成段',
        'techniques': <Map<String, dynamic>>[
          <String, dynamic>{
            'category': '叙事技法',
            'title': '多线叙事',
            'detail': '重复条目必须被丢掉',
          },
          <String, dynamic>{
            'category': '自造分类',
            'title': '命运闭环',
            'detail': '主角改变命运的行为本身构成命运',
          },
        ],
      },
    ],
  );

  final String perspective = merged['perspective'] as String;
  check(
    'D1 完全相同的字段值只留一份',
    perspective == '第三人称限知视角',
    detail: 'got=«$perspective»',
  );
  final String sentence = merged['sentence'] as String;
  check(
    'D2 同维度不同表述并列保留 —— 合并结果是给「汇总调用」消费的中间产物，不是最终文案，'
        '去掉互相包含的重复即可',
    sentence == '短句为主；段落偏短，常以单句成段',
    detail: 'got=«$sentence»',
  );

  final List<dynamic> techs = merged['techniques'] as List<dynamic>;
  check(
    'D3 同标题技法去重（2 条多线叙事只留 1 条）',
    techs.where((dynamic t) => (t as Map)['title'] == '多线叙事').length == 1,
  );
  check('D4 技法总数正确（多线叙事 + 命运闭环 = 2）', techs.length == 2,
      detail: 'got=$techs');
  check(
    'D5 自造分类被归到既有大类',
    techs
        .every((dynamic t) => kStyleTechniqueCategories.contains((t as Map)['category'])),
    detail: 'cats=${techs.map((dynamic t) => (t as Map)['category']).toList()}',
  );

  final Map<String, dynamic> empty = StyleDigestText.mergeObservations(
    <Map<String, dynamic>>[],
  );
  check(
    'D6 空观察列表 → 所有维度为空、技法为空（不抛异常）',
    empty.keys.length == kStyleAspectLabels.length + 1 &&
        (empty['techniques'] as List<dynamic>).isEmpty &&
        empty['perspective'] == '',
    detail: 'keys=${empty.keys.toList()}',
  );

  final Map<String, dynamic> capped = StyleDigestText.mergeObservations(
    <Map<String, dynamic>>[
      <String, dynamic>{
        'techniques': <Map<String, dynamic>>[
          for (int i = 0; i < 100; i++)
            <String, dynamic>{
              'category': '叙事技法',
              'title': '技法$i',
              'detail': '说明$i',
            },
        ],
      },
    ],
  );
  check(
    'D7 技法数量有上限（防止规则膨胀到无法注入）',
    (capped['techniques'] as List<dynamic>).length == kStyleMaxTechniques,
    detail: 'got=${(capped['techniques'] as List<dynamic>).length}',
  );

  final Map<String, dynamic> contained = StyleDigestText.mergeObservations(
    <Map<String, dynamic>>[
      <String, dynamic>{'imagery': '常用「血月」意象'},
      <String, dynamic>{'imagery': '常用「血月」意象，并常写「陨星」'},
    ],
  );
  check(
    'D8 后到的长句是已有的超集 → 替换（短句不能把长句挤掉）',
    contained['imagery'] == '常用「血月」意象，并常写「陨星」',
    detail: 'got=«${contained['imagery']}»',
  );

  final Map<String, dynamic> supersetFirst = StyleDigestText.mergeObservations(
    <Map<String, dynamic>>[
      <String, dynamic>{'imagery': '常用「血月」意象，并常写「陨星」'},
      <String, dynamic>{'imagery': '常用「血月」意象'},
    ],
  );
  check(
    'D9 已有的是新值的超集 → 丢掉新值（避免回退到更短的表述）',
    supersetFirst['imagery'] == '常用「血月」意象，并常写「陨星」',
    detail: 'got=«${supersetFirst['imagery']}»',
  );

  print('');
  print('===== E. 字段与分类约定 =====');

  check(
    'E1 七个文本维度都有中文名（否则 UI 会出现裸键名）',
    kStyleAspectLabels.length == 7 &&
        kStyleAspectLabels.values.every((String v) => v.trim().isNotEmpty),
  );
  check(
    'E2 技法大类非空',
    kStyleTechniqueCategories.isNotEmpty,
  );
  check(
    'E3 JSON 解析转发可用（含前后废话）',
    StyleDigestText.parseJsonObject('结果如下：{"perspective":"第一人称"}谢谢')?['perspective'] ==
        '第一人称',
  );

  print('');
  print('===============================');
  print('pass=$pass  fail=$fail');
  print(fail > 0 ? 'SELFTEST FAILED' : 'SELFTEST OK');
}
