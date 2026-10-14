// 纲要管理 —— 按卷宗、按章节撰写并保存书籍项目的大纲与细纲。
//
// 用户要求（+48）：「章节管理模块上方要追加一个纲要管理，用来分卷宗分章节
// 存写对应书籍项目的大纲、细纲」。
//
// 存储位置（**刻意复用既有列，不新建表**）：
//   * 卷大纲   → `Volumes.description`
//   * 章细纲   → `Chapters.summary`
//
// 为什么复用而不是加表：
//   ① AI 写作链路的上下文早就在读这两列 ——
//      `chapter_preview_page._loadAiContext` 的 `volumeOutline` 取
//      `vol.description`、`chapterOutline` 取 `row.summary`；
//      `chapter_rewrite_service` / `continue_story_service` /
//      `project_context_assembler` 也读同样的字段。
//      在这里写，作者刚保存的细纲**立刻**成为后续所有 AI 写作的参考，
//      不需要额外的同步步骤。
//   ② 卷宗/章节的创建、排序仍在「卷宗管理 / 章节管理」里做，本页只负责
//      「写内容」，职责不重叠。
//   ③ 避免 schema 版本升级（schemaVersion 1 → 2 + migration），存量数据
//      零风险。
//
// ⚠ 列宽上限：两列都是 `withLength(max: 1000)`，drift 在写入时会校验长度
// （见 database.g.dart 的 `validateIntegrity`），超出会抛 InvalidDataException。
// 因此本页在保存前做字数检查并给出可读错误，而不是让异常裸奔。
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/utils/foreshadow_ledger.dart';
import '../../core/di.dart';
import '../../data/database.dart';
import '../../l10n/l10n.dart';
import '../layout/navigation.dart' show currentProjectIdProvider;
import 'foreshadow_grid_view.dart';

/// `Volumes.description` / `Chapters.summary` 的列宽上限（drift 写入校验）。
const int kOutlineMaxChars = 1000;

class OutlineManagementPage extends ConsumerStatefulWidget {
  const OutlineManagementPage({super.key});

  @override
  ConsumerState<OutlineManagementPage> createState() =>
      _OutlineManagementPageState();
}

