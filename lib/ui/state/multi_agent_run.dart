// 多智能体写书 · 全局运行状态（跨对话框/跨页面共享）。
//
// 需求：向导对话框可「收起到后台」，生成在后台继续；AppBar 右上角出现
// 绿色「写作中」动态长条（展示最新进度），点击进入章节矩阵视图实时查看
// 各并行团队的写作进度。
//
// 结构：Notifier 持有 MultiAgentRunState（步骤/总进度/章节矩阵），
// 持有 Completer 让收起后的对话框（或再次打开的向导）能等到同一次结果。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/multi_agent_book_generation_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

/// 章节阶段标签（矩阵 / AppBar 长条共用），按当前界面语言渲染。
String multiAgentPhaseLabel(Object phase, L10n l10n) => switch (phase) {
      MultiAgentChapterPhase.queued => l10n.t('MAG.Phase.Queued', '排队中'),
      MultiAgentChapterPhase.planning => l10n.t('MAG.Phase.Planning', '组长派活'),
      MultiAgentChapterPhase.writing => l10n.t('MAG.Phase.Writing', '写手成稿'),
      MultiAgentChapterPhase.accepting => l10n.t('MAG.Phase.Accepting', '组长验收'),
      MultiAgentChapterPhase.rework => l10n.t('MAG.Phase.Rework', '打回返工'),
      MultiAgentChapterPhase.leaderFix => l10n.t('MAG.Phase.LeaderFix', '组长补写'),
      MultiAgentChapterPhase.polishing => l10n.t('MAG.Phase.Polishing', '拼接定稿'),
      MultiAgentChapterPhase.outlineRepair =>
        l10n.t('MAG.Phase.OutlineRepair', '调纲重写'),
      MultiAgentChapterPhase.done => l10n.t('MAG.Phase.Done', '已完成'),
      MultiAgentChapterPhase.failed => l10n.t('MAG.Phase.Failed', '失败'),
      _ => '$phase',
    };

/// 时长文案：`3分05秒` / `3m 05s`（AppBar 长条、生成向导、矩阵对话框共用）。
String formatElapsed(Duration d, L10n l10n) {
  final int m = d.inMinutes;
  final int s = d.inSeconds % 60;
  final String ss = s.toString().padLeft(2, '0');
  return m > 0
      ? l10n.tf('Common.DurationMSFmt', '{0}分{1}秒', <Object>[m, ss])
      : l10n.tf('Common.DurationSFmt', '{0}秒', <Object>[s]);
}

/// 单章的实时写作状态。
class MultiAgentRunChapter {
  const MultiAgentRunChapter({
    required this.id,
    required this.title,
    required this.volumeTitle,
    this.phase = MultiAgentChapterPhase.queued,
    this.progress = 0,
    this.detail = '',
  });

  final String id;
  final String title;
  final String volumeTitle;
  final MultiAgentChapterPhase phase;
  final double progress;
  final String detail;

  MultiAgentRunChapter copyWith({
    MultiAgentChapterPhase? phase,
    double? progress,
    String? detail,
  }) =>
      MultiAgentRunChapter(
        id: id,
        title: title,
        volumeTitle: volumeTitle,
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        detail: detail ?? this.detail,
      );
}

/// 一次写书运行的全局快照。
///
/// ⚠ **运行结束后状态不清空**：作者最需要的「哪几章 NG 了、NG 率多少」恰恰是
/// 跑完之后才看的 —— 清空了就得重跑一次才知道（用户实测痛点：写完窗口自动关闭，
/// 之后再也无法回看本次写作的章节矩阵）。项目概览页与 AppBar 依赖
/// [hasLastRun] 提供「查看上次写作详情」的入口。
class MultiAgentRunState {
  const MultiAgentRunState({
    required this.running,
    this.bookTitle = '',
    this.projectId = '',
    this.step = '',
    this.progress,
    this.startedAt,
    this.finishedAt,
    this.chapters = const <MultiAgentRunChapter>[],
    this.doneCount = 0,
  });

