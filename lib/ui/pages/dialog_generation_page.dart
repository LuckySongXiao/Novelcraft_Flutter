import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../core/di.dart';
import '../../data/database.dart';
import '../../l10n/l10n.dart';
import '../../ai/models/chat.dart';
import '../layout/navigation.dart';

String _relFor(String v, L10n l10n) => switch (v) {
      '朋友' => l10n.t('DG.Rel.Friend', '朋友'),
      '恋人' => l10n.t('DG.Rel.Lover', '恋人'),
      '敌人' => l10n.t('DG.Rel.Enemy', '敌人'),
      '家人' => l10n.t('DG.Rel.Family', '家人'),
      '同事' => l10n.t('DG.Rel.Colleague', '同事'),
      '陌生人' => l10n.t('DG.Rel.Stranger', '陌生人'),
      _ => v,
    };

String _purposeFor(String v, L10n l10n) => switch (v) {
      '对话推进剧情' =>
        l10n.t('DG.Purpose.Plot', '对话推进剧情'),
      '展现人物性格' =>
        l10n.t('DG.Purpose.Character', '展现人物性格'),
      '揭露背景信息' =>
        l10n.t('DG.Purpose.Background', '揭露背景信息'),
      '制造矛盾冲突' =>
        l10n.t('DG.Purpose.Conflict', '制造矛盾冲突'),
      '烘托情绪氛围' =>
        l10n.t('DG.Purpose.Atmosphere', '烘托情绪氛围'),
      _ => v,
    };

String _emotionFor(String v, L10n l10n) => switch (v) {
      '平静' => l10n.t('DG.Emo.Calm', '平静'),
      '喜悦' => l10n.t('DG.Emo.Joy', '喜悦'),
      '愤怒' => l10n.t('DG.Emo.Anger', '愤怒'),
      '悲伤' => l10n.t('DG.Emo.Sad', '悲伤'),
      '紧张' => l10n.t('DG.Emo.Tense', '紧张'),
      '幽默' => l10n.t('DG.Emo.Humor', '幽默'),
      '暧昧' => l10n.t('DG.Emo.Ambiguous', '暧昧'),
      '恐惧' => l10n.t('DG.Emo.Fear', '恐惧'),
      _ => v,
    };

String _styleFor(String v, L10n l10n) => switch (v) {
      '写实' => l10n.t('DG.Style.Realistic', '写实'),
      '古风' => l10n.t('DG.Style.Classical', '古风'),
      '口语化' => l10n.t('DG.Style.Colloquial', '口语化'),
      '文学化' => l10n.t('DG.Style.Literary', '文学化'),
      '二次元' => l10n.t('DG.Style.ACGA', '二次元'),
      '剧本台词' => l10n.t('DG.Style.Script', '剧本台词'),
      _ => v,
    };

String _lengthLabelFor(int level, L10n l10n) => switch (level) {
      1 || 2 => l10n.t('DG.Length.VeryShort', '很短'),
      3 || 4 => l10n.t('DG.Length.Short', '较短'),
      5 || 6 => l10n.t('DG.Length.Medium', '中等'),
      7 || 8 => l10n.t('DG.Length.Long', '较长'),
      9 || 10 => l10n.t('DG.Length.VeryLong', '很长'),
      _ => l10n.t('DG.Length.Medium', '中等'),
    };

class DialogGenerationPage extends ConsumerStatefulWidget {
  const DialogGenerationPage({super.key});

  @override
  ConsumerState<DialogGenerationPage> createState() =>
      _DialogGenerationPageState();
}

class _DialogGenerationPageState extends ConsumerState<DialogGenerationPage> {
  final _charactersCtrl = TextEditingController();
  final _situationCtrl = TextEditingController();
  final _resultCtrl = TextEditingController();

  String _relationship = '朋友';
  String _purpose = '对话推进剧情';
  String _emotion = '平静';
  String _style = '写实';
  double _length = 5;

  bool _isGenerating = false;
  String _streamText = '';
  double? _quality;
  String? _thinkingId;
  DateTime? _generatedAt;

