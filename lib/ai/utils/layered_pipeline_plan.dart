// 分层写书管线 —— **纯规则层**（锚点 / 里程碑线性补齐 / 提示词 / 校验）。
//
// 用户要求（+50）：
//   「串行写纲要，大纲和细纲还有正文部分可以串行写，这些都可以预设起点和终点来
//    线性补齐过程，然后可以根据串行书写的主线大纲并行书写分卷大纲（串行），
//    然后通过分卷大纲并行书写章节细纲（串行），再根据章节细纲并行书写每一章的
//    正文（串行）……参考 WeaveGrid 的上下文交互设计理念……要贴合 RWKV 模型的特性。」
//
// 四级管线（每级：**单元间并行 / 单元内串行**）：
//
//   L1 主线大纲      1 个单元（串行）           → 产出 K 个「卷末必须到达的状态」
//   L2 分卷大纲      卷数 K 个单元（卷间并行）  → 每卷产出 M 个「章末里程碑」
//   L3 章节细纲      K×M 个单元（章间并行）    → 每章产出结构化细纲 + 伏笔提示
//   L4 正文          K×M 个单元（章间并行）    → 每章分片串行续写
//
// 「预设起点和终点、线性补齐过程」的落地：每级都持有一对**锚**
// （[PipelineAnchor]：起点状态 / 终点状态），并把弧线**按单元数均分**成
// [PipelineMilestone] 序列；第 i 个单元结束时必须落在整条弧线的 i/K 分位。
// 这样既不会「第一段就把终点写完」，也不会「最后一段还停在起点」。
//
// 本文件**零 IO、零 import**（除 dart:convert 用于 JSON 解析），可直接离线自检：
//   dart --disable-dart-dev tools/layered_pipeline_selftest.dart
library;

import 'dart:convert';

/// 管线层级。
enum PipelineLevel {
  /// 主线大纲（全书 1 个单元）。
  mainOutline,

  /// 分卷大纲（每卷 1 个单元，卷间并行）。
  volumeOutline,

  /// 章节细纲（每章 1 个单元，章间并行）。
  chapterBrief,

  /// 章节正文（每章 1 个单元，章间并行；单元内分片串行）。
  chapterProse,
}

extension PipelineLevelLabel on PipelineLevel {
  String get labelZh => switch (this) {
        PipelineLevel.mainOutline => '主线大纲',
        PipelineLevel.volumeOutline => '分卷大纲',
        PipelineLevel.chapterBrief => '章节细纲',
        PipelineLevel.chapterProse => '章节正文',
      };

  /// 单元的中文名（用于提示词与日志）。
  String get unitZh => switch (this) {
        PipelineLevel.mainOutline => '卷',
        PipelineLevel.volumeOutline => '章',
        PipelineLevel.chapterBrief => '章',
        PipelineLevel.chapterProse => '片',
      };
}

/// 一对锚：起点状态 + 终点状态。
///
/// 「状态」是**剧情状态**（人物处境、已知信息、未解冲突），不是字数。
class PipelineAnchor {
  const PipelineAnchor({
    required this.start,
    required this.end,
    this.startLabel = '起点',
    this.endLabel = '终点',
  });

  final String start;
  final String end;
  final String startLabel;
  final String endLabel;

  bool get isComplete => start.trim().isNotEmpty && end.trim().isNotEmpty;

  /// 提示词片段（两个锚都为空时返回空串 —— 允许「无锚」退化模式）。
  String render() {
    if (!isComplete) return '';
    return '【$startLabel】\n${start.trim()}\n\n'
        '【$endLabel】\n${end.trim()}';
  }
}

/// 一个里程碑：第 [index] 个单元（共 [total] 个）结束时必须到达的状态。
class PipelineMilestone {
  const PipelineMilestone({
    required this.index,
    required this.total,
    required this.label,
    required this.endState,
  });

  /// 1 起的序号。
  final int index;
  final int total;

  /// 单元名（卷名 / 章名）。
  final String label;

