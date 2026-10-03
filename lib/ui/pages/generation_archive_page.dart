import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/project_content_archive_service.dart';
import '../../application/services/writing_archive_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';
import '../widgets/readonly_prose_view.dart';

/// 写作过程档案页（功能 B）—— 双 Tab：
///   Tab1「生成档案」：ProjectContentArchiveService（scope=project_archive）
///     的历史归档——双 Agent 需求简报 / MainDraft / 定稿都在条目 metadata 里，
///     此前只写不读；这里是首个读取入口。
///   Tab2「大纲」：Plots(type='主线').outline 只读阅读。
class GenerationArchivePage extends ConsumerStatefulWidget {
  const GenerationArchivePage({super.key});

  @override
  ConsumerState<GenerationArchivePage> createState() =>
      _GenerationArchivePageState();
}

class _GenerationArchivePageState extends ConsumerState<GenerationArchivePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: l10n.t('GAP.TabArchive', '生成档案')),
              Tab(text: l10n.t('GAP.TabOutline', '大纲')),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: const [_ArchiveTab(), _OutlineTab()],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab1：生成档案
// ---------------------------------------------------------------------------

class _ArchiveTab extends ConsumerStatefulWidget {
  const _ArchiveTab();

  @override
  ConsumerState<_ArchiveTab> createState() => _ArchiveTabState();
}

class _ArchiveTabState extends ConsumerState<_ArchiveTab> {
  List<ProjectArchiveEntry>? _entries;
  String? _error;

