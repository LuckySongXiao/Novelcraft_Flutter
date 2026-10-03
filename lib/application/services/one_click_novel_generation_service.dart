// 一键生成书籍 —— 对应 C# `WPF/Services/OneClickNovelGenerationService.cs`。
//
// 流程：RWKV 自命名（书名/类型/简介）→ 建项目 → 双 Agent 出主线大纲 → 补齐前置条件 →
// 双 Agent 写第一章 → 第一章落库。
//
// 与 C# 的差异：
// 1. **成功语义改为结构化**：C# 只要不抛异常就 `IsSuccess = true`，大纲/首章失败只藏在
//    `Message` 文本里，调用方无法分支。这里把每一步的成败提为显式字段，UI 逐条如实渲染。
// 2. **不谎报联动**：C# 会执行 `ChapterUpdateWorkflowService`（角色出场/剧情进度/时间线同步），
//    该工艺属于后续批次，本批 `linkageApplied` **恒为 false**，结果文案用 `OCG.ResultLinkPending`。
// 3. **RWKV 检查不自动拉起进程**（C# 同）：只 `testConnection`，失败即返回，**数据库零写入**。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/rwkv/rwkv_sampling.dart';
import '../../ai/runtime_settings.dart';
import '../../ai/utils/concept_parser.dart';
import '../../ai/utils/localized_text.dart';
import '../../ai/workflow/dual_agent_workflow.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import '../../data/repositories/plot_repository.dart';
import '../../data/repositories/project_repository.dart';
import '../../data/repositories/volume_repository.dart';
import 'chapter_dedup_guard.dart';
import 'chapter_post_process_service.dart';
import 'chapter_sync_service.dart';
import 'prerequisite_generation_service.dart';
import 'writing_archive_service.dart';

const Uuid _uuid = Uuid();

/// 一键生成结果（结构化，不靠 message 猜成败）。
class OneClickNovelGenerationResult {
  const OneClickNovelGenerationResult({
    required this.isSuccess,
    required this.bookTitle,
    required this.projectId,
    required this.message,
    this.genre = '',
    this.premise = '',
    this.projectCreated = false,
    this.outlineGenerated = false,
    this.outlineSaved = false,
    this.prerequisitesGenerated = false,
    this.chapterGenerated = false,
    this.chapterSaved = false,
    this.linkageApplied = false,
    this.failureStep,
    this.warnings = const <String>[],
    this.outlineText = '',
    this.chapterText = '',
  });

  final bool isSuccess;
  final String bookTitle;
  final String projectId;
  final String message;

  /// 自命名得到的小说类型 / 一句话简介（对应 C# 消息里的 `类型：` / `简介：` 两行）。
  final String genre;
  final String premise;

  final bool projectCreated;
  final bool outlineGenerated;
  final bool outlineSaved;
  final bool prerequisitesGenerated;
  final bool chapterGenerated;
  final bool chapterSaved;

  /// 章节联动同步（人物出场/剧情进度/时间线）—— 功能 C：由后处理编排真实执行，
  /// 开关见 AI 配置页；未开启/失败时为 false 并把原因写进 warnings。
  final bool linkageApplied;

  /// 失败所在步骤：`rwkv` / `concept` / `outline` / `chapter`（成功为 null）。
  final String? failureStep;

  final List<String> warnings;

  /// 功能 B：本次生成的大纲 / 首章正文原文（内存直通，供结果对话框「查看」）。
  final String outlineText;
  final String chapterText;

  /// 供 UI 判断是否要提示"部分失败"。
  bool get hasPartialFailure =>
      isSuccess && !(outlineSaved && chapterSaved);
}

/// 一键生成书籍服务。
class OneClickNovelGenerationService {
  OneClickNovelGenerationService({
    required DualAgentWorkflowService dualAgent,
    required PrerequisiteGenerationService prerequisites,
    required ProjectRepository projects,
    required PlotRepository plots,
    required VolumeRepository volumes,
    required ChapterRepository chapters,
    required RwkvProvider Function() rwkv,
    required IModelProvider? Function() writingProvider,
    required AiTextSource texts,
    ChapterPostProcessService? postProcess,
    WritingArchiveService? writingArchive,
  })  : _dualAgent = dualAgent,
        _prerequisites = prerequisites,
        _projects = projects,
        _plots = plots,
        _volumes = volumes,
        _chapters = chapters,
        _rwkv = rwkv,
        _writingProvider = writingProvider,
        _texts = texts,
        _postProcess = postProcess,
        _writingArchive = writingArchive;

