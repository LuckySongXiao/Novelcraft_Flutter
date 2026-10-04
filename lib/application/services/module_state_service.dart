import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
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

  Map<String, ModuleContract> get contracts => {
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
    if (input.projectId.isEmpty || input.status != 'Completed') return null;
    if (FictionQuality.issue(input.content) != null) return null;
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
    // Cover the entire chapter, including state transitions at the ending.
    for (var start = 0; start < input.content.length; start += 3000) {
      final chunk = input.content.substring(start, (start + 3200).clamp(0, input.content.length));
      String? error;
      List<Map<String, dynamic>>? valid;
      for (var attempt = 0; attempt < 2; attempt++) {
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
          if (item is! Map<String, dynamic> || validate(item, input.content) != null) {
            error = 'invalid target/field/name/evidence';
            valid = null;
            break;
          }
          valid!.add(item);
        }
        if (valid != null) break;
      }
      if (valid == null) return null;
      items.addAll(valid);
    }
    // No partial writes on parsing or validation failure.
    final count = await apply(input, items);
    return 'AI 设定同步：已核验 ${contracts.length} 类分区，更新 $count 项。';
  }

  String? validate(Map<String, dynamic> item, String source) {
    final contract = contracts[item['target']];
    if (contract == null || !contract.fields.containsKey(item['field'])) return 'field';
    if (!['create', 'update'].contains(item['action'])) return 'action';
    for (final key in ['name', 'content', 'evidence']) {
      if (item[key] is! String || (item[key] as String).trim().isEmpty) return key;
    }
    final name = (item['name'] as String).trim();
    final evidence = (item['evidence'] as String).trim();
    if (name.length > 100 || !source.contains(name) ||
        evidence.length < 4 || !source.contains(evidence) || !evidence.contains(name)) {
      return 'evidence';
    }
    if ((item['content'] as String).length > (item['field'] == 'status' ? 50 : 1000)) return 'length';
    if (FictionQuality.issue(item['content'] as String) != null) return 'content';
    return null;
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