  /// 档案级别筛选：all / project / volume / chapter。
  String _levelFilter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final projectId = ref.read(currentProjectIdProvider);
    if (projectId == null) {
      setState(() {
        _entries = const [];
        _error = null;
      });
      return;
    }
    try {
      final svc = ref.read(projectContentArchiveProvider);
      final entries = await svc.listEntries(projectId);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final projectId = ref.watch(currentProjectIdProvider);

    if (projectId == null) {
      return const _NoProjectHint();
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 44, color: scheme.outline),
            const SizedBox(height: 10),
            Text(l10n.tf('GAP.ArchiveFailed', '归档读取失败：{0}', [_error!])),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _load, child: Text(l10n.t('Common.Refresh', '刷新'))),
          ],
        ),
      );
    }
    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 44, color: scheme.outline),
            const SizedBox(height: 10),
            Text(l10n.t('GAP.Empty', '暂无归档内容：跑一次生成 / 改写后，产物会自动归档到这里')),
          ],
        ),
      );
    }
    final List<ProjectArchiveEntry> visible = _levelFilter == 'all'
        ? entries
        : entries
            .where((ProjectArchiveEntry e) =>
                (e.metadata[ArchiveDescription.kLevel] ?? '') == _levelFilter)
            .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Text(l10n.tf('GAP.CountFmt', '共 {0} 条（新→旧，保留最近 200 条）',
                  [entries.length]),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(l10n.t('Common.Refresh', '刷新')),
                onPressed: _load,
              ),
            ],
          ),
        ),
        // 档案级别筛选：项目 / 分卷 / 章节
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Wrap(
            spacing: 6,
            children: <Widget>[
              for (final (String key, String label) in <(String, String)>[
                ('all', l10n.t('GAP.Level.All', '全部')),
                ('project', l10n.t('GAP.Level.Project', '项目档案')),
                ('volume', l10n.t('GAP.Level.Volume', '分卷档案')),
                ('chapter', l10n.t('GAP.Level.Chapter', '章节档案')),
              ])
                ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: _levelFilter == key,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _levelFilter = key),
                ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    l10n.t('GAP.Level.Empty', '该级别暂无档案'),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final e = visible[i];
                    final String level =
                        e.metadata[ArchiveDescription.kLevel] ?? '';
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          level.isNotEmpty
                              ? _levelIcon(level)
                              : _iconFor(e.taskType),
                          color: scheme.primary,
                        ),
                        title: Text(
                          e.title.trim().isNotEmpty
                              ? e.title
                              : _taskTypeLabel(e.taskType, l10n),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${level.isNotEmpty ? _levelLabel(level, l10n) : _taskTypeLabel(e.taskType, l10n)}'
                          ' · ${e.characterCount} 字 · '
                          '${DateTime.fromMillisecondsSinceEpoch(e.createdAtMs).toString().substring(0, 19)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (e.metadata.isNotEmpty)
                              Badge(
                                label: Text('${e.metadata.length}'),
                                backgroundColor: scheme.secondaryContainer,
                              ),
                            // 手动删减 / 修改：下标以完整 entries 为准
                            //（visible 只是筛选后的子集）。
                            PopupMenuButton<String>(
                              tooltip: l10n.t('Common.More', '更多'),
                              onSelected: (String v) {
                                final int idx = entries.indexOf(e);
                                if (idx < 0) return;
                                if (v == 'edit') {
                                  _editEntry(e, idx);
                                } else if (v == 'delete') {
                                  _deleteEntry(e, idx);
                                }
                              },
                              itemBuilder: (BuildContext ctx) =>
                                  <PopupMenuEntry<String>>[
                                PopupMenuItem<String>(
                                  value: 'edit',
                                  child: Text(l10n.t('Common.Edit', '修改')),
                                ),
                                PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Text(l10n.t('Common.Delete', '删除')),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () => _openDetail(e),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _levelLabel(String level, L10n l10n) => switch (level) {
        ArchiveLevel.project => l10n.t('GAP.Level.Project', '项目档案'),
        ArchiveLevel.volume => l10n.t('GAP.Level.Volume', '分卷档案'),
        ArchiveLevel.chapter => l10n.t('GAP.Level.Chapter', '章节档案'),
        _ => level,
      };

  IconData _levelIcon(String level) => switch (level) {
        ArchiveLevel.project => Icons.folder_special_outlined,
        ArchiveLevel.volume => Icons.menu_book_outlined,
        ArchiveLevel.chapter => Icons.article_outlined,
        _ => Icons.description_outlined,
      };

  /// 手动修改一条档案的标题 / 正文。
  Future<void> _editEntry(ProjectArchiveEntry e, int index) async {
    final l10n = ref.read(l10nProvider);
    final TextEditingController titleCtl =
        TextEditingController(text: e.title);
    final TextEditingController contentCtl =
        TextEditingController(text: e.content);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('GAP.Edit.Title', '修改档案')),
        content: SizedBox(
          width: 680,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: titleCtl,
                decoration: InputDecoration(
                  labelText: l10n.t('GAP.Edit.EntryTitle', '标题'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: TextField(
                  controller: contentCtl,
                  maxLines: null,
                  minLines: 10,
                  decoration: InputDecoration(
                    labelText: l10n.t('GAP.Edit.Content', '正文'),
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.t('Common.Save', '保存')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final String pid = ref.read(currentProjectIdProvider) ?? '';
    final bool done = await ref
        .read(projectContentArchiveProvider)
        .updateEntry(pid, index, title: titleCtl.text, content: contentCtl.text);
    if (!mounted) return;
    if (done) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.t('GAP.Edit.Saved', '已保存修改')),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.error,
        content: Text(l10n.t('GAP.Edit.Failed', '修改失败：未找到该档案或写入失败')),
      ));
    }
  }

  /// 手动删除一条档案（不可恢复，需二次确认）。
  Future<void> _deleteEntry(ProjectArchiveEntry e, int index) async {
    final l10n = ref.read(l10nProvider);
    final String name = e.title.trim().isNotEmpty ? e.title : e.taskType;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('Common.Delete', '删除')),
        content: Text(l10n.tf(
          'GAP.Delete.Confirm',
          '确定删除这条档案吗？此操作不可恢复。\n\n{0}',
          <Object>[name.length > 40 ? '${name.substring(0, 40)}…' : name],
        )),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.t('Common.Delete', '删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final String pid = ref.read(currentProjectIdProvider) ?? '';
    final bool done =
        await ref.read(projectContentArchiveProvider).deleteEntry(pid, index);
    if (!mounted) return;
    if (done) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.t('GAP.Delete.Done', '已删除该档案')),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.error,
        content: Text(l10n.t('GAP.Delete.Failed', '删除失败：未找到该档案或写入失败')),
      ));
    }
  }

  void _openDetail(ProjectArchiveEntry e) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _ArchiveDetailPage(entry: e)),
    );
  }

  IconData _iconFor(String taskType) => switch (taskType) {
        'GenerateOutline' => Icons.account_tree_outlined,
        'GenerateChapterContent' => Icons.menu_book_outlined,
        'ReviseChapter' => Icons.auto_fix_high_outlined,
        _ => Icons.description_outlined,
      };

  String _taskTypeLabel(String taskType, L10n l10n) => switch (taskType) {
        'GenerateOutline' => l10n.t('GAP.TaskType.GenerateOutline', '主线大纲'),
        'GenerateChapterContent' =>
          l10n.t('GAP.TaskType.GenerateChapterContent', '章节生成'),
        'ReviseChapter' => l10n.t('GAP.TaskType.ReviseChapter', '章节改写'),
        'ArchiveProject' => l10n.t('GAP.Level.Project', '项目档案'),
        'ArchiveVolume' => l10n.t('GAP.Level.Volume', '分卷档案'),
        'ArchiveChapter' => l10n.t('GAP.Level.Chapter', '章节档案'),
        _ => taskType.isEmpty
            ? l10n.t('GAP.TaskType.Unknown', '未命名任务')
            : taskType,
      };
}

