// `lib/ai/utils/dataset_spec_validator.dart` 的离线自检 + **真机数据审计**。
//
// 两种用法：
//   1) 自检（无参数）：
//        dart --disable-dart-dev tools/dataset_spec_validator_selftest.dart
//      —— 用合成正/负例覆盖范式里的每一道闸与每一个错误码 E1~E17。
//
//   2) 审计既有案例（把真实模型产物过一遍范式）：
//        dart --disable-dart-dev tools/dataset_spec_validator_selftest.dart audit <案例目录>
//      案例目录需含 `chapterBrief/N.txt` / `chapterProse/N.txt` / `milestone/*.txt`
//      / `report.json`（可选，用于取 askChars 与全书章数）。
//
//     ⚠ 审计模式会让「范式的纸面规则」对上「真实模型的真实毛病」——
//       这是制定范式时最该做的一步：规则写漏了哪条，一眼就看出来。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:novelcraft/ai/utils/dataset_spec_validator.dart';
import 'package:novelcraft/ai/utils/layered_pipeline_plan.dart';

int _passed = 0;
int _failed = 0;

void _check(String label, bool ok) {
  if (ok) {
    _passed++;
  } else {
    _failed++;
    print('FAIL  $label');
  }
}

/// 断言某个样本应通过。
void _expectPass(DatasetSample s, String label) {
  final DatasetVerdict v = DatasetSpecValidator.validate(s);
  if (!v.ok) {
    print('     ↳ 未过原因: ${v.failedChecks.join(' | ')}');
  }
  _check(label, v.ok);
}

/// 断言某个样本应失败，且失败原因里含 [needle]。
void _expectFail(DatasetSample s, String label, {String? needle}) {
  final DatasetVerdict v = DatasetSpecValidator.validate(s);
  final bool hit = !v.ok &&
      (needle == null ||
          v.failedChecks.any((String c) => c.contains(needle)) ||
          v.metrics.values.any((Object? x) => '$x'.contains(needle)));
  if (!hit) {
    print('     ↳ ok=${v.ok} checks=${v.failedChecks}');
  }
  _check(label, hit);
}

// ---------------------------------------------------------------------------
// 合成素材
// ---------------------------------------------------------------------------

String _brief({
  String title = '《潮声与灯塔》',
  String goal = '沈砚在第一次夜班里撞见退潮异象，决定独自去东岬看一眼。',
  String carry = '他刚接手夜班，与周晓棠只是在派出所门口点过一次头。',
  String conflict = '镇上的老规矩与他的好奇心撞在一起——去，就违背了老岑的告诫。',
  String twist = '他在礁石旁捡到一枚刻着自己名字的旧借阅卡。',
  String hook = '海水开始回涨，而图书馆的门还没开。',
  String cast = '沈砚、老岑',
  String time = '入秋第三日，夜班第一晚',
  String? foreshadow,
}) {
  final StringBuffer b = StringBuffer()
    ..writeln('标题：$title')
    ..writeln('本章目标：$goal')
    ..writeln('承接上文：$carry')
    ..writeln('核心冲突：$conflict')
    ..writeln('关键转折：$twist')
    ..writeln('章末钩子：$hook')
    ..writeln('出场人物：$cast')
    ..writeln('故事时间节点：$time');
  if (foreshadow != null) {
    b.writeln();
    b.writeln('## 伏笔提示');
    b.writeln(foreshadow);
  }
  return b.toString().trim();
}

// ---- 正文夹具 ----
//
// ⚠ 首版夹具从 12 句的池子里循环取句子，`charNgramRepeatRatio` 高达 0.83 ——
// 夹具自己就退化了，根本测不出正例。改用「固定种子的伪随机中文 + 已见
// 12-gram 判重」：每句 28 字，从词表里随机抽 14 个词，若任一 12-gram
// 已出现过就重抽。确定性（种子固定）+ 保证低复读。
final Random _rnd = Random(20261014);
final Set<String> _seenGrams = <String>{};

