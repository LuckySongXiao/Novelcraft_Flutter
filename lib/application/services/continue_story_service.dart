// 继续规划剧情并续写 —— 基于项目当前最新状态（主线大纲 / 各卷大纲 /
// 最近章节结尾）自主规划下一章，并在必要时自主追加新分卷；
// 分卷名称与章节名称均由模型自主命名。
//
// 编排：
//   ① 汇总最新 state（主线大纲 + 各卷状态与大纲节选 + 最近一章结尾）
//   ② 主编智能体输出 JSON 决策：{needNewVolume, volumeName, chapterTitle,
//      chapterOutline}（纯函数解析，失败走保守兜底：不新建卷、按序号续章）
//   ③ needNewVolume = true 时自主创建新分卷（自动命名）
//   ④ 双 Agent 写正文（失败回落单次写手调用）→ 落库 + 联动同步
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/rwkv/rwkv_sampling.dart' show isRwkvFamilyProvider;
import '../../ai/runtime_settings.dart';
import '../../ai/utils/output_sanitizer.dart';
import '../../ai/workflow/dual_agent_workflow.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import '../../data/repositories/plot_repository.dart';
import '../../data/repositories/project_repository.dart';
import '../../data/repositories/volume_repository.dart';
import 'chapter_dedup_guard.dart';
import 'chapter_export_service.dart';
import 'chapter_post_process_service.dart';
import 'chapter_sync_service.dart';
import 'writing_archive_service.dart';

const Uuid _uuid = Uuid();

/// 续写决策（主编智能体的 JSON 输出，纯数据）。
class ContinueStoryPlan {
  final bool needNewVolume;
  final String volumeName;
  final String chapterTitle;
  final String chapterOutline;

  const ContinueStoryPlan({
    required this.needNewVolume,
    required this.volumeName,
    required this.chapterTitle,
    required this.chapterOutline,
  });
}

/// 续写结果。
class ContinueStoryResult {
  const ContinueStoryResult({
    required this.isSuccess,
    required this.message,
    this.volumeName = '',
    this.chapterTitle = '',
    this.newVolumeCreated = false,
    this.wordCount = 0,
    this.chapterId = '',
    this.projectId = '',
    this.contentPreview = '',
  });

  final bool isSuccess;
  final String message;
  final String volumeName;
  final String chapterTitle;
  final bool newVolumeCreated;
  final int wordCount;
  final String chapterId;
  final String projectId;
  final String contentPreview;
}

/// 继续规划剧情并续写服务。
class ContinueStoryService {
  ContinueStoryService({
    required this.projects,
    required this.plots,
    required this.volumes,
    required this.chapters,
    required this.dualAgent,
    required this.writingProvider,
    this.postProcess,
    this.writingArchive,
    this.exportService,
  });

  final ProjectRepository projects;
  final PlotRepository plots;
  final VolumeRepository volumes;
  final ChapterRepository chapters;
  final DualAgentWorkflowService dualAgent;

  /// 写作 provider（双代理 SubAgent provider；规划与回落写手都用它）。
  final IModelProvider? Function() writingProvider;

  final ChapterPostProcessService? postProcess;

  /// 写作档案（章节落库即生成章节档案，确定性四段描述；可空不装配）。
  final WritingArchiveService? writingArchive;

  /// 章节结构化导出（可空不装配；失败折叠）。
  final ChapterExportService? exportService;

