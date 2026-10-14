// 「分层写书」对话框（+50）—— 把命令行验证过的四级管线接进 App。
//
// 工艺：主线大纲（串行，起点→终点锚定）→ 分卷大纲（卷间并行 / 卷内串行）
//       → 章节细纲（章间并行 / 章内串行 + 差异补丁自查）→ 正文（同前，带伏笔义务）
//
// 与「一键生成书籍 / 多智能体写书」的关系：**并存、互不影响**。本对话框只在
// 用户主动选择时运行，落库到新建（或同名复用）的项目里。
//
// ⚠ 已知边界（+50 实测）：
//   * 正文默认走**无状态**路由（RWKV 云端 `/state/*` 当前不可用于正文）；
//   * 细纲质量依赖模型对契约的遵守度 —— 字段重复 / 缺字段会被检出并提示，
//     但客户端无法保证模型一定修正。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/utils/layered_pipeline_plan.dart';
import '../../application/services/layered_book_runner.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';

/// 分层写书结果（回传给调用方用于跳转）。
class LayeredGenerationResult {
  const LayeredGenerationResult({
    required this.projectId,
    required this.bookTitle,
    required this.isSuccess,
    required this.message,
  });

  final String projectId;
  final String bookTitle;
  final bool isSuccess;
  final String message;
}

Future<LayeredGenerationResult?> showLayeredGenerationDialog(
  BuildContext context,
) =>
    showDialog<LayeredGenerationResult>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => const _LayeredGenerationDialog(),
    );

class _LayeredGenerationDialog extends ConsumerStatefulWidget {
  const _LayeredGenerationDialog();

  @override
  ConsumerState<_LayeredGenerationDialog> createState() =>
      _LayeredGenerationDialogState();
}

