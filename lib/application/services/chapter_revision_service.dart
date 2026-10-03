// 章节关联改稿服务 —— 「边聊边写」把 Agent 产出**真正写回项目章节**的落库环节。
//
// 对应 C# `Services/Copilot/` 的「章节关联处理」
// （`CreationPipelineService.ProcessChapterOperationAsync` + 采纳落库）。
//
// 两条改写工艺，按原文长度自动分流：
//   ① **长文（> [SegmentRewrite.segmentChars] 字）**：走 C# 的**分段滚动改写** ——
//      切片 → 逐片携带「处理要求 + 上一片结尾」→ 防复读重试 → 拼接 → 整体落库。
//      一次性改写长章必然被截断/压缩变短，这是分段的根本原因。
//   ② **短文**：仍走 [AiWritingService] 的双 Agent 一次成稿（质量更好，
//      且是本批已验收的路径）。
// 无正文章节则按「梗概 + 作者意见」成文（对应 C# `DraftChapterFromSummaryAsync`）。
//
// 关键设计：
// 1. **不谎报**：[ChapterRevisionResult] 把「生成成功」与「已落库」分开暴露，
//    UI 逐条如实渲染，失败绝不显示成成功。
// 2. **原子落库**：分段过程中**任何一段失败都整体不写库** —— 宁可让作者重试，
//    也不留半个章节。
// 3. **写作 provider 不可用时直接失败**：`AgentFactory` 的单 Agent 兜底会返回
//    内置示例文本（`Fallback: true`），若把它写进章节就是污染正文。
library;

import 'package:drift/drift.dart' show Value;

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/rwkv/rwkv_sampling.dart';
import '../../ai/runtime_settings.dart';
import '../../ai/utils/localized_text.dart';
import '../../ai/utils/output_sanitizer.dart';
import '../../ai/utils/segment_rewrite.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import 'ai_writing_service.dart';
import 'chapter_post_process_service.dart';
import 'chapter_sync_service.dart';
import 'project_context_assembler.dart';

/// 关联章节处理的结果。
class ChapterRevisionResult {
  const ChapterRevisionResult({
    required this.isSuccess,
    required this.content,
    required this.message,
    this.originalLength = 0,
    this.revisedLength = 0,
    this.workflowMode = '',
    this.persisted = false,
    this.segments = 0,
  });

  /// 生成是否成功（失败时 [content] 为空）。
  final bool isSuccess;

  /// 处理后的正文（失败时为空串）。
  final String content;

  /// 面向用户的结果说明（已本地化）。
  final String message;

  /// 处理前字数。
  final int originalLength;

  /// 处理后字数。
  final int revisedLength;

  /// `DualAgent` / `SingleAgent` / `Segmented` / 空串（未产出）。
  final String workflowMode;

  /// 是否已回写数据库。
  final bool persisted;

  /// 本次实际处理的分段数（1 = 未分段）。
  final int segments;

  /// 本次是否由双 Agent 流程产出。
  bool get isDualAgent => workflowMode == 'DualAgent';

  /// 本次是否走了分段滚动改写。
  bool get isSegmented => segments > 1;

  /// 成功且已落库。
  bool get applied => isSuccess && persisted;
}

/// 章节关联改稿服务。
class ChapterRevisionService {
  ChapterRevisionService({
    required AiWritingService writing,
    required ChapterRepository chapters,
    required ProjectContextAssembler contextAssembler,
    required AiTextSource texts,
    required bool Function() hasWriter,
    required IModelProvider? Function() sliceProvider,
    required RwkvProvider Function() rwkv,
    ChapterPostProcessService? postProcess,
  })  : _writing = writing,
        _chapters = chapters,
        _contextAssembler = contextAssembler,
        _texts = texts,
        _hasWriter = hasWriter,
        _sliceProvider = sliceProvider,
        _rwkv = rwkv,
        _postProcess = postProcess;

  final AiWritingService _writing;
  final ChapterRepository _chapters;
  final ProjectContextAssembler _contextAssembler;
  final AiTextSource _texts;

  /// 功能 C：章节落库后的世界观自动同步编排（可空 —— 离线测试不装配）。
  final ChapterPostProcessService? _postProcess;