  Future<ContinueStoryResult> continueStory(
    String projectId, {
    void Function(String step)? onProgress,
  }) async {
    // ---- ① 汇总最新 state ----
    onProgress?.call('正在汇总项目最新状态…');
    final ProjectRow? project = await projects.getById(projectId);
    if (project == null) {
      return ContinueStoryResult(
          isSuccess: false, message: '项目不存在：$projectId', projectId: projectId);
    }
    final List<VolumeRow> volumeRows = await volumes.getByProjectId(projectId);
    volumeRows.sort((VolumeRow a, VolumeRow b) => a.orderIndex.compareTo(b.orderIndex));
    final List<ChapterRow> chapterRows = await chapters.getByProjectId(projectId);
    final String mainOutline = await _mainOutline(projectId);

    // 最近一章（取最后一个有正文的章，按卷序+章序）
    ChapterRow? lastChapter;
    final Map<String, List<ChapterRow>> byVolume = <String, List<ChapterRow>>{};
    for (final ChapterRow c in chapterRows) {
      (byVolume[c.volumeId] ??= <ChapterRow>[]).add(c);
    }
    for (final VolumeRow v in volumeRows.reversed) {
      final List<ChapterRow>? list = byVolume[v.id];
      if (list == null || list.isEmpty) continue;
      final List<ChapterRow> sorted = list
        ..sort((ChapterRow a, ChapterRow b) => a.orderIndex.compareTo(b.orderIndex));
      for (final ChapterRow c in sorted.reversed) {
        if ((c.content ?? '').trim().isNotEmpty) {
          lastChapter = c;
          break;
        }
      }
      if (lastChapter != null) break;
    }

    // ---- ② 主编智能体决策 ----
    onProgress?.call('主编智能体正在根据最新状态规划下一章…');
    final IModelProvider? provider = writingProvider();
    final String volumesDigest = volumeRows.isEmpty
        ? '（项目还没有任何分卷）'
        : <String>[
            for (final VolumeRow v in volumeRows)
              '- ${v.title}（第${v.orderIndex}卷，状态 ${v.status}，'
                  '章节 ${chaptersIn(byVolume, v.id)} 章）'
                  '${(v.description ?? '').trim().isEmpty ? '' : '：${_truncate(v.description!.trim(), 120)}'}',
          ].join('\n');
    final String lastTail = lastChapter == null
        ? '（还没有任何章节，这是全书第一章）'
        : '上一章《${lastChapter.title}》（${lastChapter.volumeId == (volumeRows.isEmpty ? '' : volumeRows.last.id) ? '最新卷' : ''}）'
            '结尾：\n${_truncate((lastChapter.content ?? '').trim(), 800)}';

    final String planRaw = provider == null
        ? ''
        : await _chat(
            provider,
            system: '你是 NovelCraft 的主编智能体（MainAgent），负责根据项目最新状态'
                '规划接下来的剧情。只输出一个 JSON 对象，不要解释、不要 Markdown 包装。',
            user: '长篇小说《${project.name}》需要继续创作下一章。\n\n'
                '【主线大纲】\n${mainOutline.isEmpty ? '（未找到，请依据各卷概览自行推断主线方向）' : _truncate(mainOutline, 1500)}\n\n'
                '【当前分卷与进度】\n$volumesDigest\n\n'
                '【最近章节】\n$lastTail\n\n'
                '请决定接下来一章怎么写，输出 JSON 对象（不要任何其它文本）：\n'
                '{"needNewVolume": false,'
                ' "volumeName": "卷名（仅当 needNewVolume=true 时给出，自主命名，如「第三卷 风起云涌」）",'
                ' "chapterTitle": "章节标题（自主命名，如「第十一章 故人重逢」）",'
                ' "chapterOutline": "本章大纲（200-400 字：本章目标、出场人物、关键冲突、章末钩子）"}\n'
                '决策依据：若当前最后一卷的剧情已接近主线规划的卷末状态，或所有卷都已写满，'
                '则 needNewVolume=true 并为新卷自主命名；否则沿用最后一卷（volumeName 填现有卷名）。',
            maxTokens: 1200,
            temperature: 0.7,
          );
    final ContinueStoryPlan plan =
        parseContinuePlan(planRaw) ?? _fallbackPlan(volumeRows, byVolume, chapterRows);

    // ---- ③ 分卷决策 ----
    String volumeId;
    String volumeName;
    bool newVolumeCreated = false;
    if (plan.needNewVolume || volumeRows.isEmpty) {
      volumeId = _uuid.v4();
      final int nextOrder =
          volumeRows.isEmpty ? 1 : volumeRows.last.orderIndex + 1;
      volumeName = plan.volumeName.trim().isEmpty
          ? '第${_cn(nextOrder)}卷'
          : plan.volumeName.trim();
      await volumes.create(VolumesCompanion.insert(
        id: volumeId,
        title: volumeName,
        projectId: projectId,
        orderIndex: Value(nextOrder),
        status: const Value('Writing'),
      ));
      newVolumeCreated = true;
    } else {
      final VolumeRow last = volumeRows.last;
      volumeId = last.id;
      volumeName = last.title;
    }

    // ---- ④ 写正文（双 Agent，失败回落流式写手）----
    onProgress?.call('正在按大纲撰写《${plan.chapterTitle}》…');
    String content = '';
    final AIAgentRoleWorkflowResult? r = await dualAgent.tryExecute(
      'GenerateChapterContent',
      <String, dynamic>{
        'ProjectId': projectId,
        'ChapterTitle': plan.chapterTitle,
        'Outline': <String>[
          if (plan.chapterOutline.trim().isNotEmpty)
            '本章大纲：${plan.chapterOutline.trim()}',
          if (lastChapter != null)
            '上一章《${lastChapter.title}》结尾：'
                '${_truncate((lastChapter.content ?? '').trim(), 600)}',
          if (volumeRows.isNotEmpty)
            '所在分卷：$volumeName',
        ].join('\n\n'),
      },
    );
    final String dualNote = r == null
        ? '双 Agent 未接管'
        : (r.isSuccess ? '双 Agent 未产出内容' : '双 Agent 失败：${r.message}');
    if (r != null && r.isSuccess && r.content.trim().isNotEmpty) {
      content = r.content;
    } else if (provider != null) {
      // 回落：流式写手（云端经 CF 代理时，非流式长生成必撞 120s 读超时 524）
      content = await _chat(
        provider,
        system: '你是 NovelCraft 的写手智能体，按大纲写出小说正文。只输出正文本身，'
            '不要标题、不要解释、不要 Markdown 包装。',
        user: '长篇小说《${project.name}》，当前要写《${plan.chapterTitle}》'
            '（所属分卷：$volumeName）。\n\n'
            '【主线大纲】\n${mainOutline.isEmpty ? '（无）' : _truncate(mainOutline, 1200)}\n\n'
            '【本章大纲】\n${plan.chapterOutline}\n\n'
            '【衔接】\n$lastTail\n\n'
            '请写出整章正文（约 2500-4000 字），与既有剧情自然衔接。',
        maxTokens: 8000,
        temperature: 0.85,
      );
    }
    if (content.trim().isEmpty) {
      return ContinueStoryResult(
        isSuccess: false,
        message: '正文生成失败：$dualNote；'
            '回落写手${lastChatDiagnostic.isEmpty ? '也未产出内容' : '——$lastChatDiagnostic'}。'
            '（若使用 RWKV 云端等经 CF 代理的端点，请确认客户端已升级到流式调用版本）',
        volumeName: volumeName,
        chapterTitle: plan.chapterTitle,
        newVolumeCreated: newVolumeCreated,
        projectId: projectId,
      );
    }

    // ---- ⑤ 落库（查重防重复创建）+ 联动同步 + 章节档案 ----
    onProgress?.call('正在保存章节…');
    final List<ChapterRow> existingInVolume =
        await chapters.getByVolumeId(volumeId);
    final int nextIndex = existingInVolume.length + 1;

    // 查重：同卷同序号/同标题复用既有行（幂等重跑），杜绝章节标题重复创建
    final ChapterRow? dup = ChapterDedupGuard.findExisting(
      existing: existingInVolume,
      orderIndex: nextIndex,
      title: plan.chapterTitle,
    );
    final String cid;
    if (dup != null) {
      cid = dup.id;
      await chapters.updateById(dup.id, ChaptersCompanion(
        content: Value(content),
        summary: Value(_truncate(plan.chapterOutline, 900)),
        wordCount: Value(content.trim().length),
        status: const Value('Completed'),
        lastEditedAt: Value(DateTime.now()),
      ));
    } else {
      cid = _uuid.v4();
      await chapters.create(ChaptersCompanion.insert(
        id: cid,
        volumeId: volumeId,
        title: plan.chapterTitle,
        projectId: Value(projectId),
        orderIndex: Value(nextIndex),
        status: const Value('Completed'),
        content: Value(content),
        summary: Value(_truncate(plan.chapterOutline, 900)),
        wordCount: Value(content.trim().length),
      ));
    }
    final ChapterPostProcessService? post = postProcess;
    if (post != null) {
      try {
        await post.runForChapter(ChapterSyncInput(
          chapterId: cid,
          volumeId: volumeId,
          projectId: projectId,
          title: plan.chapterTitle,
          orderIndex: nextIndex,
          content: content,
          summary: plan.chapterOutline,
          tags: null,
          notes: null,
          status: 'Completed',
          versionNumber: 1,
          eventDate: DateTime.now(),
        ));
      } on Object {
        // 联动同步失败不阻塞续写结果
      }
    }
    final WritingArchiveService? archive = writingArchive;
    if (archive != null) {
      try {
        await archive.write(
          level: ArchiveLevel.chapter,
          projectId: projectId,
          title: plan.chapterTitle,
          content: content,
          volumeId: volumeId,
          chapterId: cid,
          desc: WritingArchiveService.deterministicChapterDesc(
            chapterTitle: plan.chapterTitle,
            wordCount: content.trim().length,
            outlineOrSummary: plan.chapterOutline,
          ),
        );
      } on Object {
        // 档案失败不阻塞续写结果
      }
    }
    // 结构化导出（Markdown + JSON；失败折叠不阻塞）
    final ChapterExportService? exporter = exportService;
    if (exporter != null) {
      try {
        await exporter.exportChapter(ChapterExportInput(
          projectId: projectId,
          projectName: project.name,
          volumeTitle: volumeName,
          chapterId: cid,
          title: plan.chapterTitle,
          orderIndex: nextIndex,
          status: '落库定稿',
          wordCount: content.trim().length,
          content: content,
          mainOutline: mainOutline,
          chapterOutline: plan.chapterOutline,
          minFinalWords: 4000,
          sections: const <ChapterExportSection>[],
          archive: WritingArchiveService.deterministicChapterDesc(
            chapterTitle: plan.chapterTitle,
            wordCount: content.trim().length,
            outlineOrSummary: plan.chapterOutline,
          ),
        ));
      } on Object {
        // 导出失败不阻塞续写结果
      }
    }

    return ContinueStoryResult(
      isSuccess: true,
      message: newVolumeCreated
          ? '已自主创建新分卷「$volumeName」，并完成《${plan.chapterTitle}》'
              '（${content.trim().length} 字）。'
          : '已在「$volumeName」续写《${plan.chapterTitle}》'
              '（${content.trim().length} 字）。',
      volumeName: volumeName,
      chapterTitle: plan.chapterTitle,
      newVolumeCreated: newVolumeCreated,
      wordCount: content.trim().length,
      chapterId: cid,
      projectId: projectId,
      contentPreview:
          content.trim().length > 300 ? content.substring(0, 300) : content.trim(),
    );
  }

