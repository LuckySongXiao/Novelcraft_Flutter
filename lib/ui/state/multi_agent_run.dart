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

/// 章节阶段中文标签（矩阵/长条共用）。
String multiAgentPhaseLabel(Object phase) => switch (phase) {
      MultiAgentChapterPhase.queued => '排队中',
      MultiAgentChapterPhase.planning => '组长派活',
      MultiAgentChapterPhase.writing => '写手成稿',
      MultiAgentChapterPhase.accepting => '组长验收',
      MultiAgentChapterPhase.rework => '打回返工',
      MultiAgentChapterPhase.leaderFix => '组长补写',
      MultiAgentChapterPhase.polishing => '拼接定稿',
      MultiAgentChapterPhase.done => '已完成',
      MultiAgentChapterPhase.failed => '失败',
      _ => '$phase',
    };

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
class MultiAgentRunState {
  const MultiAgentRunState({
    required this.running,
    this.bookTitle = '',
    this.step = '',
    this.progress,
    this.startedAt,
    this.chapters = const <MultiAgentRunChapter>[],
    this.doneCount = 0,
  });

  final bool running;
  final String bookTitle;
  final String step;
  final double? progress;
  final DateTime? startedAt;
  final List<MultiAgentRunChapter> chapters;
  final int doneCount;

  /// 总体进度：服务层总进度优先，缺省用章节完成度兜底。
  double? get effectiveProgress =>
      progress ?? (chapters.isEmpty ? null : doneCount / chapters.length);
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
      step: '正在启动多智能体协同写作…',
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
        message: '生成过程出现未预期错误：$err',
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
        chapters: state?.chapters ?? const <MultiAgentRunChapter>[],
        doneCount: state?.doneCount ?? 0,
      );
      _completer?.complete(failed);
      return;
    }
    state = MultiAgentRunState(
      running: false,
      bookTitle: config.bookTitle,
      step: r.message,
      progress: 1,
      startedAt: state?.startedAt,
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
      step: step ?? s?.step ?? '',
      progress: progress ?? s?.progress,
      startedAt: s?.startedAt,
      chapters: s?.chapters ?? const <MultiAgentRunChapter>[],
      doneCount: s?.doneCount ?? 0,
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
      step: state?.step ?? '',
      progress: state?.progress,
      startedAt: state?.startedAt,
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
