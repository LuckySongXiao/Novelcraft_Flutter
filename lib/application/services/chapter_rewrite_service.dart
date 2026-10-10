// 单章重写服务 —— 「按上下文把这一章从头重写一遍」。
//
// 为什么需要它（用户实测问题 ③「无法手动重写」）：
//   `ChapterRevisionService` 的三条路径都要**作者意见**（改稿 / 续写 / 问答），
//   而实测里出现的场景是「这一章生成坏了（大纲污染 / 复读 / 字数不足，被存成
//   Draft），我想让它按上下文重新写一遍」—— 没有任何入口能触发。作者只能
//   整本书重跑，代价极大。
//
// 与既有服务的关系：
//   * 与 `ChapterRevisionService`（带意见改稿）**并列**，互不替代；
//   * 清洗与质量闸**直接复用** `MultiAgentBookGenerationService.cleanFinalChapter`
//     / `chapterQualityNote` —— 单章重写与整书生成对「什么算合格正文」只能有
//     一套口径（见该文件里的公开入口注释）。
//
// 上下文装配（本服务的核心价值）：
//   前章结尾 400 字 + 本章大纲/梗概 + 下章开头 400 字 + 项目设定摘要
//   —— 单章重写最容易出的事故是「孤立成章」：开头接不上前文、结尾写掉了下一章
//   的内容。两侧邻居的**边界片段**正是约束这两件事的最小充分信息。
//
// 安全设计（沿用 `ChapterRevisionService` 的既有约定）：
//   * 质量闸不过 → **不覆盖原稿**，把原因如实回报；
//   * provider 不可用 / 返回空 → 直接失败，绝不写占位文本；
//   * 落库后触发 `ChapterPostProcessService.runForChapter()`（规则同步 + AI 抽取）。
//
// -----------------------------------------------------------------------------
// 「先调大纲、再重写」（2026-10-10 新增，用户实测问题）
//
// 实测现象：整书生成后 30 章里有 9 章 NG（6 章正文全空 + 3 章字数不足），作者点
// 「重写」**次次失败**。根因见 `.workbuddy/memory/2026-10-10.md` §11：
//
//   大纲文本里混进了「生产元信息」—— `summary` 落库成了
//   `'第一章：祭祀之夜（700字）##'`，章节标题成了 `《暗流涌动（约600字》`。
//   而 `rewrite` 把 `summary + notes` 当「本章大纲」原样喂给模型 → 模型照着
//   **「（约700字）」** 写 → 只出 1200~3100 字 → 过不了 3200 字的定稿质量闸 →
//   再次 NG。**照着坏大纲只会写出坏正文**，重写多少次都一样。
//
// 因此新增 `repairOutlineAndRewrite`：**先用前后章节的实际内容把本章大纲改对，
// 再走上面那套已验证的重写链路**。两处关键约束：
//   1. 修订出的大纲过 `OutlineRepairText.stripMeta` 清洗（字数提示 / 章号括号 /
//      Markdown 残留一律剔除），并把**目标字数由程序写死**（≥ 定稿闸下限）——
//      不再给模型任何机会在文里写「约600字」；
//   2. 修订时顺带抽出**故事内时间节点**，经 `ChapterSyncInput.storyTime` 传给
//      世界观/角色履历与时间线，让「这一章发生在什么时候」有据可查。
// -----------------------------------------------------------------------------
library;

import 'package:drift/drift.dart' show Value;

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/rwkv/rwkv_sampling.dart';
import '../../ai/runtime_settings.dart';
import '../../ai/utils/chapter_plan_text.dart';
import '../../ai/utils/localized_text.dart';
import '../../ai/utils/outline_repair_text.dart';
import '../../ai/utils/output_sanitizer.dart';
import '../../ai/utils/repetition_guard.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import '../../data/repositories/project_repository.dart';
import '../../data/repositories/volume_repository.dart';
import '../models/stats.dart';
import 'chapter_post_process_service.dart';
import 'chapter_sync_service.dart';
import 'multi_agent_book_generation_service.dart';
import 'project_context_assembler.dart';

/// 单章重写结果。
class ChapterRewriteResult {
  const ChapterRewriteResult({
    required this.isSuccess,
    required this.content,
    required this.message,
    this.chapterTitle = '',
    this.originalLength = 0,
    this.revisedLength = 0,
    this.persisted = false,
    this.qualityNote = '',
  });

  /// 生成并落库成功。
  final bool isSuccess;

  /// 重写后的正文（失败时可能为空，或为**未落库**的候选稿 —— 见 [qualityNote]）。
  final String content;

  /// 面向用户的结果说明（已本地化）。
  final String message;

  final String chapterTitle;

  /// 重写前字数。
  final int originalLength;

  /// 重写后字数。
  final int revisedLength;

  /// 是否已回写数据库。
  final bool persisted;

  /// 质量闸不合格原因（空串 = 通过）。非空时原稿**未被修改**。
  final String qualityNote;

  /// 成功且已落库。
  bool get applied => isSuccess && persisted;

  /// 复制并覆盖部分字段。
  ///
  /// 主要用途：`ChapterOutlineRepairResult` 把「大纲修订 + 正文重写」合成一条
  /// 说明后，用 `rewrite.copyWith(message: 组合说明)` 统一关窗形态 ——
  /// 调用方（进度弹窗）只需要一种结果类型。
  ChapterRewriteResult copyWith({
    bool? isSuccess,
    String? content,
    String? message,
    String? chapterTitle,
    int? originalLength,
    int? revisedLength,
    bool? persisted,
    String? qualityNote,
  }) => ChapterRewriteResult(
    isSuccess: isSuccess ?? this.isSuccess,
    content: content ?? this.content,
    message: message ?? this.message,
    chapterTitle: chapterTitle ?? this.chapterTitle,
    originalLength: originalLength ?? this.originalLength,
    revisedLength: revisedLength ?? this.revisedLength,
    persisted: persisted ?? this.persisted,
    qualityNote: qualityNote ?? this.qualityNote,
  );
}

/// 「先调大纲、再重写」的结果（见 [ChapterRewriteService.repairOutlineAndRewrite]）。
///
/// 刻意把「大纲是否修订成功」与「正文是否重写成功」**分开回报** ——
/// 实测里作者最需要知道的是「到底是我的大纲坏了，还是模型写不出来」。
class ChapterOutlineRepairResult {
  const ChapterOutlineRepairResult({
    required this.chapterTitle,
    required this.outlineRepaired,
    required this.previousOutline,
    required this.newOutline,
    required this.storyTime,
    required this.rewrite,
    required this.message,
  });

  /// 大纲修订阶段直接失败时的构造（此时 [rewrite] 是一份失败结果）。
  factory ChapterOutlineRepairResult.outlineFailed({
    required String chapterTitle,
    required String previousOutline,
    required ChapterRewriteResult rewrite,
    required String message,
  }) => ChapterOutlineRepairResult(
    chapterTitle: chapterTitle,
    outlineRepaired: false,
    previousOutline: previousOutline,
    newOutline: '',
    storyTime: '',
    rewrite: rewrite,
    message: message,
  );

  final String chapterTitle;

  /// 本章大纲是否被成功修订并写库。
  final bool outlineRepaired;

  /// 修订前的大纲/梗概原文（便于 UI 让作者对照，也便于事后追责）。
  final String previousOutline;

  /// 修订后的结构化大纲（多行文本；未修订时为空串）。
  final String newOutline;

  /// 从修订大纲里抽出的**故事内时间节点**（空串 = 模型未给出）。
  final String storyTime;

  /// 正文重写结果 —— 语义与 [ChapterRewriteResult] 完全一致。
  final ChapterRewriteResult rewrite;

  /// 面向用户的一句话结果。
  final String message;

  /// 正文已重写并落库。
  bool get applied => rewrite.applied;
}

/// 单章重写服务。
class ChapterRewriteService {
  ChapterRewriteService({
    required ChapterRepository chapters,
    required ProjectContextAssembler contextAssembler,
    required AiTextSource texts,
    required IModelProvider? Function() provider,
    RwkvProvider Function()? rwkv,
    ChapterPostProcessService? postProcess,
    VolumeRepository? volumes,
    ProjectRepository? projects,
  }) : _chapters = chapters,
       _contextAssembler = contextAssembler,
       _texts = texts,
       _provider = provider,
       _rwkv = rwkv,
       _postProcess = postProcess,
       _volumes = volumes,
       _projects = projects;

  final ChapterRepository _chapters;
  final ProjectContextAssembler _contextAssembler;
  final AiTextSource _texts;

