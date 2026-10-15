// 分层写书管线 —— **编排层**（四级：主线 → 分卷 → 细纲 → 正文）。
//
// 用户要求（+50）：层级间串行、层级内「单元间并行 / 单元内串行」，
// 每级用「起点 + 终点」锚定并**线性补齐**中间过程。
//
// 依赖全部**注入**，所以同一份编排既能在 App 里跑（仓库 + provider），
// 也能在命令行跑（文件 sink + 直连 HTTP）：
//   * [LayeredChat]           —— 一次模型调用（`sessionKey` 非空 = 单元内串行链）
//   * [LayeredArtifactSink]   —— 产物落盘/落库
//
// RWKV 贴合点（+50 实测确认）：
//   1. 服务端能力 `session_cache: true` / `concurrent_generation: true` ——
//      **每个单元一条独立 state 链**（`sessionKey`），单元内严格串行、
//      单元间天然并行；这正是「并行 + 串行」结构与 RWKV state 语义的吻合点。
//   2. 单元内续跑**只发增量**（O(1) 上下文接续）：第 N 片不必重发前 N-1 片正文。
//   3. ⚠ 实测：`/state/*` 路由在本部署上**无视 `think_type: none`**，每轮都会先吐
//      一段 `<think>`；调用方必须剥离（见 `_stripThink`），否则思考 token 会吃光
//      正文预算。
//   4. 单次生成越长越容易进 n-gram 循环（+47 实测）→ 正文按 ~1400 字切片。
library;

import 'dart:async';
import 'dart:convert';

import '../../ai/utils/foreshadow_ledger.dart';
import '../../ai/utils/layered_pipeline_plan.dart';

/// 一次模型调用请求。
class LayeredChatRequest {
  const LayeredChatRequest({
    required this.sessionKey,
    required this.system,
    required this.user,
    required this.maxTokens,
    required this.temperature,
    this.prose = false,
    this.stateful = false,
  });

  /// 单元内串行链的会话键；空串 = 无状态单次调用。
  ///
  /// ⚠ 同一个 key 的调用**必须串行**（RWKV 的 state 是单条可变递归状态）。
  final String sessionKey;
  final String system;
  final String user;
  final int maxTokens;
  final double temperature;

  /// true = 正文类（走最严防重复采样 + 温度 1.0）；false = 结构化类。
  final bool prose;

  /// 是否要求走**有状态链路**（RWKV `/state/*`，只发增量）。
  ///
  /// 只有 L4 正文链需要它 —— 结构化任务（L1/L2/L3）走无状态路由，
  /// 因为实测 `/state/*` 的**首轮必定输出思考**（无视 `think_type: none`），
  /// 会把 JSON 输出的预算吃光（首轮实测只回 128 字的畸形片段）。
  final bool stateful;
}

/// 一次模型调用。
typedef LayeredChat = Future<String> Function(LayeredChatRequest req);

/// 产物落盘/落库（`kind` ∈ mainOutline / volumeOutline / chapterBrief /
/// chapterProse / ledger / log）。
abstract class LayeredArtifactSink {
  Future<void> write(String kind, String key, String content);
}

/// 内存 sink（自检与临时场景用）。
class LayeredMemorySink implements LayeredArtifactSink {
  final Map<String, String> artifacts = <String, String>{};

  @override
  Future<void> write(String kind, String key, String content) async {
    artifacts['$kind/$key'] = content;
  }
}

/// 管线配置。
class LayeredBookConfig {
  const LayeredBookConfig({
    required this.bookTitle,
    required this.genre,
    required this.theme,
    required this.background,
    required this.protagonist,
    required this.cast,
    required this.volumeCount,
    required this.chaptersPerVolume,
    required this.bookAnchor,
    this.volumeCountForMilestones,
    this.concurrency = 2,
    this.minChapterChars = 1600,
    this.sliceChars = 1400,
    this.sliceBudgetFactor = 1.5,
    this.maxSlicesPerChapter = 4,
    this.chapterRetries = 1,
    this.briefSelfCheck = true,
    this.chapterWarmup = true,
    this.proseStateful = false,
    this.structuredTemperature = 0.7,
    this.proseTemperature = 1.0,
    this.proseParams = const <String, Object?>{},
  });

  final String bookTitle;
  final String genre;
  final String theme;
  final String background;
  final String protagonist;
  final String cast;

  /// 卷数 / 每卷章数。
  final int volumeCount;
  final int chaptersPerVolume;

  /// 全书起点 → 终点（L1 的锚）。
  final PipelineAnchor bookAnchor;

  /// 里程碑分解的段数（默认 = 卷数；可小于卷数用于粗粒度规划）。
  final int? volumeCountForMilestones;

  /// 并行单元数（受服务端 `available_bsz` 与本地内存限制）。
  final int concurrency;

  /// 单章最少字数（质量闸）。
  final int minChapterChars;

  /// 单片目标字数（+47 实测：单次越长越易复读）。
  final int sliceChars;

  /// 单片输出预算系数（相对目标字数）。
  final double sliceBudgetFactor;

  /// 单章最多片数（防止无限补片）。
  final int maxSlicesPerChapter;

  /// 单章过不了闸时的整章重写次数。
  final int chapterRetries;

  /// 细纲是否走「生成 → 自查修正」两轮串行链。
  final bool briefSelfCheck;

  /// 章内是否先走一轮**开篇规划**（再分片写正文）。
  ///
  /// 两个作用：
  ///   ① 工艺上：先定「开场画面 + 第一个冲突点」，正文不容易跑偏；
  ///   ② 工程上（+50 实测必需）：RWKV `/state/*` 的**第一轮总会先输出思考**
  ///      （无视 `think_type: none`），且思考常常吃满 `max_tokens` 导致正文为 0 字。
  ///      把第一轮固定成**短**的规划轮（`maxTokens` 小），思考自然收束，
  ///      后续分片轮就能拿到干净正文。
  final bool chapterWarmup;

