import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/utils/entity_update_text.dart';
import '../../ai/utils/fiction_quality.dart';
import '../../data/database.dart';
import 'chapter_sync_service.dart';
import 'writing_prompt_templates.dart';

/// A closed schema, not arbitrary SQL or arbitrary table access.
class ModuleContract {
  const ModuleContract(this.table, {
    this.nameColumn = 'name',
    this.historyColumn = 'notes',
    this.defaults = const {'type': 'AI'},
  });
  final TableInfo table;
  final String nameColumn;
  final String historyColumn;
  final Map<String, Object> defaults;

  Set<String> get columns => table.$columns.map((c) => c.$name).toSet();
  Map<String, String> get fields => {
    if (columns.contains('status')) 'status': 'status',
    if (columns.contains('description')) 'description': 'description',
    if (columns.contains('content')) 'content': 'content',
    if (columns.contains('notes')) 'notes': 'notes',
    'history': historyColumn,
  };
}

class ModuleStateService {
  ModuleStateService({required this.db, required this.provider, this.promptTemplates});
  final WritingPromptTemplates? promptTemplates;
  final AppDatabase db;
  final IModelProvider? Function() provider;

  /// 12 类分区的契约表。
  ///
  /// 抽成静态是为了让 `EntityProfileSynthesizer`（分卷档案归纳）复用**同一份**
  /// 定义：归纳要扫描的「哪些表、哪个名字列、哪个历史列」必须与抽取落库时的
  /// 完全一致，否则会出现「抽取写进了 A 列、归纳却去 B 列找流水」的静默错位。
  static Map<String, ModuleContract> contractsOf(AppDatabase db) => {
    'character': ModuleContract(db.characters, historyColumn: 'history'),
    'world': ModuleContract(db.worldSettings, historyColumn: 'history'),
    'faction': ModuleContract(db.factions, historyColumn: 'history'),
    'plot': ModuleContract(db.plots, nameColumn: 'title'),
    'race': ModuleContract(db.races),
    'resource': ModuleContract(db.resources),
    'realm': ModuleContract(db.secretRealms),
    'cultivation': ModuleContract(db.cultivationSystems),
    'political': ModuleContract(db.politicalSystems),
    'currency': ModuleContract(db.currencySystems, defaults: {'monetary_system': 'AI'}),
    'relationship': ModuleContract(db.relationshipNetworks, historyColumn: 'development_history'),
    'timeline': ModuleContract(db.timelineEvents, nameColumn: 'title',
      historyColumn: 'description', defaults: {}),
  };

  Map<String, ModuleContract> get contracts => contractsOf(db);

  String get template => jsonEncode({
    'input': {'chapterId': 'source chapter id', 'content': 'final prose',
      'existing': 'module -> exact entity names'},
    'output': {'updates': [
      {'target': 'character', 'action': 'create', 'name': 'exact name from prose',
        'field': 'history', 'content': 'observed change', 'evidence': 'exact quote from prose'}
    ]},
    'modules': {
      for (final e in contracts.entries)
        e.key: {'actions': ['create', 'update'], 'fields': e.value.fields.keys.toList()}
    },
  });

  static Map<String, dynamic>? parse(String raw) {
    // Scan balanced JSON objects without destroying quotes inside story text.
    for (var start = 0; start < raw.length; start++) {
      if (raw[start] != '{') continue;
      var depth = 0;
      var quoted = false;
      var escaped = false;
      for (var i = start; i < raw.length; i++) {
        final ch = raw[i];
        if (escaped) { escaped = false; continue; }
        if (ch == '\\' && quoted) { escaped = true; continue; }
        if (ch == '"') quoted = !quoted;
        if (quoted) continue;
        if (ch == '{') depth++;
        if (ch == '}') depth--;
        if (depth != 0) continue;
        try {
          final value = jsonDecode(raw.substring(start, i + 1));
          if (value is Map<String, dynamic> && value['updates'] is List) return value;
        } on FormatException { /* Try another balanced object. */ }
        break;
      }
    }
    return null;
  }

