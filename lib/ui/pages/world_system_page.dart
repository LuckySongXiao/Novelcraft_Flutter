import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enums/pseudo_enums.dart';
import '../../data/storage/key_value_store.dart';
import '../../l10n/l10n.dart';

/// 字段类型
enum SystemFieldType { text, multiline, number, select, bool }

/// 体系字段定义
class SystemFieldDef {
  const SystemFieldDef({
    required this.key,
    required this.labelZh,
    this.labelEn,
    this.type = SystemFieldType.text,
    this.optionsZh,
    this.optionsEn,
    this.options,
    this.defaultValue,
  });

  final String key;
  final String labelZh;
  final String? labelEn;
  final SystemFieldType type;

  /// 旧式选项：**值 == 中文标签**（JSON 体系页用；数据以中文原文入库）
  final List<String>? optionsZh;

  /// 与 [optionsZh] 一一对应的英文**显示标签**（不是入库值）
  final List<String>? optionsEn;

  /// 新式选项：值 + 中英标签分离（数据库实体页用，取自 [PseudoEnums]）
  final List<OptionEntry>? options;

  final Object? defaultValue;

  String labelFor(bool isEnglish) =>
      (isEnglish && labelEn != null && labelEn!.isNotEmpty)
          ? labelEn!
          : labelZh;

  /// 纯标签列表（旧接口，仅用于不需要区分值/标签的场合）
  List<String> optionsFor(bool isEnglish) {
    final src = isEnglish ? optionsEn : optionsZh;
    return src ?? optionsZh ?? const [];
  }

  /// 构造下拉框的完整候选集：**值 + 本地化标签**，并保证 [current] 一定命中。
  ///
  /// 关键不变量：Flutter 的 `DropdownButton` 要求「恰好一个」item 的 value
  /// 等于当前 value，否则直接断言崩溃（`There should be exactly one item with
  /// [DropdownButton]'s value`）。而库里的值可能来自：表列默认值、别处写入、
  /// 旧版本残留 —— 都不在静态候选表里。故此处把当前值**原样补一条**兜底。
  List<OptionEntry> optionEntries(String? current) {
    final out = <OptionEntry>[];
    final seen = <String>{};

    if (options != null) {
      for (final o in options!) {
        if (seen.add(o.value)) out.add(o);
      }
    } else {
      final zh = optionsZh ?? const <String>[];
      for (var i = 0; i < zh.length; i++) {
        final v = zh[i];
        if (!seen.add(v)) continue;
        final en = (optionsEn != null && i < optionsEn!.length)
            ? optionsEn![i]
            : null;
        out.add(OptionEntry(v, v, en));
      }
    }

    final cur = current?.trim() ?? '';
    if (cur.isNotEmpty && seen.add(cur)) {
      // 未收录值：原样展示，避免崩溃，也方便用户看到「历史脏值」
      out.add(OptionEntry(cur, cur, cur));
    }
    return out;
  }

  /// 把库里的原始值渲染成**给人看**的文案。
  ///
  /// - select 字段：命中候选 → 本地化标签；未命中 → 美化标识符
  /// - 其它字段：原样返回（正文/标题等不该被改写）
  ///
  /// 列表副标题（[summaryField]）必须走这里，否则 EN 模式会把库里的
  /// '主角' / 'Planning' / 'commodity_standard' 原样显示出来。
  String displayLabel(String? raw, bool isEnglish) {
    final v = raw?.trim() ?? '';
    if (v.isEmpty) return '';
    if (type != SystemFieldType.select) return v;
    for (final o in optionEntries(v)) {
      if (o.value == v) return o.labelFor(isEnglish);
    }
    return prettyIdentifier(v);
  }

  /// `commodity_standard` → `Commodity Standard`；已是普通词则原样返回。
  ///
  /// 用于兜住「表列写入的是英文标识符、而候选表里没有」的历史脏值。
  static String prettyIdentifier(String v) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]*([_\- ][A-Za-z0-9]+)*$').hasMatch(v)) {
      return v;
    }
    if (!v.contains('_') && !v.contains('-')) return v;
    return v
        .split(RegExp(r'[_\-]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => s[0].toUpperCase() + s.substring(1))
        .join(' ');
  }
}