  final bool running;
  final String bookTitle;

  /// 本次运行产出的项目 id（运行中为空串，成功结束后由结果回填）。
  ///
  /// 项目概览页用它判断「上次写作是不是这个项目」，避免 A 项目的概览页
  /// 显示 B 项目的结果入口。
  final String projectId;
  final String step;
  final double? progress;
  final DateTime? startedAt;

  /// 运行结束时刻（运行中为 null）。
  final DateTime? finishedAt;
  final List<MultiAgentRunChapter> chapters;
  final int doneCount;

  /// 总体进度：服务层总进度优先，缺省用章节完成度兜底。
  double? get effectiveProgress =>
      progress ?? (chapters.isEmpty ? null : doneCount / chapters.length);

  /// 是否有一次**已结束**的运行可以回看（矩阵悬浮窗的「重进入口」判据）。
  bool get hasLastRun => !running && chapters.isNotEmpty;

  /// 阶段为失败（质量闸降级草稿 / 写作失败）的章数。
  int get failedCount => chapters
      .where((MultiAgentRunChapter c) => c.phase == MultiAgentChapterPhase.failed)
      .length;

  /// 已定稿章数。
  int get completedCount => chapters
      .where((MultiAgentRunChapter c) => c.phase == MultiAgentChapterPhase.done)
      .length;

  /// **章节 NG 率** = 失败章 / 已出结果的章（排队中等还没轮到的章不计入分母）。
  ///
  /// 这是作者自己心算的那个数 —— 以前界面上不显示，只能盯着红格数（实测）。
  /// 没有任何章出结果时返回 null（不显示 0%，那会误导成「全过」）。
  double? get ngRate {
    final int decided = completedCount + failedCount;
    if (decided == 0) return null;
    return failedCount / decided;
  }
}

/// 全局写书运行控制器。
class MultiAgentRunController extends Notifier<MultiAgentRunState?> {
  Completer<MultiAgentBookResult>? _completer;

  /// Riverpod 3.x：初始状态（无运行任务时为 null）。
  @override
  MultiAgentRunState? build() => null;

  bool get isRunning => state?.running ?? false;

  /// 启动一次写书流程；已有任务进行中时共享同一个结果。
  Future<MultiAgentBookResult> start(MultiAgentBookConfig config) {
    if (isRunning && _completer != null) return _completer!.future;
    _completer = Completer<MultiAgentBookResult>();
    state = MultiAgentRunState(
      running: true,
      bookTitle: config.bookTitle,
      step: ref
          .read(l10nProvider)
          .t('MAG.Starting', '正在启动多智能体协同写作…'),
      startedAt: DateTime.now(),
    );
    _run(config);
    return _completer!.future;
  }

  Future<void> _run(MultiAgentBookConfig config) async {
    final MultiAgentBookResult r;
    try {
      r = await ref.read(multiAgentBookGenerationServiceProvider).generate(
            config: config,
            onProgress: (String step, double? progress) {
              state = _copy(step: step, progress: progress);
            },
            onChapterEvent: (MultiAgentChapterEvent e) {
              _applyChapterEvent(e);
            },
          );
    } on Object catch (err) {
      // 服务层承诺不抛异常；兜底转为失败结果，绝不让后台任务静默蒸发。
      final MultiAgentBookResult failed = MultiAgentBookResult(
        isSuccess: false,
        message: ref.read(l10nProvider).tf(
              'MAG.UnexpectedErrorFmt',
              '生成过程出现未预期错误：{0}',
              <Object>[err],
            ),
        bookTitle: config.bookTitle,
        authorName: config.authorName,
        projectId: '',
        failureStep: 'unexpected',
      );
      state = MultiAgentRunState(
        running: false,
        bookTitle: config.bookTitle,
        step: failed.message,
        startedAt: state?.startedAt,
        finishedAt: DateTime.now(),
        chapters: state?.chapters ?? const <MultiAgentRunChapter>[],
        doneCount: state?.doneCount ?? 0,
      );
      _completer?.complete(failed);
      return;
    }
    state = MultiAgentRunState(
      running: false,
      bookTitle: config.bookTitle,
      projectId: r.projectId,
      step: r.message,
      progress: 1,
      startedAt: state?.startedAt,
      finishedAt: DateTime.now(),
      chapters: state?.chapters ?? const <MultiAgentRunChapter>[],
      doneCount: r.chaptersWritten,
    );
    _completer?.complete(r);
  }

