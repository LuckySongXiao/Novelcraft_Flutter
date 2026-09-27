import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import 'world_system_page.dart' show SystemFieldDef, SystemFieldType;

/// 数据库实体的数据源抽象
///
/// 之所以不直接把 drift 的 Row 类型透传给页面，是因为 20 多个实体的 Row 类
/// 各不相同，泛型化会让页面签名失控。这里统一退化为 `Map<String, dynamic>`，
/// 由各实体的适配器负责 Row ↔ Map 转换。
abstract class EntityDataSource {
  Future<List<Map<String, dynamic>>> list(String projectId);

  Future<List<Map<String, dynamic>>> search(String projectId, String keyword);

  Future<void> create(String projectId, Map<String, dynamic> values);

  Future<void> update(String id, Map<String, dynamic> values);

  Future<void> delete(String id);
}

/// 用一组回调拼装的数据源，避免为每个实体都写一个类
class CallbackEntityDataSource implements EntityDataSource {
  const CallbackEntityDataSource({
    required this.onList,
    required this.onSearch,
    required this.onCreate,
    required this.onUpdate,
    required this.onDelete,
  });

  final Future<List<Map<String, dynamic>>> Function(String projectId) onList;
  final Future<List<Map<String, dynamic>>> Function(
    String projectId,
    String keyword,
  ) onSearch;
  final Future<void> Function(
    String projectId,
    Map<String, dynamic> values,
  ) onCreate;
  final Future<void> Function(String id, Map<String, dynamic> values) onUpdate;
  final Future<void> Function(String id) onDelete;

  @override
  Future<List<Map<String, dynamic>>> list(String projectId) => onList(projectId);

  @override
  Future<List<Map<String, dynamic>>> search(String projectId, String keyword) =>
      onSearch(projectId, keyword);

  @override
  Future<void> create(String projectId, Map<String, dynamic> values) =>
      onCreate(projectId, values);

  @override
  Future<void> update(String id, Map<String, dynamic> values) =>
      onUpdate(id, values);

  @override
  Future<void> delete(String id) => onDelete(id);
}

/// 实体页配置
///
/// 与 [WorldSystemPage] 的配置同构，区别是数据来自 drift 而非 JSON 文件。
class EntityPageConfig {
  const EntityPageConfig({
    required this.titleZh,
    this.titleEn,
    required this.itemNameZh,
    this.itemNameEn,
    required this.fields,
    required this.sourceBuilder,
    this.nameField = 'name',
    this.summaryField,
    this.previewBuilder,
  });

  final String titleZh;
  final String? titleEn;
  final String itemNameZh;
  final String? itemNameEn;
  final List<SystemFieldDef> fields;

  /// 列表标题使用的字段 key（卷宗/章节用的是 title 而非 name）
  final String nameField;

  /// 列表副标题使用的字段 key
  final String? summaryField;

  /// 可选的「预览」入口：提供后，选中记录时表单区顶部出现预览按钮，
  /// 点击把**当前表单快照**（含未保存改动 + 选中行的元信息）交给预览页。
  /// 功能 A：仅 chapterEntityConfig 提供（章节只读预览）。
  final Widget Function(BuildContext context, Map<String, dynamic> values)?
      previewBuilder;

  final EntityDataSource Function(WidgetRef ref) sourceBuilder;

  String titleFor(bool isEnglish) =>
      (isEnglish && titleEn != null && titleEn!.isNotEmpty)
          ? titleEn!
          : titleZh;

  String itemNameFor(bool isEnglish) =>
      (isEnglish && itemNameEn != null && itemNameEn!.isNotEmpty)
          ? itemNameEn!
          : itemNameZh;
}

/// 通用实体 CRUD 页 —— 左列表 + 右详情表单
///
/// C# 版每个实体都手写一对 View + ViewModel（人物管理约 2100 行、
/// 卷宗章节约 1800 行 ⋯），而它们的骨架完全一致：
/// 搜索框 + 列表 + 新增/保存/删除 + 若干文本框。
/// Dart 侧收敛为这一份模板，各实体只提供配置。
class EntityPage extends ConsumerStatefulWidget {
  const EntityPage({
    super.key,
    required this.config,
    required this.projectId,
  });

  final EntityPageConfig config;
  final String projectId;

  @override
  ConsumerState<EntityPage> createState() => _EntityPageState();
}

class _EntityPageState extends ConsumerState<EntityPage> {
  late final EntityDataSource _source;
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _selected;
  bool _loading = true;
  bool _dirty = false;
  String? _error;

