// 前置条件生成页 —— 对应 C# `Views/PrerequisiteGenerationDialog.xaml`。
//
// 数据底座补齐入口：修炼体系 / 剧情大纲 / 主要角色 / 世界设定 / 势力。
// 服务层「只补缺」，因此本页可反复点「开始生成」而不会重复插入。
//
// 与 C# 的差异：
// 1. C# 对话框里还有「使用 AI 智能生成 / 生成提示 / 书籍类型 / 世界观 / 允许编辑」五个控件，
//    它们对应 C# 的 `GenerateWithAIAsync`（**伪实现**：AI 调用结果最终被丢弃、落库的仍是模板数据）。
//    这里不渲染这些控件 —— 避免"看起来能开其实不生效"的假开关。
//    唯一真正的 AI 路径是**修炼体系**（直连 RWKV 生成自定义等级体系），已默认开启。
// 2. C# 的阈值判断写在对话框里、生成逻辑写在服务里；这里阈值全部收在服务层常量。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/prerequisite_generation_service.dart';
import '../../core/di.dart';
import '../../data/database.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';
import 'project_management_page.dart' show projectsStreamProvider;

class PrerequisiteGenerationPage extends ConsumerStatefulWidget {
  const PrerequisiteGenerationPage({super.key});

  @override
  ConsumerState<PrerequisiteGenerationPage> createState() =>
      _PrerequisiteGenerationPageState();
}