/// 归档详情：定稿正文 + 过程数据（需求简报 / MainDraft 等元数据）。
class _ArchiveDetailPage extends ConsumerWidget {
  const _ArchiveDetailPage({required this.entry});

  final ProjectArchiveEntry entry;

  /// 结构化四段描述（level 档案才有；缺省为 null）。
  ArchiveDescription? get _desc {
    final String level = entry.metadata[ArchiveDescription.kLevel] ?? '';
    if (level.isEmpty) return null;
    return ArchiveDescription.fromMetadata(entry.metadata);
  }

  Widget _descRow(String label, String value, ColorScheme scheme) {
    final String v = value.trim().isEmpty ? '—' : value.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(v,
                style: const TextStyle(fontSize: 12, height: 1.5)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          entry.title.trim().isNotEmpty ? entry.title : entry.taskType,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${_taskTypeLabel(entry.taskType, l10n)} · ${entry.characterCount} 字 · '
            '${DateTime.fromMillisecondsSinceEpoch(entry.createdAtMs).toString().substring(0, 19)}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          // 档案描述（四段固定格式：时间范围+主题任务+得失总结+规避措施）
          if (_desc != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.30),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.t('GAP.Desc.Title', '档案描述'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _descRow(l10n.t('GAP.Desc.TimeRange', '时间范围'),
                      _desc!.timeRange, scheme),
                  _descRow(l10n.t('GAP.Desc.ThemeTask', '主题任务'),
                      _desc!.themeTask, scheme),
                  _descRow(l10n.t('GAP.Desc.GainsLosses', '得失总结'),
                      _desc!.gainsLosses, scheme),
                  _descRow(l10n.t('GAP.Desc.Safeguards', '规避措施'),
                      _desc!.safeguards, scheme),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          ReadonlyProseView(content: entry.content),
          if (entry.metadata.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              l10n.t('GAP.ProcessData', '过程数据（写作中间产物）'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            for (final MapEntry<String, String> m in entry.metadata.entries)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(Icons.science_outlined,
                      size: 20, color: scheme.primary),
                  title: Text(_metaKeyLabel(m.key, l10n),
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Builder(builder: (BuildContext sub) {
                    final String v = m.value.trim();
                    return Text(
                      v.isEmpty
                          ? l10n.t('GAP.EmptyMeta', '（空）')
                          : (v.length > 60 ? '${v.substring(0, 60)}…' : v),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    );
                  }),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _showMetaValue(context, l10n, m.key, m.value),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _showMetaValue(
      BuildContext context, L10n l10n, String key, String value) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(_metaKeyLabel(key, l10n))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ReadonlyProseView(content: value, fontSize: 15),
            ],
          ),
        ),
      ),
    );
  }

