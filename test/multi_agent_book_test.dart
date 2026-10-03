// 多智能体协同写书（纯逻辑部分）单元验证。
//
// 运行：flutter test test/multi_agent_book_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/application/services/multi_agent_book_generation_service.dart';

void main() {
  group('MultiAgentBookConfig.normalize', () {
    test('空书名/作者返回错误', () {
      expect(
        const MultiAgentBookConfig(bookTitle: '  ', authorName: 'a').normalize().error,
        isNotNull,
      );
      expect(
        const MultiAgentBookConfig(bookTitle: '书', authorName: '').normalize().error,
        isNotNull,
      );
    });

    test('数值越界被钳制（子智能体下限 10）', () {
      final MultiAgentBookConfig cfg = const MultiAgentBookConfig(
        bookTitle: '书',
        authorName: '作者',
        targetVolumes: 999,
        chaptersPerVolume: 0,
        subAgentCount: 3,
      ).normalize().normalized;
      expect(cfg.targetVolumes, 50);
      expect(cfg.chaptersPerVolume, 1);
      // 用户要求至少 10 个子智能体（1 组长 + 9 写手）
      expect(cfg.subAgentCount, 10);
      expect(cfg.writerCount, 9);
    });
  });

  group('parseSectionPlan', () {
    test('解析裸 JSON 数组', () {
      const String raw = '[{"agent":1,"title":"开局","brief":"主角登场",'
          '"boundary":"止于进城门前","wordTarget":400},'
          '{"agent":2,"title":"冲突","brief":"城门冲突","boundary":"止于夜宿","wordTarget":350}]';
      final List<SectionPlan> plans =
          MultiAgentBookGenerationService.parseSectionPlan(raw, expectedWriters: 2);
      expect(plans.length, 2);
      expect(plans.first.title, '开局');
      expect(plans.last.wordTarget, 350);
    });

    test('容忍 Markdown 围栏与前后杂文本', () {
      const String raw = '好的，以下是分工：\n```json\n'
          '[{"agent":1,"title":"a","brief":"b","boundary":"c","wordTarget":300}]\n'
          '```\n请查收。';
      final List<SectionPlan> plans =
          MultiAgentBookGenerationService.parseSectionPlan(raw, expectedWriters: 1);
      expect(plans.length, 1);
      expect(plans.single.brief, 'b');
    });

    test('坏 JSON / 缺字段返回空或跳过', () {
      expect(
        MultiAgentBookGenerationService.parseSectionPlan('不是 JSON', expectedWriters: 3),
        isEmpty,
      );
      expect(
        MultiAgentBookGenerationService.parseSectionPlan(
            '[{"title":"只有标题"},{"agent":2,"brief":"有内容"}]', expectedWriters: 2),
        hasLength(1),
        reason: 'brief 与 boundary 均空的项跳过',
      );
    });
  });

  group('fallbackPlan', () {
    test('均匀切分且覆盖全部写手、末段收尾', () {
      final List<SectionPlan> plans =
          MultiAgentBookGenerationService.fallbackPlan(writers: 9, targetWords: 2700);
      expect(plans.length, 9);
      expect(plans.first.wordTarget, 300);
      expect(plans.last.boundary, contains('钩子'));
    });
  });
}