  /// 是否存在可用的写作 provider（由 DI 装配，读双代理指名 provider 与
  /// ModelManager 注册表）。false 时直接失败 —— 见文件头第 3 条。
  final bool Function() _hasWriter;

  /// 分段改写的单段生成通道（双代理的写作 provider：本地或云端都行）。
  final IModelProvider? Function() _sliceProvider;

  /// 本地 RWKV —— 没配置写作 provider 时的 raw prompt 回落通道
  /// （对应 C# `IRwkvLightningService.CompleteAsync`）。
  final RwkvProvider Function() _rwkv;

  /// 章节问答进提示词的正文截断长度（对应 C# `TruncateForPrompt(content, 1600)`）。
  static const int qaContentChars = 1600;

  /// 章节问答的输出 token 预算（对应 C# `CompleteAsync(prompt, 800)`）。
  static const int qaTokens = 800;

  /// **按作者意见改写**已有正文（覆盖 `Chapter.Content`）。
  ///
  /// 章节还没有正文时，自动改为「按梗概 + 意见成文」（对应 C# 的
  /// `DraftChapterFromSummaryAsync` 分支）。
  ///
  /// [onProgress] 只在分段路径下回调（`done` 从 0 起），长章改写要跑好几轮，
  /// UI 靠它显示"正在改写第 N/M 段"。
  Future<ChapterRevisionResult> revise({
    required String projectId,
    required String chapterId,
    required String instruction,
    void Function(int done, int total)? onProgress,
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    if (chapter == null) return _chapterMissing();

    final String original = chapter.content ?? '';
    if (original.trim().isEmpty) {
      return _composeFromSummary(
        projectId: projectId,
        chapter: chapter,
        instruction: instruction,
      );
    }
    // 长文 → C# 分段滚动改写；短文 → 双 Agent 一次成稿
    if (SegmentRewrite.needsSegmentation(original)) {
      return _rewriteSegmented(
        projectId: projectId,
        chapter: chapter,
        original: original,
        instruction: instruction,
        onProgress: onProgress,
      );
    }
    return _runAndPersist(
      projectId: projectId,
      chapter: chapter,
      original: original,
      task: 'PolishText',
      parameters: <String, dynamic>{
        'ProjectId': projectId,
        'ChapterTitle': chapter.title,
        'Title': chapter.title,
        'Content': original,
        'Instruction': instruction,
      },
    );
  }

  /// **按作者要求续写**：Agent 产出续写片段，追加到原文末尾后回写。
  Future<ChapterRevisionResult> continueWriting({
    required String projectId,
    required String chapterId,
    required String instruction,
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    if (chapter == null) return _chapterMissing();

    final String original = chapter.content ?? '';
    if (original.trim().isEmpty) {
      return revise(
        projectId: projectId,
        chapterId: chapterId,
        instruction: instruction,
      );
    }
    return _runAndPersist(
      projectId: projectId,
      chapter: chapter,
      original: original,
      task: 'ContinueChapter',
      parameters: <String, dynamic>{
        'ProjectId': projectId,
        'ChapterTitle': chapter.title,
        'Title': chapter.title,
        'Content': original,
        'Instruction': instruction,
      },
      appendToOriginal: true,
    );
  }

  /// 针对已关联章节的**提问**（对应 C# `HandleChapterQuestionAsync`）：
  /// 带章节上下文作答，**绝不改动正文**。
  ///
  /// 背景：关联模式下"处理要求"和"问题"共用同一个输入框。若不加区分，
  /// 作者随口问一句「这章节奏有什么问题？」就会被当成改稿要求把正文重写掉。
  ///
  /// 与 C# 一致：章节正文按 [qaContentChars] 截断后进提示词（长章整篇进上下文会挤爆预算）。
  /// 返回结果 `persisted = false`，UI 据此只显示答复、不显示"已更新正文"。
  Future<ChapterRevisionResult> askAboutChapter({
    required String projectId,
    required String chapterId,
    required String question,
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    if (chapter == null) return _chapterMissing();
    if (!_hasWriter()) return _noWriter((chapter.content ?? '').length);

    final bool en = _texts.isEnglish;
    final ProjectContextData? ctx = await _projectContext(projectId);
    final String projectName = ctx?.projectName ?? '';
    final String content = (chapter.content ?? '').trim();
    final String summary = (chapter.summary ?? '').trim();
    final String excerpt = SegmentRewrite.truncate(content, qaContentChars) ??
        (summary.isEmpty
            ? (en ? '(this chapter has no text yet)' : '（本章暂无正文）')
            : (en
                ? '(no text yet; synopsis: $summary)'
                : '（本章暂无正文，梗概：$summary）'));

    final String body = en
        ? 'Chapter "$chapter.title"${projectName.isEmpty ? '' : ' of "$projectName"'}:\n'
            '[Chapter text]\n$excerpt\n\n'
            "[Author's question] $question\n\n"
            'Answer the question directly and concisely. Do NOT rewrite or output the chapter text.'
        : '章节《${chapter.title}》${projectName.isEmpty ? '' : '（《$projectName》）'}：\n'
            '【章节内容】\n$excerpt\n\n'
            '【作者问题】$question\n\n'
            '请直接、简洁地回答作者的问题；**不要改写，也不要输出章节正文**。';

    final String? answer = await _generateOnce(
      body,
      maxTokens: qaTokens,
      systemPrompt: en
          ? 'You are a senior fiction editor advising the author on their own manuscript.'
              ' Answer the question; never rewrite or restate the chapter.'
          : '你是资深网文编辑，为作者分析他们自己的稿件。只回答问题，不要改写或复述章节正文。',
      stripStructureLines: false,
      temperature: 0.6,
    );

    if (answer == null || answer.trim().isEmpty) {
      return ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: _texts.t('CRS.QaFailed',
            '回答失败：模型没有返回内容。请检查「AI 配置」里的模型服务后重试。'),
        originalLength: content.length,
      );
    }

    return ChapterRevisionResult(
      isSuccess: true,
      content: answer,
      // 问答不落库、也不推进任何状态 —— message 留空，UI 不会再补一条"已更新"提示
      message: '',
      originalLength: content.length,
      workflowMode: 'ChapterQa',
    );
  }

  // ---------------------------------------------------------------------------
  // 路径一：双 Agent 一次成稿（短文 / 无正文成文 / 续写）
  // ---------------------------------------------------------------------------

  /// 无正文章节：按梗概 + 作者意见成文（对应 C# `DraftChapterFromSummaryAsync`）。
  Future<ChapterRevisionResult> _composeFromSummary({
    required String projectId,
    required ChapterRow chapter,
    required String instruction,
  }) async {
    final String summary = (chapter.summary ?? '').trim();
    return _runAndPersist(
      projectId: projectId,
      chapter: chapter,
      original: '',
      task: 'GenerateChapterContent',
      parameters: <String, dynamic>{
        'ProjectId': projectId,
        'ChapterTitle': chapter.title,
        'Title': chapter.title,
        'Outline': summary.isEmpty ? instruction : '$summary\n$instruction',
        'Instruction': instruction,
      },
    );
  }

  /// 统一出口：可用性闸门 → 调门面 → 回写。
  Future<ChapterRevisionResult> _runAndPersist({
    required String projectId,
    required ChapterRow chapter,
    required String original,
    required String task,
    required Map<String, dynamic> parameters,
    bool appendToOriginal = false,
  }) async {
    if (!_hasWriter()) return _noWriter(original.length);

    // ⚠ 必须先自己塞 `PromptSummary`。
    //
    // [AiWritingService] 只在参数里**没有** `PromptSummary` 时才注入项目上下文，
    // 而它注入的是「【润色生成约束】只能生成润色相关内容，**不得输出正文**…」——
    // 与本服务的任务（改写/成文正文）直接冲突。这里改用不含子系统约束的
    // 项目摘要，保证 Agent 拿到的是「项目设定 + 原文 + 作者意见」。
    final Map<String, dynamic> params = Map<String, dynamic>.of(parameters);
    if (!params.containsKey('PromptSummary')) {
      final ProjectContextData? ctx = await _projectContext(projectId);
      params['PromptSummary'] = ctx?.promptSummary ?? '';
    }

    final AIAssistantResult r = switch (task) {
      'PolishText' => await _writing.polishText(params),
      'ContinueChapter' => await _writing.continueChapter(params),
      _ => await _writing.generateChapterContent(params),
    };

    // ⚠ 回退闸门：`BaseAgent.executeTaskWithAI` 在「模型调用失败」时会静默回退到
    // `executeTask`，而那里返回的是**内置示例文本**（叶知秋/玄铁古剑那种演示内容）
    // 且 `isSuccess = true`。把它写进作者的正文章节就是数据污染 ——
    // 宁可报错让作者重试，也不落库。
    if (r.metadata['Fallback'] == 'true') {
      return ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: _texts.t('CRS.FallbackRefused',
            '模型没有真正返回内容（推理服务不可用/调用失败）。为避免用占位文本覆盖正文，本次未改动章节，请检查「AI 配置」里的模型服务后重试。'),
        originalLength: original.length,
      );
    }

    final String produced = r.data.trim();
    if (!r.isSuccess || produced.isEmpty) {
      return ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: r.message.isEmpty
            ? _texts.t('CRS.Empty', 'AI 返回了空内容，请换个说法重试。')
            : r.message,
        originalLength: original.length,
      );
    }

    final String merged = appendToOriginal && original.trim().isNotEmpty
        ? '${original.trimRight()}\n\n$produced'
        : produced;

    return _persistAndReport(
      chapter: chapter,
      original: original,
      merged: merged,
      workflowMode: r.metadata['WorkflowMode'] ?? '',
      segments: 1,
    );
  }

