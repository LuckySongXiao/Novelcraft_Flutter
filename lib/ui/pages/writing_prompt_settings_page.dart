import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/services/writing_prompt_templates.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

class WritingPromptSettingsPage extends ConsumerWidget {
  const WritingPromptSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final L10n l10n = ref.watch(l10nProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('WPS.Title', '写作工艺 Prompt 模板'))),
      body: ref
          .watch(writingPromptTemplatesProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => Center(
              child: Text(
                l10n.tf(
                  'WPS.LoadFailed',
                  '读取模板失败：{0}',
                  <Object>[error],
                ),
              ),
            ),
            data: (settings) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  l10n.t(
                    'WPS.Intro',
                    '每个节点可保存多套模板。选择并保存后生效，重启后保留。多智能体写书任务使用启动时的配置；运行中的任务请结束后再重启。资源模板按中文 / English 分开配置。',
                  ),
                ),
                if (settings.loadFailed)
                  Text(
                    l10n.t(
                      'WPS.LoadWarning',
                      '已保存的提示词配置损坏或不兼容，当前使用内置模板；原配置未覆盖。保存新配置会替换原配置。',
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 12),
                for (final stage in settings.stages)
                  Card(
                    child: ListTile(
                      title: Text(stage.titleFor(l10n.isEnglish)),
                      subtitle: Text(
                        l10n.tf(
                          'WPS.CurrentFmt',
                          '当前：{0} · 自定义 {1} 套',
                          <Object>[
                            _activeName(settings, stage.id, l10n),
                            settings.variants[stage.id]?.length ?? 0,
                          ],
                        ),
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              _PromptEditor(settings: settings, stage: stage),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
    );
  }

  String _activeName(
    WritingPromptTemplates settings,
    String id,
    L10n l10n,
  ) {
    for (final variant in settings.variants[id] ?? <WritingPromptVariant>[]) {
      if (variant.id == settings.selected[id]) return variant.name;
    }
    return l10n.t('WPS.BuiltinDefault', '内置默认');
  }
}

class _PromptEditor extends ConsumerStatefulWidget {
  const _PromptEditor({required this.settings, required this.stage});
  final WritingPromptTemplates settings;
  final WritingPromptStage stage;

  @override
  ConsumerState<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends ConsumerState<_PromptEditor> {
  final _name = TextEditingController();
  final _body = TextEditingController();
  late List<WritingPromptVariant> _items;
  late String _selected;
  bool _dirty = false;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _items = [...?widget.settings.variants[widget.stage.id]];
    _selected = widget.settings.selected[widget.stage.id] ?? '';
    _loadFields();
  }

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  void _loadFields() {
    final l10n = ref.read(l10nProvider);
    final selected = _items.where((item) => item.id == _selected).firstOrNull;
    _name.text = selected?.name ?? l10n.t('WPS.BuiltinDefault', '内置默认');
    _body.text = selected?.body ?? widget.stage.defaultBody;
  }

  void _capture() {
    if (_selected.isEmpty) return;
    final index = _items.indexWhere((item) => item.id == _selected);
    _items[index] = WritingPromptVariant(
      id: _selected,
      name: _name.text.trim(),
      body: _body.text,
    );
  }

  void _copy() {
    _capture();
    final l10n = ref.read(l10nProvider);
    var suffix = _items.length + 1;
    String name(int n) =>
        l10n.tf('WPS.CustomName', '自定义模板 {0}', <Object>[n]);
    while (_items.any((item) => item.name == name(suffix))) {
      suffix++;
    }
    setState(() {
      _selected = const Uuid().v4();
      _items.add(
        WritingPromptVariant(
          id: _selected,
          name: name(suffix),
          body: _body.text,
        ),
      );
      _loadFields();
      _dirty = true;
      _error = null;
    });
  }

  Future<void> _save() async {
    final l10n = ref.read(l10nProvider);
    _capture();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(writingPromptTemplatesProvider.notifier)
          .saveStage(widget.stage.id, _items, _selected);
      if (!mounted) return;
      setState(() {
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('WPS.Saved', '模板和当前选择已保存'))),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _leave() async {
    if (_saving) return;
    final l10n = ref.read(l10nProvider);
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('WPS.UnsavedTitle', '有未保存的修改')),
        content: Text(
          l10n.t('WPS.UnsavedBody', '离开将放弃本节点尚未保存的编辑和模板选择。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.t('WPS.ContinueEditing', '继续编辑')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t('WPS.Discard', '放弃修改')),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() {
        _dirty = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final bool en = l10n.isEnglish;
    final WritingPromptStage stage = widget.stage;
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(stage.titleFor(en))),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey(_selected),
              initialValue: _selected,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.t('WPS.NodeTemplate', '该节点使用的模板（保存后生效）'),
              ),
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(l10n.t('WPS.BuiltinDefault', '内置默认')),
                ),
                for (final item in _items)
                  DropdownMenuItem(
                    value: item.id,
                    child: Text(item.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      _capture();
                      setState(() {
                        _selected = value;
                        _loadFields();
                        _dirty = true;
                        _error = null;
                      });
                    },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _saving ? null : _copy,
                  icon: const Icon(Icons.copy),
                  label: Text(l10n.t('WPS.CopyAsNew', '复制为新模板')),
                ),
                OutlinedButton.icon(
                  onPressed: _saving || _selected.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _items.removeWhere((item) => item.id == _selected);
                            _selected = '';
                            _loadFields();
                            _dirty = true;
                          });
                        },
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.t('WPS.DeleteCurrent', '删除当前模板')),
                ),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                    _saving
                        ? l10n.t('WPS.Saving', '保存中…')
                        : l10n.t('WPS.Save', '保存模板与选择'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              readOnly: _selected.isEmpty || _saving,
              decoration: InputDecoration(
                labelText: l10n.t('WPS.TemplateName', '模板名称'),
              ),
              onChanged: (_) => setState(() {
                _dirty = true;
              }),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.t(
                'WPS.ReadonlyHint',
                '内置模板只读，点击“复制为新模板”后可修改。必须保留动态变量；派活、验收等节点还需保留原 JSON 字段结构，正文节点保持仅输出正文的要求。',
              ),
            ),
            ExpansionTile(
              title: Text(
                l10n.tf(
                  'WPS.VariablesRef',
                  '动态变量参考（{0}）',
                  <Object>[stage.variables.length],
                ),
              ),
              children: [
                for (final entry in stage.variables.entries)
                  ListTile(
                    dense: true,
                    title: SelectableText(
                      stage.asset ? '{${entry.key}}' : '{{${entry.key}}}',
                    ),
                    subtitle: Text(stage.variableLabel(entry.key, en)),
                  ),
              ],
            ),
            TextField(
              controller: _body,
              readOnly: _selected.isEmpty || _saving,
              minLines: 12,
              maxLines: 28,
              decoration: InputDecoration(
                labelText: l10n.t('WPS.BodyLabel', 'Prompt 正文'),
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {
                _dirty = true;
              }),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _errorMessage(l10n),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 把校验/保存失败渲染成当前语言下的文案。
  String _errorMessage(L10n l10n) {
    final Object? e = _error;
    if (e == null) return '';
    if (e is PromptTemplateException) return e.localized(l10n);
    return '$e';
  }
}

/// `PromptTemplateException` → 当前语言文案。
extension _PromptTemplateExceptionX on PromptTemplateException {
  String localized(L10n l10n) => args.isEmpty
      ? l10n.t(key, fallback)
      : l10n.tf(key, fallback, args);
}