  static const _kRelationships = ['朋友', '恋人', '敌人', '家人', '同事', '陌生人'];
  static const _kPurposes = [
    '对话推进剧情',
    '展现人物性格',
    '揭露背景信息',
    '制造矛盾冲突',
    '烘托情绪氛围',
  ];
  static const _kEmotions = ['平静', '喜悦', '愤怒', '悲伤', '紧张', '幽默', '暧昧', '恐惧'];
  static const _kStyles = ['写实', '古风', '口语化', '文学化', '二次元', '剧本台词'];

  // 注意：下列文本会**落库**（章节标题 / 标签 / 备注），会出现在章节列表与备注框里，
  // 因此必须跟随当前语言，否则 EN 模式下会漏出中文（PITFALLS §29）。
  String get _draftTitle {
    final l10n = ref.read(l10nProvider);
    final chars = _charactersCtrl.text.trim();
    if (chars.isNotEmpty) return '$chars - $_purpose';
    final stamp = DateTime.now()
        .toString()
        .replaceAll(RegExp(r'[- :.]'), '_')
        .substring(0, 15);
    return '${l10n.t('DG.DraftAutoTitle', 'AI 对话草稿')}_$stamp';
  }

  String _buildTags() {
    final l10n = ref.read(l10nProvider);
    return [
      l10n.t('DG.Tag.AiDialog', 'AI 对话'),
      _emotion,
      _style,
      _relationship,
    ].where((v) => v.isNotEmpty).join(',');
  }

  String _buildNotes() {
    final l10n = ref.read(l10nProvider);
    return '${l10n.t('DG.Notes.Scene', '场景')}：${_situationCtrl.text.trim()}\n'
        '${l10n.t('DG.Notes.Characters', '角色')}：${_charactersCtrl.text.trim()}\n'
        '${l10n.t('DG.Notes.Emotion', '情绪')}：$_emotion\n'
        '${l10n.t('DG.Notes.Style', '风格')}：$_style\n'
        '${l10n.t('DG.Notes.Quality', '质量评分')}：${(_quality ?? 0).toStringAsFixed(1)}';
  }

