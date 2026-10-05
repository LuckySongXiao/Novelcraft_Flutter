import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/book_review_settings.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/rwkv_cloud_provider.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

/// provider 存储键（`provider_cfg.{kind}` 的 `kind`）→ ModelManager 注册名。
///
/// 与 `ai_configuration_page.dart` 的 `_ProviderConfig.registeredName` 保持一致，
/// 用于把持久化的 provider 配置还原成「平台下拉」里的可选项。
const Map<String, String> _kindToRegisteredName = <String, String>{
  'deepseek': 'DeepSeek',
  'zhipu': 'ZhipuAI',
  'openrouter': 'OpenRouter',
  'ollama': 'Ollama',
  'rwkv': 'RWKV',
  'rwkvCloud': 'RWKV Cloud',
  'custom': 'Custom',
};

/// 客座读者与 13B 高级审查员配置卡。
///
/// 平台 / 模型一律改为**下拉选择**：
///  - 平台：列出「已配置（ModelManager 已注册）+ 已持久化」的供应商；
///  - 模型：直接拉取已配置好的模型——持久化的默认模型、RWKV Cloud 端点模型，
///    以及运行时 `GET {baseUrl}/models` 的可用模型。
class BookReviewSettingsCard extends ConsumerStatefulWidget {
  const BookReviewSettingsCard({super.key});

  @override
  ConsumerState<BookReviewSettingsCard> createState() =>
      _BookReviewSettingsCardState();
}

class _BookReviewSettingsCardState extends ConsumerState<BookReviewSettingsCard> {
  late List<GuestReaderProfile> _guests;
  late String _seniorProvider;
  late String _seniorModel;

  /// 读者称呼 / 品味两个文本框的控制器（固定 3 个客座读者）。
  late final List<TextEditingController> _guestName;
  late final List<TextEditingController> _guestTaste;

  /// 平台 → 该平台已配置/可拉取的模型 id 集合。
  final Map<String, List<String>> _models = <String, List<String>>{};

  /// 正在拉取模型列表的平台（用于显示 loading / 防重复请求）。
  final Set<String> _loading = <String>{};

