// 写作档案服务 —— 项目 / 分卷 / 章节 三档档案 + 固定四段描述格式。
//
// 需求口径：
//   * 创建项目后生成【项目档案】；
//   * 按已生成分卷同步生成【分卷档案】；
//   * 章节内容以组长智能体验收通过为准同步生成【章节档案】
//     （其它写作流程在章节落库时以确定性描述生成，不额外调模型）；
//   * 档案描述固定格式：时间范围 + 主题任务 + 得失总结 + 规避措施。
//
// 存储复用 ProjectContentArchiveService（KVStore scope=project_archive，
// 不开新 drift 表 —— schemaVersion=1 无迁移机制）；四段描述同时写入
// metadata（结构化，供 UI 渲染）与 content 首部（纯文本，供只读回看）。
library;

import 'project_content_archive_service.dart';

/// 档案级别。
abstract final class ArchiveLevel {
  static const String project = 'project';
  static const String volume = 'volume';
  static const String chapter = 'chapter';
}

/// 档案四段描述（时间范围+主题任务+得失总结+规避措施）。
class ArchiveDescription {
  const ArchiveDescription({
    required this.timeRange,
    required this.themeTask,
    required this.gainsLosses,
    required this.safeguards,
  });

  final String timeRange;
  final String themeTask;
  final String gainsLosses;
  final String safeguards;

  /// metadata 键（与 ProjectContentArchiveService 的 metadata Map 对齐）。
  static const String kTimeRange = 'timeRange';
  static const String kThemeTask = 'themeTask';
  static const String kGainsLosses = 'gainsLosses';
  static const String kSafeguards = 'safeguards';
  static const String kLevel = 'level';

  Map<String, String> toMetadata() => <String, String>{
        kTimeRange: timeRange,
        kThemeTask: themeTask,
        kGainsLosses: gainsLosses,
        kSafeguards: safeguards,
      };

  static ArchiveDescription fromMetadata(Map<String, String> metadata) =>
      ArchiveDescription(
        timeRange: metadata[kTimeRange] ?? '',
        themeTask: metadata[kThemeTask] ?? '',
        gainsLosses: metadata[kGainsLosses] ?? '',
        safeguards: metadata[kSafeguards] ?? '',
      );

  /// 固定四段格式（作为档案 content 首部；也是展示契约）。
  String format() =>
      '时间范围：${_orDash(timeRange)}\n'
      '主题任务：${_orDash(themeTask)}\n'
      '得失总结：${_orDash(gainsLosses)}\n'
      '规避措施：${_orDash(safeguards)}';

  static String _orDash(String v) => v.trim().isEmpty ? '—' : v.trim();

  /// 缺省字段兜底（确定性描述用）。
  ArchiveDescription withDefaults({
    String? timeRange,
    String? themeTask,
    String? gainsLosses,
    String? safeguards,
  }) =>
      ArchiveDescription(
        timeRange: this.timeRange.trim().isNotEmpty ? this.timeRange : (timeRange ?? ''),
        themeTask: this.themeTask.trim().isNotEmpty ? this.themeTask : (themeTask ?? ''),
        gainsLosses: this.gainsLosses.trim().isNotEmpty ? this.gainsLosses : (gainsLosses ?? ''),
        safeguards: this.safeguards.trim().isNotEmpty ? this.safeguards : (safeguards ?? ''),
      );
}

/// 写作档案服务。
class WritingArchiveService {
  WritingArchiveService({required ProjectContentArchiveService archive})
      : _archive = archive;

  final ProjectContentArchiveService _archive;

  /// 统一写入入口（多智能体 archiveHook 与其它流程共用）。
  ///
  /// [level] 取 [ArchiveLevel] 常量；描述失败折叠为返回码，不抛出。
  Future<ProjectArchiveWriteResult> write({
    required String level,
    required String? projectId,
    required String title,
    required String content,
    required ArchiveDescription desc,
    String? volumeId,
    String? chapterId,
  }) {
    final Map<String, String> metadata = <String, String>{
      ArchiveDescription.kLevel: level,
      ...desc.toMetadata(),
      if (volumeId != null && volumeId.isNotEmpty) 'volumeId': volumeId,
      if (chapterId != null && chapterId.isNotEmpty) 'chapterId': chapterId,
    };
    final String body = content.trim().isEmpty
        ? desc.format()
        : '${desc.format()}\n\n———\n\n$content';
    return _archive.writeCleanContent(
      projectId: projectId,
      taskType: _taskTypeFor(level),
      content: body,
      titleHint: title,
      metadata: metadata,
    );
  }

  /// 章节落库的确定性描述（无组长验收报告的流程使用，不额外调模型）。
  static ArchiveDescription deterministicChapterDesc({
    required String chapterTitle,
    required int wordCount,
    String? outlineOrSummary,
    DateTime? at,
  }) {
    final DateTime t = at ?? DateTime.now();
    final String theme =
        (outlineOrSummary ?? '').trim().split('\n').firstWhere(
              (String l) => l.trim().isNotEmpty,
              orElse: () => '',
            );
    return ArchiveDescription(
      timeRange: '《$chapterTitle》落库于 '
          '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}',
      themeTask: theme.isEmpty ? '按大纲完成本章正文创作' : theme,
      gainsLosses: '正文 $wordCount 字定稿落库',
      safeguards: '后续章节须与本章结尾状态衔接，人物/世界观变更已触发同步',
    );
  }

  static String _taskTypeFor(String level) => switch (level) {
        ArchiveLevel.project => 'ArchiveProject',
        ArchiveLevel.volume => 'ArchiveVolume',
        ArchiveLevel.chapter => 'ArchiveChapter',
        _ => 'ArchiveUnknown',
      };
}