class _OutlineManagementPageState
    extends ConsumerState<OutlineManagementPage> {
  List<VolumeRow> _volumes = const <VolumeRow>[];
  List<ChapterRow> _chapters = const <ChapterRow>[];
  String? _projectId;
  bool _loading = true;
  String? _error;

  String? _selectedVolumeId;

  /// 卷大纲编辑态（按卷宗 id 缓存，切卷不丢未保存内容）。
  final Map<String, TextEditingController> _volumeCtrls =
      <String, TextEditingController>{};
  final Map<String, bool> _volumeDirty = <String, bool>{};

  /// 章细纲编辑态。
  final Map<String, TextEditingController> _chapterCtrls =
      <String, TextEditingController>{};
  final Map<String, bool> _chapterDirty = <String, bool>{};

  /// 伏笔提示编辑态（落 `Chapters.notes`）。
  final Map<String, TextEditingController> _hintCtrls =
      <String, TextEditingController>{};
  final Map<String, bool> _hintDirty = <String, bool>{};

  /// 细纲 / 伏笔经纬 视图切换。
  bool _showGrid = false;

  /// 当前项目章节的展平结果（章 id → 全书序号）。
  ForeshadowFlattenResult _flat = const ForeshadowFlattenResult(
    sources: <ForeshadowChapterSource>[],
    orderByChapterId: <String, int>{},
  );

  /// 伏笔账本（每次载入/保存后重建；纯派生，无缓存一致性问题）。
  ForeshadowLedger _ledger = ForeshadowLedgerBuilder.build(
    const <ForeshadowChapterSource>[],
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final TextEditingController c in _volumeCtrls.values) {
      c.dispose();
    }
    for (final TextEditingController c in _chapterCtrls.values) {
      c.dispose();
    }
    for (final TextEditingController c in _hintCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final String? pid = ref.read(currentProjectIdProvider);
    setState(() {
      _loading = true;
      _error = null;
      _projectId = pid;
    });
    if (pid == null) {
      setState(() {
        _loading = false;
        _volumes = const <VolumeRow>[];
        _chapters = const <ChapterRow>[];
      });
      return;
    }
    try {
      final List<VolumeRow> vols =
          await ref.read(volumeServiceProvider).getByProjectId(pid);
      final List<ChapterRow> chaps =
          await ref.read(chapterServiceProvider).getByProjectId(pid);
      // orderIndex 升序；卷内章节也按 orderIndex 排，展示顺序与正文一致。
      vols.sort((VolumeRow a, VolumeRow b) => a.orderIndex.compareTo(b.orderIndex));
      chaps.sort((ChapterRow a, ChapterRow b) => a.orderIndex.compareTo(b.orderIndex));
      if (!mounted) return;
      setState(() {
        _volumes = vols;
        _chapters = chaps;
        _loading = false;
        _selectedVolumeId ??= vols.isNotEmpty ? vols.first.id : null;
        _rebuildLedger();
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  List<ChapterRow> _chaptersOf(String volumeId) =>
      _chapters.where((ChapterRow c) => c.volumeId == volumeId).toList();

  /// 重建展平结果与伏笔账本（**必须在 setState 内调用**）。
  ///
  /// 账本是纯派生数据 —— 每次都从各章细纲（`summary` + `notes`）重新解析，
  /// 所以不存在「改了细纲但账本没同步」的可能。
  void _rebuildLedger() {
    final Map<String, int> volOrder = <String, int>{
      for (final VolumeRow v in _volumes) v.id: v.orderIndex,
    };
    final Map<String, List<ChapterRow>> byVolume = <String, List<ChapterRow>>{};
    for (final ChapterRow c in _chapters) {
      (byVolume[c.volumeId] ??= <ChapterRow>[]).add(c);
    }
    final List<ForeshadowFlatChapter> flat = <ForeshadowFlatChapter>[];
    for (final VolumeRow v in _volumes) {
      final List<ChapterRow> list = List<ChapterRow>.of(
          byVolume[v.id] ?? const <ChapterRow>[])
        ..sort((ChapterRow a, ChapterRow b) =>
            a.orderIndex.compareTo(b.orderIndex));
      for (final ChapterRow c in list) {
        flat.add(ForeshadowFlatChapter(
          id: c.id,
          volumeId: v.id,
          title: c.title,
          outline: ForeshadowFlattener.mergeOutline(c.summary, c.notes),
          hasContent: (c.content ?? '').trim().isNotEmpty,
        ));
      }
    }
    _flat = ForeshadowFlattener.flatten(
      chapters: flat,
      volumeOrderById: volOrder,
    );
    _ledger = ForeshadowLedgerBuilder.build(_flat.sources);
  }

  /// 该书在当前项目里的全书序号（无则 0）。
  int _orderOf(ChapterRow c) => _flat.orderByChapterId[c.id] ?? 0;

  TextEditingController _hintCtrl(ChapterRow c) => _hintCtrls.putIfAbsent(
      c.id, () => TextEditingController(text: c.notes ?? ''));

  Future<void> _saveHints(ChapterRow c) async {
    final l10n = ref.read(l10nProvider);
    final String text = _hintCtrl(c).text.trim();
    try {
      await ref.read(chapterServiceProvider).updateById(
            c.id,
            ChaptersCompanion(notes: Value(text.isEmpty ? null : text)),
          );
      if (!mounted) return;
      setState(() {
        _hintDirty[c.id] = false;
        // 本地行同步（否则账本重建时读到的还是旧 notes）
        final int i = _chapters.indexWhere((ChapterRow x) => x.id == c.id);
        if (i >= 0) {
          _chapters[i] = _chapters[i].copyWith(notes: Value(text.isEmpty ? null : text));
        }
        _rebuildLedger();
      });
      _toast(l10n.t('OM.Saved', '已保存'));
    } on Object catch (e) {
      if (!mounted) return;
      _toast(l10n.tf('OM.SaveFailedFmt', '保存失败：{0}', <Object>[e]));
    }
  }

  /// 一键生成伏笔经纬：纯规则生成器给出结构 → 写入各埋线章的 `notes`。
  ///
  /// ⚠ 会**覆盖**各章 notes 里已有的「伏笔提示」小节（其余内容保留），
  /// 所以先弹确认框说明影响范围。
  Future<void> _generateForeshadow() async {
    final l10n = ref.read(l10nProvider);
    final int chapterCount = _flat.chapterCount;
    if (chapterCount < 4) {
      _toast(l10n.t('OM.FsTooShort', '章节太少（不足 4 章），无法生成伏笔经纬'));
      return;
    }
    final List<ForeshadowEntry> plan = ForeshadowGenerator.generate(
      chapterCount: chapterCount,
    );
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(l10n.t('OM.FsGenerateTitle', '生成伏笔经纬结构')),
        content: Text(l10n.tf('OM.FsGenerateBodyFmt',
            '将按纯规则生成一套伏笔骨架：\n\n{0}\n\n'
            '生成结果会写入各**埋线章**的「伏笔提示」小节（覆盖原有提示块，'
            '其余细纲内容不动）。不生成任何剧情内容 —— 每条线只留'
            '「埋线章 → 回收章」的骨架，具体是什么线由你在对应章节的细纲里填写。\n\n'
            '确认继续？',
            <Object>[ForeshadowGenerator.describe(plan, chapterCount)])),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.t('OM.FsGenerate', '生成并写入')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final Map<int, String> hints =
        ForeshadowGenerator.hintsByChapter(plan, chapterCount);
    final Map<int, ChapterRow> byOrder = <int, ChapterRow>{
      for (final ChapterRow c in _chapters)
        if (_orderOf(c) > 0) _orderOf(c): c,
    };
    int written = 0;
    for (final MapEntry<int, String> e in hints.entries) {
      final ChapterRow? c = byOrder[e.key];
      if (c == null) continue;
      final String merged = ForeshadowLedgerBuilder.upsertSection(
        c.notes ?? '',
        ForeshadowLedgerBuilder.parseHints(
          text: e.value,
          sourceOrder: e.key,
        ),
      );
      try {
        await ref.read(chapterServiceProvider).updateById(
              c.id,
              ChaptersCompanion(notes: Value(merged)),
            );
        final int i = _chapters.indexWhere((ChapterRow x) => x.id == c.id);
        if (i >= 0) {
          _chapters[i] = _chapters[i].copyWith(notes: Value(merged));
        }
        written++;
      } on Object {
        // 单章失败不阻断整体
      }
    }
    if (!mounted) return;
    setState(() {
      _hintCtrls.clear();
      _hintDirty.clear();
      _rebuildLedger();
    });
    _toast(l10n.tf('OM.FsGeneratedFmt',
        '已写入 {0} 章伏笔提示（共 {1} 条伏笔）',
        <Object>[written, plan.length]));
  }

  VolumeRow? get _selectedVolume {
    final String? id = _selectedVolumeId;
    if (id == null) return null;
    for (final VolumeRow v in _volumes) {
      if (v.id == id) return v;
    }
    return null;
  }

  TextEditingController _volumeCtrl(VolumeRow v) =>
      _volumeCtrls.putIfAbsent(v.id, () => TextEditingController(text: v.description ?? ''));

  TextEditingController _chapterCtrl(ChapterRow c) => _chapterCtrls.putIfAbsent(
      c.id, () => TextEditingController(text: c.summary ?? ''));

  Future<void> _saveVolume(VolumeRow v) async {
    final l10n = ref.read(l10nProvider);
    final String text = _volumeCtrl(v).text.trim();
    if (text.characters.length > kOutlineMaxChars) {
      _toast(l10n.tf('OM.TooLongFmt',
          '超出 {0} 字上限，请精简后再保存', <Object>[kOutlineMaxChars]));
      return;
    }
    try {
      await ref.read(volumeServiceProvider).updateById(
            v.id,
            VolumesCompanion(description: Value(text.isEmpty ? null : text)),
          );
      if (!mounted) return;
      setState(() => _volumeDirty[v.id] = false);
      _toast(l10n.t('OM.Saved', '已保存'));
    } on Object catch (e) {
      if (!mounted) return;
      _toast(l10n.tf('OM.SaveFailedFmt', '保存失败：{0}', <Object>[e]));
    }
  }

  Future<void> _saveChapter(ChapterRow c) async {
    final l10n = ref.read(l10nProvider);
    final String text = _chapterCtrl(c).text.trim();
    if (text.characters.length > kOutlineMaxChars) {
      _toast(l10n.tf('OM.TooLongFmt',
          '超出 {0} 字上限，请精简后再保存', <Object>[kOutlineMaxChars]));
      return;
    }
    try {
      await ref.read(chapterServiceProvider).updateById(
            c.id,
            ChaptersCompanion(summary: Value(text.isEmpty ? null : text)),
          );
      if (!mounted) return;
      setState(() => _chapterDirty[c.id] = false);
      _toast(l10n.t('OM.Saved', '已保存'));
    } on Object catch (e) {
      if (!mounted) return;
      _toast(l10n.tf('OM.SaveFailedFmt', '保存失败：{0}', <Object>[e]));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;

    // 侧栏切换项目时自动重载 —— 否则本页会一直显示上一个项目的卷宗。
    ref.listen<String?>(currentProjectIdProvider, (String? prev, String? next) {
      if (prev != next) {
        _volumeCtrls.clear();
        _chapterCtrls.clear();
        _volumeDirty.clear();
        _chapterDirty.clear();
        _selectedVolumeId = null;
        _load();
      }
    });

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_projectId == null) {
      return _emptyState(
        scheme,
        Icons.folder_open_outlined,
        l10n.t('OM.NoProject', '请先选择一个项目'),
      );
    }
    if (_error != null) {
      return _emptyState(
        scheme,
        Icons.error_outline,
        l10n.tf('OM.LoadFailedFmt', '载入失败：{0}', <Object>[_error!]),
      );
    }
    if (_volumes.isEmpty) {
      return _emptyState(
        scheme,
        Icons.menu_book_outlined,
        l10n.t('OM.NoVolumes', '当前项目还没有卷宗，请先在「卷宗管理」中创建'),
      );
    }

    return Column(
      children: <Widget>[
        _buildToolbar(l10n, scheme),
        const Divider(height: 1),
        Expanded(
          child: _showGrid
              ? _buildGrid(l10n, scheme)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      width: 260,
                      child: _buildVolumeList(l10n, scheme),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildDetail(l10n, scheme)),
                  ],
                ),
        ),
      ],
    );
  }

  /// 顶部工具条：细纲 / 伏笔经纬 切换 + 一键生成经纬。
  Widget _buildToolbar(L10n l10n, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: <Widget>[
          SegmentedButton<bool>(
            segments: <ButtonSegment<bool>>[
              ButtonSegment<bool>(
                value: false,
                icon: const Icon(Icons.edit_note, size: 16),
                label: Text(l10n.t('OM.TabBriefs', '细纲')),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: const Icon(Icons.timeline, size: 16),
                label: Text(l10n.t('OM.TabGrid', '伏笔经纬')),
              ),
            ],
            selected: <bool>{_showGrid},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
            onSelectionChanged: (Set<bool> s) =>
                setState(() => _showGrid = s.first),
          ),
          const Spacer(),
          if (_ledger.entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                l10n.tf('OM.FsCountFmt', '{0} 条伏笔 · 未回收 {1}',
                    <Object>[_ledger.density.entryCount, _ledger.density.openCount]),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          OutlinedButton.icon(
            onPressed: _generateForeshadow,
            icon: const Icon(Icons.auto_awesome_motion, size: 16),
            label: Text(l10n.t('OM.FsGenerate', '生成伏笔经纬')),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(L10n l10n, ColorScheme scheme) {
    if (_ledger.entries.isEmpty) {
      return _emptyState(
        scheme,
        Icons.timeline,
        l10n.t('OM.FsEmpty',
            '还没有任何伏笔提示。可在「细纲」页的每章「伏笔提示」里手写，或点右上角「生成伏笔经纬」自动生成一套骨架。'),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(
          l10n.t('OM.FsTitle', '伏笔经纬（设定 → 提醒 → 收回）'),
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.t('OM.FsHint',
              '上方是伏笔设定轴、下方是收回轴，连线从埋线章连到回收章，小圆点是途中提醒，'
              '红色底带是转折章（剧情单元末章）。点击某章可跳到该章细纲。'),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        ForeshadowGridView(
          ledger: _ledger,
          onTapOrder: (int order) {
            for (final ChapterRow c in _chapters) {
              if (_orderOf(c) == order) {
                setState(() {
                  _showGrid = false;
                  _selectedVolumeId = c.volumeId;
                });
                break;
              }
            }
          },
        ),
      ],
    );
  }

  Widget _emptyState(ColorScheme scheme, IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 44, color: scheme.outline),
          const SizedBox(height: 10),
          Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(ref.read(l10nProvider).t('Common.Refresh', '刷新')),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 左栏：卷宗列表
  // ---------------------------------------------------------------------------
  Widget _buildVolumeList(L10n l10n, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: <Widget>[
              Icon(Icons.account_tree_outlined, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.t('OM.VolumeList', '卷宗'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.t('Common.Refresh', '刷新'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: _load,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: _volumes.length,
            itemBuilder: (BuildContext context, int i) {
              final VolumeRow v = _volumes[i];
              final bool selected = v.id == _selectedVolumeId;
              final List<ChapterRow> chaps = _chaptersOf(v.id);
              final int briefed = chaps
                  .where((ChapterRow c) => (c.summary ?? '').trim().isNotEmpty)
                  .length;
              return ListTile(
                dense: true,
                selected: selected,
                selectedColor: scheme.primary,
                leading: CircleAvatar(
                  radius: 12,
                  backgroundColor: selected
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  child: Text(
                    '${v.orderIndex}',
                    style: TextStyle(
                      fontSize: 11,
                      color: selected
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                title: Text(
                  v.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  l10n.tf('OM.VolumeSubtitleFmt', '{0} 章 · 已写细纲 {1}',
                      <Object>[chaps.length, briefed]),
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () => setState(() => _selectedVolumeId = v.id),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 右栏：卷大纲 + 章细纲
  // ---------------------------------------------------------------------------
  Widget _buildDetail(L10n l10n, ColorScheme scheme) {
    final VolumeRow? v = _selectedVolume;
    if (v == null) {
      return _emptyState(
        scheme,
        Icons.touch_app_outlined,
        l10n.t('OM.PickVolume', '请在左侧选择一个卷宗'),
      );
    }
    final List<ChapterRow> chaps = _chaptersOf(v.id);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(
          l10n.tf('OM.DetailTitleFmt', '第 {0} 卷 · {1}',
              <Object>[v.orderIndex, v.title]),
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _buildVolumeOutlineEditor(l10n, scheme, v),
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            Icon(Icons.list_alt_outlined, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              l10n.t('OM.ChapterBriefs', '章细纲'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.tf('OM.ChapterCountFmt', '{0} 章', <Object>[chaps.length]),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (chaps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                l10n.t('OM.NoChapters', '本卷还没有章节，请先在「章节管理」中添加'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          for (final ChapterRow c in chaps) ...[
            _buildChapterBriefCard(l10n, scheme, c),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildVolumeOutlineEditor(
    L10n l10n,
    ColorScheme scheme,
    VolumeRow v,
  ) {
    final TextEditingController ctrl = _volumeCtrl(v);
    final bool dirty = _volumeDirty[v.id] == true;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.menu_book_outlined, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  l10n.t('OM.VolumeOutline', '本卷大纲'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (dirty)
                  Text(
                    l10n.t('OM.Unsaved', '未保存'),
                    style: TextStyle(fontSize: 11, color: scheme.error),
                  ),
                _charCounter(l10n, scheme, ctrl.text),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.t('OM.VolumeOutlineHint',
                  '整卷的核心冲突、主角阶段目标、重要转折与结局走向。保存后，本卷所有章节的 AI 写作都会把它作为参考。'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              minLines: 5,
              maxLines: 12,
              style: const TextStyle(fontSize: 14, height: 1.7),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '例如：本卷写陈九从看祠杂役一步步接近祠堂夹层里的血书……',
              ),
              onChanged: (_) => setState(() => _volumeDirty[v.id] = true),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => _saveVolume(v),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: Text(l10n.t('OM.SaveVolume', '保存卷大纲')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChapterBriefCard(
    L10n l10n,
    ColorScheme scheme,
    ChapterRow c,
  ) {
    final TextEditingController ctrl = _chapterCtrl(c);
    final bool dirty = _chapterDirty[c.id] == true;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.article_outlined, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.tf('OM.ChapterTitleFmt', '第 {0} 章 · {1}',
                        <Object>[c.orderIndex, c.title]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
                // 全书序号 —— 伏笔提示里的「第 N 章」用的就是这个号
                if (_orderOf(c) > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      l10n.tf('OM.GlobalOrderFmt', '全书第 {0} 章',
                          <Object>[_orderOf(c)]),
                      style: TextStyle(
                          fontSize: 10,
                          color: scheme.primary,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                if ((c.content ?? '').trim().isNotEmpty)
                  Text(
                    l10n.tf('OM.WordsFmt', '正文 {0} 字',
                        <Object>[(c.content ?? '').trim().length]),
                    style: TextStyle(
                        fontSize: 10, color: scheme.onSurfaceVariant),
                  ),
                if (dirty) ...[
                  const SizedBox(width: 6),
                  Text(
                    l10n.t('OM.Unsaved', '未保存'),
                    style: TextStyle(fontSize: 11, color: scheme.error),
                  ),
                ],
                _charCounter(l10n, scheme, ctrl.text),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: ctrl,
              minLines: 3,
              maxLines: 8,
              style: const TextStyle(fontSize: 13, height: 1.6),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: l10n.t('OM.ChapterBriefHint',
                    '本章要发生什么、谁出场、关键转折、章末钩子……（保存后 AI 写作会参考）'),
              ),
              onChanged: (_) => setState(() => _chapterDirty[c.id] = true),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => _saveChapter(c),
                icon: const Icon(Icons.save_outlined, size: 15),
                label: Text(l10n.t('OM.SaveBrief', '保存细纲')),
              ),
            ),
            const SizedBox(height: 10),
            _buildHintEditor(l10n, scheme, c),
          ],
        ),
      ),
    );
  }

  /// 伏笔提示编辑器（落 `Chapters.notes`）。
  ///
  /// 与参考项目同构：**提示就写在大纲旁边**，作者只维护这一处；
  /// 账本、经纬图、写作提示词全部从这份文本派生。
  Widget _buildHintEditor(L10n l10n, ColorScheme scheme, ChapterRow c) {
    final TextEditingController ctrl = _hintCtrl(c);
    final bool dirty = _hintDirty[c.id] == true;
    final ForeshadowChapterLink link = _ledger.linkAt(_orderOf(c));
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.hub_outlined, size: 14, color: scheme.secondary),
              const SizedBox(width: 5),
              Text(
                l10n.t('OM.HintsLabel', '伏笔提示'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  link.isEmpty
                      ? l10n.t('OM.HintsNone', '本章无联动')
                      : l10n.tf('OM.HintsLinkFmt',
                          '埋 {0} · 提醒 {1} · 回收 {2}',
                          <Object>[
                            link.setups.length,
                            link.reminders.length,
                            link.payoffs.length,
                          ]),
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                ),
              ),
              if (dirty)
                Text(l10n.t('OM.Unsaved', '未保存'),
                    style: TextStyle(fontSize: 11, color: scheme.error)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.t('OM.HintsFormatHint',
                '格式：- T001（第12章 → 第50章；提醒第30章）：一句话铺垫方向。'
                '章号用「全书第 N 章」（见上方标签）。'),
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontSize: 12, height: 1.5, fontFamily: 'monospace'),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              border: const OutlineInputBorder(),
              hintText: '## 伏笔提示\n- T001（第${_orderOf(c) > 0 ? _orderOf(c) : 1}章 → 第${_orderOf(c) > 0 ? _orderOf(c) + 8 : 9}章）：一句话方向',
              hintStyle: TextStyle(fontSize: 11, color: scheme.outline),
            ),
            onChanged: (_) => setState(() => _hintDirty[c.id] = true),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => _saveHints(c),
              icon: const Icon(Icons.save_outlined, size: 15),
              label: Text(l10n.t('OM.SaveHints', '保存伏笔提示')),
            ),
          ),
        ],
      ),
    );
  }

  /// 字数计数（超上限变红 —— 保存前就看见，而不是等异常）。
  Widget _charCounter(L10n l10n, ColorScheme scheme, String text) {
    final int n = text.trim().characters.length;
    final bool over = n > kOutlineMaxChars;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        l10n.tf('OM.CharCountFmt', '{0} / {1}',
            <Object>[n, kOutlineMaxChars]),
        style: TextStyle(
          fontSize: 10,
          color: over ? scheme.error : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
