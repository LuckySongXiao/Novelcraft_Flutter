// 验收后更新分派服务 —— 组长智能体验收完章节写作内容后，罗列待更新项目，
// 按固定模板接口分派手下 9 位写手更新人物管理/世界观各子项
// （新内容登记或既有设定履历追加）。
//
// 固定模板接口（组长验收报告里的 updates 数组，每条）：
//   {"target":"character|world|faction|plot|timeline",
//    "action":"update|create",
//    "name":"实体准确名称",
//    "field":"status|history|notes|content|description",
//    "content":"需要登记的设定/履历变化"}
//
// 防幻觉约束（对齐 chapter_ai_state_service）：
//   * update 必须 name 与库内实体**精确相等**才应用，否则跳过并记录；
//   * create 仅允许 character/world/plot/timeline（faction 新增易污染关系网，
//     默认拒绝）；名称长度/内容长度有上限；
//   * 条数封顶（默认 20），任何失败只记 issue 绝不阻塞章节保存。
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../ai/utils/output_sanitizer.dart';
import '../../data/database.dart';
import '../../data/repositories/repository_base.dart' show notDeleted;

const Uuid _uuid = Uuid();

/// 单条更新项（固定模板接口）。
class ChapterUpdateItem {
  const ChapterUpdateItem({
    required this.target,
    required this.action,
    required this.name,
    required this.field,
    required this.content,
  });

  static const Set<String> kTargets = <String>{
    'character', 'world', 'faction', 'plot', 'timeline',
  };
  static const Set<String> kActions = <String>{'update', 'create'};
  static const Set<String> kFields = <String>{
    'status', 'history', 'notes', 'content', 'description',
  };

  final String target;
  final String action;
  final String name;
  final String field;
  final String content;

  bool get isValid =>
      kTargets.contains(target) &&
      kActions.contains(action) &&
      kFields.contains(field) &&
      name.trim().isNotEmpty &&
      name.trim().length <= 100 &&
      content.trim().isNotEmpty;

  /// 宽松解析：字段缺省给空串，由 [isValid] 判定（非法项调用方跳过并记录）。
  static ChapterUpdateItem fromMap(Map<String, Object?> m) => ChapterUpdateItem(
        target: (m['target'] ?? '').toString().trim().toLowerCase(),
        action: (m['action'] ?? '').toString().trim().toLowerCase(),
        name: (m['name'] ?? '').toString().trim(),
        field: (m['field'] ?? '').toString().trim().toLowerCase(),
        content: (m['content'] ?? '').toString().trim(),
      );

  static List<ChapterUpdateItem> parseItems(
    Iterable<Map<String, Object?>> raw,
  ) =>
      <ChapterUpdateItem>[
        for (final Map<String, Object?> m in raw) ChapterUpdateItem.fromMap(m),
      ];
}

/// 验收后更新分派服务。
class TeamUpdateDispatchService {
  TeamUpdateDispatchService({required AppDatabase db, this.maxItems = 20})
      : _db = db;

  final AppDatabase _db;

  /// 单章更新项上限（防组长幻觉刷库）。
  final int maxItems;

  /// 分派并应用。
  ///
  /// [items] 为组长验收报告的 updates 原始条目；
  /// [writerChat] 由调用方提供（绑定团队写手的独享 state 通道），
  /// 参数为（写手槽位 1..9，派发提示词），返回写手产出的最终登记文本。
  ///
  /// 返回 issue 列表（空 = 全部应用成功）；任何失败只记 issue 不抛出。
  Future<List<String>> dispatchUpdates({
    required String projectId,
    required List<Map<String, Object?>> items,
    required Future<String> Function(int writerSlot, String prompt) writerChat,
  }) async {
    final List<String> issues = <String>[];
    final String pid = projectId.trim();
    if (pid.isEmpty) {
      return <String>['缺少 projectId，更新分派跳过'];
    }

    // ---- 1. 解析 + 校验 + 封顶 ----
    final List<ChapterUpdateItem> all = ChapterUpdateItem.parseItems(items)
        .where((ChapterUpdateItem it) => it.isValid)
        .toList(growable: true);
    final int dropped = items.length - all.length;
    if (dropped > 0) {
      issues.add('$dropped 条更新项格式非法，已跳过');
    }
    if (all.length > maxItems) {
      issues.add('更新项 ${all.length} 条超上限 $maxItems，已截断');
      all.removeRange(maxItems, all.length);
    }
    if (all.isEmpty) return issues;

    // ---- 2. 按 target 分组（保持出现顺序），组内全局轮转写手槽位 ----
    final List<String> targetOrder = <String>[];
    final Map<String, List<ChapterUpdateItem>> groups =
        <String, List<ChapterUpdateItem>>{};
    for (final ChapterUpdateItem it in all) {
      (groups[it.target] ??= <ChapterUpdateItem>[]).add(it);
      if (!targetOrder.contains(it.target)) targetOrder.add(it.target);
    }

    int slotSeq = 0;
    for (final String target in targetOrder) {
      for (final ChapterUpdateItem it in groups[target]!) {
        final int slot = (slotSeq++ % 9) + 1;
        try {
          // 写手按各自偏向产出最终登记文本；产出为空回落组长原始 content
          final String produced =
              await writerChat(slot, _writerPrompt(slot, it));
          String content = AIOutputSanitizer.extractCleanOutput(produced).trim();
          if (content.isEmpty || content.length < 4) content = it.content;
          content = content.length > 500 ? content.substring(0, 500) : content;

          final String? issue = await _apply(pid, it, content);
          if (issue != null) issues.add(issue);
        } on Object catch (e) {
          issues.add('「${it.name}」分派失败：$e');
        }
      }
    }
    return issues;
  }

