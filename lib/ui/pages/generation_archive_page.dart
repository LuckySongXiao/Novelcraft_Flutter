import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/project_content_archive_service.dart';
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
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(_iconFor(e.taskType), color: scheme.primary),
                  title: Text(
                    e.title.trim().isNotEmpty
                        ? e.title
                        : _taskTypeLabel(e.taskType, l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_taskTypeLabel(e.taskType, l10n)} · ${e.characterCount} 字 · '
                    '${DateTime.fromMillisecondsSinceEpoch(e.createdAtMs).toString().substring(0, 19)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: e.metadata.isEmpty
                      ? null
                      : Badge(
                          label: Text('${e.metadata.length}'),
                          backgroundColor: scheme.secondaryContainer,
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
        _ => taskType.isEmpty
            ? l10n.t('GAP.TaskType.Unknown', '未命名任务')
            : taskType,
      };
}

/// 归档详情：定稿正文 + 过程数据（需求简报 / MainDraft 等元数据）。
class _ArchiveDetailPage extends ConsumerWidget {
  const _ArchiveDetailPage({required this.entry});

  final ProjectArchiveEntry entry;

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
        _ => taskType.isEmpty
            ? l10n.t('GAP.TaskType.Unknown', '未命名任务')
            : taskType,
      };

  String _metaKeyLabel(String key, L10n l10n) => switch (key) {
        'RequirementBrief' => l10n.t('GAP.Meta.RequirementBrief', '需求简报（SubAgent）'),
        'MainDraft' => l10n.t('GAP.Meta.MainDraft', '初稿（MainAgent）'),
        'WorkflowMode' => l10n.t('GAP.Meta.WorkflowMode', '工作流模式'),
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