  /// 项目仓储 —— **仅**用于「重写落库成功后刷新 `projects.progress`」。
  ///
  /// 可空：缺省时跳过进度刷新（离线测试 / 旧装配不因此失败）。
  final ProjectRepository? _projects;

  /// 卷仓储 —— **仅**用于「大纲修订」时取本卷大纲（`volumes.description`）。
  ///
  /// 可空：离线测试不装配时，大纲修订退化为「只有前后章 + 项目设定」，
  /// 不会因此失败。
  final VolumeRepository? _volumes;

  /// 主 Agent（7.2B）—— 由 DI 装配为 `resolveAgentProvider(main: true)`。
  final IModelProvider? Function() _provider;

  /// 本地 RWKV 的 raw prompt 回落通道（provider 缺失时）。null = 不回落
  /// （离线单测只需注入 provider，不必构造真 RwkvProvider）。
  final RwkvProvider Function()? _rwkv;

  /// 落库后的世界观自动同步编排（可空 —— 离线测试不装配）。
  final ChapterPostProcessService? _postProcess;

  /// 前章结尾 / 下章开头各取多少字作为衔接约束。
  static const int neighbourChars = 400;

  /// **大纲修订**时前章结尾 / 下章开头各取多少字。
  ///
  /// 比正文重写宽一倍：要判断「这一章该写什么」，只看 400 字往往不够 ——
  /// 上一章怎么收的、下一章已经写到哪儿，都需要更多原文。
  static const int repairNeighbourChars = 800;

  /// 单章重写的输出预算（目标 4200 字 / 下限 3200 字，留足余量）。
  static const int rewriteTokens = 6000;

  /// 大纲修订的输出预算（7 行结构化字段，1500 字够）。
  static const int outlineRepairTokens = 1600;

  /// 本服务的质量闸下限（与整书生成缺省一致）。
  static const int minFinalWords =
      MultiAgentBookGenerationService.kDefaultMinFinalWords;

  /// 【规划-续写-润色】管线的总目标字数（与整书生成 `chapterWordTarget` 缺省一致）。
  static const int planTotalTargetWords = 4200;

  /// 切片规划的输出预算（每行「片N|字数|要点」，几百 token 足够）。
  static const int planTokens = 700;

  /// 一次规划最多接受多少片（超出截断，缺口由补片循环兜底）。
  static const int maxSlices = 6;

  /// 写完规划片后字数仍不足时，最多自动补写多少片。
  static const int maxTopUpSlices = 2;

  /// 逐段润色的分块目标字数（与整书 `_polishDraft` 的 850 量级一致）。
  static const int polishChunkTarget = 900;

  /// 写入 `chapters.notes` 的 AI 修订大纲块标题（幂等：重跑会先去掉上一块）。
  static const String outlineBlockHeader = '【AI 修订大纲】';

  /// 写入 `chapters.notes` 的原始备注块标题。
  static const String notesTailHeader = '【原始备注】';

