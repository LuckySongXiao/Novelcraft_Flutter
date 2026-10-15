// 分层写书的 **App 侧装配**：建项目 → 跑四级管线 → 逐级落库。
//
// 与 `tools/layered_pipeline_bench.dart` 共用同一个编排层
// （`LayeredBookGenerationService`）—— 命令行版把产物写文件，App 版写仓库。
//
// 落库映射（全部复用既有列，不新增表）：
//   * 主线大纲   → `Plots(type='主线')` 的 `outline`
//   * 卷大纲     → `Volumes.description`
//   * 章细纲     → `Chapters.summary`（8 行）+ `Chapters.notes`（`## 伏笔提示` 小节）
//   * 章正文     → `Chapters.content` / `wordCount` / `status`
//
// ⚠ 两列有长度上限（`summary` 1000 / `description` 1000），drift 写入时会校验
//（`validateIntegrity` → `checkTextLength`），超限抛 `InvalidDataException` ——
// 所以这里**先截断再写**，不让异常打断整本书的生成。
library;

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../../ai/utils/layered_pipeline_plan.dart';
import '../../data/database.dart';
import '../services/chapter_service.dart';
import '../services/plot_service.dart';
import '../services/project_service.dart';
import '../services/volume_service.dart';
import 'layered_book_generation_service.dart';

const Uuid _uuid = Uuid();

/// 一次分层写书的输入。
class LayeredRunRequest {
  const LayeredRunRequest({
    required this.bookTitle,
    required this.genre,
    required this.theme,
    required this.background,
    required this.protagonist,
    required this.cast,
    required this.volumeCount,
    required this.chaptersPerVolume,
    required this.bookAnchor,
    this.concurrency = 2,
    this.minChapterChars = 1600,
    this.proseStateful = false,
  });

  final String bookTitle;
  final String genre;
  final String theme;
  final String background;
  final String protagonist;
  final String cast;
  final int volumeCount;
  final int chaptersPerVolume;
  final PipelineAnchor bookAnchor;
  final int concurrency;
  final int minChapterChars;

  /// 正文是否走 RWKV 有状态路由（默认 false，见 HANDOFF +50 实测结论）。
  final bool proseStateful;
}

/// 一次分层写书的结果。
class LayeredRunOutcome {
  const LayeredRunOutcome({
    required this.projectId,
    required this.chapterCount,
    required this.passed,
    required this.avgChars,
    required this.avgNgram,
    required this.foreshadowEntries,
    required this.foreshadowErrors,
    required this.notes,
  });

  final String projectId;
  final int chapterCount;
  final int passed;
  final int avgChars;
  final double avgNgram;
  final int foreshadowEntries;
  final int foreshadowErrors;

  /// 管线提示（细纲字段重复、自查补丁不可用等）。
  final List<String> notes;
}

/// 把分层产物写进仓库。
class RepositoryLayeredSink implements LayeredArtifactSink {
  RepositoryLayeredSink({
    required this.projectId,
    required this.volumes,
    required this.chapters,
    required this.plots,
    this.chaptersPerVolume = 5,
    this.onLog,
  });

  final String projectId;
  final VolumeService volumes;
  final ChapterService chapters;
  final PlotService plots;
  final int chaptersPerVolume;
  final void Function(String message)? onLog;

  /// 卷序号（1 起）→ 卷 id。
  final Map<int, String> _volumeIds = <int, String>{};

  /// 全书章序号（1 起）→ 章 id。
  final Map<int, String> _chapterIds = <int, String>{};

  /// 落库统计（供结果展示）。
  final List<String> written = <String>[];

  @override
  Future<void> write(String kind, String key, String content) async {
    switch (kind) {
      case 'mainOutline':
        await _writeMainOutline(content);
      case 'volumeOutline':
        await _writeVolumeOutline(int.tryParse(key) ?? 0, content);
      case 'chapterBrief':
        await _writeChapterBrief(int.tryParse(key) ?? 0, content);
      case 'chapterProse':
        await _writeChapterProse(int.tryParse(key) ?? 0, content);
      default:
        // 里程碑 / 账本摘要等中间产物：不进库（它们可从细纲重新派生）
        return;
    }
  }

  Future<void> _writeMainOutline(String content) async {
    if (content.trim().isEmpty) return;
    final List<PlotRow> existing = await plots.getByProjectId(projectId);
    final PlotRow? main = existing
        .where((PlotRow p) => p.type == '主线')
        .cast<PlotRow?>()
        .firstWhere((PlotRow? p) => true, orElse: () => null);
    if (main != null) {
      await plots.updateById(
        main.id,
        PlotsCompanion(outline: Value(_clip(content, 20000))),
      );
    } else {
      await plots.create(PlotsCompanion.insert(
        id: _uuid.v4(),
        title: '主线大纲',
        type: '主线',
        projectId: projectId,
        importance: const Value(10),
        outline: Value(_clip(content, 20000)),
      ));
    }
    written.add('主线大纲');
    onLog?.call('已写入主线大纲（${content.trim().length} 字）');
  }

