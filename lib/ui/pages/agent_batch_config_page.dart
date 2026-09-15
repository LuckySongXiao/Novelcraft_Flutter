// Agent 攒批配置页（P4-28）。
//
// 解决 HANDOFF §28 的具体场景：用户想让一部分 Agent 攒批、另一部分独立请求。
// 最典型的理由 —— **Director 的 prompt 特别长，跟短 prompt 混在一批里会把
// 整批的首 token 时间都拖到跟它一样**（攒批是同批同速的）。所以长任务单独成组。
//
// ⚠ 本页最重要的一处设计：**「支持攒批」是能力，不是开关。**
//   唯一判定依据是 `BaseAgent.buildPromptForBatch()` 是否返回非 null。
//   默认返回 null，因为批量路由**无状态**（不带 state 续跑），prompt 必须自包含；
//   拿"拍平参数"的兜底文本去攒批只会**静默降质**。
//   所以本页对「已开启但未实现」的 Agent 会打**醒目警告**，而不是假装它生效了。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/agents/agent.dart';
import '../../ai/workflow/agent_batch_settings.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

class AgentBatchConfigPage extends ConsumerStatefulWidget {
  const AgentBatchConfigPage({super.key});

  @override
  ConsumerState<AgentBatchConfigPage> createState() =>
      _AgentBatchConfigPageState();
}

class _AgentBatchConfigPageState extends ConsumerState<AgentBatchConfigPage> {
  final Map<String, TextEditingController> _groupCtrls =
      <String, TextEditingController>{};