  // -----------------------------------------------------------------------

  String _writerPrompt(int slot, ChapterUpdateItem it) =>
      '你是章节写作团队的写手 writer-$slot。组长派发设定登记任务：\n'
      '- 目标：${it.target}\n- 动作：${it.action}\n- 实体：${it.name}\n'
      '- 字段：${it.field}\n- 原始变更：${it.content}\n\n'
      '请把它整理成可直接登记的设定/履历文本（一到三句话，客观陈述、'
      '贴合既有世界观，不要评论不要解释）。只输出文本本身。';

  /// 应用一条更新；返回 issue（null = 成功）。
  Future<String?> _apply(
    String pid,
    ChapterUpdateItem it,
    String content,
  ) async {
    switch (it.target) {
      case 'character':
        return _applyCharacter(pid, it, content);
      case 'world':
        return _applyWorld(pid, it, content);
      case 'faction':
        return _applyFaction(pid, it, content);
      case 'plot':
        return _applyPlot(pid, it, content);
      case 'timeline':
        return _applyTimeline(pid, it, content);
    }
    return '未知目标 ${it.target}，已跳过';
  }

  String _append(String? existing, String content) {
    final String base = (existing ?? '').trim();
    final String line = '[团队更新] $content';
    return base.isEmpty ? line : '$base\n$line';
  }

  Future<String?> _applyCharacter(
    String pid,
    ChapterUpdateItem it,
    String content,
  ) async {
    final List<CharacterRow> rows = await (_db.select(_db.characters)..where(
      (t) => t.projectId.equals(pid) & notDeleted(t.isDeleted),
    )).get();
    final CharacterRow? hit = _exactName<CharacterRow>(
      rows, it.name, (CharacterRow r) => r.name,
    );
    if (hit != null) {
      await (_db.update(_db.characters)
            ..where((t) => t.id.equals(hit.id)))
          .write(CharactersCompanion(
        status: it.field == 'status' ? Value(_clamp(content, 50)) : const Value.absent(),
        history: it.field == 'history'
            ? Value(_append(hit.history, content))
            : const Value.absent(),
        notes: it.field == 'notes'
            ? Value(_append(hit.notes, content))
            : const Value.absent(),
      ));
      return null;
    }
    if (it.action == 'create') {
      await _db.into(_db.characters).insert(CharactersCompanion.insert(
            id: _newId(),
            name: _clamp(it.name, 100),
            type: '配角',
            projectId: pid,
            status: const Value('Active'),
            notes: Value(content),
          ));
      return null;
    }
    return '人物「${it.name}」不在库中，update 已跳过（防幻觉）';
  }

  Future<String?> _applyWorld(
    String pid,
    ChapterUpdateItem it,
    String content,
  ) async {
    final List<WorldSettingRow> rows = await (_db.select(_db.worldSettings)
          ..where((t) =>
              t.projectId.equals(pid) & notDeleted(t.isDeleted)))
        .get();
    final Iterable<WorldSettingRow> hits =
        rows.where((WorldSettingRow r) => r.name.trim() == it.name.trim());
    if (hits.isNotEmpty) {
      final WorldSettingRow hit = hits.first;
      await (_db.update(_db.worldSettings)
            ..where((t) => t.id.equals(hit.id)))
          .write(WorldSettingsCompanion(
        status: it.field == 'status' ? Value(_clamp(content, 50)) : const Value.absent(),
        history: it.field == 'history'
            ? Value(_append(hit.history, content))
            : const Value.absent(),
        notes: it.field == 'notes'
            ? Value(_append(hit.notes, content))
            : const Value.absent(),
        content: it.field == 'content' ? Value(content) : const Value.absent(),
        description: it.field == 'description'
            ? Value(content)
            : const Value.absent(),
      ));
      return null;
    }
    if (it.action == 'create') {
      await _db.into(_db.worldSettings).insert(WorldSettingsCompanion.insert(
            id: _newId(),
            name: _clamp(it.name, 200),
            type: '设定',
            projectId: pid,
            content: Value(content),
          ));
      return null;
    }
    return '世界设定「${it.name}」不在库中，update 已跳过（防幻觉）';
  }