const List<String> _vocab = <String>[
  '潮水', '灯塔', '青石', '台阶', '防波堤', '礁石', '盐粒', '纸页', '书脊', '借书卡',
  '编目', '潮痕', '水线', '贝礁', '木门', '门闩', '铁环', '油灯', '灯芯', '海图',
  '邮戳', '信封', '钢笔', '墨渍', '钟摆', '楼梯', '回廊', '书架', '尘埃', '蛛网',
  '窗棂', '夜色', '晨雾', '远处', '近处', '脚下', '头顶', '身后', '面前', '胸口',
  '掌心', '指缝', '肩膀', '膝盖', '脚步', '影子', '回声', '寂静', '低语', '叹息',
  '灯塔下', '海岬上', '退潮时', '涨潮前', '入秋后', '夜半时', '拂晓前', '黄昏里',
  '书架间', '回廊上', '石阶上', '窗棂旁', '门缝里', '水线下', '青苔上', '沙地上',
  '沈砚', '老岑', '周晓棠', '编目员', '守塔人', '值班表', '手电筒', '旧报纸',
];

String _oneSentence() {
  for (int attempt = 0; attempt < 400; attempt++) {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 14; i++) {
      b.write(_vocab[_rnd.nextInt(_vocab.length)]);
    }
    final String s = b.toString();
    final List<String> grams = <String>[];
    bool fresh = true;
    for (int i = 0; i + 12 <= s.length; i++) {
      final String g = s.substring(i, i + 12);
      if (_seenGrams.contains(g)) {
        fresh = false;
        break;
      }
      grams.add(g);
    }
    if (fresh) {
      _seenGrams.addAll(grams);
      return s;
    }
  }
  return '第${_seenGrams.length}个退潮的夜晚';
}

String _prose(int minChars) {
  final StringBuffer b = StringBuffer();
  while (b.length < minChars + 200) {
    b.write(_oneSentence());
    b.write('。\n');
  }
  return '${b.toString().trim()}。';
}

String _milestones(int n) {
  final StringBuffer b = StringBuffer('[');
  for (int i = 1; i <= n; i++) {
    if (i > 1) b.write(',');
    b.write('{"index":$i,"label":"第$i卷 潮线","endState":'
        '"第$i段推进到全弧线的 ${(i * 100 / n).round()}%：沈砚解决了第$i个障碍，'
        '并暴露出第$i条新的疑问。"}');
  }
  b.write(']');
  return b.toString();
}

// ---------------------------------------------------------------------------
// 自检
// ---------------------------------------------------------------------------

