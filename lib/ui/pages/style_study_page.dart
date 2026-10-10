// 文风研读（拆书）页 —— 把一本写得好的小说拆成可复用的写作规则。
//
// 三种输入来源（用户明确要求都要支持）：
//   ① 本地文件：`file_picker` 读 txt/md → 解码 → [StyleDigestService.digest]；
//   ② 粘贴文本：直接给服务；
//   ③ 已有项目：服务自己按 projectId 拉章节正文（`digestProject`）。
//
// 页面上半部分是**规则集库**（读全局 `StyleRuleLibrary`），下半部分是「拆书」。
// 拆完默认存库并把当前项目指到它 —— 「拆完即用」是主路径。
//
// ⚠ 编码：网文 txt 有相当比例是 GBK/GB18030，而 Dart 标准库只自带 UTF-8 /
// UTF-16。这里做 BOM 嗅探 + 严格 UTF-8，失败时**明确报错要求转码**，而不是
// 用 `allowMalformed` 硬解成一堆 U+FFFD 再拿去拆书 —— 后者会静默产出
// 「以□□□为主」这种垃圾规则，比报错难查得多。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/utils/style_digest_text.dart';
import '../../application/services/style_digest_service.dart';
import '../../application/services/style_rule.dart';
import '../../core/di.dart';
import '../../data/database.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart';
import 'project_management_page.dart' show projectsStreamProvider;

/// 拆书输入来源。
enum StyleSource { file, paste, project }

/// 七个维度的英文名（中文名在 `lib/ai/utils/style_digest_text.dart`，
/// 那里是纯 Dart 领域层，不带 i18n）。
const Map<String, String> _aspectLabelsEn = <String, String>{
  'perspective': 'Narrative perspective & person',
  'sentence': 'Sentence & paragraph length',
  'dialogue': 'Dialogue vs. narration ratio',
  'imagery': 'Common imagery & rhetoric',
  'rhythm': 'Pacing & scene transitions',
  'opening': 'Opening & hook technique',
  'taboo': 'Taboo expressions (AI-flavored / clichés)',
};

/// 技法大类的英文名。
const Map<String, String> _categoryLabelsEn = <String, String>{
  '叙事技法': 'Narrative craft',
  '人物塑造': 'Characterization',
  '对话与语言': 'Dialogue & language',
  '战斗与冲突': 'Combat & conflict',
  '节奏与结构': 'Pacing & structure',
  '情绪与幽默': 'Emotion & humor',
  '主题与立意': 'Theme & message',
};

class StyleStudyPage extends ConsumerStatefulWidget {
  const StyleStudyPage({super.key});

  @override
  ConsumerState<StyleStudyPage> createState() => _StyleStudyPageState();
}

class _StyleStudyPageState extends ConsumerState<StyleStudyPage> {
  StyleSource _source = StyleSource.file;
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _pasteCtrl = TextEditingController();

  /// 已读入的本地文件内容（空 = 还没选文件）。
  String _fileText = '';
  String _fileLabel = '';
  String _projectId = '';

  bool _running = false;
  String _step = '';
  StyleDigestResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 默认把「已有项目」预选到当前项目。
    _projectId = ref.read(currentProjectIdProvider) ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pasteCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 动作

