// 拆书（Agent 拆书 → 写作模板）。
//
// 用户诉求
// --------
// 「把一本写得好的小说拆成一套可复用的写作规则，拿去指导我自己的书。」
// 样本动辄 6~18 MB（`E:\书籍拆分\` 下的样本），远超任何上下文窗口，
// 所以必须两步走：
//
//   ① 采样：`StyleDigestText.sampleChunks` 把整本切成若干块，首尾必留、
//      中间均匀取样（只取开头会得到「黄金三章」式的系统性偏差结论）；
//   ② 两阶段归纳：逐块「观察」→ 合并 → 一次「汇总」成固定 schema 的规则。
//
// 为什么是两阶段而不是「逐块观察直接拼起来」
// ------------------------------------------
// 逐块观察是**并列的描述句**（「多用短句」「段落偏短」），拼起来是一堆同义反复。
// 汇总这一步把它们压成**指令式规则**（「以短句为主，单句成段，叙述密度高」），
// 并且让模型有机会丢掉互相矛盾的观察。汇总失败时降级用合并结果 —— 可读性差些，
// 但仍然是能注入的规则，不会让用户白跑一趟。
//
// 三种输入来源（本地文件 / 粘贴文本 / 已有项目章节）
// --------------------------------------------------
// 前两种在 UI 侧读成纯文本后走 [digest]；第三种走 [digestProject] 直接把
// 项目已写章节拼起来 —— 半本书就能看出自己的文风，对「续写保持一致性」有用。
//
// 本服务**只管产出**（文本 → 规则集），入库与「哪个项目启用哪套」由
// `StyleRuleLibraryNotifier`（`lib/core/di.dart`）负责。分开的理由：
// 入库需要一个**已经装载好的库**（否则会读-改-写覆盖并发修改），
// 而那是应用层的状态，不是本服务的职责。
import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/utils/localized_text.dart';
import '../../ai/utils/style_digest_text.dart';
import '../../data/database.dart';
import 'chapter_service.dart';
import 'style_rule.dart';
import 'writing_prompt_templates.dart';

/// 一次拆书的结果。
class StyleDigestResult {
  const StyleDigestResult({
    required this.isSuccess,
    required this.message,
    this.ruleSet,
    this.chunks = 0,
    this.observations = 0,
    this.techniques = 0,
    this.notes = const <String>[],
  });

  /// 是否产出可用规则。注意：**产出为空也算成功**（样本太短 / 不像小说），
  /// 那是正常结论，不是故障 —— 只有「模型不可用 / 样本为空 / 全部观察失败」
  /// 才是失败。
  final bool isSuccess;

  /// 人类可读结论，UI 直接显示。
  final String message;

  final StyleRuleSet? ruleSet;

  /// 实际采样的块数。
  final int chunks;

  /// 成功返回观察结果的块数。
  final int observations;

  /// 最终落地的技法条数。
  final int techniques;

  /// 需要人工注意的问题（部分块失败、走了降级路径等）。
  final List<String> notes;
}

/// Agent 拆书服务。
class StyleDigestService {
  StyleDigestService({
    required this.provider,
    this.promptTemplates,
    this.texts = const StaticTextSource(),
    this.chapters,
  });

  /// 拆书用的模型。与设定抽取同源（主 Agent / 7.2B）—— 拆书是「规划级」任务，
  /// 需要的是归纳能力而不是文笔。
  final IModelProvider? Function() provider;

  final WritingPromptTemplates? promptTemplates;

  /// 取词接口（领域层不依赖 i18n 表，见 `lib/ai/utils/localized_text.dart`）。
  final AiTextSource texts;

  /// 用于「已有项目」输入来源。为 null 时 [digestProject] 会报错而不是静默返回空。
  final ChapterService? chapters;

  String _t(String key, String fallback) => texts.t(key, fallback);

  String _tf(String key, String fallback, List<Object> args) =>
      texts.tf(key, fallback, args);

  // 采样 / 清洗 / 合并的**纯文本规则**统一放在
  // `lib/ai/utils/style_digest_text.dart` —— 那里是纯 Dart，
  // `tools/style_digest_selftest.dart` 可离线直跑；本文件只留需要模型
  // 与数据库的流程逻辑。

  /// 采样块大小。4000 字 ≈ 一次观察调用能吃透的篇幅，再大模型就开始
  /// 「总结剧情」而不是「看写法」。
  static const int chunkChars = 4000;

  /// 采样块数上限。6 块 ≈ 2.4 万字样本，覆盖全书首/中/尾；再多是边际收益
  /// 递减而延迟线性增长（并发 4 → 2 轮）。
  static const int maxChunks = 6;

  /// 逐块观察返回的技法条数上限（每块）。
  static const int maxTechniquesPerChunk = 8;