  /// 本单元结束时必须到达的状态（**线性补齐的插值锚**）。
  final String endState;

  /// 在整条弧线上的推进比例（i / K）。
  double get ratio => total <= 0 ? 1.0 : index / total;

  /// 百分比文案（如 `40%`）。
  String get ratioLabel => '${(ratio * 100).round()}%';

  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'label': label,
        'endState': endState,
      };

  static PipelineMilestone fromJson(Map<String, Object?> m, int total) {
    final Object? idx = m['index'];
    final int index = idx is num
        ? idx.toInt()
        : (int.tryParse('${m['index'] ?? ''}') ?? 1);
    return PipelineMilestone(
      index: index < 1 ? 1 : index,
      total: total,
      label: (m['label'] ?? m['name'] ?? m['title'] ?? '').toString().trim(),
      endState: (m['endState'] ??
              m['state'] ??
              m['ending'] ??
              m['end_state'] ??
              m['summary'] ??
              '')
          .toString()
          .trim(),
    );
  }
}

/// 里程碑编解码 + 校验（纯函数）。
abstract final class MilestoneCodec {
  /// 解析模型输出为里程碑列表。
  ///
  /// 容错两种形态：
  ///   ① JSON（数组，或 `{"milestones": [...]}` 包裹），字段名容错见
  ///      [PipelineMilestone.fromJson]；
  ///   ② 行式：`第1卷《卷名》：状态描述` / `1. 卷名 —— 状态` / `1) 卷名：状态`。
  ///
  /// 识别不到任何里程碑时返回空表（调用方据此走兜底）。
  static List<PipelineMilestone> parse(String raw, {required int total}) {
    final String text = _stripFence(raw.trim());
    if (text.isEmpty || total <= 0) return const <PipelineMilestone>[];

    final List<PipelineMilestone> fromJson = _tryJson(text, total);
    if (fromJson.isNotEmpty) return fromJson;
    return _tryLines(text, total);
  }