  final _searchCtrl = TextEditingController();
  final _formCtrl = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _source = widget.config.sourceBuilder(ref);
    for (final f in widget.config.fields) {
      _formCtrl[f.key] = TextEditingController();
    }
    _reload();
  }

  @override
  void didUpdateWidget(covariant EntityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) {
      _reload();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final c in _formCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final kw = _searchCtrl.text.trim();
      final rows = kw.isEmpty
          ? await _source.list(widget.projectId)
          : await _source.search(widget.projectId, kw);
      if (!mounted) return;
      setState(() {
        _items = rows;
        _loading = false;
        // 选中项可能已被删除，重新对齐
        if (_selected != null) {
          final id = _selected!['id'];
          _selected = rows.cast<Map<String, dynamic>?>().firstWhere(
                (r) => r?['id'] == id,
                orElse: () => null,
              );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _fillForm(Map<String, dynamic>? row) {
    for (final f in widget.config.fields) {
      final v = row?[f.key];
      _formCtrl[f.key]!.text = v == null ? '' : '$v';
    }
  }

  Map<String, dynamic> _readForm() {
    final values = <String, dynamic>{};
    for (final f in widget.config.fields) {
      final raw = _formCtrl[f.key]!.text.trim();
      if (raw.isEmpty) continue;
      values[f.key] = switch (f.type) {
        SystemFieldType.number => num.tryParse(raw) ?? raw,
        _ => raw,
      };
    }
    return values;
  }

  void _select(Map<String, dynamic> row) {
    setState(() {
      _selected = row;
      _dirty = false;
    });
    _fillForm(row);
  }

  Future<void> _newItem() async {
    setState(() {
      _selected = null;
      _dirty = false;
    });
    _fillForm(null);
  }

  Future<void> _save() async {
    final values = _readForm();
    if (values.isEmpty) return;
    final l10n = ref.read(l10nProvider);
    try {
      if (_selected == null) {
        await _source.create(widget.projectId, values);
      } else {
        await _source.update(_selected!['id'] as String, values);
      }
      if (!mounted) return;
      setState(() => _dirty = false);
      await _reload();
      _snack(l10n.t('Common.Saved', '已保存'));
    } catch (e) {
      _snack(l10n.tf('Common.SaveFailed', '保存失败：{0}', [e.toString()]));
    }
  }

  Future<void> _delete() async {
    final id = _selected?['id'] as String?;
    if (id == null) return;
    final l10n = ref.read(l10nProvider);
    final isEnglish = l10n.isEnglish;
    final itemName = widget.config.itemNameFor(isEnglish);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, dref, _) {
          final dl10n = dref.watch(l10nProvider);
          return AlertDialog(
            title: Text(dl10n.t('Dlg.ConfirmDelete', '确认删除')),
            content: Text(
              dl10n.tf('Dlg.DeleteItemHint', '删除后可在回收站恢复。确定删除这条{0}？', [itemName]),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(dl10n.t('Common.Cancel', '取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(dl10n.t('Dlg.Delete', '删除')),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    try {
      await _source.delete(id);
      if (!mounted) return;
      setState(() {
        _selected = null;
        _dirty = false;
      });
      _fillForm(null);
      await _reload();
      _snack(l10n.t('Common.Deleted', '已删除'));
    } catch (e) {
      _snack(l10n.tf('Common.DeleteFailed', '删除失败：{0}', [e.toString()]));
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = widget.config;
    final l10n = ref.watch(l10nProvider);
    final isEnglish = l10n.isEnglish;
    final itemName = cfg.itemNameFor(isEnglish);

    // 列表副标题所用字段的字段定义（用于把枚举原始值映射成本地化标签）
    final summaryKey = cfg.summaryField;
    final summaryDef = summaryKey == null
        ? null
        : cfg.fields.where((f) => f.key == summaryKey).firstOrNull;

    if (_error != null) {
      return Center(child: Text(l10n.tf('Common.LoadFailed', '加载失败：{0}', [_error.toString()])));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: _newItem,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.tf('Common.NewItem', '新建{0}', [itemName])),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _dirty || _selected != null ? _save : null,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(l10n.t('Dlg.Save', '保存')),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _selected == null ? null : _delete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(l10n.t('Dlg.Delete', '删除')),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: l10n.t('Common.Refresh', '刷新'),
                onPressed: _reload,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              const Spacer(),
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    l10n.t('Common.UnsavedChanges', '有未保存的修改'),
                    style: TextStyle(fontSize: 12, color: scheme.tertiary),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 300,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: TextField(
                              controller: _searchCtrl,
                              decoration: InputDecoration(
                                hintText: l10n.tf('Common.SearchItem', '搜索{0}', [itemName]),
                                prefixIcon: const Icon(Icons.search, size: 18),
                                isDense: true,
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  tooltip: l10n.t('Common.Clear', '清除'),
                                  icon: const Icon(Icons.close, size: 16),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    _reload();
                                  },
                                ),
                              ),
                              onSubmitted: (_) => _reload(),
                            ),
                          ),
                          Expanded(
                            child: _items.isEmpty
                                ? Center(
                                    child: Text(
                                      l10n.tf('Common.EmptyItem', '暂无{0}', [itemName]),
                                      style: TextStyle(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: _items.length,
                                    itemBuilder: (context, i) {
                                      final row = _items[i];
                                      final selected =
                                          _selected?['id'] == row['id'];
                                      return ListTile(
                                        selected: selected,
                                        selectedTileColor:
                                            scheme.secondaryContainer,
                                        title: Text(
                                          '${row[cfg.nameField] ?? l10n.t('Common.Unnamed', '未命名')}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        // 副标题走字段的展示映射：枚举值 → 本地化标签，
                                        // 否则 EN 模式会把 '主角' / 'Planning' 原样漏出来
                                        subtitle: summaryDef == null
                                            ? null
                                            : Text(
                                                summaryDef.displayLabel(
                                                  row[cfg.summaryField]
                                                      ?.toString(),
                                                  isEnglish,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                        onTap: () => _select(row),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildForm(isEnglish)),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildForm(bool isEnglish) {
    final preview = widget.config.previewBuilder;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 功能 A：选中记录后提供只读预览（表单快照 + 行元信息一起带走）
        if (preview != null && _selected != null) ...[
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.chrome_reader_mode_outlined, size: 18),
              label: Text(ref
                  .read(l10nProvider)
                  .t('CPV.Open', '预览本章')),
              onPressed: () {
                final values = Map<String, dynamic>.of(_selected!);
                // 表单当前值覆盖：未保存的改动也进预览
                for (final f in widget.config.fields) {
                  values[f.key] = _formCtrl[f.key]!.text;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => preview(context, values)),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
        for (final f in widget.config.fields) ...[
          _buildField(f, isEnglish),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  /// 下拉选择字段。
  ///
  /// ⚠ 崩溃防护（PITFALLS §28）：`DropdownButton` 要求「恰好一个」item 的 value
  /// 等于当前 value，否则抛
  /// `There should be exactly one item with [DropdownButton]'s value: X`。
  /// 而库里的值可能来自表列默认值（Volumes.status='Planning'、Chapters.status='Draft'、
  /// Characters.status='Active' …）或其它版本残留，并不在静态候选表里。
  /// 因此先用 [SystemFieldDef.optionEntries] 把当前值补进候选集再交渲染。
  Widget _buildSelectField(SystemFieldDef f, bool isEnglish) {
    final current = _formCtrl[f.key]!.text;
    final entries = f.optionEntries(current);
    final matched = entries.any((o) => o.value == current);
    return DropdownButtonFormField<String>(
      // 切换记录时强制重建 State，否则 FormField 会沿用上一条记录的选中态
      key: ValueKey('${f.key}|$current'),
      initialValue: matched ? current : null,
      decoration: InputDecoration(
        labelText: f.labelFor(isEnglish),
        border: const OutlineInputBorder(),
      ),
      items: entries
          .map((o) => DropdownMenuItem<String>(
                value: o.value,
                child: Text(o.labelFor(isEnglish)),
              ))
          .toList(),
      onChanged: (v) {
        _formCtrl[f.key]!.text = v ?? '';
        setState(() => _dirty = true);
      },
    );
  }

  Widget _buildField(SystemFieldDef f, bool isEnglish) {
    switch (f.type) {
      case SystemFieldType.multiline:
        return TextField(
          controller: _formCtrl[f.key],
          maxLines: 5,
          decoration: InputDecoration(
            labelText: f.labelFor(isEnglish),
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() => _dirty = true),
        );
      case SystemFieldType.select:
        return _buildSelectField(f, isEnglish);
      case SystemFieldType.number:
        return TextField(
          controller: _formCtrl[f.key],
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: f.labelFor(isEnglish),
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() => _dirty = true),
        );
      case SystemFieldType.bool:
        return SwitchListTile(
          title: Text(f.labelFor(isEnglish)),
          value: _formCtrl[f.key]!.text == 'true',
          onChanged: (v) {
            _formCtrl[f.key]!.text = '$v';
            setState(() => _dirty = true);
          },
        );
      case SystemFieldType.text:
        return TextField(
          controller: _formCtrl[f.key],
          decoration: InputDecoration(
            labelText: f.labelFor(isEnglish),
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() => _dirty = true),
        );
    }
  }
}
