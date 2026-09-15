import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../data/database.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';

enum HealthCheckMode { consistency, quality, all }

String severityFor(String v, bool isEnglish) => switch (v) {
      '错误' => isEnglish ? 'Error' : '错误',
      '警告' => isEnglish ? 'Warning' : '警告',
      '提示' => isEnglish ? 'Info' : '提示',
      _ => v,
    };

String categoryFor(String v, bool isEnglish) => switch (v) {
      '角色档案' => isEnglish ? 'Character Profile' : '角色档案',
      '人物关系' => isEnglish ? 'Character Relations' : '人物关系',
      '剧情大纲' => isEnglish ? 'Plot Outline' : '剧情大纲',
      '势力组织' => isEnglish ? 'Factions' : '势力组织',
      '世界设定' => isEnglish ? 'World Setting' : '世界设定',
      '章节正文' => isEnglish ? 'Chapter Content' : '章节正文',
      '时间线' => isEnglish ? 'Timeline' : '时间线',
      'AI 一致性检查' =>
        isEnglish ? 'AI Consistency Check' : 'AI 一致性检查',
      _ => v,
    };

String _navTargetName(NavigationTarget t, bool isEnglish) => switch (t) {
      NavigationTarget.characterManagement =>
        isEnglish ? 'Character Management' : '角色管理',
      NavigationTarget.characterRelationshipManagement =>
        isEnglish ? 'Relation Graph' : '关系网络',
      NavigationTarget.timeline =>
        isEnglish ? 'Timeline Management' : '时间线管理',
      NavigationTarget.factionManagement =>
        isEnglish ? 'Faction Management' : '势力管理',
      NavigationTarget.plotManagement =>
        isEnglish ? 'Plot Management' : '剧情管理',
      NavigationTarget.worldSettingManagement =>
        isEnglish ? 'World Setting Management' : '世界设定管理',
      NavigationTarget.volumeManagement =>
        isEnglish ? 'Volume & Chapter Management' : '卷章管理',
      _ => t.name,
    };

class _HealthIssue {
  final String id;
  final String severity;
  final String category;
  final String description;
  final String detail;
  final String? targetType;
  final String? targetName;
  final String? targetId;

  _HealthIssue({
    required this.id,
    required this.severity,
    required this.category,
    required this.description,
    required this.detail,
    this.targetType,
    this.targetName,
    this.targetId,
  });
}

class ProjectHealthCheckPage extends ConsumerStatefulWidget {
  const ProjectHealthCheckPage({super.key});

  @override
  ConsumerState<ProjectHealthCheckPage> createState() => _ProjectHealthCheckPageState();
}

