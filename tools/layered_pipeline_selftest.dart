// 离线自检：layered_pipeline_plan.dart（分层管线纯规则层）。
//
// 运行：dart --disable-dart-dev tools/layered_pipeline_selftest.dart
library;

import 'dart:convert';

import 'package:novelcraft/ai/utils/layered_pipeline_plan.dart';
import 'package:novelcraft/application/services/layered_book_generation_service.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool cond) {
  if (cond) {
    _passed++;
  } else {
    _failed++;
    print('FAIL  $name');
  }
}

void main() {
  // =========================================================================
  // A 组：锚渲染
  // =========================================================================
  {
    const PipelineAnchor a = PipelineAnchor(start: '开篇状态', end: '结局状态');
    _check('A1 完整锚 isComplete', a.isComplete);
    final String r = a.render();
    _check('A2 渲染含起终点标签', r.contains('【起点】') && r.contains('【终点】'));
    _check('A3 渲染含两端内容', r.contains('开篇状态') && r.contains('结局状态'));
    const PipelineAnchor empty = PipelineAnchor(start: '', end: '');
    _check('A4 空锚 isComplete=false', !empty.isComplete);
    _check('A5 空锚渲染为空串', empty.render().isEmpty);
    const PipelineAnchor half = PipelineAnchor(start: '只有起点', end: '   ');
    _check('A6 半锚不算完整', !half.isComplete);
  }

  // =========================================================================
  // B 组：里程碑解析（JSON）
  // =========================================================================
  {
    const String raw = '[{"index":1,"label":"第一卷 退潮","endState":"沈砚第一次进入图书馆"},'
        '{"index":2,"label":"第二卷 借阅卡","endState":"沈砚知道编目员在回应他"},'
        '{"index":3,"label":"第三卷 涨潮","endState":"沈砚做出最终选择"}]';
    final List<PipelineMilestone> ms = MilestoneCodec.parse(raw, total: 3);
    _check('B1 解析出 3 条', ms.length == 3);
    _check('B2 标签正确', ms.first.label == '第一卷 退潮');
    _check('B3 状态正确', ms.last.endState == '沈砚做出最终选择');
    _check('B4 比例正确', ms[1].ratio == 2 / 3);
    _check('B5 比例文案', ms[2].ratioLabel == '100%');
  }
  {
    // 围栏 + 包裹对象 + 字段别名
    const String raw = '```json\n{"milestones":[{"name":"卷一","state":"状态一"},'
        '{"name":"卷二","summary":"状态二"}]}\n```';
    final List<PipelineMilestone> ms = MilestoneCodec.parse(raw, total: 2);
    _check('B6 围栏 + 包裹对象可解析', ms.length == 2);
    _check('B7 name/state 别名', ms.first.label == '卷一' && ms.first.endState == '状态一');
    _check('B8 summary 别名', ms[1].endState == '状态二');
  }
  {
    // 杂文本中夹 JSON
    const String raw = '好的，这是结果：\n'
        '[{"label":"A","endState":"状态A"}]\n以上。';
    final List<PipelineMilestone> ms = MilestoneCodec.parse(raw, total: 1);
    _check('B9 夹在杂文本里也能解析', ms.length == 1 && ms.first.endState == '状态A');
  }

  // =========================================================================
  // C 组：里程碑解析（行式）
  // =========================================================================
  {
    const String raw = '第1卷《退潮四十分钟》：沈砚第一次走进图书馆，知道书按人名编目。\n'
        '第2卷《借阅卡上的字》：沈砚发现自己的名字出现在借阅卡上。\n'
        '第3卷《涨潮》：大潮将至，沈砚必须做出选择。';
    final List<PipelineMilestone> ms = MilestoneCodec.parse(raw, total: 3);
    _check('C1 行式解析 3 条', ms.length == 3);
    _check('C2 卷名被抽出', ms[1].label == '借阅卡上的字');
    _check('C3 状态被抽出', ms.last.endState.contains('做出选择'));
  }
  {
    const String raw = '1. 第一卷 —— 开篇立足\n'
        '2. 第二卷 —— 真相浮现\n'
        '3. 第三卷 —— 终局收束';
    final List<PipelineMilestone> ms = MilestoneCodec.parse(raw, total: 3);
    _check('C4 数字列表 + 破折号', ms.length == 3);
    _check('C5 状态抽取', ms[0].endState == '开篇立足');
  }
  {
    // 无分隔符的普通句子不应被当里程碑
    const String raw = '这一卷讲的是沈砚的成长\n他慢慢理解了代价\n';
    _check('C6 无分隔符 → 不误判',
        MilestoneCodec.parse(raw, total: 2).isEmpty);
  }
  {
    // ⚠ 实测（+50）：模型极常忽略对象 schema，直接返回**字符串数组**。
    // 这是合法输出形态，必须按位置收下（否则会退到行式解析、拆成垃圾）。
    const String raw = '[\n'
        '  "沈砚接手夜班，对低潮图书馆一无所知。",\n'
        '  "沈砚第一次走进图书馆，确认书架按人名编目。",\n'
        '  "沈砚做出选择并承担代价。"\n'
        ']';
    final List<PipelineMilestone> ms = MilestoneCodec.parse(raw, total: 3);
    _check('C9 字符串数组被收下', ms.length == 3);
    _check('C10 按位置作为 endState',
        ms[0].endState.startsWith('沈砚接手夜班') &&
            ms[2].endState.startsWith('沈砚做出选择'));
    _check('C11 label 留空（不编造）', ms.every((PipelineMilestone m) => m.label.isEmpty));
    _check('C12 该形态应通过校验（有推进）',
        MilestoneCodec.validate(ms).isEmpty);
  }
  {
    _check('C7 空输入 → 空表', MilestoneCodec.parse('', total: 3).isEmpty);
    _check('C8 total=0 → 空表', MilestoneCodec.parse('[]', total: 0).isEmpty);
  }

  // =========================================================================
  // D 组：normalise（补齐 / 截断 / 重排序号）
  // =========================================================================
  {
    final List<PipelineMilestone> parsed = <PipelineMilestone>[
      const PipelineMilestone(index: 7, total: 3, label: '甲', endState: '状态甲'),
      const PipelineMilestone(index: 9, total: 3, label: '乙', endState: '状态乙'),
    ];
    final List<PipelineMilestone> n = MilestoneCodec.normalise(parsed, 4);
    _check('D1 补齐到 4 条', n.length == 4);
    _check('D2 序号重排为 1..4', n[0].index == 1 && n[3].index == 4);
    _check('D3 已有内容保留', n[0].label == '甲' && n[1].endState == '状态乙');
    _check('D4 补齐项为空状态', n[2].endState.isEmpty && n[3].endState.isEmpty);
    _check('D5 超出则截断', MilestoneCodec.normalise(parsed, 1).length == 1);
    _check('D6 total=0 → 空表',
        MilestoneCodec.normalise(parsed, 0).isEmpty);
  }

  // =========================================================================
  // E 组：校验
  // =========================================================================
  {
    final List<PipelineMilestone> ok = MilestoneCodec.normalise(
      MilestoneCodec.parse(
        '[{"label":"a","endState":"状态A"},{"label":"b","endState":"状态B"}]',
        total: 2,
      ),
      2,
    );
    _check('E1 正常里程碑无问题', MilestoneCodec.validate(ok).isEmpty);
  }
  {
    final List<PipelineMilestone> withEmpty = MilestoneCodec.normalise(
      <PipelineMilestone>[
        const PipelineMilestone(index: 1, total: 2, label: 'a', endState: '有'),
      ],
      2,
    );
    _check('E2 空状态 → 报缺项',
        MilestoneCodec.validate(withEmpty).any((String s) => s.contains('为空')));
  }
  {
    final List<PipelineMilestone> same = MilestoneCodec.normalise(
      <PipelineMilestone>[
        const PipelineMilestone(index: 1, total: 2, label: 'a', endState: '一样'),
        const PipelineMilestone(index: 2, total: 2, label: 'b', endState: '一样'),
      ],
      2,
    );
    _check('E3 状态全同 → 报没推进',
        MilestoneCodec.validate(same).any((String s) => s.contains('没有推进')));
  }
  {
    const String endState = '全书终点状态';
    final List<PipelineMilestone> copy = MilestoneCodec.normalise(
      <PipelineMilestone>[
        const PipelineMilestone(index: 1, total: 1, label: 'a', endState: '中间态'),
        const PipelineMilestone(index: 2, total: 2, label: 'b', endState: endState),
      ],
      2,
    );
    final List<String> issues = MilestoneCodec.validate(
      copy,
      anchor: const PipelineAnchor(start: '起点态', end: endState),
    );
    _check('E4 末条照抄终点锚 → 报疑似照抄',
        issues.any((String s) => s.contains('照抄')));
  }
  {
    _check('E5 空表 → 报空',
        MilestoneCodec.validate(const <PipelineMilestone>[]).isNotEmpty);
  }

  // =========================================================================
  // F 组：L1 里程碑规划提示词（线性补齐语义必须在里面）
  // =========================================================================
  {
    const PipelineAnchor a = PipelineAnchor(
      start: '开篇：主角刚接手夜班',
      end: '结局：主角做出最终选择',
      startLabel: '全书起点',
      endLabel: '全书终点',
    );
    final String p = LayeredPrompts.milestonePlan(
      anchor: a,
      count: 4,
      unitZh: '卷',
      worldContext: '书名：《测试书》',
    );
    _check('F1 含段数', p.contains('4 段'));
    _check('F2 含起点终点内容', p.contains('主角刚接手夜班') && p.contains('做出最终选择'));
    _check('F3 含线性推进要求', p.contains('线性推进要求'));
    _check('F4 含分位说明', p.contains('1/4') || p.contains('25%'));
    _check('F5 含「不要第 1 段就写完终点」的约束',
        p.contains('不要') && p.contains('第 1 段'));
    _check('F6 含 JSON 输出契约', p.contains('"endState"'));
    _check('F7 含作品设定', p.contains('书名：《测试书》'));
  }

  // =========================================================================
  // G 组：L3 细纲提示词（含伏笔小节契约）
  // =========================================================================
  {
    final String p = LayeredPrompts.chapterBrief(
      globalOrder: 3,
      totalChapters: 15,
      chapterLabel: '第3章·《夜班》',
      volumeLabel: '第 1 卷',
      chapterMilestone: const PipelineMilestone(
        index: 3, total: 5, label: '夜班', endState: '沈砚拿到登记册',
      ),
      previousChapterState: '沈砚接到周晓棠的电话',
      volumeOutline: '本卷讲退潮四十分钟。',
      foreshadowObligations: '【伏笔联动】\n- T001：需在本章回收',
    );
    _check('G1 含本章起终点', p.contains('沈砚接到周晓棠的电话') && p.contains('沈砚拿到登记册'));
    _check('G2 含 8 行输出契约', p.contains('标题：《本章正式章名》') && p.contains('故事时间节点：'));
    _check('G3 含伏笔小节契约', p.contains('## 伏笔提示'));
    _check('G4 含伏笔义务', p.contains('T001'));
    _check('G5 含全书序号', p.contains('第 3/15 章'));
  }

  // =========================================================================
  // H 组：L4 正文分片提示词
  // =========================================================================
  {
    final String first = LayeredPrompts.proseSlice(
      bookTitle: '测试书',
      chapterLabel: '第1章',
      sliceIndex: 1,
      askChars: 1400,
      chapterBrief: '本章目标：开篇',
      tailContext: '',
      isFirstSlice: true,
    );
    _check('H1 首片说明「从第一句开始」', first.contains('从本章第一句开始'));
    _check('H2 含字数硬要求', first.contains('不少于 1400 字'));
    _check('H3 首片无「前文末尾」块', !first.contains('前文末尾'));

    final String next = LayeredPrompts.proseSlice(
      bookTitle: '测试书',
      chapterLabel: '第1章',
      sliceIndex: 2,
      askChars: 900,
      chapterBrief: '本章目标：开篇',
      tailContext: '前文最后一段。',
      foreshadowBlock: '【伏笔联动】\n- T001：回收',
      isFirstSlice: false,
    );
    _check('H4 续片含「第 2 片」', next.contains('第 2 片'));
    _check('H5 续片含前文末尾', next.contains('前文最后一段。'));
    _check('H6 续片含「不得重复」约束', next.contains('不得与前文末尾重复'));
    _check('H7 续片含伏笔块', next.contains('T001'));
  }

  // =========================================================================
  // I 组：JSON 往返（toJson → fromJson）
  // =========================================================================
  {
    const PipelineMilestone m = PipelineMilestone(
      index: 2, total: 3, label: '卷二', endState: '状态二',
    );
    final Map<String, Object?> j = m.toJson();
    _check('I1 toJson 字段', j['index'] == 2 && j['label'] == '卷二');
    final PipelineMilestone back = PipelineMilestone.fromJson(j, 3);
    _check('I2 往返一致',
        back.index == m.index && back.label == m.label && back.endState == m.endState);
    _check('I3 往返后可 JSON 序列化',
        jsonEncode(back.toJson()).contains('状态二'));
  }
  {
    // 层级标签
    _check('I4 层级中文名',
        PipelineLevel.mainOutline.labelZh == '主线大纲' &&
            PipelineLevel.chapterProse.labelZh == '章节正文');
    _check('I5 单元中文名',
        PipelineLevel.volumeOutline.unitZh == '章' &&
            PipelineLevel.chapterProse.unitZh == '片');
  }

  // =========================================================================
  // J 组：结构化输出清洗 + 细纲契约校验（+50 实测三类污染的对策）
  // =========================================================================
  {
    // ① 开场白（实测原文）
    const String polluted = '好的，我已经仔细核查了您提供的细纲。以下是修正后的完整版本，'
        '所有问题均已解决：\n---\n**第1章·夜班与传闻**\n'
        '标题：《夜班与传闻》\n本章目标：沈砚接手夜班。\n'
        '承接上文：他刚下班。\n核心冲突：传闻与职业习惯冲突。\n'
        '关键转折：他听到退潮的声响。\n章末钩子：钟指向三点。\n'
        '出场人物：沈砚、周晓棠。\n故事时间节点：入秋第三日。';
    final String cleaned =
        LayeredBookGenerationService.cleanStructured(polluted);
    _check('J1 开场白被剥掉', !cleaned.startsWith('好的'));
    _check('J2 分隔线被剥掉', !cleaned.contains('---'));
    _check('J3 强调符被剥掉', !cleaned.contains('**'));
    _check('J4 从契约行开始', cleaned.startsWith('标题：') ||
        cleaned.startsWith('第1章'));
    _check('J5 契约字段保留', cleaned.contains('本章目标') &&
        cleaned.contains('章末钩子'));
  }
  {
    // ② 代码围栏
    const String fenced = '```json\n[{"index":1,"label":"a","endState":"b"}]\n```';
    final String cleaned = LayeredBookGenerationService.cleanStructured(fenced);
    _check('J6 围栏被剥掉', !cleaned.contains('```'));
    _check('J7 JSON 主体保留', cleaned.startsWith('[') && cleaned.contains('endState'));
  }
  {
    // ③ 模板占位行原样回抄（实测原文）
    const String template = '标题：《本章正式章名》\n本章目标：…\n'
        '## 伏笔提示\n'
        '- Txxx（第A章 → 第B章；提醒第C章）：一句话方向（≤50 字，越模糊越好）\n'
        '- T012（第12章 → 第28章）：一枚旧铜钱始终没被提起。';
    final String cleaned = LayeredBookGenerationService.cleanStructured(template);
    _check('J8 模板占位行被丢弃', !cleaned.contains('Txxx'));
    _check('J9 「第A章」占位被丢弃', !cleaned.contains('第A章'));
    _check('J10 真实伏笔行保留', cleaned.contains('T012'));
  }
  {
    // 细纲契约校验
    _check('J11 合格细纲通过', LayeredBookGenerationService.looksLikeChapterBrief(
        '标题：《x》\n本章目标：a\n承接上文：b\n核心冲突：c\n关键转折：d\n'
        '章末钩子：e\n出场人物：f'));
    _check('J12 只有 2 个字段 → 不合格',
        !LayeredBookGenerationService.looksLikeChapterBrief(
            '本章目标：a\n承接上文：b\n其余都是散文。'));
    _check('J13 对话式散文 → 不合格',
        !LayeredBookGenerationService.looksLikeChapterBrief(
            '好的，我帮你改好了。这是一段没有任何字段名的说明文字。'));
    _check('J14 空文本 → 不合格',
        !LayeredBookGenerationService.looksLikeChapterBrief(''));
  }
  {
    // 空输入 / 无契约行的输入
    _check('J15 空输入清洗不崩',
        LayeredBookGenerationService.cleanStructured('') == '');
    // 没有任何契约行 → 不剥（通用函数不猜语义，交给调用方的契约校验兜底）
    _check('J16 无契约行 → 原样返回',
        LayeredBookGenerationService.cleanStructured('好的，这是结果：') ==
            '好的，这是结果：');
    // 但「开场白 + 契约行」一定会剥掉开场白（J1/J4 已覆盖），这里再锁一次边界：
    _check('J17 开场白在前、契约行在后 → 从契约行开始', () {
      final String c = LayeredBookGenerationService.cleanStructured(
          '好的，结果如下：\n本章目标：a\n核心冲突：b\n关键转折：c\n章末钩子：d');
      return c.startsWith('本章目标：');
    }());
  }

  {
    // ④ 指令回显（+50 实测第四类污染）：自查轮把自查清单抄进结果
    const String echoed = '标题：《灯塔下的秘密》\n'
        '本章目标：沈砚发现低潮图书馆。\n'
        '承接上文：他刚接手夜班。\n'
        '核心冲突：是否介入。\n'
        '关键转折：他听到潮声。\n'
        '章末钩子：钟指向三点。\n'
        '出场人物：沈砚、周晓棠\n'
        '故事时间节点：入秋第三日。\n'
        '## 伏笔提示\n'
        '- T012（第12章 → 第28章）：一枚旧铜钱始终没被提起。\n'
        '请自查：\n'
        '① 本章终点「灯塔下的暗示」是否已在细纲里落实；\n'
        '② 承接上文是否与上一章状态一致；\n'
        '④ 回收章必须晚于埋线章至少 2 章。\n'
        '有问题就修正，没问题就原样重发。输出完整细纲';
    final String cleaned = LayeredBookGenerationService.cleanStructured(echoed);
    _check('J18 指令回显被截断', !cleaned.contains('请自查'));
    _check('J19 自查条目被截断', !cleaned.contains('①'));
    _check('J20 真实内容保留', cleaned.contains('标题：《灯塔下的秘密》') &&
        cleaned.contains('章末钩子'));
    _check('J21 真实伏笔行保留', cleaned.contains('T012'));
    _check('J22 清洗后仍是合格细纲',
        LayeredBookGenerationService.looksLikeChapterBrief(cleaned));
  }
  {
    // 伏笔示例章号必须落在本书范围内（否则模型照抄会产出越界伏笔）
    for (final List<int> book in <List<int>>[
      <int>[1, 5], <int>[2, 12], <int>[3, 50], <int>[5, 50], <int>[48, 50],
    ]) {
      final String p = LayeredPrompts.chapterBrief(
        globalOrder: book[0],
        totalChapters: book[1],
        chapterLabel: '第${book[0]}章',
        volumeLabel: '第 1 卷',
        chapterMilestone: const PipelineMilestone(
          index: 1, total: 1, label: 'x', endState: 'y',
        ),
        previousChapterState: '',
        volumeOutline: '',
      );
      final RegExpMatch? m = RegExp(r'第(\d+)章 → 第(\d+)章').firstMatch(p);
      final bool ok = m != null &&
          int.parse(m.group(1)!) >= 1 &&
          int.parse(m.group(2)!) <= book[1] &&
          int.parse(m.group(2)!) >= int.parse(m.group(1)!) + 2;
      _check('J23-${book[0]}/${book[1]} 示例章号在范围内', ok);
    }
    // 末两章：不允许再埋新伏笔（跨度不足，埋了收不回来）
    for (final int last in <int>[49, 50]) {
      final String p = LayeredPrompts.chapterBrief(
        globalOrder: last,
        totalChapters: 50,
        chapterLabel: '第$last章',
        volumeLabel: '第 1 卷',
        chapterMilestone: const PipelineMilestone(
          index: 1, total: 1, label: 'x', endState: 'y',
        ),
        previousChapterState: '',
        volumeOutline: '',
      );
      _check('J24-$last 末两章禁止埋新伏笔',
          p.contains('不要再埋新的伏笔') && !p.contains('第$last章 → 第'));
    }
  }

  // =========================================================================
  // K 组：细纲解析 / 字段重复检测 / 差异补丁（+50 第二轮：让自查轮真正可用）
  // =========================================================================
  {
    const String brief = '标题：《灯塔下的秘密》\n'
        '本章目标：沈砚发现低潮图书馆。\n'
        '承接上文：他刚接手夜班。\n'
        '核心冲突：是否介入周晓棠的命运。\n'
        '关键转折：他听到退潮的声响。\n'
        '章末钩子：钟指向三点。\n'
        '出场人物：沈砚、周晓棠\n'
        '故事时间节点：入秋第三日。';
    final Map<String, String> f = BriefPatch.parseFields(brief);
    _check('K1 解析出 8 个字段', f.length == 8);
    _check('K2 标题解析正确', f['标题'] == '《灯塔下的秘密》');
    _check('K3 契约字段常量 8 项', kChapterBriefFields.length == 8);
    _check('K4 合格细纲通过校验', BriefPatch.looksLikeBrief(brief));
    _check('K5 无字段文本不通过', !BriefPatch.looksLikeBrief('一段散文。'));
    _check('K6 无重复时返回空表',
        BriefPatch.duplicatedFields(brief).isEmpty);
  }
  {
    // 字段复制检测（实测第 1 章就是这种形态）
    const String dup = '标题：《x》\n本章目标：同一句话。\n承接上文：别的话。\n'
        '核心冲突：同一句话。\n关键转折：同一句话。\n章末钩子：钩子。\n'
        '出场人物：甲乙\n故事时间节点：某日。';
    final List<String> d = BriefPatch.duplicatedFields(dup);
    _check('K7 检出重复', d.isNotEmpty);
    _check('K8 检出 3 对（目标/冲突/转折两两相同）', d.length == 3);
    _check('K9 重复对格式可读',
        d.contains('本章目标==核心冲突') && d.contains('核心冲突==关键转折'));
  }
  {
    const String brief = '标题：《旧题》\n本章目标：目标A\n承接上文：承接A\n'
        '核心冲突：目标A\n关键转折：转折A\n章末钩子：钩子A\n'
        '出场人物：甲乙\n故事时间节点：某日。\n\n## 伏笔提示\n'
        '- T003（第3章 → 第8章）：一枚旧铜钱。';
    // 只回需要改的字段
    const String patch = '核心冲突：沈砚必须在救人与代价之间选择。\n'
        '关键转折：他发现借阅卡背面有自己的名字。';
    final String applied = BriefPatch.apply(brief, patch);
    final Map<String, String> af = BriefPatch.parseFields(applied);
    _check('K10 补丁字段被替换', af['核心冲突'] == '沈砚必须在救人与代价之间选择。');
    _check('K11 第二个补丁字段也替换',
        af['关键转折'] == '他发现借阅卡背面有自己的名字。');
    _check('K12 未提及字段保持原样', af['本章目标'] == '目标A' && af['标题'] == '《旧题》');
    _check('K13 伏笔小节保留', applied.contains('T003'));
    _check('K14 补丁后无重复', BriefPatch.duplicatedFields(applied).isEmpty);
    _check('K15 补丁后仍是合格细纲', BriefPatch.looksLikeBrief(applied));
  }
  {
    // 补丁带伏笔小节 → 替换
    const String brief = '标题：《x》\n本章目标：a\n承接上文：b\n核心冲突：c\n'
        '关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g\n\n'
        '## 伏笔提示\n- T001（第1章 → 第5章）：旧线。';
    const String patch = '## 伏笔提示\n- T009（第2章 → 第6章）：新线。';
    final String applied = BriefPatch.apply(brief, patch);
    _check('K16 伏笔小节被替换', applied.contains('T009') && !applied.contains('旧线'));
    _check('K17 8 行保留', applied.contains('本章目标：a') && applied.contains('章末钩子：e'));
  }
  {
    // 无可用字段的补丁 → 原样返回（等价「无需修改」）
    const String brief = '标题：《x》\n本章目标：a\n承接上文：b\n核心冲突：c\n'
        '关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g';
    _check('K18 纯文字补丁不改变细纲',
        BriefPatch.apply(brief, '无需修改') == brief);
    _check('K19 空补丁不改变细纲', BriefPatch.apply(brief, '') == brief);
    // 指令回显型补丁也不会污染
    final String echoed = BriefPatch.apply(brief,
        '请核验以下 4 点：\n① 本章终点是否落实\n关键转折：真正要改的转折');
    _check('K20 回显型补丁只取字段行', echoed.contains('关键转折：真正要改的转折'));
    _check('K21 回显文字未进细纲', !echoed.contains('请核验') && !echoed.contains('①'));
  }
  {
    // 自查提示词：必须要求「只回字段」且带重复清单
    const String brief = '标题：《x》\n本章目标：同一句\n承接上文：b\n'
        '核心冲突：同一句\n关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g';
    final String p = BriefPatch.selfCheckPrompt(
      brief: brief, milestoneEndState: '终点状态X', totalChapters: 12,
    );
    _check('K22 含待核验细纲', p.contains('【待核验的章节细纲】'));
    _check('K23 含里程碑终点', p.contains('终点状态X'));
    _check('K24 含章号范围', p.contains('1~12'));
    _check('K25 要求只回字段行', p.contains('只输出需要修改的字段行'));
    _check('K26 含「无需修改」约定', p.contains('无需修改'));
    _check('K27 带出已检出的重复', p.contains('本章目标==核心冲突'));
    _check('K28 禁止复述清单', p.contains('不要复述'));
  }

  // =========================================================================
  // L 组：splitBrief（+51 修复：裸行 `伏笔提示：` 会让 indexOf 返回 -1 而崩溃）
  // =========================================================================
  {
    const String withHash = '标题：《灯塔》\n本章目标：a\n承接上文：b\n'
        '核心冲突：c\n关键转折：d\n章末钩子：e\n出场人物：f\n'
        '故事时间节点：g\n\n## 伏笔提示\n- T001（第1章 → 第5章）：旧线。';
    final ({String body, String? section}) a = BriefPatch.splitBrief(withHash);
    _check('L1 有 ## 标题时 section 非空', a.section != null);
    _check('L2 body 不含伏笔小节', !a.body.contains('T001'));
    _check('L3 body 保留 8 行', a.body.contains('本章目标：a') && a.body.contains('故事时间节点：g'));
    _check('L4 section 含伏笔行', a.section!.contains('T001'));
  }
  {
    // ⚠ 关键回归：裸行 `伏笔提示：`（无 ##）—— 旧实现 indexOf('## 伏笔提示') == -1
    const String bare = '标题：《灯塔》\n本章目标：a\n承接上文：b\n'
        '核心冲突：c\n关键转折：d\n章末钩子：e\n出场人物：f\n'
        '故事时间节点：g\n\n伏笔提示：\n- T002（第2章 → 第6章）：裸行形态。';
    final ({String body, String? section}) b = BriefPatch.splitBrief(bare);
    _check('L5 裸行标题不崩且 section 非空', b.section != null);
    _check('L6 裸行 body 不含伏笔行', !b.body.contains('T002'));
    _check('L7 裸行 body 保留 8 行', b.body.contains('故事时间节点：g'));
    _check('L8 裸行 section 规范化为 ##', b.section!.startsWith('## 伏笔提示'));
  }
  {
    const String none = '标题：《灯塔》\n本章目标：a\n承接上文：b\n'
        '核心冲突：c\n关键转折：d\n章末钩子：e\n出场人物：f\n'
        '故事时间节点：g';
    final ({String body, String? section}) c = BriefPatch.splitBrief(none);
    _check('L9 无伏笔小节 → section 为 null', c.section == null);
    _check('L10 无伏笔小节 → body 为全文', c.body.contains('故事时间节点：g'));
  }
  {
    // 空小节（只有标题没有内容）→ section 为 null，但 body 必须去掉标题行
    const String emptySec = '标题：《灯塔》\n本章目标：a\n承接上文：b\n'
        '核心冲突：c\n关键转折：d\n章末钩子：e\n出场人物：f\n'
        '故事时间节点：g\n\n## 伏笔提示';
    final ({String body, String? section}) d = BriefPatch.splitBrief(emptySec);
    _check('L11 空小节 → section 为 null', d.section == null);
    _check('L12 空小节 → body 不含标题行', !d.body.contains('伏笔提示'));
    _check('L13 空小节 → body 保留 8 行', d.body.contains('故事时间节点：g'));
  }
  {
    // body 必须能安全喂给 substring 类操作：长度恒 >= 0 且非负
    for (final String t in <String>[
      '伏笔提示：', '## 伏笔提示', '', '标题：x', '\n\n## 伏笔提示\n- T001（第1章 → 第3章）：x',
    ]) {
      final ({String body, String? section}) r = BriefPatch.splitBrief(t);
      _check('L14-${t.length} splitBrief 不崩且 body 长度非负',
          r.body.length >= 0 && r.section == null || r.section!.isNotEmpty);
    }
  }

  // =========================================================================
  // M 组：服务端 `>` 前缀剥离（+51 真机实测：本部署每条 completion 都带 `>`）
  // =========================================================================
  {
    const String brief = '>标题：《潮声与灯塔》\n本章目标：a\n承接上文：b\n'
        '核心冲突：c\n关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g';
    final String cleaned = LayeredBookGenerationService.cleanStructured(brief);
    _check('M1 开头的 > 被剥离', !cleaned.startsWith('>'));
    _check('M2 剥离后仍是合格细纲',
        BriefPatch.looksLikeBrief(cleaned));
    _check('M3 剥离后「标题」字段可解析',
        BriefPatch.parseFields(cleaned)['标题'] == '《潮声与灯塔》');
    _check('M4 剥离后 8 字段齐全',
        BriefPatch.parseFields(cleaned).length == 8);
  }
  {
    const String json = '> [{"index":1,"label":"卷名","endState":"状态"}]';
    final String cleaned = LayeredBookGenerationService.cleanStructured(json);
    _check('M5 JSON 前的 > 被剥离', cleaned.trimLeft().startsWith('['));
  }
  {
    // 只剥「开头连续段」：正文里合法的引用不能被误伤
    const String mixed = '标题：x\n本章目标：a\n承接上文：b\n核心冲突：c\n'
        '关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g\n'
        '> 这是一行正文里的引用';
    final String cleaned = LayeredBookGenerationService.cleanStructured(mixed);
    _check('M6 非开头的 > 保留', cleaned.contains('> 这是一行正文里的引用'));
  }
  {
    const String blankThenQuote = '\n\n>标题：《x》\n本章目标：a\n承接上文：b\n'
        '核心冲突：c\n关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g';
    final String cleaned =
        LayeredBookGenerationService.cleanStructured(blankThenQuote);
    _check('M7 空行之后的 > 也被剥离', !cleaned.contains('>标题'));
    _check('M8 剥离后标题可解析',
        BriefPatch.parseFields(cleaned)['标题'] == '《x》');
  }
  {
    // 幂等：已经干净的输入不应被改变
    const String clean = '标题：《x》\n本章目标：a\n承接上文：b\n核心冲突：c\n'
        '关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g';
    _check('M9 干净输入保持不变',
        LayeredBookGenerationService.cleanStructured(clean) == clean);
  }

  print('layered_pipeline_selftest: $_passed passed, $_failed failed');
  if (_failed > 0) {
    throw StateError('layered_pipeline_selftest FAILED: $_failed assertion(s)');
  }
}