  Future<String?> extractAndApply(ChapterSyncInput input) async {
    final prompts = promptTemplates ?? WritingPromptTemplates.defaults();
    if (input.projectId.isEmpty) return null;
    final String whole = input.content.trim();
    // ⚠ 前置条件从「必须 status == 'Completed'」放宽为「正文非空且质量合格」。
    //
    // 用户实测（2026-10-09）：3 卷 30 章里有 3 章未通过质量闸、被存成 Draft，
    // 而旧判据让这 3 章**连尝试都没有** —— 它们的正文其实已经写出来了
    // （2395 / 2435 字），里面的设定变化完全应当登记。同时确认：
    // 正文为空（生成彻底失败）或质量不合格（复读/大纲污染）时抽取不可信，
    // 那时才跳过。
    if (whole.isEmpty) return null;
    if (FictionQuality.issue(whole) != null) return null;
    final p = provider();
    if (p == null || !p.isAvailable) return null;
    final existing = <String, List<String>>{};
    for (final e in contracts.entries) {
      final rows = await db.customSelect(
        'SELECT "${e.value.nameColumn}" FROM "${e.value.table.actualTableName}" '
        'WHERE project_id = ? AND is_deleted = 0',
        variables: [Variable(input.projectId)],
      ).get();
      existing[e.key] = rows.map((r) => r.read<String>(e.value.nameColumn)).toList();
    }
    final items = <Map<String, dynamic>>[];
    // 分段抽取失败**只跳过错块**，不再整章放弃。
    //
    // 旧实现是 `if (valid == null) return null;` —— 只要章内**任意**一个分段
    // 两次都没能把模型输出纠正成合法的 updates JSON（小模型长文下很常见），
    // 整章就一个设定也抽不到。用户观测到的「审核通过后人物/世界观毫无变化」
    // 有相当一部分就来自这里：失败是静默的，看起来像「Agent 没做这件事」。
    int failedChunks = 0;
    int okChunks = 0;
    // Cover the entire chapter, including state transitions at the ending.
    for (var start = 0; start < whole.length; start += 3000) {
      final chunk = whole.substring(start, (start + 3200).clamp(0, whole.length));
      String? error;
      List<Map<String, dynamic>>? valid;
      // 3 次机会（旧实现 2 次）—— 小模型的第一次输出经常是「解释 + 半截 JSON」，
      // 带错误回执重问一次的成功率明显更高。
      for (var attempt = 0; attempt < 3; attempt++) {
        final response = await p.chat(ChatRequest(
          systemPrompt: prompts.render('State/system', {}),
          messages: [ChatMessage.user(prompts.render('State/extract', {
            'schema': template, 'existing': jsonEncode(existing), 'title': input.title, 'chunk': chunk,
            'correction': error == null ? '' : '上次格式失败：$error。请重新按 updates JSON 模板输出，不要解释。',
          }))],
          temperature: .88,
          maxTokens: 2400,
        ));
        if (!response.isSuccess) return null;
        final parsed = parse(response.content);
        if (parsed == null) { error = 'missing updates array'; continue; }
        final raw = parsed['updates'] as List;
        if (raw.length > 30) { error = 'at most 30 updates per part'; continue; }
        valid = [];
        for (final item in raw) {
          if (item is! Map<String, dynamic>) {
            error = 'invalid target/field/name/evidence';
            valid = null;
            break;
          }
          // 先收敛长度与 evidence 形态再校验 —— 见 [_normalizeItem]。
          _normalizeItem(item);
          if (validate(item, whole) != null) {
            error = 'invalid target/field/name/evidence';
            valid = null;
            break;
          }
          valid!.add(item);
        }
        if (valid != null) break;
      }
      if (valid == null) {
        failedChunks++;
        continue;
      }
      okChunks++;
      items.addAll(valid);
    }
    // ⚠ 判据是「**没有任何一个分段成功**」，不能是 `items.isEmpty` ——
    // 模型合法地返回 `{"updates":[]}`（本章没有新设定）时 items 同样是空的，
    // 那是**成功且零更新**，必须照常回报「更新 0 项」，不能当成抽取失败。
    if (okChunks == 0) {
      // 严格 JSON 全线失败 → 换一套「每行一条、竖线分隔」的极简指令再问一次。
      //
      // 为什么有效：小模型对「嵌套 JSON + 12 类 existing 名单 + 3200 字正文」
      // 这个组合几乎必败（吐解释、吐半截 JSON、吐 Markdown 表格），
      // 但对「类别|名称|字段|一句话」这种登记表非常稳 —— 这也是用户实测里
      // 「人物/世界观一条都没更新」的直接补救。
      final List<Map<String, dynamic>> loose = await _extractLooseLines(
        p,
        input,
        whole,
      );
      if (loose.isEmpty) {
        return '$kAiExtractionFailurePrefix$failedChunks 个分段均未按 updates JSON 输出，'
            '行式兜底也未得到有效条目（章节《${input.title}》）';
      }
      items.addAll(loose);
    }
    // 同一实体同字段的多条更新先合并，避免档案被写成一串流水账
    final List<Map<String, dynamic>> merged = _mergeDuplicateItems(items);
    // 逐条校验已在收集阶段完成，这里仍走事务：任一条非法则整批回滚，
    // 绝不留下半成品（与原设计一致）。
    final count = await apply(input, merged);
    final String suffix = failedChunks == 0
        ? ''
        : '（$failedChunks 个分段未产出，其余照常写入）';
    return 'AI 设定同步：已核验 ${contracts.length} 类分区，更新 $count 项。$suffix';
  }