  // ---------------------------------------------------------------------------
  // 路径二：长文分段滚动改写（C# `RewriteChapterCoreAsync` 工艺）
  // ---------------------------------------------------------------------------

  /// 分段滚动改写：逐段改写并携带「上一段结尾」，最后拼接落库。
  ///
  /// 与 C# 的差异：C# 用一次性的 `CompleteAsync`（无 state）；这里同样**不用**
  /// state 会话，因为每段的提示词已自包含（处理要求 + 衔接尾部 + 原文片段）。
  Future<ChapterRevisionResult> _rewriteSegmented({
    required String projectId,
    required ChapterRow chapter,
    required String original,
    required String instruction,
    void Function(int done, int total)? onProgress,
  }) async {
    if (!_hasWriter()) return _noWriter(original.length);

    // 闸门：段数超上限**直接拒绝**，且必须在任何模型调用（含上下文查询）之前 ——
    // 否则作者等了几分钟才被告知"这一章太长"，而"只改前 N 段"是不允许的半成品。
    final SegmentPlan plan = SegmentRewrite.plan(original);
    if (plan.exceedsLimit) {
      return ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: _texts.tf(
          'CRS.SegmentLimit',
          '本章 {0} 字，按每段 {1} 字需分成 {2} 段，超过上限 {3} 段。'
              '请拆成多章、或缩小改写范围后重试。',
          <Object>[
            original.length,
            SegmentRewrite.segmentChars,
            plan.count,
            plan.limit,
          ],
        ),
        originalLength: original.length,
      );
    }