  final DualAgentWorkflowService _dualAgent;
  final PrerequisiteGenerationService _prerequisites;
  final ProjectRepository _projects;
  final PlotRepository _plots;
  final VolumeRepository _volumes;
  final ChapterRepository _chapters;
  final RwkvProvider Function() _rwkv;

  /// 功能 C：首章落库后的世界观自动同步编排（可空 —— 离线测试不装配）。
  final ChapterPostProcessService? _postProcess;

  /// 写作档案（首章落库即生成章节档案，确定性四段描述；可空不装配）。
  final WritingArchiveService? _writingArchive;

  /// 当前配置的写作 provider（双代理的 SubAgent provider）。
  ///
  /// 用它取代「必须本地 RWKV」的硬门槛：这样**只用云端**（不启本地 server）也能一键成书。
  /// 返回 null 时回落到本地 RWKV。
  final IModelProvider? Function() _writingProvider;

  final AiTextSource _texts;

  bool get _en => _texts.isEnglish;

  /// C# 侧项目默认目标字数。
  static const int defaultTargetWordCount = 100000;

  /// 对应 C# `GenerateAsync(progress, ct)`。整个流程**不抛异常**。
  Future<OneClickNovelGenerationResult> generate({
    void Function(String step)? onProgress,
  }) async {
    final List<String> warnings = <String>[];
    final RwkvProvider rwkv = _rwkv();
    final IModelProvider? writer = _writingProvider();

    // 步骤 0：推理服务可用性（不自动拉起进程）—— 必须在任何写库之前
    //
    // 与 C# 的差异：C# 硬编码只检查本地 RWKV。这里优先检查**当前配置的写作 provider**
    // （可以是 `RWKV Cloud`），因此"只用云端、不启本地 server"也能跑通；
    // 没有配置写作 provider 时才回落到本地 RWKV。
    onProgress?.call(_texts.t('OCG.CheckingRwkv', '正在检查推理服务…'));
    final bool online = writer != null
        ? (await writer.testConnection()).isSuccess
        : (await rwkv.testConnection()).isSuccess;
    if (!online) {
      return OneClickNovelGenerationResult(
        isSuccess: false,
        bookTitle: '',
        projectId: '',
        message: _texts.t('OCG.RwkvUnreachable',
            '推理服务不可用。请先在「AI 配置」中启动本地 RWKV 服务，或配置好 RWKV 云端（含 Cloudflare Access 凭证）并设为双代理提供者。'),
        failureStep: 'rwkv',
      );
    }

    // 步骤 1：自命名
    onProgress?.call(_texts.t('OCG.Concepting', '正在构思新书（书名/类型/简介）…'));
    final ({String title, String genre, String premise}) concept;
    try {
      concept = await _generateBookConcept(rwkv, writer);
    } on Object catch (e) {
      return OneClickNovelGenerationResult(
        isSuccess: false,
        bookTitle: '',
        projectId: '',
        message: _texts.tf('MW.OneClickFailed', '一键生成失败：{0}', <Object>[e]),
        failureStep: 'concept',
      );
    }

    // 步骤 2：建项目
    onProgress?.call(_texts.tf(
        'OCG.CreatingBook', '正在创建书籍项目《{0}》…', <Object>[concept.title]));
    String projectId;
    try {
      projectId = await _createProject(concept);
    } on Object catch (e) {
      return OneClickNovelGenerationResult(
        isSuccess: false,
        bookTitle: concept.title,
        projectId: '',
        message: _texts.tf('MW.OneClickFailed', '一键生成失败：{0}', <Object>[e]),
        failureStep: 'concept',
      );
    }

    // 步骤 3：双 Agent 出主线大纲
    onProgress?.call(_texts.tf(
        'OCG.GeneratingOutlineFor', '正在为《{0}》生成主线大纲…', <Object>[concept.title]));
    bool outlineGenerated = false;
    bool outlineSaved = false;
    String outlineContent = '';
    try {
      final AIAgentRoleWorkflowResult? r = await _dualAgent.tryExecute(
        'GenerateOutline',
        <String, dynamic>{
          'ProjectId': projectId,
          'Title': concept.title,
          'theme': '${concept.title}：${concept.premise}',
        },
      );
      if (r != null && r.isSuccess && r.content.trim().isNotEmpty) {
        outlineGenerated = true;
        outlineContent = r.content;
      } else {
        warnings.add(r?.message ?? '');
      }
    } on Object catch (e) {
      warnings.add('$e');
    }

    if (outlineGenerated) {
      try {
        await _plots.create(PlotsCompanion.insert(
          id: _uuid.v4(),
          title: _en
              ? '${concept.title} - Main Outline'
              : '${concept.title}·主线大纲',
          type: '主线',
          projectId: projectId,
          status: const Value('进行中'),
          priority: const Value('高'),
          description: Value(concept.premise),
          outline: Value(outlineContent),
        ));
        outlineSaved = true;
      } on Object catch (e) {
        warnings.add('$e');
      }
    }

    // 步骤 4：补齐前置条件（大纲已有，故跳过剧情大纲生成）
    onProgress?.call(_texts.t('OCG.GeneratingSupport', '正在补齐角色 / 设定 / 势力…'));
    bool prerequisitesGenerated = false;
    try {
      final PrerequisiteGenerationResult pr =
          await _prerequisites.generatePrerequisites(
        projectId,
        options: const PrerequisiteGenerationOptions(
          generatePlotOutlines: false,
        ),
      );
      prerequisitesGenerated = pr.totalGeneratedCount > 0;
    } on Object catch (e) {
      warnings.add('$e');
    }

    // 步骤 5：双 Agent 写第一章
    onProgress?.call(_texts.t('OCG.GeneratingChapter', '正在撰写第一章…'));
    bool chapterGenerated = false;
    bool chapterSaved = false;
    String chapterContent = '';
    try {
      // ⚠ 键名是 `Outline`（不是 ChapterOutline）—— 与 C# 一致，写错模型就看不到上下文
      final AIAgentRoleWorkflowResult? r = await _dualAgent.tryExecute(
        'GenerateChapterContent',
        <String, dynamic>{
          'ProjectId': projectId,
          'ChapterTitle': _en ? 'Chapter 1' : '第一章',
          'Outline': outlineContent.isEmpty ? concept.premise : outlineContent,
        },
      );
      if (r != null && r.isSuccess && r.content.trim().isNotEmpty) {
        chapterGenerated = true;
        chapterContent = r.content;
      } else {
        warnings.add(r?.message ?? '');
      }
    } on Object catch (e) {
      warnings.add('$e');
    }

    if (chapterGenerated) {
      try {
        await _saveFirstChapter(
          projectId: projectId,
          title: _en ? 'Chapter 1' : '第一章',
          content: chapterContent,
          summary: concept.premise,
        );
        chapterSaved = true;
      } on Object catch (e) {
        warnings.add('$e');
      }
    }

    // 章节联动同步（功能 C）：首章落库后自动同步人物/剧情/时间线等。
    // 开关在 AI 配置页；未开启或失败都**如实反映**在 linkageApplied / warnings 里。
    bool linkageApplied = false;
    final ChapterPostProcessService? post = _postProcess;
    if (chapterSaved && post != null) {
      try {
        final ChapterRow? saved = await _chapters.getByProjectId(projectId)
            .then((List<ChapterRow> rows) => rows.firstOrNull);
        if (saved != null) {
          final ChapterPostProcessSummary summary =
              await post.runForChapter(ChapterSyncInput(
            chapterId: saved.id,
            volumeId: saved.volumeId,
            projectId: saved.projectId ?? projectId,
            title: saved.title,
            orderIndex: saved.orderIndex,
            content: chapterContent,
            summary: concept.premise,
            tags: saved.tags,
            notes: saved.notes,
            status: saved.status,
            versionNumber: saved.versionNumber,
            eventDate: DateTime.now(),
          ));
          linkageApplied = summary.applied;
          if (!summary.applied) {
            final String reason = summary.skippedReason ?? '';
            if (reason.isNotEmpty && reason != 'disabled') {
              warnings.add('章节联动同步未执行：$reason');
            }
          }
        }
      } on Object catch (e) {
        warnings.add('章节联动同步未执行：$e');
      }
    }
    final String message = outlineSaved || chapterSaved
        ? _texts.t('MW.OneClickDone', '一键生成完成')
        : _texts.t('MW.OneClickFailed', '一键生成失败：大纲与首章均未落库。');

    return OneClickNovelGenerationResult(
      isSuccess: outlineSaved || chapterSaved,
      bookTitle: concept.title,
      projectId: projectId,
      message: message,
      genre: concept.genre,
      premise: concept.premise,
      projectCreated: true,
      outlineGenerated: outlineGenerated,
      outlineSaved: outlineSaved,
      prerequisitesGenerated: prerequisitesGenerated,
      chapterGenerated: chapterGenerated,
      chapterSaved: chapterSaved,
      linkageApplied: linkageApplied,
      failureStep: (outlineSaved || chapterSaved)
          ? null
          : (outlineGenerated ? 'outline' : 'chapter'),
      warnings:
          warnings.where((String w) => w.trim().isNotEmpty).toList(growable: false),
      outlineText: outlineContent,
      chapterText: chapterContent,
    );
  }