  /// 行式兜底抽取（见 [extractAndApply] 中的说明）。
  Future<List<Map<String, dynamic>>> _extractLooseLines(
    IModelProvider p,
    ChapterSyncInput input,
    String whole,
  ) async {
    const Map<String, String> targetLabels = <String, String>{
      '人物': 'character',
      '角色': 'character',
      '势力': 'faction',
      '组织': 'faction',
      '世界观': 'world',
      '设定': 'world',
      '剧情': 'plot',
      '情节': 'plot',
    };
    const Map<String, String> fieldLabels = <String, String>{
      '状态': 'status',
      '履历': 'history',
      '简介': 'description',
      '备注': 'notes',
      '内容': 'content',
    };
    try {
      final ChatResponse resp = await p.chat(
        ChatRequest(
          systemPrompt:
              '你是严谨的资料登记员。只输出「每行一条、竖线分隔」的登记表，'
              '禁止解释、禁止 JSON、禁止 Markdown 表格、禁止输出表头与分隔线。'
              '每行**必须以类别开头**，行首不要加 `|` 符号。',
          messages: <ChatMessage>[
            ChatMessage.user(
              '下面是小说章节《${input.title}》的正文。请列出本章中**发生了可登记变化**的条目。\n'
              '每行输出 4 段，用竖线 | 分隔：\n'
              '类别|名称|字段|一句话变化\n'
              '（直接以「类别」二字或具体类别开头，不要写成 Markdown 表格，'
              '不要行首的 | ，不要表头行，不要 |---|---| 分隔线）\n'
              '类别只能取：人物 / 势力 / 世界观 / 剧情\n'
              '字段只能取：状态 / 履历 / 简介 / 备注\n'
              '名称必须是正文里**原样出现过**的词；'
              '没有可登记的内容就只输出一行「无」。\n\n'
              '【正文】\n$whole',
            ),
          ],
          temperature: 0.4,
          maxTokens: 1600,
        ),
      );
      if (!resp.isSuccess) return const <Map<String, dynamic>>[];
      return _parseLooseLines(resp.content, whole, targetLabels, fieldLabels);
    } on Object {
      return const <Map<String, dynamic>>[];
    }
  }

