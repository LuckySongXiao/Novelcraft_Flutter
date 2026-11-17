import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/utils/fiction_quality.dart';
import 'package:novelcraft/application/services/selection_edit_service.dart';

void main() {
  test('scrubArtifacts filters repeated-format invalid text', () {
    // 内联大纲标题 + 字数注记（3B 真机形态）
    expect(
      FictionQuality.scrubArtifacts('他仿佛被抛入另一个世界。##唐朝初年·长安城西郊废弃佛寺（约1000字）清晨五点半，阳光洒进房间。'),
      '他仿佛被抛入另一个世界。清晨五点半，阳光洒进房间。',
    );
    // 整行章名 / 标题
    expect(
      FictionQuality.scrubArtifacts('># 第一章：龙鳞低语\n陈默从瓦砾中爬起来。'),
      '陈默从瓦砾中爬起来。',
    );
    // 提示词回声行（1B 真机形态）
    expect(
      FictionQuality.scrubArtifacts('我是《后宫加一实力加一》的正文小说主笔，以下是第一卷全文：---\n凌晨两点十七分，她醒了。'),
      '凌晨两点十七分，她醒了。',
    );
    // 行内模板标记：从标记处丢到行尾（标记之后是另一回合的模板）
    expect(
      FictionQuality.scrubArtifacts('她说。Assistant:【后宫加一实力加一】---\n他走了。'),
      '她说。\n他走了。',
    );
    // 整书实测：大纲块整行丢弃，正文接缝不留残渣
    expect(
      FictionQuality.scrubArtifacts(
        '林枫知道战斗才开始。\n【本章大纲】-起点：断魂村遇袭。\n-转折：苏雨晴出现。\n'
        '-高潮：两人对决。\n###【本章正文】林枫睁开眼睛，周围景象骤然变化。',
      ),
      '林枫知道战斗才开始。\n\n林枫睁开眼睛，周围景象骤然变化。',
    );
    // 行内大纲块（`##本段目标…` 全在一行）
    expect(
      FictionQuality.scrubArtifacts(
        '黑色泥土翻涌如潮水。\n【本章大纲】第三章：命运丝线##本段目标林枫学会控制。##出场人物-林枫（主角）\n林枫抬头。',
      ),
      '黑色泥土翻涌如潮水。\n\n林枫抬头。',
    );
    // 行内标签只摘标签、保留句子；正文字彩不误删
    expect(
      FictionQuality.scrubArtifacts('【本段内容】荒野上风卷着枯叶。【轰隆！】大地震动。'),
      '荒野上风卷着枯叶。【轰隆！】大地震动。',
    );
    // 章末注记
    expect(
      FictionQuality.scrubArtifacts('他拔腿狂奔。\n（本章目标：1.揭示真相；2.引入反派）'),
      '他拔腿狂奔。',
    );
    // 正常正文一律不动
    const String prose = '他推开门。外面下雨了，雨点打在青石板上。';
    expect(FictionQuality.scrubArtifacts(prose), prose);
  });

  test('rejects prompt echo and outline markers', () {
    // 1B 真机样本：把任务说明当成正文写出来。
    expect(
      FictionQuality.issue('我是《后宫加一实力加一》的正文小说主笔，以下是第一卷全文：---'),
      'assistant_text',
    );
    expect(
      FictionQuality.issue('慕容雪之死留下悬念。Assistant:【后宫加一实力加一】---'),
      'assistant_text',
    );
    // 3B 真机样本：大纲原文（含 Markdown 标题与字数注记）被抄进正文。
    expect(
      FictionQuality.issue('她仿佛被抛入了另一个世界。##唐朝初年·长安城西郊废弃佛寺（约1000字）清晨五点半，'),
      'outline_leak',
    );
    expect(FictionQuality.issue('># 第一章：龙鳞低语，废墟中苏醒'), 'outline_leak');
    // 正常正文不应误伤（破折号、书名号、普通井号前缀都没有）。
    expect(
      FictionQuality.issue('“你是谁？”他问。“我是守门人。”来者回答。本章约三千字。'),
      isNull,
    );
  });
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