  /// 平台候选列表。
  List<String> _platforms = <String>[];

  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final L10n l10n = ref.read(l10nProvider);
    final BookReviewSettings settings = ref.read(bookReviewSettingsProvider);
    _seniorProvider = settings.seniorProvider;
    _seniorModel = settings.seniorModel;
    // 尚未保存过客座读者时，用**当前语言**的占位默认值（已保存的称呼 / 品味
    // 属于用户数据，切语言不覆盖）。
    _guests = List<GuestReaderProfile>.generate(
      3,
      (int index) => settings.guestReaders.length > index
          ? settings.guestReaders[index]
          : GuestReaderProfile(
              id: 'guest-${index + 1}',
              name: l10n.tf(
                'BRS.GuestDefaultName',
                '客座读者 {0}',
                <Object>[index + 1],
              ),
              taste: l10n.t(
                'BRS.GuestDefaultTaste',
                '普通读者：关注可读性、节奏和情绪是否自然',
              ),
            ),
    );
    _guestName = <TextEditingController>[
      for (final GuestReaderProfile g in _guests)
        TextEditingController(text: g.name),
    ];
    _guestTaste = <TextEditingController>[
      for (final GuestReaderProfile g in _guests)
        TextEditingController(text: g.taste),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_bootstrap()));
  }

  @override
  void dispose() {
    for (final TextEditingController c in _guestName) {
      c.dispose();
    }
    for (final TextEditingController c in _guestTaste) {
      c.dispose();
    }
    super.dispose();
  }

  /// 收集「已配置好的平台」，并把每个平台**已保存的默认模型**作为下拉候选，
  /// 最后对每个平台异步拉取运行时模型列表补充。
  Future<void> _bootstrap() async {
    final Set<String> platforms = <String>{'RWKV', 'RWKV Cloud'};

    // 1) ModelManager 已注册（= 已保存 / 已测试连接）的 provider。
    try {
      for (final IModelProvider p
          in ref.read(modelManagerProvider).getAllProviders()) {
        if (p.providerName.trim().isNotEmpty) {
          platforms.add(p.providerName.trim());
        }
      }
    } on Object {
      // 注册表读取失败不影响其它来源
    }

    // 2) 持久化的 provider 配置：平台名 + 默认模型。
    try {
      final Map<String, Map<String, Object?>> all =
          await ref.read(modelConfigStoreProvider).loadAll();
      for (final MapEntry<String, Map<String, Object?>> e in all.entries) {
        final String? name = _kindToRegisteredName[e.key];
        if (name == null) continue;
        platforms.add(name);
        final Object? model = e.value['defaultModel'];
        if (model is String && model.trim().isNotEmpty) {
          _addModel(name, model.trim());
        }
      }
    } on Object {
      // 损坏配置跳过
    }

    // 3) RWKV Cloud 各端点的默认模型（云端模型名与平台名分列存储）。
    try {
      final kv = await ref.read(keyValueStoreProvider.future);
      final String? raw = await kv.readJson('ai_config', 'rwkv.cloud_profiles');
      if (raw != null && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final Object? item in decoded) {
            if (item is! Map) continue;
            platforms.add('RWKV Cloud');
            final Object? model = item['defaultModel'];
            if (model is String && model.trim().isNotEmpty) {
              _addModel('RWKV Cloud', model.trim());
            }
          }
        }
      }
    } on Object {
      // 端点配置缺失时忽略
    }

    // 3b) RWKV Cloud 具体端点（provider 名形如 `RWKV Cloud::{id}`，与
    // `AgentEndpointRegistry.key` 一致）：可指定走哪个云端端点。
    try {
      final Map<String, RwkvCloudEndpointProfile> profiles =
          ref.read(agentEndpointRegistryProvider).profiles;
      for (final MapEntry<String, RwkvCloudEndpointProfile> e
          in profiles.entries) {
        platforms.add(e.key);
        final String m = e.value.defaultModel.trim();
        if (m.isNotEmpty) _addModel(e.key, m);
      }
    } on Object {
      // 端点注册表不可用时忽略
    }

    // 4) 当前设置里已选用的平台（可能未注册，仍要能在下拉里看到）。
    if (_seniorProvider.trim().isNotEmpty) platforms.add(_seniorProvider.trim());
    for (final GuestReaderProfile g in _guests) {
      if (g.provider.trim().isNotEmpty) platforms.add(g.provider.trim());
    }

    if (!mounted) return;
    setState(() {
      _platforms = platforms.toList()..sort();
      _ready = true;
    });

    // 5) 拉取各平台可用模型列表（含运行时 /models）。
    for (final String p in _platforms) {
      unawaited(_ensureModels(p));
    }
  }

  void _addModel(String platform, String id) {
    final String key = platform.trim();
    if (key.isEmpty || id.trim().isEmpty) return;
    final List<String> list = _models.putIfAbsent(key, () => <String>[]);
    if (!list.contains(id)) list.add(id);
  }

  /// 拉取指定平台的可用模型；结果并入 [_models]。
  ///
  /// 只对**已注册且可用**的 provider 请求（未配置的平台解析为 null，自然跳过）。
  Future<void> _ensureModels(String platform) async {
    final String name = platform.trim();
    if (name.isEmpty || _loading.contains(name)) return;
    _loading.add(name);
    List<String> ids = <String>[];
    try {
      final IModelProvider? p = ref.read(agentProviderResolverProvider)(name);
      if (p != null) {
        final List<ModelInfo> list = await p.getAvailableModels();
        ids = <String>{
          for (final ModelInfo e in list)
            if (e.id.trim().isNotEmpty) e.id.trim(),
        }.toList()
          ..sort();
      }
    } on Object {
      ids = <String>[];
    }
    if (!mounted) return;
    setState(() {
      _loading.remove(name);
      for (final String id in ids) {
        _addModel(name, id);
      }
    });
  }

  Future<void> _save() async {
    await ref
        .read(bookReviewSettingsProvider.notifier)
        .update(
          BookReviewSettings(
            seniorProvider: _seniorProvider.trim(),
            seniorModel: _seniorModel.trim(),
            guestReaders: _guests,
            enableSeniorReview: true,
          ),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ref.read(l10nProvider).t('BRS.Saved', '审查团队配置已保存'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final L10n l10n = ref.watch(l10nProvider);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.groups_2_outlined, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.t('BRS.Title', '客座读者与 13B 高级审查员'),
                ),
              ),
              TextButton(
                onPressed: _save,
                child: Text(l10n.t('Common.Save', '保存')),
              ),
            ],
          ),
          Text(
            l10n.t(
              'BRS.Intro',
              '7B 会读取客座意见，再向 13B 请教；13B 可认可 7B 或提出修订意见。'
              '平台与模型从已配置的供应商中下拉选择，拉到模型列表即可直接选用。',
            ),
          ),
          const SizedBox(height: 8),
          if (!_ready)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _platformField(
                  label: l10n.t('BRS.SeniorPlatform', '13B 审查员平台'),
                  value: _seniorProvider,
                  onChanged: (String v) => setState(() {
                    _seniorProvider = v;
                    _seniorModel = '';
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _modelField(
                  label: l10n.t('BRS.SeniorModel', '13B 审查员模型'),
                  platform: _seniorProvider,
                  value: _seniorModel,
                  onChanged: (String v) =>
                      setState(() => _seniorModel = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (int index = 0; index < _guests.length; index++)
            _guestEditor(index, l10n),
        ],
      ),
    );
  }

  Widget _guestEditor(int index, L10n l10n) {
    final GuestReaderProfile profile = _guests[index];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Switch(
                value: profile.enabled,
                onChanged: (bool enabled) => setState(() {
                  _guests[index] = _guests[index].copyWith(enabled: enabled);
                }),
              ),
              Expanded(
                child: TextField(
                  controller: _guestName[index],
                  decoration: InputDecoration(
                    labelText: l10n.t('BRS.GuestName', '读者称呼'),
                    isDense: true,
                  ),
                  onChanged: (String v) =>
                      _guests[index] = _guests[index].copyWith(name: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _platformField(
                  label: l10n.t('BRS.Platform', '平台'),
                  value: profile.provider,
                  onChanged: (String v) => setState(() {
                    _guests[index] = _guests[index].copyWith(
                      provider: v,
                      model: '',
                    );
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _modelField(
                  label: l10n.t('BRS.Model', '模型'),
                  platform: profile.provider,
                  value: profile.model,
                  onChanged: (String v) => setState(() {
                    _guests[index] = _guests[index].copyWith(model: v);
                  }),
                ),
              ),
            ],
          ),
          TextField(
            controller: _guestTaste[index],
            decoration: InputDecoration(
              labelText: l10n.t('BRS.GuestTaste', '人类品味/关注点'),
              isDense: true,
            ),
            onChanged: (String v) =>
                _guests[index] = _guests[index].copyWith(taste: v),
          ),
        ],
      ),
    );
  }

  /// 平台下拉：候选 = 已配置平台 + 当前值（防止历史值被丢弃）。
  Widget _platformField({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    final L10n l10n = ref.watch(l10nProvider);
    final String current = value.trim();
    final List<String> items = <String>{
      ..._platforms,
      if (current.isNotEmpty) current,
    }.toList()..sort();
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('platform::$label::$current'),
      initialValue: current.isEmpty ? null : current,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      hint: Text(l10n.t('BRS.PickPlatform', '选择已配置平台')),
      items: <DropdownMenuItem<String>>[
        for (final String n in items)
          DropdownMenuItem<String>(
            value: n,
            child: Text(n, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (String? v) {
        if (v == null) return;
        onChanged(v);
        unawaited(_ensureModels(v));
      },
    );
  }

  /// 模型下拉：候选 = 该平台已配置/拉取到的模型 + 当前值；空值代表用平台默认模型。
  Widget _modelField({
    required String label,
    required String platform,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    final L10n l10n = ref.watch(l10nProvider);
    final String p = platform.trim();
    final String current = value.trim();
    final bool loading = _loading.contains(p);
    final List<String> models = <String>{
      ...?_models[p],
      if (current.isNotEmpty) current,
    }.toList()..sort();
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('model::$label::$p::$current'),
      initialValue: current,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: loading
            ? const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
      ),
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(
          value: '',
          child: Text(
            l10n.t('BRS.PlatformDefault', '（使用平台默认模型）'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final String m in models)
          DropdownMenuItem<String>(
            value: m,
            child: Text(m, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (String? v) => onChanged(v ?? ''),
    );
  }
}