  @override
  void dispose() {
    _charactersCtrl.dispose();
    _situationCtrl.dispose();
    _resultCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final hasProject = ref.watch(currentProjectIdProvider) != null;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('DG.Title', 'AI 对话生成器'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                if (!hasProject)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      l10n.t('DG.NoProjectHint', '尚未选择项目，保存到章节功能不可用。'),
                      style: TextStyle(color: scheme.tertiary),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.t('DG.ParamSection', '参数设置'),
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 16,
                          runSpacing: 12,
                          children: [
                            _tf(
                              controller: _charactersCtrl,
                              label: l10n.t('DG.CharactersLabel', '角色（逗号分隔）'),
                              hint: l10n.t('DG.CharactersHint', '例如：叶知秋, 苏曼莎'),
                              width: 360,
                              maxLines: 1,
                            ),
                            _dd(
                              label: l10n.t('DG.RelationshipLabel', '关系'),
                              value: _relationship,
                              items: _kRelationships,
                              display: (v) => _relFor(v, l10n),
                              onChanged: (v) => setState(() => _relationship = v),
                            ),
                            _tf(
                              controller: _situationCtrl,
                              label: l10n.t('DG.SituationLabel', '情境'),
                              hint: l10n.t('DG.SituationHint', '描述对话发生的场景与目的'),
                              width: 480,
                              maxLines: 2,
                            ),
                            _dd(
                              label: l10n.t('DG.PurposeLabel', '目的'),
                              value: _purpose,
                              items: _kPurposes,
                              display: (v) => _purposeFor(v, l10n),
                              onChanged: (v) => setState(() => _purpose = v),
                            ),
                            _dd(
                              label: l10n.t('DG.EmotionLabel', '情绪基调'),
                              value: _emotion,
                              items: _kEmotions,
                              display: (v) => _emotionFor(v, l10n),
                              onChanged: (v) => setState(() => _emotion = v),
                            ),
                            _dd(
                              label: l10n.t('DG.StyleLabel', '语言风格'),
                              value: _style,
                              items: _kStyles,
                              display: (v) => _styleFor(v, l10n),
                              onChanged: (v) => setState(() => _style = v),
                            ),
                            SizedBox(
                              width: 360,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.t('DG.LengthLabel', '对话长度'),
                                    style: Theme.of(context).inputDecorationTheme.labelStyle,
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Slider(
                                          min: 1,
                                          max: 10,
                                          divisions: 9,
                                          value: _length,
                                          label: _lengthLabelFor(
                                              _length.toInt(), l10n),
                                          onChanged: _isGenerating
                                              ? null
                                              : (v) => setState(() => _length = v),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 52,
                                        child: Text(
                                          _lengthLabelFor(_length.toInt(), l10n),
                                          textAlign: TextAlign.end,
                                          style: TextStyle(color: scheme.onSurfaceVariant),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _isGenerating ? null : _generate,
                              icon: const Icon(Icons.auto_awesome),
                              label: Text(l10n.t('DG.GenerateButton', '生成对话')),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: (_isGenerating || _resultCtrl.text.isEmpty)
                                  ? null
                                  : _optimize,
                              icon: const Icon(Icons.auto_awesome),
                              label: Text(l10n.t('DG.OptimizeButton', '优化当前')),
                            ),
                            IconButton(
                              onPressed: _pickCharacters,
                              tooltip: l10n.t('DG.PickFromLibraryTip', '从角色库选择'),
                              icon: const Icon(Icons.person_search_outlined),
                            ),
                            IconButton(
                              onPressed: _resultCtrl.text.isEmpty ? null : _copy,
                              tooltip: l10n.t('DG.CopyTip', '复制'),
                              icon: const Icon(Icons.copy_outlined),
                            ),
                            IconButton(
                              onPressed: !hasProject || _resultCtrl.text.isEmpty
                                  ? null
                                  : _saveToProject,
                              tooltip: l10n.t('DG.SaveTip', '保存到项目章节'),
                              icon: const Icon(Icons.save_outlined),
                            ),
                            IconButton(
                              onPressed: _resultCtrl.text.isEmpty ? null : _export,
                              tooltip: l10n.t('DG.ExportTip', '导出到文件'),
                              icon: const Icon(Icons.file_download_outlined),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _saveTemplate,
                              icon: const Icon(Icons.bookmark_add_outlined),
                              label: Text(l10n.t('DG.SaveTemplate', '保存模板')),
                            ),
                            OutlinedButton.icon(
                              onPressed: _loadTemplate,
                              icon: const Icon(Icons.folder_open_outlined),
                              label: Text(l10n.t('DG.LoadTemplate', '加载模板')),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.help_outline),
                              tooltip: l10n.t('DG.HelpTip', '帮助'),
                              onPressed: _showHelp,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(l10n.t('DG.ResultSection', '生成结果'),
                                style: Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            if (_quality != null) _qualityChip(l10n),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_generatedAt != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              '${l10n.t('DG.GeneratedAt', '生成时间')}：${_generatedAt!.toString().substring(0, 19)}   '
                              '${l10n.t('DG.ThinkId', '思维链')}：${_thinkingId ?? '-'}',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        SizedBox(
                          height: 320,
                          child: TextField(
                            controller: _resultCtrl,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            decoration: InputDecoration(
                              hintText: _isGenerating && _streamText.isEmpty
                                  ? l10n.t('DG.GeneratingHint', '正在生成...')
                                  : l10n.t('DG.ResultHint', '生成的对话会出现在这里，可编辑。'),
                              border: const OutlineInputBorder(),
                              enabledBorder: const OutlineInputBorder(),
                              suffixIcon: _isGenerating
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        if (_isGenerating && _streamText.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              l10n.t('DG.StreamingTip', '流式生成已结束后内容会自动填入结果框。'),
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tf({
    required TextEditingController controller,
    required String label,
    String? hint,
    double width = 280,
    int maxLines = 1,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _dd({
    required String label,
    required String value,
    required List<String> items,
    required String Function(String) display,
    required ValueChanged<String> onChanged,
  }) {
    return SizedBox(
      width: 220,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: items
            .map((e) => DropdownMenuItem<String>(
                value: e, child: Text(display(e))))
            .toList(growable: false),
        onChanged: _isGenerating ? null : (v) => v != null ? onChanged(v) : null,
      ),
    );
  }

  Widget _qualityChip(L10n l10n) {
    final q = _quality ?? 0;
    final bg = q >= 8.0
        ? Colors.green
        : q >= 6.0
            ? Colors.orange
            : Colors.red;
    return Chip(
      backgroundColor: bg,
      label: Text(
        l10n.tf('DG.QualityScore', '质量评分：{0}/10', [q.toStringAsFixed(1)]),
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      avatar: Icon(
        q >= 8.0
            ? Icons.verified
            : q >= 6.0
                ? Icons.thumbs_up_down
                : Icons.warning_amber_outlined,
        color: Colors.white,
        size: 18,
      ),
    );
  }

  // --- 业务动作 ---

  Future<Map<String, dynamic>> _buildParams() async {
    return <String, dynamic>{
      'projectId': ref.read(currentProjectIdProvider) ?? '',
      'characters': _charactersCtrl.text.trim(),
      'relationship': _relationship,
      'situation': _situationCtrl.text.trim(),
      'purpose': _purpose,
      'emotion': _emotion,
      'style': _style,
      'length': _length.toInt(),
    };
  }

  Future<void> _generate() async {
    if (_isGenerating) return;
    final params = await _buildParams();
    await _runGeneration(params, optimize: false);
  }

  Future<void> _optimize() async {
    if (_isGenerating || _resultCtrl.text.isEmpty) return;
    final params = await _buildParams();
    params['existingDialogue'] = _resultCtrl.text;
    params['optimizationMode'] = true;
    await _runGeneration(params, optimize: true);
  }

  Future<void> _runGeneration(Map<String, dynamic> params, {required bool optimize}) async {
    final l10n = ref.read(l10nProvider);
    final mm = ref.read(modelManagerProvider);
    final prov = mm.getDefaultProvider();
    if (prov == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
          l10n.t('DG.NoDefaultModel',
              '尚未配置默认 AI 模型，请先到「AI 配置」注册并设为默认。'),
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() {
      _isGenerating = true;
      _streamText = '';
    });

    final sb = StringBuffer();
    try {
      final prompt = _buildPrompt(params, optimize: optimize);
      final system = '你是资深小说对话润色师。只输出对话，不要多余解释。';
      final req = ChatRequest(
        model: '',
        messages: [
          ChatMessage.system(system),
          ChatMessage.user(prompt),
        ],
        stream: true,
        maxTokens: 2048,
        temperature: 0.85,
      );
      await mm.chatStream(req, (ChatChunk chunk) {
        if (chunk.content.isNotEmpty) {
          sb.write(chunk.content);
          if (mounted) setState(() => _streamText = sb.toString());
        }
      });
      if (!mounted) return;
      setState(() {
        _resultCtrl.text = sb.toString();
        _quality = _estimateQuality(sb.toString(), params);
        _thinkingId = DateTime.now().microsecondsSinceEpoch.toString();
        _generatedAt = DateTime.now();
        _streamText = '';
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.tf('DG.GenerateFailed', '生成失败：{0}', [e])),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  String _buildPrompt(Map<String, dynamic> p, {required bool optimize}) {
    if (optimize) {
      return '''请对以下对话进行优化润色，要求：
- 角色：${p['characters']}，关系：${p['relationship']}
- 保持原有情绪：${p['emotion']}；风格：${p['style']}
- 原有对话：
${p['existingDialogue']}''';
    }
    return '''请为以下设定生成小说对话：
- 参与角色：${p['characters']}（关系：${p['relationship']}）
- 场景/情境：${p['situation']}
- 对话目的：${p['purpose']}
- 情绪基调：${p['emotion']}
- 语言风格：${p['style']}
- 对话长度等级(1~10)：${p['length']}（等级越高轮次越多）
请直接输出对话剧本，采用「角色：台词」格式，可加括号动作描写。''';
  }

  double _estimateQuality(String content, Map<String, dynamic> params) {
    if (content.trim().isEmpty) return 0.0;
    final charsCount = content.length;
    final hasNames = RegExp(r'^[^\s：:]{1,8}[：:]', multiLine: true)
        .allMatches(content)
        .length;
    final lines = content.split(RegExp(r'\n+')).where((e) => e.trim().isNotEmpty).length;
    double score = 5.0;
    if (charsCount > 200) score += 1;
    if (charsCount > 600) score += 0.5;
    if (hasNames >= 3) score += 0.5;
    if (lines >= 4) score += 0.5;
    if (RegExp(r'[，。、]').allMatches(content).length >= 10) score += 0.5;
    if ((params['characters'] as String).isNotEmpty &&
        (params['characters'] as String).split(',').any((n) => content.contains(n.trim()))) {
      score += 1;
    }
    if ((params['situation'] as String).isNotEmpty) score += 0.5;
    return score.clamp(0.0, 10.0);
  }

  Future<void> _pickCharacters() async {
    final l10n = ref.read(l10nProvider);
    final projectId = ref.read(currentProjectIdProvider);
    if (projectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('DG.PickChars.NoProject', '请先选择一个项目'))),
      );
      return;
    }
    final repo = ref.read(characterRepositoryProvider);
    final chars = await repo.getByProjectId(projectId);
    if (!mounted) return;
    if (chars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('DG.PickChars.Empty', '当前项目暂无角色，请先创建。'))),
      );
      return;
    }
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _CharacterPickerDialog(names: chars.map((c) => c.name).whereType<String>().toList()),
    );
    if (picked != null && picked.isNotEmpty) {
      _charactersCtrl.text = picked.join(',');
    }
  }

  Future<void> _copy() async {
    final l10n = ref.read(l10nProvider);
    await Clipboard.setData(ClipboardData(text: _resultCtrl.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('DG.CopyDone', '对话已复制到剪贴板'))),
      );
    }
  }

  Future<void> _saveToProject() async {
    final l10n = ref.read(l10nProvider);
    final projectId = ref.read(currentProjectIdProvider);
    if (projectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.t('DG.Save.NoProject', '请先选择项目')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    final volRepo = ref.read(volumeRepositoryProvider);
    final chRepo = ref.read(chapterRepositoryProvider);
    const uuid = Uuid();
    try {
      var volumes = await volRepo.getByProjectId(projectId);
      // 用**语言无关的 type='AI' 标记**定位草稿卷，而不是标题 ——
      // 否则切换语言后标题变了会找不不到，重复建卷（PITFALLS §29）。
      var vol = volumes
          .where((v) => v.type == 'AI')
          .cast<VolumeRow?>()
          .firstWhere(
            (_) => true,
            orElse: () => null,
          );
      vol ??= await volRepo.create(VolumesCompanion.insert(
        id: uuid.v4(),
        projectId: projectId,
        title: l10n.t('DG.DraftVolumeTitle', 'AI 对话草稿'),
        description: d.Value(
            l10n.t('DG.DraftVolumeDesc', 'AI 对话生成器保存的草稿章节')),
        status: const d.Value('Planning'),
        type: const d.Value('AI'),
        createdAt: d.Value(DateTime.now()),
        updatedAt: d.Value(DateTime.now()),
      ));
      final chapter = await chRepo.create(ChaptersCompanion.insert(
        id: uuid.v4(),
        volumeId: vol.id,
        title: _draftTitle,
        projectId: d.Value(projectId),
        summary: d.Value(_situationCtrl.text.trim()),
        content: d.Value(_resultCtrl.text),
        status: const d.Value('Draft'),
        type: const d.Value('DialogueDraft'),
        tags: d.Value(_buildTags()),
        notes: d.Value(_buildNotes()),
        orderIndex: const d.Value(99999),
        wordCount: d.Value(_resultCtrl.text.length),
        createdAt: d.Value(DateTime.now()),
        updatedAt: d.Value(DateTime.now()),
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('DG.Save.Done', '已保存到章节草稿：{0}', [chapter.title]))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('DG.Save.Failed', '保存失败：{0}', [e])), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _export() async {
    final l10n = ref.read(l10nProvider);
    final fileName = '${_draftTitle.replaceAll(RegExp(r'[\\/:*?"<>| ]'), '_')}.md';
    final ext = fileName.split('.').last.toLowerCase();
    final content = ext == 'json'
        ? _jsonExport()
        : ext == 'txt'
            ? _resultCtrl.text
            : _markdownExport();
    final outUri = await FilePicker.saveFile(
      dialogTitle: l10n.t('DG.Export.DialogTitle', '导出对话'),
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['md', 'txt', 'json'],
      bytes: Uint8List.fromList(content.codeUnits),
    );
    if (mounted && outUri != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.tf('DG.Export.Done', '已导出：{0}', [outUri]))),
      );
    }
  }

  String _markdownExport() => '# $_draftTitle\n\n'
      '- 角色：${_charactersCtrl.text.trim()}\n'
      '- 关系：$_relationship\n'
      '- 场景：${_situationCtrl.text.trim()}\n'
      '- 目的：$_purpose\n'
      '- 情绪：$_emotion\n'
      '- 风格：$_style\n'
      '- 质量评分：${(_quality ?? 0).toStringAsFixed(1)}\n\n'
      '## 对话内容\n\n${_resultCtrl.text}\n';

  String _jsonExport() {
    return '{\n'
        '  "characters": ${_charactersCtrl.text.trim().replaceAll('"', '\\"').padLeft(2)},\n'
        '  "situation": "${_situationCtrl.text.trim().replaceAll('"', '\\"')}",\n'
        '  "purpose": "$_purpose",\n'
        '  "emotion": "$_emotion",\n'
        '  "style": "$_style",\n'
        '  "qualityScore": ${(_quality ?? 0).toStringAsFixed(2)},\n'
        '  "content": "${_resultCtrl.text.replaceAll('"', '\\"').replaceAll('\n', '\\n')}",\n'
        '  "exportedAt": "${DateTime.now().toIso8601String()}"\n'
        '}';
  }

  Future<void> _saveTemplate() async {
    final l10n = ref.read(l10nProvider);
    final nameCtrl = TextEditingController(
        text: l10n.tf('DG.SaveTemplate.DefaultName', '对话模板_{0}',
            [DateTime.now().millisecondsSinceEpoch]));
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx2, ref2, _) {
          final dl10n = ref2.watch(l10nProvider);
          return AlertDialog(
            title: Text(dl10n.t('DG.SaveTemplate.DialogTitle', '保存模板')),
            content: TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                  labelText: dl10n.t('DG.SaveTemplate.NameLabel', '模板名称'),
                  border: const OutlineInputBorder()),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(dl10n.t('Common.Cancel', '取消'))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
                  child: Text(dl10n.t('Common.Save', '保存'))),
            ],
          );
        },
      ),
    );
    if (name == null || name.isEmpty) return;
    final storeAsync = ref.read(keyValueStoreProvider);
    storeAsync.whenData((store) async {
      final existing = await store.readJson('dialog', 'templates');
      final list = existing == null || existing.isEmpty
          ? <Map<String, dynamic>>[]
          : (jsonDecode(existing) as List<dynamic>).cast<Map<String, dynamic>>();
      final templates = List<Map<String, dynamic>>.from(list);
      templates.add(<String, dynamic>{
        'name': name,
        'characters': _charactersCtrl.text.trim(),
        'relationship': _relationship,
        'situation': _situationCtrl.text.trim(),
        'purpose': _purpose,
        'emotion': _emotion,
        'style': _style,
        'length': _length.toInt(),
        'savedAt': DateTime.now().toIso8601String(),
      });
      await store.writeJson('dialog', 'templates', jsonEncode(templates));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('DG.SaveTemplate.Done', '模板已保存：{0}', [name]))),
        );
      }
    });
  }

  Future<void> _loadTemplate() async {
    final l10n = ref.read(l10nProvider);
    final storeAsync = ref.read(keyValueStoreProvider);
    storeAsync.whenData((store) async {
      final raw = await store.readJson('dialog', 'templates');
      final list = raw == null || raw.isEmpty
          ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      if (list.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.t('DG.LoadTemplate.Empty', '暂未保存任何模板'))),
          );
        }
        return;
      }
      if (!mounted) return;
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => Consumer(
          builder: (ctx2, ref2, _) {
            final dl10n = ref2.watch(l10nProvider);
            return SimpleDialog(
              title: Text(dl10n.t('DG.LoadTemplate.DialogTitle', '选择模板')),
              children: list
                  .map((t) => SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, t),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(t['name'] as String? ??
                              dl10n.t('Common.Unnamed', '未命名')),
                        ),
                      ))
                  .toList(growable: false),
            );
          },
        ),
      );
      if (picked == null) return;
      if (picked['characters'] is String) _charactersCtrl.text = picked['characters'] as String;
      if (picked['situation'] is String) _situationCtrl.text = picked['situation'] as String;
      setState(() {
        _relationship = (picked['relationship'] as String?) ?? _relationship;
        _purpose = (picked['purpose'] as String?) ?? _purpose;
        _emotion = (picked['emotion'] as String?) ?? _emotion;
        _style = (picked['style'] as String?) ?? _style;
        _length = ((picked['length'] as num?)?.toDouble() ?? _length).clamp(1, 10).toDouble();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('DG.LoadTemplate.Done', '已加载模板：{0}', [picked['name']]))),
        );
      }
    });
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx2, ref2, _) {
          final dl10n = ref2.watch(l10nProvider);
          return AlertDialog(
            title: Text(dl10n.t(
                'DG.Help.DialogTitle', 'AI 对话生成器 · 使用说明')),
            content: Text(dl10n.t('DG.Help.Content', '''1. 角色设置：输入角色名，用逗号分隔；也可以点旁边的人图标从角色库选择。\n2. 情境/目的：描述对话发生的场景（谁，在哪，因为什么），越详细越好。\n3. 情绪/风格：选择基调（幽默、紧张…）和文字风格（古风、写实…）。\n4. 长度：1=很短，10=很长，按需要调节。\n5. 点「生成对话」即可调用默认 AI 模型生成，流式输出。\n6. 如果对结果不满意，可以「优化当前」继续润色，或者改参数重生成。\n7. 满意后可以：复制 / 保存到章节草稿 / 导出 md/txt/json / 存成模板下次复用。''')),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(dl10n.t('DG.Help.GotIt', '我知道了'))),
            ],
          );
        },
      ),
    );
  }
}

class _CharacterPickerDialog extends ConsumerStatefulWidget {
  final List<String> names;
  const _CharacterPickerDialog({required this.names});

  @override
  ConsumerState<_CharacterPickerDialog> createState() =>
      _CharacterPickerDialogState();
}

class _CharacterPickerDialogState
    extends ConsumerState<_CharacterPickerDialog> {
  final _selected = <String>{};
  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    return AlertDialog(
      title: Text(l10n.t('DG.PickChars.DialogTitle', '从角色库选择')),
      content: SizedBox(
        width: 320,
        height: 380,
        child: ListView(
          children: widget.names
              .map((name) => CheckboxListTile(
                    dense: true,
                    title: Text(name),
                    value: _selected.contains(name),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(name);
                        } else {
                          _selected.remove(name);
                        }
                      });
                    },
                  ))
              .toList(growable: false),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('Common.Cancel', '取消'))),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList(growable: false)),
          child: Text(l10n.t('Common.Confirm', '确定')),
        ),
      ],
    );
  }
}