  int chaptersIn(Map<String, List<ChapterRow>> byVolume, String volumeId) =>
      byVolume[volumeId]?.length ?? 0;

  /// 主线大纲：优先 type='主线' 的剧情记录；退化到标题含「主线」；再退化到第一条。
  Future<String> _mainOutline(String projectId) async {
    final List<PlotRow> all = await plots.getByProjectId(projectId);
    if (all.isEmpty) return '';
    for (final PlotRow p in all) {
      if (p.type == '主线') return p.outline ?? '';
    }
    for (final PlotRow p in all) {
      if (p.title.contains('主线')) return p.outline ?? '';
    }
    return all.first.outline ?? '';
  }

  // ---- 决策解析（纯函数，供测试）----

  /// 解析主编决策 JSON；容忍围栏与杂文本；失败返回 null。
  static ContinueStoryPlan? parseContinuePlan(String raw) {
    String text = raw.trim();
    final RegExp fence = RegExp(r'```(?:json)?([\s\S]*?)```', multiLine: true);
    final RegExpMatch? m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on Object {
      return null;
    }
    if (decoded is! Map) return null;
    final String title = (decoded['chapterTitle'] ?? '').toString().trim();
    final String outline = (decoded['chapterOutline'] ?? '').toString().trim();
    if (title.isEmpty) return null;
    return ContinueStoryPlan(
      needNewVolume: decoded['needNewVolume'] == true ||
          decoded['needNewVolume'].toString().toLowerCase() == 'true',
      volumeName: (decoded['volumeName'] ?? '').toString(),
      chapterTitle: title,
      chapterOutline: outline,
    );
  }