class _PrerequisiteGenerationPageState
    extends ConsumerState<PrerequisiteGenerationPage> {
  String? _projectId;

  bool _genPlots = true;
  bool _genCharacters = true;
  bool _genWorld = true;
  bool _genFactions = true;
  bool _genCultivation = true;

  bool _busy = false;

  /// 最近一次「检查状态」或「开始生成」的结果（用于展示计数与需求标志）。
  PrerequisiteGenerationResult? _result;

  /// 生成过程日志行（服务层已本地化的条目行）。
  final List<String> _log = <String>[];

  String _contextSummary = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String? current = ref.read(currentProjectIdProvider);
      setState(() => _projectId = current);
      if (current != null) {
        _loadContext(current);
      }
    });
  }

  Future<void> _loadContext(String projectId) async {
    final String summary = await ref
        .read(projectContextAssemblerProvider)
        .buildSubsystemPromptContext(projectId, '前置条件');
    if (!mounted) return;
    setState(() => _contextSummary = summary);
  }

  /// 「检查状态」= 用「全部不生成」的选项跑一次服务，只取计数与需求标志。
  Future<void> _checkStatus() async {
    final String? projectId = _projectId;
    if (projectId == null) return;
    setState(() => _busy = true);
    try {
      final PrerequisiteGenerationResult r = await ref
          .read(prerequisiteGenerationServiceProvider)
          .generatePrerequisites(
            projectId,
            options: const PrerequisiteGenerationOptions(
              generatePlotOutlines: false,
              generateMainCharacters: false,
              generateWorldSettings: false,
              generateFactions: false,
              generateCultivationSystem: false,
            ),
          );
      if (!mounted) return;
      setState(() => _result = r);
      await _loadContext(projectId);
    } on Object catch (e) {
      if (mounted) {
        final L10n l10n = ref.read(l10nProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.tf('PG.CheckStatusFailedFmt', '检查状态失败：{0}',
              <Object>[e])),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate() async {
    final String? projectId = _projectId;
    if (projectId == null) return;
    final L10n l10n = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _log.clear();
    });
    try {
      final PrerequisiteGenerationResult r = await ref
          .read(prerequisiteGenerationServiceProvider)
          .generatePrerequisites(
            projectId,
            options: PrerequisiteGenerationOptions(
              generatePlotOutlines: _genPlots,
              generateMainCharacters: _genCharacters,
              generateWorldSettings: _genWorld,
              generateFactions: _genFactions,
              generateCultivationSystem: _genCultivation,
            ),
          );
      if (!mounted) return;
      setState(() {
        _result = r;
        _log.addAll(r.generatedItems);
      });
      await _loadContext(projectId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.totalGeneratedCount > 0
            ? l10n.tf('PG.DoneMsgFmt', '前置条件生成完成！\n\n{0}',
                <Object>[r.generatedItems.join('\n')])
            : l10n.t('PG.NoNeedTitle', '无需生成')),
      ));
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              l10n.tf('PG.CheckStatusFailedFmt', '检查状态失败：{0}', <Object>[e])),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final AsyncValue<List<ProjectRow>> projectsAsync =
        ref.watch(projectsStreamProvider);

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.t('PG.Title', '前置条件生成'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(l10n.t('PG.Desc',
                '为确保AI编辑功能正常运行，系统将检查并生成必要的前置数据，并按项目基础信息、世界观、大纲、配套设定、卷章写作的顺序展示当前流程状态。'),),
            const SizedBox(height: 16),
            // ---- 项目选择 + 检查状态 ----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: projectsAsync.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (Object e, _) => Text(
                            l10n.tf('Common.LoadFailed', '加载失败：{0}',
                                <Object>[e])),
                        data: (List<ProjectRow> projects) {
                          if (projects.isEmpty) {
                            return Text(l10n.t('PG.NoProjectSelected', '未选择项目。'));
                          }
                          final String? value =
                              projects.any((ProjectRow p) => p.id == _projectId)
                                  ? _projectId
                                  : null;
                          return DropdownButtonFormField<String>(
                            initialValue: value,
                            decoration: InputDecoration(
                              labelText:
                                  l10n.t('PG.ProjectSelection', '项目选择'),
                              hintText:
                                  l10n.t('PG.HintSelectProject', '选择已有项目'),
                            ),
                            items: <DropdownMenuItem<String>>[
                              for (final ProjectRow p in projects)
                                DropdownMenuItem<String>(
                                  value: p.id,
                                  child: Text(p.name),
                                ),
                            ],
                            onChanged: (String? v) {
                              setState(() {
                                _projectId = v;
                                _result = null;
                                _log.clear();
                              });
                              if (v != null) _loadContext(v);
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Tooltip(
                      message: l10n.t('PG.CheckStatusTip', '重新检查当前项目的数据状态'),
                      child: OutlinedButton.icon(
                        onPressed: _projectId == null || _busy
                            ? null
                            : _checkStatus,
                        icon: const Icon(Icons.fact_check_outlined),
                        label: Text(l10n.t('PG.CheckStatus', '检查状态')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // ---- 当前数据状态 ----
            _SectionCard(
              title: l10n.t('PG.DataStatus', '当前项目数据状态'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (_projectId == null)
                    Text(l10n.t('PG.SummaryPlaceholder', '请选择项目后查看当前写作流程状态。'))
                  else if (_result == null)
                    Text(l10n.t('PG.SummaryPlaceholder', '请选择项目后查看当前写作流程状态。'))
                  else ...<Widget>[
                    _statusLine(
                      l10n.tf('PG.PlotsStatusFmt', '剧情大纲: {0} 个 {1}',
                          <Object>[_result!.existingPlotsCount, _ok(!_result!.needsPlotOutlines, l10n)]),
                    ),
                    _statusLine(
                      l10n.tf('PG.CharactersStatusFmt', '主要角色: {0} 个 {1}',
                          <Object>[_result!.existingMainCharactersCount, _ok(!_result!.needsMainCharacters, l10n)]),
                    ),
                    _statusLine(
                      l10n.tf('PG.WorldStatusFmt', '世界设定: {0} 个 {1}',
                          <Object>[_result!.existingWorldSettingsCount, _ok(!_result!.needsWorldSettings, l10n)]),
                    ),
                    _statusLine(
                      l10n.tf('PG.FactionsStatusFmt', '势力组织: {0} 个 {1}',
                          <Object>[_result!.existingFactionsCount, _ok(!_result!.needsFactions, l10n)]),
                    ),
                    _statusLine(
                      _result!.existingCultivationSystemsCount > 0
                          ? l10n.tf('PG.CultivationReadyFmt', '修炼体系: {0} 套 ✓',
                              <Object>[_result!.existingCultivationSystemsCount])
                          : l10n.t('PG.CultivationEmpty',
                              '修炼体系: 未设定，AI 可自上而下生成自定义等级体系'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // ---- 生成选项 ----
            _SectionCard(
              title: l10n.t('PG.Options', '生成选项'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _optionTile(
                    l10n.t('PG.GenPlots', '生成剧情大纲'),
                    _genPlots,
                    (bool v) => setState(() => _genPlots = v),
                  ),
                  _optionTile(
                    l10n.t('PG.GenCharacters', '生成主要角色'),
                    _genCharacters,
                    (bool v) => setState(() => _genCharacters = v),
                  ),
                  _optionTile(
                    l10n.t('PG.GenWorld', '生成世界设定'),
                    _genWorld,
                    (bool v) => setState(() => _genWorld = v),
                  ),
                  _optionTile(
                    l10n.t('PG.GenFactions', '生成势力组织'),
                    _genFactions,
                    (bool v) => setState(() => _genFactions = v),
                  ),
                  _optionTile(
                    l10n.t('PG.GenCultivation', '生成修炼体系（AI 自定义等级体系）'),
                    _genCultivation,
                    (bool v) => setState(() => _genCultivation = v),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: _projectId == null || _busy ? null : _generate,
                        icon: const Icon(Icons.auto_fix_high),
                        label: Text(l10n.t('PG.StartGenerate', '开始生成')),
                      ),
                      const SizedBox(width: 12),
                      if (_busy) ...[
                        const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text(l10n.t('PG.Preparing', '准备开始生成...'),
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // ---- AI 上下文摘要 ----
            _SectionCard(
              title: l10n.t('PG.ContextSummary', 'AI 上下文约束摘要'),
              child: SelectableText(
                _contextSummary.isEmpty
                    ? (_projectId == null
                        ? l10n.t('PG.ContextPlaceholder',
                            '请选择项目后查看 AI 将遵循的上位设定与生成顺序。')
                        : l10n.t('PG.NoContextSummary', '当前项目暂无可用的 AI 上下文摘要。'))
                    : _contextSummary,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 16),
              _SectionCard(
                title: l10n.t('PG.Result', '生成结果'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final String line in _log)
                      Text('· $line', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _ok(bool ready, L10n l10n) =>
      ready ? '✓' : l10n.t('PG.NeedGenerate', '需要生成');

  static Widget _statusLine(String text) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(text));

  static Widget _optionTile(String label, bool value, ValueChanged<bool> onChanged) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: value,
        onChanged: (bool? v) => onChanged(v ?? false),
        title: Text(label),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    )),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}