  Future<String?> _applyFaction(
    String pid,
    ChapterUpdateItem it,
    String content,
  ) async {
    final List<FactionRow> rows = await (_db.select(_db.factions)..where(
      (t) => t.projectId.equals(pid) & notDeleted(t.isDeleted),
    )).get();
    final Iterable<FactionRow> hits =
        rows.where((FactionRow r) => r.name.trim() == it.name.trim());
    if (hits.isNotEmpty) {
      final FactionRow hit = hits.first;
      await (_db.update(_db.factions)
            ..where((t) => t.id.equals(hit.id)))
          .write(FactionsCompanion(
        status: it.field == 'status' ? Value(_clamp(content, 50)) : const Value.absent(),
        history: it.field == 'history'
            ? Value(_append(hit.history, content))
            : const Value.absent(),
        notes: it.field == 'notes'
            ? Value(_append(hit.notes, content))
            : const Value.absent(),
        description: it.field == 'description'
            ? Value(content)
            : const Value.absent(),
      ));
      return null;
    }
    // 势力不开放 create（新增势力影响关系网/成员统计，必须人工建）
    return '势力「${it.name}」不在库中，已跳过（势力新增须人工确认）';
  }

  Future<String?> _applyPlot(
    String pid,
    ChapterUpdateItem it,
    String content,
  ) async {
    final List<PlotRow> rows = await (_db.select(_db.plots)..where(
      (t) => t.projectId.equals(pid) & notDeleted(t.isDeleted),
    )).get();
    final Iterable<PlotRow> hits =
        rows.where((PlotRow r) => r.title.trim() == it.name.trim());
    if (hits.isNotEmpty) {
      final PlotRow hit = hits.first;
      await (_db.update(_db.plots)
            ..where((t) => t.id.equals(hit.id)))
          .write(PlotsCompanion(
        notes: it.field == 'notes' || it.field == 'history'
            ? Value(_append(hit.notes, content))
            : const Value.absent(),
        description: it.field == 'description'
            ? Value(content)
            : const Value.absent(),
      ));
      return null;
    }
    if (it.action == 'create') {
      await _db.into(_db.plots).insert(PlotsCompanion.insert(
            id: _newId(),
            title: _clamp(it.name, 200),
            type: '支线',
            projectId: pid,
            description: Value(content),
          ));
      return null;
    }
    return '剧情「${it.name}」不在库中，update 已跳过（防幻觉）';
  }

  Future<String?> _applyTimeline(
    String pid,
    ChapterUpdateItem it,
    String content,
  ) async {
    final List<TimelineEventRow> rows = await (_db.select(_db.timelineEvents)
          ..where((t) =>
              t.projectId.equals(pid) & notDeleted(t.isDeleted)))
        .get();
    final Iterable<TimelineEventRow> hits =
        rows.where((TimelineEventRow r) => r.title.trim() == it.name.trim());
    if (hits.isNotEmpty) {
      final TimelineEventRow hit = hits.first;
      await (_db.update(_db.timelineEvents)
            ..where((t) => t.id.equals(hit.id)))
          .write(TimelineEventsCompanion(
        description: it.field == 'description' || it.field == 'history'
            ? Value(_append(hit.description, content))
            : const Value.absent(),
      ));
      return null;
    }
    if (it.action == 'create') {
      await _db
          .into(_db.timelineEvents)
          .insert(TimelineEventsCompanion.insert(
            id: _newId(),
            projectId: pid,
            title: _clamp(it.name, 200),
            eventDate: DateTime.now(),
            category: const Value('剧情事件'),
            description: Value(content),
          ));
      return null;
    }
    return '时间线事件「${it.name}」不在库中，update 已跳过（防幻觉）';
  }

  /// 精确名匹配（trim 后相等）；返回命中首项。
  static T? _exactName<T>(List<T> rows, String name, String Function(T) keyOf) {
    final String n = name.trim();
    for (final T r in rows) {
      if (keyOf(r).trim() == n) return r;
    }
    return null;
  }

  static String _clamp(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
}

String _newId() => _uuid.v4();
