import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/services/writing_prompt_templates.dart';
import '../../core/di.dart';

class WritingPromptSettingsPage extends ConsumerWidget {
  const WritingPromptSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('写作工艺 Prompt 模板')),
    body: ref
        .watch(writingPromptTemplatesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(child: Text('读取模板失败：$error')),
          data: (settings) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                '每个节点可保存多套模板。选择并保存后生效，重启后保留。多智能体写书任务使用启动时的配置；运行中的任务请结束后再重启。资源模板按中文 / English 分开配置。',
              ),
              if (settings.loadWarning != null)
                Text(
                  settings.loadWarning!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              for (final stage in settings.stages)
                Card(
                  child: ListTile(
                    title: Text(stage.title),
                    subtitle: Text(
                      '当前：${_activeName(settings, stage.id)} · 自定义 ${settings.variants[stage.id]?.length ?? 0} 套',
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

  String _activeName(WritingPromptTemplates settings, String id) {
    for (final variant in settings.variants[id] ?? <WritingPromptVariant>[]) {
      if (variant.id == settings.selected[id]) return variant.name;
    }
    return '内置默认';
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
  String? _error;

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
    final selected = _items.where((item) => item.id == _selected).firstOrNull;
    _name.text = selected?.name ?? '内置默认';
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
    var suffix = _items.length + 1;
    while (_items.any((item) => item.name == '自定义模板 $suffix')) {
      suffix++;
    }
    setState(() {
      _selected = const Uuid().v4();
      _items.add(
        WritingPromptVariant(
          id: _selected,
          name: '自定义模板 $suffix',
          body: _body.text,
        ),
      );
      _loadFields();
      _dirty = true;
      _error = null;
    });
  }

  Future<void> _save() async {
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('模板和当前选择已保存')));
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
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
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('离开将放弃本节点尚未保存的编辑和模板选择。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃修改'),
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
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !_saving,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _leave();
    },
    child: Scaffold(
      appBar: AppBar(title: Text(widget.stage.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey(_selected),
            initialValue: _selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '该节点使用的模板（保存后生效）'),
            items: [
              const DropdownMenuItem(value: '', child: Text('内置默认')),
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
                label: const Text('复制为新模板'),
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
                label: const Text('删除当前模板'),
              ),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(_saving ? '保存中…' : '保存模板与选择'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            readOnly: _selected.isEmpty || _saving,
            decoration: const InputDecoration(labelText: '模板名称'),
            onChanged: (_) => setState(() {
              _dirty = true;
            }),
          ),
          const SizedBox(height: 12),
          const Text(
            '内置模板只读，点击“复制为新模板”后可修改。必须保留动态变量；派活、验收等节点还需保留原 JSON 字段结构，正文节点保持仅输出正文的要求。',
          ),
          ExpansionTile(
            title: Text('动态变量参考（${widget.stage.variables.length}）'),
            children: [
              for (final entry in widget.stage.variables.entries)
                ListTile(
                  dense: true,
                  title: SelectableText(
                    widget.stage.asset ? '{${entry.key}}' : '{{${entry.key}}}',
                  ),
                  subtitle: Text(entry.value),
                ),
            ],
          ),
          TextField(
            controller: _body,
            readOnly: _selected.isEmpty || _saving,
            minLines: 12,
            maxLines: 28,
            decoration: const InputDecoration(
              labelText: 'Prompt 正文',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _dirty = true;
            }),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}