class _LayeredGenerationDialogState
    extends ConsumerState<_LayeredGenerationDialog> {
  final TextEditingController _title =
      TextEditingController(text: '退潮四十分钟');
  final TextEditingController _genre =
      TextEditingController(text: '都市悬疑 · 轻奇幻');
  final TextEditingController _theme =
      TextEditingController(text: '人是否应该改写尚未发生的坏事 —— 以及改写的代价由谁承担。');
  final TextEditingController _background = TextEditingController(
      text: '临海小城「潮尾镇」。镇东海岬的旧灯塔下，有一座只在退潮时露出水面的图书馆：'
          '涨潮时它被海水淹没，退潮的四十分钟里，门会开。'
          '馆内每一本书都记录着一件尚未发生的事，按人名编目。');
  final TextEditingController _protagonist = TextEditingController(
      text: '沈砚，28 岁，市立图书馆夜班管理员。有轻度面孔失认症：认不出人脸，'
          '只能靠声音、步态和习惯认人。');
  final TextEditingController _cast = TextEditingController(
      text: '沈砚（主角，夜班馆员）；周晓棠（海防派出所民警，行动派，不信邪）；'
          '老岑（灯塔守，守了四十年）；「编目员」（从未露脸，只在借阅卡上留字）。');
  final TextEditingController _anchorStart = TextEditingController(
      text: '沈砚刚接手市立图书馆夜班，镇上流传「东岬退潮时别去」的说法，'
          '他对低潮图书馆一无所知，与周晓棠只是点头之交。');
  final TextEditingController _anchorEnd = TextEditingController(
      text: '百年大潮退去，低潮图书馆被永久淹没；沈砚知道了「编目员」是谁、'
          '也明白了改写的代价由谁承担，并做出最终选择后承担后果。');

  int _volumes = 1;
  int _chaptersPerVolume = 5;
  int _concurrency = 2;
  bool _proseStateful = false;
  bool _running = false;
  final List<String> _log = <String>[];
  LayeredRunOutcome? _outcome;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _genre.dispose();
    _theme.dispose();
    _background.dispose();
    _protagonist.dispose();
    _cast.dispose();
    _anchorStart.dispose();
    _anchorEnd.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final L10n l10n = ref.read(l10nProvider);
    if (_title.text.trim().isEmpty) {
      setState(() => _error = l10n.t('LG.NeedTitle', '请填写书名'));
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _outcome = null;
      _log.clear();
    });
    try {
      final LayeredRunOutcome outcome =
          await ref.read(layeredBookRunnerProvider).run(
        LayeredRunRequest(
          bookTitle: _title.text.trim(),
          genre: _genre.text.trim(),
          theme: _theme.text.trim(),
          background: _background.text.trim(),
          protagonist: _protagonist.text.trim(),
          cast: _cast.text.trim(),
          volumeCount: _volumes,
          chaptersPerVolume: _chaptersPerVolume,
          bookAnchor: PipelineAnchor(
            start: _anchorStart.text.trim(),
            end: _anchorEnd.text.trim(),
            startLabel: l10n.t('LG.AnchorStart', '全书起点'),
            endLabel: l10n.t('LG.AnchorEnd', '全书终点'),
          ),
          concurrency: _concurrency,
          proseStateful: _proseStateful,
        ),
        onProgress: (String step, double? progress) {
          if (!mounted) return;
          setState(() => _log.add(step));
        },
      );
      if (!mounted) return;
      setState(() {
        _running = false;
        _outcome = outcome;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Icon(Icons.account_tree_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.t('LG.Title', '分层写书（串行 → 并行）'))),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 520,
        child: _outcome != null
            ? _buildOutcome(l10n, scheme, _outcome!)
            : _running
                ? _buildRunning(l10n, scheme)
                : _buildForm(l10n, scheme),
      ),
      actions: _running
          ? <Widget>[
              TextButton(
                onPressed: null,
                child: Text(l10n.t('LG.Running', '生成中…')),
              ),
            ]
          : _outcome != null
              ? <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(
                      LayeredGenerationResult(
                        projectId: _outcome!.projectId,
                        bookTitle: _title.text.trim(),
                        isSuccess: true,
                        message: l10n.tf('LG.DoneFmt',
                            '过闸 {0}/{1} 章 · 平均 {2} 字 · ngram {3}',
                            <Object>[
                              _outcome!.passed,
                              _outcome!.chapterCount,
                              _outcome!.avgChars,
                              _outcome!.avgNgram.toStringAsFixed(3),
                            ]),
                      ),
                    ),
                    child: Text(l10n.t('LG.OpenProject', '打开项目')),
                  ),
                ]
              : <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.t('Common.Cancel', '取消')),
                  ),
                  FilledButton(
                    onPressed: _run,
                    child: Text(l10n.t('LG.Start', '开始生成')),
                  ),
                ],
    );
  }

  Widget _buildForm(L10n l10n, ColorScheme scheme) {
    return ListView(
      children: <Widget>[
        Text(
          l10n.t('LG.Hint',
              '四级管线：主线大纲（串行）→ 分卷大纲（卷间并行/卷内串行）→ 章节细纲（章间并行/章内串行）→ 正文。'
              '每级都按「起点 → 终点」锚定并线性补齐中间过程。'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _field(l10n.t('LG.BookTitle', '书名'), _title),
        _field(l10n.t('LG.Genre', '题材'), _genre),
        _field(l10n.t('LG.Theme', '主题'), _theme, lines: 2),
        _field(l10n.t('LG.Background', '背景设定'), _background, lines: 3),
        _field(l10n.t('LG.Protagonist', '主角'), _protagonist, lines: 2),
        _field(l10n.t('LG.Cast', '主要人物'), _cast, lines: 2),
        const Divider(height: 24),
        Text(
          l10n.t('LG.AnchorHint',
              '起点 / 终点锚：整条剧情弧线的两端。模型会把中间过程**均匀分段**补齐，'
              '不会第一段就写完结局，也不会最后一段还停在起点。'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        _field(l10n.t('LG.AnchorStart', '全书起点'), _anchorStart, lines: 2),
        _field(l10n.t('LG.AnchorEnd', '全书终点'), _anchorEnd, lines: 2),
        const Divider(height: 24),
        Row(
          children: <Widget>[
            Expanded(
              child: _stepper(
                l10n.t('LG.Volumes', '卷数'),
                _volumes,
                (int v) => setState(() => _volumes = v),
                min: 1,
                max: 8,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stepper(
                l10n.t('LG.ChaptersPerVolume', '每卷章数'),
                _chaptersPerVolume,
                (int v) => setState(() => _chaptersPerVolume = v),
                min: 2,
                max: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stepper(
                l10n.t('LG.Concurrency', '并行单元数'),
                _concurrency,
                (int v) => setState(() => _concurrency = v),
                min: 1,
                max: 6,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _proseStateful,
          onChanged: (bool v) => setState(() => _proseStateful = v),
          title: Text(
            l10n.t('LG.Stateful', '正文使用 RWKV 有状态续跑（实验性）'),
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            l10n.t('LG.StatefulHint',
                '实测本部署的 /state/* 会无视 think_type 并先输出思考，过闸率不稳定（1/5~4/5）。'
                '建议保持关闭，除非服务端已修好。'),
            style: const TextStyle(fontSize: 11),
          ),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 12, color: scheme.error)),
        ],
      ],
    );
  }

  Widget _buildRunning(L10n l10n, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const LinearProgressIndicator(),
        const SizedBox(height: 10),
        Text(l10n.t('LG.Running', '生成中…'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: ListView(
              children: <Widget>[
                for (final String line in _log)
                  Text(line,
                      style: const TextStyle(fontSize: 11, height: 1.6)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOutcome(
    L10n l10n,
    ColorScheme scheme,
    LayeredRunOutcome o,
  ) {
    return ListView(
      children: <Widget>[
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.t('LG.ResultTitle', '生成完成'),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(l10n.tf('LG.StatFmt',
                    '章节 {0} 章 · 过闸 {1} 章 · 平均 {2} 字 · 平均 ngram {3}',
                    <Object>[
                      o.chapterCount,
                      o.passed,
                      o.avgChars,
                      o.avgNgram.toStringAsFixed(3),
                    ])),
                Text(l10n.tf('LG.ForeshadowFmt',
                    '伏笔账本：{0} 条 · 结构错误 {1}',
                    <Object>[o.foreshadowEntries, o.foreshadowErrors])),
              ],
            ),
          ),
        ),
        if (o.notes.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(l10n.t('LG.Notes', '管线提示'),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          for (final String n in o.notes)
            Text('· $n',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 12),
        Text(l10n.t('LG.Log', '执行日志'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        for (final String line in _log)
          Text(line, style: const TextStyle(fontSize: 11, height: 1.6)),
      ],
    );
  }

  Widget _field(String label, TextEditingController ctrl, {int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        minLines: lines,
        maxLines: lines + 2,
        style: const TextStyle(fontSize: 13, height: 1.5),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _stepper(
    String label,
    int value,
    void Function(int) onChanged, {
    required int min,
    required int max,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: const TextStyle(fontSize: 11)),
        Row(
          children: <Widget>[
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove, size: 16),
              onPressed:
                  value > min ? () => onChanged(value - 1) : null,
            ),
            Text('$value', style: const TextStyle(fontSize: 14)),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 16),
              onPressed:
                  value < max ? () => onChanged(value + 1) : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// 便捷入口：跑完分层写书后选中项目并跳转（供 `app_shell` 复用）。
Future<void> openLayeredGeneration(
  BuildContext context,
  WidgetRef ref,
) async {
  final LayeredGenerationResult? result =
      await showLayeredGenerationDialog(context);
  if (result == null || result.projectId.isEmpty) return;
  ref.read(currentProjectIdProvider.notifier).select(result.projectId);
  ref
      .read(navigationProvider.notifier)
      .navigateTo(NavigationTarget.projectOverview);
}
