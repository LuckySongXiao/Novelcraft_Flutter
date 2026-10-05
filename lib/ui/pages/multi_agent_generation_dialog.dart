// 多智能体协同写书 —— 开始前由用户填写向导：
//   书籍名称 / 作者署名 / 初始目标分卷数 / 每卷目标章节数 / 可分配子智能体数量。
// 开始后按三级大纲（主线 → 分卷 → 章节）与「组长 + 写手」章节团队编排，
// 进度实时展示（含每章进度条），结束后逐条如实渲染结果。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/workflow/concurrency_planner.dart';
import '../../application/services/multi_agent_book_generation_service.dart';
import '../../l10n/l10n.dart';
import '../state/multi_agent_run.dart';
import '../widgets/readonly_prose_view.dart';
import 'writing_prompt_settings_page.dart';

/// 弹出「多智能体协同写书」向导对话框；用户中途关闭返回 null。
Future<MultiAgentBookResult?> showMultiAgentGenerationDialog(
  BuildContext context,
) {
  return showDialog<MultiAgentBookResult>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => const _MultiAgentWizardDialog(),
  );
}

class _MultiAgentWizardDialog extends ConsumerStatefulWidget {
  const _MultiAgentWizardDialog();

  @override
  ConsumerState<_MultiAgentWizardDialog> createState() =>
      _MultiAgentWizardDialogState();
}

