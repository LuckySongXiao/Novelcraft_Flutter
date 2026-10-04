// 项目纯净内容归档（SubAgent 定稿落档库）。
//
// 对应 C# `WPF/Services/ProjectArchiveService.WriteCleanContentAsync`
// （C# 落 `archive_library/` 目录 + `catalog.json`；Dart 侧改用 `KeyValueStore`）。
//
// 为什么不开新表：drift 侧 `schemaVersion = 1` 且没有 `onUpgrade`，加表必须连带写迁移；
// 而归档内容是**大块文本、只追加、按项目成组**，正好是 KeyValueStore 的适用形态
// （同款先例：`RwkvSessionArchive`）。
//
// 与 C# 的差异：
// 1. **加了上限**：单项目只保留最近 [maxEntriesPerProject] 条（C# 是分文件无上限，
//    Dart 把整个项目序列化成一个 JSON 值，不加上限会无限膨胀）。
// 2. 返回值是**机器码**而不是路径/文案 —— 服务层不硬编码中文，UI 按码取词。
library;

import 'dart:convert';

import '../../data/database.dart';
import '../../data/repositories/project_repository.dart';
import '../../data/storage/key_value_store.dart';

/// 归档写入结果。
class ProjectArchiveWriteResult {
  const ProjectArchiveWriteResult._({
    required this.isSuccess,
    required this.isSkipped,
    required this.code,
  });

  /// 写入成功。
  const ProjectArchiveWriteResult.ok()
      : this._(isSuccess: true, isSkipped: false, code: 'ok');

  /// 跳过（`empty` / `noProject` / `notFound`）。
  const ProjectArchiveWriteResult.skipped(String code)
      : this._(isSuccess: false, isSkipped: true, code: code);

  /// 写入异常。
  const ProjectArchiveWriteResult.failed()
      : this._(isSuccess: false, isSkipped: false, code: 'failed');

  final bool isSuccess;
  final bool isSkipped;

  /// 机器码：`ok` / `empty` / `noProject` / `notFound` / `failed`。
  final String code;

  /// 供 UI 判断"是否需要提示用户"（跳过与失败都值得提示）。
  bool get needsAttention => !isSuccess;
}

/// 一条归档记录。
class ProjectArchiveEntry {
  const ProjectArchiveEntry({
    required this.projectId,
    required this.projectName,
    required this.taskType,
    required this.title,
    required this.content,
    required this.createdAtMs,
    required this.metadata,
  });

  final String projectId;
  final String projectName;

  /// 产生这条内容的 AI 任务类型（如 `GenerateChapterContent`）。
  final String taskType;

  /// 标题提示（对应 C# 的 `titleHint`，可为空）。
  final String title;

  final String content;
  final int createdAtMs;

  /// 附加元信息（双 Agent 的 `WorkflowMode` / `MainDraft` 等）。
  final Map<String, String> metadata;

  int get characterCount => content.length;

  Map<String, Object?> toMap() => <String, Object?>{
        'projectId': projectId,
        'projectName': projectName,
        'taskType': taskType,
        'title': title,
        'content': content,
        'createdAtMs': createdAtMs,
        'metadata': metadata,
      };