void _selftest() {
  print('=== dataset_spec_validator 自检 ===');

  // ===== A 组：合格样本应通过 =====
  _expectPass(
    DatasetSample(
      task: 'T01_volume_milestone',
      format: DatasetFormatKind.jsonArray,
      completion: _milestones(3),
      milestoneCount: 3,
    ),
    'A1 卷级里程碑合格',
  );
  _expectPass(
    DatasetSample(
      task: 'T02_chapter_milestone',
      format: DatasetFormatKind.jsonArray,
      completion: _milestones(5),
      milestoneCount: 5,
    ),
    'A2 章级里程碑合格',
  );
  _expectPass(
    const DatasetSample(
      task: 'T03_chapter_names',
      format: DatasetFormatKind.jsonObject,
      completion:
          '{"names":[{"i":1,"name":"潮声与灯塔"},{"i":2,"name":"第一次借阅"},'
          '{"i":3,"name":"代价初现"}]}',
    ),
    'A3 章名合格',
  );
  _expectPass(
    DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: _brief(
        foreshadow: '- T001（第1章 → 第6章）：一件旧物上的名字被反复提及，来历未明。',
      ),
      globalOrder: 1,
      totalChapters: 8,
    ),
    'A4 细纲合格（含合法伏笔）',
  );
  _expectPass(
    const DatasetSample(
      task: 'T05_brief_patch',
      format: DatasetFormatKind.textLines,
      completion: '关键转折：他发现借阅卡背面的名字是自己父亲。',
    ),
    'A5 差异补丁合格',
  );
  _expectPass(
    const DatasetSample(
      task: 'T05_brief_patch',
      format: DatasetFormatKind.textLines,
      completion: '无需修改',
    ),
    'A6 「无需修改」合格',
  );
  _expectPass(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: _prose(900),
      askChars: 800,
    ),
    'A7 正文分片合格',
  );
  _expectPass(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: _prose(1500),
      askChars: 1400,
    ),
    'A8 正文 1500 字仍合格（在 2400 上限内）',
  );

  // ===== B 组：每个错误码都应被抓到 =====
  _expectFail(
    const DatasetSample(
      task: 'T01_volume_milestone',
      format: DatasetFormatKind.jsonArray,
      completion: '好的，这是三卷里程碑：\n',
    ),
    'B1 E1 开场白 → G1',
    needle: 'G1',
  );
  _expectFail(
    DatasetSample(
      task: 'T01_volume_milestone',
      format: DatasetFormatKind.jsonArray,
      completion: '>${_milestones(3)}',
      milestoneCount: 3,
    ),
    'B2 E17 `>` 前缀 → G1',
    needle: 'E17',
  );
  _expectFail(
    const DatasetSample(
      task: 'T02_chapter_milestone',
      format: DatasetFormatKind.jsonArray,
      completion: '["沈砚走进图书馆","沈砚发现真相","沈砚做出选择"]',
      milestoneCount: 3,
    ),
    'B3 E11 schema 降级 → G2',
    needle: 'E11',
  );
  _expectFail(
    DatasetSample(
      task: 'T02_chapter_milestone',
      format: DatasetFormatKind.jsonArray,
      completion: '```json\n${_milestones(3)}\n```',
      milestoneCount: 3,
    ),
    'B4 E2 Markdown 围栏 → G1',
    needle: 'G1',
  );
  _expectFail(
    DatasetSample(
      task: 'T02_chapter_milestone',
      format: DatasetFormatKind.jsonArray,
      completion: _milestones(2),
      milestoneCount: 3,
    ),
    'B5 条数不符 → G2',
    needle: '条数',
  );
  _expectFail(
    const DatasetSample(
      task: 'T02_chapter_milestone',
      format: DatasetFormatKind.jsonArray,
      completion:
          '[{"index":1,"label":"a","endState":"同一句话。"},'
          '{"index":2,"label":"b","endState":"同一句话。"},'
          '{"index":3,"label":"c","endState":"同一句话。"}]',
      milestoneCount: 3,
    ),
    'B6 状态全同 → G2',
    needle: '没有推进',
  );
  _expectFail(
    const DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: '标题：《潮声与灯塔》\n本章目标：只有一个字段的残缺细纲。',
      globalOrder: 1,
      totalChapters: 8,
    ),
    'B7 缺字段 → G2',
    needle: '字段',
  );
  _expectFail(
    DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: _brief(
        goal: '同一句话。',
        conflict: '同一句话。',
        twist: '同一句话。',
      ),
      globalOrder: 1,
      totalChapters: 8,
    ),
    'B8 E5 字段复制 → G2',
  );
  _expectFail(
    DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: _brief(title: '《Txxx》'),
      globalOrder: 1,
      totalChapters: 8,
    ),
    'B9 E3 占位行回抄 → G2',
  );
  _expectFail(
    DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: _brief(foreshadow: '- T001（第1章 → 第28章）：一句话方向。'),
      globalOrder: 1,
      totalChapters: 8,
    ),
    'B10 E6 伏笔越界 → G5',
  );
  _expectFail(
    DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: _brief(foreshadow: '- T001（第1章 → 第2章）：一句话方向。'),
      globalOrder: 1,
      totalChapters: 8,
    ),
    'B11 伏笔跨度不足 → G5',
  );
  _expectFail(
    DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: _brief(foreshadow: '- T007（第7章 → 第8章）：一句话方向。'),
      globalOrder: 7,
      totalChapters: 8,
    ),
    'B12 末章禁埋 → G5',
    needle: '末章禁埋',
  );
  _expectFail(
    const DatasetSample(
      task: 'T05_brief_patch',
      format: DatasetFormatKind.textLines,
      completion: '请核验以下 4 点：\n① 本章终点是否落实\n关键转折：真正要改的转折',
    ),
    'B13 E4 指令回显 → G2',
    needle: 'E4',
  );
  _expectFail(
    const DatasetSample(
      task: 'T05_brief_patch',
      format: DatasetFormatKind.textLines,
      completion: '一份完全不带字段的散文。',
    ),
    'B14 无字段补丁 → G2',
    needle: '补丁',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: '${_prose(300)}${'绝壁绝壁绝壁绝壁绝壁绝壁' * 20}',
      askChars: 300,
    ),
    'B15 E8 复读退化 → G3',
    needle: 'G3',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: '${_prose(800)}\n（全文完）',
      askChars: 700,
    ),
    'B16 E10 收尾语 → G3',
    needle: 'E10',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: _prose(800).substring(0, 860),
      askChars: 700,
    ),
    'B17 E9 中途断句 → G3',
    needle: 'E9',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: '${_prose(700)}\n本章目标：沈砚去东岬。',
      askChars: 600,
    ),
    'B18 E6 复述细纲字段 → G3',
    needle: 'E6',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: '# 第一章 退潮时分\n${_prose(700)}',
      askChars: 600,
    ),
    'B19 E5 Markdown 标题 → G3',
    needle: 'E5',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: '${_prose(700)}\nUser: 继续',
      askChars: 600,
    ),
    'B20 E15 角色标记泄漏 → G3',
    needle: 'E15',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: _prose(120),
      askChars: 800,
    ),
    'B21 E16 长度塌陷 → G4',
    needle: 'G4',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion: _prose(2600),
      askChars: 2400,
    ),
    'B22 单片超 2400 → G4',
    needle: '2400',
  );
  _expectFail(
    DatasetSample(
      task: 'T06_prose_slice',
      format: DatasetFormatKind.prose,
      completion:
          '${_prose(600)}\n'
          'Then he walked along the breakwater for a long time, thinking about '
          'the lighthouse and the library beneath it. The tide was going out, '
          'and nobody was watching the water at all. He counted his steps, one '
          'and then two, until the iron ring appeared above the reef, and he '
          'understood that the door would open only when the water had pulled '
          'back far enough to show the whole staircase.',
      askChars: 600,
    ),
    'B23 E12 中英混杂 → G7',
    needle: 'G7',
  );
  _expectFail(
    const DatasetSample(
      task: 'T04_chapter_brief',
      format: DatasetFormatKind.textLines,
      completion: '',
    ),
    'B24 空样本',
  );
  _expectFail(
    const DatasetSample(
      task: 'T03_chapter_names',
      format: DatasetFormatKind.jsonObject,
      completion: '{"names":[{"i":1,"name":"本章目标之血色契约"}]}',
    ),
    'B25 E14 章名含元信息 → G2',
    needle: 'E14',
  );

  // ===== C 组：G6 去重 =====
  {
    // ⚠ 必须先用同一个 String 再比：`_prose()` 每次调用都生成**新**正文
    //（随机种子推进），连续调两次拿到的不是同一段文本（首轮就栽在这）。
    final String a = _prose(700);
    final DatasetDedup dd = DatasetDedup();
    dd.add(a);
    _check('C1 相同文本判重', dd.isDuplicate(a));
    _check('C2 相似度接近 1', dd.maxSimilarity(a) > 0.9);
    final String other = _prose(700).split('').reversed.join();
    _check('C3 无关文本不判重', !dd.isDuplicate(other));
    _check('C4 空索引不判重', !DatasetDedup().isDuplicate(a));
  }

  // ===== D 组：指标 =====
  {
    _check('D1 含标点中文比例接近 1',
        DatasetSpecValidator.cjkRatio('这是一段中文。').round() == 1);
    _check('D2 纯英文比例为 0', DatasetSpecValidator.cjkRatio('abc def') == 0);
    _check('D3 空串比例为 0', DatasetSpecValidator.cjkRatio('') == 0);
    _check('D4 「无需修改」等价判定',
        DatasetSpecValidator.isNoChange(' 无需修改。') &&
            DatasetSpecValidator.isNoChange('') &&
            DatasetSpecValidator.isNoChange('合格'));
    _check('D5 非等价不被判「无需修改」',
        !DatasetSpecValidator.isNoChange('关键转折：改一下'));
    _check('D6 JSON 的中文比例下限低于正文',
        DatasetSpecValidator.minCjkRatioFor(DatasetFormatKind.jsonArray) <
            DatasetSpecValidator.minCjkRatioFor(DatasetFormatKind.prose));
  }

  // ===== E 组：字段契约与范式一致 =====
  {
    _check('E1 契约字段共 8 项', kChapterBriefFields.length == 8);
    _check('E2 字段首尾与范式 §3.2.3 一致',
        kChapterBriefFields.first == '标题' &&
            kChapterBriefFields.last == '故事时间节点');
  }


  // ===== F 组：Part II State Tuning 专项闸位 =====
  {
    // 同质的细纲组：8 字段、长度接近、人格一致 → 应通过
    final List<StateTuningSample> good = <StateTuningSample>[
      for (int i = 0; i < 6; i++)
        StateTuningSample(
          stateTarget: StateTarget.briefContract,
          completion: _brief(
            foreshadow: '- T001（第1章 → 第6章）：一件旧物上的名字来历未明。',
          ),
          persona: '分卷编剧',
          pov: '第三人称限知',
          tense: '过去时',
        ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(good);
    _check('F1 同质细纲组通过', v.ok);
    if (!v.ok) print('     ↳ ${v.reasons.join(' | ')}');
  }
  {
    // 混入其它 state 的样本 → ST-G9
    final List<StateTuningSample> mixed = <StateTuningSample>[
      StateTuningSample(
        stateTarget: StateTarget.briefContract,
        completion: _brief(),
        persona: '分卷编剧',
      ),
      StateTuningSample(
        stateTarget: StateTarget.novelistProse,
        completion: _prose(700),
        persona: '正文写手',
      ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(mixed);
    _check('F2 混入其它 state → ST-G9', !v.ok && v.failedGates.contains('ST-G9'));
  }
  {
    // textLines 字段数不一致 → ST-G9
    final List<StateTuningSample> f = <StateTuningSample>[
      for (int i = 0; i < 4; i++)
        StateTuningSample(
          stateTarget: StateTarget.briefContract,
          completion: _brief(),
          persona: '分卷编剧',
        ),
      StateTuningSample(
        stateTarget: StateTarget.briefContract,
        completion: '标题：《残缺》\n本章目标：只有一个字段。',
        persona: '分卷编剧',
      ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(f);
    _check('F3 字段数不统一 → ST-G9',
        !v.ok && v.reasons.any((String r) => r.contains('字段数不统一')));
  }
  {
    // cjk_ratio 极差过大（中文里夹一段英文）→ ST-G9
    final List<StateTuningSample> f = <StateTuningSample>[
      for (int i = 0; i < 3; i++)
        StateTuningSample(
          stateTarget: StateTarget.novelistProse,
          completion: _prose(700),
        ),
      StateTuningSample(
        stateTarget: StateTarget.novelistProse,
        completion:
            'Then he walked along the breakwater for a long time, thinking '
            'about the lighthouse and the library beneath it. The tide was '
            'going out, and nobody was watching the water at all today.',
      ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(f);
    _check('F4 cjk 极差过大 → ST-G9',
        !v.ok && v.reasons.any((String r) => r.contains('cjk_ratio 极差')));
  }
  {
    // 长度档位混得太开 → ST-G9（state 只能偏一个长度）
    final List<StateTuningSample> f = <StateTuningSample>[
      for (int i = 0; i < 3; i++)
        StateTuningSample(
          stateTarget: StateTarget.novelistProse,
          completion: _prose(1400),
        ),
      for (int i = 0; i < 3; i++)
        StateTuningSample(
          stateTarget: StateTarget.novelistProse,
          completion: _prose(400),
        ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(f);
    _check('F5 长度档位混开 → ST-G9',
        !v.ok && v.reasons.any((String r) => r.contains('中位数')));
  }
  {
    // 人称分歧 → ST-G9
    final List<StateTuningSample> f = <StateTuningSample>[
      StateTuningSample(
        stateTarget: StateTarget.novelistProse,
        completion: _prose(700),
        pov: '第三人称限知',
      ),
      StateTuningSample(
        stateTarget: StateTarget.novelistProse,
        completion: _prose(700),
        pov: '第一人称',
      ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(f);
    _check('F6 人称分歧 → ST-G9',
        !v.ok && v.reasons.any((String r) => r.contains('pov')));
  }
  {
    // 多轮样本 → ST-G12
    final List<StateTuningSample> f = <StateTuningSample>[
      StateTuningSample(
        stateTarget: StateTarget.novelistProse,
        completion: _prose(700),
      ),
      StateTuningSample(
        stateTarget: StateTarget.novelistProse,
        completion: 'User: 继续\nAssistant: 好的，我接着写。',
      ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(f);
    _check('F7 多轮样本 → ST-G12',
        !v.ok && v.failedGates.contains('ST-G12'));
    _check('F8 isSingleTurn 判定',
        StateTuningGates.isSingleTurn(_prose(200)) &&
            !StateTuningGates.isSingleTurn('Assistant: hi'));
  }
  {
    // 空组 → ST-G9
    final StateGateVerdict v =
        StateTuningGates.checkGroup(const <StateTuningSample>[]);
    _check('F9 空组 → ST-G9', !v.ok && v.failedGates.contains('ST-G9'));
  }
  {
    // JSON 结构类同质组也应通过（shape 走 jsonArray）
    final List<StateTuningSample> good = <StateTuningSample>[
      for (int i = 0; i < 4; i++)
        StateTuningSample(
          stateTarget: StateTarget.outlinerStruct,
          completion: _milestones(3 + i),
          persona: '总编剧',
        ),
    ];
    final StateGateVerdict v = StateTuningGates.checkGroup(good);
    _check('F10 同质 JSON 组通过', v.ok);
    if (!v.ok) print('     ↳ ${v.reasons.join(' | ')}');
  }
  {
    // byName 解析
    _check('F11 StateTarget.byName 可用',
        StateTarget.byName('novelist_prose') == StateTarget.novelistProse &&
            StateTarget.byName('ST-3') == StateTarget.briefContract);
    _check('F12 每个 state 都有唯一输出形状',
        StateTarget.values
                .map((StateTarget t) => t.format)
                .toSet()
                .length >=
            2);
  }

  print('dataset_spec_validator 自检: $_passed passed, $_failed failed');
  if (_failed > 0) {
    throw StateError('dataset_spec_validator 自检失败');
  }
}

// ---------------------------------------------------------------------------
// 审计模式
// ---------------------------------------------------------------------------

/// 把一个案例目录里的真实产物过一遍范式。
int _audit(String dir) {
  print('=== 审计案例目录：$dir ===');
  final File report = File('$dir/report.json');
  Map<String, Object?>? rep;
  if (report.existsSync()) {
    try {
      final dynamic d = jsonDecode(report.readAsStringSync());
      if (d is Map) rep = Map<String, Object?>.from(d);
    } on Object catch (_) {
      rep = null;
    }
  }
  final int totalChapters = () {
    if (rep == null) return 0;
    final Object? chs = rep['chapters'];
    if (chs is List && chs.isNotEmpty) return chs.length;
    return 0;
  }();
  final Map<int, int> askByChapter = <int, int>{};
  if (rep != null) {
    final Object? chs = rep['chapters'];
    if (chs is List) {
      for (final Object? c in chs) {
        if (c is Map && c['chapter'] != null && c['chars'] != null) {
          askByChapter[int.tryParse('${c['chapter']}') ?? 0] =
              int.tryParse('${c['chars']}') ?? 0;
        }
      }
    }
  }

  final List<String> lines = <String>[];
  int pass = 0;
  int fail = 0;

  void run({required String label, required DatasetSample sample}) {
    final DatasetVerdict v = DatasetSpecValidator.validate(sample);
    if (v.ok) {
      pass++;
    } else {
      fail++;
    }
    lines.add('${v.ok ? 'PASS' : 'FAIL'}  $label'
        '${v.ok ? '' : '\n        gates=${v.failedGates.join(",")}'
            '\n        ${v.failedChecks.join('\n        ')}'}');
  }

  for (final String rel in <String>['milestone/volumes.txt']) {
    final File f = File('$dir/$rel');
    if (!f.existsSync()) continue;
    run(
      label: rel,
      sample: DatasetSample(
        task: 'T01_volume_milestone',
        format: DatasetFormatKind.jsonArray,
        completion: f.readAsStringSync(),
      ),
    );
  }

  for (int i = 1; i <= (totalChapters <= 0 ? 20 : totalChapters); i++) {
    final File f = File('$dir/chapterBrief/$i.txt');
    if (!f.existsSync()) continue;
    run(
      label: 'chapterBrief/$i.txt',
      sample: DatasetSample(
        task: 'T04_chapter_brief',
        format: DatasetFormatKind.textLines,
        completion: f.readAsStringSync(),
        totalChapters: totalChapters <= 0 ? 5 : totalChapters,
        globalOrder: i,
      ),
    );
  }

  for (int i = 1; i <= 60; i++) {
    final File f = File('$dir/chapterProse/$i.txt');
    if (!f.existsSync()) continue;
    run(
      label: 'chapterProse/$i.txt',
      sample: DatasetSample(
        task: 'T06_prose_slice',
        format: DatasetFormatKind.prose,
        completion: f.readAsStringSync(),
        askChars: askByChapter[i] ?? 0,
      ),
    );
  }

  for (final String rel in <String>['mainOutline/main.txt', 'volumeOutline/1.txt']) {
    final File f = File('$dir/$rel');
    if (!f.existsSync()) continue;
    run(
      label: rel,
      sample: DatasetSample(
        task: 'T13_main_outline',
        // ⚠ 大纲是**结构化条目文本**，不是 prose。用 prose 会让 G3 的
        // prose 专属检查（Markdown 标题 / 复述细纲字段 / 完整句收尾）误伤大纲
        // —— 首轮审计就把 `# 卷名` 这种合法条目化标记判成了 E5。
        format: DatasetFormatKind.textLines,
        completion: f.readAsStringSync(),
      ),
    );
  }

  for (final String l in lines) {
    print('  $l');
  }
  print('');
  print('审计结果：通过 $pass / 失败 $fail'
      '（全书章数=${totalChapters <= 0 ? '未知' : totalChapters}）');
  return fail == 0 ? 0 : 1;
}

void main(List<String> args) {
  if (args.length >= 2 && args[0] == 'audit') {
    exit(_audit(args[1]));
  }
  _selftest();
}