  String _taskTypeLabel(String taskType, L10n l10n) => switch (taskType) {
        'GenerateOutline' => l10n.t('GAP.TaskType.GenerateOutline', '主线大纲'),
        'GenerateChapterContent' =>
          l10n.t('GAP.TaskType.GenerateChapterContent', '章节生成'),
        'ReviseChapter' => l10n.t('GAP.TaskType.ReviseChapter', '章节改写'),
        'ArchiveProject' => l10n.t('GAP.Level.Project', '项目档案'),
        'ArchiveVolume' => l10n.t('GAP.Level.Volume', '分卷档案'),
        'ArchiveChapter' => l10n.t('GAP.Level.Chapter', '章节档案'),
        _ => taskType.isEmpty
            ? l10n.t('GAP.TaskType.Unknown', '未命名任务')
            : taskType,
      };

  String _metaKeyLabel(String key, L10n l10n) => switch (key) {
        'RequirementBrief' => l10n.t('GAP.Meta.RequirementBrief', '需求简报（SubAgent）'),
        'MainDraft' => l10n.t('GAP.Meta.MainDraft', '初稿（MainAgent）'),
        'WorkflowMode' => l10n.t('GAP.Meta.WorkflowMode', '工作流模式'),
        'timeRange' => l10n.t('GAP.Desc.TimeRange', '时间范围'),
        'themeTask' => l10n.t('GAP.Desc.ThemeTask', '主题任务'),
        'gainsLosses' => l10n.t('GAP.Desc.GainsLosses', '得失总结'),
        'safeguards' => l10n.t('GAP.Desc.Safeguards', '规避措施'),
        'level' => l10n.t('GAP.Meta.Level', '档案级别'),
        'volumeId' => l10n.t('GAP.Meta.VolumeId', '分卷 ID'),
        'chapterId' => l10n.t('GAP.Meta.ChapterId', '章节 ID'),
        _ => key,
      };
}

// ---------------------------------------------------------------------------
// Tab2：大纲（Plots type='主线'）
// ---------------------------------------------------------------------------

class _OutlineTab extends ConsumerStatefulWidget {
  const _OutlineTab();

  @override
  ConsumerState<_OutlineTab> createState() => _OutlineTabState();
}

class _OutlineTabState extends ConsumerState<_OutlineTab> {
  List<PlotOutlineItem>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final projectId = ref.read(currentProjectIdProvider);
    if (projectId == null) {
      setState(() {
        _items = const [];
        _error = null;
      });
      return;
    }
    try {
      final repo = ref.read(plotRepositoryProvider);
      final plots = await repo.getByType(projectId, '主线');
      if (!mounted) return;
      setState(() {
        _items = [
          for (final p in plots)
            PlotOutlineItem(
              title: p.title,
              status: p.status,
              progress: p.progress,
              outline: p.outline ?? '',
            ),
        ];
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final projectId = ref.watch(currentProjectIdProvider);

    if (projectId == null) return const _NoProjectHint();
    if (_error != null) {
      return Center(child: Text(l10n.tf('GAP.OutlineFailed', '大纲读取失败：{0}', [_error!])));
    }
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_tree_outlined, size: 44, color: scheme.outline),
            const SizedBox(height: 10),
            Text(l10n.t('GAP.NoOutline', '暂无主线大纲：一键生成书籍或剧情管理中可产生')),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(it.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    if (it.status.isNotEmpty)
                      Chip(
                        label: Text(it.status,
                            style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (it.outline.trim().isEmpty)
                  Text(l10n.t('GAP.NoOutline', '暂无主线大纲'),
                      style: TextStyle(color: scheme.onSurfaceVariant))
                else
                  ReadonlyProseView(content: it.outline, fontSize: 14),
              ],
            ),
          ),
        );
      },
    );
  }
}

class PlotOutlineItem {
  const PlotOutlineItem({
    required this.title,
    required this.status,
    required this.progress,
    required this.outline,
  });

  final String title;
  final String status;
  final double progress;
  final String outline;
}

class _NoProjectHint extends ConsumerWidget {
  const _NoProjectHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off_outlined, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(l10n.t('Common.PleaseSelectProjectFirst', '请先在「项目管理」中选择一个项目')),
        ],
      ),
    );
  }
}
