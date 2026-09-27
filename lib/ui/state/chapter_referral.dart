// 「边聊边写」的**目标章节关联状态** —— 提到 Riverpod 的唯一目的是**跨页面保持**。
//
// 对应 C#：`CopilotSessionService` 是单例服务，`ChapterReferral`（书/卷/章 + 处理模式）
// 挂在服务上，所以 MainWindow 切走页面再回来关联还在。Dart 侧 `AppShell._buildPage`
// 每次只挂一个页面，页面 `State` 随导航销毁 —— 关联、模式、三级选择会一起丢失，
// 作者"去卷章管理看一眼再回来"就得重新关联一遍。
//
// 设计取舍：
// 1. 只保存 **ID + 已加载的行数据**，不保存正文副本：改稿时服务按 id 重新读库，
//    保证写回的是最新正文（别的页面改了标题/正文也不会拿到旧快照）。
// 2. 三级下拉的列表也一起放在这里：切回来时**不重复查库**，界面立刻可用。
// 3. 消息流（聊天记录）仍留在页面 State —— 那是页面展示层的事，
//    与本状态解耦（本模块只管"关联到哪一章 + 用什么模式"）。
// 4. **落 KVStore**（`copilot/chapter_referral`）：App 重启后仍然记得上次关联的
//    章节与处理模式 —— 与 `DualAgentSettingsNotifier` 同一套读法（build 先给默认值，
//    再异步恢复；恢复后自愈清理悬空关联）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../data/database.dart';
import '../../data/storage/key_value_store.dart';

/// 「关联目标章节」的会话状态（跨页面保持）。
class ChapterReferral {
  const ChapterReferral({
    this.projects = const <ProjectRow>[],
    this.volumes = const <VolumeRow>[],
    this.chapters = const <ChapterRow>[],
    this.projectId,
    this.volumeId,
    this.pickedChapterId,
    this.linkedChapterId,
    this.reviseMode = true,
    this.expanded = false,
    this.loading = false,
  });

  /// 书籍下拉候选（已加载过的列表，切回页面时复用）。
  final List<ProjectRow> projects;

  /// 分卷下拉候选（随 [projectId] 变化）。
  final List<VolumeRow> volumes;

  /// 章节下拉候选（随 [volumeId] 变化）。
  final List<ChapterRow> chapters;

  /// 当前选中的书籍 / 分卷。
  final String? projectId;
  final String? volumeId;

  /// 下拉里**选中但尚未点「关联」**的章节 —— 与 [linkedChapterId] 必须分开，
  /// 否则"只是挑了一下"就直接进入改写模式，输入会被误当成改进意见。
  final String? pickedChapterId;

  /// 已关联的目标章节（null = 未关联，输入走普通问答）。
  final String? linkedChapterId;

  /// true = 按意见改写（覆盖正文）；false = 按意见续写（末尾追加）。
  final bool reviseMode;

  /// 关联面板是否展开。
  final bool expanded;

  /// 列表加载中（禁用「关联」按钮）。
  final bool loading;

  ProjectRow? get project {
    for (final ProjectRow p in projects) {
      if (p.id == projectId) return p;
    }
    return null;
  }

  VolumeRow? get volume {
    for (final VolumeRow v in volumes) {
      if (v.id == volumeId) return v;
    }
    return null;
  }

  ChapterRow? get pickedChapter {
    for (final ChapterRow c in chapters) {
      if (c.id == pickedChapterId) return c;
    }
    return null;
  }

  ChapterRow? get linkedChapter {
    for (final ChapterRow c in chapters) {
      if (c.id == linkedChapterId) return c;
    }
    return null;
  }

  /// 是否已关联目标章节。
  bool get isLinked => linkedChapter != null;

  /// 面板里展示的卷序（1 起）。
  int get volumeOrder {
    final int i = volumes.indexWhere((VolumeRow v) => v.id == volumeId);
    return i < 0 ? 1 : i + 1;
  }

  /// 面板里展示的章序（卷内，1 起）。
  int get chapterOrder {
    final int i = chapters.indexWhere((ChapterRow c) => c.id == linkedChapterId);
    return i < 0 ? 1 : i + 1;
  }

  /// 三级都选齐了才能点「关联」。
  bool get canLink =>
      project != null && volume != null && pickedChapter != null;
}