  /// 解析行式登记表 → `updates` 条目（仍然过 [validate] 防幻觉）。
  List<Map<String, dynamic>> _parseLooseLines(
    String raw,
    String whole,
    Map<String, String> targetLabels,
    Map<String, String> fieldLabels,
  ) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final String lineRaw in raw.split(RegExp(r'\r?\n'))) {
      // ⚠ 用 [pipeRowCells] 而不是裸 `split('|')`：7B 几乎总会加 Markdown 表格
      // 外壳，行首那个 `|` 会切出空段 → `类别 = ''` → 整行被丢弃 → 兜底等于没跑。
      final List<String>? cells = pipeRowCells(lineRaw);
      if (cells == null || cells.length < 4) continue;
      final String? target = targetLabels[cells[0].trim()];
      final String name = cells[1].trim();
      if (target == null || name.isEmpty) continue;
      // 名称必须原样出现在正文里 —— 这条是防幻觉的关键闸门。
      if (name.length > 100 || !whole.contains(name)) continue;
      String value = cells.sublist(3).join('|').trim();
      if (value.isEmpty) continue;
      final ModuleContract contract = contracts[target]!;
      final String rawField = fieldLabels[cells[2].trim()] ?? 'history';
      final String field = contract.fields.containsKey(rawField)
          ? rawField
          : (contract.fields.containsKey('history') ? 'history' : 'notes');
      // status 列有 50 字上限（见 [validate]）。
      if (field == 'status' && value.length > 50) {
        value = value.substring(0, 50);
      }
      if (value.length > 1000) value = value.substring(0, 1000);
      // evidence：取名称在正文中的一段真实窗口（既是证据也满足 validate 的
      // 「evidence 含 name 且是正文子串」）。
      final int at = whole.indexOf(name);
      final String evidence = whole.substring(
        at,
        (at + 24).clamp(0, whole.length),
      );
      final Map<String, dynamic> item = <String, dynamic>{
        // 用 create：实体已存在时 [apply] 会走更新分支，不存在时新建，
        // 语义与「登记」一致。
        'target': target,
        'action': 'create',
        'name': name,
        'field': field,
        'content': value,
        'evidence': evidence,
      };
      if (validate(item, whole) != null) continue;
      out.add(item);
      if (out.length >= 60) break;
    }
    return out;
  }

  /// 合并「同 target + 同 name + 同 field」的多条更新。
  ///
  /// `status` 不合并（列宽上限 50，拼接必然超限，且状态取**最后一次**才有意义）；
  /// 其余文本字段用「；」连接后截到 1000 字。
  static List<Map<String, dynamic>> _mergeDuplicateItems(
    List<Map<String, dynamic>> items,
  ) {
    final Map<String, Map<String, dynamic>> byKey =
        <String, Map<String, dynamic>>{};
    final List<String> order = <String>[];
    for (final Map<String, dynamic> it in items) {
      final String name = (it['name'] as String).trim();
      final String field = (it['field'] as String).trim();
      final String key =
          '${it['target']}|${name.toLowerCase()}|$field';
      final Map<String, dynamic>? existing = byKey[key];
      if (existing == null) {
        byKey[key] = Map<String, dynamic>.of(it);
        order.add(key);
        continue;
      }
      if (field == 'status') {
        existing['content'] = it['content'];
        existing['evidence'] = it['evidence'];
        continue;
      }
      final String joined =
          '${existing['content']}；${it['content']}';
      existing['content'] =
          joined.length > 1000 ? joined.substring(0, 1000) : joined;
      if ((existing['evidence'] as String).length <
          (it['evidence'] as String).length) {
        existing['evidence'] = it['evidence'];
      }
    }
    return <Map<String, dynamic>>[for (final String k in order) byKey[k]!];
  }

  String? validate(Map<String, dynamic> item, String source) {
    final contract = contracts[item['target']];
    if (contract == null || !contract.fields.containsKey(item['field'])) return 'field';
    if (!['create', 'update'].contains(item['action'])) return 'action';
    for (final key in ['name', 'content', 'evidence']) {
      if (item[key] is! String || (item[key] as String).trim().isEmpty) return key;
    }
    final name = (item['name'] as String).trim();
    final evidence = stripEvidencePrefix(item['evidence'] as String);
    // ⚠ evidence 判据从 `source.contains(evidence)`（必须是**连续子串**）放宽为
    // 「分段有据」（见 [evidenceSharesText]）。7B 实测会把 evidence 写成拼接引用
    // 并带 `正文：` 前缀 → 旧判据条条必败 → 整章 0 条设定。
    // 防幻觉的真正闸门是 `source.contains(name)`：**实体名必须原样出现在正文**。
    if (name.length > 100 || !source.contains(name) || evidence.length < 4 ||
        !evidenceSharesText(evidence, source)) {
      return 'evidence';
    }
    if ((item['content'] as String).length > (item['field'] == 'status' ? 50 : 1000)) return 'length';
    if (FictionQuality.issue(item['content'] as String) != null) return 'content';
    return null;
  }

  /// 收敛模型给的 `content` / `evidence` —— 在 [validate] **之前**调用。
  ///
  /// * `content` 超列宽时**截断**而不是判非法：`status` 列宽 50，而 7B 对状态
  ///   几乎必给一整句话 —— 旧实现「超长即拒绝」意味着 status 更新**永远**
  ///   落不下来；状态本来就是「取最后一次」的短标记，截断更贴近预期。
  /// * `evidence` 脱掉 `正文：` 这类字段名前缀，再交给 [evidenceSharesText]。
  static void _normalizeItem(Map<String, dynamic> item) {
    final String field = (item['field'] ?? '').toString().trim();
    final Object? rawContent = item['content'];
    if (rawContent is String) {
      final int max = field == 'status' ? 50 : 1000;
      final String v = rawContent.trim();
      item['content'] = v.length > max ? v.substring(0, max) : v;
    }
    final Object? rawEvidence = item['evidence'];
    if (rawEvidence is String) {
      item['evidence'] = stripEvidencePrefix(rawEvidence);
    }
  }

  Future<int> apply(ChapterSyncInput input, List<Map<String, dynamic>> items) =>
      db.transaction(() async {
        var count = 0;
        for (final item in items) {
          final problem = validate(item, input.content);
          if (problem != null) throw FormatException('Invalid module update: $problem');
          final c = contracts[item['target']]!;
          final table = c.table.actualTableName;
          final name = (item['name'] as String).trim();
          final rows = await db.customSelect(
            'SELECT * FROM "$table" WHERE project_id = ? AND "${c.nameColumn}" = ? AND is_deleted = 0',
            variables: [Variable(input.projectId), Variable(name)],
          ).get();
          if (rows.length > 1) throw StateError('Ambiguous entity: $name');
          final field = c.fields[item['field']]!;
          final value = (item['content'] as String).trim();
          final entry = '[${input.chapterId}:${input.versionNumber} ${input.title}] $value';
          if (rows.isEmpty) {
            if (item['action'] != 'create') throw StateError('Missing entity: $name');
            final values = <String, Object>{
              'id': const Uuid().v4(), 'project_id': input.projectId,
              c.nameColumn: name, ...c.defaults,
              if (item['target'] == 'timeline') 'event_date': (input.eventDate ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
              field: value,
              c.historyColumn: entry,
            };
            await db.customInsert(
              'INSERT INTO "$table" (${values.keys.map((k) => '"$k"').join(',')}) '
              'VALUES (${List.filled(values.length, '?').join(',')})',
              variables: values.values.map((v) => Variable(v)).toList(),
              updates: {c.table},
            );
          } else {
            final row = rows.single;
            final history = (row.data[c.historyColumn] as String?) ?? '';
            if (history.split('\n').contains(entry)) continue;
            final values = <String, Object>{
              field: (item['field'] == 'history' || item['field'] == 'notes')
                  ? '${row.data[field] ?? ''}\n$entry'.trim() : value,
              c.historyColumn: '$history\n$entry'.trim(),
            };
            await db.customUpdate(
              'UPDATE "$table" SET ${values.keys.map((k) => '"$k" = ?').join(',')}, '
              'updated_at = unixepoch(), version = version + 1 WHERE id = ? AND project_id = ?',
              variables: [
                ...values.values.map((v) => Variable(v)),
                Variable(row.read<String>('id')), Variable(input.projectId),
              ],
              updates: {c.table},
            );
          }
          count++;
        }
        return count;
      });
}
