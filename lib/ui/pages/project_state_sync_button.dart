import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/services/chapter_sync_service.dart';
import '../../core/di.dart';

/// Explicit repair entry for books generated before structured state sync.
class ProjectStateSyncButton extends ConsumerStatefulWidget {
  const ProjectStateSyncButton({super.key, required this.projectId, required this.onDone});
  final String projectId;
  final VoidCallback onDone;
  @override
  ConsumerState<ProjectStateSyncButton> createState() => _ProjectStateSyncButtonState();
}

class _ProjectStateSyncButtonState extends ConsumerState<ProjectStateSyncButton> {
  bool _running = false;
  String _note = '';

  Future<void> _run() async {
    if (_running) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从已完成章节补同步设定'),
        content: const Text('将按卷章顺序读取已完成正文，调用 MainAgent 抽取人物与各类设定，'
            '新增有正文依据的档案并追加履历。会消耗模型调用；正文不会修改。'
            '失败项保留重试机会，已成功且未变化的章节跳过。请先启用 AI 状态抽取。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始同步')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() { _running = true; _note = '正在读取章节…'; });
    try {
      final post = ref.read(chapterPostProcessServiceProvider);
      if (!await post.aiEnabled()) throw StateError('请先到 AI 配置启用 AI 状态抽取');
      final volumes = await ref.read(volumeRepositoryProvider).getByProjectId(widget.projectId);
      volumes.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      var applied = 0, skipped = 0, failed = 0;
      for (final volume in volumes) {
        final chapters = await ref.read(chapterRepositoryProvider).getByVolumeId(volume.id);
        chapters.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
        for (final chapter in chapters) {
          if (!mounted) return;
          if (chapter.status != 'Completed' || (chapter.content ?? '').trim().isEmpty) {
            skipped++;
            continue;
          }
          setState(() => _note = '同步《${chapter.title}》…');
          final result = await post.runForChapter(ChapterSyncInput(
            chapterId: chapter.id, volumeId: volume.id, projectId: widget.projectId,
            title: chapter.title, orderIndex: chapter.orderIndex,
            content: chapter.content!, summary: chapter.summary,
            status: chapter.status, versionNumber: chapter.versionNumber,
          ));
          if (result.aiApplied) {
            applied++;
          } else if (result.skippedReason == 'alreadySynced') {
            skipped++;
          } else {
            failed++;
          }
        }
      }
      if (mounted) setState(() => _note = '同步完成：成功 $applied 章，跳过 $skipped 章，失败 $failed 章。');
    } on Object catch (e) {
      if (mounted) setState(() => _note = '同步未完成：$e');
    } finally {
      if (mounted) {
        setState(() => _running = false);
        widget.onDone();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton.icon(
        onPressed: _running ? null : _run,
        icon: const Icon(Icons.sync),
        label: Text(_running ? '正在同步设定…' : '从已完成章节补同步人物与设定'),
      ),
      if (_note.isNotEmpty) Text(_note),
    ],
  );
}