  /// 按上下文重写 [chapterId] 这一章。
  ///
  /// [instruction] 为可选的作者额外要求（空串 = 纯按上下文重写）。
  /// [onProgress] 回调阶段名（`context` / `generate` / `gate` / `sync`），UI 可显示进度。
  /// [storyTime] 故事内时间节点（由 [repairOutlineAndRewrite] 的修订大纲给出）；
  /// 非空时会随履历与时间线一起落库 —— 见 `ChapterSyncInput.storyTime`。
  Future<ChapterRewriteResult> rewrite({
    required String chapterId,
    String projectId = '',
    String instruction = '',
    String storyTime = '',
    void Function(String phase)? onProgress,
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    if (chapter == null) return _chapterMissing('');

    final String pid = projectId.trim().isNotEmpty
        ? projectId.trim()
        : (chapter.projectId ?? '');
    final String original = (chapter.content ?? '').trim();

    onProgress?.call('context');
    final _RewriteContext ctx = await _collectContext(pid, chapter);
    final String outline = _outlineOf(chapter);

    // 既没有大纲、也没有前文 —— 没有任何可依据的信息，重写必然是无中生有。
    // 与其让模型自由发挥，不如如实告诉作者「先补大纲」。
    if (outline.isEmpty && ctx.prevTail.isEmpty && instruction.trim().isEmpty) {
      return ChapterRewriteResult(
        isSuccess: false,
        content: '',
        message: _texts.t(
          'CRW.NoBasis',
          '无法重写：本章既没有大纲/梗概，也没有上一章正文，且未填写额外要求。'
              '请先补全本章大纲，或在「额外要求」里说明这一章要写什么。',
        ),
        chapterTitle: chapter.title,
        originalLength: original.length,
      );
    }

    onProgress?.call('generate');
    final String body = _buildPrompt(
      chapter: chapter,
      outline: outline,
      ctx: ctx,
      instruction: instruction.trim(),
    );
    final String? raw = await _generate(body, maxTokens: rewriteTokens);
    if (raw == null || raw.trim().isEmpty) {
      return ChapterRewriteResult(
        isSuccess: false,
        content: '',
        message: _texts.t(
          'CRW.GenerateFailed',
          '重写失败：模型没有返回内容。请检查「AI 配置」里的模型服务后重试。',
        ),
        chapterTitle: chapter.title,
        originalLength: original.length,
      );
    }

    onProgress?.call('gate');
    // ⚠ 与整书生成共用同一套清洗：剥状态块 / 元信息抬头 / 思考块 / 段落小标题，
    // 折叠复读并截断退化尾部。质量闸必须在这之后判定。
    final String text = MultiAgentBookGenerationService.cleanFinalChapter(
      raw,
    ).trim();
    if (text.isEmpty) {
      return ChapterRewriteResult(
        isSuccess: false,
        content: '',
        message: _texts.t('CRW.Empty', '重写失败：清洗后正文为空，原稿未修改。'),
        chapterTitle: chapter.title,
        originalLength: original.length,
      );
    }

    final String note = MultiAgentBookGenerationService.chapterQualityNote(
      text,
      minWords: minFinalWords,
    );
    if (note.isNotEmpty) {
      // 保留候选稿供作者查看，但**不写库** —— 质量不合格的稿子绝不能覆盖原稿。
      return ChapterRewriteResult(
        isSuccess: false,
        content: text,
        message: _texts.tf(
          'CRW.QualityFailed',
          '重写未通过质量闸（{0}），原稿未修改。可调整大纲后重试。',
          <Object>[note],
        ),
        chapterTitle: chapter.title,
        originalLength: original.length,
        revisedLength: text.length,
        qualityNote: note,
      );
    }

    return _persistAndSync(
      chapter: chapter,
      merged: text,
      original: original,
      storyTime: storyTime,
      onProgress: onProgress,
    );
  }

  // ---------------------------------------------------------------------------
  // 先调大纲、再重写
  // ---------------------------------------------------------------------------

  /// **先用前后章节的实际内容把本章大纲改对，再按流程重写正文。**
  ///
  /// 这是「失败章反复重写失败」的正解 —— 完整推理见文件头「先调大纲、再重写」一节。
  ///
  /// 阶段回调：`context` / `outline` / `generate` / `gate` / `sync`。
  ///
  /// 语义（与 [rewrite] 的三态回报保持一致，不合并、不谎报）：
  ///   * 大纲修订失败 → [ChapterOutlineRepairResult.outlineRepaired] = false，
  ///     **大纲与正文都不写库**；
  ///   * 大纲修订成功 → 落库 `summary`（一句话梗概）+ `notes`（结构化大纲，
  ///     用户原有备注保留在「【原始备注】」块里，重跑幂等），再调用 [rewrite]；
  ///   * 正文过不了质量闸 → 沿用 [rewrite] 的既有语义：**大纲改动保留、正文不覆盖**。
  ///     （这一点是刻意的：大纲是「改进」，原稿是「资产」，不能因为新稿不合格就把
  ///     改进也回滚掉 —— 作者可以只接受大纲调整后自己改写。）
  Future<ChapterOutlineRepairResult> repairOutlineAndRewrite({
    required String chapterId,
    String projectId = '',
    String instruction = '',
    bool persistOutline = true,
    void Function(String phase)? onProgress,
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    if (chapter == null) {
      return ChapterOutlineRepairResult.outlineFailed(
        chapterTitle: '',
        previousOutline: '',
        rewrite: _chapterMissing(''),
        message: _texts.t('CRW.ChapterMissing', '目标章节不存在或已被删除，请刷新后重试。'),
      );
    }
    final String pid = projectId.trim().isNotEmpty
        ? projectId.trim()
        : (chapter.projectId ?? '');
    final String original = (chapter.content ?? '').trim();
    final String previousOutline = _outlineOf(chapter);

    onProgress?.call('context');
    final _RewriteContext ctx = await _collectContext(
      pid,
      chapter,
      neighbourChars: repairNeighbourChars,
    );

    onProgress?.call('outline');
    final String? raw = await _generate(
      _buildOutlineRepairPrompt(
        chapter: chapter,
        ctx: ctx,
        instruction: instruction.trim(),
      ),
      maxTokens: outlineRepairTokens,
      systemPrompt: _texts.isEnglish
          ? 'You are a senior fiction editor. Output only the requested outline '
                'fields. No prose, no explanations, no word-count hints, no headings.'
          : '你是资深小说编辑。只输出要求的大纲字段，不写正文、不做解释、'
                '不写任何字数提示、不加小标题。',
      temperature: 0.6,
    );

    final RepairedOutline? parsed = raw == null
        ? null
        : OutlineRepairText.parse(raw);
    final String cleanedRaw = raw == null
        ? ''
        : OutlineRepairText.stripMeta(raw);
    final bool structured = parsed != null && parsed.isUsable;
    // 兜底：模型没按格式给，但清洗后仍有一段像样的文字 —— 也当大纲用，
    // 比「直接判失败、作者再点一次」务实（实测小模型的不听话率不低）。
    final bool usable = structured || cleanedRaw.length >= 20;
    if (!usable) {
      final String failMsg = _texts.t(
        'CRW.OutlineRepairFailed',
        '大纲调整失败：模型没有给出可用的大纲内容。本章大纲与正文均未修改，'
            '可先在章节编辑页手工补一段大纲，或在「额外要求」里说明这一章要写什么。',
      );
      return ChapterOutlineRepairResult.outlineFailed(
        chapterTitle: chapter.title,
        previousOutline: previousOutline,
        rewrite: ChapterRewriteResult(
          isSuccess: false,
          content: '',
          message: failMsg,
          chapterTitle: chapter.title,
          originalLength: original.length,
        ),
        message: failMsg,
      );
    }

    final RepairedOutline outline = structured
        ? parsed
        : RepairedOutline(goal: OutlineRepairText.stripFieldLabels(cleanedRaw));
    // 落 notes 的版本**不带**「篇幅」行 —— 那一行本身是写给模型的硬要求，
    // 若也写进 notes，下次清洗时它会被当成元信息残渣（自检 D5 锁死这一点）。
    final String notesOutline = OutlineRepairText.render(
      outline,
      targetWords: 0,
    );

    // 复读闸（+46）：模型在严格惩罚参数下仍可能整段复读（真机实测，见
    // docs/交接-复读问题-外援接入指南.md）。复读内容一旦落进 notes，会在
    // 后续每次「按大纲重写」里传染 —— 无论上游多烂，这里必须自保：
    // 宁可如实失败让作者重点一次，绝不把复读写库。
    if (RepetitionGuard.isDegenerate(notesOutline) ||
        RepetitionGuard.isDegenerate(cleanedRaw)) {
      final String failMsg = _texts.t(
        'CRW.OutlineRepeatBlocked',
        '大纲调整失败：模型输出疑似整段复读，已被防污染策略拦截。'
            '本章大纲与正文均未修改，可稍后重试；若反复出现，'
            '建议在「额外要求」里写明本章具体要推进的剧情。',
      );
      return ChapterOutlineRepairResult.outlineFailed(
        chapterTitle: chapter.title,
        previousOutline: previousOutline,
        rewrite: ChapterRewriteResult(
          isSuccess: false,
          content: '',
          message: failMsg,
          chapterTitle: chapter.title,
          originalLength: original.length,
        ),
        message: failMsg,
      );
    }
    final String storyTime = OutlineRepairText.stripMeta(
      outline.timeNode,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    final String brief = OutlineRepairText.toBrief(
      outline.goal.trim().isNotEmpty ? outline.goal : cleanedRaw,
      maxChars: 120,
    );

    if (persistOutline) {
      try {
        await _chapters.updateById(
          chapter.id,
          ChaptersCompanion(
            summary: Value(brief),
            notes: Value(_composeNotes(chapter.notes, notesOutline)),
            lastEditedAt: Value(DateTime.now()),
          ),
        );
      } on Object catch (e) {
        final String msg = _texts.tf(
          'CRW.OutlinePersistFailed',
          '大纲调整完成，但回写章节失败：{0}',
          <Object>[e],
        );
        return ChapterOutlineRepairResult.outlineFailed(
          chapterTitle: chapter.title,
          previousOutline: previousOutline,
          rewrite: ChapterRewriteResult(
            isSuccess: false,
            content: '',
            message: msg,
            chapterTitle: chapter.title,
            originalLength: original.length,
          ),
          message: msg,
        );
      }
    }

    // 用刚写入的大纲走「规划-续写-润色」管线（它会重新读库，拿到的是修订后的内容）。
    final ChapterRewriteResult rw = await rewriteWithPlan(
      chapterId: chapter.id,
      projectId: pid,
      instruction: instruction,
      storyTime: storyTime,
      outline: notesOutline,
      onProgress: onProgress,
    );

    final String head = _texts.tf(
      'CRW.OutlineRepairedFmt',
      '已按前后章节调整《{0}》的大纲{1}。',
      <Object>[
        chapter.title,
        storyTime.isEmpty
            ? ''
            : _texts.tf('CRW.OutlineTimeFmt', '（故事时间：{0}）', <Object>[
                storyTime,
              ]),
      ],
    );
    return ChapterOutlineRepairResult(
      chapterTitle: chapter.title,
      outlineRepaired: true,
      previousOutline: previousOutline,
      newOutline: notesOutline,
      storyTime: storyTime,
      rewrite: rw,
      message: '$head${rw.message}',
    );
  }

  // ---------------------------------------------------------------------------
  // 规划-续写-润色管线（2026-10-10 第二次完善，用户拍板工艺）
  // ---------------------------------------------------------------------------

  /// **先规划续写切片，再逐片续写达标，最后逐段润色。**
  ///
  /// 为什么 +43 的单发重写不够（用户实测「重写后篇幅未达预期、状态未变更」）：
  /// 单发生成把「约 4200 字」全押一次输出，7B 实际只出 1200~3100 字 →
  /// 过不了 3200 字质量闸 → 不落库 → `status` 停在 Draft、履历一起被卡住。
  ///
  /// 工艺（口径均经用户确认）：
  ///   1. **底座判据**（程序自动）：原稿非空且过质量检查（不看字数）→ 从原稿
  ///      末尾续写；否则第一片从开篇重写（坏稿不保留）；
  ///   2. **规划**：模型按修订大纲产出「片N|目标字数|要点」，解析不出 →
  ///      程序按缺口均分兜底（单片 ≤2200 字，绝不回到「押一次输出」的老路）；
  ///   3. **续写**：逐片串行，每片带前文末尾 + 大纲 + 本片要点；写完仍不足
  ///      3200 字自动补片（至多 [maxTopUpSlices] 片）；**≥3200 过闸即达标**
  ///      （4200 是尽力目标）；
  ///   4. **润色**：主 Agent（7B）按 900 字块逐段审查润色，只改表达不改剧情，
  ///      单块塌缩 <85% 保留原块，整体 <90% 放弃润色；
  ///   5. **落库**：过质量闸 → Draft → Completed → 履历/时间线（含故事时间）
  ///      → **刷新 `projects.progress`**（此前重写落库从不刷进度 —— 用户实测
  ///      「项目进度不同步」的直接原因）。
  ///
  /// 阶段回调：`context` / `plan` / `write` / `polish` / `gate` / `sync` / `progress`。
  ///
  /// [outline] 为修订后的大纲（[repairOutlineAndRewrite] 传入）；空串时回落
  /// 读库的 `_outlineOf`。失败语义与 [rewrite] 一致：**正文没过闸就绝不落库**。
  Future<ChapterRewriteResult> rewriteWithPlan({
    required String chapterId,
    String projectId = '',
    String instruction = '',
    String storyTime = '',
    String outline = '',
    int totalTargetWords = ChapterRewriteService.planTotalTargetWords,
    void Function(String phase)? onProgress,
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    if (chapter == null) return _chapterMissing('');

    final String pid = projectId.trim().isNotEmpty
        ? projectId.trim()
        : (chapter.projectId ?? '');
    final String original = (chapter.content ?? '').trim();

    onProgress?.call('context');
    final _RewriteContext ctx = await _collectContext(pid, chapter);
    final String effectiveOutline = outline.trim().isNotEmpty
        ? outline.trim()
        : _outlineOf(chapter);

    // ① 底座判据（口径经用户确认：程序自动）。
    final bool baseUsable =
        original.isNotEmpty &&
        MultiAgentBookGenerationService.chapterQualityNote(
          original,
          minWords: 0,
        ).isEmpty;
    String accumulated = baseUsable ? original : '';

    // ② 规划：模型产出切片，解析不出走程序兜底。
    onProgress?.call('plan');
    final int remaining = (totalTargetWords - accumulated.length).clamp(
      0,
      1 << 30,
    );
    List<ContinuationSlice> slices = <ContinuationSlice>[];
    if (remaining > 0) {
      final String? planRaw = await _generate(
        _buildSlicePlanPrompt(
          chapter: chapter,
          outline: effectiveOutline,
          ctx: ctx,
          tail: _tailOf(accumulated, 500),
          remainingWords: remaining,
          totalTargetWords: totalTargetWords,
          instruction: instruction.trim(),
        ),
        maxTokens: planTokens,
        systemPrompt: _texts.isEnglish
            ? 'You are a senior fiction editor. Output only slice lines in the '
                  'requested format. No prose, no explanation.'
            : '你是资深小说编辑。只按要求的格式输出片行，不写正文、不做解释。',
        temperature: 0.4,
      );
      slices =
          ((planRaw == null)
              ? null
              : parseSlicePlan(
                  planRaw,
                  remainingWords: remaining,
                  maxSlices: maxSlices,
                )) ??
          fallbackSlices(remainingWords: remaining);
    }

    // ③ 逐片续写（串行：每片接在上一片末尾之后）。
    onProgress?.call('write');
    int sliceNo = 0;
    for (final ContinuationSlice slice in slices) {
      sliceNo++;
      final String tail = _tailOf(accumulated, 500);
      final String? raw = await _generate(
        _buildSlicePrompt(
          chapter: chapter,
          outline: effectiveOutline,
          ctx: ctx,
          slice: slice,
          sliceCount: slices.length,
          tail: tail,
          isFirst: accumulated.isEmpty,
          isLast: sliceNo == slices.length,
        ),
        maxTokens: (slice.targetWords * 2).clamp(1200, 3400),
      );
      if (raw == null || raw.trim().isEmpty) {
        // 单片失败不中断 —— 但底座为空时后续片失去「从开篇写起」的锚，
        // 继续只会写出多个开头，直接如实失败。
        if (accumulated.isEmpty) {
          return ChapterRewriteResult(
            isSuccess: false,
            content: '',
            message: _texts.t(
              'CRW.WriteFailed',
              '重写失败：续写片没有产出内容，原稿未修改。'
                  '请检查「AI 配置」里的模型服务后重试。',
            ),
            chapterTitle: chapter.title,
            originalLength: original.length,
          );
        }
        continue;
      }
      String piece = MultiAgentBookGenerationService.cleanFinalChapter(
        raw,
      ).trim();
      piece = trimSliceEcho(tail, piece);
      if (piece.isEmpty) continue;
      accumulated = accumulated.isEmpty ? piece : '$accumulated\n\n$piece';
    }

    // ③' 补片循环：写完规划片仍不足下限 → 自动补写（至多 [maxTopUpSlices] 片）。
    int topUps = 0;
    while (accumulated.trim().length < minFinalWords &&
        topUps < maxTopUpSlices) {
      topUps++;
      final String tail = _tailOf(accumulated, 500);
      final int need = (totalTargetWords - accumulated.length).clamp(800, 2200);
      final String? raw = await _generate(
        _buildSlicePrompt(
          chapter: chapter,
          outline: effectiveOutline,
          ctx: ctx,
          slice: ContinuationSlice(
            index: sliceNo + 1,
            targetWords: need,
            goal: _texts.t('CRW.TopUpGoal', '补足篇幅：把当前场景写透，不要仓促收尾'),
          ),
          sliceCount: slices.length + maxTopUpSlices,
          tail: tail,
          isFirst: accumulated.isEmpty,
          isLast: false,
          forceLengthWarning: true,
        ),
        maxTokens: (need * 2).clamp(1600, 3400),
      );
      if (raw == null || raw.trim().isEmpty) break;
      String piece = MultiAgentBookGenerationService.cleanFinalChapter(
        raw,
      ).trim();
      piece = trimSliceEcho(tail, piece);
      if (piece.isEmpty) break;
      sliceNo++;
      accumulated = accumulated.isEmpty ? piece : '$accumulated\n\n$piece';
    }

    // ④ 达标判据（口径经用户确认：≥3200 过闸即达标）。
    final String preNote = MultiAgentBookGenerationService.chapterQualityNote(
      accumulated,
      minWords: minFinalWords,
    );
    if (preNote.isNotEmpty) {
      return ChapterRewriteResult(
        isSuccess: false,
        content: accumulated,
        message: _texts.tf(
          'CRW.PlanShortFailed',
          '重写未达标（{0}）：续写后正文 {1} 字，原稿未修改。可重试一次，'
              '或先补全本章大纲再重写。',
          <Object>[preNote, accumulated.trim().length],
        ),
        chapterTitle: chapter.title,
        originalLength: original.length,
        revisedLength: accumulated.trim().length,
        qualityNote: preNote,
      );
    }

    // ⑤ 逐段审查润色（主 Agent / 7B；单块塌缩保留原块，整体塌缩放弃润色）。
    onProgress?.call('polish');
    final String polished = await _polishAll(accumulated, effectiveOutline);
    final String finalText =
        polished.trim().isNotEmpty &&
            polished.length >= (accumulated.length * 0.9).floor()
        ? polished
        : accumulated;

    // ⑥ 定稿质量闸（润色后复检 —— 润色本身也可能把稿子改坏）。
    onProgress?.call('gate');
    final String note = MultiAgentBookGenerationService.chapterQualityNote(
      finalText,
      minWords: minFinalWords,
    );
    if (note.isNotEmpty) {
      return ChapterRewriteResult(
        isSuccess: false,
        content: finalText,
        message: _texts.tf(
          'CRW.QualityFailed',
          '重写未通过质量闸（{0}），原稿未修改。可调整大纲后重试。',
          <Object>[note],
        ),
        chapterTitle: chapter.title,
        originalLength: original.length,
        revisedLength: finalText.length,
        qualityNote: note,
      );
    }

    // ⑦ 落库 + 履历（`_persistAndSync` 负责 Draft → Completed 与世界观同步）。
    final ChapterRewriteResult result = await _persistAndSync(
      chapter: chapter,
      merged: finalText,
      original: original,
      storyTime: storyTime,
      onProgress: onProgress,
    );
    if (!result.persisted) return result;

    // ⑧ 同步刷新项目进度（用户实测「重写后进度不同步」的修复点）。
    onProgress?.call('progress');
    final String progressNote = await _refreshProjectProgress(pid);

    final int plannedTotal = slices.fold<int>(
      0,
      (int s, ContinuationSlice x) => s + x.targetWords,
    );
    final String planInfo = slices.isEmpty
        ? _texts.t('CRW.NoSliceNeeded', '底座已达标，直接进入逐段润色')
        : _texts.tf('CRW.PlanFmt', '已按规划分 {0} 片续写（共约 {1} 字）', <Object>[
            slices.length,
            plannedTotal,
          ]);
    final String polishInfo = identical(polished, finalText)
        ? _texts.t('CRW.PolishDone', '全文已经主模型逐段审查润色')
        : _texts.t('CRW.PolishKept', '润色结果未达保留标准，沿用润色前正文');
    return result.copyWith(
      message: '$planInfo，$polishInfo。${result.message}$progressNote',
    );
  }

  /// 刷新 `projects.progress`（已完成章 / 总章数），返回面向用户的说明
  ///（失败返回空串 —— 进度只是派生量，不能拖垮重写结果）。
  Future<String> _refreshProjectProgress(String pid) async {
    final ProjectRepository? projects = _projects;
    if (projects == null || pid.isEmpty) return '';
    try {
      final List<ChapterRow> rows = await _chapters.getByProjectId(pid);
      final int completed = rows
          .where((ChapterRow c) => c.status == 'Completed')
          .length;
      final int progress = progressFromChapterCounts(
        completed,
        rows.length,
      ).round();
      await projects.updateProgress(pid, progress);
      return _texts.tf('CRW.ProgressFmt', '（项目进度已刷新：{0}%）', <Object>[progress]);
    } on Object {
      return '';
    }
  }

  /// 切片规划提示词。
  String _buildSlicePlanPrompt({
    required ChapterRow chapter,
    required String outline,
    required _RewriteContext ctx,
    required String tail,
    required int remainingWords,
    required int totalTargetWords,
    required String instruction,
  }) {
    final bool en = _texts.isEnglish;
    final StringBuffer sb = StringBuffer();
    if (en) {
      sb.writeln(
        'You are a senior fiction editor. This chapter must be '
        'continued in SLICES to reach the required length.',
      );
      sb.writeln('[Chapter outline]\n$outline\n');
      sb.writeln(
        tail.isEmpty
            ? 'The chapter currently has NO prose; slice 1 starts from the opening.'
            : '[End of the existing prose (slice 1 continues right after it)]\n$tail\n',
      );
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln(
          '[Start of the NEXT chapter — hard boundary, never write into it]\n'
          '${ctx.nextHead}\n',
        );
      }
      sb.writeln(
        'Remaining length to fill: about $remainingWords characters '
        '(gate minimum $minFinalWords, target $totalTargetWords).',
      );
      if (instruction.isNotEmpty) {
        sb.writeln('[Extra requirements from the author]\n$instruction\n');
      }
      sb.writeln(
        'Output format (follow exactly, one line per slice):\n'
        'Slice1|1400|what this slice covers (one sentence)\n'
        'Slice2|1300|...\n'
        'Rules:\n'
        '1. Output ONLY slice lines (1-$maxSlices lines). No prose, no explanation, no Markdown.\n'
        '2. Each slice target is 300-2200 characters; together they must fill the gap.\n'
        '3. The LAST slice must land on the end hook of the outline.',
      );
    } else {
      sb.writeln('你是一位资深中文网文编辑。下面这一章需要**分片续写**补足篇幅。');
      sb.writeln('【本章大纲】\n$outline\n');
      sb.writeln(
        tail.isEmpty
            ? '本章目前**没有正文**，第 1 片将从开篇写起。'
            : '【已有正文末尾（第 1 片要接着它往后写）】\n$tail\n',
      );
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln('【下一章开头（硬边界，任何一片都不要写过来）】\n${ctx.nextHead}\n');
      }
      sb.writeln(
        '还需补足约 $remainingWords 字（定稿下限 $minFinalWords 字，'
        '总目标 $totalTargetWords 字）。',
      );
      if (instruction.isNotEmpty) {
        sb.writeln('【作者额外要求】\n$instruction\n');
      }
      sb.writeln(
        '【输出格式（严格照做，每片一行）】\n'
        '片1|1400|这一片写什么（一句话要点）\n'
        '片2|1300|…\n'
        '纪律：\n'
        '1. 只输出片行（1~$maxSlices 行），不要解释、不要 Markdown、不要正文；\n'
        '2. 每片目标字数 300~2200，所有片加起来要能补足缺口；\n'
        '3. 最后一片必须把剧情收在大纲的【章末钩子】上。',
      );
    }
    return sb.toString();
  }

  /// 单片续写提示词（承接 `_serialSegmentPrompt` 的防回抄语义）。
  String _buildSlicePrompt({
    required ChapterRow chapter,
    required String outline,
    required _RewriteContext ctx,
    required ContinuationSlice slice,
    required int sliceCount,
    required String tail,
    required bool isFirst,
    required bool isLast,
    String instruction = '',
    bool forceLengthWarning = false,
  }) {
    final bool en = _texts.isEnglish;
    final StringBuffer sb = StringBuffer();
    if (en) {
      sb.writeln(
        'You are a top-tier fiction writer. Continue ONE slice of a '
        'novel chapter.',
      );
      sb.writeln();
      if (ctx.promptSummary.trim().isNotEmpty) {
        sb.writeln('[Project bible]\n${ctx.promptSummary.trim()}\n');
      }
      sb.writeln(
        '[Chapter outline]\n'
        '${outline.isEmpty ? '(no outline; continue naturally)' : outline}\n',
      );
      if (isFirst) {
        if (ctx.prevTail.isNotEmpty) {
          sb.writeln(
            '[End of the PREVIOUS chapter — continuity only, do NOT '
            'rewrite it]\n${ctx.prevTail}\n',
          );
        }
        sb.writeln('Start from the opening of this chapter.\n');
      } else {
        sb.writeln(
          '[End of the existing prose (for continuity only, do NOT '
          'output this part)]\n$tail\n',
        );
        sb.writeln(
          'Continue right after it; if it stops mid-sentence, finish '
          'that sentence first; your first sentence must not repeat it.\n',
        );
      }
      sb.writeln(
        '[This slice] ${slice.index}/$sliceCount, target about '
        '${slice.targetWords} characters'
        '${slice.goal.isEmpty ? '' : ': ${slice.goal}'}\n',
      );
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln(
          '[Start of the NEXT chapter — boundary, do NOT write into it]\n'
          '${ctx.nextHead}\n',
        );
      }
      if (instruction.isNotEmpty) {
        sb.writeln('[Extra requirements from the author]\n$instruction\n');
      }
      if (forceLengthWarning) {
        sb.writeln(
          'WARNING: the chapter is still too short; this slice MUST be '
          'about ${slice.targetWords} characters. Do not wrap up early.\n',
        );
      }
      sb.writeln(
        'Rules (must follow):\n'
        '1. Output ONLY the new prose: no title, no explanation, no Markdown, '
        'no word count, no headings, no state blocks.\n'
        '2. Do NOT copy sentences from the given context.\n'
        '3. Do NOT write what belongs to the NEXT chapter.\n'
        '${isLast ? '4. This is the LAST slice: land on the end hook of the outline; '
                  'never write closing markers such as "(THE END)".' : '4. The story continues after this slice; stop on an advancing beat, '
                  'do not wrap up.'}',
      );
    } else {
      sb.writeln('你是一位资深中文网文作家。请为一章小说**续写一段正文**。');
      sb.writeln();
      if (ctx.promptSummary.trim().isNotEmpty) {
        sb.writeln('【项目设定摘要】\n${ctx.promptSummary.trim()}\n');
      }
      sb.writeln(
        '【本章大纲】\n'
        '${outline.isEmpty ? '（本章没有大纲，请紧接上文自然延续）' : outline}\n',
      );
      if (isFirst) {
        if (ctx.prevTail.isNotEmpty) {
          sb.writeln(
            '【上一章结尾（仅供衔接上下文，**不要重写这一章**）】\n'
            '${ctx.prevTail}\n',
          );
        }
        sb.writeln('请从本章开篇写起。\n');
      } else {
        sb.writeln('【前文末尾（仅供衔接上下文，**不要输出这一段**）】\n$tail\n');
        sb.writeln(
          '请**紧接上文继续写**；若前文末尾停在半句，请先把那半句补完再往下写；'
          '第一句不得与前文末尾重复。\n',
        );
      }
      sb.writeln(
        '【本片任务】第 ${slice.index}/$sliceCount 片，目标约 '
        '${slice.targetWords} 字${slice.goal.isEmpty ? '' : '：${slice.goal}'}\n',
      );
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln('【下一章开头（仅供边界，**不要写到这里来**）】\n${ctx.nextHead}\n');
      }
      if (instruction.isNotEmpty) {
        sb.writeln('【作者额外要求】\n$instruction\n');
      }
      if (forceLengthWarning) {
        sb.writeln(
          '⚠ 目前全章仍太短：本片必须写足约 ${slice.targetWords} 字，'
          '不要提前收尾。\n',
        );
      }
      sb.writeln(
        '写作纪律（必须严格遵守）：\n'
        '1. **只输出新增正文**：不要章节标题、不要解释、不要 Markdown、'
        '不要字数统计、不要小标题、不要状态块；\n'
        '2. 不要照抄上文里已有的句子；\n'
        '3. 不要把属于下一章的内容提前写掉；\n'
        '${isLast ? '4. 本片是本章**最后一段**：必须把剧情收在大纲的【章末钩子】上，'
                  '不要提前收尾，也绝对不要写「（全文完）」这类收尾语。' : '4. 本片之后剧情还要继续：停在剧情推进处即可，不要收尾。'}',
      );
    }
    return sb.toString();
  }

  /// 逐段审查润色（主 Agent / 7B）：900 字块、只改表达、塌缩守卫。
  Future<String> _polishAll(String text, String outline) async {
    final List<String> chunks = chunkForPolish(text, target: polishChunkTarget);
    if (chunks.isEmpty) return text;
    final bool en = _texts.isEnglish;
    final String outlineBrief = OutlineRepairText.toBrief(
      outline,
      maxChars: 100,
      fallback: outline.isEmpty
          ? ''
          : outline.substring(0, outline.length.clamp(0, 100)),
    );
    final StringBuffer result = StringBuffer();
    for (int i = 0; i < chunks.length; i++) {
      final String chunk = chunks[i];
      final String prevTail = i == 0 ? '' : _tailOf(chunks[i - 1], 180);
      final StringBuffer sb = StringBuffer();
      if (en) {
        sb.writeln('Polish the following passage sentence by sentence:');
        sb.writeln(
          '- Fix wording ONLY: broken sentences, repetition, pacing, '
          'imagery. Do NOT change plot, characters, facts, or events; do not '
          'add or remove scenes.',
        );
        sb.writeln('- Keep the length within ±10% of the original.');
        sb.writeln(
          '- Output ONLY the polished prose: no explanation, no '
          'headings, no "polished version" prefix.',
        );
        if (outlineBrief.isNotEmpty) {
          sb.writeln(
            '[Chapter outline (reference only, do not copy)]\n$outlineBrief\n',
          );
        }
        if (prevTail.isNotEmpty) {
          sb.writeln(
            '[End of the previous passage (continuity only, do NOT '
            'output this part)]\n$prevTail\n',
          );
        }
        sb.writeln('[Passage to polish]\n$chunk');
      } else {
        sb.writeln('请对下面的正文片段做**逐句审查润色**：');
        sb.writeln(
          '- 只改表达：修病句、去重复、顺节奏、强化画面；'
          '**不改剧情、不改人物、不增删情节、不改事实**；',
        );
        sb.writeln('- 字数与原文相当（±10%），不得缩写或扩写；');
        sb.writeln(
          '- 只输出润色后的正文：不要解释、不要小标题、'
          '不要「润色后版本：」之类前缀。',
        );
        if (outlineBrief.isNotEmpty) {
          sb.writeln('【本章大纲（供对照，不要照抄）】\n$outlineBrief\n');
        }
        if (prevTail.isNotEmpty) {
          sb.writeln('【上一片段结尾（仅供衔接，**不要输出这一段**）】\n$prevTail\n');
        }
        sb.writeln('【待润色片段】\n$chunk');
      }
      final String? raw = await _generate(
        sb.toString(),
        maxTokens: (chunk.length * 2).clamp(1200, 3200),
        systemPrompt: en
            ? 'You are a meticulous fiction editor. Output only the polished '
                  'prose, same plot, same length.'
            : '你是一位细致的中文网文编辑。只输出润色后的正文：剧情不变、长度相当。',
        temperature: 0.5,
      );
      String best = raw == null
          ? ''
          : MultiAgentBookGenerationService.cleanFinalChapter(raw).trim();
      // 塌缩守卫（口径与整书 `_polishDraft` 一致）：单块 <85% 保留原块。
      if (best.length < (chunk.length * 0.85).floor()) best = chunk;
      if (result.isNotEmpty) result.write('\n');
      result.write(best);
    }
    return result.toString();
  }

  /// 大纲修订提示词（中文 / 英文按当前界面语言分流）。
  String _buildOutlineRepairPrompt({
    required ChapterRow chapter,
    required _RewriteContext ctx,
    required String instruction,
  }) {
    final bool en = _texts.isEnglish;
    final String current = _outlineOf(chapter);
    final StringBuffer sb = StringBuffer();

    if (en) {
      sb.writeln(
        'You are a senior fiction editor. This chapter keeps failing the '
        'length / quality gate, and the fix must start from the OUTLINE — not the prose.',
      );
      sb.writeln(
        'Rewrite the outline of THIS one chapter so that it fits the '
        'surrounding chapters and can be written at the required length.',
      );
      sb.writeln();
      if (ctx.promptSummary.trim().isNotEmpty) {
        sb.writeln('[Project bible]\n${ctx.promptSummary.trim()}\n');
      }
      if (ctx.volumeOutline.trim().isNotEmpty) {
        sb.writeln('[Volume outline]\n${ctx.volumeOutline.trim()}\n');
      }
      if (ctx.siblings.isNotEmpty) {
        sb.writeln(
          '[Other chapters of this volume — for positioning only]\n'
          '${ctx.siblings.join('\n')}\n',
        );
      }
      if (ctx.prevTail.isNotEmpty) {
        sb.writeln(
          '[End of the PREVIOUS chapter'
          '${ctx.prevTitle.isEmpty ? '' : ' "${ctx.prevTitle}"'}'
          ' — continuity reference, do NOT rewrite it]\n${ctx.prevTail}\n',
        );
      }
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln(
          '[Start of the NEXT chapter'
          '${ctx.nextTitle.isEmpty ? '' : ' "${ctx.nextTitle}"'}'
          ' — boundary reference, do NOT write into it]\n${ctx.nextHead}\n',
        );
      }
      sb.writeln(
        '[The chapter whose outline must be fixed] '
        '${ctx.projectName.isEmpty ? '' : 'of "${ctx.projectName}" '}— "${chapter.title}"',
      );
      sb.writeln('[Current outline (partly broken)]');
      sb.writeln(current.isEmpty ? '(none)' : current);
      sb.writeln();
      if (instruction.isNotEmpty) {
        sb.writeln('[Extra requirements from the author]\n$instruction\n');
      }
      sb.writeln(_outlineFormatBlock(en: true));
    } else {
      sb.writeln(
        '你是一位资深中文网文编辑。下面这一章**反复写不合格**，'
        '而问题的根子在**大纲**，不在文字。',
      );
      sb.writeln('请依据上下文，把**这一章**的大纲改到「接得上、有冲突、写得够长」的状态。');
      sb.writeln();
      if (ctx.promptSummary.trim().isNotEmpty) {
        sb.writeln('【项目设定摘要】\n${ctx.promptSummary.trim()}\n');
      }
      if (ctx.volumeOutline.trim().isNotEmpty) {
        sb.writeln('【本卷大纲】\n${ctx.volumeOutline.trim()}\n');
      }
      if (ctx.siblings.isNotEmpty) {
        sb.writeln(
          '【本卷其他章节的梗概（仅用于判断本章位置与呼应）】\n'
          '${ctx.siblings.join('\n')}\n',
        );
      }
      if (ctx.prevTail.isNotEmpty) {
        sb.writeln(
          '【上一章结尾'
          '${ctx.prevTitle.isEmpty ? '' : '《${ctx.prevTitle}》'}'
          '（只作为承接依据，**不要重写它**）】\n${ctx.prevTail}\n',
        );
      }
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln(
          '【下一章开头'
          '${ctx.nextTitle.isEmpty ? '' : '《${ctx.nextTitle}》'}'
          '（只作为边界，**不要写到这里来**）】\n${ctx.nextHead}\n',
        );
      }
      sb.writeln(
        '【待修订的这一章】'
        '${ctx.projectName.isEmpty ? '' : '（《${ctx.projectName}》）'}《${chapter.title}》',
      );
      sb.writeln('【现有大纲（部分已损坏）】');
      sb.writeln(current.isEmpty ? '（无）' : current);
      sb.writeln();
      if (instruction.isNotEmpty) {
        sb.writeln('【作者额外要求】\n$instruction\n');
      }
      sb.writeln(_outlineFormatBlock(en: false));
    }
    return sb.toString();
  }

  /// 大纲字段的输出格式约束（中英共用一套纪律，避免两处漂移）。
  static String _outlineFormatBlock({required bool en}) => en
      ? 'Output format (follow exactly, no extra text):\n'
            'Goal: what this chapter must advance to (one sentence)\n'
            'Picks up from: the exact state / event the previous chapter ended on\n'
            'Core conflict: the main tension of this chapter\n'
            'Key turn: the turning point\n'
            'End hook: where it stops and what it teases for the next chapter\n'
            'Characters: who appears (comma separated)\n'
            'Story time: in-story time (e.g. "dusk of the third day")\n'
            '\n'
            'Rules:\n'
            '1. Output ONLY those 7 lines. No prose, no explanation, no code fences, no sub-headings.\n'
            '2. NEVER write a word-count hint ("about 600 words" etc.), and never write '
            'production metadata such as "chapter 7/10" inside a field.\n'
            '3. Length is decided by the system. Do not specify or suggest any length.\n'
            '4. If this chapter\'s position in the volume means no major plot should happen '
            'here, honestly mark it as a transition chapter instead of forcing a climax.'
      : '【输出格式（严格照做，不要任何多余文字）】\n'
            '本章目标：这一章要推进到哪儿（一句话）\n'
            '承接上文：紧接上一章结尾的什么状态 / 事件\n'
            '核心冲突：本章的主要矛盾\n'
            '关键转折：本章的转折点\n'
            '章末钩子：结尾停在哪里、给下一章留什么\n'
            '出场人物：本卷现有角色中本章会出场的人（顿号分隔）\n'
            '故事时间节点：故事内的时间（如「第三日黄昏」「祭祀当夜」）\n'
            '\n'
            '纪律：\n'
            '1. 只输出上面 7 行，不要正文、不要解释、不要 Markdown 代码块、不要小标题；\n'
            '2. **绝对不要**写任何字数提示（「约600字」「目标字数」一律禁止），'
            '也不要在字段里写「第N/M章」这类生产信息；\n'
            '3. 篇幅由系统另行规定，你不需要、也不允许给出字数；\n'
            '4. 若本章在卷中的位置决定了它不该发生重要剧情，请如实写成过渡章，'
            '不要为了「有戏」硬塞高潮。';

  /// 组合 `chapters.notes`：AI 修订大纲块在前，用户原始备注在后（幂等）。
  static String _composeNotes(String? oldNotes, String outline) {
    final String preserved = _stripPreviousOutlineBlock(
      (oldNotes ?? '').trim(),
    );
    final StringBuffer sb = StringBuffer();
    sb.writeln(outlineBlockHeader);
    sb.write(outline.trim());
    if (preserved.isNotEmpty) {
      sb.writeln();
      sb.writeln();
      sb.writeln(notesTailHeader);
      sb.write(preserved);
    }
    return sb.toString();
  }

  /// 去掉上一次写入的「【AI 修订大纲】…【原始备注】」块，只留用户自己的备注。
  ///
  /// 幂等性的关键：不做这一步，反复修复会把旧大纲一层层叠上去，
  /// 最后提示词里同时出现三份互相矛盾的大纲。
  static String _stripPreviousOutlineBlock(String notes) {
    final String text = notes.trim();
    if (text.isEmpty) return '';
    if (!text.startsWith(outlineBlockHeader)) return text;
    final int tail = text.indexOf(notesTailHeader);
    return tail < 0 ? '' : text.substring(tail + notesTailHeader.length).trim();
  }

  /// 组装上下文：前章结尾 / 下章开头 / 同卷兄弟章梗概 / 本卷大纲 / 项目设定摘要。
  ///
  /// [neighbourChars] 决定前后章各取多少字 —— 正文重写用 [neighbourChars]，
  /// 大纲修订用 [repairNeighbourChars]（要判断「这一章该写什么」，400 字不够）。
  Future<_RewriteContext> _collectContext(
    String pid,
    ChapterRow chapter, {
    int neighbourChars = ChapterRewriteService.neighbourChars,
  }) async {
    String prevTail = '';
    String nextHead = '';
    String prevTitle = '';
    String nextTitle = '';
    final List<String> siblings = <String>[];
    try {
      final List<ChapterRow> all = await _chapters.getByProjectId(pid);
      final int at = all.indexWhere((ChapterRow c) => c.id == chapter.id);
      if (at >= 0) {
        if (at > 0) {
          prevTail = _tailOf(all[at - 1].content, neighbourChars);
          prevTitle = all[at - 1].title;
        }
        if (at + 1 < all.length) {
          nextHead = _headOf(all[at + 1].content, neighbourChars);
          nextTitle = all[at + 1].title;
        }
        // 同卷其他章的**梗概**（不取正文）：判断本章在卷中的位置与前后呼应。
        // 只带同卷，避免多卷项目把无关卷的剧情混进来干扰判断。
        for (final ChapterRow c in all) {
          if (c.id == chapter.id || c.volumeId != chapter.volumeId) continue;
          final String brief = OutlineRepairText.stripMeta(
            (c.summary ?? '').trim(),
          ).replaceAll(RegExp(r'\s+'), ' ');
          siblings.add(
            '第${c.orderIndex}章《${c.title}》'
            '${brief.isEmpty ? '' : '：$brief'}',
          );
        }
      }
    } on Object {
      // 上下文装配失败不阻断重写 —— 退化为「只有大纲与设定」。
    }

    String promptSummary = '';
    String projectName = '';
    if (pid.isNotEmpty) {
      try {
        final ProjectContextData? data = await _contextAssembler.build(pid);
        promptSummary = data?.promptSummary ?? '';
        projectName = data?.projectName ?? '';
      } on Object {
        // 同上：项目上下文缺失只降低质量，不阻断。
      }
    }

    // 本卷大纲（`volumes.description` 里存的是整书生成时的分卷大纲摘录）。
    String volumeOutline = '';
    final VolumeRepository? volumes = _volumes;
    if (volumes != null &&
        pid.isNotEmpty &&
        chapter.volumeId.trim().isNotEmpty) {
      try {
        final List<VolumeRow> volRows = await volumes.getByProjectId(pid);
        final int vi = volRows.indexWhere(
          (VolumeRow v) => v.id == chapter.volumeId,
        );
        if (vi >= 0) {
          final String desc = (volRows[vi].description ?? '').trim();
          volumeOutline = desc.length > 900 ? desc.substring(0, 900) : desc;
        }
      } on Object {
        // 卷大纲缺失只降低修订质量，不阻断。
      }
    }

    return _RewriteContext(
      prevTail: prevTail,
      nextHead: nextHead,
      promptSummary: promptSummary,
      projectName: projectName,
      prevTitle: prevTitle,
      nextTitle: nextTitle,
      siblings: siblings,
      volumeOutline: volumeOutline,
    );
  }

  /// 本章的写作依据：优先大纲（`notes` 之外的既有字段），其次梗概。
  ///
  /// 章节表里与「写作依据」相关的字段是 `summary`（梗概）与 `notes`（备注 /
  /// 大纲原文）。实测里 30 章的 `summary` 是「大纲原文截断」—— 所以把 `notes`
  /// 也一并带上（若两者基本相同则只留一份，避免提示词里重复两大段）。
  static String _outlineOf(ChapterRow chapter) {
    final String summary = (chapter.summary ?? '').trim();
    final String notes = (chapter.notes ?? '').trim();
    if (summary.isEmpty) return notes;
    if (notes.isEmpty) return summary;
    if (notes.contains(summary)) return notes;
    if (summary.contains(notes)) return summary;
    return '$summary\n$notes';
  }

  /// 重写提示词（中文 / 英文按当前界面语言分流）。
  String _buildPrompt({
    required ChapterRow chapter,
    required String outline,
    required _RewriteContext ctx,
    required String instruction,
  }) {
    final bool en = _texts.isEnglish;
    final StringBuffer sb = StringBuffer();

    if (en) {
      sb.writeln('You are rewriting ONE chapter of a novel from scratch.');
      sb.writeln();
      if (ctx.promptSummary.trim().isNotEmpty) {
        sb.writeln('[Project bible]\n${ctx.promptSummary.trim()}\n');
      }
      if (ctx.prevTail.isNotEmpty) {
        sb.writeln(
          '[End of the PREVIOUS chapter — for continuity only, do NOT rewrite it]\n'
          '${ctx.prevTail}\n',
        );
      }
      sb.writeln(
        '[This chapter to rewrite] '
        '${ctx.projectName.isEmpty ? '' : 'of "${ctx.projectName}" '}'
        '— "${chapter.title}"\n'
        '${outline.isEmpty ? '(no outline available; continue from the context above)' : outline}\n',
      );
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln(
          '[Start of the NEXT chapter — for continuity only, do NOT write into it]\n'
          '${ctx.nextHead}\n',
        );
      }
      if (instruction.isNotEmpty) {
        sb.writeln('[Extra requirements from the author]\n$instruction\n');
      }
      sb.writeln(
        'Rewrite this chapter as finished novel prose, about 4200 characters.\n'
        'Rules (must follow):\n'
        '1. Output ONLY the chapter prose. No chapter title, no explanation, no Markdown, '
        'no word count, no headings, no state/outline blocks.\n'
        '2. Do NOT copy sentences from the previous chapter ending; the opening must follow '
        'naturally from it.\n'
        '3. Do NOT write what belongs to the next chapter; stop on an advancing beat.\n'
        '4. Never write closing markers such as "(THE END)".',
      );
    } else {
      sb.writeln('你是一位资深中文网文作家。请把下面这一章**从头重写**一遍。');
      sb.writeln();
      if (ctx.promptSummary.trim().isNotEmpty) {
        sb.writeln('【项目设定摘要】\n${ctx.promptSummary.trim()}\n');
      }
      if (ctx.prevTail.isNotEmpty) {
        sb.writeln(
          '【上一章结尾（仅供衔接上下文，**不要重写这一章**）】\n'
          '${ctx.prevTail}\n',
        );
      }
      sb.writeln(
        '【本章要重写的内容】'
        '${ctx.projectName.isEmpty ? '' : '（《${ctx.projectName}》）'}'
        '《${chapter.title}》\n'
        '${outline.isEmpty ? '（本章没有大纲，请紧接上一章结尾自然延续）' : outline}\n',
      );
      if (ctx.nextHead.isNotEmpty) {
        sb.writeln(
          '【下一章开头（仅供衔接上下文，**不要写到这里来**）】\n'
          '${ctx.nextHead}\n',
        );
      }
      if (instruction.isNotEmpty) {
        sb.writeln('【作者额外要求】\n$instruction\n');
      }
      sb.writeln(
        '请重写本章正文，目标约 4200 字。\n'
        '写作纪律（必须严格遵守）：\n'
        '1. **只输出本章正文**：不要章节标题、不要任何解释、不要 Markdown、'
        '不要字数统计、不要小标题、不要状态更新或大纲块；\n'
        '2. 不要照抄上一章结尾的句子，开篇要与其自然衔接；\n'
        '3. 不要把属于下一章的内容提前写掉，结尾停在剧情推进处；\n'
        '4. 绝对不要写「（全文完）」「（完）」这类收尾语。',
      );
    }
    return sb.toString();
  }

  /// 一次生成（带一次重试）；全部失败返回 null —— **绝不降级为占位文本**。
  ///
  /// [systemPrompt] 缺省为「只输出章节正文」的写手人格；大纲修订会传自己的
  /// 编辑人格（见 [repairOutlineAndRewrite]）。
  Future<String?> _generate(
    String body, {
    required int maxTokens,
    String? systemPrompt,
    double temperature = 0.88,
  }) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final String? text = await _generateOnce(
        body,
        maxTokens: maxTokens,
        systemPrompt: systemPrompt,
        temperature: temperature,
      );
      if (text != null && text.trim().isNotEmpty) return text;
      if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  Future<String?> _generateOnce(
    String body, {
    required int maxTokens,
    String? systemPrompt,
    double temperature = 0.88,
  }) async {
    final IModelProvider? provider = _provider();
    if (provider != null && provider.isAvailable) {
      try {
        final ChatResponse resp = await provider.chat(
          ChatRequest(
            systemPrompt:
                systemPrompt ??
                (_texts.isEnglish
                    ? 'You are a top-tier fiction writer. Output only the rewritten '
                          'chapter prose: no explanations, no headings, no title.'
                    : '你是顶级中文网文作家。只输出重写后的章节正文，禁止任何解释、小标题或章节标题。'),
            messages: <ChatMessage>[ChatMessage.user(body)],
            temperature: temperature,
            maxTokens: maxTokens,
            // RWKV 家族才认这套防复读采样参数（其它厂商会 400）
            parameters: isRwkvFamilyProvider(provider.providerName)
                ? Map<String, dynamic>.of(
                    aiRuntimeSettings.longFormSamplingParams(),
                  )
                : <String, dynamic>{},
          ),
        );
        if (resp.isSuccess) {
          final String cleaned = AIOutputSanitizer.extractCleanOutput(
            resp.content,
          ).trim();
          if (cleaned.isNotEmpty) return cleaned;
        }
      } on Object {
        // 静默回落 raw 通道，最终失败由调用方统一报错。
      }
    }

    final RwkvProvider Function()? rwkv = _rwkv;
    if (rwkv == null) return null;
    try {
      final String? raw = await rwkv().completeRawPrompt(
        '$body\n\n【正文】\n',
        maxTokens: maxTokens,
        temperature: temperature,
        topP: 0.85,
      );
      final String cleaned = AIOutputSanitizer.extractCleanOutput(
        raw ?? '',
      ).trim();
      return cleaned.isEmpty ? null : cleaned;
    } on Object {
      return null;
    }
  }

  /// 落库 + 触发世界观同步，并生成面向用户的说明。
  Future<ChapterRewriteResult> _persistAndSync({
    required ChapterRow chapter,
    required String merged,
    required String original,
    String storyTime = '',
    void Function(String phase)? onProgress,
  }) async {
    try {
      await _chapters.updateById(
        chapter.id,
        ChaptersCompanion(
          content: Value(merged),
          wordCount: Value(merged.length),
          lastEditedAt: Value(DateTime.now()),
          versionNumber: Value(chapter.versionNumber + 1),
          // 质量闸已通过 → 视为「已完成」。若本章此前是草稿（生成坏了被降级），
          // 重写成功正好把它扶正；非草稿状态保持不动。
          status: Value(
            chapter.status == 'Draft' ? 'Completed' : chapter.status,
          ),
        ),
      );
    } on Object catch (e) {
      return ChapterRewriteResult(
        isSuccess: true,
        content: merged,
        message: _texts.tf(
          'CRW.PersistFailed',
          '已重写出《{0}》，但回写章节失败：{1}',
          <Object>[chapter.title, e],
        ),
        chapterTitle: chapter.title,
        originalLength: original.length,
        revisedLength: merged.length,
      );
    }

    onProgress?.call('sync');
    String message = _texts.tf(
      'CRW.Applied',
      '已按上下文重写《{0}》：{1} 字 → {2} 字。',
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
            status: chapter.status == 'Draft' ? 'Completed' : chapter.status,
            versionNumber: chapter.versionNumber + 1,
            eventDate: DateTime.now(),
            storyTime: storyTime,
          ),
        );
        if (summary.applied) {
          final List<String> parts = <String>[
            if (summary.ruleApplied) summary.countsForDisplay(_texts),
            if (summary.aiNote.isNotEmpty) summary.aiNote,
          ];
          final String detail = parts
              .where((String p) => p.isNotEmpty)
              .join('；');
          if (detail.isNotEmpty) {
            message += _texts.tf('SYN.SyncDoneFmt', '（世界观自动同步：{0}）', <Object>[
              detail,
            ]);
          }
        } else if (summary.skippedReason != null &&
            summary.skippedReason != 'alreadySynced' &&
            summary.skippedReason != 'disabled') {
          message += _texts.tf('SYN.SyncFailFmt', '（世界观同步未执行：{0}）', <Object>[
            summary.skippedReason ?? '',
          ]);
        }
      } on Object catch (e) {
        message += _texts.tf('SYN.SyncFailFmt', '（世界观同步未执行：{0}）', <Object>[e]);
      }
    }

    return ChapterRewriteResult(
      isSuccess: true,
      content: merged,
      message: message,
      chapterTitle: chapter.title,
      originalLength: original.length,
      revisedLength: merged.length,
      persisted: true,
    );
  }

  ChapterRewriteResult _chapterMissing(String title) => ChapterRewriteResult(
    isSuccess: false,
    content: '',
    message: _texts.t('CRW.ChapterMissing', '目标章节不存在或已被删除，请刷新后重试。'),
    chapterTitle: title,
  );

  /// 取正文末尾 [max] 字，并尽量从句子边界开始（避免半句开头）。
  static String _tailOf(String? content, int max) {
    final String text = (content ?? '').trim();
    if (text.isEmpty) return '';
    if (text.length <= max) return text;
    final String tail = text.substring(text.length - max);
    final int at = tail.indexOf(RegExp(r'[。！？!?…\n]'));
    return (at >= 0 && at + 1 < tail.length) ? tail.substring(at + 1) : tail;
  }

  /// 取正文开头 [max] 字，并尽量在句子边界结束。
  static String _headOf(String? content, int max) {
    final String text = (content ?? '').trim();
    if (text.isEmpty) return '';
    if (text.length <= max) return text;
    final String head = text.substring(0, max);
    final int at = head.lastIndexOf(RegExp(r'[。！？!?…\n]'));
    return at > 0 ? head.substring(0, at + 1) : head;
  }
}

/// 一次重写所需的上下文片段。
class _RewriteContext {
  const _RewriteContext({
    required this.prevTail,
    required this.nextHead,
    required this.promptSummary,
    required this.projectName,
    this.prevTitle = '',
    this.nextTitle = '',
    this.siblings = const <String>[],
    this.volumeOutline = '',
  });

  final String prevTail;
  final String nextHead;
  final String promptSummary;
  final String projectName;

  /// 上一章 / 下一章的标题（大纲修订时给出「承接谁、别写到谁那儿」）。
  final String prevTitle;
  final String nextTitle;

  /// 同卷其他章的「第N章《标题》：梗概」列表。
  final List<String> siblings;

  /// 本卷大纲（`volumes.description`，可能为空）。
  final String volumeOutline;
}