  /// 正文链是否走 RWKV 有状态路由（`/state/*`，O(1) 增量续跑）。
  ///
  /// ⚠ **默认 false**（+50 实测结论）：本部署的 `/state/*` **无视
  /// `think_type: none`**，首轮必输出思考，且思考长度极不稳定 ——
  /// 同一套代码连跑三次，过闸率 1/5 → 4/5 → 2/5，出现 0 字章。
  /// 无状态路由（`/v1/chat/completions`）实测稳定（基线 5/5）。
  /// 等服服务端修好「`/state/*` 尊重 `think_type`」后再打开这个开关。
  final bool proseStateful;

  final double structuredTemperature;
  final double proseTemperature;

  /// 正文采样参数（RWKV 家族专属；空表 = 不下发）。
  final Map<String, Object?> proseParams;

  int get totalChapters => volumeCount * chaptersPerVolume;

  String get worldContext => '书名：《$bookTitle》　题材：$genre\n'
      '主题：$theme\n'
      '背景：$background\n'
      '主角：$protagonist\n'
      '主要人物：$cast';
}

/// 单章结果。
class LayeredChapterResult {
  LayeredChapterResult({
    required this.order,
    required this.label,
    required this.brief,
    required this.prose,
    required this.note,
    required this.slices,
    required this.ngram,
    required this.paragraphRepeat,
    required this.attempts,
  });

  final int order;
  final String label;
  final String brief;
  final String prose;
  final String note;
  final int slices;
  final double ngram;
  final double paragraphRepeat;
  final int attempts;

  bool get pass => note.isEmpty;
  int get chars => prose.length;

  Map<String, Object?> toJson() => <String, Object?>{
        'chapter': order,
        'label': label,
        'chars': chars,
        'ngram': double.parse(ngram.toStringAsFixed(4)),
        'para': double.parse(paragraphRepeat.toStringAsFixed(4)),
        'pass': pass,
        'note': note,
        'slices': slices,
        'attempts': attempts,
      };
}

/// 管线结果。
class LayeredBookResult {
  LayeredBookResult({
    required this.chapters,
    required this.volumeMilestones,
    required this.chapterMilestones,
    required this.ledger,
    required this.stageSeconds,
    required this.calls,
    required this.failures,
  });

  final List<LayeredChapterResult> chapters;
  final List<PipelineMilestone> volumeMilestones;
  final Map<int, List<PipelineMilestone>> chapterMilestones;
  final ForeshadowLedger ledger;

  /// 各阶段耗时（秒）。
  final Map<String, double> stageSeconds;

  /// 模型调用次数（按层）。
  final Map<String, int> calls;
  final List<String> failures;

  int get passed => chapters.where((LayeredChapterResult c) => c.pass).length;
  double get avgChars => chapters.isEmpty
      ? 0
      : chapters
              .map((LayeredChapterResult c) => c.chars.toDouble())
              .reduce((double a, double b) => a + b) /
          chapters.length;
  double get avgNgram => chapters.isEmpty
      ? 0
      : chapters
              .map((LayeredChapterResult c) => c.ngram)
              .reduce((double a, double b) => a + b) /
          chapters.length;

  Map<String, Object?> toJson() => <String, Object?>{
        'chapters': <Map<String, Object?>>[
          for (final LayeredChapterResult c in chapters) c.toJson(),
        ],
        'volumeMilestones': <Map<String, Object?>>[
          for (final PipelineMilestone m in volumeMilestones) m.toJson(),
        ],
        'chapterMilestones': <String, Object?>{
          for (final MapEntry<int, List<PipelineMilestone>> e
              in chapterMilestones.entries)
            '${e.key}': <Map<String, Object?>>[
              for (final PipelineMilestone m in e.value) m.toJson(),
            ],
        },
        'foreshadow': <String, Object?>{
          'entries': ledger.entries.length,
          'open': ledger.openCount,
          'errors': ledger.errors.length,
          'warnings': ledger.warnings.length,
        },
        'stageSeconds': stageSeconds,
        'calls': calls,
        'failures': failures,
        'summary': <String, Object?>{
          'passed': passed,
          'total': chapters.length,
          'avgChars': avgChars.round(),
          'avgNgram': double.parse(avgNgram.toStringAsFixed(4)),
        },
      };
}

/// 分层写书服务。
class LayeredBookGenerationService {
  LayeredBookGenerationService({
    required this.chat,
    required this.sink,
    this.onProgress,
    this.cleanProse,
    this.qualityNote,
    this.trimEcho,
  });

  final LayeredChat chat;
  final LayeredArtifactSink sink;
  final void Function(String step)? onProgress;

  /// 正文清洗（注入以便与 App 的清洗口径完全一致）。
  final String Function(String raw)? cleanProse;

  /// 质量闸（返回空串 = 过闸）。
  final String Function(String prose, int minChars)? qualityNote;

  /// 回声去重（剥「前文末尾」回抄）。
  final String Function(String tail, String piece)? trimEcho;

