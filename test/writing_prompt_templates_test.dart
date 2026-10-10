import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/ai/prompts/prompt_template.dart';
import 'package:novelcraft/application/services/multi_agent_book_generation_service.dart';
import 'package:novelcraft/application/services/writing_prompt_catalog.dart';
import 'package:novelcraft/application/services/writing_prompt_templates.dart';
import 'package:novelcraft/core/di.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/volume_repository.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';
import 'package:novelcraft/ui/pages/writing_prompt_settings_page.dart';

class MemoryPromptStore implements KeyValueStore {
  String? raw;
  bool failWrites = false;
  @override
  Future<void> init() async {}
  @override
  Future<String?> readJson(String scope, String key) async => raw;
  @override
  Future<void> writeJson(String scope, String key, String json) async {
    if (failWrites) throw StateError('disk full');
    raw = json;
  }

  @override
  Future<void> remove(String scope, String key) async {
    raw = null;
  }

  @override
  Future<List<String>> listKeys(String scope) async => [];
}

void main() {
  test('全部内置节点变量一致，正文中的花括号不递归替换', () {
    final settings = WritingPromptTemplates.defaults();
    for (final stage in settings.stages) {
      expect(stage.validate(stage.defaultBody), isNull, reason: stage.id);
      final values = {for (final key in stage.variables.keys) key: '正文 {{保留}}'};
      final rendered = settings.render(stage.id, values);
      if (values.isNotEmpty) expect(rendered, contains('正文 {{保留}}'));
    }
  });

  test('多模板选择持久化、节点隔离、恢复默认、损坏配置回退', () async {
    final store = MemoryPromptStore();
    var settings = WritingPromptTemplates.defaults();
    final body = settings.stage('Book/mainOutline').defaultBody;
    settings = settings.withStage('Book/mainOutline', [
      WritingPromptVariant(id: 'fast', name: '精简', body: '$body\n少用形容词。'),
      WritingPromptVariant(id: 'slow', name: '细腻', body: '$body\n描写细腻。'),
    ], 'slow');
    await settings.save(store);
    final loaded = await WritingPromptTemplates.load(store, bookPromptStages);
    expect(loaded.variants['Book/mainOutline'], hasLength(2));
    expect(loaded.body('Book/mainOutline'), endsWith('描写细腻。'));
    expect(
      loaded.body('Book/volumeOutline'),
      settings.stage('Book/volumeOutline').defaultBody,
    );
    final reset = loaded.withStage(
      'Book/mainOutline',
      loaded.variants['Book/mainOutline']!,
      '',
    );
    expect(reset.body('Book/mainOutline'), body);
    expect(loaded.body('Book/mainOutline'), endsWith('描写细腻。'));
    store.raw = '{broken';
    final recovered = await WritingPromptTemplates.load(
      store,
      bookPromptStages,
    );
    // 字段名是 `loadFailed`（bool）；UI 侧 `writing_prompt_settings_page.dart`
    // 就是读它来提示「模板读取失败，已回退默认」。旧测试引用的 `loadWarning`
    // 早已不存在 —— 属于历史遗留的过期断言。
    expect(recovered.loadFailed, isTrue);
    expect(recovered.body('Book/mainOutline'), body);
    expect(store.raw, '{broken');
  });

  test('拒绝空模板、缺失变量、未知变量和不存在的选择', () {
    final settings = WritingPromptTemplates.defaults();
    final stage = settings.stage('Book/polish');
    expect(stage.validate(''), isNotNull);
    expect(stage.validate('没有上下文'), isNotNull);
    expect(stage.validate('{{chunk}} {{typo}}'), isNotNull);
    expect(stage.validate('{{chunk}} {{broken'), isNotNull);
    // 领域层不 import l10n：错误一律抛携带 `key + 中文兜底 + args` 的
    // `PromptTemplateException`，由 UI 侧用 L10n 渲染。旧的 `FormatException`
    // 断言是历史遗留（见 `writing_prompt_templates.dart` `withStage` 实现）。
    expect(
      () => settings.withStage(stage.id, [], 'missing'),
      throwsA(isA<PromptTemplateException>()),
    );
  });

  test('资源模板覆盖按语种隔离并保留旧变量语法', () {
    const stage = WritingPromptStage(
      id: 'Asset/Workflow/MainAgent.System/zh',
      title: '主编',
      defaultBody: '任务：{TaskName}',
      variables: {'TaskName': '任务名称'},
      asset: true,
    );
    final base = PromptTemplateRegistry({
      'Workflow/MainAgent.System/zh': stage.defaultBody,
      'Workflow/MainAgent.System/en': 'Task: {TaskName}',
    });
    final settings = WritingPromptTemplates(stages: [stage]).withStage(
      stage.id,
      [
        const WritingPromptVariant(
          id: 'custom',
          name: '定制',
          body: '新任务：{TaskName}',
        ),
      ],
      'custom',
    );
    expect(
      settings.overlay(base).get('Workflow/MainAgent.System', isEnglish: false),
      '新任务：{TaskName}',
    );
    expect(
      settings.overlay(base).get('Workflow/MainAgent.System', isEnglish: true),
      'Task: {TaskName}',
    );
  });

  test('生成服务实际发送选中模板及书籍变量', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var settings = WritingPromptTemplates.defaults();
    settings = settings.withStage('Book/mainOutline', [
      WritingPromptVariant(
        id: 'custom',
        name: '测试',
        body: '自定义生效\n${settings.body('Book/mainOutline')}',
      ),
    ], 'custom');
    String sent = '';
    final service = MultiAgentBookGenerationService(
      projects: ProjectRepository(db),
      plots: PlotRepository(db),
      volumes: VolumeRepository(db),
      chapters: ChapterRepository(db),
      writingProvider: () => null,
      promptTemplates: settings,
      chatExecutor:
          (
            system,
            messages, {
            required maxTokens,
            temperature = .85,
            String? sessionKey,
          }) async {
            sent = messages.last.content;
            return '';
          },
    );
    await service.generate(
      config: const MultiAgentBookConfig(
        bookTitle: '模板测试书',
        authorName: '作者甲',
        targetVolumes: 1,
        chaptersPerVolume: 1,
      ),
    );
    expect(sent, startsWith('自定义生效'));
    expect(sent, contains('模板测试书'));
    expect(sent, contains('作者甲'));
    expect(sent, isNot(contains('{{cfg_')));
  });

  test('保存失败不更改当前生效配置', () async {
    final store = MemoryPromptStore();
    final container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWith((ref) async => store),
        promptTemplatesProvider.overrideWith(
          (ref) async => const PromptTemplateRegistry.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final before = await container.read(writingPromptTemplatesProvider.future);
    store.failWrites = true;
    await expectLater(
      container.read(writingPromptTemplatesProvider.notifier).saveStage(
        'Book/polish',
        [
          const WritingPromptVariant(
            id: 'custom',
            name: '测试',
            body: '新要求 {{chunk}}',
          ),
        ],
        'custom',
      ),
      throwsStateError,
    );
    expect(
      container.read(writingPromptTemplatesProvider).requireValue,
      same(before),
    );
    expect(store.raw, isNull);
  });

  testWidgets('用户复制编辑保存模板后，重新打开仍保留选择与内容', (tester) async {
    final store = MemoryPromptStore();
    Widget app() => ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWith((ref) async => store),
        promptTemplatesProvider.overrideWith(
          (ref) async => const PromptTemplateRegistry.empty(),
        ),
      ],
      child: const MaterialApp(home: WritingPromptSettingsPage()),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('7B 审查员角色与输出格式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制为新模板'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '悬疑主编');
    await tester.enterText(find.byType(TextField).last, '你是悬疑小说主编，关注线索与伏笔。');
    await tester.tap(find.text('保存模板与选择'));
    await tester.pumpAndSettle();
    expect(store.raw, contains('悬疑主编'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('当前：悬疑主编'), findsOneWidget);
    await tester.tap(find.text('7B 审查员角色与输出格式'));
    await tester.pumpAndSettle();
    expect(find.text('你是悬疑小说主编，关注线索与伏笔。'), findsOneWidget);
  });
}
