// 分派规划器验证（dispatch_planner.dart，纯 Dart 逻辑 + 假 KVStore）—— 主 Agent 分派决策。
//
// 运行：flutter test test/dispatch_planner_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/workflow/dispatch_planner.dart';

void main() {
  late Map<String, Map<String, String>> store;
  late WorkflowDispatchPlanner planner;

  void buildPlanner({
    Future<int?> Function()? probe,
    int fallback = 16,
    Future<String?> Function(String prompt)? askMainAgent,
  }) {
    planner = WorkflowDispatchPlanner(
      readJson: (scope, key) async => store[scope]?[key],
      writeJson: (scope, key, json) async =>
          (store[scope] ??= <String, String>{})[key] = json,
      probe: probe ?? (() async => 167),
      configuredFallback: () => fallback,
      askMainAgent: askMainAgent,
    );
  }

  setUp(() {
    store = <String, Map<String, String>>{};
  });

  group('parseDispatchDecision', () {
    test('纯整数 / 带说明文字 / 非法输入', () {
      expect(planner2.parseDispatchDecision('3'), 3);
      expect(planner2.parseDispatchDecision('我决定分派 12 个'), 12);
      expect(planner2.parseDispatchDecision('abc'), isNull);
      expect(planner2.parseDispatchDecision(null), isNull);
      expect(planner2.parseDispatchDecision(''), isNull);
    });
  });

  group('decide（探测 + 主 Agent 决策 clamp）', () {
    test('主 Agent 未装配 → 用满探测值，并持久化到 KVStore', () async {
      buildPlanner();
      final DispatchPlan plan = await planner.decide(
        workflowName: '测试流',
        taskCount: 6,
        parallelizable: 4,
      );
      expect(plan.probedMax, 167);
      expect(plan.source, 'server');
      expect(plan.mainAgentDecision, 0);
      expect(plan.effective, 167);
      expect(
        store[WorkflowDispatchPlanner.scope]?[WorkflowDispatchPlanner.key],
        isNotNull,
        reason: '探测结果必须落 KVStore',
      );
      final DispatchPlan? persisted = await planner.lastPlan();
      expect(persisted?.probedMax, 167);
    });

    test('主 Agent 表态 3 → 生效 3', () async {
      buildPlanner(askMainAgent: (_) async => '3');
      final DispatchPlan plan = await planner.decide(
        workflowName: '测试流',
        taskCount: 6,
        parallelizable: 4,
      );
      expect(plan.mainAgentDecision, 3);
      expect(plan.effective, 3);
    });

    test('主 Agent 超报（999 > 探测 167）→ clamp 到 167', () async {
      buildPlanner(askMainAgent: (_) async => '999');
      final DispatchPlan plan = await planner.decide(
        workflowName: '测试流',
        taskCount: 6,
        parallelizable: 4,
      );
      expect(plan.effective, 167);
    });

    test('主 Agent 回复非整数 → 未表态，用满探测值', () async {
      buildPlanner(askMainAgent: (_) async => '我觉得还行');
      final DispatchPlan plan = await planner.decide(
        workflowName: '测试流',
        taskCount: 6,
        parallelizable: 4,
      );
      expect(plan.mainAgentDecision, 0);
      expect(plan.effective, 167);
    });

    test('探测失败 → 回退本地配置值（16）', () async {
      buildPlanner(probe: () async => null);
      final DispatchPlan plan = await planner.decide(
        workflowName: '测试流',
        taskCount: 6,
        parallelizable: 4,
      );
      expect(plan.probedMax, 16);
      expect(plan.source, 'config');
      expect(plan.effective, 16);
    });

    test('决策 > 回退值（例如回退 4，主 Agent 要 8）→ clamp 到 4', () async {
      buildPlanner(
        probe: () async => null,
        fallback: 4,
        askMainAgent: (_) async => '8',
      );
      final DispatchPlan plan = await planner.decide(
        workflowName: '测试流',
        taskCount: 6,
        parallelizable: 4,
      );
      expect(plan.effective, 4);
    });
  });
}

// 复用顶层 planner 实例做纯函数断言（parseDispatchDecision 不依赖状态）
final WorkflowDispatchPlanner planner2 = WorkflowDispatchPlanner(
  readJson: (_, _) async => null,
  writeJson: (_, _, _) async {},
  probe: () async => null,
  configuredFallback: () => 16,
);
