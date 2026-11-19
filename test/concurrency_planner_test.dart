// 并发自动计算测试：分卷数 × 每卷章节数 + 并行章节上限 + 档位。
//
// 唯一工艺是「主笔分段串行」：每章 1 条串行管线，章与章之间并行。
//
// 运行：flutter test test/concurrency_planner_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/workflow/concurrency_planner.dart';

void main() {
  group('totalChapters', () {
    test('分卷数 × 每卷章节数', () {
      expect(ConcurrencyPlanner.totalChapters(3, 10), 30);
      expect(ConcurrencyPlanner.totalChapters(1, 1), 1);
    });
    test('负数兜底为 0', () {
      expect(ConcurrencyPlanner.totalChapters(-3, 10), 0);
      expect(ConcurrencyPlanner.totalChapters(3, -10), 0);
    });
  });

  group('recommendedParallelChapters（按模型规模取最佳并发）', () {
    test('3B → 6 条管线', () {
      expect(
        ConcurrencyPlanner.recommendedParallelChapters(
          'rwkv-g1m-3b-temp-6056-ctx65536.w8a16',
        ),
        6,
      );
    });
    test('1.5B → 8，7.2B → 3，13B → 2', () {
      expect(
        ConcurrencyPlanner.recommendedParallelChapters(
          'rwkv7-g1l-1.5b-20261031-ctx34304.pth',
        ),
        8,
      );
      expect(
        ConcurrencyPlanner.recommendedParallelChapters(
          'rwkv7-g1k-7.2b-20260930-ctx25600',
        ),
        3,
      );
      expect(
        ConcurrencyPlanner.recommendedParallelChapters('rwkv7-13b'),
        2,
      );
    });
    test('解析不到参数量 → 保守 4', () {
      expect(
        ConcurrencyPlanner.recommendedParallelChapters('my-custom-model'),
        ConcurrencyPlanner.kFallbackRecommendedPipelines,
      );
    });
    test('量化后缀里的数字不会被误判为参数量', () {
      expect(
        ConcurrencyPlanner.recommendedParallelChapters(
          'rwkv-g1m-3b-temp-6056-ctx65536.w8a16.rwkvq',
        ),
        6,
      );
    });
  });

  group('compute（高速模式：全部章节同时开工）', () {
    test('3 卷 × 10 章 = 30 条管线全开，不设上限', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 3,
          chaptersPerVolume: 10,
          maxParallelChapters: 10,
          mode: MultiAgentSpeedMode.turbo,
        ),
        30,
        reason: '高速模式忽略并行上限，并发 = 总章节数',
      );
    });

    test('超绝对上限收口 9999', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 500,
          chaptersPerVolume: 200,
          maxParallelChapters: 0,
          mode: MultiAgentSpeedMode.turbo,
        ),
        ConcurrencyPlanner.kAbsoluteMaxPipelines,
      );
    });
  });

  group('compute（普通模式：受并行章节上限约束）', () {
    test('min(总章节数, 并行章节上限)', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 3,
          chaptersPerVolume: 10,
          maxParallelChapters: 10,
          mode: MultiAgentSpeedMode.normal,
        ),
        10,
        reason: '3×10=30 章但只允许 10 条管线并行',
      );
    });

    test('上限 0 → 按模型规模自动推荐（3B → 6）', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 10,
          chaptersPerVolume: 30,
          maxParallelChapters: 0,
          mode: MultiAgentSpeedMode.normal,
          modelName: 'rwkv-g1m-3b-temp-6056-ctx65536.w8a16',
        ),
        6,
      );
    });

    test('总章节数小于上限 → 取总章节数（不需要排队）', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 2,
          chaptersPerVolume: 5,
          maxParallelChapters: 100,
          mode: MultiAgentSpeedMode.normal,
        ),
        10,
        reason: '2×5=10 章，全部同时开工，无排队',
      );
    });

    test('上限超过 100 仍被硬上限压到 100', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 50,
          chaptersPerVolume: 20,
          maxParallelChapters: 300,
          mode: MultiAgentSpeedMode.normal,
        ),
        100,
      );
    });

    test('零章节兜底 1 条管线', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 0,
          chaptersPerVolume: 10,
          maxParallelChapters: 10,
          mode: MultiAgentSpeedMode.normal,
        ),
        1,
      );
    });
  });

  test('describe 输出公式与结果（UI 展示）', () {
    final String turbo = ConcurrencyPlanner.describe(
      volumes: 3,
      chaptersPerVolume: 10,
      maxParallelChapters: 10,
      mode: MultiAgentSpeedMode.turbo,
      modelName: 'rwkv-g1m-3b-temp-6056-ctx65536.w8a16',
    );
    expect(turbo, contains('高速模式'));
    expect(turbo, contains('并发 30'));
    expect(turbo, contains('单章内严格串行'));

    final String normal = ConcurrencyPlanner.describe(
      volumes: 3,
      chaptersPerVolume: 10,
      maxParallelChapters: 0,
      mode: MultiAgentSpeedMode.normal,
      modelName: 'rwkv-g1m-3b-temp-6056-ctx65536.w8a16',
    );
    expect(normal, contains('普通模式'));
    expect(normal, contains('自动推荐 6'));
    expect(normal, contains('并发 6'));
  });
}