  @override
  void dispose() {
    for (final TextEditingController c in _groupCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrl(String agentName) => _groupCtrls.putIfAbsent(
      agentName,
      () => TextEditingController(
          text: ref.read(agentBatchSettingsProvider).groupIdFor(agentName) ?? ''));

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AgentBatchSettings settings = ref.watch(agentBatchSettingsProvider);
    final List<BaseAgent> agents = ref.watch(allAgentsProvider);

    // 能力判定：与引擎/执行器**同一依据**，所以不会出现"开关开了但没效果"
    bool supportsBatch(BaseAgent a) =>
        a.buildPromptForBatch(_sampleTaskType(a), <String, dynamic>{}) != null;

    final Map<String, List<String>> dist = settings.groupDistribution();
    final List<String> misconfigured = <String>[
      for (final BaseAgent a in agents)
        if (settings.isEnabledFor(a.name) && !supportsBatch(a)) a.name,
    ];
    final List<String> capable = <String>[
      for (final BaseAgent a in agents)
        if (supportsBatch(a)) a.name,
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('ABatch.Title', 'Agent 攒批配置'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeCard(l10n, scheme, dist, misconfigured, capable),
          const SizedBox(height: 14),
          ...agents.map((BaseAgent a) => _agentTile(
                context,
                l10n,
                scheme,
                settings,
                a,
                supportsBatch(a),
                dist,
              )),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  /// 取一个该 Agent 支持的任务类型做能力探测（`buildPromptForBatch` 是纯函数，
  /// 只看它认不认这个 taskType + 有没有提供 batchPrompt）。
  String _sampleTaskType(BaseAgent a) => a.supportedCapabilities().isNotEmpty
      ? a.supportedCapabilities().first.name
      : 'default';

  Widget _noticeCard(
    L10n l10n,
    ColorScheme scheme,
    Map<String, List<String>> dist,
    List<String> misconfigured,
    List<String> capable,
  ) {
    final int effective = dist.entries
        .where((MapEntry<String, List<String>> e) =>
            e.key != AgentBatchSettings.defaultGroup)
        .fold<int>(0, (int s, MapEntry<String, List<String>> e) => s + e.value.length);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.t('ABatch.Intro', '攒批与分组'),
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            l10n.t('ABatch.IntroBody',
                '同一分组内的 Agent 才会合进一次批量请求。攒批是同批同速的——'
                '把长 prompt 和短 prompt 混在一批，整批的首 token 时间都会被拉长，'
                '所以建议给长任务单独设一个组。'),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            '${l10n.t('ABatch.Groups', '当前分组')}：'
            '${dist.isEmpty ? l10n.t('ABatch.NoGroups', '（未开启任何 Agent）') : dist.entries.map((MapEntry<String, List<String>> e) => '${e.key == AgentBatchSettings.defaultGroup ? l10n.t('ABatch.DefaultGroup', '默认') : e.key}(${e.value.length})').join('  ')}',
            style: const TextStyle(fontSize: 12),
          ),
          if (capable.isEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              l10n.t('ABatch.NoCapable',
                  '⚠ 当前没有任何 Agent 实现了 buildPromptForBatch，'
                  '因此攒批不会生效（这是刻意的：批量路由无状态，'
                  'prompt 必须自包含，否则会静默降质）。'),
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ] else if (misconfigured.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '${l10n.t('ABatch.Misconfigured', '⚠ 以下 Agent 已开启攒批但未实现批量 prompt，实际不会生效')}：'
              '${misconfigured.join(', ')}',
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ],
          if (effective == 0 && dist.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              l10n.t('ABatch.AllDefaultGroup',
                  '提示：所有已开启的 Agent 都在「默认」组，等于没分组——'
                  '若其中有特别长的任务，建议单独分一组。'),
              style: TextStyle(fontSize: 12, color: scheme.tertiary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _agentTile(
    BuildContext context,
    L10n l10n,
    ColorScheme scheme,
    AgentBatchSettings settings,
    BaseAgent a,
    bool capable,
    Map<String, List<String>> dist,
  ) {
    final bool enabled = settings.isEnabledFor(a.name);
    final bool inconsistent = enabled && !capable;
    final List<String> existingGroups = dist.keys
        .where((String g) => g != AgentBatchSettings.defaultGroup)
        .toList()
      ..sort();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: inconsistent ? scheme.error : scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: (bool v) => ref
                  .read(agentBatchSettingsProvider.notifier)
                  .update(a.name, enabled: v),
              title: Text(a.name, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                capable
                    ? l10n.t('ABatch.Capable', '已实现批量 prompt，可用于攒批')
                    : l10n.t('ABatch.NotCapable',
                        '未实现 buildPromptForBatch —— 攒批不会生效（会走单路）'),
                style: TextStyle(
                    fontSize: 11,
                    color: capable ? scheme.onSurfaceVariant : scheme.error),
              ),
            ),
            if (enabled && capable)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 120,
                      child: Text(l10n.t('ABatch.Group', '分组'),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _ctrl(a.name),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: l10n.t('ABatch.GroupHint',
                              '留空 = 默认组；长 prompt 建议独立分组'),
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (String v) => ref
                            .read(agentBatchSettingsProvider.notifier)
                            .update(a.name,
                                groupId: v.trim().isEmpty ? null : v.trim()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: l10n.t('Common.Save', '保存'),
                      icon: const Icon(Icons.check, size: 18),
                      onPressed: () {
                        final String v = _ctrl(a.name).text.trim();
                        ref
                            .read(agentBatchSettingsProvider.notifier)
                            .update(a.name,
                                groupId: v.isEmpty ? null : v);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(l10n.t('Common.Saved', '已保存'))));
                      },
                    ),
                  ],
                ),
              ),
            if (existingGroups.isNotEmpty && enabled && capable)
              Padding(
                padding: const EdgeInsets.only(left: 120, top: 6),
                child: Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final String g in existingGroups)
                      ActionChip(
                        label: Text(g, style: const TextStyle(fontSize: 11)),
                        onPressed: () {
                          _ctrl(a.name).text = g;
                          ref
                              .read(agentBatchSettingsProvider.notifier)
                              .update(a.name, groupId: g);
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