/// 关联状态控制器。
class ChapterReferralController extends Notifier<ChapterReferral> {
  /// KVStore 作用域 / 键（对应 C# 的 Copilot 会话，故 scope 用 `copilot`）。
  static const String _scope = 'copilot';
  static const String _key = 'chapter_referral';

  @override
  ChapterReferral build() {
    // 先给默认值保证首帧可用，再异步恢复上次的关联（与双代理配置同一套写法）
    unawaited(_restore());
    return const ChapterReferral();
  }

  /// 拷贝时用游标区分"没传"与"传了 null"（切书/切卷要真把下游清空）。
  static const Object _unset = Object();

  ChapterReferral _copy({
    List<ProjectRow>? projects,
    List<VolumeRow>? volumes,
    List<ChapterRow>? chapters,
    Object? projectId = _unset,
    Object? volumeId = _unset,
    Object? pickedChapterId = _unset,
    Object? linkedChapterId = _unset,
    bool? reviseMode,
    bool? expanded,
    bool? loading,
  }) =>
      ChapterReferral(
        projects: projects ?? state.projects,
        volumes: volumes ?? state.volumes,
        chapters: chapters ?? state.chapters,
        projectId: identical(projectId, _unset)
            ? state.projectId
            : projectId as String?,
        volumeId:
            identical(volumeId, _unset) ? state.volumeId : volumeId as String?,
        pickedChapterId: identical(pickedChapterId, _unset)
            ? state.pickedChapterId
            : pickedChapterId as String?,
        linkedChapterId: identical(linkedChapterId, _unset)
            ? state.linkedChapterId
            : linkedChapterId as String?,
        reviseMode: reviseMode ?? state.reviseMode,
        expanded: expanded ?? state.expanded,
        loading: loading ?? state.loading,
      );

  Future<void> toggleExpanded() async {
    state = _copy(expanded: !state.expanded);
    await _save();
  }

  Future<void> setReviseMode(bool revise) async {
    state = _copy(reviseMode: revise);
    await _save();
  }

  /// 首次展开时加载书籍列表；已加载过（或正在加载）直接跳过 ——
  /// 页面切回来不重复查库。加载失败上抛，由页面弹提示。
  Future<void> ensureProjectsLoaded() async {
    if (state.projects.isNotEmpty || state.loading) return;
    state = _copy(loading: true);
    try {
      state = _copy(projects: await _readProjects(), loading: false);
    } on Object {
      state = _copy(loading: false);
      rethrow;
    }
  }

  /// 选择书籍：清空分卷 / 章节 / 已关联章节（跨书关联不允许，避免误改别的项目）。
  Future<void> selectProject(String? projectId) async {
    state = _copy(
      projectId: projectId,
      volumeId: null,
      pickedChapterId: null,
      linkedChapterId: null,
      volumes: const <VolumeRow>[],
      chapters: const <ChapterRow>[],
      loading: true,
    );
    await _save();
    if (projectId == null || projectId.isEmpty) {
      state = _copy(loading: false);
      return;
    }
    try {
      state = _copy(volumes: await _readVolumes(projectId), loading: false);
    } on Object {
      state = _copy(loading: false);
      rethrow;
    }
  }

  /// 选择分卷：清空章节与已关联章节。
  ///
  /// 返回值 = 本次操作**是否丢掉了原有的关联**（页面据此给作者明确提示）。
  Future<bool> selectVolume(String? volumeId) async {
    final bool dropped = state.linkedChapterId != null;
    state = _copy(
      volumeId: volumeId,
      pickedChapterId: null,
      linkedChapterId: null,
      chapters: const <ChapterRow>[],
      loading: true,
    );
    await _save();
    if (volumeId == null || volumeId.isEmpty) {
      state = _copy(loading: false);
      return dropped;
    }
    try {
      state = _copy(chapters: await _readChapters(volumeId), loading: false);
    } on Object {
      state = _copy(loading: false);
      rethrow;
    }
    return dropped;
  }

  /// 仅记录下拉选择，不进入改写模式 —— 必须 [link] 才生效。
  Future<void> pickChapter(String? chapterId) async {
    state = _copy(pickedChapterId: chapterId);
    await _save();
  }