  /// 是否已从仓库载入既有卷（保证**重复运行幂等**）。
  ///
  /// ⚠ 这是一个真实 BUG 的修复：`_volumeIds` / `_chapterIds` 是**每次 run 新建的 sink**
  /// 上的实例字段。同名书第二次运行时 sink 是全新的、对既有行一无所知 →
  /// 会把整卷整章**再建一遍**（集成测试 `layered_book_runner_test.dart` 断言
  /// `vs.length == 1` 时实测得到 2，正是这条）。所以必须先查库回填。
  ///
  /// 用 `Future` 缓存而不是 bool 标记：卷是**并行**处理的，bool 标记会让第二个
  /// 并发调用在第一个还在查询时就返回，读到空的 `_volumeIds`。
  Future<void>? _volumesLoad;

  Future<void> _ensureVolumesLoaded() => _volumesLoad ??= () async {
        final List<VolumeRow> existing = await volumes.getByProjectId(projectId);
        for (final VolumeRow v in existing) {
          _volumeIds.putIfAbsent(v.orderIndex, () => v.id);
        }
      }();

  Future<void>? _chaptersLoad;

  /// 载入既有章。键是「卷序 × 卷内章序」推出的**全书序号** —— 必须与管线口径一致
  ///（`Chapters.orderIndex` 是卷内序号，不能直接当全书序号用）。
  Future<void> _ensureChaptersLoaded() => _chaptersLoad ??= () async {
        await _ensureVolumesLoaded();
        final List<ChapterRow> existing =
            await chapters.getByProjectId(projectId);
        for (final ChapterRow c in existing) {
          final int? volOrder = _volumeOrderOf(c.volumeId);
          if (volOrder == null) continue;
          final int global = (volOrder - 1) * chaptersPerVolume + c.orderIndex;
          if (global >= 1) _chapterIds.putIfAbsent(global, () => c.id);
        }
      }();

  int? _volumeOrderOf(String volumeId) {
    for (final MapEntry<int, String> e in _volumeIds.entries) {
      if (e.value == volumeId) return e.key;
    }
    return null;
  }

  Future<void> _writeVolumeOutline(int index, String content) async {
    if (index < 1 || content.trim().isEmpty) return;
    await _ensureVolumesLoaded();
    String? id = _volumeIds[index];
    if (id == null) {
      id = _uuid.v4();
      await volumes.create(VolumesCompanion.insert(
        id: id,
        title: '第 $index 卷',
        projectId: projectId,
        orderIndex: Value(index),
        status: const Value('Writing'),
        description: Value(_clip(content, 1000)),
      ));
      _volumeIds[index] = id;
    } else {
      await volumes.updateById(
        id,
        VolumesCompanion(description: Value(_clip(content, 1000))),
      );
    }
    written.add('第 $index 卷大纲');
    onLog?.call('已写入第 $index 卷大纲');
  }

  Future<void> _writeChapterBrief(int order, String content) async {
    if (order < 1 || content.trim().isEmpty) return;
    final int volumeIndex = (order - 1) ~/ chaptersPerVolume + 1;
    final int orderInVolume = (order - 1) % chaptersPerVolume + 1;
    // 幂等：先回填既有章（否则重复运行会重复建章）
    await _ensureChaptersLoaded();
    String volumeId = _volumeIds[volumeIndex] ?? '';
    if (volumeId.isEmpty) {
      // 卷大纲可能因「内容为空」被 `_writeVolumeOutline` 跳过 → 这里**兜底建卷**。
      // 否则整卷的章节都会被下面的 early-return 静默丢弃（章节细纲 + 正文一起丢）。
      volumeId = _uuid.v4();
      await volumes.create(VolumesCompanion.insert(
        id: volumeId,
        title: '第 $volumeIndex 卷',
        projectId: projectId,
        orderIndex: Value(volumeIndex),
        status: const Value('Writing'),
      ));
      _volumeIds[volumeIndex] = volumeId;
      onLog?.call('第 $volumeIndex 卷无大纲，已兜底建卷以保证章节落库');
    }
    // 细纲（8 行）与伏笔提示分列存：`summary` 有 1000 字上限，`notes` 无上限。
    // ⚠ 用 `BriefPatch.splitBrief` 而不是 `indexOf('## 伏笔提示')` —— 后者在
    //    「裸行 `伏笔提示：`」形态下返回 -1，`substring(0, -1)` 会抛 RangeError。
    final ({String body, String? section}) split = BriefPatch.splitBrief(content);
    final String briefOnly = split.body;
    final String? section = split.section;
    final String title =
        (BriefPatch.parseFields(content)['标题'] ?? '第 $order 章')
            .replaceAll(RegExp(r'^[《【]|[》】]$'), '')
            .trim();
    final String safeTitle =
        title.isEmpty ? '第 $order 章' : _clip(title, 120);
    String? id = _chapterIds[order];
    if (id == null) {
      id = _uuid.v4();
      await chapters.create(ChaptersCompanion.insert(
        id: id,
        volumeId: volumeId,
        title: safeTitle,
        projectId: Value(projectId),
        orderIndex: Value(orderInVolume),
        status: const Value('Draft'),
        summary: Value(_clip(briefOnly, 1000)),
        notes: Value(section),
      ));
      _chapterIds[order] = id;
    } else {
      await chapters.updateById(
        id,
        ChaptersCompanion(
          title: Value(safeTitle),
          summary: Value(_clip(briefOnly, 1000)),
          notes: Value(section),
        ),
      );
    }
    written.add('第 $order 章细纲');
    onLog?.call('已写入第 $order 章细纲《$safeTitle》');
  }