/// 世界观体系配置
///
/// C# 版每个体系页都手写一遍 ViewModel（10 个 *DataService 各 123 行 +
/// 12 个 View 各约 950 行，合计约 11,400 行），方法名逐字重复
/// （ImportXxx_Click / ExportXxx_Click / SaveXxx_Click / AIAssistant_Click）。
/// Dart 侧改为**配置驱动**：一份模板 + 若干份配置即可覆盖全部体系。
class WorldSystemConfig {
  const WorldSystemConfig({
    required this.scope,
    required this.titleZh,
    this.titleEn,
    required this.itemNameZh,
    this.itemNameEn,
    required this.fields,
    this.summaryField,
  });

  /// 存储作用域（对应 C# 的 `%AppData%\NovelManagement\{scope}\`）
  final String scope;

  final String titleZh;
  final String? titleEn;

  /// 单条记录的名称（如「功法」「装备」）
  final String itemNameZh;
  final String? itemNameEn;

  final List<SystemFieldDef> fields;

  /// 列表副标题使用的字段 key
  final String? summaryField;

  String titleFor(bool isEnglish) =>
      (isEnglish && titleEn != null && titleEn!.isNotEmpty)
          ? titleEn!
          : titleZh;

  String itemNameFor(bool isEnglish) =>
      (isEnglish && itemNameEn != null && itemNameEn!.isNotEmpty)
          ? itemNameEn!
          : itemNameZh;
}

/// 体系数据仓储（基于平台无关的 JSON 存储）
class WorldSystemRepository {
  WorldSystemRepository(this._store, this._config);

  final KeyValueStore _store;
  final WorldSystemConfig _config;

  Future<List<Map<String, dynamic>>> load(String projectId) async {
    final raw = await _store.readJson(_config.scope, projectId);
    if (raw == null || raw.isEmpty) return [];
    try {
      final doc = jsonDecode(raw);
      if (doc is! Map<String, dynamic>) return [];
      final items = doc['items'];
      if (items is! List) return [];
      return items
          .whereType<Map<String, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String projectId, List<Map<String, dynamic>> items) async {
    // 与 C# 版一致：保存时按名称排序
    final sorted = [...items]
      ..sort(
        (a, b) => (a['name'] ?? '').toString().compareTo(
              (b['name'] ?? '').toString(),
            ),
      );
    final doc = {
      'projectId': projectId,
      'updatedAt': DateTime.now().toIso8601String(),
      'items': sorted,
    };
    await _store.writeJson(_config.scope, projectId, jsonEncode(doc));
  }
}

/// 通用体系页 —— 列表 + 详情表单 + 导入导出
class WorldSystemPage extends ConsumerStatefulWidget {
  const WorldSystemPage({
    super.key,
    required this.config,
    required this.projectId,
    required this.store,
  });

  final WorldSystemConfig config;
  final String projectId;
  final KeyValueStore store;

  @override
  ConsumerState<WorldSystemPage> createState() => _WorldSystemPageState();
}

class _WorldSystemPageState extends ConsumerState<WorldSystemPage> {
  late final WorldSystemRepository _repo;
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _selected;
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _repo = WorldSystemRepository(widget.store, widget.config);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _repo.load(widget.projectId);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    await _repo.save(widget.projectId, _items);
  }

  List<Map<String, dynamic>> get _filtered {
    if (_keyword.trim().isEmpty) return _items;
    final k = _keyword.trim().toLowerCase();
    return _items.where((item) {
      return item.values.any(
        (v) => v?.toString().toLowerCase().contains(k) ?? false,
      );
    }).toList();
  }

  void _create() {
    final draft = <String, dynamic>{
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      for (final f in widget.config.fields)
        f.key: f.defaultValue ??
            (f.type == SystemFieldType.bool ? false : ''),
    };
    setState(() => _selected = draft);
  }

  Future<void> _saveSelected() async {
    final sel = _selected;
    if (sel == null) return;
    final idx = _items.indexWhere((e) => e['id'] == sel['id']);
    if (idx >= 0) {
      _items[idx] = sel;
    } else {
      _items.add(sel);
    }
    await _persist();
    if (!mounted) return;
    setState(() => _selected = null);
  }

