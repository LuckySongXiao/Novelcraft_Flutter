import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../pages/entity_configs.dart' show entityConfigByTarget;

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
      var created = 0;
      for (final entry in entityConfigByTarget.entries) {
        final rawList = entities[entry.key.name];
        if (rawList is! List) continue;
        final ds = entry.value.sourceBuilder(ref);
        for (final item in rawList.cast<Map<String, dynamic>>()) {
          await ds.create(widget.projectId, item);
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