    final ProjectContextData? ctx = await _projectContext(projectId);
    final List<String> segments = plan.slices;
    final String trimmedInstruction =
        SegmentRewrite.truncate(instruction, SegmentRewrite.instructionChars) ??
            '';

    final List<String> parts = <String>[];
    for (int i = 0; i < segments.length; i++) {
      onProgress?.call(i, segments.length);
      final String body = SegmentRewrite.buildSegmentPrompt(
        projectName: ctx?.projectName ?? '',
        chapterTitle: chapter.title,
        instruction: trimmedInstruction,
        carryTail: parts.isEmpty ? '' : SegmentRewrite.tailOf(parts.last),
        index: i + 1,
        total: segments.length,
        segment: segments[i],
        isEnglish: _texts.isEnglish,
      );

      String? piece =
          await _generateSlice(body, maxTokens: SegmentRewrite.sliceTokens);

      // 防复读：本段输出几乎等于原文片段 → 换更强提示词重试一次（对应 C# 的 retry 分支）
      if (piece != null && SegmentRewrite.isDuplicateSlice(segments[i], piece)) {
        final String retry = SegmentRewrite.buildRetryPrompt(
          instruction: trimmedInstruction,
          index: i + 1,
          total: segments.length,
          segment: segments[i],
          isEnglish: _texts.isEnglish,
        );
        final String? retried =
            await _generateSlice(retry, maxTokens: SegmentRewrite.sliceTokens);
        if (retried != null && retried.trim().isNotEmpty) piece = retried;
      }

      if (piece == null || piece.trim().isEmpty) {
        // 原子性：任何一段失败都整体不落库
        return ChapterRevisionResult(
          isSuccess: false,
          content: '',
          message: _texts.tf(
            'CRS.SegmentFailed',
            '分段改写第 {0}/{1} 段失败，正文未改动。请检查模型服务后重试。',
            <Object>[i + 1, segments.length],
          ),
          originalLength: original.length,
        );
      }
      parts.add(piece);
    }
    onProgress?.call(segments.length, segments.length);

