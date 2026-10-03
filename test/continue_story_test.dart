// 继续规划剧情并续写（纯解析逻辑）单元验证。
//
// 运行：flutter test test/continue_story_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/application/services/continue_story_service.dart';

void main() {
  group('parseContinuePlan', () {
    test('解析裸 JSON 决策', () {
      const String raw = '{"needNewVolume": true, "volumeName": "第三卷 风起云涌",'
          '"chapterTitle": "第十一章 故人重逢",'
          '"chapterOutline": "故人归来，旧怨重提……"}';
      final ContinueStoryPlan? plan = ContinueStoryService.parseContinuePlan(raw);
      expect(plan, isNotNull);
      expect(plan!.needNewVolume, isTrue);
      expect(plan.volumeName, '第三卷 风起云涌');
      expect(plan.chapterTitle, '第十一章 故人重逢');
    });

    test('容忍 Markdown 围栏与前后杂文本', () {
      const String raw = '决策如下：\n```json\n'
          '{"needNewVolume": false, "volumeName": "第一卷",'
          '"chapterTitle": "第五章 反击", "chapterOutline": "反击开始"}\n'
          '```\n以上。';
      final ContinueStoryPlan? plan = ContinueStoryService.parseContinuePlan(raw);
      expect(plan, isNotNull);
      expect(plan!.needNewVolume, isFalse);
      expect(plan.chapterTitle, '第五章 反击');
    });

    test('needNewVolume 字符串 "true" 也识别', () {
      const String raw =
          '{"needNewVolume": "true", "chapterTitle": "第二章", "chapterOutline": "x"}';
      expect(ContinueStoryService.parseContinuePlan(raw)!.needNewVolume, isTrue);
    });

    test('缺 chapterTitle / 坏 JSON 返回 null（走保守兜底）', () {
      expect(
        ContinueStoryService.parseContinuePlan(
            '{"needNewVolume": false, "chapterOutline": "x"}'),
        isNull,
      );
      expect(ContinueStoryService.parseContinuePlan('不是 JSON'), isNull);
    });
  });
}