  factory ProjectArchiveEntry.fromJson(Map<String, Object?> json) {
    final Object? rawMeta = json['metadata'];
    final Map<String, String> meta = <String, String>{};
    if (rawMeta is Map) {
      rawMeta.forEach((Object? k, Object? v) {
        meta['$k'] = '$v';
      });
    }
    return ProjectArchiveEntry(
      projectId: (json['projectId'] as String?) ?? '',
      projectName: (json['projectName'] as String?) ?? '',
      taskType: (json['taskType'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      metadata: meta,
    );
  }
}

/// 项目纯净内容归档服务。
class ProjectContentArchiveService {
  ProjectContentArchiveService({
    required Future<KeyValueStore> Function() store,
    required ProjectRepository projects,
  })  : _store = store,
        _projects = projects;

  /// KVStore 作用域（与 `ai_config` 分开：这是大块文本，别混进小配置）。
  static const String scope = 'project_archive';

  /// 单项目保留的归档条数上限（新记录插到最前，超出裁掉最旧的）。
  static const int maxEntriesPerProject = 200;

  final Future<KeyValueStore> Function() _store;
  final ProjectRepository _projects;

  static String keyFor(String projectId) => projectId.trim();

  /// 对应 C# `WriteCleanContentAsync(projectId, taskType, content, titleHint, metadata, ct)`。
  ///
  /// 跳过条件逐条对齐 C#：内容空白 / 无项目 ID / 项目查不到。
  Future<ProjectArchiveWriteResult> writeCleanContent({
    required String? projectId,
    required String taskType,
    required String content,
    String? titleHint,
    Map<String, String>? metadata,
  }) async {
    if (content.trim().isEmpty) {
      return const ProjectArchiveWriteResult.skipped('empty');
    }
    final String pid = (projectId ?? '').trim();
    if (pid.isEmpty) {
      return const ProjectArchiveWriteResult.skipped('noProject');
    }
    try {
      final ProjectRow? project = await _projects.getById(pid);
      if (project == null) {
        return const ProjectArchiveWriteResult.skipped('notFound');
      }

      final KeyValueStore kv = await _store();
      final List<ProjectArchiveEntry> entries = await _read(kv, pid);
      entries.insert(
        0,
        ProjectArchiveEntry(
          projectId: pid,
          projectName: project.name,
          taskType: taskType,
          title: titleHint?.trim() ?? '',
          content: content,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          metadata: metadata ?? const <String, String>{},
        ),
      );
      await _writeAll(kv, pid, entries);
      return const ProjectArchiveWriteResult.ok();
    } on Object {
      return const ProjectArchiveWriteResult.failed();
    }
  }

  /// 列出某项目最近的归档（默认最多 50 条，按时间倒序）。
  Future<List<ProjectArchiveEntry>> listEntries(
    String projectId, {
    int limit = 50,
  }) async {
    final String pid = projectId.trim();
    if (pid.isEmpty || limit <= 0) return const <ProjectArchiveEntry>[];
    try {
      final KeyValueStore kv = await _store();
      final List<ProjectArchiveEntry> entries = await _read(kv, pid);
      if (entries.length <= limit) return entries;
      return entries.sublist(0, limit);
    } on Object {
      return const <ProjectArchiveEntry>[];
    }
  }

  /// 手动删除一条归档（下标按 [listEntries] 的返回顺序，0 = 最新）。
  ///
  /// 编辑 / 删除都走「读全量 → 改 → 整体回写」，因此下标必须在同一次读取
  /// 得到的列表上使用 —— UI 每次操作后都会重新 `listEntries`。
  Future<bool> deleteEntry(String projectId, int index) async {
    final String pid = projectId.trim();
    if (pid.isEmpty || index < 0) return false;
    try {
      final KeyValueStore kv = await _store();
      final List<ProjectArchiveEntry> entries = await _read(kv, pid);
      if (index >= entries.length) return false;
      entries.removeAt(index);
      await _writeAll(kv, pid, entries);
      return true;
    } on Object {
      return false;
    }
  }

  /// 手动修改一条归档的标题 / 正文（下标同 [deleteEntry]）。
  ///
  /// 传 null 表示该字段保持不变；元数据（档案描述 / 过程数据）不动。
  Future<bool> updateEntry(
    String projectId,
    int index, {
    String? title,
    String? content,
  }) async {
    final String pid = projectId.trim();
    if (pid.isEmpty || index < 0) return false;
    try {
      final KeyValueStore kv = await _store();
      final List<ProjectArchiveEntry> entries = await _read(kv, pid);
      if (index >= entries.length) return false;
      final ProjectArchiveEntry old = entries[index];
      entries[index] = ProjectArchiveEntry(
        projectId: old.projectId,
        projectName: old.projectName,
        taskType: old.taskType,
        title: title ?? old.title,
        content: content ?? old.content,
        createdAtMs: old.createdAtMs,
        metadata: old.metadata,
      );
      await _writeAll(kv, pid, entries);
      return true;
    } on Object {
      return false;
    }
  }

  /// Reconcile archive metadata with the live project after a rename, import,
  /// or deletion. Returns the number of records changed or removed.
  Future<int> reconcileProject(
    String projectId, {
    required String projectName,
    Set<String>? validVolumeIds,
    Set<String>? validChapterIds,
  }) async {
    final String pid = projectId.trim();
    if (pid.isEmpty) return 0;
    try {
      final KeyValueStore kv = await _store();
      final List<ProjectArchiveEntry> old = await _read(kv, pid);
      int changed = 0;
      final List<ProjectArchiveEntry> next = <ProjectArchiveEntry>[];
      for (final ProjectArchiveEntry entry in old) {
        if (entry.projectId != pid) {
          changed++;
          continue;
        }
        final String volumeId = entry.metadata['volumeId'] ?? '';
        final String chapterId = entry.metadata['chapterId'] ?? '';
        if ((volumeId.isNotEmpty &&
                validVolumeIds != null &&
                !validVolumeIds.contains(volumeId)) ||
            (chapterId.isNotEmpty &&
                validChapterIds != null &&
                !validChapterIds.contains(chapterId))) {
          changed++;
          continue;
        }
        if (entry.projectName != projectName) changed++;
        next.add(ProjectArchiveEntry(
          projectId: entry.projectId,
          projectName: projectName,
          taskType: entry.taskType,
          title: entry.title,
          content: entry.content,
          createdAtMs: entry.createdAtMs,
          metadata: entry.metadata,
        ));
      }
      if (changed > 0) await _writeAll(kv, pid, next);
      return changed;
    } on Object {
      return 0;
    }
  }

  /// 整体回写某项目的归档列表（超上限裁掉最旧的）。
  Future<void> _writeAll(
    KeyValueStore kv,
    String pid,
    List<ProjectArchiveEntry> entries,
  ) async {
    final List<ProjectArchiveEntry> trimmed =
        entries.length > maxEntriesPerProject
            ? entries.sublist(0, maxEntriesPerProject)
            : entries;
    await kv.writeJson(
      scope,
      keyFor(pid),
      jsonEncode(<Object?>[
        for (final ProjectArchiveEntry e in trimmed) e.toMap(),
      ]),
    );
  }

  /// 读取并反序列化；损坏的存档当作空列表（绝不抛出去炸 UI）。
  Future<List<ProjectArchiveEntry>> _read(KeyValueStore kv, String pid) async {
    final String? raw = await kv.readJson(scope, keyFor(pid));
    if (raw == null || raw.isEmpty) return <ProjectArchiveEntry>[];
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return <ProjectArchiveEntry>[];
    final List<ProjectArchiveEntry> out = <ProjectArchiveEntry>[];
    for (final Object? item in decoded) {
      if (item is Map) {
        out.add(ProjectArchiveEntry.fromJson(
          item.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
        ));
      }
    }
    return out;
  }
}
