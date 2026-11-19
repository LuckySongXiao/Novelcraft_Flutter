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
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk) onChunkReceived,
  ) async {
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
  ChapterSyncInput input(String source, {String status = 'Completed'}) =>
      ChapterSyncInput(
        chapterId: 'chapter', volumeId: 'v', projectId: 'p', title: '门后',
        orderIndex: 1, content: source, status: status,
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
    // 行式主路径整段失败 → 落到 JSON 次选；次选第一次格式错误、第二次纠正。
    var jsonCalls = 0;
    model.answer = (req) {
      if (req.messages.single.content.contains('类别|名称|字段')) {
        return '抱歉，我无法完成这个任务。';
      }
      jsonCalls++;
      return jsonCalls.isOdd
          ? '格式错误'
          : '```json\n${jsonEncode({'updates': []})}\n```';
    };
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

  // ---- A4：前置条件放宽（Draft 也抽取） ----
  test('draft chapter with valid prose is still mined', () async {
    model.answer = (_) => jsonEncode({
      'updates': [
        {
          'target': 'character', 'action': 'create', 'name': '林轩',
          'field': 'history', 'content': '林轩走出城门。', 'evidence': '林轩走出城门。',
        },
      ],
    });
    final String? note =
        await service.extractAndApply(input('林轩走出城门。', status: 'Draft'));
    expect(note, contains('更新 1 项'));
    expect((await db.select(db.characters).get()).single.name, '林轩');
  });

  test('empty prose is skipped without calling the model', () async {
    // 跳过原因要回传（旧实现返回 null，UI 只能显示「AI 抽取失败已跳过」）。
    expect(
      await service.extractAndApply(input('   ')),
      startsWith(kAiExtractionFailurePrefix),
    );
    expect(model.requests, isEmpty);
  });

  // ---- A3：行式登记表是主路径（小模型几乎必败于严格 JSON） ----
  test('line register is the primary path for local models', () async {
    model.answer = (req) {
      final String prompt = req.messages.single.content;
      if (prompt.contains('类别|名称|字段|一句话变化')) {
        return '人物|林轩|履历|林轩在城门口救下了沈砚。';
      }
      return '抱歉，我无法完成这个任务。';
    };
    final String? note = await service.extractAndApply(input('林轩在城门口救下了沈砚。'));
    expect(note, contains('更新 1 项'));
    final rows = await db.select(db.characters).get();
    expect(rows.single.name, '林轩');
    expect(rows.single.history, contains('林轩在城门口救下了沈砚。'));
  });

  test('markdown table shell and 「无」 are both handled', () async {
    model.answer = (_) =>
        '| 类别 | 名称 | 字段 | 一句话变化 |\n|---|---|---|---|\n'
        '| 人物 | 林轩 | 履历 | 林轩在城门口救下了沈砚。 |';
    expect(
      await service.extractAndApply(input('林轩在城门口救下了沈砚。')),
      contains('更新 1 项'),
    );
    model.answer = (_) => '无';
    final String? none = await service.extractAndApply(
      input('林轩在城门口救下了沈砚。', status: 'Draft'),
    );
    expect(none, contains('更新 0 项'));
    expect(none, isNot(startsWith(kAiExtractionFailurePrefix)));
  });

  test('failure prefix is returned when strict and loose both fail', () async {
    model.answer = (_) => '抱歉，我无法完成这个任务。';
    final String? note = await service.extractAndApply(input('林轩在城门口救下了沈砚。'));
    expect(note, startsWith(kAiExtractionFailurePrefix));
  });

  // ---- 防幻觉闸门：名称必须原样出现在正文里 ----
  test('line whose name never appears in prose is rejected without retrying',
      () async {
    model.answer = (req) {
      final String prompt = req.messages.single.content;
      if (prompt.contains('类别|名称|字段|一句话变化')) {
        return '人物|赵云|履历|赵云在城门口救下了沈砚。';
      }
      return '不该走到 JSON 次选';
    };
    final String? note = await service.extractAndApply(input('林轩在城门口救下了沈砚。'));
    expect(note, contains('更新 0 项'));
    expect(note, contains('未通过防幻觉校验'));
    expect(await db.select(db.characters).get(), isEmpty);
    // 登记表形状已经正确 → 不应再花几分钟走 JSON 次选。
    expect(model.requests, hasLength(1));
  });

  test('composite name 「皇帝（秦昭元）」 falls back to its base name', () async {
    model.answer = (_) => '人物|皇帝（秦昭元）|简介|皇帝身体虚弱。';
    final String? note =
        await service.extractAndApply(input('秦昭元坐在殿上，皇帝沉默不语。'));
    expect(note, contains('更新 1 项'));
    expect((await db.select(db.characters).get()).single.name, '皇帝');
  });

  // ---- 真机回归：流式逐块 sanitize 会把「只有换行」的 delta trim 掉 ----
  test('rows glued into one line by streaming are re-split', () async {
    model.answer = (_) =>
        '类别|名称|字段|一句话变化'
        '人物|林晚|状态|现代文职人员，被卷入古代纷争'
        '人物|秦昭元|状态|皇帝，身体虚弱但坚持守护'
        '势力|叛军|状态|集结镇魂玉碎片，意图破坏封印阵法';
    final String? note =
        await service.extractAndApply(input('林晚与秦昭元在殿前相遇，叛军正在集结。'));
    expect(note, contains('更新 3 项'));
    expect(
      (await db.select(db.characters).get()).map((e) => e.name).toSet(),
      {'林晚', '秦昭元'},
    );
    expect((await db.select(db.factions).get()).single.name, '叛军');
  });

  test('instruction echo is retried once, then treated as zero updates',
      () async {
    // 真机 3B 形态：把整段指令复述出来，一个数据行都没有。
    const echo = '类别|名称|字段|一句话变化（不要写成 Markdown表格，不要行首的| ，'
        '不要表头行，不要|---|---|分隔线）类别只能取：人物 /势力 /世界观/剧情'
        '字段只能取：状态 /履历 /简介 /备注';
    var calls = 0;
    model.answer = (_) {
      calls++;
      // 第一次回声；纠偏后给出正常登记行。
      return calls == 1 ? echo : '人物|林轩|履历|林轩在城门口救下了沈砚。';
    };
    final String? note =
        await service.extractAndApply(input('林轩在城门口救下了沈砚。'));
    expect(calls, 2, reason: '回声必须带纠偏重问一次');
    expect(note, contains('更新 1 项'));
  });

  test('分片互不重叠且切口对齐句末（同一段正文只送一次）', () async {
    final String source =
        List<String>.generate(600, (int i) => '第$i句正文内容大约十几个字。').join();
    model.answer = (_) => '无';
    final String? note = await service.extractAndApply(input(source));
    expect(note, contains('更新 0 项'));

    final List<String> chunks = model.requests
        .map((ChatRequest r) => r.messages.single.content)
        .map((String p) => p.split('【正文】\n').last)
        .toList();
    expect(chunks.length, greaterThan(3), reason: '长文必须切成多片');
    expect(
      chunks.join(),
      source,
      reason: '分片必须无缝拼接：既不重叠，也不丢字（旧实现步长 1100 会重复 21%）',
    );
    for (int i = 0; i < chunks.length - 1; i++) {
      expect(
        chunks[i].endsWith('。'),
        isTrue,
        reason: '第 ${i + 1} 片切口应回退到句末，避免把半句话交给模型',
      );
    }
  });
}