  /// 关联当前选中的章节；返回是否成功（失败由页面提示"请先选齐"）。
  Future<bool> link() async {
    final ChapterRow? c = state.pickedChapter;
    if (state.project == null || state.volume == null || c == null) return false;
    state = _copy(linkedChapterId: c.id);
    await _save();
    return true;
  }

  /// 解除关联（输入「取消关联」或点「解除关联」）。
  Future<void> unlink() async {
    state = _copy(linkedChapterId: null);
    await _save();
  }

  /// 改稿落库后刷新候选列表里的章节快照（字数/版本变了）。
  /// 只影响内存候选，不进 KVStore（重启后重新查库即可）。
  void replaceChapter(ChapterRow row) {
    final List<ChapterRow> next = state.chapters
        .map((ChapterRow c) => c.id == row.id ? row : c)
        .toList(growable: false);
    state = _copy(chapters: next);
  }

  // ---------------------------------------------------------------------------
  // 持久化（KVStore）—— App 重启后仍记得上次关联的章节与处理模式
  // ---------------------------------------------------------------------------

  /// 只持久化**可重建的 ID 与开关**；候选列表与 loading 都不落盘
  /// （列表重启后重新查库，避免存了一份过期的书名/章节名）。
  Map<String, Object?> _persisted() => <String, Object?>{
        'projectId': state.projectId,
        'volumeId': state.volumeId,
        'pickedChapterId': state.pickedChapterId,
        'linkedChapterId': state.linkedChapterId,
        'reviseMode': state.reviseMode,
        'expanded': state.expanded,
      };

  Future<void> _save() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      await kv.writeJson(_scope, _key, jsonEncode(_persisted()));
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('保存章节关联状态失败：$e');
    }
  }

  /// 恢复上次的关联状态。
  ///
  /// 恢复的不只是 id：候选列表要一起查出来，否则下拉是空的、
  /// `linkedChapter` 也解析不出来（界面会显示"未关联"）。
  /// 最后**自愈**：目标章节/项目已被删除时清掉悬空关联并回写存储。
  Future<void> _restore() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final String? raw = await kv.readJson(_scope, _key);
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final String? projectId = _asId(decoded['projectId']);
      final String? volumeId = _asId(decoded['volumeId']);
      state = _copy(
        projectId: projectId,
        volumeId: volumeId,
        pickedChapterId: _asId(decoded['pickedChapterId']),
        linkedChapterId: _asId(decoded['linkedChapterId']),
        reviseMode: decoded['reviseMode'] as bool? ?? true,
        expanded: decoded['expanded'] as bool? ?? false,
      );

      if (projectId != null) {
        state = _copy(projects: await _readProjects());
        state = _copy(volumes: await _readVolumes(projectId));
        if (volumeId != null) {
          state = _copy(chapters: await _readChapters(volumeId));
        }
      }

      // 自愈：关联的章节已不存在（被删/项目被删）→ 不留悬空关联
      if (state.linkedChapterId != null && state.linkedChapter == null) {
        state = _copy(linkedChapterId: null, pickedChapterId: null);
        await _save();
      }
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('恢复章节关联状态失败：$e');
    }
  }

  static String? _asId(Object? value) {
    if (value is! String) return null;
    final String v = value.trim();
    return v.isEmpty ? null : v;
  }

  Future<List<ProjectRow>> _readProjects() =>
      ref.read(projectRepositoryProvider).getAll();

  Future<List<VolumeRow>> _readVolumes(String projectId) async {
    final List<VolumeRow> rows =
        await ref.read(volumeRepositoryProvider).getByProjectId(projectId);
    rows.sort((VolumeRow a, VolumeRow b) =>
        a.orderIndex.compareTo(b.orderIndex));
    return rows;
  }

  Future<List<ChapterRow>> _readChapters(String volumeId) async {
    final List<ChapterRow> rows =
        await ref.read(chapterRepositoryProvider).getByVolumeId(volumeId);
    rows.sort((ChapterRow a, ChapterRow b) =>
        a.orderIndex.compareTo(b.orderIndex));
    return rows;
  }
}

/// 关联状态 —— **全局单例**，页面销毁不影响（这正是本模块存在的理由）。
final chapterReferralProvider =
    NotifierProvider<ChapterReferralController, ChapterReferral>(
        ChapterReferralController.new);