  MultiAgentRunState _copy({String? step, double? progress}) {
    final MultiAgentRunState? s = state;
    return MultiAgentRunState(
      running: s?.running ?? true,
      bookTitle: s?.bookTitle ?? '',
      projectId: s?.projectId ?? '',
      step: step ?? s?.step ?? '',
      progress: progress ?? s?.progress,
      startedAt: s?.startedAt,
      finishedAt: s?.finishedAt,
      chapters: s?.chapters ?? const <MultiAgentRunChapter>[],
      doneCount: s?.doneCount ?? 0,
    );
  }

  /// 单章重写（运行结束后的外部修补）成功后，把矩阵里这一格标为已定稿。
  ///
  /// 矩阵反映的是**本次运行**的结果，而单章重写发生在运行之后 —— 不更新的话，
  /// 作者刚重写完的那一格还挂着「草稿」红标，看起来像没生效。
  void markChapterDone(String chapterId, {String detail = ''}) {
    final List<MultiAgentRunChapter> old =
        state?.chapters ?? <MultiAgentRunChapter>[];
    final int idx =
        old.indexWhere((MultiAgentRunChapter c) => c.id == chapterId);
    if (idx < 0) return;
    final List<MultiAgentRunChapter> chapters =
        List<MultiAgentRunChapter>.of(old);
    chapters[idx] = chapters[idx].copyWith(
      phase: MultiAgentChapterPhase.done,
      progress: 1,
      detail: detail.isEmpty ? chapters[idx].detail : detail,
    );
    state = MultiAgentRunState(
      running: state?.running ?? false,
      bookTitle: state?.bookTitle ?? '',
      projectId: state?.projectId ?? '',
      step: state?.step ?? '',
      progress: state?.progress,
      startedAt: state?.startedAt,
      finishedAt: state?.finishedAt,
      chapters: chapters,
      doneCount: chapters
          .where((MultiAgentRunChapter c) =>
              c.phase == MultiAgentChapterPhase.done)
          .length,
    );
  }

  void _applyChapterEvent(MultiAgentChapterEvent e) {
    final List<MultiAgentRunChapter> old = state?.chapters ?? <MultiAgentRunChapter>[];
    final int idx = old.indexWhere((MultiAgentRunChapter c) => c.id == e.chapterId);
    final MultiAgentRunChapter updated = (idx >= 0 ? old[idx] : MultiAgentRunChapter(
          id: e.chapterId,
          title: e.chapterTitle,
          volumeTitle: e.volumeTitle,
        ))
        .copyWith(phase: e.phase, progress: e.progress, detail: e.detail);
    final List<MultiAgentRunChapter> chapters = List<MultiAgentRunChapter>.of(old);
    if (idx >= 0) {
      chapters[idx] = updated;
    } else {
      chapters.add(updated);
    }
    state = MultiAgentRunState(
      running: true,
      bookTitle: state?.bookTitle ?? '',
      projectId: state?.projectId ?? '',
      step: state?.step ?? '',
      progress: state?.progress,
      startedAt: state?.startedAt,
      finishedAt: null,
      chapters: chapters,
      doneCount: chapters
          .where((MultiAgentRunChapter c) => c.phase == MultiAgentChapterPhase.done)
          .length,
    );
  }
}

/// 全局唯一写书运行状态。
final multiAgentRunProvider =
    NotifierProvider<MultiAgentRunController, MultiAgentRunState?>(
  MultiAgentRunController.new,
);