class _MultiAgentWizardDialogState
    extends ConsumerState<_MultiAgentWizardDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();
  final TextEditingController _volumesCtrl = TextEditingController(text: '3');
  final TextEditingController _chaptersCtrl = TextEditingController(text: '10');

  /// 目标预留团队数（普通模式上限；0 = 不限）。
  final TextEditingController _reservedCtrl = TextEditingController(text: '10');

  /// 并发档位：普通（≤100 团队）/ 高速（全部章节同时开工）。
  MultiAgentSpeedMode _mode = MultiAgentSpeedMode.normal;

  /// 写作工艺（正文产出方式）：续写优选 / 单笔直书 / 主笔分段串行 / 组长+9 写手。
  WritingCraft _craft = WritingCraft.beam;

  String? _formError;
  bool _running = false;
  MultiAgentBookResult? _result;

  @override
  void initState() {
    super.initState();
    // 打开向导时若已有后台写书任务在跑 → 直接进入运行视图（绑定全局状态）。
    _running = ref.read(multiAgentRunProvider)?.running ?? false;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    _volumesCtrl.dispose();
    _chaptersCtrl.dispose();
    _reservedCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final l10n = ref.read(l10nProvider);
    final int volumes = int.tryParse(_volumesCtrl.text.trim()) ?? 3;
    final int chaptersPerVolume = int.tryParse(_chaptersCtrl.text.trim()) ?? 10;
    final int reserved = int.tryParse(_reservedCtrl.text.trim()) ?? 10;
    final config = MultiAgentBookConfig(
      bookTitle: _titleCtrl.text,
      authorName: _authorCtrl.text,
      targetVolumes: volumes,
      chaptersPerVolume: chaptersPerVolume,
      subAgentCount: 10, // 固定编制：1 组长 + 9 偏向写手（仅 team 工艺使用）
      craft: _craft,
      // 并发由公式自动计算（分卷数 × 每卷章节数 + 预留团队数 + 档位）
      concurrency: ConcurrencyPlanner.compute(
        volumes: volumes,
        chaptersPerVolume: chaptersPerVolume,
        reservedTeams: reserved,
        mode: _mode,
      ),
    );
    final ({String? error, MultiAgentBookConfig normalized}) norm = config
        .normalize();
    if (norm.error != null) {
      setState(
        () => _formError = l10n.tf('MAG.FormError', '输入有误：{0}', <Object>[
          norm.error!,
        ]),
      );
      return;
    }
    setState(() {
      _formError = null;
      _running = true;
    });
    // 生成由全局控制器托管：对话框可收起到后台（AppBar 绿色长条），
    // 重开向导或写作动态矩阵都能看到同一份实时进度。
    final MultiAgentBookResult r = await ref
        .read(multiAgentRunProvider.notifier)
        .start(norm.normalized);
    if (!mounted) return;
    setState(() {
      _result = r;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final MultiAgentBookResult? r = _result;

    return AlertDialog(
      title: Text(l10n.t('MAG.Title', '多智能体协同写书')),
      content: SizedBox(
        width: 480,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: _running
              ? SingleChildScrollView(child: _buildRunning(l10n))
              : (r == null
                  ? _buildForm(l10n)
                  : SingleChildScrollView(
                      child: _buildResult(context, l10n, r))),
        ),
      ),
      actions: <Widget>[
        if (!_running && r == null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
        if (!_running && r == null)
          FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.groups),
            label: Text(l10n.t('MAG.Start', '开始协同写作')),
          ),
        if (_running)
          // 收起到后台：生成继续（AppBar 绿色「写作中」长条可回来看进度）
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(null),
            icon: const Icon(Icons.picture_in_picture_alt, size: 16),
            label: Text(l10n.t('MAG.Background', '收起，后台继续')),
          ),
        if (!_running && r != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(r),
            child: Text(l10n.t('Common.Confirm', '确定')),
          ),
      ],
    );
  }

  Widget _buildForm(L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.t(
              'MAG.FormIntro',
              '先配置书籍信息。G1K 组合中 7.2B 负责大纲和润色，2.9B 负责正文；'
                  '其他模型按所选写作工艺执行。',
            ),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _titleCtrl,
            maxLength: 60,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(60),
            ],
            decoration: InputDecoration(
              labelText: l10n.t('MAG.BookTitle', '书籍名称'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _authorCtrl,
            maxLength: 30,
            decoration: InputDecoration(
              labelText: l10n.t('MAG.Author', '作者署名'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _volumesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.t('MAG.TargetVolumes', '目标分卷数'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _chaptersCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.t('MAG.ChaptersPerVolume', '每卷章节数'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ---- 写作工艺（正文产出方式）----
          TextButton.icon(
            icon: const Icon(Icons.edit_note),
            label: Text(
              l10n.t('MAG.ConfigurePrompts', '配置各工艺节点 Prompt 模板'),
            ),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const WritingPromptSettingsPage(),
            )),
          ),
          // 2026-09-30 实测：单次生成自然收敛 ≈2000~2800 字且尾部易复读，
          // 故「主笔分段串行」为推荐默认；旧 9 写手并行保留但成本约 8 倍。
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.t('MAG.Craft', '写作工艺（正文产出方式）'),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final (WritingCraft, String) item
                  in <(WritingCraft, String)>[
                    (WritingCraft.beam, l10n.t('MAG.Craft.Beam', '续写优选（推荐）')),
                    (WritingCraft.solo, l10n.t('MAG.Craft.Solo', '单笔直书')),
                    (WritingCraft.duo, l10n.t('MAG.Craft.Duo', '主笔分段串行')),
                    (
                      WritingCraft.team,
                      l10n.t('MAG.Craft.Team', '组长 + 9 写手（旧）'),
                    ),
                  ])
                ChoiceChip(
                  label: Text(item.$2, style: const TextStyle(fontSize: 12)),
                  selected: _craft == item.$1,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _craft = item.$1),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(switch (_craft) {
            WritingCraft.beam => l10n.t(
              'MAG.Craft.BeamHint',
              '每轮并发 5 份续写候选、按「长度/多样性/污染/重复度」择优再续写：'
                  '专为 RWKV「续写强、指令弱」设计，成功率最高。',
            ),
            WritingCraft.solo => l10n.t(
              'MAG.Craft.SoloHint',
              '1 次调用写完本章：最快最省，适合短章（实测自然收敛约 2000~2800 字）。',
            ),
            WritingCraft.duo => l10n.t(
              'MAG.Craft.DuoHint',
              '主笔按 ~2200 字/段续写、只带上一段尾部 300 字。',
            ),
            WritingCraft.team => l10n.t(
              'MAG.Craft.TeamHint',
              '1 组长 + 9 写手并行 + 组长拼接：每章 12+ 次调用、成本约 8 倍，仅特殊需求时使用。',
            ),
          }, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          TextField(
            controller: _reservedCtrl,
            enabled: _mode == MultiAgentSpeedMode.normal,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            decoration: InputDecoration(
              labelText: l10n.t('MAG.ReservedTeams', '目标预留团队数'),
              helperText: l10n.t(
                'MAG.ReservedHelper',
                '普通模式上限（≤100）；0 = 不限，由硬上限兜底',
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          // ---- 并发档位：普通（≤100 团队）/ 高速（全部章节同时开工）----
          SegmentedButton<MultiAgentSpeedMode>(
            segments: <ButtonSegment<MultiAgentSpeedMode>>[
              ButtonSegment<MultiAgentSpeedMode>(
                value: MultiAgentSpeedMode.normal,
                icon: const Icon(Icons.speed, size: 18),
                label: Text(compact
                    ? l10n.t('MAG.Mode.NormalShort', '普通')
                    : l10n.t('MAG.Mode.Normal', '普通模式（≤100 团队）')),
              ),
              ButtonSegment<MultiAgentSpeedMode>(
                value: MultiAgentSpeedMode.turbo,
                icon: const Icon(Icons.rocket_launch_outlined, size: 18),
                label: Text(compact
                    ? l10n.t('MAG.Mode.TurboShort', '高速')
                    : l10n.t('MAG.Mode.Turbo', '高速模式（全部同时开工）')),
              ),
            ],
            selected: <MultiAgentSpeedMode>{_mode},
            onSelectionChanged: (Set<MultiAgentSpeedMode> s) =>
                setState(() => _mode = s.first),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.t('MAG.ComputedTitle', '并发自动计算'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ConcurrencyPlanner.describe(
                    volumes: int.tryParse(_volumesCtrl.text.trim()) ?? 3,
                    chaptersPerVolume:
                        int.tryParse(_chaptersCtrl.text.trim()) ?? 10,
                    reservedTeams:
                        int.tryParse(_reservedCtrl.text.trim()) ?? 10,
                    mode: _mode,
                  ),
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          if (_formError != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRunning(L10n l10n) {
    final MultiAgentRunState? run = ref.watch(multiAgentRunProvider);
    final String elapsed = run?.startedAt == null
        ? ''
        : ' · ${l10n.t('MAG.Elapsed', '已用时')} ${formatElapsed(DateTime.now().difference(run!.startedAt!), l10n)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        LinearProgressIndicator(value: run?.effectiveProgress),
        const SizedBox(height: 12),
        Text(
          (run?.step ?? '').isEmpty
              ? l10n.t('MAG.Starting', '正在启动多智能体协同写作…')
              : run!.step,
        ),
        if (elapsed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '$elapsed · ${l10n.t('MAG.ElapsedHint', '思考型模型单步可能需要数分钟，请耐心等待；单次调用超时自动跳过')}',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildResult(BuildContext context, L10n l10n, MultiAgentBookResult r) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<(String, String?)> lines = <(String, String?)>[
      (
        r.projectCreated
            ? l10n.tf('MAG.ResultCreatedFmt', '新书《{0}》（作者：{1}）已创建。', <Object>[
                r.bookTitle,
                r.authorName,
              ])
            : l10n.t('MAG.ResultNotCreated', '项目未创建。'),
        r.mainOutlineText.trim().isEmpty ? null : r.mainOutlineText,
      ),
      (
        l10n.tf('MAG.ResultVolumesFmt', '分卷大纲：{0} 卷已规划并写入。', <Object>[
          r.volumesPlanned,
        ]),
        null,
      ),
      (
        l10n.tf('MAG.ResultOutlinesFmt', '章节大纲：{0} 章已规划并写入。', <Object>[
          r.chapterOutlinesPlanned,
        ]),
        null,
      ),
      (
        l10n.tf('MAG.ResultWrittenFmt', '团队协作成稿：{0}/{1} 章已完成并落库。', <Object>[
          r.chaptersWritten,
          r.chaptersPlanned,
        ]),
        null,
      ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              r.isSuccess ? Icons.check_circle_outline : Icons.error_outline,
              size: 18,
              color: r.isSuccess ? Colors.green : scheme.error,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                r.message,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final (String, String?) line in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '· ${line.$1}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (line.$2 != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: const Icon(
                      Icons.chrome_reader_mode_outlined,
                      size: 14,
                    ),
                    label: Text(
                      l10n.t('OCG.ViewOutput', '查看'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () =>
                        _viewOutput(context, l10n, line.$1, line.$2!),
                  ),
              ],
            ),
          ),
        if (r.warnings.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            l10n.t('MAG.WarningsTitle', '警告与部分失败'),
            style: TextStyle(fontSize: 12, color: scheme.error),
          ),
          for (final String w in r.warnings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                '· $w',
                style: TextStyle(fontSize: 11, color: scheme.error),
              ),
            ),
        ],
      ],
    );
  }

  void _viewOutput(BuildContext context, L10n l10n, String label, String text) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [ReadonlyProseView(content: text, fontSize: 15)],
          ),
        ),
      ),
    );
  }
}