  Future<void> _writeChapterProse(int order, String content) async {
    final String? id = _chapterIds[order];
    if (id == null || content.trim().isEmpty) return;
    await chapters.updateById(
      id,
      ChaptersCompanion(
        content: Value(content),
        wordCount: Value(content.trim().length),
        status: const Value('Completed'),
        lastEditedAt: Value(DateTime.now()),
      ),
    );
    written.add('第 $order 章正文');
    onLog?.call('已写入第 $order 章正文（${content.trim().length} 字）');
  }

  /// 截断到列上限（`withLength` 由 drift 在写入时校验，超限会抛异常）。
  static String _clip(String text, int max) =>
      text.length <= max ? text : text.substring(0, max);
}

/// 分层写书的 App 侧入口：建项目 → 跑管线 → 返回统计。
class LayeredBookRunner {
  LayeredBookRunner({
    required this.projects,
    required this.volumes,
    required this.chapters,
    required this.plots,
    required this.chat,
    this.cleanProse,
    this.qualityNote,
    this.trimEcho,
  });

  final ProjectService projects;
  final VolumeService volumes;
  final ChapterService chapters;
  final PlotService plots;

  /// 一次模型调用（App 侧由 DI 注入真实 provider）。
  final LayeredChat chat;
  final String Function(String raw)? cleanProse;
  final String Function(String prose, int minChars)? qualityNote;
  final String Function(String tail, String piece)? trimEcho;

  Future<LayeredRunOutcome> run(
    LayeredRunRequest req, {
    void Function(String step, double? progress)? onProgress,
  }) async {
    // ---- 建项目（同名走复用，避免重复创建）----
    final ProjectRow? existing = await projects.getByName(req.bookTitle);
    final String projectId = existing?.id ?? _uuid.v4();
    if (existing == null) {
      await projects.create(ProjectsCompanion.insert(
        id: projectId,
        name: req.bookTitle,
        type: req.genre,
        description: Value(req.theme),
        status: const Value('Writing'),
      ));
    }
    onProgress?.call('已创建项目《${req.bookTitle}》', 0.01);

    final RepositoryLayeredSink sink = RepositoryLayeredSink(
      projectId: projectId,
      volumes: volumes,
      chapters: chapters,
      plots: plots,
      chaptersPerVolume: req.chaptersPerVolume,
      onLog: (String m) => onProgress?.call(m, null),
    );
    final LayeredBookGenerationService service =
        LayeredBookGenerationService(
      chat: chat,
      sink: sink,
      onProgress: (String step) => onProgress?.call(step, null),
      cleanProse: cleanProse,
      qualityNote: qualityNote,
      trimEcho: trimEcho,
    );

    final LayeredBookResult result = await service.generate(LayeredBookConfig(
      bookTitle: req.bookTitle,
      genre: req.genre,
      theme: req.theme,
      background: req.background,
      protagonist: req.protagonist,
      cast: req.cast,
      volumeCount: req.volumeCount,
      chaptersPerVolume: req.chaptersPerVolume,
      bookAnchor: req.bookAnchor,
      concurrency: req.concurrency,
      minChapterChars: req.minChapterChars,
      proseStateful: req.proseStateful,
    ));

    return LayeredRunOutcome(
      projectId: projectId,
      chapterCount: result.chapters.length,
      passed: result.passed,
      avgChars: result.avgChars.round(),
      avgNgram: result.avgNgram,
      foreshadowEntries: result.ledger.entries.length,
      foreshadowErrors: result.ledger.errors.length,
      notes: result.failures,
    );
  }
}
