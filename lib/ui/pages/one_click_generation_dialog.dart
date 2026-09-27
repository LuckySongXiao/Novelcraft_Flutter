// 一键生成书籍对话框 —— 对应 C# `MainWindow` 的「一键生成书籍」按钮 + 进度对话框。
//
// 与 C# 的差异：C# 用 MessageBox 展示"是否成功"，失败明细只藏在 message 文本里；
// 这里按 [OneClickNovelGenerationResult] 的显式字段**逐条如实渲染**
// （哪些成功、哪些失败、失败在哪一步），并且**绝不打印"联动已完成"**
// ——`linkageApplied` 在本批恒为 false，对应文案走 `OCG.ResultLinkPending`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/one_click_novel_generation_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../widgets/readonly_prose_view.dart';

/// 弹出「一键生成书籍」对话框；返回结果（用户中途关闭返回 null）。
Future<OneClickNovelGenerationResult?> showOneClickGenerationDialog(
  BuildContext context,
) {
  return showDialog<OneClickNovelGenerationResult>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => const _OneClickGenerationDialog(),
  );
}

class _OneClickGenerationDialog extends ConsumerStatefulWidget {
  const _OneClickGenerationDialog();

  @override
  ConsumerState<_OneClickGenerationDialog> createState() =>
      _OneClickGenerationDialogState();
}

class _OneClickGenerationDialogState
    extends ConsumerState<_OneClickGenerationDialog> {
  String _step = '';
  OneClickNovelGenerationResult? _result;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final OneClickNovelGenerationResult r = await ref
        .read(oneClickNovelGenerationServiceProvider)
        .generate(onProgress: (String step) {
      if (mounted) setState(() => _step = step);
    });
    if (!mounted) return;
    setState(() {
      _result = r;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final OneClickNovelGenerationResult? r = _result;

    return AlertDialog(
      title: Text(l10n.t('Side.Btn.OneClick', '一键生成书籍')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (_running) ...<Widget>[
              LinearProgressIndicator(
                value: null,
                semanticsLabel: l10n.t('MW.OneClickRunning', '正在一键生成，请稍候…'),
              ),
              const SizedBox(height: 12),
              Text(_step.isEmpty
                  ? l10n.t('MW.OneClickRunning', '正在一键生成，请稍候…')
                  : _step),
            ],
            if (r != null) _buildResult(context, l10n, r),
          ],
        ),
      ),
      actions: <Widget>[
        if (!_running)
          TextButton(
            onPressed: () => Navigator.of(context).pop(r),
            child: Text(l10n.t('Common.Confirm', '确定')),
          ),
      ],
    );
  }

  Widget _buildResult(
    BuildContext context,
    L10n l10n,
    OneClickNovelGenerationResult r,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 行文本 + 可选的查看产物（功能 B：大纲/首章文本内存直通，点「查看」可读全文）
    final List<(String, String?)> lines = <(String, String?)>[];

    if (r.projectCreated) {
      lines.add((
        l10n
            .tf('OCG.ResultCreatedFmt', '新书《{0}》已创建并出现在左侧导航。',
                <Object>[r.bookTitle])
            .trim(),
        null,
      ));
      lines.add((
        l10n.tf('OCG.ResultGenreFmt', '类型：{0}', <Object>[r.genre]).trim(),
        null,
      ));
      lines.add((
        l10n.tf('OCG.ResultPremiseFmt', '简介：{0}', <Object>[r.premise]).trim(),
        null,
      ));
    }

    lines.add((
      r.outlineSaved
          ? l10n.t('OCG.ResultOutlineSaved', '大纲：已由双 Agent 生成，并写入剧情库（主线）。')
          : (r.outlineGenerated
              ? l10n.t('OCG.ResultOutlineArchiveFail',
                  '大纲：已生成并归档，但写入剧情库失败（见日志）。')
              : l10n.t('OCG.ResultOutlineFail', '大纲：生成失败（见日志）。')),
      r.outlineText.trim().isEmpty ? null : r.outlineText,
    ));

    lines.add((
      r.chapterSaved
          ? l10n.t('OCG.ResultChapterSaved', '第一章：已由双 Agent 生成，并写入章节库（第一卷）。')
          : (r.chapterGenerated
              ? l10n.t('OCG.ResultChapterArchiveFail',
                  '第一章：已生成并归档，但写入章节库失败（见日志）。')
              : l10n.t('OCG.ResultChapterFail', '第一章：生成失败（见日志）。')),
      r.chapterText.trim().isEmpty ? null : r.chapterText,
    ));

    if (r.projectCreated) {
      lines.add((
        r.prerequisitesGenerated
            ? l10n.t('OCG.ResultPrereqSaved',
                '角色 / 世界设定 / 势力：已自动生成并写入对应模块。')
            : l10n.t('OCG.ResultPrereqFail',
                '角色 / 世界设定 / 势力：生成失败（见日志），可在「前置条件生成」中重试。'),
        null,
      ));
    }

    // 章节联动同步：由 ChapterPostProcessService 决定是否执行（可在 AI 配置页开关）
    lines.add((
      r.linkageApplied
          ? l10n.t('OCG.ResultLinkDone', '联动同步：已按本章内容更新人物 / 剧情 / 世界观记录。')
          : l10n.t('OCG.ResultLinkPending',
              '联动更新：章节联动同步未执行（未开启或未产生可用结果，可在 AI 配置页开启）。'),
      null,
    ));

    return Column(
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
                r.isSuccess
                    ? l10n.t('MW.OneClickDone', '一键生成完成')
                    : l10n.tf('MW.OneClickFailed', '一键生成失败：{0}', <Object>[r.message]),
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
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Text('· ${line.$1}',
                      style: const TextStyle(fontSize: 12)),
                ),
                if (line.$2 != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: const Icon(Icons.chrome_reader_mode_outlined,
                        size: 14),
                    label: Text(l10n.t('OCG.ViewOutput', '查看'),
                        style: const TextStyle(fontSize: 12)),
                    onPressed: () => _viewOutput(context, l10n, line.$1, line.$2!),
                  ),
              ],
            ),
          ),
        if (r.warnings.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            l10n.t('PG.FailedTitle', '生成失败'),
            style: TextStyle(fontSize: 12, color: scheme.error),
          ),
          for (final String w in r.warnings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text('· $w',
                  style: TextStyle(fontSize: 11, color: scheme.error)),
            ),
        ],
      ],
    );
  }

  /// 功能 B：全屏只读查看本次生成的产物文本（大纲 / 首章）。
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