  static List<PipelineMilestone> _tryJson(String text, int total) {
    final int start = text.indexOf('[');
    final int startObj = text.indexOf('{');
    // 取更靠前的那个作为 JSON 起点
    int at = -1;
    if (start >= 0 && (startObj < 0 || start < startObj)) {
      at = start;
    } else if (startObj >= 0) {
      at = startObj;
    }
    if (at < 0) return const <PipelineMilestone>[];
    final int endBracket = text.lastIndexOf(']');
    final int endBrace = text.lastIndexOf('}');
    final int end = endBracket > endBrace ? endBracket : endBrace;
    if (end <= at) return const <PipelineMilestone>[];
    Object? decoded;
    try {
      decoded = jsonDecode(text.substring(at, end + 1));
    } on Object {
      return const <PipelineMilestone>[];
    }
    List<Object?>? items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map) {
      for (final String key in <String>['milestones', 'items', 'list', 'units']) {
        final Object? v = decoded[key];
        if (v is List) {
          items = v;
          break;
        }
      }
    }
    if (items == null) return const <PipelineMilestone>[];
    final List<PipelineMilestone> out = <PipelineMilestone>[];
    for (final Object? item in items) {
      // ⚠ 实测（+50）：模型极常**忽略对象 schema**，直接返回「状态句子的字符串数组」。
      // 这是合法且有用的输出形态 —— 按位置当作 endState 收下，不要判为解析失败
      //（判失败会退到行式解析，把整段 JSON 拆成垃圾里程碑）。
      if (item is String) {
        final String s = item.trim();
        if (s.isEmpty) continue;
        out.add(PipelineMilestone(
          index: out.length + 1,
          total: total,
          label: '',
          endState: s,
        ));
        continue;
      }
      if (item is! Map) continue;
      final PipelineMilestone m = PipelineMilestone.fromJson(
        item.map((Object? k, Object? v) =>
            MapEntry<String, Object?>('$k', v)),
        total,
      );
      if (m.endState.isEmpty && m.label.isEmpty) continue;
      out.add(m);
    }
    return out;
  }

  static final RegExp _linePattern = RegExp(
    r'^\s*(?:[-*•]|\d+\s*[.、)）])\s*',
  );
  static final RegExp _labelTail = RegExp(
    r'(?:第\s*\d+\s*[卷章节]|\d+\s*[.、)）])?\s*[《【]?([^》】：:—-]{1,40})[》】]?',
  );

  static List<PipelineMilestone> _tryLines(String text, int total) {
    final List<PipelineMilestone> out = <PipelineMilestone>[];
    for (final String rawLine in text.split(RegExp(r'\r\n|\r|\n'))) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('{')) continue;
      // 只认「有分隔符」的行（：/—— /-），否则会把普通句子当里程碑。
      final RegExpMatch? sep =
          RegExp(r'[：:]|——|--|\s-\s').firstMatch(line);
      if (sep == null) continue;
      String head = line.substring(0, sep.start).trim();
      final String tail = line.substring(sep.end).trim();
      if (tail.isEmpty) continue;
      head = head.replaceFirst(_linePattern, '').trim();
      String label = head;
      final RegExpMatch? lm = _labelTail.firstMatch(head);
      if (lm != null && (lm.group(1) ?? '').trim().isNotEmpty) {
        label = lm.group(1)!.trim();
      }
      out.add(PipelineMilestone(
        index: out.length + 1,
        total: total,
        label: label,
        endState: tail,
      ));
    }
    return out;
  }

  static String _stripFence(String text) {
    final RegExpMatch? m =
        RegExp(r'```(?:json)?([\s\S]*?)```', multiLine: true).firstMatch(text);
    return m == null ? text : m.group(1)!.trim();
  }

  /// 把解析结果规整到**恰好 [total] 个**里程碑。
  ///
  /// 少了 → 用空状态补齐（并在校验里报「缺项」）；多了 → 截断。
  /// 序号一律重排为 1..total（模型常给错序号）。
  static List<PipelineMilestone> normalise(
    List<PipelineMilestone> parsed,
    int total,
  ) {
    if (total <= 0) return const <PipelineMilestone>[];
    final List<PipelineMilestone> out = <PipelineMilestone>[];
    for (int i = 0; i < total; i++) {
      final PipelineMilestone? src = i < parsed.length ? parsed[i] : null;
      out.add(PipelineMilestone(
        index: i + 1,
        total: total,
        label: src?.label ?? '',
        endState: src?.endState ?? '',
      ));
    }
    return out;
  }

  /// 结构校验（返回人类可读的问题清单；空表 = 通过）。
  ///
  /// 只做**可判定**的检查，不做语义判断：
  ///   * 数量不符 / 状态为空 → error；
  ///   * 末尾状态与首条完全相同（等于没推进）→ warning；
  ///   * 锚存在时，末条状态与终点锚完全一致（模型偷懒照抄）→ warning。
  static List<String> validate(
    List<PipelineMilestone> milestones, {
    PipelineAnchor? anchor,
  }) {
    final List<String> issues = <String>[];
    if (milestones.isEmpty) {
      issues.add('里程碑为空');
      return issues;
    }
    final int empty = milestones
        .where((PipelineMilestone m) => m.endState.trim().isEmpty)
        .length;
    if (empty > 0) issues.add('$empty 个里程碑的状态描述为空');
    final Set<String> distinct = <String>{
      for (final PipelineMilestone m in milestones) m.endState.trim(),
    };
    if (distinct.length <= 1 && milestones.length > 1) {
      issues.add('所有里程碑状态相同 —— 弧线没有推进');
    }
    final PipelineAnchor? a = anchor;
    if (a != null && a.isComplete) {
      final String last = milestones.last.endState.trim();
      if (last == a.end.trim()) {
        issues.add('末条状态与终点锚逐字相同 —— 疑似照抄而非推导');
      }
    }
    return issues;
  }
}