  /// 观察结果的单字段长度上限（与合并上限分开：合并上限更大，因为是拼接后的）。
  static const int observeFieldMaxChars = 220;

  /// 一次拆书最多并发几个观察请求。
  static const int defaultConcurrency = 4;

  /// 拆一段文本（来源：本地文件 / 粘贴）。
  Future<StyleDigestResult> digest({
    required String text,
    String name = '',
    String sourceLabel = '',
    int maxChunkCount = maxChunks,
    int chunkSize = chunkChars,
    int concurrency = defaultConcurrency,
    void Function(String step)? onProgress,
  }) async {
    final IModelProvider? p = provider();
    if (p == null || !p.isAvailable) {
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.NoProvider', '拆书所需的模型不可用（请在 AI 配置中检查主 Agent）。'),
      );
    }

    final String cleaned = StyleDigestText.cleanSample(text);
    if (cleaned.trim().length < 400) {
      // 400 字以内连句式统计都做不了，直接拒绝比产出垃圾规则好。
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.SampleTooShort', '样本文本太短（不足 400 字），无法研读文风。'),
      );
    }

    final List<String> chunks = StyleDigestText.sampleChunks(
      cleaned,
      chunkChars: chunkSize,
      maxChunks: maxChunkCount,
    );
    if (chunks.isEmpty) {
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.EmptySample', '样本清洗后没有可用正文，无法研读文风。'),
      );
    }

    final WritingPromptTemplates prompts =
        promptTemplates ?? WritingPromptTemplates.defaults();
    final List<String> notes = <String>[];
    // 名称兜底放在这里而不是入库时：规则集名是**产物的一部分**（列表里、
    // 提示词里的书名都取它），不该只在存盘那一刻才有值。
    final String ruleName = name.trim().isEmpty
        ? _t('SDR.DefaultName', '未命名规则集')
        : name.trim();

    // ---- 第一阶段：逐块观察（有界并发，单块失败不影响其它块）----
    onProgress?.call(
      _tf('SDR.ObservingFmt', '正在研读 {0} 个样本片段…', <Object>[chunks.length]),
    );
    final List<Map<String, dynamic>> observations = <Map<String, dynamic>>[];
    int done = 0;
    await _runPool<int, void>(
      concurrency,
      <int>[for (int i = 0; i < chunks.length; i++) i],
      (int index) async {
        try {
          final Map<String, dynamic>? obs = await _observeOne(
            p,
            prompts,
            chunks[index],
            index,
            chunks.length,
          );
          if (obs != null) observations.add(obs);
        } on Object {
          // 忽略：样本块之间互相独立，一块失败不该拖垮整次拆书。
        } finally {
          done++;
          onProgress?.call(
            _tf('SDR.ObserveProgressFmt', '已研读 {0}/{1} 个片段…', <Object>[
              done,
              chunks.length,
            ]),
          );
        }
      },
    );

    if (observations.isEmpty) {
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.ObserveFailed', '模型没有返回任何可用的观察结果，请检查模型配置后重试。'),
        chunks: chunks.length,
      );
    }

    // ---- 合并观察 ----
    final Map<String, dynamic> merged = StyleDigestText.mergeObservations(
      observations,
    );
    final List<StyleTechnique> mergedTechniques = _techniquesFrom(
      merged['techniques'],
    );

    // ---- 第二阶段：汇总成规则（失败则降级用合并结果）----
    onProgress?.call(_t('SDR.Synthesizing', '正在汇总写作规则…'));
    StyleRuleSet? ruleSet;
    try {
      ruleSet = await _synthesize(
        p,
        prompts,
        merged,
        name: ruleName,
        sourceLabel: sourceLabel,
      );
    } on Object {
      ruleSet = null;
    }
    if (ruleSet == null || ruleSet.isEmpty) {
      // 降级：直接把合并结果当规则。可读性差些（是并列描述句而不是指令），
      // 但用户拿到的是能用的东西，不是一句「失败了」。
      ruleSet = StyleRuleSet(
        name: ruleName,
        sourceLabel: sourceLabel,
        aspects: <String, String>{
          for (final String k in kStyleAspectLabels.keys)
            if (('${merged[k] ?? ''}').trim().isNotEmpty)
              k: ('${merged[k] ?? ''}').trim(),
        },
        techniques: mergedTechniques,
      );
      notes.add(_t('SDR.FallbackNote', '汇总步骤未返回可用结果，已直接使用逐块观察的合并结果。'));
    }

    if (ruleSet.isEmpty) {
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.NoRules', '样本中没有提炼出可复用的写作规则。'),
        chunks: chunks.length,
        observations: observations.length,
      );
    }

    final StyleRuleSet finalSet = ruleSet.copyWith(
      notes: ruleSet.notes.isEmpty ? notes.join('；') : ruleSet.notes,
    );
    return StyleDigestResult(
      isSuccess: true,
      message: _tf('SDR.ResultFmt', '已研读 {0} 个片段，提炼出 {1} 条写作技法。', <Object>[
        observations.length,
        finalSet.techniques.length,
      ]),
      ruleSet: finalSet,
      chunks: chunks.length,
      observations: observations.length,
      techniques: finalSet.techniques.length,
      notes: notes,
    );
  }

  /// 拆一个已有项目的章节正文（来源：已有项目）。
  Future<StyleDigestResult> digestProject({
    required String projectId,
    String projectName = '',
    int maxChunkCount = maxChunks,
    int chunkSize = chunkChars,
    int concurrency = defaultConcurrency,
    void Function(String step)? onProgress,
  }) async {
    if (projectId.isEmpty) {
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.NoProject', '缺少项目标识，无法研读项目文风。'),
      );
    }
    final ChapterService? svc = chapters;
    if (svc == null) {
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.NoChapterAccess', '无法读取项目章节，不能研读项目文风。'),
      );
    }
    final List<ChapterRow> all = await svc.getByProjectId(projectId);
    final StringBuffer buf = StringBuffer();
    int chapterCount = 0;
    for (final ChapterRow ch in all) {
      final String content = (ch.content ?? '').trim();
      if (content.isEmpty) continue; // 草稿章不算样本
      chapterCount++;
      if (ch.title.trim().isNotEmpty) buf.writeln(ch.title.trim());
      buf.writeln(content);
      buf.writeln();
    }
    if (chapterCount == 0) {
      return StyleDigestResult(
        isSuccess: false,
        message: _t('SDR.NoChapters', '该项目还没有已写正文的章节，无法研读文风。'),
      );
    }
    final String label = projectName.isEmpty
        ? _tf('SDR.SourceProjectFmt', '项目章节（{0} 章）', <Object>[chapterCount])
        : _tf('SDR.SourceProjectNamedFmt', '项目《{0}》（{1} 章）', <Object>[
            projectName,
            chapterCount,
          ]);
    return digest(
      text: buf.toString(),
      name: projectName,
      sourceLabel: label,
      maxChunkCount: maxChunkCount,
      chunkSize: chunkSize,
      concurrency: concurrency,
      onProgress: onProgress,
    );
  }

  // ---------------------------------------------------------------- 内部

  Future<Map<String, dynamic>?> _observeOne(
    IModelProvider p,
    WritingPromptTemplates prompts,
    String sample,
    int index,
    int total,
  ) async {
    final String aspects = kStyleAspectLabels.entries
        .map((MapEntry<String, String> e) => '- ${e.key}（${e.value}）')
        .join('\n');
    final String categories = kStyleTechniqueCategories.join('、');
    final String json = <String>[
      for (final String k in kStyleAspectLabels.keys) '"$k":""',
      '"techniques":[{"category":"$categories的第一项","title":"技法名",'
          '"detail":"可复用的写法，一句话"}]',
    ].join(', ');
    final ChatResponse resp = await p.chat(
      ChatRequest(
        systemPrompt: prompts.render('Style/system', const <String, String>{}),
        messages: <ChatMessage>[
          ChatMessage.user(
            prompts.render('Style/observe', <String, String>{
              'index': '${index + 1}',
              'total': '$total',
              'aspects': aspects,
              'categories': categories,
              'json': '{$json}',
              'sample': sample,
            }),
          ),
        ],
        temperature: 0.4,
        maxTokens: 1800,
      ),
    );
    if (!resp.isSuccess) return null;
    final Map<String, dynamic>? obj = StyleDigestText.parseJsonObject(
      resp.content,
    );
    if (obj == null) return null;

    // 逐字段做长度闸 —— 单块输出过长通常意味着模型开始复述正文。
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final String k in kStyleAspectLabels.keys) {
      final Object? v = obj[k];
      if (v is! String) continue;
      String s = v.trim();
      if (s.isEmpty) continue;
      if (s.length > observeFieldMaxChars) {
        s = s.substring(0, observeFieldMaxChars);
      }
      out[k] = s;
    }
    final List<Map<String, dynamic>> techs = <Map<String, dynamic>>[];
    final Object? rawTech = obj['techniques'];
    if (rawTech is List) {
      for (final Object? item in rawTech) {
        if (item is! Map) continue;
        final String title = '${item['title'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        String detail = '${item['detail'] ?? ''}'.trim();
        if (detail.length > kStyleTechniqueMaxChars) {
          detail = detail.substring(0, kStyleTechniqueMaxChars);
        }
        techs.add(<String, dynamic>{
          'category': '${item['category'] ?? ''}'.trim(),
          'title': title,
          'detail': detail,
        });
        if (techs.length >= maxTechniquesPerChunk) break;
      }
    }
    if (techs.isNotEmpty) out['techniques'] = techs;
    return out.isEmpty ? null : out;
  }

  Future<StyleRuleSet?> _synthesize(
    IModelProvider p,
    WritingPromptTemplates prompts,
    Map<String, dynamic> merged, {
    required String name,
    required String sourceLabel,
  }) async {
    final String aspects = kStyleAspectLabels.entries
        .map((MapEntry<String, String> e) => '- ${e.key}（${e.value}）')
        .join('\n');
    final String categories = kStyleTechniqueCategories.join('、');
    final List<StyleTechnique> techs = _techniquesFrom(merged['techniques']);
    final StringBuffer obs = StringBuffer();
    for (final String k in kStyleAspectLabels.keys) {
      final String v = ('${merged[k] ?? ''}').trim();
      if (v.isEmpty) continue;
      obs.writeln('${kStyleAspectLabels[k]}：$v');
    }
    if (techs.isNotEmpty) {
      obs.writeln('候选技法：');
      for (final StyleTechnique t in techs) {
        obs.writeln(
          t.detail.isEmpty
              ? '- [${t.category}] ${t.title}'
              : '- [${t.category}] ${t.title}：${t.detail}',
        );
      }
    }
    final String json = <String>[
      for (final String k in kStyleAspectLabels.keys) '"$k":""',
      '"techniques":[{"category":"$categories的第一项","title":"技法名",'
          '"detail":"可复用的写法，一句话"}]',
    ].join(', ');
    final ChatResponse resp = await p.chat(
      ChatRequest(
        systemPrompt: prompts.render('Style/system', const <String, String>{}),
        messages: <ChatMessage>[
          ChatMessage.user(
            prompts.render('Style/synthesize', <String, String>{
              'name': name.trim().isEmpty ? '（未命名）' : name.trim(),
              'aspects': aspects,
              'categories': categories,
              'observations': obs.toString().trimRight(),
              'json': '{$json}',
            }),
          ),
        ],
        temperature: 0.4,
        maxTokens: 3200,
      ),
    );
    if (!resp.isSuccess) return null;
    final Map<String, dynamic>? obj = StyleDigestText.parseJsonObject(
      resp.content,
    );
    if (obj == null) return null;

    final Map<String, String> outAspects = <String, String>{};
    for (final String k in kStyleAspectLabels.keys) {
      final Object? v = obj[k];
      if (v is! String) continue;
      final String s = v.trim();
      if (s.isEmpty) continue;
      outAspects[k] = s.length > kStyleAspectMaxChars
          ? s.substring(0, kStyleAspectMaxChars)
          : s;
    }
    final List<StyleTechnique> outTechs = _techniquesFrom(obj['techniques']);
    if (outAspects.isEmpty && outTechs.isEmpty) return null;
    return StyleRuleSet(
      name: name,
      sourceLabel: sourceLabel,
      aspects: outAspects,
      techniques: outTechs,
      notes: '${obj['notes'] ?? ''}'.trim(),
    );
  }

  /// 把 JSON 数组解析成技法列表（分类归一、标题去重、长度闸）。
  static List<StyleTechnique> _techniquesFrom(Object? raw) {
    if (raw is! List) return const <StyleTechnique>[];
    final List<StyleTechnique> out = <StyleTechnique>[];
    final Set<String> seen = <String>{};
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final String title = '${item['title'] ?? ''}'.trim();
      if (title.isEmpty) continue;
      if (!seen.add(title.toLowerCase())) continue;
      String detail = '${item['detail'] ?? ''}'.trim();
      if (detail.length > kStyleTechniqueMaxChars) {
        detail = detail.substring(0, kStyleTechniqueMaxChars);
      }
      String category = '${item['category'] ?? ''}'.trim();
      if (!kStyleTechniqueCategories.contains(category)) {
        category = StyleDigestText.nearestCategory('$title$detail');
      }
      out.add(StyleTechnique(category: category, title: title, detail: detail));
      if (out.length >= kStyleMaxTechniques) break;
    }
    return out;
  }

  /// 固定并发度的任务池（与 `EntityProfileSynthesizer` 同形）。
  static Future<void> _runPool<T, R>(
    int concurrency,
    List<T> items,
    Future<R> Function(T item) task,
  ) async {
    if (items.isEmpty) return;
    final int lanes = concurrency < 1 ? 1 : concurrency;
    int cursor = 0;
    Future<void> worker() async {
      while (true) {
        final int i = cursor++;
        if (i >= items.length) return;
        await task(items[i]);
      }
    }

    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < lanes && i < items.length; i++) worker(),
    ]);
  }
}