  /// 决策解析失败的保守兜底：不新建卷，按序号续写下一章（无卷时新建第一卷）。
  static ContinueStoryPlan _fallbackPlan(
    List<VolumeRow> volumeRows,
    Map<String, List<ChapterRow>> byVolume,
    List<ChapterRow> allChapters,
  ) {
    if (volumeRows.isEmpty) {
      return const ContinueStoryPlan(
        needNewVolume: true,
        volumeName: '第一卷',
        chapterTitle: '第一章',
        chapterOutline: '依据主线大纲展开全书第一章：交代主角与世界观起点，'
            '埋下核心冲突的引子，章末留下推进主线的钩子。',
      );
    }
    final VolumeRow last = volumeRows.last;
    final int next = (byVolume[last.id]?.length ?? 0) + 1;
    return ContinueStoryPlan(
      needNewVolume: false,
      volumeName: last.title,
      chapterTitle: '第${_cn(next)}章',
      chapterOutline: '依据主线大纲与最近章节自然推进剧情，本章完成下一个关键事件，'
          '章末留下推进主线的钩子。',
    );
  }

  /// 最近一次模型调用产出为空的原因（诊断用）。
  String lastChatDiagnostic = '';

  /// 流式优先的单次调用（CF 代理端点非流式长生成会撞 120s 读超时 524）；
  /// 流式失败回落非流式；空产出记录精确原因到 [lastChatDiagnostic]。
  Future<String> _chat(
    IModelProvider provider, {
    required String system,
    required String user,
    required int maxTokens,
    double temperature = 0.7,
  }) async {
    lastChatDiagnostic = '';
    final ChatRequest req = ChatRequest(
      systemPrompt: system,
      messages: <ChatMessage>[ChatMessage.user(user)],
      temperature: temperature,
      maxTokens: maxTokens,
      stream: true,
      parameters: isRwkvFamilyProvider(provider.providerName)
          ? Map<String, dynamic>.of(aiRuntimeSettings.longFormSamplingParams())
          : <String, dynamic>{},
    );
    ChatResponse resp;
    try {
      resp = await provider.chatStream(req, (_) {});
    } on Object {
      try {
        resp = await provider.chat(
          ChatRequest(
            systemPrompt: system,
            messages: <ChatMessage>[ChatMessage.user(user)],
            temperature: temperature,
            maxTokens: maxTokens,
            parameters: isRwkvFamilyProvider(provider.providerName)
                ? Map<String, dynamic>.of(aiRuntimeSettings.longFormSamplingParams())
                : <String, dynamic>{},
          ),
        );
      } on Object catch (e) {
        lastChatDiagnostic = '调用异常：$e';
        return '';
      }
    }
    if (!resp.isSuccess) {
      lastChatDiagnostic = '调用失败：${resp.errorMessage ?? '未知错误'}';
      return '';
    }
    final String cleaned = AIOutputSanitizer.extractCleanOutput(resp.content).trim();
    if (cleaned.isEmpty) {
      lastChatDiagnostic =
          '产出为空（finishReason=${resp.finishReason}，原文长度=${resp.content.length}）';
    }
    return cleaned;
  }

  static String _truncate(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  static String _cn(int n) {
    const List<String> cn = <String>[
      '零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十',
    ];
    if (n <= 10) return cn[n];
    if (n < 20) return '十${cn[n - 10]}';
    if (n < 100) {
      final int tens = n ~/ 10;
      final int ones = n % 10;
      return '${cn[tens]}十${ones == 0 ? '' : cn[ones]}';
    }
    return '$n';
  }
}
