// 反 AI 味叙事指南（StoryScope 论文落地）测试。
//
// 论文：arXiv:2604.03136v6 —— 61,608 篇平行语料证明话语层叙事结构
// （而非表面风格）即可 93.2% F1 区分人/AI。本测试守护其向项目
// 写作/编辑链的转化：指南常量、prompt 注入、AiFlavorCheck 能力。
//
// 运行：flutter test test/anti_ai_flavor_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:novelcraft/ai/agents/agents.dart';
import 'package:novelcraft/ai/utils/anti_ai_flavor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  group('反 AI 味指南常量', () {
    test('五戒齐全且各有出路', () {
      for (final String key in [
        '一戒点题说教',
        '二戒单线整洁',
        '三戒线性叙事',
        '四戒感官超写',
        '五戒和解模板',
      ]) {
        expect(kAntiAiFlavorGuidelines.contains(key), isTrue,
            reason: '指南缺「$key」');
      }
      // 每条都应给出正向出路（不止禁令）
      expect(
        kAntiAiFlavorGuidelines.contains('让读者从情节自行推断'),
        isTrue,
      );
      expect(kAntiAiFlavorGuidelines.contains('时间跳跃、闪回'), isTrue);
    });

    test('withAntiAiFlavorGuidelines 开关行为', () {
      const base = 'BASE';
      expect(withAntiAiFlavorGuidelines(base), contains(base));
      expect(withAntiAiFlavorGuidelines(base), contains('五戒'));
      expect(withAntiAiFlavorGuidelines(base, enabled: false), base);
    });
  });

  group('Agent 注入', () {
    final WriterAgent writer = WriterAgent(logger: Logger('t'));
    final EditorAgent editor = EditorAgent(logger: Logger('t'));

    test('Writer 三个写作任务都注入指南', () {
      for (final String t in [
        'GenerateChapterContent',
        'ContinueChapter',
        'PolishText',
      ]) {
        expect(writer.buildSystemPrompt(t).contains('五戒'), isTrue,
            reason: '任务 $t 应注入反 AI 味指南');
      }
      // 非写作任务不注入
      expect(
        writer.buildSystemPrompt('Unknown').contains('五戒'),
        isFalse,
      );
    });

    test('Editor 新增 AiFlavorCheck 能力与五维自检 prompt', () {
      final names = editor
          .supportedCapabilities()
          .map((c) => c.name)
          .toList(growable: false);
      expect(names, contains('AiFlavorCheck'));

      final prompt = editor.buildSystemPrompt('AiFlavorCheck');
      for (final String dim in [
        '主题显式',
        '因果过整洁',
        '时间过线性',
        '感官超写',
        '和解模板',
      ]) {
        expect(prompt.contains(dim), isTrue, reason: '五维缺「$dim」');
      }
    });

    test('Editor AiFlavorCheck 本地回退如实标注且五维齐全', () async {
      final r = await editor.executeTask('AiFlavorCheck', const {});
      expect(r.isSuccess, isTrue);
      expect(r.metadata['Fallback'], isTrue, reason: '无 AI 时如实标注回退');
      expect((r.data as String).contains('五维评分'), isTrue);
    });
  });
}