/// 分层提示词组装（纯字符串，便于离线核对）。
abstract final class LayeredPrompts {
  /// L1：把「起点 → 终点」的弧线**均分成 K 段**，产出每段的终点状态。
  static String milestonePlan({
    required PipelineAnchor anchor,
    required int count,
    required String unitZh,
    String worldContext = '',
    String extra = '',
    String labelHint = '单元名（8~14 字的文学化名称）',
    String stateHint = '本单元结束时必须到达的剧情状态（40~80 字）',
    String jsonExample = '',
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('任务：把一条剧情弧线**均分成 $count 段**，给出每一段结束时必须到达的状态。');
    b.writeln();
    if (worldContext.trim().isNotEmpty) {
      b.writeln('【作品设定】');
      b.writeln(worldContext.trim());
      b.writeln();
    }
    b.writeln(anchor.render());
    b.writeln();
    b.writeln('【线性推进要求（重要）】');
    b.writeln('- 整条弧线从「${anchor.startLabel}」走到「${anchor.endLabel}」，'
        '请把它**均匀切成 $count 段**；');
    b.writeln('- 第 i 段结束时，剧情应推进到整条弧线的约 i/$count 分位：'
        '第 1 段只完成 ${(100 / count).round()}%，'
        '第 $count 段必须**恰好**到达「${anchor.endLabel}」；');
    b.writeln('- **不要**在第 1 段就把终点事件写完，也**不要**到最后一段还停在起点状态；');
    b.writeln('- 每段的状态描述要写「人物处境 + 已解决什么 + 新暴露什么」，'
        '40~80 字，具体到可判定，不要写「继续推进」这类空话。');
    if (extra.trim().isNotEmpty) {
      b.writeln('- $extra');
    }
    b.writeln();
    b.writeln('【字段含义（务必按此填，别填反）】');
    b.writeln('- `label`：$labelHint');
    b.writeln('- `endState`：$stateHint');
    b.writeln();
    b.writeln('只输出 JSON **数组**（数组元素必须是**对象**，不是字符串），'
        '不要解释、不要 Markdown 围栏：');
    b.writeln(jsonExample.isEmpty
        ? '[{"index":1,"label":"第1${unitZh}的$labelHint","endState":"第1${unitZh}结束时必须到达的状态"},'
            '{"index":2,"label":"…","endState":"…"}]'
        : jsonExample);
    b.writeln();
    b.writeln('⚠ 硬性格式要求：回复的**第一个字符必须是 `[`**，最后一个字符必须是 `]`；'
        '禁止在 JSON 前后写任何说明文字、标题、分隔线或 Markdown 代码围栏。');
    return b.toString().trim();
  }

  /// L2：为**一个卷**生成分卷大纲（单元内串行 —— 逐章推进）。
  static String volumeOutline({
    required int volumeIndex,
    required int volumeCount,
    required String volumeLabel,
    required PipelineMilestone volumeMilestone,
    required List<PipelineMilestone> chapterMilestones,
    required String previousVolumeTail,
    required String mainOutline,
    String worldContext = '',
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('任务：为《$volumeLabel》（第 $volumeIndex/$volumeCount 卷）'
        '撰写本卷大纲，并给出本卷 ${chapterMilestones.length} 个章节的推进顺序。');
    b.writeln();
    if (worldContext.trim().isNotEmpty) {
      b.writeln('【作品设定】');
      b.writeln(worldContext.trim());
      b.writeln();
    }
    b.writeln('【全书主线大纲】');
    b.writeln(mainOutline.trim());
    b.writeln();
    if (previousVolumeTail.trim().isNotEmpty) {
      b.writeln('【上一卷结尾状态】');
      b.writeln(previousVolumeTail.trim());
      b.writeln();
    }
    b.writeln('【本卷起点 → 本卷终点】');
    b.writeln('起点：${previousVolumeTail.trim().isEmpty ? '全书开篇' : '见上一卷结尾状态'}');
    b.writeln('终点（本卷结束时必须到达）：${volumeMilestone.endState}');
    b.writeln();
    b.writeln('【本卷各章必须到达的里程碑（已按线性推进排好，不要改动顺序与归属）】');
    for (final PipelineMilestone m in chapterMilestones) {
      b.writeln('第 ${m.index} 章（推进到全卷 ${m.ratioLabel}）：${m.endState}');
    }
    b.writeln();
    b.writeln('请输出：');
    b.writeln('1. 本卷的核心冲突与阶段目标（100~200 字）；');
    b.writeln('2. 逐章安排（每章 1 行）：`第N章｜章名｜本章要推进到什么`，'
        '必须与上面的里程碑一致；');
    b.writeln('3. 本卷埋下、需要在后卷回收的长线伏笔（若有，每行一条，'
        '格式 `- Txxx（第A章 → 第B章）：一句话方向`，不确定就留空）。');
    return b.toString().trim();
  }

  /// L3：为一章生成结构化细纲（含伏笔提示）。
  ///
  /// ⚠ 伏笔示例里的章号**必须落在本书范围内**：+50 实测模型会照抄示例章号，
  /// 之前写死 `第12章 → 第28章`，在 5 章的书里直接产出「回收章超出全书」的
  /// 无效伏笔（10 条结构错误里有 5 条来自这里）。
  static String chapterBrief({
    required int globalOrder,
    required int totalChapters,
    required String chapterLabel,
    required String volumeLabel,
    required PipelineMilestone chapterMilestone,
    required String previousChapterState,
    required String volumeOutline,
    String foreshadowObligations = '',
    String worldContext = '',
  }) {
    final StringBuffer b = StringBuffer();
    final int payoffExample = _examplePayoff(globalOrder, totalChapters);
    // 跨度纪律：埋线章之后必须还留得下 ≥2 章，否则本章不许埋新线
    final bool canPlant = globalOrder + kMinForeshadowSpan <= totalChapters;
    b.writeln('任务：为《$chapterLabel》（全书第 $globalOrder/$totalChapters 章，'
        '所属《$volumeLabel》）撰写章节细纲。');
    b.writeln();
    if (worldContext.trim().isNotEmpty) {
      b.writeln('【作品设定】');
      b.writeln(worldContext.trim());
      b.writeln();
    }
    b.writeln('【本卷大纲】');
    b.writeln(volumeOutline.trim());
    b.writeln();
    b.writeln('【本章起点 → 本章终点】');
    b.writeln('起点（上一章结束时的状态）：'
        '${previousChapterState.trim().isEmpty ? '本卷开篇' : previousChapterState.trim()}');
    b.writeln('终点（本章结束时必须到达）：${chapterMilestone.endState}');
    b.writeln();
    if (foreshadowObligations.trim().isNotEmpty) {
      b.writeln(foreshadowObligations.trim());
      b.writeln();
    }
    b.writeln('请严格按以下 8 行输出（不要 Markdown 标记、不要解释）：');
    b.writeln('⚠ 8 行必须**各写各的、内容互不重复**（尤其「本章目标 / 核心冲突 / 关键转折」'
        '三者绝不能是同一句话——实测这种字段复制会让正文反复写同一个节拍、'
        '直接推高复读率）。');
    b.writeln('标题：《本章正式章名》');
    b.writeln('本章目标：…');
    b.writeln('承接上文：…');
    b.writeln('核心冲突：…');
    b.writeln('关键转折：…');
    b.writeln('章末钩子：…');
    b.writeln('出场人物：…');
    b.writeln('故事时间节点：…');
    b.writeln();
    if (canPlant) {
      b.writeln('⚠ **伏笔登记规则**：只要本章出现了「留下未解疑问 / 提前暗示 / 只说了一半」'
          '的写法，就**必须**在 8 行之后登记一条（不要只把它写在正文里却不在细纲登记）；'
          '确实一条都没有，才整节省略。格式：');
      b.writeln('## 伏笔提示');
      b.writeln('- T${_pad3(globalOrder)}（第$globalOrder章 → 第$payoffExample章）：'
          '<一句话方向，≤50 字>');
      b.writeln('（编号用真实数字；回收章必须晚于埋线章至少 2 章、且**不超过全书 '
          '$totalChapters 章** —— 上面这行只是格式示例，'
          '若本章没有伏笔就整节省略，**不要照抄示例的章号**。）');
    } else {
      // 跨度纪律：本章之后已不足 2 章，埋下的线收不回来 → 明确禁止埋新线
      b.writeln('⚠ 本章距全书结尾已不足 2 章，**不要再埋新的伏笔**'
          '（埋了也收不回来）—— 不要输出伏笔小节。');
    }
    b.writeln();
    b.writeln('⚠ 禁止输出上面这些示例行本身（不要写 `Txxx`、`第A章`、`…` 占位符）；'
        '第一个字符必须是 `标`（即直接以「标题：」开头），不要写任何开场白或收尾语。');
    return b.toString().trim();
  }

  static String _pad3(int n) => n.toString().padLeft(3, '0');

  /// 示例回收章：埋线章 + max(2, 全书 40%)，且不超全书、不早于埋线章+2。
  static int _examplePayoff(int setup, int total) {
    int span = (total * 0.4).round();
    if (span < kMinForeshadowSpan) span = kMinForeshadowSpan;
    int payoff = setup + span;
    if (payoff > total) payoff = total;
    if (payoff < setup + kMinForeshadowSpan) {
      payoff = setup + kMinForeshadowSpan;
    }
    return payoff > total ? total : payoff;
  }

  /// 伏笔最小跨度（与 `foreshadow_ledger.dart` 的 `kForeshadowMinSpan` 同值）。
  ///
  /// 这里**刻意重复**一个常量而不是 import 账本文件：本文件要保持「零 import」
  /// 的纯规则属性（可直接 dart 脚本直跑自检），跨文件依赖会破坏这一点。
  static const int kMinForeshadowSpan = 2;

  /// L4：正文分片续写（单元内串行；RWKV 走 state 增量续跑）。
  static String proseSlice({
    required String bookTitle,
    required String chapterLabel,
    required int sliceIndex,
    required int askChars,
    required String chapterBrief,
    required String tailContext,
    String foreshadowBlock = '',
    String worldContext = '',
    bool isFirstSlice = true,
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('任务：写《$bookTitle》《$chapterLabel》的正文'
        '${isFirstSlice ? '（从本章第一句开始）' : '（第 $sliceIndex 片，紧接上文续写）'}。');
    if (worldContext.trim().isNotEmpty) {
      b.writeln('背景：${worldContext.trim()}');
    }
    b.writeln('本章细纲：');
    b.writeln(chapterBrief.trim());
    if (foreshadowBlock.trim().isNotEmpty) {
      b.writeln();
      b.writeln(foreshadowBlock.trim());
    }
    b.writeln();
    if (tailContext.trim().isNotEmpty) {
      b.writeln('【前文末尾（仅供衔接上下文，**不要输出这一段**）】');
      b.writeln(tailContext.trim());
      b.writeln();
      b.writeln('请紧接上文写下去。只输出**新增**的正文，第一句不得与前文末尾重复。');
    }
    b.writeln('篇幅：本片不少于 $askChars 字的成稿正文。这是硬要求。');
    return b.toString().trim();
  }
}

/// 章节细纲的字段契约（顺序即输出顺序）。
///
/// 单列成常量是为了让「解析 / 校验 / 打补丁」三处共用同一份定义 ——
/// 任何一处漏改都会让细纲结构悄悄漂移。
const List<String> kChapterBriefFields = <String>[
  '标题',
  '本章目标',
  '承接上文',
  '核心冲突',
  '关键转折',
  '章末钩子',
  '出场人物',
  '故事时间节点',
];

/// 细纲的解析 / 校验 / 差异补丁（纯函数）。
///
/// **为什么要有「差异补丁」**（+50 实测教训）：
/// 原先的自查轮要求模型「重发整份细纲」，结果模型把**核验清单本身**
/// （`请自查 / ① ② ④ / 有问题就修正`）抄进了输出 —— 既污染细纲，又让
/// 「契约校验」把整份自查结果判为不合格而丢弃（4/5 次）。
/// 改成「只回需要修改的字段行」后：模型没有机会复述清单，token 也省一半。
abstract final class BriefPatch {
  static final RegExp _fieldLine = RegExp(
    r'^\s*(?:[-*•]\s*)?(' + kChapterBriefFields.join('|') + r')\s*[：:]\s*(.*)$',
  );

  /// 解析细纲为「字段 → 值」（未出现的字段不进表）。
  static Map<String, String> parseFields(String brief) {
    final Map<String, String> out = <String, String>{};
    for (final String line in brief.split(RegExp(r'\r\n|\r|\n'))) {
      final RegExpMatch? m = _fieldLine.firstMatch(line);
      if (m == null) continue;
      final String name = m.group(1)!;
      final String value = m.group(2)!.trim();
      if (value.isEmpty) continue;
      out[name] = value;
    }
    return out;
  }

  /// 找出**取值完全相同的字段对**（如 `本章目标 == 关键转折`）。
  ///
  /// 实测：字段复制的细纲会让正文反复写同一个节拍，直接推高复读率
  /// （第 1 章细纲三字段相同 → 该章 ngram 0.154）。
  /// 返回形如 `本章目标==核心冲突` 的字符串列表（按契约顺序）。
  static List<String> duplicatedFields(String brief) {
    final Map<String, String> f = parseFields(brief);
    final List<String> out = <String>[];
    final List<String> keys = <String>[
      for (final String k in kChapterBriefFields)
        if (f.containsKey(k)) k,
    ];
    for (int i = 0; i < keys.length; i++) {
      for (int j = i + 1; j < keys.length; j++) {
        if (f[keys[i]] == f[keys[j]]) {
          out.add('${keys[i]}==${keys[j]}');
        }
      }
    }
    return out;
  }

  /// 细纲是否「合格」：至少命中 4 个契约字段。
  static bool looksLikeBrief(String text) {
    int hit = 0;
    for (final String f in kChapterBriefFields) {
      if (text.contains('$f：') || text.contains('$f:')) hit++;
    }
    return hit >= 4;
  }

  /// 把「差异补丁」合并进细纲。
  ///
  /// 规则（全部确定性，不做语义推断）：
  ///   ① 补丁里出现 `字段：新值` → 替换细纲里该字段那一行；
  ///   ② 补丁里出现 `## 伏笔提示` 小节 → 替换细纲的伏笔小节（没有则追加）；
  ///   ③ 补丁里没有的东西一律**保持原样**（包括非字段行、顺序、空行）；
  ///   ④ 补丁没有任何可识别字段 → 原样返回（等价于「无需修改」）。
  static String apply(String brief, String patch) {
    final Map<String, String> updates = parseFields(patch);
    final String? patchSection = _sectionOf(patch);
    if (updates.isEmpty && patchSection == null) return brief;

    final List<String> out = <String>[];
    for (final String line in brief.split(RegExp(r'\r\n|\r|\n'))) {
      // 伏笔小节交给 ② 处理，先原样跳过（下面统一重建）
      if (_isSectionTitle(line)) break;
      final RegExpMatch? m = _fieldLine.firstMatch(line);
      if (m != null && updates.containsKey(m.group(1))) {
        out.add('${m.group(1)}：${updates[m.group(1)]}');
      } else {
        out.add(line);
      }
    }
    // 伏笔小节：补丁带则用补丁的，否则保留原来的
    final String section =
        patchSection ?? _sectionOf(brief) ?? '';
    final String head = out.join('\n').trimRight();
    return section.isEmpty ? head : '$head\n\n$section';
  }

  /// 自查轮的提示词：要求**只回需要修改的字段**。
  static String selfCheckPrompt({
    required String brief,
    required String milestoneEndState,
    required int totalChapters,
  }) {
    final List<String> dup = duplicatedFields(brief);
    final StringBuffer b = StringBuffer();
    b.writeln('【待核验的章节细纲】');
    b.writeln(brief.trim());
    b.writeln();
    b.writeln('请核验以下 4 点：');
    b.writeln('① 本章终点「$milestoneEndState」是否已在细纲里落实'
        '（本章目标/关键转折/章末钩子要有对应）；');
    b.writeln('② 承接上文是否与上一章状态一致；');
    b.writeln('③ 伏笔提示格式是否为 `- Txxx（第A章 → 第B章）：方向`，'
        '章号在 1~$totalChapters 之间；');
    b.writeln('④ 八个字段的内容**必须互不重复**（目标/冲突/转折不能是同一句话）。');
    if (dup.isNotEmpty) {
      b.writeln('   ⚠ 已检出重复：${dup.join('、')} —— 这几项必须改写。');
    }
    b.writeln();
    b.writeln('【输出格式（务必遵守）】');
    b.writeln('**只输出需要修改的字段行**，每行 `字段名：新内容`；'
        '不需要修改的字段**不要输出**；');
    b.writeln('如果全部合格，只回复两个字：`无需修改`。');
    b.writeln('⚠ 不要复述上面的核验清单（不要写「请核验」「①」「如果全部合格」这类字），'
        '不要写任何解释、开场白或收尾语。');
    b.writeln('示例（只示意格式，内容按你的判断写）：');
    b.writeln('关键转折：<改写后的转折>');
    b.writeln('章末钩子：<改写后的钩子>');
    return b.toString().trim();
  }

  /// 取出细纲里的「伏笔提示」小节文本（含 `## 伏笔提示` 标题；没有则 null）。
  ///
  /// App 侧落库时要把它与 8 行细纲**分开存**（+49 约定：细纲进 `Chapters.summary`，
  /// 伏笔提示进 `Chapters.notes`），所以这里需要一个公开入口。
  static String? foreshadowSection(String brief) => _sectionOf(brief);

  static bool _isSectionTitle(String line) =>
      RegExp(r'^\s*#+\s*伏笔提示').hasMatch(line) ||
      RegExp(r'^\s*伏笔提示\s*[：:]?\s*$').hasMatch(line);

  /// 取出文本里的「伏笔提示」小节（含标题；没有则 null）。
  /// 把细纲拆成「字段正文部分」与「伏笔提示小节」（后者为 null 表示没有）。
  ///
  /// ⚠ **必须用这个方法**，不要用 `content.indexOf('## 伏笔提示')` 自己切：
  /// `_sectionOf` 也接受**不带 `##`** 的标题（如裸行 `伏笔提示：`），
  /// 此时 `indexOf` 返回 -1，调用方做 `substring(0, -1)` 会直接抛 `RangeError`。
  static ({String body, String? section}) splitBrief(String text) {
    final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
    int start = -1;
    for (int i = 0; i < lines.length; i++) {
      if (_isSectionTitle(lines[i])) {
        start = i;
        break;
      }
    }
    if (start < 0) return (body: text.trim(), section: null);
    return (
      body: lines.sublist(0, start).join('\n').trim(),
      section: _sectionOf(text),
    );
  }

  static String? _sectionOf(String text) {
    final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
    int start = -1;
    for (int i = 0; i < lines.length; i++) {
      if (_isSectionTitle(lines[i])) {
        start = i;
        break;
      }
    }
    if (start < 0) return null;
    final List<String> out = <String>['## 伏笔提示'];
    for (int i = start + 1; i < lines.length; i++) {
      final String t = lines[i].trim();
      if (t.isEmpty) continue;
      // 下一个标题 → 小节结束
      if (t.startsWith('#')) break;
      // 指令回显 → 截断
      if (RegExp(r'^(请|⚠|[①②③④])').hasMatch(t)) break;
      out.add(lines[i].trimRight());
    }
    return out.length > 1 ? out.join('\n') : null;
  }
}
