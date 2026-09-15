// drift 的 Column 与 Flutter 的 Column 同名，必须加前缀避免歧义
import 'package:drift/drift.dart' as d;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/di.dart';
import '../../data/database.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';

String _projectTypeLabel(String v, L10n l10n) => switch (v) {
      '玄幻' => l10n.t('PM.Type.Xuanhuan', '玄幻'),
      '都市' => l10n.t('PM.Type.Urban', '都市'),
      '科幻' => l10n.t('PM.Type.SciFi', '科幻'),
      '历史' => l10n.t('PM.Type.History', '历史'),
      '其他' => l10n.t('PM.Type.Other', '其他'),
      _ => v,
    };

/// 项目列表 —— 对应 C# Views/ProjectManagementView.xaml（757 行）
///
/// 数据源直接走 drift 的 `watch()` 流：C# 版每次导航回页面都要重新查库并手动刷新 UI，
/// Dart 侧由 Stream 自动驱动重建。
final projectsStreamProvider = StreamProvider<List<ProjectRow>>((ref) {
  return ref.watch(projectRepositoryProvider).watchAll();
});

class ProjectManagementPage extends ConsumerWidget {
  const ProjectManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final projectsAsync = ref.watch(projectsStreamProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: projectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(l10n.tf('Common.LoadFailed', '加载失败：{0}', [e.toString()]))),
        data: (projects) {
          if (projects.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open, size: 64, color: scheme.outline),
                  const SizedBox(height: 12),
                  Text(l10n.t('PM.Empty', '还没有项目，点击右下角新建')),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: projects.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) =>
                _ProjectCard(project: projects[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.t('PM.NewProject', '新建项目')),
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    String type = '玄幻';
    final l10n = ref.read(l10nProvider);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, dref, _) {
          final dl10n = dref.watch(l10nProvider);
          return AlertDialog(
            title: Text(dl10n.t('PM.NewProject', '新建项目')),
            content: SizedBox(
              width: 420,
              child: StatefulBuilder(
                builder: (ctx, setSt) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(
                        labelText: dl10n.t('PM.Name', '项目名称'),
                      ),
                      autofocus: true,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      decoration: InputDecoration(
                        labelText: dl10n.t('PM.Description', '项目描述'),
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: type,
                      decoration: InputDecoration(
                        labelText: dl10n.t('PM.Type', '项目类型'),
                      ),
                      items: [
                        for (final v in const ['玄幻', '都市', '科幻', '历史', '其他'])
                          DropdownMenuItem(value: v, child: Text(_projectTypeLabel(v, dl10n))),
                      ],
                      onChanged: (v) => setSt(() => type = v ?? type),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(dl10n.t('Common.Cancel', '取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(dl10n.t('Common.Create', '创建')),
              ),
            ],
          );
        },
      ),
    );

    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;

    try {
      await ref.read(projectRepositoryProvider).create(
            ProjectsCompanion.insert(
              id: const Uuid().v4(),
              name: name,
              type: type,
              description: d.Value(
                descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
              ),
            ),
          );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('PM.CreateFailed', '创建失败：{0}', [e.toString()]))),
        );
      }
    }
  }
}

/// 项目卡片
class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({required this.project});

  final ProjectRow project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text(
            project.name.isNotEmpty ? project.name.characters.first : '?',
            style: TextStyle(color: scheme.onPrimaryContainer),
          ),
        ),
        title: Text(project.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (project.description != null &&
                project.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  project.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Chip(
                  label: Text(_projectTypeLabel(project.type, l10n), style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
                const SizedBox(width: 8),
                Text(
                  '${l10n.t('PM.Progress', '进度')} ${project.progress}%',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            final repo = ref.read(projectRepositoryProvider);
            if (v == 'open') {
              ref.read(currentProjectIdProvider.notifier).select(project.id);
              ref.read(navigationProvider.notifier).navigateTo(
                    NavigationTarget.projectOverview,
                    context: NavigationContext(
                      projectId: project.id,
                      projectName: project.name,
                    ),
                  );
            } else if (v == 'delete') {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(l10n.t('Common.Delete', '删除')),
                  content: Text(
                    l10n.tf(
                      'Common.DeleteConfirm',
                      '确定删除「{0}」吗？此操作不可恢复。',
                      [project.name],
                    ),
                  ),
                  actions: [
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
              if (ok == true) await repo.delete(project.id);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'open',
              child: Text(l10n.t('PM.Open', '打开')),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text(l10n.t('Common.Delete', '删除')),
            ),
          ],
        ),
        onTap: () {
          ref.read(currentProjectIdProvider.notifier).select(project.id);
          ref.read(navigationProvider.notifier).navigateTo(
                NavigationTarget.projectOverview,
                context: NavigationContext(
                  projectId: project.id,
                  projectName: project.name,
                ),
              );
        },
      ),
    );
  }
}