  /// 建项目（对应 C# `ProjectCatalogService.CreateProjectAsync` 的字段集）。
  ///
  /// ⚠ `TargetWordCount / EnableAI / AutoSave / VersionControl / Template` 在 Dart 侧
  /// **没有对应列**，按约定写进 `Projects.settings`（JSON）而不是新增 drift 列
  /// （`schemaVersion = 1` 且无 `onUpgrade`，加列必须连带写迁移）。
  /// 本批只写入、暂无读取方；后续批次接入自动保存/版本控制时从这里取。
  Future<String> _createProject(
    ({String title, String genre, String premise}) concept,
  ) async {
    // 重名解决统一走仓储层（含「软删除同名项目复活」+ 活跃重名加序号），
    // 旧实现只查未删除同名 → 命中软删行时直接炸 UNIQUE constraint failed。
    final ProjectNameResolution res = await _projects.createResolvingName(
      ProjectsCompanion.insert(
        id: _uuid.v4(),
        name: concept.title,
        type: concept.genre,
        description: Value(concept.premise),
        settings: Value(jsonEncode(<String, Object?>{
          'targetWordCount': defaultTargetWordCount,
          'enableAI': true,
          'autoSave': true,
          'versionControl': false,
          'template': 'AI一键生成',
        })),
      ),
    );
    return res.row.id;
  }