class _ProjectHealthCheckPageState extends ConsumerState<ProjectHealthCheckPage> {
  bool _isChecking = false;
  DateTime? _lastCheckAt;
  HealthCheckMode _lastMode = HealthCheckMode.all;
  final List<_HealthIssue> _issues = [];
  String? _selectedId;
  bool _aiRunning = false;

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isEnglish = l10n.isEnglish;
    final projectId = ref.watch(currentProjectIdProvider);
    final projectName = projectId == null ? null : l10n.t('HC.CurrentProjectLabel', '当前项目');
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      l10n.t('HC.Title', '项目健康检查'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Spacer(),
                    Tooltip(
                      message: l10n.t('HC.ConsistencyCheckTooltip', '一致性检查'),
                      child: FilledButton.tonalIcon(
                        onPressed: _isChecking
                            ? null
                            : () => _run(HealthCheckMode.consistency),
                        icon: const Icon(Icons.verified_user_outlined),
                        label: Text(l10n.t('HC.ConsistencyCheck', '一致性检查')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: l10n.t('HC.QualityCheckTooltip', '质量检查'),
                      child: FilledButton.tonalIcon(
                        onPressed: _isChecking
                            ? null
                            : () => _run(HealthCheckMode.quality),
                        icon: const Icon(Icons.grade_outlined),
                        label: Text(l10n.t('HC.QualityCheck', '质量检查')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: l10n.t('HC.FullCheckTooltip', '全量检查'),
                      child: FilledButton.icon(
                        onPressed: _isChecking ? null : () => _run(HealthCheckMode.all),
                        icon: const Icon(Icons.health_and_safety),
                        label: Text(l10n.t('HC.FullCheck', '全量检查')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _isChecking ? null : () => _run(_lastMode),
                      icon: const Icon(Icons.refresh),
                      tooltip: l10n.t('HC.Recheck', '再次检查'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  projectId == null
                      ? l10n.t('HC.SelectProjectFirst', '请先选择一个项目')
                      : l10n.tf('HC.CurrentProjectInfo', '{label}：{name}（{id}…）', {
                          'label': l10n.t('HC.CurrentProjectLabel', '当前项目'),
                          'name': projectName ?? '',
                          'id': projectId.substring(0, 8),
                        }),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                _summaryCard(l10n, scheme, isEnglish),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: projectId == null
                ? const _NoProjectHint()
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 5,
                        child: _issues.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.check_circle_outline,
                                        size: 72, color: scheme.primary.withAlpha(120)),
                                    const SizedBox(height: 12),
                                    Text(
                                      _lastCheckAt == null
                                          ? l10n.t('HC.NoRunYet', '尚未执行任何检查，点上方按钮开始')
                                          : l10n.t('HC.NoIssue', '检查通过，未发现问题'),
                                      style: TextStyle(color: scheme.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(8),
                                itemCount: _issues.length,
                                itemBuilder: (ctx, i) {
                                  final iss = _issues[i];
                                  final selected = iss.id == _selectedId;
                                  final sevColor = _colorFor(iss.severity);
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Material(
                                      color: selected
                                          ? scheme.secondaryContainer.withAlpha(200)
                                          : scheme.surface,
                                      borderRadius: BorderRadius.circular(8),
                                      child: ListTile(
                                        onTap: () => setState(() => _selectedId = iss.id),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          side: selected
                                              ? BorderSide(color: scheme.primary)
                                              : BorderSide.none,
                                        ),
                                        leading: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: sevColor.withAlpha(30),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            severityFor(iss.severity, isEnglish),
                                            style: TextStyle(
                                              color: sevColor,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          iss.description,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                        subtitle: Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text(
                                            '${categoryFor(iss.category, isEnglish)}${iss.targetName != null ? l10n.tf('HC.CategoryTargetSep', ' · {type}：{name}', {
                                                'type': iss.targetType ?? '',
                                                'name': iss.targetName ?? '',
                                              }) : ''}',
                                            style: TextStyle(
                                              color: scheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        dense: true,
                                        trailing: Icon(
                                          Icons.chevron_right,
                                          size: 18,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        flex: 6,
                        child: _detailPanel(scheme, l10n, isEnglish),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(L10n l10n, ColorScheme scheme, bool isEnglish) {
    final errors = _issues.where((e) => e.severity == '错误').length;
    final warnings = _issues.where((e) => e.severity == '警告').length;
    final infos = _issues.where((e) => e.severity == '提示').length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _statChip(Icons.error_outline, severityFor('错误', isEnglish), errors, Colors.red, scheme),
            const SizedBox(width: 10),
            _statChip(Icons.warning_amber_outlined, severityFor('警告', isEnglish), warnings, Colors.orange, scheme),
            const SizedBox(width: 10),
            _statChip(Icons.info_outline, severityFor('提示', isEnglish), infos, Colors.blue, scheme),
            const SizedBox(width: 10),
            _statChip(Icons.assignment_late_outlined, l10n.t('HC.TotalLabel', '总数'), _issues.length, scheme.primary, scheme),
            const Spacer(),
            Text(
              _lastCheckAt == null
                  ? '${l10n.t('HC.NotChecked', '尚未检查')}${_aiRunning ? l10n.t('HC.AiRunningSep', ' · AI 工作流执行中…') : ''}'
                  : '${l10n.t('HC.LastCheck', '最近检查')}：${_lastCheckAt!.toString().substring(0, 19)}${_aiRunning ? l10n.t('HC.AiRunningSep', ' · AI 工作流执行中…') : ''}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statChip(
    IconData icon,
    String label,
    int value,
    Color color,
    ColorScheme scheme,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$label $value',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: color,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailPanel(ColorScheme scheme, L10n l10n, bool isEnglish) {
    final iss = _issues.where((e) => e.id == _selectedId).cast<_HealthIssue?>().firstWhere(
          (_) => true,
          orElse: () => null,
        );
    if (iss == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, size: 64, color: scheme.onSurfaceVariant.withAlpha(120)),
            const SizedBox(height: 12),
            Text(
              l10n.t('HC.SelectHint', '选择左侧问题查看详情与修复建议'),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final sevColor = _colorFor(iss.severity);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: sevColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${severityFor(iss.severity, isEnglish)} · ${categoryFor(iss.category, isEnglish)}',
                  style: TextStyle(color: sevColor, fontWeight: FontWeight.bold),
                ),
              ),
              if (iss.targetId != null || iss.targetName != null)
                Text(
                  l10n.tf('HC.TargetLabel', '目标：{type} · {name}', {
                    'type': iss.targetType ?? l10n.t('HC.Unknown', '未知'),
                    'name': iss.targetName ?? iss.targetId ?? '',
                  }),
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(iss.description, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.primary.withAlpha(120)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('HC.DetailAndSuggestions', '详情与修复建议'),
                  style: TextStyle(
                      color: scheme.primary, fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                SelectableText(iss.detail, style: const TextStyle(height: 1.6)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => _jumpTo(iss, isEnglish),
                icon: const Icon(Icons.open_in_new),
                label: Text(l10n.t('HC.JumpToTarget', '跳转定位')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _colorFor(String severity) => switch (severity) {
        '错误' => Colors.red,
        '警告' => Colors.orange,
        _ => Colors.blue,
      };

  Future<void> _run(HealthCheckMode mode) async {
    final l10n = ref.read(l10nProvider);
    final projectId = ref.read(currentProjectIdProvider);
    if (projectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('HC.SelectProjectInMgrFirst', '请先在项目管理中选择一个项目'))),
      );
      return;
    }
    setState(() {
      _isChecking = true;
      _aiRunning = false;
      _issues.clear();
      _selectedId = null;
    });
    try {
      final issues = await _runLocalChecks(projectId, mode);
      if (!mounted) return;
      setState(() {
        _issues.addAll(issues);
        _lastMode = mode;
        _lastCheckAt = DateTime.now();
      });
      if (mode == HealthCheckMode.consistency || mode == HealthCheckMode.all) {
        _runAiConsistency(projectId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('HC.CheckFailed', '执行检查失败：{error}',
              {'error': '$e'})), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<List<_HealthIssue>> _runLocalChecks(String projectId, HealthCheckMode mode) async {
    final found = <_HealthIssue>[];
    var idCounter = 0;
    String nextId() => '${DateTime.now().millisecondsSinceEpoch}_${idCounter++}';

    if (mode == HealthCheckMode.consistency || mode == HealthCheckMode.all) {
      final chars = await ref.read(characterRepositoryProvider).getByProjectId(projectId);
      final factions = await ref.read(factionRepositoryProvider).getByProjectId(projectId);
      final volumes = await ref.read(volumeRepositoryProvider).getByProjectId(projectId);
      final chapters = await ref.read(chapterRepositoryProvider).getByProjectId(projectId);
      final plots = await ref.read(plotRepositoryProvider).getByProjectId(projectId);
      final relations = await ref.read(characterRelationshipRepositoryProvider).getByProjectId(projectId);

      for (final c in chars) {
        if (c.name.trim().isEmpty) {
          found.add(_HealthIssue(
            id: nextId(),
            severity: '错误',
            category: '角色档案',
            description: '存在角色缺少姓名',
            detail: '建议给该角色补充正式姓名，便于引用与时间线串联。',
            targetType: '角色',
            targetName: c.name.isEmpty ? '(空)' : c.name,
            targetId: c.id,
          ));
        }
        final bioBuf = StringBuffer();
        if (c.appearance != null) bioBuf.write(c.appearance);
        if (c.personality != null) bioBuf.write(c.personality);
        if (c.background != null) bioBuf.write(c.background);
        if (c.abilities != null) bioBuf.write(c.abilities);
        if (bioBuf.length < 20) {
          final display = c.name.isEmpty ? '未命名' : c.name;
          found.add(_HealthIssue(
            id: nextId(),
            severity: '警告',
            category: '角色档案',
            description: '角色「$display」人物描述偏短',
            detail: '人物描述（外貌/性格/背景/能力）建议合计不少于 50 字；否则 AI 生成对话和剧情时容易失真。',
            targetType: '角色',
            targetName: c.name.isEmpty ? '(空)' : c.name,
            targetId: c.id,
          ));
        }
      }

      for (final ch in chapters) {
        final content = ch.content ?? '';
        if (content.trim().isEmpty) {
          final title = ch.title.isEmpty ? '未命名章节' : ch.title;
          found.add(_HealthIssue(
            id: nextId(),
            severity: '警告',
            category: '章节正文',
            description: '章节「$title」正文为空',
            detail: '该章节尚未撰写正文，建议补写或标记为「占位」，避免后续导出时出现漏文。',
            targetType: '章节',
            targetName: ch.title.isEmpty ? '(空)' : ch.title,
            targetId: ch.id,
          ));
        }
      }

      final involvedCharIds = <String>{};
      for (final r in relations) {
        involvedCharIds.add(r.sourceCharacterId);
        involvedCharIds.add(r.targetCharacterId);
      }
      for (final c in chars) {
        if (!involvedCharIds.contains(c.id) && chars.length > 3) {
          final display = c.name.isEmpty ? '未命名' : c.name;
          found.add(_HealthIssue(
            id: nextId(),
            severity: '提示',
            category: '人物关系',
            description: '角色「$display」暂未建立任何人际关系',
            detail: '建议为该角色至少增加一条关系连线（朋友/家人/敌人…），否则人物关系网络图呈现孤岛。',
            targetType: '角色',
            targetName: c.name.isEmpty ? '(空)' : c.name,
            targetId: c.id,
          ));
        }
      }

      for (final p in plots) {
        final title = p.title;
        final desc = p.description ?? '';
        if (desc.trim().isEmpty) {
          found.add(_HealthIssue(
            id: nextId(),
            severity: '提示',
            category: '剧情大纲',
            description: '剧情节点「${title.isEmpty ? '(未命名)' : title}」缺少描述',
            detail: '建议补充起承转合的具体事件、冲突、冲突解决方式，便于后续扩展成章节。',
            targetType: '剧情',
            targetName: title.isEmpty ? '(空)' : title,
            targetId: p.id,
          ));
        }
      }

      if (volumes.isEmpty) {
        found.add(_HealthIssue(
          id: nextId(),
          severity: '警告',
          category: '章节正文',
          description: '当前项目尚未创建任何卷宗',
          detail: '建议至少创建 1 卷，并放入若干章节，以形成完整的创作结构。',
        ));
      }
      if (chars.isEmpty) {
        found.add(_HealthIssue(
          id: nextId(),
          severity: '错误',
          category: '角色档案',
          description: '当前项目尚未创建任何角色',
          detail: '没有角色无法展开叙事，建议至少创建 2~3 位核心角色。',
        ));
      }
      if (factions.isEmpty && chars.length >= 3) {
        found.add(_HealthIssue(
          id: nextId(),
          severity: '提示',
          category: '势力组织',
          description: '项目已拥有角色但尚无任何势力/组织',
          detail: '如果故事涉及门派/国家/家族等群体，建议添加势力并把角色归属进去，会让世界观更扎实。',
        ));
      }
      if (plots.isEmpty) {
        found.add(_HealthIssue(
          id: nextId(),
          severity: '警告',
          category: '剧情大纲',
          description: '尚未撰写任何剧情节点',
          detail: '剧情大纲是故事的骨架；建议按开端→发展→高潮→结局拆分若干节点。',
        ));
      }
    }

    if (mode == HealthCheckMode.quality || mode == HealthCheckMode.all) {
      final chapters = await ref.read(chapterRepositoryProvider).getByProjectId(projectId);
      for (final ch in chapters) {
        final content = ch.content ?? '';
        final wc = ch.wordCount > 0 ? ch.wordCount : content.length;
        final title = ch.title;
        final status = ch.status;
        if (wc > 0 && wc < 300 && status != 'Draft') {
          found.add(_HealthIssue(
            id: nextId(),
            severity: '提示',
            category: '章节正文',
            description: '章节「$title」字数偏少（$wc），但状态非草稿',
            detail: '如果章节非「草稿」状态，建议字数达到 800 以上；若仍在创作中请改回 Draft，避免误判。',
            targetType: '章节',
            targetName: title.isEmpty ? '(空)' : title,
            targetId: ch.id,
          ));
        }
        if (wc > 20000) {
          found.add(_HealthIssue(
            id: nextId(),
            severity: '提示',
            category: '章节正文',
            description: '章节「$title」字数过长（$wc）',
            detail: '单章建议控制在 3000~8000 字；过长建议拆分为多个子章节，方便后续节奏调整。',
            targetType: '章节',
            targetName: title.isEmpty ? '(空)' : title,
            targetId: ch.id,
          ));
        }
      }

      final byVol = <String, List<ChapterRow>>{};
      for (final c in chapters) {
        byVol.putIfAbsent(c.volumeId, () => []).add(c);
      }
      byVol.forEach((vid, list) {
        list.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
        for (var i = 0; i < list.length - 1; i++) {
          final curr = list[i].orderIndex;
          final next = list[i + 1].orderIndex;
          if (curr == next) {
            final a = list[i].title.isEmpty ? '(空)' : list[i].title;
            final b = list[i + 1].title.isEmpty ? '(空)' : list[i + 1].title;
            found.add(_HealthIssue(
              id: nextId(),
              severity: '警告',
              category: '时间线',
              description: '同一卷宗下两章「$a」与「$b」排序号相同',
              detail: 'orderIndex 相同会导致时间线和章节列表顺序不稳定；请修正每一章的 orderIndex 使其严格递增。',
            ));
          }
        }
      });
    }

    const order = {'错误': 0, '警告': 1, '提示': 2};
    found.sort((a, b) => (order[a.severity] ?? 9).compareTo(order[b.severity] ?? 9));
    return found;
  }

  Future<void> _runAiConsistency(String projectId) async {
    final l10n = ref.read(l10nProvider);
    final engine = ref.read(workflowEngineProvider);
    if (!mounted) return;
    setState(() => _aiRunning = true);
    try {
      final wf = await engine.createPredefinedWorkflow(
        'ConsistencyCheck',
        <String, dynamic>{'projectId': projectId},
      );
      await engine.executeWorkflow(wf);
      final entries = <MapEntry<String, dynamic>>[];
      for (final t in wf.tasks) {
        final r = t.result;
        if (r == null) continue;
        final sections = r.metadata['sections'] as Map<String, dynamic>?;
        if (sections != null && sections.isNotEmpty) {
          for (final e in sections.entries) {
            entries.add(MapEntry('${t.name}:${e.key}', '${e.value}'));
          }
        } else if (r.data != null) {
          entries.add(MapEntry(t.name, r.data.toString()));
        }
        r.metadata.forEach((k, v) {
          if (k == 'sections') return;
          final s = '$v';
          if (s.length > 5) {
            entries.add(MapEntry('${t.name}[$k]', s));
          }
        });
      }
      if (entries.isNotEmpty) {
        final buf = StringBuffer();
        for (final e in entries) {
          buf.writeln('● [${e.key}] ${e.value}');
        }
        final aiIssue = _HealthIssue(
          id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
          severity: '提示',
          category: 'AI 一致性检查',
          description: 'AI 一致性检查工作流输出 ${entries.length} 条线索',
          detail: '来自 ConsistencyCheck 工作流的结果：\n\n$buf\n\n请逐条核对并修复相应实体。',
        );
        if (mounted) {
          setState(() {
            _issues.add(aiIssue);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('HC.AiCheckSkipped', 'AI 一致性检查跳过：{error}',
              {'error': '$e'})), backgroundColor: Colors.orange),
        );
      }
    } finally {
      if (mounted) setState(() => _aiRunning = false);
    }
  }

  void _jumpTo(_HealthIssue issue, bool isEnglish) {
    final l10n = ref.read(l10nProvider);
    final target = _resolveNavTarget(issue.category);
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.tf('HC.NoPageForCategory',
            '无法为类别「{cat}」找到对应页面', {
          'cat': categoryFor(issue.category, isEnglish),
        }))),
      );
      return;
    }
    if (issue.targetName != null && issue.targetName!.isNotEmpty) {
      //
    }
    ref.read(navigationProvider.notifier).navigateTo(target);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.tf('HC.NavigatedTo', '已跳转到「{page}」：{target}', {
          'page': _navTargetName(target, isEnglish),
          'target': issue.targetName ?? categoryFor(issue.category, isEnglish),
        })),
      ),
    );
  }

  static NavigationTarget? _resolveNavTarget(String category) => switch (category) {
        '角色档案' => NavigationTarget.characterManagement,
        '人物关系' => NavigationTarget.characterRelationshipManagement,
        '势力组织' => NavigationTarget.factionManagement,
        '剧情大纲' => NavigationTarget.plotManagement,
        '世界设定' => NavigationTarget.worldSettingManagement,
        '章节正文' => NavigationTarget.volumeManagement,
        '时间线' => NavigationTarget.timeline,
        _ => null,
      };
}

class _NoProjectHint extends ConsumerWidget {
  const _NoProjectHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off_outlined, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(l10n.t('HC.SelectProjectInMgrHint', '请先在「项目管理」中选择一个项目')),
        ],
      ),
    );
  }
}