  Future<LayeredBookResult> generate(LayeredBookConfig cfg) async {
    final List<String> failures = <String>[];
    final Map<String, int> calls = <String, int>{};
    final Map<String, double> stageSeconds = <String, double>{};

    void bump(String key) => calls[key] = (calls[key] ?? 0) + 1;

    Future<String> call({
      required String sessionKey,
      required String system,
      required String user,
      required int maxTokens,
      required double temperature,
      required bool prose,
      required String stage,
      bool stateful = false,
    }) async {
      bump(stage);
      final String raw = await chat(LayeredChatRequest(
        sessionKey: sessionKey,
        system: system,
        user: user,
        maxTokens: maxTokens,
        temperature: temperature,
        prose: prose,
        stateful: stateful,
      ));
      final String stripped = _stripThink(raw);
      // 正文只剥思考；结构化输出再走一道「去开场白 / 去围栏 / 去模板行」。
      return prose ? stripped : cleanStructured(stripped);
    }

    // =======================================================================
    // L1 主线大纲（1 个单元，串行）
    // =======================================================================
    final Stopwatch sw = Stopwatch()..start();
    onProgress?.call('L1 主线大纲：把「起点 → 终点」均分成 ${cfg.volumeCount} 卷…');
    final int planCount = cfg.volumeCountForMilestones ?? cfg.volumeCount;
    final String l1Prompt = LayeredPrompts.milestonePlan(
      anchor: cfg.bookAnchor,
      count: planCount,
      unitZh: '卷',
      worldContext: cfg.worldContext,
      labelHint: '卷名（如「退潮四十分钟」）',
      stateHint: '本卷结束时主角所处状态与已暴露的信息（40~80 字）',
    );
    String milestoneRaw = await call(
      sessionKey: '${cfg.bookTitle}::main',
      system: '你是长篇小说总编剧。只输出要求的 JSON 数组，不要解释、不要 Markdown 围栏。',
      user: l1Prompt,
      maxTokens: 1400,
      temperature: cfg.structuredTemperature,
      prose: false,
      stage: 'L1.milestone',
    );
    List<PipelineMilestone> volumeMilestones = MilestoneCodec.normalise(
      MilestoneCodec.parse(milestoneRaw, total: planCount),
      planCount,
    );
    List<String> msIssues =
        MilestoneCodec.validate(volumeMilestones, anchor: cfg.bookAnchor);
    // 格式/结构不合格 → **纠正重试一次**（把问题反馈给模型，只重跑这一步）
    if (msIssues.isNotEmpty) {
      failures.add('L1 里程碑首次不合格：${msIssues.join('；')} → 纠正重试');
      milestoneRaw = await call(
        sessionKey: '${cfg.bookTitle}::main',
        system: '你是长篇小说总编剧。只输出要求的 JSON 数组，不要解释、不要 Markdown 围栏。',
        user: '$l1Prompt\n\n⚠ 上一次输出被拒绝：${msIssues.join('；')}。'
            '请重新输出**完整**的 JSON 对象数组（$planCount 个对象，'
            '每个都要有非空的 label 与 endState）。',
        maxTokens: 1400,
        temperature: cfg.structuredTemperature,
        prose: false,
        stage: 'L1.milestoneRetry',
      );
      volumeMilestones = MilestoneCodec.normalise(
        MilestoneCodec.parse(milestoneRaw, total: planCount),
        planCount,
      );
      msIssues = MilestoneCodec.validate(volumeMilestones, anchor: cfg.bookAnchor);
      for (final String i in msIssues) {
        failures.add('L1 里程碑纠正后仍不合格：$i');
      }
    }
    await sink.write('milestoneRaw', 'volumes', milestoneRaw);
    await sink.write(
      'milestone',
      'volumes',
      const JsonEncoder.withIndent('  ').convert(<Map<String, Object?>>[
        for (final PipelineMilestone m in volumeMilestones) m.toJson(),
      ]),
    );

    // 主线大纲正文（1 次；把里程碑串成可读大纲）
    final String mainOutline = await call(
      sessionKey: '${cfg.bookTitle}::main',
      system: '你是长篇小说总编剧。只输出大纲正文，不要解释。',
      user: '${cfg.worldContext}\n\n'
          '${cfg.bookAnchor.render()}\n\n'
          '【各卷推进里程碑（按序）】\n'
          '${volumeMilestones.map((PipelineMilestone m) => '第 ${m.index} 卷（${m.ratioLabel}）：${m.endState}').join('\n')}\n\n'
          '请写出一份主线大纲：逐卷给出「卷名 · 核心冲突 · 主角阶段目标」，'
          '必须与上面的里程碑一致；每卷 80~150 字；最后用一句话点出全书结局。',
      maxTokens: 2000,
      temperature: cfg.structuredTemperature,
      prose: false,
      stage: 'L1.outline',
    );
    await sink.write('mainOutline', 'main', mainOutline);
    stageSeconds['L1'] = sw.elapsedMilliseconds / 1000;

    // =======================================================================
    // L2 分卷大纲（卷间并行 / 卷内串行）
    // =======================================================================
    sw.reset();
    onProgress?.call('L2 分卷大纲：${cfg.volumeCount} 卷并行（每卷内部串行）…');
    final List<int> volumeIndexes = <int>[
      for (int i = 1; i <= cfg.volumeCount; i++) i,
    ];
    final Map<int, ({String outline, List<PipelineMilestone> chapters})>
        volumePlans =
        <int, ({String outline, List<PipelineMilestone> chapters})>{};

    await _forEachUnit(volumeIndexes, cfg.concurrency, (int volIndex) async {
      final PipelineMilestone vMilestone =
          _milestoneFor(volumeMilestones, volIndex, planCount);
      final String prevTail = volIndex <= 1
          ? cfg.bookAnchor.start
          : (volumePlans[volIndex - 1]?.outline ?? '');
      final String l2Prompt = LayeredPrompts.milestonePlan(
        anchor: PipelineAnchor(
          start: prevTail.isEmpty ? '本卷开篇' : _clip(prevTail, 200),
          end: vMilestone.endState,
          startLabel: '本卷起点',
          endLabel: '本卷终点',
        ),
        count: cfg.chaptersPerVolume,
        unitZh: '章',
        worldContext: cfg.worldContext,
        extra: '本卷在第 ${vMilestone.index}/${vMilestone.total} 卷，'
            '整卷结束时必须到达：${vMilestone.endState}',
        labelHint: '章名（8~14 字，文学化，不要写「第N章名」这种占位）',
        stateHint: '本章结束时必须到达的剧情状态（40~80 字）',
      );
      String raw = await call(
        sessionKey: '${cfg.bookTitle}::vol$volIndex',
        system: '你是长篇小说分卷编剧。只输出要求的 JSON 数组，不要解释、不要 Markdown 围栏。',
        user: l2Prompt,
        maxTokens: 1800,
        temperature: cfg.structuredTemperature,
        prose: false,
        stage: 'L2.milestone',
      );
      List<PipelineMilestone> chMs = MilestoneCodec.normalise(
        MilestoneCodec.parse(raw, total: cfg.chaptersPerVolume),
        cfg.chaptersPerVolume,
      );
      List<String> issues = MilestoneCodec.validate(chMs);
      if (issues.isNotEmpty) {
        failures.add('L2 第 $volIndex 卷里程碑首次不合格：${issues.join('；')} → 纠正重试');
        raw = await call(
          sessionKey: '${cfg.bookTitle}::vol$volIndex',
          system: '你是长篇小说分卷编剧。只输出要求的 JSON 数组，不要解释、不要 Markdown 围栏。',
          user: '$l2Prompt\n\n⚠ 上一次输出被拒绝：${issues.join('；')}。'
              '请重新输出**完整**的 JSON 对象数组（${cfg.chaptersPerVolume} 个对象，'
              'label = 章名，endState = 章末状态，两者都不能空、不要填反）。',
          maxTokens: 1800,
          temperature: cfg.structuredTemperature,
          prose: false,
          stage: 'L2.milestoneRetry',
        );
        chMs = MilestoneCodec.normalise(
          MilestoneCodec.parse(raw, total: cfg.chaptersPerVolume),
          cfg.chaptersPerVolume,
        );
        issues = MilestoneCodec.validate(chMs);
        for (final String i in issues) {
          failures.add('L2 第 $volIndex 卷里程碑纠正后仍不合格：$i');
        }
      }
      await sink.write('volumeMilestoneRaw', '$volIndex', raw);

      // 本卷大纲正文（同一会话的第二轮 —— 卷内串行的体现）
      //
      // ⚠ 提示词**自包含**（把里程碑再贴一遍）：RWKV 的 state 链能省掉这段，
      // 但非 RWKV provider（DeepSeek / 本地 GGUF）没有 state，跟随轮看不到上一轮。
      final String outline = await call(
        sessionKey: '${cfg.bookTitle}::vol$volIndex',
        system: '你是长篇小说分卷编剧。只输出大纲正文，不要解释。',
        user: '本卷是第 $volIndex/${cfg.volumeCount} 卷'
            '（${vMilestone.label.isEmpty ? '卷名待定' : vMilestone.label}）。\n\n'
            '【本卷起点】\n${prevTail.trim().isEmpty ? '本卷开篇' : _clip(prevTail, 200)}\n\n'
            '【本卷终点（本卷结束时必须到达）】\n${vMilestone.endState}\n\n'
            '【本卷各章里程碑（已按线性推进排好，不要改动顺序与归属）】\n'
            '${chMs.map((PipelineMilestone m) => '第 ${m.index} 章（${m.ratioLabel}）：${m.endState}').join('\n')}\n\n'
            '请把它写成一份本卷大纲：先给「卷名 · 核心冲突 · 主角阶段目标」'
            '（100~200 字），再逐章一行 `第N章｜章名｜本章要推进到什么`。'
            '章名要文学化（8~14 字），不要出现卷号章号。',
        maxTokens: 2000,
        temperature: cfg.structuredTemperature,
        prose: false,
        stage: 'L2.outline',
      );
      volumePlans[volIndex] = (outline: outline, chapters: chMs);
      await sink.write('volumeOutline', '$volIndex', outline);
      await sink.write(
        'chapterMilestones',
        '$volIndex',
        const JsonEncoder.withIndent('  ').convert(<Map<String, Object?>>[
          for (final PipelineMilestone m in chMs) m.toJson(),
        ]),
      );
      onProgress?.call('L2 第 $volIndex/${cfg.volumeCount} 卷完成');
    });
    stageSeconds['L2'] = sw.elapsedMilliseconds / 1000;

    // =======================================================================
    // L3 章节细纲（章间并行 / 章内串行：生成 → 自查修正）
    // =======================================================================
    sw.reset();
    onProgress?.call('L3 章节细纲：${cfg.totalChapters} 章并行（每章内部串行）…');
    final List<({int order, int volIndex, int idxInVol})> briefUnits =
        <({int order, int volIndex, int idxInVol})>[];
    for (int v = 1; v <= cfg.volumeCount; v++) {
      for (int c = 1; c <= cfg.chaptersPerVolume; c++) {
        briefUnits.add((
          order: (v - 1) * cfg.chaptersPerVolume + c,
          volIndex: v,
          idxInVol: c,
        ));
      }
    }
    final Map<int, String> briefs = <int, String>{};
    final Map<int, List<PipelineMilestone>> chapterMilestones =
        <int, List<PipelineMilestone>>{};

    await _forEachUnit(briefUnits, cfg.concurrency, (
      ({int order, int volIndex, int idxInVol}) unit,
    ) async {
      final List<PipelineMilestone> chMs =
          volumePlans[unit.volIndex]?.chapters ?? const <PipelineMilestone>[];
      chapterMilestones[unit.order] = chMs;
      final PipelineMilestone m = _milestoneFor(
        chMs,
        unit.idxInVol,
        cfg.chaptersPerVolume,
      );
      final String prevState = unit.idxInVol <= 1
          ? (unit.volIndex <= 1
              ? cfg.bookAnchor.start
              : '上一卷结束：${_clip(volumePlans[unit.volIndex - 1]?.outline ?? '', 160)}')
          : (chMs.length >= unit.idxInVol - 1
              ? chMs[unit.idxInVol - 2].endState
              : '');
      final String label = m.label.isEmpty
          ? '第${unit.order}章'
          : '第${unit.order}章·《${m.label}》';
      final String volumeOutline = volumePlans[unit.volIndex]?.outline ?? '';

      final String brief = await call(
        sessionKey: '${cfg.bookTitle}::ch${unit.order}',
        system: '你是长篇小说细纲编剧。严格按指定行格式输出，不要解释、不要 Markdown 围栏。',
        user: LayeredPrompts.chapterBrief(
          globalOrder: unit.order,
          totalChapters: cfg.totalChapters,
          chapterLabel: label,
          volumeLabel: '第 ${unit.volIndex} 卷',
          chapterMilestone: m,
          previousChapterState: prevState,
          volumeOutline: volumeOutline,
          worldContext: cfg.worldContext,
        ),
        maxTokens: 1600,
        temperature: cfg.structuredTemperature,
        prose: false,
        stage: 'L3.brief',
      );
      String finalBrief = cleanStructured(brief);
      if (!BriefPatch.looksLikeBrief(finalBrief)) {
        failures.add('L3 第 ${unit.order} 章首轮细纲不合格（缺契约字段），已原样保留');
      }
      // 首轮就检出字段复制 → 记一笔（这是正文复读的上游成因）
      final List<String> dup = BriefPatch.duplicatedFields(finalBrief);
      if (dup.isNotEmpty) {
        failures.add('L3 第 ${unit.order} 章细纲字段重复：${dup.join('、')}');
      }
      if (cfg.briefSelfCheck) {
        // 第二轮（同一会话）：**只回差异补丁**，不重发整份细纲。
        //
        // ⚠ +50 实测：原先要求「重发完整细纲」，模型会把核验清单本身抄进输出，
        // 导致 4/5 次被判不合格而丢弃（安全但无效）。改成补丁后模型没有机会复述清单。
        final String patchRaw = await call(
          sessionKey: '${cfg.bookTitle}::ch${unit.order}',
          system: '你是长篇小说细纲审校。只输出需要修改的字段行，不要解释。',
          user: BriefPatch.selfCheckPrompt(
            brief: finalBrief,
            milestoneEndState: m.endState,
            totalChapters: cfg.totalChapters,
          ),
          maxTokens: 800,
          temperature: cfg.structuredTemperature,
          prose: false,
          stage: 'L3.selfcheck',
        );
        final String patch = cleanStructured(patchRaw);
        if (_isNoChange(patch)) {
          // 无需修改 → 保持原样
        } else {
          final String patched = BriefPatch.apply(finalBrief, patch);
          if (patched.trim().isNotEmpty &&
              BriefPatch.looksLikeBrief(patched) &&
              patched != finalBrief) {
            finalBrief = patched;
            final List<String> after = BriefPatch.duplicatedFields(finalBrief);
            if (after.isEmpty && dup.isNotEmpty) {
              failures.add('L3 第 ${unit.order} 章：字段重复已由自查修正');
            } else if (after.isNotEmpty) {
              failures.add('L3 第 ${unit.order} 章：自查后仍有字段重复 ${after.join('、')}');
            }
          } else {
            failures.add('L3 第 ${unit.order} 章：自查补丁不可用，已保留原细纲');
          }
        }
      }
      briefs[unit.order] = finalBrief;
      await sink.write('chapterBrief', '${unit.order}', finalBrief);
      onProgress?.call('L3 第 ${unit.order}/${cfg.totalChapters} 章细纲完成');
    });
    stageSeconds['L3'] = sw.elapsedMilliseconds / 1000;

    // ---- 伏笔账本（结构先于正文：由细纲派生，注入 L4）----
    final ForeshadowFlattenResult flat = _flatten(briefs, cfg);
    ForeshadowLedger ledger = ForeshadowLedgerBuilder.build(flat.sources);
    await sink.write(
      'ledger',
      'summary',
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'entries': ledger.entries.length,
        'open': ledger.openCount,
        'errors': <String>[for (final ForeshadowIssue i in ledger.errors) i.message],
        'warnings': <String>[
          for (final ForeshadowIssue i in ledger.warnings) i.message,
        ],
        'density': <String, Object?>{
          'chapters': ledger.chapterCount,
          'reminders': ledger.density.reminderCount,
          'turning': ledger.turningOrders,
        },
      }),
    );

    // =======================================================================
    // L4 正文（章间并行 / 章内串行：分片续写，RWKV state 增量）
    // =======================================================================
    sw.reset();
    onProgress?.call('L4 正文：${cfg.totalChapters} 章并行（每章分片串行续写）…');
    final Map<int, LayeredChapterResult> results =
        <int, LayeredChapterResult>{};
    // 前文衔接：上一章正文末尾（**只在已写完的章节间传递**）
    final Map<int, String> chapterTails = <int, String>{};

    await _forEachUnit(briefUnits, cfg.concurrency, (
      ({int order, int volIndex, int idxInVol}) unit,
    ) async {
      final String brief = briefs[unit.order] ?? '';
      String foreshadowBlock = ForeshadowPrompt.build(
        ledger: ledger,
        order: unit.order,
        outlineAt: (int o) =>
            o >= 1 && o <= cfg.totalChapters ? (briefs[o] ?? '') : '',
      );
      // 细纲字段重复的**确定性兜底**：模型在自查轮不一定肯改细纲，
      // 但至少要在正文提示词里明确警告「不要把同一个节拍写两遍」。
      final List<String> briefDup = BriefPatch.duplicatedFields(brief);
      if (briefDup.isNotEmpty) {
        foreshadowBlock = <String>[
          if (foreshadowBlock.isNotEmpty) foreshadowBlock,
          '【本章细纲提示（务必避免）】\n'
              '本章细纲里 ${briefDup.join('、')} 的描述**完全相同** —— '
              '正文里不要把同一个节拍写两遍：请把「关键转折」写成与「本章目标」'
              '**不同的新事件**，把「章末钩子」写成本章结尾新出现的悬念。',
        ].join('\n\n');
      }
      final String prevTail = unit.order <= 1
          ? ''
          : (chapterTails[unit.order - 1] ?? '');

      LayeredChapterResult r = await _writeChapter(
        cfg: cfg,
        order: unit.order,
        label: _labelFor(chapterMilestones[unit.order] ?? const <PipelineMilestone>[], unit.idxInVol, unit.order),
        brief: brief,
        foreshadowBlock: foreshadowBlock,
        prevTail: prevTail,
        call: call,
      );
      // 未过闸 → 整章重写（与基线同一工艺，保证可比）
      int attempt = 1;
      while (!r.pass && attempt <= cfg.chapterRetries) {
        attempt++;
        onProgress?.call('L4 第 ${unit.order} 章未过闸（${r.note}）→ 整章重写');
        final LayeredChapterResult retry = await _writeChapter(
          cfg: cfg,
          order: unit.order,
          label: r.label,
          brief: brief,
          foreshadowBlock: foreshadowBlock,
          prevTail: prevTail,
          call: call,
        );
        r = LayeredChapterResult(
          order: r.order,
          label: r.label,
          brief: brief,
          prose: retry.prose,
          note: retry.note,
          slices: retry.slices,
          ngram: retry.ngram,
          paragraphRepeat: retry.paragraphRepeat,
          attempts: attempt,
        );
      }
      results[unit.order] = r;
      chapterTails[unit.order] =
          r.prose.length > 500 ? r.prose.substring(r.prose.length - 500) : r.prose;
      await sink.write('chapterProse', '${unit.order}', r.prose);
      onProgress?.call('L4 第 ${unit.order}/${cfg.totalChapters} 章完成'
          '（${r.chars} 字${r.pass ? '' : '，未过闸：${r.note}'}）');
    });
    stageSeconds['L4'] = sw.elapsedMilliseconds / 1000;

    final List<LayeredChapterResult> ordered = <LayeredChapterResult>[
      for (int i = 1; i <= cfg.totalChapters; i++)
        if (results[i] != null) results[i]!,
    ];
    return LayeredBookResult(
      chapters: ordered,
      volumeMilestones: volumeMilestones,
      chapterMilestones: chapterMilestones,
      ledger: ledger,
      stageSeconds: stageSeconds,
      calls: calls,
      failures: failures,
    );
  }

  /// 写一章（分片串行；同章共用一个 session —— RWKV 的 O(1) 上下文接续）。
  Future<LayeredChapterResult> _writeChapter({
    required LayeredBookConfig cfg,
    required int order,
    required String label,
    required String brief,
    required String foreshadowBlock,
    required String prevTail,
    required Future<String> Function({
      required String sessionKey,
      required String system,
      required String user,
      required int maxTokens,
      required double temperature,
      required bool prose,
      required String stage,
      bool stateful,
    }) call,
  }) async {
    final StringBuffer body = StringBuffer();
    int sliceNo = 0;
    String localTail = prevTail;
    if (cfg.chapterWarmup && cfg.proseStateful) {
      // 章内串行第 1 轮：开篇规划（短）。同时消费掉 RWKV 的首轮思考。
      await call(
        sessionKey: '${cfg.bookTitle}::ch$order',
        system: '你是专业中文小说主笔作家。只输出简短要点，不要写正文。',
        user: '本章细纲：\n${brief.trim()}\n\n'
            '${foreshadowBlock.trim().isEmpty ? '' : '${foreshadowBlock.trim()}\n\n'}'
            '请用 3~5 句列出本章的**开场画面**与**第一个冲突点**，'
            '并说明第一段从哪一句起笔。不要写正文，不要思考。',
        maxTokens: 420,
        temperature: cfg.structuredTemperature,
        prose: false,
        stateful: cfg.proseStateful,
        stage: 'L4.warmup',
      );
    }
    while (body.length < cfg.minChapterChars + 400 &&
        sliceNo < cfg.maxSlicesPerChapter) {
      sliceNo++;
      final int need = cfg.minChapterChars + 400 - body.length;
      final int ask = need < cfg.sliceChars ? need : cfg.sliceChars;
      // 单元内串行：非首片只发增量（state 已持有前文）
      final String curTail = body.isEmpty
          ? localTail
          : (body.length > 500
              ? body.toString().substring(body.length - 500)
              : body.toString());
      final String raw = await call(
        sessionKey: '${cfg.bookTitle}::ch$order',
        system: '你是专业中文小说主笔作家。严格中文、第三人称、只用给定的人物与设定；'
            '只输出章节正文，不要标题、分节标记、解释、字数统计或大纲复述；'
            '开头抓眼球，结尾留钩子；必须写满要求的字数。',
        user: LayeredPrompts.proseSlice(
          bookTitle: cfg.bookTitle,
          chapterLabel: label,
          sliceIndex: sliceNo,
          askChars: ask,
          chapterBrief: brief,
          tailContext: curTail,
          foreshadowBlock: foreshadowBlock,
          worldContext: cfg.background,
          isFirstSlice: body.isEmpty,
        ),
        maxTokens: (ask * cfg.sliceBudgetFactor).clamp(1000, 2400).toInt(),
        temperature: cfg.proseTemperature,
        prose: true,
        stateful: cfg.proseStateful,
        stage: 'L4.prose',
      );
      final String piece = cleanProse?.call(raw) ?? raw;
      if (piece.trim().isEmpty) break;
      final String Function(String, String)? te = trimEcho;
      final String trimmed = te == null ? piece : te(curTail, piece);
      final String body2 = trimmed.trim().isEmpty ? piece : trimmed;
      if (body.isNotEmpty) body.write('\n\n');
      body.write(body2);
    }
    final String cleaned = cleanProse?.call(body.toString()) ?? body.toString();
    final String note = qualityNote?.call(cleaned, cfg.minChapterChars) ?? '';
    return LayeredChapterResult(
      order: order,
      label: label,
      brief: brief,
      prose: cleaned,
      note: note,
      slices: sliceNo,
      ngram: _ngram(cleaned),
      paragraphRepeat: _paragraphRepeat(cleaned),
      attempts: 1,
    );
  }

  /// 并发跑一组单元（单元间并行；单元内由 sessionKey 串行）。
  Future<void> _forEachUnit<T>(
    List<T> units,
    int concurrency,
    Future<void> Function(T unit) run,
  ) async {
    final int limit = concurrency < 1 ? 1 : concurrency;
    int next = 0;
    final List<Future<void>> workers = <Future<void>>[];
    for (int w = 0; w < limit && w < units.length; w++) {
      workers.add(() async {
        while (true) {
          final int i = next++;
          if (i >= units.length) return;
          await run(units[i]);
        }
      }());
    }
    await Future.wait(workers);
  }

  // ---- 纯工具 ----

  static PipelineMilestone _milestoneFor(
    List<PipelineMilestone> list,
    int index,
    int total,
  ) {
    if (index >= 1 && index <= list.length) return list[index - 1];
    return PipelineMilestone(
      index: index,
      total: total,
      label: '',
      endState: '',
    );
  }

  static String _labelFor(
    List<PipelineMilestone> list,
    int idxInVol,
    int order,
  ) {
    final PipelineMilestone m = _milestoneFor(list, idxInVol, list.length);
    return m.label.isEmpty ? '第$order章' : '第$order章·《${m.label}》';
  }

  static ForeshadowFlattenResult _flatten(
    Map<int, String> briefs,
    LayeredBookConfig cfg,
  ) {
    final List<ForeshadowFlatChapter> flat = <ForeshadowFlatChapter>[];
    for (int order = 1; order <= cfg.totalChapters; order++) {
      final int volIndex = (order - 1) ~/ cfg.chaptersPerVolume + 1;
      flat.add(ForeshadowFlatChapter(
        id: 'ch$order',
        volumeId: 'vol$volIndex',
        title: '第$order章',
        outline: briefs[order] ?? '',
        hasContent: false,
      ));
    }
    return ForeshadowFlattener.flatten(
      chapters: flat,
      volumeOrderById: <String, int>{
        for (int v = 1; v <= cfg.volumeCount; v++) 'vol$v': v,
      },
    );
  }

  static String _clip(String text, int max) {
    final String s = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length <= max ? s : '${s.substring(0, max)}…';
  }

  /// 剥离 `<think>` 块与未闭合的思考前缀。
  ///
  /// ⚠ 实测（+50）：`/state/*` 路由在本部署上无视 `think_type: none`，每轮都会
  /// 先吐一段思考；不剥掉的话正文预算会被吃光（且思考文字会被当正文入库）。
  static String _stripThink(String raw) {
    String t = raw;
    t = t.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
      '',
    );
    // 未闭合的思考：整段丢弃（宁缺勿滥 —— 思考文字绝不能进正文）
    t = t.replaceFirst(
      RegExp(r'^\s*<think(?:ing)?>[\s\S]*$', caseSensitive: false),
      '',
    );
    t = t.replaceAll(RegExp(r'</?(?:think|thinking)>', caseSensitive: false), '');
    return t.trim();
  }

  /// 结构化输出的清洗（+50 实测三类污染，逐条对症）。
  ///
  /// 实测污染形态：
  ///   ① 开场白：`好的，这是一份……：` / `好的，我已经仔细核查了……`；
  ///   ② Markdown：代码围栏、`---` 分隔线、`**强调**`；
  ///   ③ 模板行原样回抄：`- Txxx（第A章 → 第B章）：一句话方向（≤50 字，越模糊越好）`。
  ///
  /// 只做**确定性**剥离，不改动正文语义。
  static String cleanStructured(String raw) {
    String t = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // ⓿ **开头的 Markdown 引用块标记 `>`**
    //
    // ⚠ 这是本部署的**服务端模板行为**，不是模型行为：真机实测（+51）
    //   `只回复一个字：好` → `>好`，且与 `system` / `stop_tokens` 完全无关，
    //   每条 completion 都会带一个前缀 `>`。正文链路经
    //   `AIOutputSanitizer._stripLeadingQuoteBlock` 已经剥掉了，**结构化链路
    //   必须在这里自己剥** —— 否则 `>标题：《x》` 会让 `BriefPatch.parseFields`
    //   的 `^\s*标题` 匹配失败，直接丢掉「标题」字段（章名退化成「第 N 章」）。
    t = _stripLeadingQuotePrefix(t);
    // ① 代码围栏
    t = t.replaceAll(RegExp(r'^[ \t]*```[a-zA-Z0-9_+-]*[ \t]*$', multiLine: true), '');
    // ② 开场白：丢掉「首个契约标记之前」的所有行
    final List<String> lines = t.split('\n');
    int start = 0;
    for (int i = 0; i < lines.length; i++) {
      if (_looksLikeContractLine(lines[i])) {
        start = i;
        break;
      }
    }
    final List<String> kept = lines.sublist(start);
    // ③ 分隔线 / 强调符 / 模板占位行 / **指令回显**
    //
    // 「指令回显」是 +50 实测的第四类污染：自查轮的输出会把**自查清单本身**
    // 抄进结果（`请自查：① … ② … ④ … 有问题就修正…`），并把伏笔示例章号
    // 一起抄下来。命中这些标记就从该行起**整段截断**（后面都是回显的指令）。
    final List<String> out = <String>[];
    for (final String line in kept) {
      final String s = line.replaceAll('**', '').replaceAll('__', '');
      final String trimmed = s.trim();
      if (RegExp(r'^-{3,}$').hasMatch(trimmed)) continue;
      if (_instructionEcho.hasMatch(trimmed)) break;
      // 模板占位行：`Txxx` / `第A章` / `…` 形式的示例行，原样回抄时必须丢弃
      if (RegExp(r'Txxx|TXX|第[A-Za-z]章').hasMatch(trimmed)) continue;
      out.add(s);
    }
    return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 指令回显的起始标记（命中即整段截断）。
  static final RegExp _instructionEcho = RegExp(
    r'^\s*(?:请自查|请核查|请核验|自查[:：]|核查[:：]|⚠|注意[:：]|'
    r'[①②③④⑤⑥]|有问题就修正|输出完整细纲|没问题就原样|'
    r'【待核验的细纲】|上面的细纲)',
  );

  /// 是否是「契约行」—— 判定结构化输出的真正起点。
  static final RegExp _contractLine = RegExp(
    r'^\s*(?:\[\s*\{?|\{)|标题：|本章目标：|承接上文：|核心冲突：|关键转折：|'
    r'章末钩子：|出场人物：|故事时间节点：|##|第\s*\d+\s*[章卷]|[-*•]\s*T\d',
  );

  static bool _looksLikeContractLine(String line) =>
      _contractLine.hasMatch(line.trim());

  /// 引用块标记（行首可选空白 + `>` + 可选空格）。
  static final RegExp _quotePrefix = RegExp(r'^\s*>\s?');

  /// 剥掉**开头连续**的 `>` 引用块标记（跳过开头的空行后再判断）。
  ///
  /// 只剥「开头连续段」而不是每行都剥 —— 与 `AIOutputSanitizer` 同语义，
  /// 避免误伤正文里合法的引用。
  static String _stripLeadingQuotePrefix(String text) {
    final List<String> lines = text.split('\n');
    int i = 0;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    int stripped = 0;
    while (i < lines.length && _quotePrefix.hasMatch(lines[i])) {
      lines[i] = lines[i].replaceFirst(_quotePrefix, '');
      i++;
      stripped++;
    }
    return stripped == 0 ? text : lines.join('\n');
  }

  /// 自查轮回复「无需修改」的各种写法。
  static bool _isNoChange(String patch) {
    final String t = patch.replaceAll(RegExp(r'[\s。．.,，、:：]'), '');
    if (t.isEmpty) return true;
    return t == '无需修改' ||
        t == '无' ||
        t == '合格' ||
        t == '全部合格' ||
        t == '无需改动' ||
        t == '没有需要修改的字段';
  }

  /// 细纲契约校验：至少命中 4 个字段名才算一份合格细纲。
  ///
  /// 用于**拒绝**「自查轮把细纲改坏」的情况（实测：自查轮返回了一段对话式
  /// 改写，字段被填成了其它章的里程碑）。
  static bool looksLikeChapterBrief(String text) {
    const List<String> markers = <String>[
      '本章目标', '承接上文', '核心冲突', '关键转折', '章末钩子', '出场人物',
    ];
    int hit = 0;
    for (final String m in markers) {
      if (text.contains(m)) hit++;
    }
    return hit >= 4;
  }

  /// 字符 n-gram 重复率（与 `RepetitionGuard.charNgramRepeatRatio` 同口径的
  /// 简化版 —— 编排层不依赖守卫实现，便于离线自检）。
  static double _ngram(String text, {int n = 12}) {
    final String s = text.replaceAll(RegExp(r'\s+'), '');
    if (s.length < n * 2) return 0;
    final Map<String, int> counts = <String, int>{};
    for (int i = 0; i + n <= s.length; i++) {
      final String g = s.substring(i, i + n);
      counts[g] = (counts[g] ?? 0) + 1;
    }
    int repeated = 0;
    for (final int c in counts.values) {
      if (c > 1) repeated += c - 1;
    }
    final int total = s.length - n + 1;
    return total <= 0 ? 0 : repeated / total;
  }

  /// 段落重复率（完全相同段落的占比）。
  static double _paragraphRepeat(String text) {
    final List<String> ps = text
        .split(RegExp(r'\n\s*\n'))
        .map((String p) => p.trim())
        .where((String p) => p.length >= 12)
        .toList();
    if (ps.isEmpty) return 0;
    final Set<String> uniq = ps.toSet();
    return (ps.length - uniq.length) / ps.length;
  }
}