  Future<void> _deleteSelected() async {
    final sel = _selected;
    if (sel == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, dref, _) {
          final dl10n = dref.watch(l10nProvider);
          return AlertDialog(
            title: Text(dl10n.t('Dlg.Delete', '删除')),
            content: Text(
              dl10n.tf('Dlg.DeleteConfirm', '确定删除「{0}」吗？此操作不可恢复。', [sel['name']?.toString() ?? '']),
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
    _items.removeWhere((e) => e['id'] == sel['id']);
    await _persist();
    if (!mounted) return;
    setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    final isEnglish = l10n.isEnglish;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final itemName = widget.config.itemNameFor(isEnglish);

    // 列表副标题所用字段的定义（用于把枚举原始值映射成本地化标签）
    final summaryKey = widget.config.summaryField;
    final summaryDef = summaryKey == null
        ? null
        : widget.config.fields.where((f) => f.key == summaryKey).firstOrNull;

    return Row(
      children: [
        SizedBox(
          width: 320,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: l10n.tf('Common.SearchItem', '搜索{0}', [itemName]),
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _keyword = v),
                ),
              ),
              Expanded(
                child: _filtered.isEmpty
                    ? Center(
                        child: Text(
                          l10n.tf('Common.EmptyItem', '暂无{0}', [itemName]),
                          style: TextStyle(color: scheme.outline),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filtered.length,
                        itemBuilder: (context, i) {
                          final item = _filtered[i];
                          final isSel = _selected?['id'] == item['id'];
                          return ListTile(
                            selected: isSel,
                            title: Text(
                              (item['name'] ?? l10n.t('Common.Unnamed', '未命名')).toString(),
                            ),
                            // 副标题走字段展示映射，避免把枚举原始值直接漏给用户
                            subtitle: summaryDef == null
                                ? null
                                : Text(
                                    summaryDef.displayLabel(
                                      item[widget.config.summaryField]
                                          ?.toString(),
                                      isEnglish,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            onTap: () =>
                                setState(() => _selected = {...item}),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.tf('Common.NewItem', '新建{0}', [itemName])),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _selected == null
              ? Center(
                  child: Text(
                    l10n.tf('Common.SelectOrNewItem', '请选择或新建{0}', [itemName]),
                    style: TextStyle(color: scheme.outline),
                  ),
                )
              : _buildForm(isEnglish),
        ),
      ],
    );
  }

  Widget _buildForm(bool isEnglish) {
    final sel = _selected!;
    final l10n = ref.watch(l10nProvider);
    final itemName = widget.config.itemNameFor(isEnglish);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(
                sel['name']?.toString().isNotEmpty == true
                    ? sel['name'].toString()
                    : l10n.tf('Common.NewItem', '新建{0}', [itemName]),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _deleteSelected,
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.t('Dlg.Delete', '删除')),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saveSelected,
                icon: const Icon(Icons.save_outlined),
                label: Text(l10n.t('Dlg.Save', '保存')),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final f in widget.config.fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _buildField(f, sel, isEnglish),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildField(
      SystemFieldDef f, Map<String, dynamic> sel, bool isEnglish) {
    final value = sel[f.key];
    final label = f.labelFor(isEnglish);

    if (f.type == SystemFieldType.bool) {
      return SwitchListTile(
        title: Text(label),
        value: value == true,
        contentPadding: EdgeInsets.zero,
        onChanged: (v) => setState(() => sel[f.key] = v),
      );
    }

    if (f.type == SystemFieldType.select) {
      // 值（入库原文）与显示标签分离：EN 模式下只换显示，不改写入值，
      // 避免「切 EN 存英文、切回 ZH 值失配」的数据污染（PITFALLS §28）。
      final current = value?.toString() ?? '';
      final entries = f.optionEntries(current);
      final matched = entries.any((o) => o.value == current);
      return DropdownButtonFormField<String>(
        key: ValueKey('${f.key}|$current'),
        initialValue: matched ? current : null,
        decoration: InputDecoration(labelText: label),
        items: entries
            .map((o) => DropdownMenuItem<String>(
                  value: o.value,
                  child: Text(o.labelFor(isEnglish)),
                ))
            .toList(),
        onChanged: (v) => setState(() => sel[f.key] = v),
      );
    }

    if (f.type == SystemFieldType.number) {
      return TextFormField(
        initialValue: value?.toString() ?? '',
        decoration: InputDecoration(labelText: label),
        keyboardType: TextInputType.number,
        onChanged: (v) => sel[f.key] = num.tryParse(v) ?? 0,
      );
    }

    return TextFormField(
      initialValue: value?.toString() ?? '',
      decoration: InputDecoration(labelText: label),
      maxLines: f.type == SystemFieldType.multiline ? 6 : 1,
      onChanged: (v) => sel[f.key] = v,
    );
  }
}
