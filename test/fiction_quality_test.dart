import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/utils/fiction_quality.dart';
import 'package:novelcraft/application/services/selection_edit_service.dart';

void main() {
  test('rejects mid-chapter assistant prose and local language drift', () {
    expect(FictionQuality.issue('门缓缓打开。\n\n好，我将以不同的视角写一个完整的故事。'), 'assistant_text');
    expect(FictionQuality.issue('门缓缓打开。\n${List.filled(12, 'Somebody is somebody else.').join()}\n他回头。'),
        'language_drift');
    expect(FictionQuality.issue('“你是谁？”他问。“我是守门人。”来者回答。'), isNull);
  });
  test('rejects changing-word and substring loops', () {
    final loop = List.generate(40, (i) => '就像是一种规范$i——').join();
    expect(FictionQuality.issue('他笑了。$loop\n有人走近。'), 'repetition');
    expect(FictionQuality.issue(List.filled(40, '调式化的').join()), 'repetition');
  });
  test('retry does not carry corrupt output into next request', () async {
    final requests = <ChatRequest>[];
    final result = await FictionQuality.generate(
      prompt: '门前的故事',
      chat: (r) async {
        requests.add(r);
        return ChatResponse(content: requests.length == 1
            ? '好，我将为您写一段小说。'
            : '他推开锈蚀的铁门，看见父亲留下的那盏灯。');
      },
    );
    expect(requests, hasLength(2));
    expect(requests.last.messages.single.content, isNot(contains('为您')));
    expect(result, startsWith('他推开'));
  });
  test('two corrupt outputs fail closed', () async {
    var calls = 0;
    await expectLater(FictionQuality.generate(
      prompt: 'write',
      chat: (_) async {
        calls++;
        return ChatResponse(content: '好，我将为您写一段小说。');
      },
    ), throwsStateError);
    expect(calls, 2);
  });
  test('selection rewrite uses neighbors, not chapter ending', () {
    final prompt = SelectionEditService.buildPrompt(
      action: ChapterAiAction.polish,
      selected: 'INVALID',
      fullContent: '他推开门。INVALID父亲正站在门后。${List.filled(1500, '远').join()}章末。',
      instruction: '本段内容无效，需要重写',
    );
    expect(prompt, contains('选区是无效稿'));
    expect(prompt, contains('<before>他推开门。</before>'));
    expect(prompt, contains('<after>父亲正站在门后。'));
    expect(prompt, isNot(contains('章末。')));
  });
  test('stale and ambiguous selections are rejected', () {
    expect(() => SelectionEditService.buildPrompt(
      action: ChapterAiAction.rewrite, selected: 'missing', fullContent: 'abc',
    ), throwsStateError);
    expect(() => SelectionEditService.buildPrompt(
      action: ChapterAiAction.rewrite, selected: 'abc', fullContent: 'abc abc',
    ), throwsStateError);
  });
}
