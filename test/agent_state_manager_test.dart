// 智能体 state 分组管理测试：量化并发 / 激活分组 / 独享 state / 快照。
//
// 运行：flutter test test/agent_state_manager_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/agents/writer_personas.dart';
import 'package:novelcraft/ai/workflow/agent_state_manager.dart';

void main() {
  group('quantizeConcurrency（并发必须是 10 的倍数）', () {
    test('小于 10 抬到 10', () {
      expect(AgentStateManager.quantizeConcurrency(1), 10);
      expect(AgentStateManager.quantizeConcurrency(9), 10);
    });
    test('10 的倍数保持不变', () {
      expect(AgentStateManager.quantizeConcurrency(10), 10);
      expect(AgentStateManager.quantizeConcurrency(30), 30);
    });
    test('非 10 的倍数向下取整', () {
      expect(AgentStateManager.quantizeConcurrency(15), 10);
      expect(AgentStateManager.quantizeConcurrency(27), 20);
      expect(AgentStateManager.quantizeConcurrency(100), 100);
    });
    test('teamsForConcurrency 换算', () {
      expect(AgentStateManager.teamsForConcurrency(10), 1);
      expect(AgentStateManager.teamsForConcurrency(20), 2);
      expect(AgentStateManager.teamsForConcurrency(25), 2);
    });
  });

  group('activateGroup（1 组长 + 9 写手，state 独享）', () {
    test('分组恰好 10 个成员，组长在前写手按槽位排', () {
      final AgentStateManager m = AgentStateManager();
      final AgentStateGroup g = m.activateGroup(label: '测试团队');
      expect(g.members.length, 10);
      expect(g.leader, isNotNull);
      expect(g.leader!.isLeader, isTrue);
      expect(g.writers.length, 9);
      expect(
        g.writers.map((AgentStateEntry e) => e.slot).toList(),
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9],
      );
      // 写手必须绑定偏向人设
      for (final AgentStateEntry w in g.writers) {
        expect(w.personaId, personaForSlot(w.slot).id, reason: '${w.agentId} 偏向缺失');
      }
    });

    test('重复 groupId 抛错（防串组）', () {
      final AgentStateManager m = AgentStateManager();
      m.activateGroup(groupId: 'fixed');
      expect(() => m.activateGroup(groupId: 'fixed'), throwsStateError);
    });

    test('每个智能体 state 独享（互不串号）', () {
      final AgentStateManager m = AgentStateManager();
      final AgentStateGroup g = m.activateGroup();
      m.recordTurn(
        groupId: g.groupId,
        agentId: 'writer-1',
        userText: '写打斗段落',
        assistantText: '刀光一闪。',
      );
      m.recordTurn(
        groupId: g.groupId,
        agentId: 'leader',
        userText: '规划分工',
        assistantText: '按偏向分派。',
      );
      final AgentStateEntry w1 = m.stateOf(g.groupId, 'writer-1');
      final AgentStateEntry w2 = m.stateOf(g.groupId, 'writer-2');
      final AgentStateEntry ld = m.stateOf(g.groupId, 'leader');
      expect(w1.history.length, 2, reason: 'writer-1 自己的一轮对话');
      expect(w2.history, isEmpty, reason: 'writer-2 不应看到 writer-1 的消息');
      expect(ld.history.length, 2);
      expect(ld.turns, 1);
      expect(w1.status, AgentStateStatus.active);
      expect(ld.status, AgentStateStatus.active);
    });

    test('stateOf 不存在的组/成员快速抛错', () {
      final AgentStateManager m = AgentStateManager();
      expect(() => m.stateOf('nope', 'leader'), throwsStateError);
      final AgentStateGroup g = m.activateGroup();
      expect(() => m.stateOf(g.groupId, 'writer-99'), throwsStateError);
    });

    test('关闭组后 state 释放且不可再写', () {
      final AgentStateManager m = AgentStateManager();
      final AgentStateGroup g = m.activateGroup();
      m.recordTurn(groupId: g.groupId, agentId: 'leader', userText: 'a', assistantText: 'b');
      expect(m.closeGroup(g.groupId), isTrue);
      expect(m.closeGroup(g.groupId), isFalse);
      expect(g.active, isFalse);
      expect(m.stateOf(g.groupId, 'leader').history, isEmpty,
          reason: '关闭后消息日志必须清空释放');
      expect(
        () => m.recordTurn(
            groupId: g.groupId, agentId: 'leader', userText: 'a', assistantText: 'b'),
        throwsStateError,
      );
    });
  });

  group('snapshot（开发者诊断）', () {
    test('空管理器：全 0', () {
      final AgentStateManager m = AgentStateManager();
      final Map<String, Object?> s = m.snapshot();
      expect(s['activeGroups'], 0);
      expect(s['totalGroups'], 0);
      expect(s['activeStates'], 0);
      expect(s['groupSize'], 10);
    });

    test('激活两组后计数正确，关闭一组回落', () {
      final AgentStateManager m = AgentStateManager();
      final AgentStateGroup g1 = m.activateGroup();
      m.activateGroup();
      m.recordTurn(groupId: g1.groupId, agentId: 'writer-3', userText: 'u', assistantText: 'a');
      Map<String, Object?> s = m.snapshot();
      expect(s['activeGroups'], 2);
      expect(s['totalGroups'], 2);
      expect(s['activeStates'], 20);
      expect(s['totalTurns'], 1);
      expect((s['statusCounts'] as Map)['active'], 1);

      m.closeGroup(g1.groupId);
      s = m.snapshot();
      expect(s['activeGroups'], 1);
      expect(s['activeStates'], 10);
      expect((s['statusCounts'] as Map)['closed'], 10);
    });
  });
}
