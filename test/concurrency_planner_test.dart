// 并发自动计算测试：分卷数 × 每卷章节数 + 预留团队数 + 档位。
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

  group('compute（高速模式：全部章节同时开工）', () {
    test('3 卷 × 10 章 = 30 团队全开，不设上限', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 3,
          chaptersPerVolume: 10,
          reservedTeams: 10,
          mode: MultiAgentSpeedMode.turbo,
        ),
        30,
        reason: '高速模式忽略预留团队数，并发 = 总章节数',
      );
    });

    test('预留团队数不影响高速模式', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 20,
          chaptersPerVolume: 50,
          reservedTeams: 10,
          mode: MultiAgentSpeedMode.turbo,
        ),
        1000,
      );
    });

    test('超绝对上限收口 9999', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 500,
          chaptersPerVolume: 200,
          reservedTeams: 0,
          mode: MultiAgentSpeedMode.turbo,
        ),
        ConcurrencyPlanner.kAbsoluteMaxTeams,
      );
    });
  });

  group('compute（普通模式：≤100 团队）', () {
    test('min(总章节数, 预留团队数)', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 3,
          chaptersPerVolume: 10,
          reservedTeams: 10,
          mode: MultiAgentSpeedMode.normal,
        ),
        10,
        reason: '3×10=30 章但只预留 10 个团队',
      );
    });

    test('预留团队 0（不限）→ 由 100 硬上限兜底', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 10,
          chaptersPerVolume: 30,
          reservedTeams: 0,
          mode: MultiAgentSpeedMode.normal,
        ),
        100,
      );
    });

    test('总章节数小于预留 → 取总章节数（不需要排队）', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 2,
          chaptersPerVolume: 5,
          reservedTeams: 100,
          mode: MultiAgentSpeedMode.normal,
        ),
        10,
        reason: '2×5=10 章，全部同时开工，无排队',
      );
    });

    test('预留超过 100 仍被硬上限压到 100', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 50,
          chaptersPerVolume: 20,
          reservedTeams: 300,
          mode: MultiAgentSpeedMode.normal,
        ),
        100,
      );
    });

    test('零章节兜底 1 团队', () {
      expect(
        ConcurrencyPlanner.compute(
          volumes: 0,
          chaptersPerVolume: 10,
          reservedTeams: 10,
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
      reservedTeams: 10,
      mode: MultiAgentSpeedMode.turbo,
    );
    expect(turbo, contains('高速模式'));
    expect(turbo, contains('并发 30'));

    final String normal = ConcurrencyPlanner.describe(
      volumes: 3,
      chaptersPerVolume: 10,
      reservedTeams: 10,
      mode: MultiAgentSpeedMode.normal,
    );
    expect(normal, contains('普通模式'));
    expect(normal, contains('并发 10'));
  });
}