  Future<void> _pickFile() async {
    final L10n l10n = ref.read(l10nProvider);
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        dialogTitle: l10n.t('SDP.PickFileTitle', '选择小说文本文件'),
        type: FileType.custom,
        allowedExtensions: <String>['txt', 'md', 'text'],
      );
      if (picked.isEmpty) return;
      final PlatformFile f = picked.single;
      final Uint8List bytes = await f.readAsBytes();
      final String? text = _decodeBytes(bytes);
      if (text == null) {
        setState(() {
          _error = l10n.t(
            'SDP.DecodeFailed',
            '文件不是 UTF-8 编码（网文 txt 常见 GBK）。请先用记事本 / 编辑器另存为 UTF-8 再试。',
          );
        });
        return;
      }
      setState(() {
        _fileText = text;
        _fileLabel = l10n.tf('SDP.FilePickedFmt', '已读入 {0}（{1} 字）', <Object>[
          f.name,
          text.trim().length,
        ]);
        _error = null;
        if (_nameCtrl.text.trim().isEmpty) {
          _nameCtrl.text = _stripExtension(f.name);
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = l10n.tf('SDP.ReadFailedFmt', '读取文件失败：{0}', <Object>[e]);
      });
    }
  }

  Future<void> _run() async {
    final L10n l10n = ref.read(l10nProvider);
    if (_running) return;

    // 先做本地校验，避免白跑一次模型调用。
    if (_source == StyleSource.file && _fileText.trim().isEmpty) {
      setState(() => _error = l10n.t('SDP.NeedFile', '请先选择要拆解的文本文件。'));
      return;
    }
    if (_source == StyleSource.paste && _pasteCtrl.text.trim().isEmpty) {
      setState(() => _error = l10n.t('SDP.NeedPaste', '请先粘贴要拆解的小说正文。'));
      return;
    }
    if (_source == StyleSource.project && _projectId.isEmpty) {
      setState(() => _error = l10n.t('SDP.NeedProject', '请先选择要研读的项目。'));
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _step = l10n.t('SDP.Preparing', '正在准备样本…');
    });

    try {
      final StyleDigestService svc = ref.read(styleDigestServiceProvider);
      final StyleDigestResult r;
      if (_source == StyleSource.project) {
        final String projectName = _projectName();
        r = await svc.digestProject(
          projectId: _projectId,
          projectName: projectName,
          onProgress: (String s) {
            if (mounted) setState(() => _step = s);
          },
        );
      } else {
        r = await svc.digest(
          text: _source == StyleSource.file ? _fileText : _pasteCtrl.text,
          name: _nameCtrl.text,
          sourceLabel: _source == StyleSource.file
              ? _fileLabel
              : l10n.t('SDP.SourcePaste', '粘贴文本'),
          onProgress: (String s) {
            if (mounted) setState(() => _step = s);
          },
        );
      }
      if (!mounted) return;

      // 拆成功就入库，并把**当前项目**指到它（若当前有项目）。
      if (r.isSuccess && r.ruleSet != null && r.ruleSet!.isUsable) {
        await ref
            .read(styleRuleLibraryProvider.notifier)
            .upsert(
              r.ruleSet!,
              activateForProject: ref.read(currentProjectIdProvider) ?? '',
            );
      }
      if (!mounted) return;
      setState(() {
        _result = r;
        _running = false;
        _step = '';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _step = '';
        _error = l10n.tf('SDP.UnexpectedFmt', '拆书未完成：{0}', <Object>[e]);
      });
    }
  }

  String _projectName() {
    final List<ProjectRow> all =
        ref.read(projectsStreamProvider).value ?? const <ProjectRow>[];
    for (final ProjectRow p in all) {
      if (p.id == _projectId) return p.name;
    }
    return '';
  }

  // ------------------------------------------------------------- 视图

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('SDP.Title', '文风研读（拆书）'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Text(
            l10n.t(
              'SDP.Sub',
              '把一本写得好的小说拆成可复用的写作规则，再注入到自己的书里。'
                  '规则会作用于章节大纲、派活与正文提示词。',
            ),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _libraryCard(l10n, scheme),
          const SizedBox(height: 16),
          _digestCard(l10n, scheme),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(fontSize: 12, color: scheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _libraryCard(L10n l10n, ColorScheme scheme) {
    final StyleRuleLibrary lib = ref.watch(styleRuleLibraryProvider);
    final String currentProject = ref.watch(currentProjectIdProvider) ?? '';
    final Map<String, ProjectRow> projects = <String, ProjectRow>{
      for (final ProjectRow p
          in ref.watch(projectsStreamProvider).value ?? const <ProjectRow>[])
        p.id: p,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.t('SDP.LibraryTitle', '已有规则集'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (lib.sets.isEmpty)
              Text(
                l10n.t('SDP.LibraryEmpty', '还没有规则集。用下面的「拆书」新建一份。'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            for (final StyleRuleSet s in lib.sets)
              _RuleSetTile(
                l10n: l10n,
                set: s,
                isActiveForCurrentProject:
                    lib.activeSetFor(currentProject)?.id == s.id,
                projects: projects,
                activeFor: <String>[
                  for (final MapEntry<String, String> e in lib.active.entries)
                    if (e.value == s.id && projects.containsKey(e.key))
                      projects[e.key]!.name,
                ],
                onActivate: (String projectId) => ref
                    .read(styleRuleLibraryProvider.notifier)
                    .activate(
                      projectId,
                      lib.activeSetFor(projectId)?.id == s.id ? '' : s.id,
                    ),
                onDelete: () => _confirmDelete(l10n, s),
              ),
          ],
        ),
      ),
    );
  }

  Widget _digestCard(L10n l10n, ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.t('SDP.NewTitle', '拆书'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            SegmentedButton<StyleSource>(
              segments: <ButtonSegment<StyleSource>>[
                ButtonSegment<StyleSource>(
                  value: StyleSource.file,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(l10n.t('SDP.Source.File', '本地文件')),
                ),
                ButtonSegment<StyleSource>(
                  value: StyleSource.paste,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: Text(l10n.t('SDP.Source.Paste', '粘贴文本')),
                ),
                ButtonSegment<StyleSource>(
                  value: StyleSource.project,
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: Text(l10n.t('SDP.Source.Project', '已有项目')),
                ),
              ],
              selected: <StyleSource>{_source},
              onSelectionChanged: (Set<StyleSource> s) =>
                  setState(() => _source = s.first),
            ),
            const SizedBox(height: 12),
            if (_source == StyleSource.file) ...<Widget>[
              Row(
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: _running ? null : _pickFile,
                    icon: const Icon(Icons.attach_file, size: 16),
                    label: Text(l10n.t('SDP.PickFile', '选择文本文件')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _fileLabel.isEmpty
                          ? l10n.t('SDP.NoFileYet', '尚未选择文件（支持 txt / md，UTF-8）')
                          : _fileLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_source == StyleSource.paste)
              TextField(
                controller: _pasteCtrl,
                minLines: 6,
                maxLines: 12,
                decoration: InputDecoration(
                  labelText: l10n.t('SDP.Paste', '粘贴小说正文'),
                  helperText: l10n.t(
                    'SDP.PasteHint',
                    '粘贴越多越准（建议 5 万字以上）；服务会自动首尾保留、中间均匀取样。',
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            if (_source == StyleSource.project) ...<Widget>[
              Consumer(
                builder: (BuildContext context, WidgetRef ref, _) {
                  final List<ProjectRow> list =
                      ref.watch(projectsStreamProvider).value ??
                      const <ProjectRow>[];
                  // ⚠ 夹取：选中的项目被删掉后必须回落到空，否则
                  // DropdownButton 会因为在 items 里找不到 value 而断言红屏。
                  final bool ok = list.any(
                    (ProjectRow p) => p.id == _projectId,
                  );
                  final String current = ok ? _projectId : '';
                  return DropdownButtonFormField<String>(
                    key: ValueKey<String>('styleProject::$current'),
                    initialValue: current,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.t('SDP.Project', '要研读的项目'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: <DropdownMenuItem<String>>[
                      for (final ProjectRow p in list)
                        DropdownMenuItem<String>(
                          value: p.id,
                          child: Text(
                            p.name,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                    ],
                    onChanged: (String? v) =>
                        setState(() => _projectId = v ?? ''),
                  );
                },
              ),
              const SizedBox(height: 4),
              Text(
                l10n.t('SDP.ProjectHint', '只统计已写正文的章节；用半本书就能看出自己的文风，便于续写保持一致。'),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: l10n.t('SDP.Name', '规则集名称'),
                helperText: l10n.t('SDP.NameHint', '默认取文件名 / 项目名，可改'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.auto_stories, size: 18),
                  label: Text(
                    _running
                        ? l10n.t('SDP.Running', '拆书中…')
                        : l10n.t('SDP.Start', '开始拆书'),
                  ),
                ),
                if (_running) ...<Widget>[
                  const SizedBox(width: 14),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _step,
                      style: const TextStyle(fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            if (_result != null) ...<Widget>[
              const SizedBox(height: 14),
              _resultView(l10n, scheme, _result!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _resultView(L10n l10n, ColorScheme scheme, StyleDigestResult r) {
    final Color color = r.isSuccess ? Colors.green : scheme.error;
    final StyleRuleSet? set = r.ruleSet;
    final bool en = l10n.isEnglish;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (r.isSuccess ? Colors.green : scheme.error).withValues(
          alpha: 0.06,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                r.isSuccess ? Icons.check_circle_outline : Icons.error_outline,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  r.message,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (r.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                r.notes.join('；'),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          if (set != null && set.isUsable) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              l10n.t('SDP.ResultTitle', '研读结果（已保存）'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            for (final MapEntry<String, String> e in set.aspects.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: RichText(
                  text: TextSpan(
                    style: DefaultTextStyle.of(
                      context,
                    ).style.copyWith(fontSize: 12),
                    children: <InlineSpan>[
                      TextSpan(
                        text:
                            '${en ? (_aspectLabelsEn[e.key] ?? e.key) : (kStyleAspectLabels[e.key] ?? e.key)}：',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: e.value),
                    ],
                  ),
                ),
              ),
            if (set.techniques.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              for (final MapEntry<String, List<StyleTechnique>> g
                  in set.techniquesByCategory.entries) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: Text(
                    en ? (_categoryLabelsEn[g.key] ?? g.key) : g.key,
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
                ),
                for (final StyleTechnique t in g.value)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 3),
                    child: RichText(
                      text: TextSpan(
                        style: DefaultTextStyle.of(
                          context,
                        ).style.copyWith(fontSize: 12),
                        children: <InlineSpan>[
                          TextSpan(
                            text: '· ${t.title}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (t.detail.isNotEmpty)
                            TextSpan(text: '：${t.detail}'),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDelete(L10n l10n, StyleRuleSet set) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.t('SDP.Delete', '删除')),
        content: Text(
          l10n.tf(
            'SDP.DeleteConfirm',
            '确定删除规则集「{0}」？已启用它的项目会回到「不注入」。',
            <Object>[set.name],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.t('Common.Confirm', '确定')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(styleRuleLibraryProvider.notifier).remove(set.id);
  }
}

/// 单条规则集的展示行。
class _RuleSetTile extends StatelessWidget {
  const _RuleSetTile({
    required this.l10n,
    required this.set,
    required this.isActiveForCurrentProject,
    required this.projects,
    required this.activeFor,
    required this.onActivate,
    required this.onDelete,
  });

  final L10n l10n;
  final StyleRuleSet set;
  final bool isActiveForCurrentProject;
  final Map<String, ProjectRow> projects;

  /// 已启用本规则集的项目名（可能为空）。
  final List<String> activeFor;
  final void Function(String projectId) onActivate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              set.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.tf('SDP.TileCountFmt', '{0} 条技法', <Object>[
              set.techniques.length,
            ]),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          if (isActiveForCurrentProject) ...<Widget>[
            const SizedBox(width: 8),
            Icon(Icons.check_circle, size: 14, color: scheme.primary),
          ],
        ],
      ),
      subtitle: set.sourceLabel.isEmpty
          ? null
          : Text(
              set.sourceLabel,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      children: <Widget>[
        if (activeFor.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                l10n.tf('SDP.TileActiveFmt', '已启用：{0}', <Object>[
                  activeFor.join(l10n.isEnglish ? ', ' : '、'),
                ]),
                style: TextStyle(fontSize: 11, color: scheme.primary),
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            children: <Widget>[
              for (final MapEntry<String, ProjectRow> e in projects.entries)
                ActionChip(
                  label: Text(
                    activeFor.contains(e.value.name)
                        ? l10n.tf('SDP.DeactivateFmt', '取消《{0}》', <Object>[
                            e.value.name,
                          ])
                        : l10n.tf('SDP.ActivateFmt', '启用《{0}》', <Object>[
                            e.value.name,
                          ]),
                    style: const TextStyle(fontSize: 11),
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onActivate(e.key),
                ),
              TextButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text(
                  l10n.t('SDP.Delete', '删除'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 去扩展名（`众仙俯首.txt` → `众仙俯首`）。
String _stripExtension(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

/// 字节 → 文本。
///
/// 顺序：BOM 嗅探（UTF-8 / UTF-16LE / UTF-16BE）→ 严格 UTF-8 → 失败返回 null。
///
/// ⚠ 刻意**不用** `allowMalformed: true` 兜底：那会把 GBK 字节解成一串 U+FFFD，
/// 拆书时模型看到的是乱码样本，产出的却是「貌似正常」的规则 —— 静默错误。
/// 宁可报错让用户转码。
String? _decodeBytes(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final int n = bytes.length ~/ 2;
  final List<int> units = <int>[];
  for (int i = 0; i < n; i++) {
    final int a = bytes[i * 2];
    final int b = bytes[i * 2 + 1];
    units.add(littleEndian ? (b << 8) | a : (a << 8) | b);
  }
  return String.fromCharCodes(units);
}