  /// 第一章落库（取 Order 最小的卷；无卷则建「第一卷」）。
  Future<void> _saveFirstChapter({
    required String projectId,
    required String title,
    required String content,
    required String summary,
  }) async {
    final List<VolumeRow> volumes = await _volumes.getByProjectId(projectId);
    volumes.sort((VolumeRow a, VolumeRow b) =>
        a.orderIndex.compareTo(b.orderIndex));

    String volumeId;
    if (volumes.isEmpty) {
      volumeId = _uuid.v4();
      await _volumes.create(VolumesCompanion.insert(
        id: volumeId,
        title: _en ? 'Volume 1' : '第一卷',
        projectId: projectId,
        orderIndex: const Value(1),
        status: const Value('Writing'),
      ));
    } else {
      volumeId = volumes.first.id;
    }

    final List<ChapterRow> existingRows = await _chapters.getByVolumeId(volumeId);
    final int existingChapters = existingRows.length;

    // 查重：同卷同序号/同标题复用既有行，杜绝同一章节标题被重复创建
    final ChapterRow? dup = ChapterDedupGuard.findExisting(
      existing: existingRows,
      orderIndex: existingChapters + 1,
      title: title,
    );
    if (dup != null) {
      await _chapters.updateById(dup.id, ChaptersCompanion(
        content: Value(content),
        summary: Value(summary),
        wordCount: Value(content.length),
        lastEditedAt: Value(DateTime.now()),
      ));
      return;
    }

    final String cid = _uuid.v4();
    await _chapters.create(ChaptersCompanion.insert(
      id: cid,
      title: title,
      volumeId: volumeId,
      projectId: Value(projectId),
      content: Value(content),
      summary: Value(summary),
      orderIndex: Value(existingChapters + 1),
      status: const Value('Draft'),
      type: const Value('正文'),
      wordCount: Value(content.length),
    ));

    // 写作档案：章节落库即生成章节档案（确定性四段描述，不额外调模型）
    final WritingArchiveService? archive = _writingArchive;
    if (archive != null) {
      try {
        await archive.write(
          level: ArchiveLevel.chapter,
          projectId: projectId,
          title: title,
          content: content,
          volumeId: volumeId,
          chapterId: cid,
          desc: WritingArchiveService.deterministicChapterDesc(
            chapterTitle: title,
            wordCount: content.length,
            outlineOrSummary: summary,
          ),
        );
      } on Object {
        // 档案失败不阻塞章节落库
      }
    }
  }

