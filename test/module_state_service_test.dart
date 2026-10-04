import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/models/provider.dart';
import 'package:novelcraft/application/services/module_state_service.dart';
import 'package:novelcraft/application/services/chapter_sync_service.dart';
import 'package:novelcraft/data/database.dart';

class _Model implements IModelProvider {
  final requests = <ChatRequest>[];
  String Function(ChatRequest) answer = (_) => '{"updates":[]}';
  @override
  bool get isAvailable => true;
  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    requests.add(request);
    return ChatResponse(content: answer(request));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  late ModuleStateService service;
  late _Model model;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.projects).insert(ProjectsCompanion.insert(id: 'p', name: '书', type: '小说'));
    model = _Model();
    service = ModuleStateService(db: db, provider: () => model);
  });
  tearDown(() => db.close());
  ChapterSyncInput input(String source) => ChapterSyncInput(
    chapterId: 'chapter', volumeId: 'v', projectId: 'p', title: '门后',
    orderIndex: 1, content: source, status: 'Completed',
  );
  Map<String, dynamic> update(String target, String name) => {
    'target': target, 'action': 'create', 'name': name,
    'field': 'history', 'content': '$name出现在城中。', 'evidence': '$name出现在城中。',
  };
  test('all twelve contracts create records and append histories idempotently', () async {
    final items = [
      for (final target in service.contracts.keys) update(target, '实体$target'),
    ];
    final source = items.map((e) => e['evidence']).join('\n');
    expect(await service.apply(input(source), items), 12);
    expect(await service.apply(input(source), items), 0);
    for (final c in service.contracts.values) {
      final rows = await db.customSelect('SELECT * FROM "${c.table.actualTableName}"').get();
      expect(rows, hasLength(1));
      expect(rows.single.data[c.historyColumn], contains('[chapter:1 门后]'));
    }
  });
  test('wrong field, hallucinated evidence and cross-project rows are not changed', () async {
    final good = update('character', '林轩');
    await expectLater(service.apply(input('林轩出现在城中。'), [
      good, {...good, 'target': 'projects'},
    ]), throwsFormatException);
    await db.into(db.projects).insert(ProjectsCompanion.insert(id: 'other', name: '他书', type: '小说'));
    await db.into(db.characters).insert(CharactersCompanion.insert(
      id: 'foreign', name: '林轩', type: '主角', projectId: 'other'));
    await expectLater(service.apply(input('林轩出现在城中。'), [
      {...good, 'action': 'update'},
    ]), throwsStateError);
    expect((await db.select(db.characters).get()).single.history, isNull);
  });
  test('invalid batch rolls back earlier mutations', () async {
    final good = update('character', '林轩');
    await expectLater(service.apply(input('林轩出现在城中。'), [
      good, {...good, 'evidence': '虚构事件'},
    ]), throwsFormatException);
    expect(await db.select(db.characters).get(), isEmpty);
  });
  test('extracts entire chapter and repairs malformed JSON once', () async {
    model.answer = (_) => model.requests.length == 1
        ? '格式错误'
        : '```json\n${jsonEncode({'updates': []})}\n```';
    final source = '${String.fromCharCodes(List.generate(3400, (i) => 0x4e00 + i))}末尾新状态';
    expect(await service.extractAndApply(input(source)), contains('更新 0 项'));
    expect(model.requests.length, greaterThanOrEqualTo(3));
    expect(model.requests.last.messages.single.content, contains('末尾新状态'));
  });
  test('parse accepts wrappers but rejects arbitrary prose and missing schema', () {
    expect(ModuleStateService.parse('说明\n{"updates":[]}尾注'), isNotNull);
    expect(ModuleStateService.parse('{"foo":[]}'), isNull);
    expect(ModuleStateService.parse('不需要更新'), isNull);
  });
}