    final String merged = SegmentRewrite.stitch(parts);
    if (merged.trim().isEmpty) {
      return ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: _texts.t('CRS.Empty', 'AI 返回了空内容，请换个说法重试。'),
        originalLength: original.length,
      );
    }

    return _persistAndReport(
      chapter: chapter,
      original: original,
      merged: merged,
      workflowMode: 'Segmented',
      segments: segments.length,
    );
  }

  /// 单段生成（带一次重试，对应 C# `GenerateTextAsync` 的多轮重试）。
  ///
  /// 全部尝试都失败时返回 null —— **绝不降级**为占位文本（那会污染正文）。
  Future<String?> _generateSlice(String body, {required int maxTokens}) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final String? text = await _generateSliceOnce(body, maxTokens: maxTokens);
      if (text != null && text.trim().isNotEmpty) return text;
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return null;
  }

  /// 单次生成：优先当前写作 provider（本地 / 云端都行），
  /// 没有配置或调用失败时才回落本地 RWKV 的 raw prompt 通道。
  ///
  /// [stripStructureLines] 为 true 时按"正文切片"标准清洗（去标题/列表/提示词回显）；
  /// 问答路径必须传 false —— 答案里的 `1. 2. 3.` 列表是真内容，不能被当成结构行删掉。
  Future<String?> _generateOnce(
    String body, {
    required int maxTokens,
    required String systemPrompt,
    required bool stripStructureLines,
    double temperature = 0.85,
  }) async {
    String clean(String text) => stripStructureLines
        ? SegmentRewrite.cleanSlice(text)
        : AIOutputSanitizer.extractCleanOutput(text).trim();

    final IModelProvider? provider = _sliceProvider();
    if (provider != null) {
      try {
        final ChatResponse resp = await provider.chat(ChatRequest(
          systemPrompt: systemPrompt,
          messages: <ChatMessage>[ChatMessage.user(body)],
          temperature: temperature,
          maxTokens: maxTokens,
          // RWKV 家族才认这套防复读采样参数（其它厂商会 400）
          parameters: isRwkvFamilyProvider(provider.providerName)
              ? Map<String, dynamic>.of(aiRuntimeSettings.longFormSamplingParams())
              : <String, dynamic>{},
        ));
        final String cleaned = clean(resp.isSuccess ? resp.content : '');
        if (cleaned.isNotEmpty) return cleaned;
      } on Object {
        // 静默回落 raw 通道，最终失败由调用方统一报错
      }
    }

    // 回落：本地 RWKV 的 raw prompt（不套 chat 模板，与 C# `CompleteAsync` 一致）。
    // 不可用时 `completeRawPrompt` 返回 null。
    try {
      final String? raw = await _rwkv().completeRawPrompt(
        SegmentRewrite.wrapRawPrompt('$systemPrompt\n\n$body'),
        maxTokens: maxTokens,
        temperature: temperature,
        topP: 0.85,
      );
      final String cleaned = clean(raw ?? '');
      return cleaned.isEmpty ? null : cleaned;
    } on Object {
      return null;
    }
  }

  /// 单段改写（按正文切片标准清洗）。
  Future<String?> _generateSliceOnce(String body, {required int maxTokens}) =>
      _generateOnce(
        body,
        maxTokens: maxTokens,
        systemPrompt: _texts.isEnglish
            ? 'You are a top-tier fiction editor. Output only the revised chapter text:'
                ' no explanations, no headings, no echoing the instruction.'
            : '你是顶级中文网文编辑。只输出处理后的正文，禁止任何解释、小标题或提示词内容。',
        stripStructureLines: true,
      );

  // ---------------------------------------------------------------------------
  // 落库与公共失败结果
  // ---------------------------------------------------------------------------

  /// 回写章节并生成面向用户的结果说明（两条工艺共用）。
  Future<ChapterRevisionResult> _persistAndReport({
    required ChapterRow chapter,
    required String original,
    required String merged,
    required String workflowMode,
    required int segments,
  }) async {
    try {
      await _chapters.updateById(
        chapter.id,
        ChaptersCompanion(
          content: Value(merged),
          wordCount: Value(merged.length),
          lastEditedAt: Value(DateTime.now()),
          versionNumber: Value(chapter.versionNumber + 1),
          // 不动 status：改稿不该把「已完成」打回草稿，状态由作者自己掌控
        ),
      );
    } on Object catch (e) {
      return ChapterRevisionResult(
        isSuccess: true,
        content: merged,
        message: _texts.tf('CRS.PersistFailed', '已生成内容，但回写章节失败：{0}', <Object>[e]),
        originalLength: original.length,
        revisedLength: merged.length,
        workflowMode: workflowMode,
        segments: segments,
      );
    }

    // 功能 C：落库成功后自动同步世界观（规则同步 + 可选 AI 抽取）。
    // 后处理绝不阻塞改稿：任何异常在编排层内部折叠，这里再兜一层。
    String message = segments > 1
        ? _texts.tf(
            'CRS.AppliedSegmented',
            '已按你的要求分段改写《{0}》正文（{3} 段）：{1} 字 → {2} 字。',
            <Object>[chapter.title, original.length, merged.length, segments],
          )
        : _texts.tf(
            'CRS.Applied',
            '已按你的要求更新《{0}》正文：{1} 字 → {2} 字。',
            <Object>[chapter.title, original.length, merged.length],
          );
    final ChapterPostProcessService? post = _postProcess;
    if (post != null) {
      try {
        final ChapterPostProcessSummary summary = await post.runForChapter(
          ChapterSyncInput(
            chapterId: chapter.id,
            volumeId: chapter.volumeId,
            projectId: chapter.projectId ?? '',
            title: chapter.title,
            orderIndex: chapter.orderIndex,
            content: merged,
            summary: chapter.summary,
            tags: chapter.tags,
            notes: chapter.notes,
            status: chapter.status,
            versionNumber: chapter.versionNumber + 1,
            eventDate: DateTime.now(),
          ),
        );
        if (summary.applied) {
          final List<String> parts = <String>[
            if (summary.ruleApplied) summary.countsForDisplay(_texts),
            if (summary.aiApplied) summary.aiNote,
            if (summary.aiNote.isNotEmpty && !summary.aiApplied) summary.aiNote,
          ];
          final String detail = parts.where((String p) => p.isNotEmpty).join('；');
          if (detail.isNotEmpty) {
            message += _texts.tf('SYN.SyncDoneFmt', '（世界观自动同步：{0}）', <Object>[detail]);
          }
        } else if (summary.skippedReason != null &&
            summary.skippedReason != 'alreadySynced' &&
            summary.skippedReason != 'disabled') {
          message += _texts.tf(
              'SYN.SyncFailFmt', '（世界观同步未执行：{0}）', <Object>[summary.skippedReason ?? '']);
        }
      } on Object catch (e) {
        // 后处理故障绝不吞掉改稿结果本身
        message += _texts.tf('SYN.SyncFailFmt', '（世界观同步未执行：{0}）', <Object>[e]);
      }
    }

    return ChapterRevisionResult(
      isSuccess: true,
      content: merged,
      message: message,
      originalLength: original.length,
      revisedLength: merged.length,
      workflowMode: workflowMode,
      persisted: true,
      segments: segments,
    );
  }

  ChapterRevisionResult _chapterMissing() => ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: _texts.t('CRS.ChapterMissing', '目标章节不存在或已被删除，请重新关联。'),
      );

  ChapterRevisionResult _noWriter(int originalLength) => ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: _texts.t('CRS.NoWriter',
            '未找到可用的写作模型。请先到「AI 配置」注册并启用模型（或配好双代理提供者）。'),
        originalLength: originalLength,
      );

  /// 项目上下文（含书名与摘要）；取不到时返回 null —— 不阻断改稿。
  Future<ProjectContextData?> _projectContext(String projectId) async {
    if (projectId.isEmpty) return null;
    try {
      return await _contextAssembler.build(projectId);
    } on Object {
      return null;
    }
  }
}