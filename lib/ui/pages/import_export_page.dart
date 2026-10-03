import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/epub_export_service.dart';
import '../../application/services/import_id_remapper.dart';
import '../../application/services/project_folder_export_service.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';
import 'entity_configs.dart' show entityConfigByTarget;
import 'entity_page.dart' show EntityPageConfig;

/// 导入导出页 —— 对应 C# 的「数据备份 / 恢复」
///
/// 复用 [entityConfigByTarget] 里现成的数据源（每个实体都提供 `list` / `create`），
/// 把当前项目下全部 19 类数据库实体导出为一个 JSON 文件；导入时按相同结构回写。
/// 这样无需为每个实体单独写序列化逻辑——新增实体页只需补配置即可自动纳入备份。
class ImportExportPage extends ConsumerStatefulWidget {
  const ImportExportPage({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ImportExportPage> createState() => _ImportExportPageState();
}

class _ImportExportPageState extends ConsumerState<ImportExportPage> {
  bool _busy = false;
  String _statusKey = '';
  List<Object> _statusArgs = const [];

  /// 文件夹组导出格式：true = Markdown(.md)，false = 纯文本(.txt)
  bool _folderMarkdown = true;

  /// 正文单文件导出格式：true = Markdown(.md)，false = 纯文本(.txt)
  bool _docMarkdown = true;

  /// 手动导出：把整个项目正文导出为**单个** .md / .txt 文件。
  ///
  /// 背景：`ChapterExportService` 的章节导出是批次写作时的**自动**落盘
  ///（Markdown + JSON 过程档案，写在 `%APPDATA%\NovelManagement\exports`），
  /// 界面上既看不到也没有入口；这里补一个可见的手动导出，按「卷 → 章」
  /// 顺序把正文合并成一份可直接阅读 / 投稿 / 打印的文稿。
  Future<void> _exportWholeBook() async {
    final l10n = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _statusKey = 'IE.DocExporting';
      _statusArgs = const <Object>[];
    });
    try {
      final String pid = widget.projectId;
      final project = await ref.read(projectServiceProvider).getById(pid);
      final String bookTitle = project?.name ?? pid;

      final List<dynamic> volumes =
          await ref.read(volumeServiceProvider).getByProjectId(pid);
      final List<dynamic> chapters =
          await ref.read(chapterServiceProvider).getByProjectId(pid);

      int byOrder(dynamic a, dynamic b) =>
          ((a.orderIndex as num?)?.toInt() ?? 0)
              .compareTo((b.orderIndex as num?)?.toInt() ?? 0);

      final List<dynamic> sortedVolumes = List<dynamic>.of(volumes)..sort(byOrder);
      final bool md = _docMarkdown;
      final StringBuffer sb = StringBuffer();
      sb.writeln(md ? '# $bookTitle' : bookTitle);
      sb.writeln();

      int chapterCount = 0;
      void writeChapter(dynamic c) {
        final String body = ((c.content as String?) ?? '').trim();
        if (body.isEmpty) return;
        chapterCount++;
        sb.writeln(md ? '### ${c.title}' : '${c.title}');
        sb.writeln();
        sb.writeln(body);
        sb.writeln();
      }

      final Set<Object?> covered = <Object?>{};
      for (final dynamic v in sortedVolumes) {
        final List<dynamic> inVol = chapters
            .where((dynamic c) => c.volumeId == v.id)
            .toList()
          ..sort(byOrder);
        if (inVol.isEmpty) continue;
        sb.writeln(md ? '## ${v.title}' : '【${v.title}】');
        sb.writeln();
        for (final dynamic c in inVol) {
          covered.add(c.id);
          writeChapter(c);
        }
      }
      // 兜底：不属于任何分卷的章节（volumeId 空）也要导出
      for (final dynamic c in chapters) {
        if (covered.contains(c.id)) continue;
        writeChapter(c);
      }

      final String text = sb.toString();
      if (chapterCount == 0) {
        setState(() {
          _statusKey = 'IE.DocEmpty';
          _statusArgs = const <Object>[];
        });
        return;
      }
      final String ext = md ? 'md' : 'txt';
      final Uri? target = await FilePicker.saveFile(
        dialogTitle: l10n.t('IE.DocPicking', '选择保存位置'),
        fileName: '$bookTitle.$ext',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (target == null) {
        setState(() {
          _statusKey = 'IE.ExportCancelled';
          _statusArgs = const <Object>[];
        });
        return;
      }
      final String path =
          target.scheme == 'file' ? target.toFilePath() : '$target';
      setState(() {
        _statusKey = 'IE.DocDone';
        _statusArgs = <Object>[
          chapterCount.toString(),
          text.length.toString(),
          path,
        ];
      });
    } catch (e) {
      setState(() {
        _statusKey = 'IE.ExportFailed';
        _statusArgs = <Object>[e.toString()];
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _exportEpub() async {
    final l10n = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _statusKey = 'IE.EpubExporting';
      _statusArgs = const <Object>[];
    });
    try {
      final String pid = widget.projectId;
      final project = await ref.read(projectServiceProvider).getById(pid);
      final String bookTitle = project?.name ?? pid;
      final List<dynamic> volumes =
          await ref.read(volumeServiceProvider).getByProjectId(pid);
      final List<dynamic> chapters =
          await ref.read(chapterServiceProvider).getByProjectId(pid);
      int byOrder(dynamic a, dynamic b) =>
          ((a.orderIndex as num?)?.toInt() ?? 0)
              .compareTo((b.orderIndex as num?)?.toInt() ?? 0);
      final List<dynamic> sortedVolumes = List<dynamic>.of(volumes)..sort(byOrder);
      final List<EpubChapter> epubChapters = <EpubChapter>[];
      final Set<Object?> covered = <Object?>{};
      void addChapter(dynamic chapter, String volumeTitle) {
        final String content = ((chapter.content as String?) ?? '').trim();
        if (content.isEmpty) return;
        epubChapters.add(EpubChapter(
          title: (chapter.title as String?)?.trim().isEmpty == false
              ? chapter.title as String
              : '第 ${epubChapters.length + 1} 章',
          content: content,
          volumeTitle: volumeTitle,
          order: (chapter.orderIndex as num?)?.toInt() ?? 0,
        ));
      }

      for (final dynamic volume in sortedVolumes) {
        final List<dynamic> inVolume = chapters
            .where((dynamic chapter) => chapter.volumeId == volume.id)
            .toList()
          ..sort(byOrder);
        for (final dynamic chapter in inVolume) {
          covered.add(chapter.id);
          addChapter(chapter, (volume.title as String?) ?? '');
        }
      }
      final List<dynamic> unassigned = chapters
          .where((dynamic chapter) => !covered.contains(chapter.id))
          .toList()
        ..sort(byOrder);
      for (final dynamic chapter in unassigned) {
        addChapter(chapter, '');
      }
      if (epubChapters.isEmpty) {
        setState(() {
          _statusKey = 'IE.DocEmpty';
          _statusArgs = const <Object>[];
        });
        return;
      }
      final Uint8List bytes = Uint8List.fromList(EpubExportService.build(EpubExportInput(
        title: bookTitle,
        author: '',
        chapters: epubChapters,
        identifier: 'urn:novelcraft:$pid',
      )));
      final Uri? target = await FilePicker.saveFile(
        dialogTitle: l10n.t('IE.EpubPicking', '选择 EPUB 保存位置'),
        fileName: '$bookTitle.epub',
        bytes: Uint8List.fromList(bytes),
      );
      if (target == null) {
        setState(() {
          _statusKey = 'IE.ExportCancelled';
          _statusArgs = const <Object>[];
        });
        return;
      }
      final String path = target.scheme == 'file' ? target.toFilePath() : '$target';
      setState(() {
        _statusKey = 'IE.EpubDone';
        _statusArgs = <Object>[epubChapters.length.toString(), path];
      });
    } catch (e) {
      setState(() {
        _statusKey = 'IE.ExportFailed';
        _statusArgs = <Object>[e.toString()];
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  /// 结构化文件夹组导出：项目 → 目录树（卷宗/章节/全部实体）。
  Future<void> _exportFolder() async {
    final l10n = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _statusKey = 'IE.FolderExporting';
      _statusArgs = [];
    });
    try {
      final String? dir = await FilePicker.getDirectoryPath(
        dialogTitle: l10n.t('IE.FolderPicking', '选择导出位置'),
      );
      if (dir == null) {
        setState(() {
          _statusKey = 'IE.ExportCancelled';
          _statusArgs = [];
        });
        return;
      }
      final String pid = widget.projectId;

      // ---- 取数：项目 / 卷宗 / 章节 ----
      final project = await ref.read(projectServiceProvider).getById(pid);
      final List<Map<String, dynamic>> volumes =
          (await ref.read(volumeServiceProvider).getByProjectId(pid))
              .map<Map<String, dynamic>>((dynamic v) => <String, dynamic>{
                    'id': v.id,
                    'title': v.title,
                    'description': v.description,
                    'orderIndex': v.orderIndex,
                    'status': v.status,
                    'type': v.type,
                    'tags': v.tags,
                    'notes': v.notes,
                  })
              .toList()
                ..sort((a, b) => ((a['orderIndex'] as num?)?.toInt() ?? 0)
                    .compareTo((b['orderIndex'] as num?)?.toInt() ?? 0));
      final List<Map<String, dynamic>> chapters =
          (await ref.read(chapterServiceProvider).getByProjectId(pid))
              .map<Map<String, dynamic>>((dynamic c) => <String, dynamic>{
                    'volumeId': c.volumeId,
                    'title': c.title,
                    'orderIndex': c.orderIndex,
                    'content': c.content,
                    'summary': c.summary,
                    'status': c.status,
                    'type': c.type,
                    'wordCount': c.wordCount,
                    'versionNumber': c.versionNumber,
                    'notes': c.notes,
                  })
              .toList();

      // ---- 其余实体：复用 entityConfigByTarget 通用映射 ----
      final Map<String, EntityExportGroup> extras =
          <String, EntityExportGroup>{};
      for (final MapEntry<NavigationTarget, EntityPageConfig> e
          in entityConfigByTarget.entries) {
        if (e.key == NavigationTarget.volumeManagement ||
            e.key == NavigationTarget.chapterManagement) {
          continue;
        }
        final ds = e.value.sourceBuilder(ref);
        extras[e.key.name] = EntityExportGroup(
          nameField: e.value.nameField,
          records: await ds.list(pid),
        );
      }

      final input = ProjectFolderExportInput(
        projectName: project?.name ?? pid,
        projectFields: project == null
            ? <String, dynamic>{}
            : <String, dynamic>{
                'name': project.name,
                'description': project.description,
                'type': project.type,
                'status': project.status,
                'tags': project.tags,
                'priority': project.priority,
                'progress': project.progress,
                'notes': project.notes,
              },
        volumes: volumes,
        chapters: chapters,
        extraEntities: extras,
      );

      final Map<String, String> files =
          ProjectFolderExporter.buildFileTree(input, markdown: _folderMarkdown);
      final String root = await ProjectFolderExporter.writeTree(
        destDir: dir,
        rootName: input.projectName,
        files: files,
      );
      setState(() {
        _statusKey = 'IE.FolderDone';
        _statusArgs = [
          files.length.toString(),
          chapters.length.toString(),
          root,
        ];
      });
    } catch (e) {
      setState(() {
        _statusKey = 'IE.ExportFailed';
        _statusArgs = [e.toString()];
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final l10n = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _statusKey = 'IE.Exporting';
      _statusArgs = [];
    });
    try {
      final entities = <String, List<Map<String, dynamic>>>{};
      for (final entry in entityConfigByTarget.entries) {
        final ds = entry.value.sourceBuilder(ref);
        final items = await ds.list(widget.projectId);
        entities[entry.key.name] = items;
      }
      final payload = <String, dynamic>{
        'app': 'NovelCraft',
        'version': 1,
        'projectId': widget.projectId,
        'exportedAt': DateTime.now().toIso8601String(),
        'entities': entities,
      };
      final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(payload));
      final path = await FilePicker.saveFile(
        dialogTitle: l10n.t('IE.ExportDialogTitle', '导出项目数据'),
        fileName: 'novelcraft_${widget.projectId}.json',
        bytes: bytes,
      );
      if (path == null) {
        setState(() {
          _statusKey = 'IE.ExportCancelled';
          _statusArgs = [];
        });
      } else {
        final total = entities.values.fold(0, (s, l) => s + l.length);
        setState(() {
          _statusKey = 'IE.ExportDone';
          _statusArgs = [total.toString(), path];
        });
      }
    } catch (e) {
      setState(() {
        _statusKey = 'IE.ExportFailed';
        _statusArgs = [e.toString()];
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final l10n = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _statusKey = 'IE.Importing';
      _statusArgs = [];
    });
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: l10n.t('IE.ImportDialogTitle', '选择导出的 JSON 文件'),
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result.isEmpty) {
        setState(() {
          _statusKey = 'IE.ImportCancelled';
          _statusArgs = [];
        });
        return;
      }
      final bytes = await result.single.readAsBytes();
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final entities = decoded['entities'] as Map<String, dynamic>?;
      if (entities == null) {
        setState(() {
          _statusKey = 'IE.InvalidFormat';
          _statusArgs = [];
        });
        return;
      }
      final ImportIdRemap idRemap = ImportIdRemap.build(entities);
      var created = 0;
      for (final entry in entityConfigByTarget.entries) {
        final List<Map<String, dynamic>> rawList =
            idRemap.records(entry.key.name);
        final ds = entry.value.sourceBuilder(ref);
        for (final Map<String, dynamic> item in rawList) {
          await ds.create(widget.projectId, idRemap.remap(item));
          created++;
        }
      }
      setState(() {
        _statusKey = 'IE.ImportDone';
        _statusArgs = [created.toString()];
      });
    } catch (e) {
      setState(() {
        _statusKey = 'IE.ImportFailed';
        _statusArgs = [e.toString()];
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  String _statusText(L10n l10n) {
    if (_statusKey.isEmpty) return '';
    return switch (_statusKey) {
      'IE.Exporting' => l10n.t('IE.Exporting', '正在导出…'),
      'IE.ExportCancelled' => l10n.t('IE.ExportCancelled', '已取消导出'),
      'IE.ExportDone' => l10n.tf('IE.ExportDone', '导出完成：{0} 条记录 → {1}', _statusArgs),
      'IE.ExportFailed' => l10n.tf('IE.ExportFailed', '导出失败：{0}', _statusArgs),
      'IE.FolderExporting' => l10n.t('IE.FolderExporting', '正在导出文件夹组…'),
      'IE.FolderDone' => l10n.tf('IE.FolderDone', '导出完成：{0} 个文件（正文 {1} 章） → {2}', _statusArgs),
      'IE.DocExporting' => l10n.t('IE.DocExporting', '正在合并正文导出…'),
      'IE.DocDone' =>
        l10n.tf('IE.DocDone', '导出完成：{0} 章正文，共 {1} 字 → {2}', _statusArgs),
      'IE.DocEmpty' =>
        l10n.t('IE.DocEmpty', '当前项目还没有正文内容（章节正文为空），无需导出'),
      'IE.EpubExporting' => l10n.t('IE.EpubExporting', '正在打包 EPUB 电子书…'),
      'IE.EpubDone' =>
        l10n.tf('IE.EpubDone', 'EPUB 导出完成：{0} 章 → {1}', _statusArgs),
      'IE.Importing' => l10n.t('IE.Importing', '正在导入…'),
      'IE.ImportCancelled' => l10n.t('IE.ImportCancelled', '已取消导入'),
      'IE.InvalidFormat' => l10n.t('IE.InvalidFormat', '文件格式不正确：缺少 entities'),
      'IE.ImportDone' => l10n.tf('IE.ImportDone', '导入完成：新建 {0} 条记录', _statusArgs),
      'IE.ImportFailed' => l10n.tf('IE.ImportFailed', '导入失败：{0}', _statusArgs),
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('IE.Title', '导入导出'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.t('IE.Intro', '导出会把当前项目下全部数据库实体（人物、卷宗、世界观体系等 19 类）备份为一个 JSON 文件；导入会按相同结构回写（新建记录，不影响已有数据）。'),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: const Icon(Icons.upload_outlined),
                  label: Text(l10n.t('IE.ExportBtn', '导出当前项目')),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(l10n.t('IE.ImportBtn', '从 JSON 导入')),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              l10n.t('IE.FolderSectionTitle', '文本导出（结构化文件夹组）'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.t('IE.FolderIntro',
                  '把当前项目导出为一组按「卷宗 / 章节 / 人物 / 势力 / 世界观…」分类的文件夹（每章一个独立文件），可选 Markdown 或纯文本格式，方便在其它编辑器中继续创作。'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<bool>(
                  segments: <ButtonSegment<bool>>[
                    ButtonSegment<bool>(
                      value: true,
                      label: Text(l10n.t('IE.FolderFormatMd', 'Markdown (.md)')),
                    ),
                    ButtonSegment<bool>(
                      value: false,
                      label: Text(l10n.t('IE.FolderFormatTxt', '纯文本 (.txt)')),
                    ),
                  ],
                  selected: <bool>{_folderMarkdown},
                  onSelectionChanged: _busy
                      ? null
                      : (Set<bool> sel) =>
                          setState(() => _folderMarkdown = sel.first),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _exportFolder,
                  icon: const Icon(Icons.folder_open),
                  label: Text(l10n.t('IE.FolderBtn', '导出为文件夹组…')),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              l10n.t('IE.DocSectionTitle', '正文导出（单文件）'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.t('IE.DocIntro',
                  '把当前项目全部章节正文按「卷 → 章」顺序合并为一个文件，可选 Markdown(.md) 或纯文本(.txt)，便于直接阅读、投稿或打印。'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<bool>(
                  segments: <ButtonSegment<bool>>[
                    ButtonSegment<bool>(
                      value: true,
                      label: Text(l10n.t('IE.FolderFormatMd', 'Markdown (.md)')),
                    ),
                    ButtonSegment<bool>(
                      value: false,
                      label: Text(l10n.t('IE.FolderFormatTxt', '纯文本 (.txt)')),
                    ),
                  ],
                  selected: <bool>{_docMarkdown},
                  onSelectionChanged: _busy
                      ? null
                      : (Set<bool> sel) =>
                          setState(() => _docMarkdown = sel.first),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _exportWholeBook,
                  icon: const Icon(Icons.description_outlined),
                  label: Text(l10n.t('IE.DocBtn', '导出正文（.md / .txt）…')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _exportEpub,
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(l10n.t('IE.EpubBtn', '导出 EPUB 电子书…')),
            ),
            const SizedBox(height: 20),
            if (_busy)
              const LinearProgressIndicator()
            else if (_statusKey.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_statusText(l10n))),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