  // ------------------------------------------------------------ 自命名与解析

  Future<({String title, String genre, String premise})> _generateBookConcept(
    RwkvProvider rwkv,
    IModelProvider? writer,
  ) async {
    final String systemPrompt = _en
        ? 'You are a senior fiction editor responsible for cover-level planning of brand-new books.'
        : '你是一名资深网文编辑，负责为新书做封面级策划。';
    final String userPrompt = _en
        ? 'Plan a brand-new novel. Output EXACTLY three lines in the following format, one item per line, nothing else:\n'
            '书名：(an evocative ENGLISH book title, 2-6 words, no quotes, keep the label 书名： as-is)\n'
            '类型：(ENGLISH genre, e.g. Fantasy / Urban / Sci-Fi / Romance / Mystery / Thriller, keep the label 类型： as-is)\n'
            '简介：(the core premise in one ENGLISH sentence, max 25 words, keep the label 简介： as-is)\n\n'
            'CRITICAL: every value after each Chinese label MUST be in English.'
        : '请为一部全新的网络书籍做策划。严格按照以下三行格式输出，每行一项，不要输出其他任何内容：\n'
            '书名：（不超过12个字的中文书名，不要书名号）\n'
            '类型：（如：东方玄幻 / 都市异能 / 科幻末日 等）\n'
            '简介：（一句话核心创意，不超过60字）';

    String raw = '';
    if (writer != null) {
      // 走当前配置的写作 provider（本地 RWKV 或 RWKV 云端都适用）。
      // RWKV 家族附带防复读采样参数；maxTokens ≥1200 保证思维链前缀不把正文挤掉。
      final ChatResponse resp = await writer.chat(ChatRequest(
        systemPrompt: systemPrompt,
        messages: <ChatMessage>[ChatMessage.user(userPrompt)],
        temperature: 0.85,
        maxTokens: 1200,
        parameters: isRwkvFamilyProvider(writer.providerName)
            ? Map<String, dynamic>.of(aiRuntimeSettings.longFormSamplingParams())
            : <String, dynamic>{},
      ));
      raw = resp.isSuccess ? (resp.content) : '';
    } else {
      // 回落本地：用 raw prompt 通道（不套 chat 模板），与 C# 一致。
      raw = await rwkv.completeRawPrompt(
            'User: $systemPrompt\n$userPrompt\n\nAssistant:  thinking</think\n',
            maxTokens: 1200,
            temperature: 0.85,
            topP: 0.85,
          ) ??
          '';
    }

    final ({String title, String genre, String premise}) parsed =
        parseBookConcept(raw, isEnglish: _en);
    return (
      title: firstNonEmptyConcept(
          parsed.title, conceptPlaceholderTitle(_en)),
      genre: firstNonEmptyConcept(parsed.genre, _en ? 'Fiction' : '长篇书籍'),
      premise: firstNonEmptyConcept(
        parsed.premise,
        _en
            ? 'A brand-new book project generated end-to-end by the RWKV dual agents.'
            : '由 RWKV 双 Agent 一键生成的全新书籍项目。',
      ),
    );
  }
}
