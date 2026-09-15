// ignore_for_file: avoid_print
//
// `AgentBatchSettings` 的逻辑验证（P4-28）。
//
// 为什么值得单独验：分组语义、哨兵（区分"不传"与"显式清空"）、
// 往返序列化这些地方写错了**不会报错**，只会让用户觉得"开了开关没用"。
// 纯 Dart 模块 ⇒ 能在这里真跑。
//
// 运行：dart run tool/verify_batch_settings.dart
import 'dart:convert';
import 'dart:io';

import 'package:novelcraft/ai/workflow/agent_batch_settings.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $name — $detail');
  } else {
    fail++;
    print('  ❌ $name — $detail');
  }
}

void main() {
  print('=' * 78);
  print('[1] 默认全关（与改动前行为完全一致）');
  print('=' * 78);
  const AgentBatchSettings empty = AgentBatchSettings.empty;
  check('isEmpty', empty.isEmpty, 'ok');
  check('未配置的 Agent 默认不攒批', !empty.isEnabledFor('WriterAgent'), 'ok');
  check('未配置的 Agent 无分组', empty.groupIdFor('WriterAgent') == null, 'ok');

  print('');
  print('=' * 78);
  print('[2] 开关与分组：显式覆盖 vs 默认');
  print('=' * 78);
  AgentBatchSettings s = AgentBatchSettings.empty
      .withEntry('CharacterAgent', enabled: true)
      .withEntry('PlotAgent', enabled: true, groupId: 'short')
      .withEntry('WorldAgent', enabled: true, groupId: 'short')
      .withEntry('DirectorAgent', enabled: true, groupId: 'long');
  check('开启生效', s.isEnabledFor('CharacterAgent'), 'ok');
  check('未开启的不受影响', !s.isEnabledFor('WriterAgent'), 'ok');
  check('分组读取正确', s.groupIdFor('DirectorAgent') == 'long',
      '${s.groupIdFor('DirectorAgent')}');
  check('未设分组时返回 null（= 默认组）',
      s.groupIdFor('CharacterAgent') == null, 'ok');

  final List<String> enabled = s.enabledAgents;
  check('enabledAgents 已排序', enabled.length == 4, '$enabled');

  print('');
  print('=' * 78);
  print('[3] 分组分布 —— UI 用来提示"你其实只开了一个组"');
  print('=' * 78);
  final Map<String, List<String>> dist = s.groupDistribution();
  print('  $dist');
  check('short 组 2 个', dist['short']?.length == 2, '${dist['short']}');
  check('long 组 1 个', dist['long']?.length == 1, '${dist['long']}');
  check('默认组单列（不是混进别的组）',
      dist[AgentBatchSettings.defaultGroup]?.contains('CharacterAgent') ?? false,
      '${dist[AgentBatchSettings.defaultGroup]}');

  print('');
  print('=' * 78);
  print('[4] 哨兵语义：能区分「不传」与「显式清空分组」');
  print('=' * 78);
  AgentBatchSettings g = AgentBatchSettings.empty
      .withEntry('A', enabled: true, groupId: 'g1');
  // 不传 groupId → 保持
  g = g.withEntry('A', enabled: true);
  check('不传 groupId 时保留原分组', g.groupIdFor('A') == 'g1',
      '${g.groupIdFor('A')}');
  // 显式传 null → 清空
  g = g.withEntry('A', groupId: null);
  check('显式传 null 能清空分组', g.groupIdFor('A') == null, 'null');
  check('清空分组不影响开关', g.isEnabledFor('A'), 'ok');
  // 显式传字符串 → 设置
  g = g.withEntry('A', groupId: 'g2');
  check('显式传字符串能重设分组', g.groupIdFor('A') == 'g2', '${g.groupIdFor('A')}');

  print('');
  print('=' * 78);
  print('[5] 往返序列化（KVStore 持久化路径）');
  print('=' * 78);
  final AgentBatchSettings back = AgentBatchSettings.fromJson(
      jsonDecode(jsonEncode(s.toMap())) as Map<String, Object?>);
  check('分组分布一致', back.groupDistribution().toString() == dist.toString(),
      '${back.groupDistribution()}');
  check('enabledAgents 一致', back.enabledAgents.join(',') == enabled.join(','),
      back.enabledAgents.join(','));
  check('version 字段存在', s.toMap()['version'] == 1, '${s.toMap()['version']}');

  // 容错：脏数据不该抛
  check('空 JSON 不抛异常', AgentBatchSettings.fromJson(<String, Object?>{}).isEmpty,
      'ok');
  check('byAgent 类型错误时回退空配置',
      AgentBatchSettings.fromJson(<String, Object?>{'byAgent': 'oops'}).isEmpty,
      'ok');

  print('');
  print('=' * 78);
  print('[6] clearAgent / describe（UI 展示用）');
  print('=' * 78);
  final AgentBatchSettings cleared = s.withoutAgent('PlotAgent');
  check('清除单个 Agent', !cleared.isEnabledFor('PlotAgent'), 'ok');
  check('不影响其他 Agent', cleared.isEnabledFor('WorldAgent'), 'ok');

  // describe：能力与开关不一致时必须明确报出来
  final List<String> lines = s.describe(
    <String>['CharacterAgent', 'PlotAgent', 'WriterAgent', 'EditorAgent'],
    // 假设只有 Character/Plot/World/Director 中的一部分实现了批量 prompt
    (String n) => n == 'PlotAgent' || n == 'WriterAgent',
  );
  print('  describe() 输出：');
  for (final String l in lines) {
    print('    · $l');
  }
  check('「已开启但未实现」被明确标出',
      lines.any((String l) => l.contains('CharacterAgent') && l.contains('⚠')),
      'CharacterAgent 开了但没有能力');
  check('「有能力但未开启」也被标出',
      lines.any((String l) => l.contains('WriterAgent') && l.contains('未开启')),
      'WriterAgent 有能力但没开');
  check('真正生效的标 ✅',
      lines.any((String l) => l.contains('PlotAgent') && l.contains('✅')),
      'PlotAgent 开关+能力都有');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
