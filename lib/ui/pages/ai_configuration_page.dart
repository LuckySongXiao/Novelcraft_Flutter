import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../application/services/agent_endpoint_registry.dart';
import '../../data/storage/key_value_store.dart';
import '../../l10n/l10n.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/openai_compatible_provider.dart';
import '../../ai/providers/ollama_provider.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/providers/rwkv_cloud_provider.dart';
import '../../ai/rwkv/rwkv_engine.dart'
    show RwkvEngineConfig, RwkvNativeOptions;
import '../../ai/rwkv/g1k_model_preset.dart';
import '../../ai/runtime_settings.dart';
import '../../ai/rwkv/rwkv_gpu_probe.dart';
import '../../ai/rwkv/rwkv_model_fit.dart';
import '../../ai/rwkv/rwkv_models.dart' show RwkvLocalModel;
import '../../ai/rwkv/rwkv_official_resources.dart'
    show
        OfficialServerVariant,
        OfficialServerVariantX,
        RwkvCancelHandle,
        RwkvDownloadCancelledException,
        RwkvDownloadPhase,
        RwkvDownloadPhaseX,
        RwkvDownloadProgress,
        RwkvOfficialModel,
        RwkvModelQuantX;
import '../../ai/providers/deepseek_provider.dart';
import '../../ai/providers/openrouter_provider.dart';
import '../../ai/providers/zhipu_provider.dart';
import '../../ai/workflow/dual_agent_workflow.dart';
import 'book_review_settings_card.dart';

enum _ProviderKind {
  deepseek,
  zhipu,

  /// OpenRouter（OpenAI 兼容聚合平台，默认模型 `apodex/apodex-1.1-mini:free`）。
  openrouter,
  ollama,
  rwkv,

  /// 云端 RWKV 官方端点（`api-7b.rwkvos.com`，Cloudflare Access 保护）
  rwkvCloud,
  custom,
}

String _pvdLabel(_ProviderKind kind, bool isEnglish) => switch (kind) {
  _ProviderKind.deepseek => 'DeepSeek',
  _ProviderKind.zhipu => isEnglish ? 'Zhipu AI' : '智谱 AI',
  _ProviderKind.openrouter => 'OpenRouter',
  _ProviderKind.ollama => isEnglish ? 'Ollama (Local)' : 'Ollama (本地)',
  _ProviderKind.rwkv => isEnglish ? 'RWKV (Local)' : 'RWKV (本地)',
  _ProviderKind.rwkvCloud =>
    isEnglish ? 'RWKV Cloud (Official)' : 'RWKV 云端（官方）',
  _ProviderKind.custom => isEnglish ? 'OpenAI Compatible' : 'OpenAI 兼容',
};

extension _ProviderKindX on _ProviderKind {
  IconData get icon => switch (this) {
    _ProviderKind.deepseek => Icons.auto_awesome,
    _ProviderKind.zhipu => Icons.lightbulb_outline,
    _ProviderKind.openrouter => Icons.hub_outlined,
    _ProviderKind.ollama => Icons.computer_outlined,
    _ProviderKind.rwkv => Icons.memory_outlined,
    _ProviderKind.rwkvCloud => Icons.cloud_outlined,
    _ProviderKind.custom => Icons.settings_input_component_outlined,
  };

  bool get isLocal =>
      this == _ProviderKind.ollama || this == _ProviderKind.rwkv;
}

class _ProviderConfig {
  final _ProviderKind kind;
  String baseUrl;
  String apiKey;
  String defaultModel;
  int timeoutSeconds;
  double defaultTemperature;
  int defaultMaxTokens;
  bool enableStreaming;

  String? rwkvLocalExecutable;

  String? rwkvLocalModelPath;

  /// 内置引擎（rwkv_lightning_cuda）强制外置的词表路径（PITFALLS §27.1）
  String? rwkvLocalVocabPath;

  /// 本地 server 的引擎变体；`cuda12`/`cuda13` 表示走内置引擎
  OfficialServerVariant? rwkvLocalServerVariant;

  /// 会话推理是否走 `/state/chat/completions`（服务端按 `session_id` 维护 state）。
  ///
  /// 默认 `true`：本项目的目标引擎 `rwkv_lightning_cuda` 支持该路由，且这是
  /// RNN 的 O(1) 上下文接续（每轮只发增量，不重发历史，实测有效）。
  /// 若换成 llama.cpp / rwkv.cpp 等不提供 `/state/*` 的引擎，请关掉。
  bool rwkvUseStatefulRoute = true;

  /// Cloudflare Access Service Token 的 Client Id（形如 `xxx.access`）。
  ///
  /// ⚠ 头名按字节精确比较，拼错**不会** 401，而是静默返回 HTML 登录页
  /// （PITFALLS §27.2）。
  String cfAccessClientId = '';

  /// Cloudflare Access Service Token 的 Client Secret。
  String cfAccessClientSecret = '';

  /// 思考前缀模式（`none`/`fast`/`free`/`preferChinese`/`en`/`enShort`/`enLong`）
  String rwkvThinkType = 'fast';

  /// 引擎级并发上限（客户端侧限流）。
  ///
  /// ⚠ 真实并发由**服务端**的 FIFO admission queue 决定（`/v1/server/status` 的
  /// `available_bsz`，实测 169；单卡 4090 官方标称可扛 900+ 并发）。默认 16
  /// 对齐实测吞吐峰值（PITFALLS §31.3）；追求极限可在配置里调高。
  int rwkvMaxConcurrentSessions = 16;

  _ProviderConfig(this.kind)
    : baseUrl = switch (kind) {
        _ProviderKind.deepseek => 'https://api.deepseek.com/v1',
        _ProviderKind.zhipu => 'https://open.bigmodel.cn/api/paas/v4',
        _ProviderKind.openrouter => kOpenRouterDefaultBaseUrl,
        _ProviderKind.ollama => 'http://localhost:11434',
        _ProviderKind.rwkv => 'http://localhost:8000',
        _ProviderKind.rwkvCloud => kRwkvCloudDefaultBaseUrl,
        _ProviderKind.custom => 'https://api.openai.com/v1',
      },
      apiKey = '',
      defaultModel = switch (kind) {
        _ProviderKind.deepseek => 'deepseek-chat',
        _ProviderKind.zhipu => 'glm-4-flash',
        _ProviderKind.openrouter => kOpenRouterDefaultModel,
        _ProviderKind.ollama => 'qwen2.5:7b',
        _ProviderKind.rwkv => 'rwkv7-g1i',
        _ProviderKind.rwkvCloud => '',
        _ProviderKind.custom => 'gpt-3.5-turbo',
      },
      timeoutSeconds = 120,
      defaultTemperature = 0.7,
      defaultMaxTokens = 4000,
      enableStreaming = true;

  String get registeredName => switch (kind) {
    _ProviderKind.deepseek => 'DeepSeek',
    _ProviderKind.zhipu => 'ZhipuAI',
    _ProviderKind.openrouter => 'OpenRouter',
    _ProviderKind.ollama => 'Ollama',
    _ProviderKind.rwkv => 'RWKV',
    _ProviderKind.rwkvCloud => 'RWKV Cloud',
    _ProviderKind.custom => 'Custom',
  };

  /// 模型最大参考长度 —— **恒等于「最大令牌数」**（用户约定：两者必须相等）。
  ///
  /// 用 getter 而非独立字段，从根本上杜绝「保存后两处数值漂移」。
  int get maxReferenceLength => defaultMaxTokens;
}

class AIConfigurationPage extends ConsumerStatefulWidget {
  const AIConfigurationPage({super.key});

  @override
  ConsumerState<AIConfigurationPage> createState() =>
      _AIConfigurationPageState();
}

/// 最大令牌数滑动档位节点：512 → 1M（14 档）。
///
/// ⚠ 24K(24576) / 25K(25600) 两个**非 2 的幂**档位是刻意插入的：RWKV 官方
/// G1K 云端模型的上下文窗口标称 `ctx25600`（= 25K），若档位表只有
/// 16K → 32K，用户拖滑块会被吸附到 32K，永远选不出模型真实支持的 25K。
const List<int> kMaxTokensSteps = <int>[
  512, // 512
  1024, // 1K
  2048, // 2K
  4096, // 4K
  8192, // 8K
  16384, // 16K
  24576, // 24K
  25600, // 25K（RWKV G1K 云端 ctx25600）
  32768, // 32K
  65536, // 64K
  131072, // 128K
  262144, // 256K
  524288, // 512K
  1048576, // 1M
];

/// 档位刻度标签（与 [kMaxTokensSteps] 一一对应）。
const List<String> kMaxTokensStepLabels = <String>[
  '512',
  '1K',
  '2K',
  '4K',
  '8K',
  '16K',
  '24K',
  '25K',
  '32K',
  '64K',
  '128K',
  '256K',
  '512K',
  '1M',
];

/// 值 → 档位标签（16K/32K/.../1M；非档位值显示实际数值）。
String maxTokensLabel(int tokens) {
  final int idx = kMaxTokensSteps.indexOf(tokens);
  return idx >= 0 ? kMaxTokensStepLabels[idx] : '$tokens';
}

/// 值 → 最近档位的滑块索引（存量自定义值自动吸附）。
int maxTokensSliderIndex(int tokens) {
  int best = 0;
  int bestDiff = 1 << 62;
  for (int i = 0; i < kMaxTokensSteps.length; i++) {
    final int d = (kMaxTokensSteps[i] - tokens).abs();
    if (d < bestDiff) {
      bestDiff = d;
      best = i;
    }
  }
  return best;
}

class _AIConfigurationPageState extends ConsumerState<AIConfigurationPage> {
  _ProviderKind _selectedKind = _ProviderKind.deepseek;
  final Map<_ProviderKind, _ProviderConfig> _configs = {
    for (final k in _ProviderKind.values) k: _ProviderConfig(k),
  };
  final Map<String, bool> _availableMap = {};
  final Map<String, ProviderStatistics> _statsMap = {};
  String? _defaultProvider;
  bool _testing = false;
  ConnectionTestResult? _lastTest;
  String? _connectingTo;
  List<RwkvCloudEndpointProfile> _cloudProfiles = kRwkvOfficialEndpointProfiles;
  String _activeCloudProfileId = 'official-7b';
  List<String> _cloudModelIds = <String>[];
  bool _cloudModelsLoading = false;
  String? _cloudModelsError;
  int _cloudModelsRequestId = 0;

  final List<RwkvLocalModel> _rwkvModels = <RwkvLocalModel>[];
  bool _rwkvScanning = false;
  bool _rwkvLaunching = false;
  bool _rwkvStopping = false;

  OfficialServerVariant _serverVariant = OfficialServerVariant.vulkan;
  RwkvDownloadProgress? _serverInstallProgress;
  RwkvDownloadProgress? _modelDownloadProgress;
  RwkvCancelHandle? _serverInstallCancelHandle;
  RwkvCancelHandle? _modelDownloadCancelHandle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadPersistedRwkvPrefs();
      await _loadPersistedProviderConfigs();
      await _loadRwkvCloudProfiles();
      _refreshFromManager();
      // 必须放在 provider 配置与默认 provider 都恢复之后：让「模型上下文
      // 窗口」跟随默认 provider 的模型名刷新（详见方法注释）。
      await _syncContextWindowFromModel();
      _ensureRwkvScanned();
    });
  }

  static const String _kvScopeAiConfig = 'ai_config';
  static const String _kvKeyRwkvCfg = 'rwkv.configuration';
  static const String _kvKeyRuntimeSettings = 'runtime_settings';

  /// 云端 RWKV（api-7b.rwkvos.com）的配置：baseUrl + CF Service Token。
  static const String _kvKeyRwkvCloudCfg = 'rwkv.cloud_configuration';
  static const String _kvKeyRwkvCloudProfiles = 'rwkv.cloud_profiles';
  static const String _kvKeyRwkvCloudActiveProfile =
      'rwkv.cloud_active_profile';
  static const String _kvScopeUiPrefs = 'ui_prefs';
  static const String _kvKeyRwkvServerVariant = 'rwkv.server_variant';

  Future<void> _loadPersistedRwkvPrefs() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      String? cfgJson;
      String? variantJson;
      try {
        cfgJson = await kv.readJson(_kvScopeAiConfig, _kvKeyRwkvCfg);
      } catch (_) {}
      try {
        variantJson = await kv.readJson(
          _kvScopeUiPrefs,
          _kvKeyRwkvServerVariant,
        );
      } catch (_) {}
      String? cloudJson;
      try {
        cloudJson = await kv.readJson(_kvScopeAiConfig, _kvKeyRwkvCloudCfg);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        if (cfgJson != null && cfgJson.isNotEmpty) {
          try {
            final Object? decoded = jsonDecode(cfgJson);
            if (decoded is Map<String, Object?>) {
              final c = RwkvConfiguration.fromJson(decoded);
              final cfg = _configs[_ProviderKind.rwkv]!;
              cfg.baseUrl = c.baseUrl;
              cfg.defaultModel = c.defaultModel;
              cfg.defaultMaxTokens = c.defaultMaxTokens;
              if ((c.localExecutable ?? '').isNotEmpty) {
                cfg.rwkvLocalExecutable = c.localExecutable;
              }
              if ((c.localModelPath ?? '').isNotEmpty) {
                cfg.rwkvLocalModelPath = c.localModelPath;
              }
              if ((c.localVocabPath ?? '').isNotEmpty) {
                cfg.rwkvLocalVocabPath = c.localVocabPath;
              }
              cfg.rwkvLocalServerVariant = c.localServerVariant;
              // 引擎级参数（原生生成参数 / stateful 开关 / 并发上限）
              final RwkvEngineConfig? ec = c.engineConfig;
              if (ec != null) {
                cfg.rwkvUseStatefulRoute = ec.useStatefulRoute;
                cfg.rwkvMaxConcurrentSessions = ec.maxConcurrentSessions;
                final String? tt = ec.nativeOptions.thinkType;
                if (tt != null && tt.isNotEmpty) cfg.rwkvThinkType = tt;
              }
            }
          } catch (_) {}
        }
        if (variantJson != null && variantJson.isNotEmpty) {
          try {
            _serverVariant = OfficialServerVariant.values.firstWhere(
              (OfficialServerVariant v) => v.name == variantJson,
              orElse: () => OfficialServerVariant.vulkan,
            );
          } catch (_) {}
        }
        if (cloudJson != null && cloudJson.isNotEmpty) {
          try {
            final Object? decoded = jsonDecode(cloudJson);
            if (decoded is Map<String, Object?>) {
              final RwkvCloudConfiguration c =
                  RwkvCloudConfiguration.fromCloudMap(decoded);
              final _ProviderConfig cc = _configs[_ProviderKind.rwkvCloud]!;
              cc.baseUrl = c.baseUrl;
              cc.defaultModel = c.defaultModel;
              cc.timeoutSeconds = c.timeoutSeconds;
              cc.defaultMaxTokens = c.defaultMaxTokens;
              cc.defaultTemperature = c.defaultTemperature;
              cc.enableStreaming = c.enableStreaming;
              cc.cfAccessClientId = c.cfAccessClientId;
              cc.cfAccessClientSecret = c.cfAccessClientSecret;
            }
          } catch (_) {}
        }
      });
    } catch (_) {}
  }

  /// 启动时把持久化的 provider 配置回填到页面字段（`provider_cfg.*`）。
  ///
  /// 写入方是 [_persistProviderConfig]，实例侧恢复方是 `ProviderAutoRestore`
  /// （启动时 initialize + 注册）。**本方法补的是 UI 侧**：缺了它，provider
  /// 实例虽已恢复，但页面字段仍是 `_ProviderConfig(kind)` 的默认值，用户看到
  /// 「配置全没了 / 重启后取不到模型配置」，只能重填一遍。
  Future<void> _loadPersistedProviderConfigs() async {
    Map<String, Map<String, Object?>> all;
    String? def;
    try {
      all = await ref.read(modelConfigStoreProvider).loadAll();
      def = await ref.read(modelConfigStoreProvider).loadDefault();
    } on Object {
      return;
    }
    if (!mounted) return;
    setState(() {
      for (final MapEntry<String, Map<String, Object?>> e in all.entries) {
        final _ProviderKind? kind = _kindByStorageKey(e.key);
        if (kind == null) continue;
        _applyPersistedJson(_configs[kind]!, e.value);
      }
      if (def != null && def.isNotEmpty) _defaultProvider = def;
    });
  }

  Future<void> _loadRwkvCloudProfiles() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final String? rawProfiles = await kv.readJson(
        _kvScopeAiConfig,
        _kvKeyRwkvCloudProfiles,
      );
      final String? rawActive = await kv.readJson(
        _kvScopeAiConfig,
        _kvKeyRwkvCloudActiveProfile,
      );

      final Map<String, RwkvCloudEndpointProfile> profilesById =
          <String, RwkvCloudEndpointProfile>{
            for (final RwkvCloudEndpointProfile profile
                in kRwkvOfficialEndpointProfiles)
              profile.id: profile,
          };
      if (rawProfiles != null && rawProfiles.isNotEmpty) {
        final Object? decoded = jsonDecode(rawProfiles);
        if (decoded is List) {
          for (final Object? item in decoded) {
            if (item is! Map) continue;
            final RwkvCloudEndpointProfile profile =
                RwkvCloudEndpointProfile.fromJson(
                  item.map(
                    (Object? key, Object? value) =>
                        MapEntry<String, Object?>('$key', value),
                  ),
                );
            if (profile.id.isNotEmpty && _validCloudBaseUrl(profile.baseUrl)) {
              profilesById[profile.id] = profile;
            }
          }
        }
      } else {
        // Migrate the former single cloud configuration without losing fields.
        final _ProviderConfig legacy = _configs[_ProviderKind.rwkvCloud]!;
        final String? officialId = _officialProfileForUrl(legacy.baseUrl)?.id;
        final RwkvCloudEndpointProfile migrated = RwkvCloudEndpointProfile(
          id:
              officialId ??
              'custom-legacy-${DateTime.now().microsecondsSinceEpoch}',
          name:
              _officialProfileForUrl(legacy.baseUrl)?.name ??
              'RWKV Cloud (Legacy)',
          baseUrl: legacy.baseUrl,
          apiKey: legacy.apiKey,
          defaultModel: legacy.defaultModel,
          cfAccessClientId: legacy.cfAccessClientId,
          cfAccessClientSecret: legacy.cfAccessClientSecret,
          timeoutSeconds: legacy.timeoutSeconds,
          defaultMaxTokens: legacy.defaultMaxTokens,
          defaultTemperature: legacy.defaultTemperature,
          enableStreaming: legacy.enableStreaming,
        );
        profilesById[migrated.id] = migrated;
      }

      final String requestedActive = rawActive == null || rawActive.isEmpty
          ? ''
          : (jsonDecode(rawActive) as String? ?? '');
      final RwkvCloudEndpointProfile active =
          profilesById[requestedActive] ??
          _officialProfileForUrl(_configs[_ProviderKind.rwkvCloud]!.baseUrl) ??
          profilesById['official-7b']!;
      if (!mounted) return;
      setState(() {
        _cloudProfiles = profilesById.values.toList()
          ..sort((a, b) {
            final int aOfficial = a.id.startsWith('official-') ? 0 : 1;
            final int bOfficial = b.id.startsWith('official-') ? 0 : 1;
            return aOfficial != bOfficial
                ? aOfficial.compareTo(bOfficial)
                : a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        _activeCloudProfileId = active.id;
        _applyCloudProfile(active);
      });
      await _persistCloudProfiles();
    } on Object {
      // Keep the four empty official endpoint templates available on bad data.
    }
  }

  static bool _validCloudBaseUrl(String value) {
    final Uri? uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }

  RwkvCloudEndpointProfile? _officialProfileForUrl(String url) {
    final String normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    for (final RwkvCloudEndpointProfile profile
        in kRwkvOfficialEndpointProfiles) {
      if (profile.baseUrl == normalized) return profile;
    }
    return null;
  }

  void _applyCloudProfile(RwkvCloudEndpointProfile profile) {
    final _ProviderConfig cfg = _configs[_ProviderKind.rwkvCloud]!;
    cfg
      ..baseUrl = profile.baseUrl
      ..apiKey = profile.apiKey
      ..defaultModel = profile.defaultModel
      ..cfAccessClientId = profile.cfAccessClientId
      ..cfAccessClientSecret = profile.cfAccessClientSecret
      ..timeoutSeconds = profile.timeoutSeconds
      ..defaultMaxTokens = profile.defaultMaxTokens
      ..defaultTemperature = profile.defaultTemperature
      ..enableStreaming = profile.enableStreaming;
  }

  RwkvCloudEndpointProfile _currentCloudProfile() {
    final _ProviderConfig cfg = _configs[_ProviderKind.rwkvCloud]!;
    final RwkvCloudEndpointProfile? selected = _cloudProfiles
        .where((RwkvCloudEndpointProfile p) => p.id == _activeCloudProfileId)
        .firstOrNull;
    return RwkvCloudEndpointProfile(
      id: _activeCloudProfileId,
      name: selected?.name ?? 'RWKV Cloud',
      baseUrl: cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      apiKey: cfg.apiKey,
      defaultModel: cfg.defaultModel,
      cfAccessClientId: cfg.cfAccessClientId,
      cfAccessClientSecret: cfg.cfAccessClientSecret,
      timeoutSeconds: cfg.timeoutSeconds,
      defaultMaxTokens: cfg.defaultMaxTokens,
      defaultTemperature: cfg.defaultTemperature,
      enableStreaming: cfg.enableStreaming,
    );
  }

  Future<void> _persistCloudProfiles() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final RwkvCloudEndpointProfile current = _currentCloudProfile();
      final List<RwkvCloudEndpointProfile> profiles = _cloudProfiles
          .map(
            (RwkvCloudEndpointProfile profile) =>
                profile.id == current.id ? current : profile,
          )
          .toList();
      if (!profiles.any((RwkvCloudEndpointProfile p) => p.id == current.id)) {
        profiles.add(current);
      }
      _cloudProfiles = profiles;
      await kv.writeJson(
        _kvScopeAiConfig,
        _kvKeyRwkvCloudProfiles,
        jsonEncode(profiles.map((p) => p.toJson()).toList()),
      );
      await kv.writeJson(
        _kvScopeAiConfig,
        _kvKeyRwkvCloudActiveProfile,
        jsonEncode(_activeCloudProfileId),
      );
      await ref.read(agentEndpointRegistryProvider).replace(profiles);
    } on Object {
      // Profile persistence is best-effort; normal provider config is also saved.
    }
  }

  Future<void> _selectCloudProfile(String id) async {
    final RwkvCloudEndpointProfile? profile = _cloudProfiles
        .where((RwkvCloudEndpointProfile p) => p.id == id)
        .firstOrNull;
    if (profile == null || id == _activeCloudProfileId) return;
    await _persistCloudProfiles();
    setState(() {
      _activeCloudProfileId = profile.id;
      _applyCloudProfile(profile);
      _cloudModelIds = <String>[];
      _cloudModelsError = null;
      _lastTest = null;
    });
    await _persistCloudProfiles();
    await _persistProviderConfig();
    await _persistRwkvPrefs();
    await _fetchCloudModels();
  }

  Future<void> _addCloudProfile() async {
    final TextEditingController nameController = TextEditingController();
    final TextEditingController urlController = TextEditingController();
    final (String name, String url)? result =
        await showDialog<(String, String)>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: Text(
              ref.read(l10nProvider).t('AIC.Cloud.AddProfile', '添加云端配置'),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: ref
                        .read(l10nProvider)
                        .t('AIC.Cloud.ProfileName', '配置名称'),
                  ),
                ),
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: ref
                        .read(l10nProvider)
                        .t('AIC.FieldBaseUrl', 'API 基础地址'),
                    hintText: 'https://example.com/v1',
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(ref.read(l10nProvider).t('Common.Cancel', '取消')),
              ),
              FilledButton(
                onPressed: () {
                  final String name = nameController.text.trim();
                  final String url = urlController.text.trim().replaceAll(
                    RegExp(r'/+$'),
                    '',
                  );
                  if (name.isEmpty || !_validCloudBaseUrl(url)) return;
                  Navigator.pop(context, (name, url));
                },
                child: Text(ref.read(l10nProvider).t('Common.Add', '添加')),
              ),
            ],
          ),
        );
    nameController.dispose();
    urlController.dispose();
    if (result == null || !mounted) return;
    final RwkvCloudEndpointProfile profile = RwkvCloudEndpointProfile(
      id: 'custom-${DateTime.now().microsecondsSinceEpoch}',
      name: result.$1,
      baseUrl: result.$2,
    );
    setState(() {
      _cloudProfiles = <RwkvCloudEndpointProfile>[..._cloudProfiles, profile];
    });
    await _selectCloudProfile(profile.id);
  }

  Future<void> _removeCloudProfile() async {
    final RwkvCloudEndpointProfile? active = _cloudProfiles
        .where((RwkvCloudEndpointProfile p) => p.id == _activeCloudProfileId)
        .firstOrNull;
    if (active == null || active.id.startsWith('official-')) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          ref.read(l10nProvider).t('AIC.Cloud.RemoveProfile', '删除此配置？'),
        ),
        content: Text(active.name),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ref.read(l10nProvider).t('Common.Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ref.read(l10nProvider).t('Common.Delete', '删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _cloudProfiles.removeWhere(
        (RwkvCloudEndpointProfile p) => p.id == active.id,
      );
      _activeCloudProfileId = 'official-7b';
      _applyCloudProfile(
        _cloudProfiles.firstWhere((p) => p.id == _activeCloudProfileId),
      );
      _cloudModelIds = <String>[];
    });
    await _persistCloudProfiles();
    await _persistProviderConfig();
    await _persistRwkvPrefs();
    await _fetchCloudModels();
  }

  Future<void> _fetchCloudModels() async {
    final int requestId = ++_cloudModelsRequestId;
    final String profileId = _activeCloudProfileId;
    setState(() {
      _cloudModelsLoading = true;
      _cloudModelsError = null;
    });
    try {
      final RwkvCloudProvider provider = ref.read(
        rwkvCloudProviderInstanceProvider,
      );
      await provider.initialize(_buildConfig());
      final List<String> ids = <String>{
        for (final ModelInfo model in await provider.getAvailableModels())
          if (model.id.trim().isNotEmpty) model.id.trim(),
      }.toList()..sort();
      if (!mounted ||
          requestId != _cloudModelsRequestId ||
          profileId != _activeCloudProfileId) {
        return;
      }
      setState(() {
        _cloudModelIds = ids;
        if (ids.isEmpty) {
          _cloudModelsError = ref
              .read(l10nProvider)
              .t(
                'AIC.Cloud.ModelsUnavailable',
                '未能从该 API 地址读取模型列表，请检查地址和 Cloudflare Access 凭据。',
              );
        } else if (_cfg.defaultModel.isEmpty && ids.length == 1) {
          _cfg.defaultModel = ids.single;
        }
      });
    } on Object catch (e) {
      if (mounted &&
          requestId == _cloudModelsRequestId &&
          profileId == _activeCloudProfileId) {
        setState(() => _cloudModelsError = '$e');
      }
    } finally {
      if (mounted && requestId == _cloudModelsRequestId) {
        setState(() => _cloudModelsLoading = false);
      }
    }
  }

  /// 存储键（`provider_cfg.{kind}` 的 `{kind}`）→ 页面 provider 枚举。
  static _ProviderKind? _kindByStorageKey(String key) {
    for (final _ProviderKind k in _ProviderKind.values) {
      if (k.name == key) return k;
    }
    return null;
  }

  /// 把持久化 JSON 写回 [_ProviderConfig]（字段名与 [_snapshotToJson] 对齐）。
  ///
  /// 约定：**键存在即覆盖**（含空值 —— 用户清空 API Key 也应当被尊重）；
  /// 仅 RWKV 本地路径类字段跳过空值，避免覆盖 legacy 键里更完整的旧配置。
  static void _applyPersistedJson(_ProviderConfig c, Map<String, Object?> j) {
    void str(String k, void Function(String v) apply) {
      final Object? v = j[k];
      if (v is String) apply(v);
    }

    void num_(String k, void Function(num v) apply) {
      final Object? v = j[k];
      if (v is num) apply(v);
    }

    void boolean(String k, void Function(bool v) apply) {
      final Object? v = j[k];
      if (v is bool) apply(v);
    }

    str('baseUrl', (String v) => c.baseUrl = v);
    str('apiKey', (String v) => c.apiKey = v);
    str('defaultModel', (String v) => c.defaultModel = v);
    num_('timeoutSeconds', (num v) => c.timeoutSeconds = v.toInt());
    num_('defaultTemperature', (num v) => c.defaultTemperature = v.toDouble());
    num_('defaultMaxTokens', (num v) => c.defaultMaxTokens = v.toInt());
    boolean('enableStreaming', (bool v) => c.enableStreaming = v);
    str('rwkvThinkType', (String v) {
      if (v.isNotEmpty) c.rwkvThinkType = v;
    });
    boolean('rwkvUseStatefulRoute', (bool v) => c.rwkvUseStatefulRoute = v);
    num_(
      'rwkvMaxConcurrentSessions',
      (num v) => c.rwkvMaxConcurrentSessions = v.toInt(),
    );
    str('rwkvLocalExecutable', (String v) {
      if (v.isNotEmpty) c.rwkvLocalExecutable = v;
    });
    str('rwkvLocalModelPath', (String v) {
      if (v.isNotEmpty) c.rwkvLocalModelPath = v;
    });
    str('rwkvLocalVocabPath', (String v) {
      if (v.isNotEmpty) c.rwkvLocalVocabPath = v;
    });
    str('rwkvLocalServerVariant', (String v) {
      for (final OfficialServerVariant sv in OfficialServerVariant.values) {
        if (sv.name == v) {
          c.rwkvLocalServerVariant = sv;
          return;
        }
      }
    });
    // 云端 CF Access Service Token（RWKV 云端 + 其它 CF 保护端点）
    str('cfAccessClientId', (String v) => c.cfAccessClientId = v);
    str('cfAccessClientSecret', (String v) => c.cfAccessClientSecret = v);
  }

  /// 内置引擎装齐后的回调：把 exe / 词表 / 模型 / 变体写进配置并落盘。
  void _onBuiltInProvisioned(BuiltInEngineProvision p) {
    final cfg = _configs[_ProviderKind.rwkv]!;
    cfg.rwkvLocalExecutable = p.executablePath;
    cfg.rwkvLocalVocabPath = p.vocabPath;
    cfg.rwkvLocalServerVariant = p.variant;
    if (p.modelPath != null && p.modelPath!.isNotEmpty) {
      cfg.rwkvLocalModelPath = p.modelPath;
    }
    // 顶部「官方 Server 变体」下拉同步到内置引擎变体，避免两处不一致
    setState(() => _serverVariant = p.variant);
    _persistRwkvPrefs();
    _ensureRwkvScanned(force: true);
  }

  /// 内置引擎的 `.pth` 权重下载完成后写进配置。
  void _onBuiltInModelDownloaded(
    String modelPath,
    OfficialServerVariant variant,
  ) {
    final cfg = _configs[_ProviderKind.rwkv]!;
    cfg.rwkvLocalModelPath = modelPath;
    cfg.rwkvLocalServerVariant = variant;
    _persistRwkvPrefs();
    _ensureRwkvScanned(force: true);
  }

  Future<void> _persistRwkvPrefs() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final cfg = _configs[_ProviderKind.rwkv]!;
      final rwkvCfg = RwkvConfiguration(
        baseUrl: cfg.baseUrl,
        defaultModel: cfg.defaultModel,
        defaultMaxTokens: cfg.defaultMaxTokens,
        localExecutable: cfg.rwkvLocalExecutable,
        localModelPath: cfg.rwkvLocalModelPath,
        localVocabPath: cfg.rwkvLocalVocabPath,
        localServerVariant: cfg.rwkvLocalServerVariant,
      );
      await kv.writeJson(
        _kvScopeAiConfig,
        _kvKeyRwkvCfg,
        jsonEncode(rwkvCfg.toMap()),
      );
      await kv.writeJson(
        _kvScopeUiPrefs,
        _kvKeyRwkvServerVariant,
        _serverVariant.name,
      );
      // 云端配置（含 CF Service Token）单独持久化，与本地引擎互不影响
      final _ProviderConfig cloudCfg = _configs[_ProviderKind.rwkvCloud]!;
      await kv.writeJson(
        _kvScopeAiConfig,
        _kvKeyRwkvCloudCfg,
        jsonEncode(
          RwkvCloudConfiguration(
            baseUrl: cloudCfg.baseUrl,
            apiKey: cloudCfg.apiKey,
            defaultModel: cloudCfg.defaultModel,
            timeoutSeconds: cloudCfg.timeoutSeconds,
            defaultMaxTokens: cloudCfg.defaultMaxTokens,
            defaultTemperature: cloudCfg.defaultTemperature,
            enableStreaming: cloudCfg.enableStreaming,
            cfAccessClientId: cloudCfg.cfAccessClientId,
            cfAccessClientSecret: cloudCfg.cfAccessClientSecret,
          ).toCloudMap(),
        ),
      );
      // ⚠ 双写通用 provider 注册表（provider_cfg.rwkvCloud）：
      // 启动恢复（ProviderAutoRestore）与页面字段回填都读**这个**键；
      // 上面那个 legacy 键仅为兼容旧版本数据而保留。
      await ref
          .read(modelConfigStoreProvider)
          .save(_ProviderKind.rwkvCloud.name, _snapshotToJson(cloudCfg));
    } catch (_) {}
  }

  Future<void> _ensureRwkvScanned({bool force = false}) async {
    if (_rwkvScanning) return;
    if (!force && _rwkvModels.isNotEmpty) return;
    setState(() => _rwkvScanning = true);
    try {
      final prov = ref.read(rwkvProviderInstanceProvider);
      final models = await prov.listLocalModels();
      if (!mounted) return;
      setState(() {
        _rwkvModels
          ..clear()
          ..addAll(models);
        if (models.isNotEmpty) {
          final cfg = _configs[_ProviderKind.rwkv]!;
          cfg.rwkvLocalModelPath ??= models.first.filePath;
          if (cfg.defaultModel == 'rwkv7-g1i' || cfg.defaultModel.isEmpty) {
            cfg.defaultModel = models.first.fileName;
          }
        }
      });
    } finally {
      if (mounted) setState(() => _rwkvScanning = false);
    }
  }

  Future<void> _launchRwkvLocalServer() async {
    final l10n = ref.read(l10nProvider);
    if (_rwkvLaunching) return;
    setState(() {
      _rwkvLaunching = true;
      _lastTest = null;
    });
    final cfg = _configs[_ProviderKind.rwkv]!;
    final prov = ref.read(rwkvProviderInstanceProvider);
    try {
      final ok = await prov.launchLocalServer(
        overrideExecutable: cfg.rwkvLocalExecutable,
        overrideModelPath: cfg.rwkvLocalModelPath,
        port:
            int.tryParse(Uri.tryParse(cfg.baseUrl)?.port.toString() ?? '') ??
            8000,
      );
      if (!mounted) return;
      final diagnostics = prov.lastLaunchDiagnostics;
      setState(() {
        _lastTest = ok
            ? ConnectionTestResult(
                isSuccess: true,
                responseTime: const Duration(milliseconds: 50),
                serverInfo: <String, dynamic>{
                  'note': l10n.t(
                    'AIC.RwkvServerLaunchedNote',
                    '本地 RWKV server 已拉起，等待就绪…',
                  ),
                },
              )
            : ConnectionTestResult(
                isSuccess: false,
                responseTime: const Duration(milliseconds: 0),
                errorMessage: diagnostics != null && diagnostics.isNotEmpty
                    ? diagnostics
                    : l10n.t(
                        'AIC.RwkvLaunchFailed',
                        '拉起失败：请检查「RWKV Server 可执行文件」路径与模型文件路径',
                      ),
              );
      });
      if (ok) await Future<void>.delayed(const Duration(seconds: 1));
      await _testConnection();
    } finally {
      if (mounted) setState(() => _rwkvLaunching = false);
    }
  }

  Future<void> _stopRwkvLocalServer() async {
    final l10n = ref.read(l10nProvider);
    if (_rwkvStopping) return;
    setState(() {
      _rwkvStopping = true;
      _lastTest = null;
    });
    try {
      final bool stopped = await ref
          .read(rwkvProviderInstanceProvider)
          .stopLocalServer();
      if (!mounted) return;
      setState(() {
        _lastTest = ConnectionTestResult(
          isSuccess: stopped,
          responseTime: Duration.zero,
          serverInfo: <String, dynamic>{
            'note': stopped
                ? l10n.t('AIC.RwkvServerStoppedNote', '本地 RWKV server 已停止')
                : l10n.t(
                    'AIC.RwkvServerNotRunningNote',
                    '本地 RWKV server 当前没有在运行（无需停止）',
                  ),
          },
          errorMessage: stopped
              ? null
              : l10n.t(
                  'AIC.RwkvServerNotRunningNote',
                  '本地 RWKV server 当前没有在运行（无需停止）',
                ),
        );
      });
      // 停止后立刻复测，让「可用性」与状态卡片反映真实情况（对齐启动后的行为）
      if (stopped) await _testConnection();
    } finally {
      if (mounted) setState(() => _rwkvStopping = false);
    }
  }

  Future<void> _installOfficialServer() async {
    final l10n = ref.read(l10nProvider);
    if (_serverInstallProgress != null &&
        !_serverInstallProgress!.phase.isTerminal) {
      return;
    }
    setState(() {
      _serverInstallCancelHandle = null;
      _serverInstallProgress = RwkvDownloadProgress(
        phase: RwkvDownloadPhase.fetchingMeta,
        message: l10n.tf(
          'AIC.PreparingOfficialServer',
          '准备下载官方 llama.cpp {variant} …',
          {'variant': _serverVariant.displayName},
        ),
      );
    });
    final prov = ref.read(rwkvProviderInstanceProvider);
    try {
      final exePath = await prov.installOfficialLlamaServer(
        variant: _serverVariant,
        onProgress: (RwkvDownloadProgress p) {
          if (!mounted) return;
          setState(() => _serverInstallProgress = p);
        },
        onHandleReady: (RwkvCancelHandle h) {
          if (!mounted) return;
          setState(() => _serverInstallCancelHandle = h);
        },
      );
      if (!mounted) return;
      final cfg = _configs[_ProviderKind.rwkv]!;
      setState(() {
        cfg.rwkvLocalExecutable = exePath;
        _serverInstallProgress = RwkvDownloadProgress(
          phase: RwkvDownloadPhase.done,
          message: l10n.tf(
            'AIC.OfficialServerInstalled',
            '官方 server 已安装：{path}',
            {'path': exePath},
          ),
          totalBytes: _serverInstallProgress?.totalBytes ?? 0,
          receivedBytes: _serverInstallProgress?.totalBytes ?? 0,
        );
        _serverInstallCancelHandle = null;
      });
      await _saveAndRegister();
      _persistRwkvPrefs();
    } on RwkvDownloadCancelledException catch (e, s) {
      if (!mounted) return;
      setState(() {
        _serverInstallProgress = RwkvDownloadProgress(
          phase: RwkvDownloadPhase.cancelled,
          error: e,
          stackTrace: s,
          message: l10n.tf('AIC.InstallCancelled', '安装已取消{suffix}', {
            'suffix': e.message == null ? '' : '（${e.message}）',
          }),
          totalBytes: _serverInstallProgress?.totalBytes ?? 0,
          receivedBytes: _serverInstallProgress?.receivedBytes ?? 0,
        );
        _serverInstallCancelHandle = null;
      });
    } on Exception catch (e, s) {
      if (!mounted) return;
      setState(() {
        _serverInstallProgress = RwkvDownloadProgress(
          phase: RwkvDownloadPhase.failed,
          error: e,
          stackTrace: s,
          message: l10n.tf('AIC.InstallFailed', '安装失败：{error}', {
            'error': '$e',
          }),
        );
        _serverInstallCancelHandle = null;
      });
    }
  }

  Future<void> _showOfficialModelsDialog() async {
    final l10n = ref.read(l10nProvider);
    final mm = ScaffoldMessenger.of(context);
    final prov = ref.read(rwkvProviderInstanceProvider);
    final List<RwkvOfficialModel>?
    models = await showDialog<List<RwkvOfficialModel>>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return FutureBuilder<List<RwkvOfficialModel>>(
          future: prov.listOfficialModels(
            onProgress: (RwkvDownloadProgress p) {},
          ),
          builder:
              (
                BuildContext dialogCtx,
                AsyncSnapshot<List<RwkvOfficialModel>> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return AlertDialog(
                    title: Text(
                      l10n.t('AIC.QueryingOfficialModels', '正在查询官方模型列表…'),
                    ),
                    content: const LinearProgressIndicator(),
                  );
                }
                if (snapshot.hasError) {
                  return AlertDialog(
                    title: Text(l10n.t('AIC.QueryFailed', '查询失败')),
                    content: SingleChildScrollView(
                      child: Text('${snapshot.error}'),
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.pop(dialogCtx),
                        child: Text(l10n.t('Common.Close', '关闭')),
                      ),
                    ],
                  );
                }
                final list = snapshot.data ?? const <RwkvOfficialModel>[];
                return SimpleDialog(
                  title: Text(
                    l10n.t('AIC.SelectOfficialModel', '选择要下载的官方 RWKV 模型'),
                  ),
                  children: <Widget>[
                    for (final m in list)
                      SimpleDialogOption(
                        onPressed: () =>
                            Navigator.pop(dialogCtx, <RwkvOfficialModel>[m]),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Icon(Icons.download_for_offline_outlined),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      m.displayName,
                                      style: Theme.of(ctx).textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${m.paramsLabel} · ${m.quant.displayLabel.split('(').last.replaceAll(')', '')} · ${m.sizeHumanReadable}\n${m.fileName}',
                                      style: Theme.of(ctx).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          l10n.t(
                            'AIC.NoOfficialModels',
                            '未找到可用官方模型，请稍后再试或手动下载 GGUF 到 rwkv_models/ 目录。',
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: Text(l10n.t('Common.Cancel', '取消')),
                    ),
                  ],
                );
              },
        );
      },
    );
    if (models == null || models.isEmpty) return;
    final model = models.first;
    mm.showSnackBar(
      SnackBar(
        content: Text(
          l10n.tf('AIC.StartDownloadModel', '开始下载：{name}（{size}）', {
            'name': model.displayName,
            'size': model.sizeHumanReadable,
          }),
        ),
      ),
    );
    await _downloadModel(model);
  }

  Future<void> _downloadModel(RwkvOfficialModel model) async {
    final l10n = ref.read(l10nProvider);
    if (_modelDownloadProgress != null &&
        !_modelDownloadProgress!.phase.isTerminal) {
      return;
    }
    setState(() {
      _modelDownloadCancelHandle = null;
      _modelDownloadProgress = RwkvDownloadProgress(
        phase: RwkvDownloadPhase.fetchingMeta,
        message: l10n.tf('AIC.PreparingDownload', '准备下载：{name} …', {
          'name': model.displayName,
        }),
      );
    });
    final mm = ScaffoldMessenger.of(context);
    final prov = ref.read(rwkvProviderInstanceProvider);
    try {
      final filePath = await prov.downloadOfficialModel(
        model,
        onProgress: (RwkvDownloadProgress p) {
          if (!mounted) return;
          setState(() => _modelDownloadProgress = p);
        },
        onHandleReady: (RwkvCancelHandle h) {
          if (!mounted) return;
          setState(() => _modelDownloadCancelHandle = h);
        },
      );
      if (!mounted) return;
      setState(() {
        _modelDownloadProgress = RwkvDownloadProgress(
          phase: RwkvDownloadPhase.done,
          message: l10n.tf('AIC.DownloadComplete', '下载完成：{path}', {
            'path': filePath,
          }),
          totalBytes: model.sizeBytes,
          receivedBytes: model.sizeBytes,
        );
        _modelDownloadCancelHandle = null;
      });
      final cfg = _configs[_ProviderKind.rwkv]!;
      cfg.rwkvLocalModelPath = filePath;
      if (cfg.defaultModel == 'rwkv7-g1i' || cfg.defaultModel.isEmpty) {
        cfg.defaultModel = model.fileName;
      }
      await _saveAndRegister();
      await _ensureRwkvScanned(force: true);
      _persistRwkvPrefs();
      mm.showSnackBar(
        SnackBar(
          content: Text(
            l10n.tf('AIC.ModelDownloadedSelected', '✅ {name} 已下载并选中。', {
              'name': model.displayName,
            }),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } on RwkvDownloadCancelledException catch (e, s) {
      if (!mounted) return;
      setState(() {
        _modelDownloadProgress = RwkvDownloadProgress(
          phase: RwkvDownloadPhase.cancelled,
          error: e,
          stackTrace: s,
          message: l10n.tf('AIC.DownloadCancelled', '下载已取消{suffix}', {
            'suffix': e.message == null ? '' : '（${e.message}）',
          }),
          totalBytes: model.sizeBytes,
          receivedBytes: _modelDownloadProgress?.receivedBytes ?? 0,
        );
        _modelDownloadCancelHandle = null;
      });
      mm.showSnackBar(
        SnackBar(
          content: Text(
            l10n.tf('AIC.DownloadCancelledModel', '下载已取消：{name}', {
              'name': model.displayName,
            }),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } on Exception catch (e, s) {
      if (!mounted) return;
      setState(() {
        _modelDownloadProgress = RwkvDownloadProgress(
          phase: RwkvDownloadPhase.failed,
          error: e,
          stackTrace: s,
          message: l10n.tf('AIC.DownloadFailed', '下载失败：{error}', {
            'error': '$e',
          }),
        );
        _modelDownloadCancelHandle = null;
      });
      mm.showSnackBar(
        SnackBar(
          content: Text(
            l10n.tf('AIC.DownloadFailedSnack', '下载失败：{error}', {'error': '$e'}),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _refreshFromManager() {
    final mm = ref.read(modelManagerProvider);
    final all = mm.getAllProviders();
    final available = <String, bool>{
      for (final p in all) p.providerName: p.isAvailable,
    };
    final stats = mm.getAllStatistics();
    final def = mm.getDefaultProvider()?.providerName;
    if (!mounted) return;
    setState(() {
      _availableMap
        ..clear()
        ..addAll(available);
      _statsMap
        ..clear()
        ..addAll(stats);
      _defaultProvider = def;
    });
  }

  _ProviderConfig get _cfg => _configs[_selectedKind]!;

  void _selectProviderKind(_ProviderKind kind) {
    setState(() {
      _selectedKind = kind;
      _lastTest = null;
    });
    if (kind == _ProviderKind.rwkvCloud) {
      _fetchCloudModels();
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _lastTest = null;
      _connectingTo = _cfg.registeredName;
    });
    try {
      final mm = ref.read(modelManagerProvider);
      final cfg = _buildConfig();
      IModelProvider? prov;
      switch (_selectedKind) {
        case _ProviderKind.deepseek:
          prov = ref.read(deepSeekProviderInstanceProvider);
          break;
        case _ProviderKind.zhipu:
          prov = ref.read(zhipuProviderInstanceProvider);
          break;
        case _ProviderKind.openrouter:
          prov = ref.read(openRouterProviderInstanceProvider);
          break;
        case _ProviderKind.ollama:
          prov = ref.read(ollamaProviderInstanceProvider);
          break;
        case _ProviderKind.rwkv:
          prov = ref.read(rwkvProviderInstanceProvider);
          break;
        case _ProviderKind.rwkvCloud:
          prov = ref.read(rwkvCloudProviderInstanceProvider);
          break;
        case _ProviderKind.custom:
          prov = ref.read(customOAICompatibleProviderInstanceProvider);
          break;
      }
      if (prov == null) return;
      await prov.initialize(cfg);
      final result = await prov.testConnection();
      if (mounted) {
        setState(() {
          _lastTest = result;
        });
        if (result.isSuccess && mm.getProvider(prov.providerName) == null) {
          mm.registerProvider(prov);
        }
        _refreshFromManager();
      }
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _connectingTo = null;
        });
      }
    }
  }

  /// 初始化云端 Provider 并取回引擎状态摘要（能力/显存/队列/吞吐）。
  ///
  /// 走 `rwkvCloudProviderInstanceProvider`（全局单例）—— 避免多实例导致
  /// 服务端 `/state/*` 会话缓存不一致（PITFALLS §31 单例要求）。
  Future<RwkvCloudServerSummary?> _fetchCloudStatus() async {
    final prov = ref.read(rwkvCloudProviderInstanceProvider);
    await prov.initialize(_buildConfig());
    return prov.fetchServerSummary();
  }

  IModelConfiguration _buildConfig() {
    switch (_selectedKind) {
      case _ProviderKind.deepseek:
        return DeepSeekConfiguration(
          apiKey: _cfg.apiKey,
          defaultModel: _cfg.defaultModel,
          baseUrl: _cfg.baseUrl,
          timeoutSeconds: _cfg.timeoutSeconds,
          defaultMaxTokens: _cfg.defaultMaxTokens,
        );
      case _ProviderKind.zhipu:
        return ZhipuConfiguration(
          apiKey: _cfg.apiKey,
          defaultModel: _cfg.defaultModel,
          baseUrl: _cfg.baseUrl,
          defaultMaxTokens: _cfg.defaultMaxTokens,
        );
      case _ProviderKind.openrouter:
        // OpenRouter：OpenAI 兼容；baseUrl 必须带 `/api/v1`。
        // 模型 id 含 `/` 与 `:`（如 `apodex/apodex-1.1-mini:free`），按整串处理。
        return OpenRouterConfiguration(
          apiKey: _cfg.apiKey,
          defaultModel: _cfg.defaultModel,
          baseUrl: _cfg.baseUrl,
          timeoutSeconds: _cfg.timeoutSeconds,
          defaultTemperature: _cfg.defaultTemperature,
          defaultMaxTokens: _cfg.defaultMaxTokens,
          enableStreaming: _cfg.enableStreaming,
        );
      case _ProviderKind.ollama:
        return OllamaConfiguration(
          baseUrl: _cfg.baseUrl,
          defaultModel: _cfg.defaultModel,
        );
      case _ProviderKind.rwkv:
        return RwkvConfiguration(
          baseUrl: _cfg.baseUrl,
          defaultModel: _cfg.defaultModel,
          defaultMaxTokens: _cfg.defaultMaxTokens,
          localExecutable: _cfg.rwkvLocalExecutable,
          localModelPath: _cfg.rwkvLocalModelPath,
          localVocabPath: _cfg.rwkvLocalVocabPath,
          localServerVariant: _cfg.rwkvLocalServerVariant,
          // ⚠ 必须显式带 engineConfig：provider 的 initialize() 靠它把 baseUrl /
          // 原生参数 / stateful 开关同步进引擎；不传的话引擎永远打 localhost
          // （PITFALLS §31.7）。
          engineConfig: RwkvEngineConfig(
            baseUrl: _cfg.baseUrl,
            maxConcurrentSessions: _cfg.rwkvMaxConcurrentSessions,
            nativeOptions: RwkvNativeOptions(thinkType: _cfg.rwkvThinkType),
            useStatefulRoute: _cfg.rwkvUseStatefulRoute,
          ),
        );
      case _ProviderKind.rwkvCloud:
        // 云端官方端点：baseUrl 必须带 `/v1`（`/openai/v1` 实测 404）；
        // CF 头由 RwkvCloudConfiguration 自动并入 customHeaders。
        return RwkvCloudConfiguration(
          baseUrl: _cfg.baseUrl,
          apiKey: _cfg.apiKey,
          defaultModel: _cfg.defaultModel,
          timeoutSeconds: _cfg.timeoutSeconds,
          defaultMaxTokens: _cfg.defaultMaxTokens,
          defaultTemperature: _cfg.defaultTemperature,
          enableStreaming: _cfg.enableStreaming,
          cfAccessClientId: _cfg.cfAccessClientId,
          cfAccessClientSecret: _cfg.cfAccessClientSecret,
        );
      case _ProviderKind.custom:
        return OpenAICompatibleConfiguration(
          providerName: 'Custom',
          providerKind: 'Custom',
          baseUrl: _cfg.baseUrl,
          apiKey: _cfg.apiKey,
          defaultModel: _cfg.defaultModel,
          timeoutSeconds: _cfg.timeoutSeconds,
          defaultTemperature: _cfg.defaultTemperature,
          defaultMaxTokens: _cfg.defaultMaxTokens,
          enableStreaming: _cfg.enableStreaming,
        );
    }
  }

  Future<void> _saveAndRegister() async {
    final l10n = ref.read(l10nProvider);
    final isEnglish = l10n.isEnglish;
    final mm = ref.read(modelManagerProvider);
    IModelProvider? prov;
    switch (_selectedKind) {
      case _ProviderKind.deepseek:
        prov = ref.read(deepSeekProviderInstanceProvider);
        break;
      case _ProviderKind.zhipu:
        prov = ref.read(zhipuProviderInstanceProvider);
        break;
      case _ProviderKind.openrouter:
        prov = ref.read(openRouterProviderInstanceProvider);
        break;
      case _ProviderKind.ollama:
        prov = ref.read(ollamaProviderInstanceProvider);
        break;
      case _ProviderKind.rwkv:
        prov = ref.read(rwkvProviderInstanceProvider);
        break;
      case _ProviderKind.rwkvCloud:
        prov = ref.read(rwkvCloudProviderInstanceProvider);
        break;
      case _ProviderKind.custom:
        prov = ref.read(customOAICompatibleProviderInstanceProvider);
        break;
    }
    if (prov == null) return;

    // ⚠ 持久化必须**先做、且无条件做**：
    // 旧实现把 _persistProviderConfig/_persistRwkvPrefs 放在 `if (ok)` 里，
    // 而 initialize() 内部要做一次网络连通性探测（RWKV 云端尤其明显：没网 /
    // CF Token 没配通 / 端点 404 → 返回 false），于是**配置一个字都没落盘**，
    // 用户看到的是「初始化失败」，重启后自然什么也恢复不了。
    await _persistRwkvPrefs();
    await _persistProviderConfig();

    final bool ok = await prov.initialize(_buildConfig());
    if (mm.getProvider(prov.providerName) == null) {
      // 注册与「当前是否连通」解耦：配置正确但暂时离线时也应注册，
      // 这样启动恢复（ProviderAutoRestore）与写作流程都能拿到该 provider。
      mm.registerProvider(prov);
    }
    if (!mounted) return;
    final String label = _pvdLabel(_cfg.kind, isEnglish);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.tf('AIC.ConfigSavedRegistered', '{label} 配置已保存并注册', {
              'label': label,
            }),
          ),
        ),
      );
      _refreshFromManager();
    } else {
      // 已落盘，仅连通性检查失败：如实告知「已保存、但当前连不上」
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.tf(
              'AIC.ConfigSavedButOffline',
              '{label} 配置已保存到本地（重启后自动恢复），但当前连通性检查未通过：'
                  '请检查地址、API Key / CF Token 与网络后重试',
              {'label': label},
            ),
          ),
          backgroundColor: Colors.orange,
        ),
      );
      _refreshFromManager();
    }
  }

  void _setDefault(String name) {
    final mm = ref.read(modelManagerProvider);
    mm.setDefaultProvider(name);
    setState(() => _defaultProvider = name);
    // 持久化默认 provider（下次启动自动恢复）
    try {
      ref.read(modelConfigStoreProvider).saveDefault(name);
    } on Object {
      // 持久化失败不影响当前会话
    }
  }

  /// 注册名（`RWKV Cloud` / `RWKV Cloud::official-7b`）→ provider 种类。
  ///
  /// 与 [_kindByStorageKey] 互补：后者用于 `provider_cfg.*` 的存储键（= kind.name），
  /// 这里用于 `ModelManager` 记录的默认 provider 名。精确名优先，其次剥 `::` 后缀。
  _ProviderKind? _kindByRegisteredName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final _ProviderKind k in _ProviderKind.values) {
      if (_configs[k]!.registeredName == name) return k;
    }
    for (final _ProviderKind k in _ProviderKind.values) {
      if (name.startsWith('${_configs[k]!.registeredName}::')) return k;
    }
    return null;
  }

  /// 单独落盘运行时设置（采样/思维链之外只动窗口时用）。
  Future<void> _persistRuntimeSettings(AiRuntimeSettings s) async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      await kv.writeJson(
        _kvScopeAiConfig,
        _kvKeyRuntimeSettings,
        jsonEncode(s.toJson()),
      );
    } on Object {
      // 落盘失败不影响当前会话（下次保存会重试）。
    }
  }

  /// 让「模型上下文窗口」跟随**默认 provider 的模型名**刷新并落盘。
  ///
  /// 背景（用户报「模型支持 25K，却设不了 25K 上下文」）：窗口此前**只在点
  /// 「保存」provider 时**刷新一次，页面加载时用的是 KVStore 里的旧值 ——
  /// 模型名写着 `ctx25600`，窗口却卡在默认的 16384，于是生成链路的
  /// `outputBudgetTokens` 被 `16384 × 55% ≈ 9011` 钳死，滑块拖到 25K 也没用。
  ///
  /// 这里在页面加载后按默认 provider 的模型名同步一次（不新增任何可编辑控件，
  /// 窗口仍是只读派生值），保证窗口与模型名一致。
  Future<void> _syncContextWindowFromModel() async {
    if (!mounted) return;
    final _ProviderKind? kind = _kindByRegisteredName(_defaultProvider);
    if (kind == null) return;
    final String model = (_configs[kind]?.defaultModel ?? '').trim();
    if (model.isEmpty) return;
    final int window = AiRuntimeSettings.parseContextWindow(model);
    if (window == aiRuntimeSettings.contextWindowTokens) return;
    final AiRuntimeSettings next = aiRuntimeSettings.copyWith(
      contextWindowTokens: window,
    );
    aiRuntimeSettings = next;
    await _persistRuntimeSettings(next);
  }

  /// 把当前 provider 配置写入本地（下次启动自动恢复），并在保存默认后同步。
  Future<void> _persistProviderConfig() async {
    try {
      if (_selectedKind == _ProviderKind.rwkvCloud) {
        await _persistCloudProfiles();
      }
      await ref
          .read(modelConfigStoreProvider)
          .save(_selectedKind.name, _snapshotToJson(_cfg));
      await ref.read(modelConfigStoreProvider).saveDefault(_defaultProvider);
      // 模型最大参考长度 = 最大令牌数：保存 provider 时一并同步并持久化，
      // 保障重启后生成链路的参考窗口与「最大令牌数」依然一致。
      // 窗口优先取**默认 provider** 的模型名（生成链路用的是它）；默认 provider
      // 未知时退回当前所选 provider —— 否则在非默认 tab 上点保存会把窗口改写成
      // 别家模型的窗口值（如 OpenRouter 模型没有 ctx 标记 → 被写成 16384）。
      final _ProviderKind? defKind = _kindByRegisteredName(_defaultProvider);
      final String defModel = defKind == null
          ? ''
          : (_configs[defKind]?.defaultModel ?? '').trim();
      final AiRuntimeSettings synced = aiRuntimeSettings.copyWith(
        maxReferenceLength: _cfg.defaultMaxTokens,
        contextWindowTokens: AiRuntimeSettings.parseContextWindow(
          defModel.isNotEmpty ? defModel : _cfg.defaultModel,
        ),
      );
      aiRuntimeSettings = synced;
      await _persistRuntimeSettings(synced);
    } on Object {
      // 持久化失败不影响保存结果
    }
  }

  /// _ProviderConfig → JSON（与 provider_auto_restore 的反序列化字段对齐）。
  static Map<String, Object?> _snapshotToJson(_ProviderConfig c) =>
      <String, Object?>{
        'baseUrl': c.baseUrl,
        'apiKey': c.apiKey,
        'defaultModel': c.defaultModel,
        'timeoutSeconds': c.timeoutSeconds,
        'defaultTemperature': c.defaultTemperature,
        'defaultMaxTokens': c.defaultMaxTokens,
        'enableStreaming': c.enableStreaming,
        'rwkvLocalExecutable': c.rwkvLocalExecutable,
        'rwkvLocalModelPath': c.rwkvLocalModelPath,
        'rwkvLocalVocabPath': c.rwkvLocalVocabPath,
        'rwkvLocalServerVariant': c.rwkvLocalServerVariant?.name,
        'rwkvMaxConcurrentSessions': c.rwkvMaxConcurrentSessions,
        'rwkvThinkType': c.rwkvThinkType,
        'rwkvUseStatefulRoute': c.rwkvUseStatefulRoute,
        'cfAccessClientId': c.cfAccessClientId,
        'cfAccessClientSecret': c.cfAccessClientSecret,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isEnglish = l10n.isEnglish;
    final mm = ref.watch(modelManagerProvider);
    final registered = mm.getAllProviders();

    // 荣耀 Magic 7 Pro 等横屏手机：AppBar 已有「AI 配置」标题，页内大标题
    // 重复占一行；触屏窄屏隐藏并收紧内边距，把空间还给配置卡。
    final bool touch =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final bool phoneLayout = touch && MediaQuery.sizeOf(context).width < 1000;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.all(phoneLayout ? 12 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!phoneLayout) ...[
              Text(
                l10n.t('AIC.Title', 'AI 配置'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
            ],
            Expanded(
              // 手机横屏逻辑宽 ~780：内容区只剩 ~500px，左右分栏（220 列表 + 卡片）
              // 会把配置卡挤爆 —— 窄屏改为「提供商列表在上、配置卡在下」整体滚动。
              child: LayoutBuilder(
                builder: (context, box) {
                  final narrow =
                      box.maxWidth < 560 || (touch && box.maxWidth < 860);
                  final Widget cards = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_selectedKind == _ProviderKind.rwkvCloud) ...[
                        _CloudEndpointProfilesCard(
                          profiles: _cloudProfiles,
                          selectedId: _activeCloudProfileId,
                          onSelected: _selectCloudProfile,
                          onAdd: _addCloudProfile,
                          onRemove: _removeCloudProfile,
                        ),
                        const SizedBox(height: 16),
                      ],
                      _ConfigCard(
                        cfg: _cfg,
                        onChanged: () => setState(() {}),
                        testing: _testing,
                        onTest: _testConnection,
                        connectingTo: _connectingTo,
                        onSave: _saveAndRegister,
                        lastTest: _lastTest,
                        cloudModelIds: _selectedKind == _ProviderKind.rwkvCloud
                            ? _cloudModelIds
                            : null,
                        cloudModelsLoading: _cloudModelsLoading,
                        cloudModelsError: _cloudModelsError,
                        onFetchCloudModels:
                            _selectedKind == _ProviderKind.rwkvCloud
                            ? _fetchCloudModels
                            : null,
                        rwkvModels: _selectedKind == _ProviderKind.rwkv
                            ? _rwkvModels
                            : null,
                        rwkvScanning: _rwkvScanning,
                        rwkvLaunching: _rwkvLaunching,
                        rwkvStopping: _rwkvStopping,
                        rwkvServerRunning: ref
                            .watch(rwkvProviderInstanceProvider)
                            .localServerRunning,
                        onStopRwkvServer: _selectedKind == _ProviderKind.rwkv
                            ? _stopRwkvLocalServer
                            : null,
                        onRefreshRwkvModels: _selectedKind == _ProviderKind.rwkv
                            ? () => _ensureRwkvScanned(force: true)
                            : null,
                        onLaunchRwkvServer: _selectedKind == _ProviderKind.rwkv
                            ? _launchRwkvLocalServer
                            : null,
                        serverVariant: _selectedKind == _ProviderKind.rwkv
                            ? _serverVariant
                            : null,
                        onServerVariantChanged:
                            _selectedKind == _ProviderKind.rwkv
                            ? (OfficialServerVariant v) {
                                setState(() => _serverVariant = v);
                                _persistRwkvPrefs();
                              }
                            : null,
                        serverInstallProgress:
                            _selectedKind == _ProviderKind.rwkv
                            ? _serverInstallProgress
                            : null,
                        modelDownloadProgress:
                            _selectedKind == _ProviderKind.rwkv
                            ? _modelDownloadProgress
                            : null,
                        onInstallOfficialServer:
                            _selectedKind == _ProviderKind.rwkv
                            ? _installOfficialServer
                            : null,
                        onShowOfficialModelsDialog:
                            _selectedKind == _ProviderKind.rwkv
                            ? _showOfficialModelsDialog
                            : null,
                        onCancelServerInstall:
                            _selectedKind == _ProviderKind.rwkv
                            ? () {
                                final h = _serverInstallCancelHandle;
                                if (h != null && !h.isCancelled) {
                                  h.cancel(
                                    l10n.t('Common.UserCancelled', '用户取消'),
                                  );
                                }
                              }
                            : null,
                        onCancelModelDownload:
                            _selectedKind == _ProviderKind.rwkv
                            ? () {
                                final h = _modelDownloadCancelHandle;
                                if (h != null && !h.isCancelled) {
                                  h.cancel(
                                    l10n.t('Common.UserCancelled', '用户取消'),
                                  );
                                }
                              }
                            : null,
                        isEnglish: isEnglish,
                      ),
                      // ---- 内置推理引擎：rwkv_lightning_cuda（albatross）----
                      if (_selectedKind == _ProviderKind.rwkv) ...[
                        const SizedBox(height: 16),
                        _BuiltInEngineCard(
                          onProvisioned: _onBuiltInProvisioned,
                          onModelDownloaded: _onBuiltInModelDownloaded,
                          statefulRoute: _cfg.rwkvUseStatefulRoute,
                          onStatefulRouteChanged: (bool v) {
                            setState(() => _cfg.rwkvUseStatefulRoute = v);
                            _persistRwkvPrefs();
                          },
                          thinkType: _cfg.rwkvThinkType,
                          onThinkTypeChanged: (String v) {
                            setState(() => _cfg.rwkvThinkType = v);
                            _persistRwkvPrefs();
                          },
                        ),
                      ],
                      // ---- 云端官方端点：Cloudflare Access 凭证 ----
                      if (_selectedKind == _ProviderKind.rwkvCloud) ...[
                        const SizedBox(height: 16),
                        _CloudCfCard(
                          clientId: _cfg.cfAccessClientId,
                          clientSecret: _cfg.cfAccessClientSecret,
                          onCredentialsChanged: (String id, String secret) {
                            setState(() {
                              _cfg.cfAccessClientId = id;
                              _cfg.cfAccessClientSecret = secret;
                            });
                          },
                          onPersist: () async {
                            await _persistCloudProfiles();
                            await _persistRwkvPrefs();
                            await _persistProviderConfig();
                          },
                          onFetchStatus: _fetchCloudStatus,
                        ),
                      ],
                      const SizedBox(height: 16),
                      _StatsCard(
                        stats: _statsMap[_cfg.registeredName],
                        available: _availableMap[_cfg.registeredName],
                      ),
                      // ---- MainAgent / SubAgent 双代理写作流（全局配置）----
                      const SizedBox(height: 16),
                      const _DualAgentCard(),
                      const SizedBox(height: 16),
                      const BookReviewSettingsCard(),
                      // ---- 功能 C：章节落库后自动同步世界观 ----
                      const SizedBox(height: 16),
                      const _ChapterSyncCard(),
                      // ---- 生成采样参数（官方推荐预设 + 手动微调）与思维链 ----
                      const SizedBox(height: 16),
                      const _SamplingThinkingCard(),
                    ],
                  );

                  final Widget list = _ProviderList(
                    width: narrow ? double.infinity : 220,
                    selectedKind: _selectedKind,
                    onTap: _selectProviderKind,
                    configs: _configs,
                    availableMap: _availableMap,
                    defaultProvider: _defaultProvider,
                    registered: registered,
                    onSetDefault: _setDefault,
                    isEnglish: isEnglish,
                  );

                  if (narrow) {
                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [list, const SizedBox(height: 16), cards],
                      ),
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      list,
                      const SizedBox(width: 16),
                      Expanded(child: SingleChildScrollView(child: cards)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内置推理引擎卡片 —— `rwkv_lightning_cuda`（albatross）。
///
/// 与 llama.cpp 路线完全独立：只吃 `.pth` / `.rwkvq`，且**强制外置词表**
/// （PITFALLS §27.1）。这里把「装引擎 → 下词表 → 下模型 → 启动」串成一条链，
/// 装完通过 [onProvisioned] 回写配置。
class _BuiltInEngineCard extends ConsumerStatefulWidget {
  const _BuiltInEngineCard({
    required this.onProvisioned,
    required this.onModelDownloaded,
    required this.statefulRoute,
    required this.onStatefulRouteChanged,
    required this.thinkType,
    required this.onThinkTypeChanged,
  });

  /// 引擎 + 词表装齐后回调
  final void Function(BuiltInEngineProvision provision) onProvisioned;

  /// .pth 权重下载完成后回调
  final void Function(String modelPath, OfficialServerVariant variant)
  onModelDownloaded;

  /// 会话 state 续跑开关（走 `/state/chat/completions`）
  final bool statefulRoute;
  final void Function(bool value) onStatefulRouteChanged;

  /// 思考前缀模式
  final String thinkType;
  final void Function(String value) onThinkTypeChanged;

  @override
  ConsumerState<_BuiltInEngineCard> createState() => _BuiltInEngineCardState();
}

class _BuiltInEngineCardState extends ConsumerState<_BuiltInEngineCard> {
  /// 只提供 CUDA 12.9 / 13.2 两档官方预编译包
  OfficialServerVariant _variant = OfficialServerVariant.cuda13;
  RwkvDownloadProgress? _progress;
  RwkvCancelHandle? _cancelHandle;
  bool _busy = false;
  bool _launching = false;
  String? _status;

  /// GPU 显存探测结果（null = 还没探 / 探不到）。探一次就缓存。
  List<RwkvGpuInfo>? _gpus;

  RwkvProvider get _provider => ref.read(rwkvProviderInstanceProvider);

  bool get _running => _progress != null && !_progress!.phase.isTerminal;

  void _onProgress(RwkvDownloadProgress p) {
    if (!mounted) return;
    setState(() => _progress = p);
  }

  String _fmtProgress(RwkvDownloadProgress p) {
    final L10n l10n = ref.read(l10nProvider);
    final String phase = l10n.t(p.phase.labelKey, p.phase.label);
    if (p.totalBytes > 0) {
      final double mb = p.receivedBytes / 1048576;
      final double totalMb = p.totalBytes / 1048576;
      final String speed = p.speedMbps > 0
          ? '  ${p.speedMbps.toStringAsFixed(1)} MB/s'
          : '';
      final String eta = p.etaSeconds > 0
          ? '  ${l10n.tf('AIC.EtaRemainingFmt', '剩余 {0}s', {'0': p.etaSeconds})}'
          : '';
      // ⚠ 必须写 `${...}`：`$totalMb.toStringAsFixed(1)` 只会插值 totalMb，
      // 后面的 `.toStringAsFixed(1)` 退化成字面文本，
      // 界面上会显示成「12.3/45.6.toStringAsFixed(1) MB」。
      // 由 `tools/dart_interp_lint.py` 扫出。
      return '$phase  ${mb.toStringAsFixed(1)}/${totalMb.toStringAsFixed(1)} MB$speed$eta';
    }
    return phase;
  }

  /// 一键装齐：引擎（下载 + SHA-256 校验 + 解压）+ 外置词表
  Future<void> _provision() async {
    if (_busy) return;
    final L10n l10n = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final p = await _provider.provisionBuiltInEngine(
        variant: _variant,
        onProgress: _onProgress,
        onHandleReady: (RwkvCancelHandle h) => _cancelHandle = h,
      );
      if (!mounted) return;
      widget.onProvisioned(p);
      setState(
        () => _status = l10n.tf(
          'AIC.BuiltIn.EngineReadyFmt',
          '引擎已就位：{0}\n词表已就位：{1}',
          {'0': p.executablePath, '1': p.vocabPath},
        ),
      );
    } on RwkvDownloadCancelledException catch (_) {
      if (mounted) {
        setState(() => _status = l10n.t('AIC.StatusCancelled', '已取消'));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _status = l10n.tf('AIC.InstallFailed', '安装失败：{error}', {
            'error': '$e',
          }),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 下载官方 `.pth` 原生权重（引擎格式，非 GGUF）
  Future<void> _downloadModel() async {
    if (_busy) return;
    final l10n = ref.read(l10nProvider);
    setState(() => _busy = true);
    try {
      final models = await _provider.listBuiltInEngineModels(
        onProgress: _onProgress,
      );
      if (!mounted) return;
      if (models.isEmpty) {
        setState(() {
          _status = l10n.t(
            'AIC.BuiltIn.NoModel',
            '未找到可用 .pth 权重，请稍后重试或手动下载到 rwkv_models/。',
          );
          _busy = false;
        });
        return;
      }
      // 先探一次显存（探不到就返回空列表 → 不做任何拦截）
      final List<RwkvGpuInfo> gpus = _gpus ?? await rwkvProbeGpus();
      _gpus = gpus;
      if (!mounted) return; // await 之后 context 可能已失效
      final int? vramFree = gpus.isEmpty ? null : gpus.first.freeBytes;

      // ⚠ 关键：**按参数量**挑推荐，不是按文件体积 ——
      //   真实清单里 `rwkv7b-g1b-0.1b-...` 有 3.4GB，比 1.5B 还大，
      //   按体积挑会挑到那个降智的架构变体（PITFALLS §38.3）。
      final RwkvOfficialModel? recommended =
          pickBestFittingModel<RwkvOfficialModel>(
            models,
            sizeOf: (RwkvOfficialModel m) => m.sizeBytes,
            rankOf: (RwkvOfficialModel m) => parseParamRankFromName(m.fileName),
            vramAvailableBytes: vramFree,
          );

      final RwkvOfficialModel? picked = await showDialog<RwkvOfficialModel>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(l10n.t('AIC.BuiltIn.PickModel', '选择官方原生 .pth 权重')),
          content: SizedBox(
            width: 680,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (vramFree != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.tf(
                        'AICfg.GpuFreeFmt',
                        '{0} · 空闲 {1}GB',
                        <Object>[
                          gpus.first.name,
                          (vramFree / (1024 * 1024 * 1024)).toStringAsFixed(1),
                        ],
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.t(
                        'AIC.BuiltIn.NoGpuProbe',
                        '未探测到显卡显存，以下仅显示权重体积，请自行确认能否加载',
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: models.length,
                    itemBuilder: (BuildContext c, int i) {
                      final RwkvOfficialModel m = models[i];
                      final RwkvModelFit fit = judgeModelFit(
                        modelSizeBytes: m.sizeBytes,
                        vramAvailableBytes: vramFree,
                      );
                      final bool isRecommended =
                          recommended != null &&
                          recommended.fileName == m.fileName;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          fit == RwkvModelFit.fits
                              ? Icons.check_circle_outline
                              : fit == RwkvModelFit.tight
                              ? Icons.warning_amber_outlined
                              : fit == RwkvModelFit.tooLarge
                              ? Icons.block_outlined
                              : Icons.help_outline,
                          size: 18,
                          color: fit == RwkvModelFit.fits
                              ? Theme.of(ctx).colorScheme.primary
                              : fit == RwkvModelFit.tight
                              ? Theme.of(ctx).colorScheme.tertiary
                              : Theme.of(ctx).colorScheme.error,
                        ),
                        title: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                m.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isRecommended)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    ctx,
                                  ).colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  l10n.t('AIC.BuiltIn.Recommended', '本机推荐'),
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          '${m.paramsLabel} · ${m.sizeHumanReadable}\n'
                          '${describeModelFit(modelSizeBytes: m.sizeBytes, vramAvailableBytes: vramFree)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        isThreeLine: true,
                        enabled: !fit.shouldBlock,
                        onTap: fit.shouldBlock
                            ? null
                            : () => Navigator.pop(ctx, m),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.t('Common.Cancel', '取消')),
            ),
          ],
        ),
      );
      if (picked == null) return;
      final String path = await _provider.downloadOfficialModel(
        picked,
        onProgress: _onProgress,
        onHandleReady: (RwkvCancelHandle h) => _cancelHandle = h,
      );
      if (!mounted) return;
      widget.onModelDownloaded(path, _variant);
      setState(
        () => _status = l10n.tf('AIC.ModelDownloadedPathFmt', '模型已下载：{0}', {
          '0': path,
        }),
      );
    } on RwkvDownloadCancelledException catch (_) {
      if (mounted) {
        setState(() => _status = l10n.t('AIC.StatusCancelled', '已取消'));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _status = l10n.tf('AIC.DownloadFailed', '下载失败：{error}', {
            'error': '$e',
          }),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用已装好的引擎拉起本地 server
  Future<void> _launch() async {
    if (_launching) return;
    final L10n l10n = ref.read(l10nProvider);
    setState(() => _launching = true);
    try {
      final bool ok = await _provider.launchLocalServer(
        serverVariant: _variant,
      );
      final String? diag = _provider.lastLaunchDiagnostics;
      if (!mounted) return;
      setState(
        () => _status = ok
            ? l10n.t('AICfg.EngineStarted',
                '✅ 内置引擎已启动（/v1/server/status 可查能力与显存）')
            : l10n.tf('AICfg.EngineLaunchFailedFmt', '启动失败：\n{0}',
                <Object>[diag ?? l10n.t('AICfg.NoDiagnostics', '无诊断信息')]),
      );
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.bolt_outlined, size: 18, color: scheme.tertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.t('AIC.BuiltIn.Title', '内置推理引擎 · rwkv_lightning_cuda'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                l10n.t('AIC.BuiltIn.Badge', '推荐 · 免编译'),
                style: TextStyle(fontSize: 11, color: scheme.tertiary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.t(
              'AIC.BuiltIn.Desc',
              '官方预编译 CUDA 包，下载后校验 SHA-256 并自动解压。'
                  '只支持 .pth / .rwkvq 权重，且必须配套外置词表（引擎不内嵌词表）。',
            ),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<OfficialServerVariant>(
                  initialValue: _variant,
                  isDense: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('AIC.BuiltIn.Variant', 'CUDA 档位'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: <DropdownMenuItem<OfficialServerVariant>>[
                    DropdownMenuItem<OfficialServerVariant>(
                      value: OfficialServerVariant.cuda13,
                      child: Text(l10n.t('AICfg.Cuda13',
                          'CUDA 13.2（新驱动推荐）')),
                    ),
                    DropdownMenuItem<OfficialServerVariant>(
                      value: OfficialServerVariant.cuda12,
                      child: Text(l10n.t('AICfg.Cuda12',
                          'CUDA 12.9（兼容旧驱动）')),
                    ),
                  ],
                  onChanged: _running
                      ? null
                      : (OfficialServerVariant? v) {
                          if (v != null) setState(() => _variant = v);
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || _running ? null : _provision,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.memory_outlined, size: 18),
                  label: Text(
                    l10n.t('AIC.BuiltIn.InstallBtn', '⚡ 安装内置引擎 + 词表'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || _running ? null : _downloadModel,
                  icon: const Icon(
                    Icons.download_for_offline_outlined,
                    size: 18,
                  ),
                  label: Text(
                    l10n.t('AIC.BuiltIn.DownloadModelBtn', '📥 下载 .pth 原生权重'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || _launching ? null : _launch,
                  icon: _launching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_outlined, size: 18),
                  label: Text(l10n.t('AIC.BuiltIn.LaunchBtn', '🚀 启动内置引擎')),
                ),
              ),
            ],
          ),
          // ---- 会话 state 续跑 / 思考前缀（原生参数）----
          const SizedBox(height: 10),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: widget.statefulRoute,
            onChanged: _busy || _running ? null : widget.onStatefulRouteChanged,
            title: Text(
              l10n.t('AIC.BuiltIn.StatefulRoute', '会话 state 续跑（每轮只发增量）'),
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              l10n.t(
                'AIC.BuiltIn.StatefulRouteHint',
                '走 /state/chat/completions，由服务端按 session_id 维护 state。'
                    '实测有效；若换成不提供 /state/* 的引擎请关闭。',
              ),
              style: const TextStyle(fontSize: 11),
            ),
          ),
          Row(
            children: <Widget>[
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  initialValue: widget.thinkType,
                  isDense: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('AIC.BuiltIn.ThinkType', '思考前缀'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(
                      value: 'none',
                      child: Text('none'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'fast',
                      child: Text(l10n.t('AICfg.FastDefault', 'fast（默认）')),
                    ),
                    const DropdownMenuItem<String>(
                      value: 'free',
                      child: Text('free'),
                    ),
                    const DropdownMenuItem<String>(
                      value: 'preferChinese',
                      child: Text('preferChinese'),
                    ),
                    const DropdownMenuItem<String>(
                        value: 'en', child: Text('en')),
                    const DropdownMenuItem<String>(
                      value: 'enShort',
                      child: Text('enShort'),
                    ),
                    const DropdownMenuItem<String>(
                      value: 'enLong',
                      child: Text('enLong'),
                    ),
                  ],
                  onChanged: _busy || _running
                      ? null
                      : (String? v) {
                          if (v != null) widget.onThinkTypeChanged(v);
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.t(
                    'AIC.BuiltIn.ThinkHint',
                    '控制助手思考前缀；采样参数（top_k/top_p/alpha_*）与 '
                        'stop_tokens 已按官方默认值固定透传。',
                  ),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (_progress != null) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: LinearProgressIndicator(
                    value: _progress!.totalBytes > 0
                        ? _progress!.fractionComplete
                        : null,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _fmtProgress(_progress!),
                  style: const TextStyle(fontSize: 11),
                ),
                if (_running)
                  IconButton(
                    tooltip: l10n.t('Common.Cancel', '取消'),
                    onPressed: () {
                      final RwkvCancelHandle? h = _cancelHandle;
                      if (h != null && !h.isCancelled) {
                        h.cancel(l10n.t('Common.UserCancelled', '用户取消'));
                      }
                    },
                    icon: const Icon(Icons.close, size: 16),
                  ),
              ],
            ),
            if (_progress!.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _progress!.message!,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
          if (_status != null) ...<Widget>[
            const SizedBox(height: 8),
            SelectableText(
              _status!,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// 云端官方端点（`api-7b.rwkvos.com`）的 Cloudflare Access 凭证卡片。
///
/// 单独一张卡的原因：CF Service Token 的两个头名**按字节精确**比较，
/// 拼错不会 401，而是静默返回 HTML 登录页 —— 必须把这两个值摆在显眼处，
/// 并给出「取引擎状态」按钮让用户立刻验证是否真的通了（PITFALLS §27.2 / §31）。
class _CloudEndpointProfilesCard extends ConsumerWidget {
  const _CloudEndpointProfilesCard({
    required this.profiles,
    required this.selectedId,
    required this.onSelected,
    required this.onAdd,
    required this.onRemove,
  });

  final List<RwkvCloudEndpointProfile> profiles;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final RwkvCloudEndpointProfile? selected = profiles
        .where((RwkvCloudEndpointProfile p) => p.id == selectedId)
        .firstOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 300,
              child: DropdownButtonFormField<String>(
                initialValue: selected?.id,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.t('AIC.Cloud.EndpointProfile', '云端端点配置'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: <DropdownMenuItem<String>>[
                  for (final RwkvCloudEndpointProfile profile in profiles)
                    DropdownMenuItem<String>(
                      value: profile.id,
                      child: Text(
                        '${profile.name} · ${profile.baseUrl}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (String? id) {
                  if (id != null) onSelected(id);
                },
              ),
            ),
            OutlinedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.t('AIC.Cloud.AddProfile', '添加配置')),
            ),
            if (selected != null && !selected.id.startsWith('official-'))
              IconButton(
                tooltip: l10n.t('AIC.Cloud.RemoveProfile', '删除此配置'),
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
      ),
    );
  }
}

class _CloudCfCard extends ConsumerStatefulWidget {
  const _CloudCfCard({
    required this.clientId,
    required this.clientSecret,
    required this.onCredentialsChanged,
    required this.onPersist,
    required this.onFetchStatus,
  });

  final String clientId;
  final String clientSecret;
  final void Function(String clientId, String clientSecret)
  onCredentialsChanged;
  final Future<void> Function() onPersist;
  final Future<RwkvCloudServerSummary?> Function() onFetchStatus;

  @override
  ConsumerState<_CloudCfCard> createState() => _CloudCfCardState();
}

class _CloudCfCardState extends ConsumerState<_CloudCfCard> {
  late final TextEditingController _idCtrl = TextEditingController(
    text: widget.clientId,
  );
  late final TextEditingController _secretCtrl = TextEditingController(
    text: widget.clientSecret,
  );
  bool _busy = false;
  RwkvCloudServerSummary? _summary;
  String? _error;

  @override
  void dispose() {
    _idCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.onFetchStatus();
      if (!mounted) return;
      setState(() {
        _summary = s;
        _error = s == null
            ? ref
                  .read(l10nProvider)
                  .t(
                    'AIC.Cloud.StatusUnavailable',
                    '取不到引擎状态：端点未响应或不是 rwkv_lightning_cuda。',
                  )
            : null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.shield_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.t(
                    'AIC.Cloud.CfTitle',
                    'Cloudflare Access 凭证（Service Token）',
                  ),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () async {
                  widget.onCredentialsChanged(
                    _idCtrl.text.trim(),
                    _secretCtrl.text.trim(),
                  );
                  await widget.onPersist();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.t('Common.Saved', '已保存'))),
                    );
                  }
                },
                child: Text(l10n.t('Common.Save', '保存')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.t(
              'AIC.Cloud.CfHint',
              '头名按字节精确匹配：CF-Access-Client-Id / CF-Access-Client-Secret。'
                  '拼错不会报 401，而是静默返回 HTML 登录页。',
            ),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _idCtrl,
            decoration: InputDecoration(
              labelText: kHeaderCfAccessClientId,
              hintText: 'xxxxxxxx.access',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (String v) =>
                widget.onCredentialsChanged(v.trim(), _secretCtrl.text.trim()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secretCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: kHeaderCfAccessClientSecret,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (String v) =>
                widget.onCredentialsChanged(_idCtrl.text.trim(), v.trim()),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _busy ? null : _fetch,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.monitor_heart_outlined, size: 18),
                label: Text(
                  l10n.t('AIC.Cloud.FetchStatus', '🩺 取引擎状态（验证是否真的连通）'),
                ),
              ),
            ],
          ),
          if (_summary != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'engine=${_summary!.engineVersion}  api=${_summary!.apiVersion}  '
              'status=${_summary!.status}',
              style: const TextStyle(fontSize: 11),
            ),
            Text(
              'bsz: hard=${_summary!.hardMaxBsz} dynamic=${_summary!.dynamicMaxBsz} '
              'available=${_summary!.availableBsz} queued=${_summary!.queuedRequests}',
              style: const TextStyle(fontSize: 11),
            ),
            if (_summary!.totalVramGb != null)
              Text(
                'VRAM ${_summary!.freeVramGb?.toStringAsFixed(1)} / '
                '${_summary!.totalVramGb!.toStringAsFixed(1)} GB   '
                'decode=${_summary!.lastDecodeSpeed?.toStringAsFixed(1) ?? "-"} tok/s   '
                'prefill=${_summary!.lastPrefillSpeed?.toStringAsFixed(0) ?? "-"} tok/s',
                style: const TextStyle(fontSize: 11),
              ),
            Text(
              'capabilities: ${_summary!.capabilities.entries.where((MapEntry<String, bool> e) => e.value).map((MapEntry<String, bool> e) => e.key).join(", ")}',
              style: const TextStyle(fontSize: 11),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            SelectableText(
              _error!,
              style: TextStyle(fontSize: 11, color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProviderList extends ConsumerWidget {
  const _ProviderList({
    required this.selectedKind,
    required this.onTap,
    required this.configs,
    required this.availableMap,
    required this.defaultProvider,
    required this.registered,
    required this.onSetDefault,
    required this.isEnglish,
    this.width = 220,
  });

  /// 列表宽度；窄屏（上下堆叠）布局传 [double.infinity] 占满整行
  final double width;

  final _ProviderKind selectedKind;
  final ValueChanged<_ProviderKind> onTap;
  final Map<_ProviderKind, _ProviderConfig> configs;
  final Map<String, bool> availableMap;
  final String? defaultProvider;
  final List<IModelProvider> registered;
  final ValueChanged<String> onSetDefault;
  final bool isEnglish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  l10n.t('AIC.ProviderListTitle', '提供商'),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              for (final k in _ProviderKind.values)
                _ProviderTile(
                  kind: k,
                  selected: k == selectedKind,
                  onTap: () => onTap(k),
                  isAvailable:
                      availableMap[configs[k]!.registeredName] ?? false,
                  isRegistered: registered.any(
                    (p) => p.providerName == configs[k]!.registeredName,
                  ),
                  isDefault: defaultProvider == configs[k]!.registeredName,
                  onSetDefault: () => onSetDefault(configs[k]!.registeredName),
                  isEnglish: isEnglish,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderTile extends ConsumerWidget {
  const _ProviderTile({
    required this.kind,
    required this.selected,
    required this.onTap,
    required this.isAvailable,
    required this.isRegistered,
    required this.isDefault,
    required this.onSetDefault,
    required this.isEnglish,
  });

  final _ProviderKind kind;
  final bool selected;
  final VoidCallback onTap;
  final bool isAvailable;
  final bool isRegistered;
  final bool isDefault;
  final VoidCallback onSetDefault;
  final bool isEnglish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: selected ? scheme.secondaryContainer : null,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                kind.icon,
                size: 18,
                color: selected ? scheme.onSecondaryContainer : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _pvdLabel(kind, isEnglish),
                      style: TextStyle(
                        fontSize: 13,
                        color: selected ? scheme.onSecondaryContainer : null,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          isAvailable
                              ? Icons.check_circle
                              : (isRegistered
                                    ? Icons.help_outline
                                    : Icons.circle_outlined),
                          size: 10,
                          color: isAvailable
                              ? Colors.green
                              : (isRegistered ? Colors.orange : scheme.outline),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isAvailable
                              ? l10n.t('AIC.StatusConnected', '已连接')
                              : (isRegistered
                                    ? l10n.t('AIC.StatusPendingTest', '待测试')
                                    : l10n.t('AIC.StatusUnregistered', '未注册')),
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isDefault)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l10n.t('AIC.DefaultBadge', '默认'),
                    style: TextStyle(
                      fontSize: 9,
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else if (isRegistered)
                IconButton(
                  icon: const Icon(Icons.star_border, size: 16),
                  iconSize: 16,
                  tooltip: l10n.t('AIC.SetDefaultTooltip', '设为默认'),
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  onPressed: onSetDefault,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfigCard extends ConsumerWidget {
  const _ConfigCard({
    required this.cfg,
    required this.onChanged,
    required this.testing,
    required this.onTest,
    required this.connectingTo,
    required this.onSave,
    this.lastTest,
    this.cloudModelIds,
    this.cloudModelsLoading = false,
    this.cloudModelsError,
    this.onFetchCloudModels,
    this.rwkvModels,
    this.rwkvScanning = false,
    this.rwkvLaunching = false,
    this.rwkvStopping = false,
    this.rwkvServerRunning = false,
    this.onRefreshRwkvModels,
    this.onLaunchRwkvServer,
    this.onStopRwkvServer,
    this.serverVariant,
    this.onServerVariantChanged,
    this.serverInstallProgress,
    this.modelDownloadProgress,
    this.onInstallOfficialServer,
    this.onShowOfficialModelsDialog,
    this.onCancelServerInstall,
    this.onCancelModelDownload,
    required this.isEnglish,
  });

  final _ProviderConfig cfg;
  final VoidCallback onChanged;
  final bool testing;
  final Future<void> Function() onTest;
  final String? connectingTo;
  final Future<void> Function() onSave;
  final ConnectionTestResult? lastTest;
  final List<String>? cloudModelIds;
  final bool cloudModelsLoading;
  final String? cloudModelsError;
  final Future<void> Function()? onFetchCloudModels;
  final List<RwkvLocalModel>? rwkvModels;
  final bool rwkvScanning;
  final bool rwkvLaunching;
  final bool rwkvStopping;

  /// 本地 server 进程当前是否在运行（决定「停止」按钮是否可点）。
  final bool rwkvServerRunning;

  /// 手动停止本地 server。
  final Future<void> Function()? onStopRwkvServer;
  final VoidCallback? onRefreshRwkvModels;
  final Future<void> Function()? onLaunchRwkvServer;
  final OfficialServerVariant? serverVariant;
  final void Function(OfficialServerVariant v)? onServerVariantChanged;
  final RwkvDownloadProgress? serverInstallProgress;
  final RwkvDownloadProgress? modelDownloadProgress;
  final Future<void> Function()? onInstallOfficialServer;
  final Future<void> Function()? onShowOfficialModelsDialog;
  final VoidCallback? onCancelServerInstall;
  final VoidCallback? onCancelModelDownload;
  final bool isEnglish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 窄视口下「标题 + Spacer + 两个按钮」会溢出 30px：
            // 标题用 Flexible 收缩，按钮行改 Wrap 允许换行
            Row(
              children: [
                Flexible(
                  child: Text(
                    l10n.tf('AIC.ParamsTitle', '{label} 参数', {
                      'label': _pvdLabel(cfg.kind, isEnglish),
                    }),
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: scheme.primary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: testing ? null : onTest,
                  icon: testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link_outlined, size: 18),
                  label: Text(
                    testing
                        ? l10n.t('AIC.Connecting', '连接中…')
                        : l10n.t('AIC.TestConnection', '测试连接'),
                  ),
                ),
                FilledButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(l10n.t('AIC.SaveAndRegister', '保存并注册')),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Field(
                  label: l10n.t('AIC.FieldBaseUrl', 'API 基础地址'),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: TextField(
                      controller: TextEditingController(text: cfg.baseUrl)
                        ..selection = TextSelection.fromPosition(
                          TextPosition(offset: cfg.baseUrl.length),
                        ),
                      onChanged: (v) {
                        cfg.baseUrl = v;
                        onChanged();
                      },
                      onSubmitted: (_) => onFetchCloudModels?.call(),
                      decoration: InputDecoration(
                        hintText: l10n.t(
                          'AIC.HintBaseUrl',
                          'https://… 或 http://localhost:…',
                        ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                if (!cfg.kind.isLocal)
                  _Field(
                    label: cfg.kind == _ProviderKind.rwkvCloud
                        ? l10n.t('AIC.Cloud.ApiKeyOptional', 'API Key（可选）')
                        : l10n.t('AIC.FieldApiKey', 'API Key'),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: TextField(
                        obscureText: true,
                        controller: TextEditingController(text: cfg.apiKey)
                          ..selection = TextSelection.fromPosition(
                            TextPosition(offset: cfg.apiKey.length),
                          ),
                        onChanged: (v) {
                          cfg.apiKey = v;
                          onChanged();
                        },
                        decoration: InputDecoration(
                          hintText: l10n.t('AIC.HintApiKey', 'sk-…'),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                _Field(
                  label: l10n.t('AIC.FieldDefaultModel', '默认模型'),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: TextField(
                      controller: TextEditingController(text: cfg.defaultModel)
                        ..selection = TextSelection.fromPosition(
                          TextPosition(offset: cfg.defaultModel.length),
                        ),
                      onChanged: (v) {
                        cfg.defaultModel = v;
                        onChanged();
                      },
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                if (cfg.kind == _ProviderKind.rwkvCloud)
                  _Field(
                    label: l10n.t(
                      'AIC.Cloud.ModelsFromEndpoint',
                      '从当前 API 地址获取模型',
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 2,
                                ),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value:
                                      (cloudModelIds ?? const <String>[])
                                          .contains(cfg.defaultModel)
                                      ? cfg.defaultModel
                                      : null,
                                  isExpanded: true,
                                  isDense: true,
                                  hint: Text(
                                    (cloudModelIds ?? const <String>[]).isEmpty
                                        ? l10n.t(
                                            'AIC.Cloud.FetchModelsHint',
                                            '获取后选择模型',
                                          )
                                        : l10n.t(
                                            'AIC.Cloud.SelectModel',
                                            '请选择模型',
                                          ),
                                  ),
                                  items: <DropdownMenuItem<String>>[
                                    for (final String id
                                        in cloudModelIds ?? const <String>[])
                                      DropdownMenuItem<String>(
                                        value: id,
                                        child: Text(
                                          id,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (String? id) {
                                    if (id == null) return;
                                    cfg.defaultModel = id;
                                    onChanged();
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            tooltip: l10n.t(
                              'AIC.Cloud.FetchModels',
                              '从 API 地址获取模型',
                            ),
                            onPressed: cloudModelsLoading
                                ? null
                                : () => onFetchCloudModels?.call(),
                            icon: cloudModelsLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (cfg.kind == _ProviderKind.rwkvCloud &&
                    cloudModelsError != null)
                  SizedBox(
                    width: 360,
                    child: Text(
                      cloudModelsError!,
                      style: TextStyle(color: scheme.error, fontSize: 11),
                    ),
                  ),
                _Field(
                  label: l10n.t('AIC.FieldTimeout', '超时 (秒)'),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: TextField(
                      keyboardType: TextInputType.number,
                      controller: TextEditingController(
                        text: cfg.timeoutSeconds.toString(),
                      ),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n > 0) {
                          cfg.timeoutSeconds = n;
                          onChanged();
                        }
                      },
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                _Field(
                  label: 'Temperature',
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: TextField(
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      controller: TextEditingController(
                        text: cfg.defaultTemperature.toString(),
                      ),
                      onChanged: (v) {
                        final n = double.tryParse(v);
                        if (n != null) {
                          cfg.defaultTemperature = n;
                          onChanged();
                        }
                      },
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                // ---- 最大令牌数：滑动输入，档位节点 16K~1M ----
                // （原为 140 宽数字输入框；改为全宽 Slider，7 档 snap，
                //   非档位的存量值自动吸附最近档位）
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            l10n.t('AIC.FieldMaxTokens', '最大令牌数'),
                            style: const TextStyle(fontSize: 12),
                          ),
                          const Spacer(),
                          Text(
                            maxTokensLabel(cfg.defaultMaxTokens),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: maxTokensSliderIndex(
                          cfg.defaultMaxTokens,
                        ).toDouble(),
                        min: 0,
                        max: (kMaxTokensSteps.length - 1).toDouble(),
                        divisions: kMaxTokensSteps.length - 1,
                        label: maxTokensLabel(cfg.defaultMaxTokens),
                        onChanged: (v) {
                          final int next = kMaxTokensSteps[v.round()];
                          cfg.defaultMaxTokens = next;
                          // 最大参考长度恒等于最大令牌数 → 同步运行时设置，
                          // 生成链路据此决定参考上下文的字符预算。
                          aiRuntimeSettings = aiRuntimeSettings.copyWith(
                            maxReferenceLength: next,
                          );
                          onChanged();
                        },
                      ),
                      // 档位刻度
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final String lbl in kMaxTokensStepLabels)
                            Text(
                              lbl,
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 最大参考长度：只读展示 —— 用户约定「模型最大参考长度
                      // = 模型最大 Tokens」，恒等于上方滑块值，不可单独编辑。
                      Row(
                        children: [
                          Text(
                            l10n.t('AIC.FieldMaxRefLength', '最大参考长度'),
                            style: const TextStyle(fontSize: 12),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            maxTokensLabel(cfg.maxReferenceLength),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: scheme.primary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.tf(
                                'AIC.MaxRefLengthHint',
                                '自动等于「最大令牌数」；实际在 {0} 窗口内切分为 参考 {1} / 输出 {2}',
                                <Object>[
                                  '${aiRuntimeSettings.contextWindowTokens}',
                                  '${aiRuntimeSettings.referenceBudgetTokens}',
                                  '${aiRuntimeSettings.outputBudgetTokens}',
                                ],
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _Field(
                  label: l10n.t('AIC.FieldStreaming', '流式输出'),
                  child: Switch(
                    value: cfg.enableStreaming,
                    onChanged: (v) {
                      cfg.enableStreaming = v;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
            if (cfg.kind == _ProviderKind.rwkv && rwkvModels != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.cloud_download_outlined,
                          size: 18,
                          color: scheme.tertiary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.t('AIC.OfficialResourcesTitle', '官方资源一键安装'),
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: scheme.onTertiaryContainer),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Builder(
                            builder: (BuildContext _) {
                              final sv =
                                  serverVariant ?? OfficialServerVariant.vulkan;
                              return InputDecorator(
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText: l10n.t(
                                    'AIC.FieldHardwareVariant',
                                    '硬件加速版本',
                                  ),
                                  border: const OutlineInputBorder(),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<OfficialServerVariant>(
                                    value: sv,
                                    isDense: true,
                                    onChanged: (OfficialServerVariant? v) {
                                      if (v != null &&
                                          onServerVariantChanged != null) {
                                        onServerVariantChanged!(v);
                                      }
                                    },
                                    items: OfficialServerVariant.values
                                        .map(
                                          (OfficialServerVariant v) =>
                                              DropdownMenuItem<
                                                OfficialServerVariant
                                              >(
                                                value: v,
                                                child: Text(v.displayName),
                                              ),
                                        )
                                        .toList(growable: false),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 4,
                          child: FilledButton.icon(
                            onPressed:
                                (serverInstallProgress != null &&
                                    !serverInstallProgress!.phase.isTerminal)
                                ? null
                                : onInstallOfficialServer,
                            icon:
                                serverInstallProgress != null &&
                                    !serverInstallProgress!.phase.isTerminal
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.install_desktop_outlined,
                                    size: 18,
                                  ),
                            label: Text(
                              serverInstallProgress != null &&
                                      serverInstallProgress!.phase.isTerminal &&
                                      serverInstallProgress!.phase ==
                                          RwkvDownloadPhase.done
                                  ? l10n.t(
                                      'AIC.OfficialServerInstalledBtn',
                                      '✅ 已安装官方 Server',
                                    )
                                  : l10n.t(
                                      'AIC.InstallOfficialServerBtn',
                                      '📦 安装官方 llama.cpp Server',
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (serverInstallProgress != null)
                      _buildProgressBlock(
                        context,
                        ref: ref,
                        progress: serverInstallProgress!,
                        scheme: scheme,
                        completedLabel: l10n.t(
                          'AIC.LlamaServerInstalled',
                          '✅ llama-server.exe 已安装',
                        ),
                        idleHide: false,
                        onCancel:
                            (serverInstallProgress != null &&
                                !serverInstallProgress!.phase.isTerminal &&
                                onCancelServerInstall != null)
                            ? onCancelServerInstall
                            : null,
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed:
                                (modelDownloadProgress != null &&
                                    !modelDownloadProgress!.phase.isTerminal)
                                ? null
                                : onShowOfficialModelsDialog,
                            icon:
                                modelDownloadProgress != null &&
                                    !modelDownloadProgress!.phase.isTerminal
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.download_for_offline_outlined,
                                    size: 18,
                                  ),
                            label: Text(
                              modelDownloadProgress != null &&
                                      modelDownloadProgress!.phase.isTerminal &&
                                      modelDownloadProgress!.phase ==
                                          RwkvDownloadPhase.done
                                  ? l10n.t(
                                      'AIC.LatestModelDownloadedBtn',
                                      '✅ 已下载最新模型',
                                    )
                                  : l10n.t(
                                      'AIC.DownloadOfficialModelBtn',
                                      '📥 下载官方原生 RWKV 模型',
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (modelDownloadProgress != null)
                      _buildProgressBlock(
                        context,
                        ref: ref,
                        progress: modelDownloadProgress!,
                        scheme: scheme,
                        completedLabel: l10n.t(
                          'AIC.OfficialModelDownloaded',
                          '✅ 官方模型已下载',
                        ),
                        idleHide: false,
                        onCancel:
                            (modelDownloadProgress != null &&
                                !modelDownloadProgress!.phase.isTerminal &&
                                onCancelModelDownload != null)
                            ? onCancelModelDownload
                            : null,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.memory_outlined,
                          size: 18,
                          color: scheme.secondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.t('AIC.LocalRwkvManagement', '本地 RWKV 管理'),
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: scheme.onSecondaryContainer),
                        ),
                        const Spacer(),
                        IconButton.filledTonal(
                          onPressed: rwkvScanning ? null : onRefreshRwkvModels,
                          iconSize: 18,
                          tooltip: l10n.t('AIC.RescanModels', '重新扫描模型目录'),
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                          icon: rwkvScanning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh, size: 18),
                        ),
                        const SizedBox(width: 6),
                        FilledButton.icon(
                          onPressed: (rwkvLaunching || testing)
                              ? null
                              : onLaunchRwkvServer,
                          icon: rwkvLaunching
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_arrow, size: 18),
                          label: Text(
                            rwkvLaunching
                                ? l10n.t('AIC.Starting', '启动中…')
                                : l10n.t(
                                    'AIC.StartLocalRwkvServer',
                                    '启动本地 RWKV Server',
                                  ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 手动停止：仅在进程确实在跑时可点（避免无意义点击）
                        OutlinedButton.icon(
                          onPressed:
                              (rwkvStopping ||
                                  !rwkvServerRunning ||
                                  onStopRwkvServer == null)
                              ? null
                              : onStopRwkvServer,
                          icon: rwkvStopping
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.stop_circle_outlined,
                                  size: 18,
                                ),
                          label: Text(
                            rwkvStopping
                                ? l10n.t('AIC.Stopping', '停止中…')
                                : l10n.t(
                                    'AIC.StopLocalRwkvServer',
                                    '停止本地 Server',
                                  ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _Field(
                          label: l10n.t(
                            'AIC.FieldRwkvExecutable',
                            'RWKV Server 可执行文件',
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 440),
                            child: TextField(
                              controller:
                                  TextEditingController(
                                      text: cfg.rwkvLocalExecutable ?? '',
                                    )
                                    ..selection = TextSelection.fromPosition(
                                      TextPosition(
                                        offset: (cfg.rwkvLocalExecutable ?? '')
                                            .length,
                                      ),
                                    ),
                              onChanged: (v) {
                                cfg.rwkvLocalExecutable = v.isEmpty ? null : v;
                                onChanged();
                              },
                              decoration: InputDecoration(
                                hintText: l10n.t(
                                  'AIC.HintRwkvExecutable',
                                  r'C:\path\to\llama-server.exe 或 rwkv.cpp\server.exe',
                                ),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ),
                        _Field(
                          label: l10n.t(
                            'AIC.FieldLocalGgufModel',
                            '本地 GGUF 模型（下拉选择）',
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 320),
                            child: Builder(
                              builder: (context) {
                                final list = rwkvModels ?? const [];
                                final selected = list.isEmpty
                                    ? null
                                    : list.firstWhere(
                                        (m) =>
                                            m.filePath ==
                                            cfg.rwkvLocalModelPath,
                                        orElse: () => list.first,
                                      );
                                return InputDecorator(
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 2,
                                    ),
                                    suffixIcon: onRefreshRwkvModels == null
                                        ? null
                                        : Padding(
                                            padding: const EdgeInsets.only(
                                              right: 4,
                                            ),
                                            child: rwkvScanning
                                                ? const SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                        ),
                                                  )
                                                : null,
                                          ),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<RwkvLocalModel>(
                                      value: selected,
                                      isExpanded: true,
                                      isDense: true,
                                      hint: Text(
                                        list.isEmpty
                                            ? l10n.t(
                                                'AIC.NoGgufFiles',
                                                'rwkv_models/ 无 GGUF 文件',
                                              )
                                            : l10n.t(
                                                'AIC.SelectModelHint',
                                                '请选择模型',
                                              ),
                                        style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                      items: [
                                        for (final m in list)
                                          DropdownMenuItem<RwkvLocalModel>(
                                            value: m,
                                            child: Tooltip(
                                              message: m.filePath,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    m.displayName,
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    '${(m.sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB · ${m.fileName}',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                      onChanged: (v) {
                                        if (v == null) return;
                                        cfg.rwkvLocalModelPath = v.filePath;
                                        if (cfg.defaultModel.isEmpty ||
                                            cfg.defaultModel == 'rwkv7-g1i') {
                                          cfg.defaultModel = v.fileName;
                                        }
                                        onChanged();
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    if ((cfg.rwkvLocalModelPath ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          l10n.tf('AIC.CurrentModelPath', '当前模型路径: {path}', {
                            'path': cfg.rwkvLocalModelPath ?? '',
                          }),
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (lastTest != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: lastTest!.isSuccess
                      ? scheme.primary.withValues(alpha: 0.08)
                      : Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: lastTest!.isSuccess
                        ? scheme.primary
                        : Colors.red.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      lastTest!.isSuccess
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: lastTest!.isSuccess ? scheme.primary : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        lastTest!.isSuccess
                            ? l10n.tf(
                                'AIC.ConnectSuccess',
                                '连接成功 · 耗时 {ms}ms{versionInfo}',
                                {
                                  'ms':
                                      '${lastTest!.responseTime.inMilliseconds}',
                                  'versionInfo':
                                      lastTest!.serverInfo.containsKey(
                                        'version',
                                      )
                                      ? l10n.tf(
                                          'AIC.ServerVersion',
                                          ' · 服务版本: {v}',
                                          {
                                            'v':
                                                '${lastTest!.serverInfo['version']}',
                                          },
                                        )
                                      : '',
                                },
                              )
                            : l10n.tf('AIC.ConnectFailed', '连接失败: {msg}', {
                                'msg': '${lastTest!.errorMessage}',
                              }),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Field extends ConsumerWidget {
  const _Field({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _StatsCard extends ConsumerWidget {
  const _StatsCard({this.stats, this.available});
  final ProviderStatistics? stats;
  final bool? available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final s = stats ?? const ProviderStatistics();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('AIC.StatsTitle', '运行统计'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: scheme.primary),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _StatChip(
                  label: l10n.t('AIC.StatTotalRequests', '总请求'),
                  value: '${s.totalRequests}',
                ),
                _StatChip(
                  label: l10n.t('AIC.StatSuccess', '成功'),
                  value: '${s.successfulRequests}',
                  color: Colors.green,
                ),
                _StatChip(
                  label: l10n.t('AIC.StatFailed', '失败'),
                  value: '${s.failedRequests}',
                  color: Colors.red,
                ),
                _StatChip(
                  label: l10n.t('AIC.StatAvgResponse', '平均响应'),
                  value: '${s.averageResponseTime.inMilliseconds}ms',
                ),
                _StatChip(
                  label: l10n.t('AIC.StatTotalTokens', '累计令牌'),
                  value: '${s.totalTokensUsed}',
                ),
                _StatChip(
                  label: l10n.t('AIC.StatLastRequest', '最后请求'),
                  value: s.lastRequestTime == null
                      ? '—'
                      : s.lastRequestTime!
                            .toLocal()
                            .toString()
                            .split('.')
                            .first,
                ),
                _StatChip(
                  label: l10n.t('AIC.StatAvailability', '可用性'),
                  value: available == true
                      ? l10n.t('AIC.StatusOnline', '在线')
                      : l10n.t('AIC.StatusOffline', '离线'),
                  color: available == true ? Colors.green : scheme.outline,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends ConsumerWidget {
  const _StatChip({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              color: c,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// MainAgent / SubAgent 双代理写作流配置卡片。
///
/// 这是**全局**配置（不属于任何单个 provider），所以固定展示在右侧栏底部。
/// 开关与下拉改完即落盘；四个文本框用「保存」显式提交，避免逐字敲键就写 KVStore。
class _DualAgentCard extends ConsumerStatefulWidget {
  const _DualAgentCard();

  @override
  ConsumerState<_DualAgentCard> createState() => _DualAgentCardState();
}

class _DualAgentCardState extends ConsumerState<_DualAgentCard> {
  bool _g1kPresetLoading = false;
  late final TextEditingController _mainModelCtrl;
  late final TextEditingController _mainRoleCtrl;
  late final TextEditingController _subModelCtrl;
  late final TextEditingController _subRoleCtrl;

  /// provider 名 → 该平台可用模型 id 列表（Agent 模型选择的候选来源）。
  final Map<String, List<String>> _models = <String, List<String>>{};

  /// 正在拉取模型列表的 provider（防并发重复请求）。
  String? _loadingModelsFor;

  /// 拉取指定 provider 的可用模型（`GET {baseUrl}/models`）。
  ///
  /// 只取**已配置/已注册**的平台：未注册的 provider 不在
  /// `ModelManager` 里，`getProvider` 返回 null，这里自然跳过。
  Future<void> _ensureModels(String providerName) async {
    final String name = providerName.trim();
    if (name.isEmpty) return;
    if (_models.containsKey(name) || _loadingModelsFor == name) return;
    _loadingModelsFor = name;
    List<String> ids = <String>[];
    try {
      final IModelProvider? p = ref.read(agentProviderResolverProvider)(name);
      if (p != null) {
        final List<ModelInfo> list = await p.getAvailableModels();
        ids = <String>{
          for (final ModelInfo e in list)
            if (e.id.trim().isNotEmpty) e.id.trim(),
        }.toList()..sort();
      }
    } catch (_) {
      // 拉取失败保持空列表：用户仍可自由输入模型 id
      ids = <String>[];
    }
    if (!mounted) return;
    setState(() {
      _models[name] = ids;
      _loadingModelsFor = null;
    });
  }

  /// 「模型列表」按钮：底部弹层列出该平台已注册的模型，点选即填入。
  Future<void> _pickModel(
    BuildContext context,
    String providerName,
    TextEditingController ctrl,
  ) async {
    final l10n = ref.read(l10nProvider);
    final String name = providerName.trim();
    _models.remove(name);
    await _ensureModels(name);
    final List<String> ids = _models[name] ?? const <String>[];
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    '$name · ${l10n.tf('AICfg.AgentModelListTitle', '可用模型（{0}）', <Object>[ids.length])}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (ids.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      l10n.t(
                        'AICfg.AgentModelEmpty',
                        '未取到模型列表（该平台可能未配置或不支持 /models）。'
                            '可直接在上方输入框手填模型 id。',
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: ids.length,
                      itemBuilder: (BuildContext _, int i) {
                        final String id = ids[i];
                        return ListTile(
                          dense: true,
                          title: Text(id, style: const TextStyle(fontSize: 12)),
                          onTap: () {
                            ctrl.text = id;
                            _save();
                            Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    final AgentRoleWorkflowSettings s = ref.read(dualAgentSettingsProvider);
    _mainModelCtrl = TextEditingController(text: s.mainAgentModel);
    _mainRoleCtrl = TextEditingController(text: s.mainAgentRoleDescription);
    _subModelCtrl = TextEditingController(text: s.subAgentModel);
    _subRoleCtrl = TextEditingController(text: s.subAgentRoleDescription);
    // 首次进入就把两个 Agent 所选平台的模型列表拉下来（可搜索下拉的候选源）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureModels(s.mainAgentProvider);
      _ensureModels(s.subAgentProvider);
    });
  }

  @override
  void dispose() {
    _mainModelCtrl.dispose();
    _mainRoleCtrl.dispose();
    _subModelCtrl.dispose();
    _subRoleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final AgentRoleWorkflowSettings s = ref.read(dualAgentSettingsProvider);
    await ref
        .read(dualAgentSettingsProvider.notifier)
        .update(
          s.copyWith(
            mainAgentModel: _mainModelCtrl.text.trim(),
            mainAgentRoleDescription: _mainRoleCtrl.text.trim().isEmpty
                ? AgentRoleWorkflowSettings.defaults.mainAgentRoleDescription
                : _mainRoleCtrl.text.trim(),
            subAgentModel: _subModelCtrl.text.trim(),
            subAgentRoleDescription: _subRoleCtrl.text.trim().isEmpty
                ? AgentRoleWorkflowSettings.defaults.subAgentRoleDescription
                : _subRoleCtrl.text.trim(),
          ),
        );
    await ref.read(g1kBookPresetProvider.notifier).update(const G1kBookPreset());
  }

  Future<void> _applyG1kPreset() async {
    final L10n l10n = ref.read(l10nProvider);
    final RwkvCloudProvider cloud = ref.read(rwkvCloudProviderInstanceProvider);
    if (!cloud.isAvailable ||
        Uri.tryParse(cloud.configuration.baseUrl)?.host !=
            'api-7b.rwkvos.com') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.t(
              'AICfg.G1kPresetSetup',
              '请先在 RWKV 云端页保存 7B 官方端点和 CF 凭据，并测试连接。',
            ),
          ),
        ),
      );
      return;
    }
    setState(() => _g1kPresetLoading = true);
    final Map<String, String> headers = cloud.configuration.customHeaders;
    final RwkvCloudProvider writer = RwkvCloudProvider();
    try {
      final String? mainId = resolveG1kModel(
        kG1kMainModelFamily,
        (await cloud.getAvailableModels()).map((m) => m.id),
      );
      final bool writerReady = await writer.initialize(
        RwkvCloudConfiguration(
          baseUrl: kG1kWriterBaseUrl,
          defaultModel: kG1kWriterModelFamily,
          cfAccessClientId: headers[kHeaderCfAccessClientId] ?? '',
          cfAccessClientSecret: headers[kHeaderCfAccessClientSecret] ?? '',
          timeoutSeconds: cloud.configuration.timeoutSeconds,
        ),
      );
      final String? writerId = writerReady
          ? resolveG1kModel(
              kG1kWriterModelFamily,
              (await writer.getAvailableModels()).map((m) => m.id),
            )
          : null;
      if (!mounted) return;
      if (mainId == null || writerId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.t(
                'AICfg.G1kPresetFailed',
                '无法唯一匹配 G1K 两个模型，请检查 7B/3B 端点模型列表，或手动填写完整 ID。',
              ),
            ),
          ),
        );
        return;
      }
      await ref
          .read(g1kBookPresetProvider.notifier)
          .update(G1kBookPreset(mainModel: mainId, writerModel: writerId));
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.t('AICfg.G1kPresetSaved', '已配置 G1K：7.2B 规划/润色，2.9B 写正文。'),
          ),
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.t(
                'AICfg.G1kPresetFailed',
                '无法唯一匹配 G1K 两个模型，请检查 7B/3B 端点模型列表，或手动填写完整 ID。',
              ),
            ),
          ),
        );
      }
    } finally {
      writer.dispose();
      if (mounted) setState(() => _g1kPresetLoading = false);
    }
  }

  /// 可选项：**ModelManager 已注册（即已在对应平台页配置/测试过）的 provider**
  /// + 两个始终存在的 RWKV 单例。
  ///
  /// 只列「已配置好」的：未配置的 provider 单例 `isAvailable == false`，
  /// `resolveExactProvider` 会返回 null，选了也用不了，列出来只是误导。
  /// 新增平台（如 OpenRouter）后：先到该平台页填 Key 并「保存/测试连接」，
  /// 启动时 `providerAutoRestore` 也会自动注册 → 这里就能选到。
  List<String> _providerOptions(List<IModelProvider> registered) {
    final Set<String> names = <String>{
      for (final IModelProvider p in registered) p.providerName,
      'RWKV',
      'RWKV Cloud',
    };
    final List<String> list = names.toList()..sort();
    return list;
  }

  Widget _endpointField(String binding, {required bool main}) {
    if (AgentEndpointRegistry.platform(binding) != 'RWKV Cloud') {
      return const SizedBox.shrink();
    }
    final L10n l10n = ref.read(l10nProvider);
    final profiles = ref.read(agentEndpointRegistryProvider).profiles;
    final keys = <String>{'RWKV Cloud', ...profiles.keys, binding};
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DropdownButtonFormField<String>(
        key: ValueKey('endpoint-$main-$binding'),
        initialValue: binding,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.t('AICfg.EndpointConfig', '端点配置（独立于上方当前端点）'),
        ),
        items: [
          for (final key in keys)
            DropdownMenuItem(
              value: key,
              child: Text(key == 'RWKV Cloud'
                  ? l10n.t('AICfg.FollowCurrentEndpoint',
                      '兼容旧配置：跟随当前端点（建议选择固定配置）')
                  : profiles[key]?.name ??
                      l10n.tf('AICfg.DeletedProfileFmt', '已删除配置：{0}',
                          <Object>[key]),
                overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (key) async {
          if (key == null) return;
          final s = ref.read(dualAgentSettingsProvider);
          final ctrl = main ? _mainModelCtrl : _subModelCtrl;
          ctrl.clear();
          await ref.read(dualAgentSettingsProvider.notifier).update(s.copyWith(
            mainAgentProvider: main ? key : null,
            subAgentProvider: main ? null : key,
            mainAgentModel: main ? '' : null,
            subAgentModel: main ? null : '',
          ));
          await ref.read(g1kBookPresetProvider.notifier).update(const G1kBookPreset());
          if (mounted) await _ensureModels(key);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final mm = ref.watch(modelManagerProvider);
    final AgentRoleWorkflowSettings s = ref.watch(dualAgentSettingsProvider);
    final G1kBookPreset g1kPreset = ref.watch(g1kBookPresetProvider);
    final List<String> options = _providerOptions(mm.getAllProviders());
    if (!options.contains(AgentEndpointRegistry.platform(s.mainAgentProvider))) {
      options.add(AgentEndpointRegistry.platform(s.mainAgentProvider));
    }
    if (!options.contains(AgentEndpointRegistry.platform(s.subAgentProvider))) {
      options.add(AgentEndpointRegistry.platform(s.subAgentProvider));
    }

    Future<void> patch({
      bool? enable,
      bool? archive,
      String? mainProvider,
      String? subProvider,
    }) async {
      await ref
          .read(dualAgentSettingsProvider.notifier)
          .update(
            s.copyWith(
              enableDualAgentWorkflow: enable,
              enableArchiveWrite: archive,
              mainAgentProvider: mainProvider,
              subAgentProvider: subProvider,
              mainAgentModel: mainProvider != null ? '' : null,
              subAgentModel: subProvider != null ? '' : null,
            ),
          );
      if (mainProvider != null || subProvider != null) {
        if (mainProvider != null) _mainModelCtrl.clear();
        if (subProvider != null) _subModelCtrl.clear();
        await ref.read(g1kBookPresetProvider.notifier).update(const G1kBookPreset());
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.groups_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.t('AICfg.DualAgentTitle', 'MainAgent / SubAgent 双代理配置'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () async {
                  await _save();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.t('Common.Saved', '已保存'))),
                    );
                  }
                },
                child: Text(l10n.t('Common.Save', '保存')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.t(
              'AICfg.DualAgentDesc',
              '建议由稠密模型承担 MainAgent，MoE 或本地 GGUF 模型承担 SubAgent。SubAgent 负责总结需求、整理定稿并归档。',
            ),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          Text(
            l10n.t(
              'AICfg.G1kPresetHint',
              '多智能体写书专用：7.2B 负责大纲与润色，2.9B 负责正文；不修改普通双代理配置。',
            ),
            style: TextStyle(fontSize: 11, color: scheme.primary),
          ),
          if (g1kPreset.enabled)
            SelectableText(
              'Main: ${g1kPreset.mainModel}\nSub: ${g1kPreset.writerModel}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _g1kPresetLoading ? null : _applyG1kPreset,
                  icon: _g1kPresetLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_fix_high_outlined, size: 18),
                  label: Text(
                    l10n.t('AICfg.G1kPreset', '预置 G1K 7.2B 主编 + 2.9B 写手'),
                  ),
                ),
                if (g1kPreset.enabled)
                  TextButton(
                    onPressed: () => ref
                        .read(g1kBookPresetProvider.notifier)
                        .update(const G1kBookPreset()),
                    child: Text(l10n.t('AICfg.G1kDisable', '停用写书预设')),
                  ),
              ],
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: s.enableDualAgentWorkflow,
              onChanged: (bool v) => patch(enable: v),
              title: Text(
                l10n.t(
                  'AICfg.EnableDualAgent',
                  '启用 MainAgent / SubAgent 双代理写作流',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _Field(
            label: l10n.t('AICfg.HintMainAgentProvider', 'MainAgent 提供者'),
            child: DropdownButtonFormField<String>(
              key: ValueKey('main-${s.mainAgentProvider}'),
              initialValue: AgentEndpointRegistry.platform(s.mainAgentProvider),
              isExpanded: true,
              items: <DropdownMenuItem<String>>[
                for (final String n in options)
                  DropdownMenuItem<String>(
                    value: n,
                    child: Text(n, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (String? v) {
                if (v == null) return;
                patch(mainProvider: v);
                _ensureModels(v);
              },
            ),
          ),
          _endpointField(s.mainAgentProvider, main: true),
          const SizedBox(height: 4),
          Text(
            l10n.t(
              'AICfg.HintAgentProviderHelper',
              '仅列出已配置并注册的平台；新增平台请先到其页签填好 Key 并点「保存 / 测试连接」',
            ),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _Field(
            label: l10n.t(
              'AICfg.HintMainAgentModel',
              'MainAgent 模型（可选，留空使用提供者默认模型）',
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _mainModelCtrl,
                    decoration: InputDecoration(
                      hintText: l10n.t(
                        'AICfg.HintAgentModelHint',
                        '留空 = 用该平台默认模型',
                      ),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: l10n.t('AICfg.AgentModelList', '模型列表'),
                  icon: const Icon(Icons.list_alt_outlined),
                  onPressed: () =>
                      _pickModel(context, s.mainAgentProvider, _mainModelCtrl),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: l10n.t('AICfg.HintMainAgentRole', 'MainAgent 职责描述'),
            child: TextField(controller: _mainRoleCtrl, maxLines: 2),
          ),
          const SizedBox(height: 16),
          Divider(color: scheme.outlineVariant, height: 1),
          const SizedBox(height: 16),
          _Field(
            label: l10n.t('AICfg.HintSubAgentProvider', 'SubAgent 提供者'),
            child: DropdownButtonFormField<String>(
              key: ValueKey('sub-${s.subAgentProvider}'),
              initialValue: AgentEndpointRegistry.platform(s.subAgentProvider),
              isExpanded: true,
              items: <DropdownMenuItem<String>>[
                for (final String n in options)
                  DropdownMenuItem<String>(
                    value: n,
                    child: Text(n, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (String? v) {
                if (v == null) return;
                patch(subProvider: v);
                _ensureModels(v);
              },
            ),
          ),
          _endpointField(s.subAgentProvider, main: false),
          const SizedBox(height: 12),
          _Field(
            label: l10n.t(
              'AICfg.HintSubAgentModel',
              'SubAgent 模型（可选，留空使用提供者默认模型）',
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _subModelCtrl,
                    decoration: InputDecoration(
                      hintText: l10n.t(
                        'AICfg.HintAgentModelHint',
                        '留空 = 用该平台默认模型',
                      ),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: l10n.t('AICfg.AgentModelList', '模型列表'),
                  icon: const Icon(Icons.list_alt_outlined),
                  onPressed: () =>
                      _pickModel(context, s.subAgentProvider, _subModelCtrl),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: l10n.t('AICfg.HintSubAgentRole', 'SubAgent 职责描述'),
            child: TextField(controller: _subRoleCtrl, maxLines: 2),
          ),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: s.enableArchiveWrite,
              onChanged: (bool v) => patch(archive: v),
              title: Text(
                l10n.t('AICfg.AllowArchiveWrite', '允许 SubAgent 将纯净定稿写入正式项目档案库'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var idx = 0;
  while (size >= 1024 && idx < units.length - 1) {
    size /= 1024;
    idx += 1;
  }
  return '${size.toStringAsFixed(size >= 100 || idx <= 1 ? 0 : 2)} ${units[idx]}';
}

String _formatEta(int totalSeconds) {
  if (totalSeconds <= 0) return '--:--';
  final m = totalSeconds ~/ 60;
  final s = totalSeconds.remainder(60);
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

Widget _buildProgressBlock(
  BuildContext context, {
  required WidgetRef ref,
  required RwkvDownloadProgress progress,
  required ColorScheme scheme,
  required String completedLabel,
  bool idleHide = true,
  VoidCallback? onCancel,
}) {
  final l10n = ref.watch(l10nProvider);
  if (idleHide &&
      progress.phase == RwkvDownloadPhase.idle &&
      (progress.message ?? '').isEmpty) {
    return const SizedBox.shrink();
  }
  switch (progress.phase) {
    case RwkvDownloadPhase.failed:
      final err =
          progress.error?.toString() ??
          progress.message ??
          l10n.t('AIC.UnknownError', '未知错误');
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.error.withValues(alpha: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.tf('AIC.PhaseFailedLabel', '❌ {phaseLabel}', {
                      'phaseLabel': l10n.t(
                        progress.phase.labelKey,
                        progress.phase.label,
                      ),
                    }),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    err,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    case RwkvDownloadPhase.cancelled:
      return Row(
        children: [
          Icon(Icons.cancel_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l10n.tf('AIC.CancelledWithMessage', '已取消：{msg}', {
                'msg': progress.message ?? '',
              }),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      );
    case RwkvDownloadPhase.done:
      final msg = progress.message ?? completedLabel;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                msg,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    case RwkvDownloadPhase.fetchingMeta:
    case RwkvDownloadPhase.downloading:
    case RwkvDownloadPhase.verifying:
    case RwkvDownloadPhase.extracting:
    case RwkvDownloadPhase.installing:
    case RwkvDownloadPhase.idle:
      final double frac = progress.totalBytes > 0
          ? progress.fractionComplete.clamp(0.0, 1.0)
          : 0.0;
      final received = _formatBytes(progress.receivedBytes);
      final total = progress.totalBytes > 0
          ? _formatBytes(progress.totalBytes)
          : '--';
      final speed = progress.speedMbps > 0
          ? '${progress.speedMbps.toStringAsFixed(2)} Mbps'
          : '-- Mbps';
      final eta = _formatEta(progress.etaSeconds);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: frac > 0 ? frac : null,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      l10n.t(progress.phase.labelKey, progress.phase.label),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$received / $total',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    Text(
                      speed,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'ETA $eta',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if ((progress.message ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    progress.message!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onCancel != null)
            Positioned(
              top: -4,
              right: -4,
              child: Semantics(
                label: l10n.t('Common.Cancel', '取消'),
                button: true,
                child: Tooltip(
                  message: l10n.t('AIC.CancelCurrentTask', '取消当前任务'),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: onCancel,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.highlight_off_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
  }
}

/// 功能 C：章节落库后自动同步世界观 —— 两级开关（规则同步默认开 / AI 抽取默认关）。
/// 生成采样参数（官方推荐预设 + 手动微调）与思维链卡片（全局设置）。
///
/// 采样参数仅对 RWKV 家族 provider 下发（DeepSeek/Zhipu 等严格 API 会 400，
/// 下发前由 `isRwkvFamilyProvider` 门控 —— 见 `rwkv_sampling.dart`）。
/// 所有改动写入 KVStore `(ai_config, runtime_settings)` 并同步全局
/// `aiRuntimeSettings`，**下一次模型调用即生效**（无需重启/重注册）。
class _SamplingThinkingCard extends ConsumerStatefulWidget {
  const _SamplingThinkingCard();

  @override
  ConsumerState<_SamplingThinkingCard> createState() =>
      _SamplingThinkingCardState();
}

class _SamplingThinkingCardState extends ConsumerState<_SamplingThinkingCard> {
  /// 可微调的采样参数（键 = 端点字段名，与 `kRwkvAntiRepeatSampling` 对齐）。
  static const List<String> _paramKeys = <String>[
    'top_k',
    'top_p',
    'alpha_presence',
    'alpha_frequency',
    'alpha_decay',
    'dry_multiplier',
    'dry_base',
    'dry_allowed_length',
    'dry_penalty_last_n',
  ];

  late final Map<String, TextEditingController> _ctrl =
      <String, TextEditingController>{
        for (final String k in _paramKeys) k: TextEditingController(),
      };

  @override
  void initState() {
    super.initState();
    // 显示当前**生效值**（预设默认 + 已存微调的合并结果）
    _fillControllers(aiRuntimeSettings.samplingParams());
  }

  @override
  void dispose() {
    for (final TextEditingController c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _fillControllers(Map<String, Object?> params) {
    for (final String k in _paramKeys) {
      _ctrl[k]!.text = params[k]?.toString() ?? '';
    }
  }

  int? _intOrNull(String key) {
    final String v = _ctrl[key]!.text.trim();
    if (v.isEmpty) return null;
    return int.tryParse(v) ?? double.tryParse(v)?.round();
  }

  double? _doubleOrNull(String key) {
    final String v = _ctrl[key]!.text.trim();
    if (v.isEmpty) return null;
    return double.tryParse(v);
  }

  /// 从文本框收集微调值（空 = 回落当前预设默认）写回全局设置并落盘。
  Future<void> _collectAndPersist() async {
    final AiRuntimeSettings s = AiRuntimeSettings(
      samplingPreset: aiRuntimeSettings.samplingPreset,
      topK: _intOrNull('top_k'),
      topP: _doubleOrNull('top_p'),
      alphaPresence: _doubleOrNull('alpha_presence'),
      alphaFrequency: _doubleOrNull('alpha_frequency'),
      alphaDecay: _doubleOrNull('alpha_decay'),
      dryMultiplier: _doubleOrNull('dry_multiplier'),
      dryBase: _doubleOrNull('dry_base'),
      dryAllowedLength: _intOrNull('dry_allowed_length'),
      dryPenaltyLastN: _intOrNull('dry_penalty_last_n'),
      thinkingEnabled: aiRuntimeSettings.thinkingEnabled,
      thinkingIntensity: aiRuntimeSettings.thinkingIntensity,
      // ⚠ 必须**显式继承**这两项：本卡片只负责采样/思维链，若省略即回落构造
      // 默认值（4000 / 16384），保存一次采样参数就会把用户在「最大令牌数」
      // 滑块上设好的 25K 与已同步的上下文窗口静默抹掉 —— 这正是用户报
      // 「设不了 25K 上下文」的第二个根因。
      maxReferenceLength: aiRuntimeSettings.maxReferenceLength,
      contextWindowTokens: aiRuntimeSettings.contextWindowTokens,
    );
    setState(() => aiRuntimeSettings = s);
    await _persist(s);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ref.read(l10nProvider).t('AIC.Sampling.Saved', '已保存，下一次生成生效'),
          ),
        ),
      );
    }
  }

  Future<void> _persist(AiRuntimeSettings s) async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      await kv.writeJson(
        'ai_config',
        'runtime_settings',
        jsonEncode(s.toJson()),
      );
    } catch (_) {
      // KVStore 写失败不阻塞创作（与 chapter_referral 同策略），下次保存会重试
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final AiRuntimeSettings s = aiRuntimeSettings;

    final Widget presetDropdown = DropdownButtonFormField<RwkvSamplingPresetId>(
      key: ValueKey<String>('samplingPreset|${s.samplingPreset.name}'),
      initialValue: s.samplingPreset,
      decoration: InputDecoration(
        labelText: l10n.t('AIC.Sampling.Preset', '参数预设'),
        border: const OutlineInputBorder(),
      ),
      items: <DropdownMenuItem<RwkvSamplingPresetId>>[
        DropdownMenuItem(
          value: RwkvSamplingPresetId.official,
          child: Text(l10n.t('AIC.Sampling.PresetOfficial', '官方推荐（抗复读）')),
        ),
        DropdownMenuItem(
          value: RwkvSamplingPresetId.strong,
          child: Text(l10n.t('AIC.Sampling.PresetStrong', '强抗复读')),
        ),
        DropdownMenuItem(
          value: RwkvSamplingPresetId.relaxed,
          child: Text(l10n.t('AIC.Sampling.PresetRelaxed', '宽松（保文笔）')),
        ),
        DropdownMenuItem(
          value: RwkvSamplingPresetId.custom,
          child: Text(l10n.t('AIC.Sampling.PresetCustom', '自定义')),
        ),
      ],
      onChanged: (RwkvSamplingPresetId? id) async {
        if (id == null) return;
        // 选预设 = 以该预设基线重置微调值（干净起点）
        final AiRuntimeSettings next = AiRuntimeSettings(
          samplingPreset: id,
          thinkingEnabled: s.thinkingEnabled,
          thinkingIntensity: s.thinkingIntensity,
        );
        setState(() {
          aiRuntimeSettings = next;
          _fillControllers(next.samplingParams());
        });
        await _persist(next);
      },
    );

    final Widget fields = Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        for (final String k in _paramKeys)
          SizedBox(
            width: 250,
            child: TextField(
              controller: _ctrl[k],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                isDense: true,
                labelText: l10n.t(_labelKey(k), _labelFallback(k)),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('AIC.Sampling.Title', '生成采样参数与思维链'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: scheme.primary),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.t(
                'AIC.Sampling.Sub',
                '仅对 RWKV 家族生效：官方推荐值（alpha_* 重复惩罚 + DRY 抗整段复读）'
                    '可一键套用，再按需微调；修改下一次生成即生效',
              ),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            presetDropdown,
            const SizedBox(height: 12),
            fields,
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(l10n.t('AIC.Sampling.Save', '保存微调')),
                onPressed: _collectAndPersist,
              ),
            ),
            const Divider(height: 24),
            Text(
              l10n.t('AIC.Thinking.Title', '思维链'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: scheme.primary),
            ),
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.thinkingEnabled,
                onChanged: (bool v) async {
                  final AiRuntimeSettings next = s.copyWith(thinkingEnabled: v);
                  setState(() => aiRuntimeSettings = next);
                  await _persist(next);
                },
                title: Text(l10n.t('AIC.Thinking.Enable', '启用思维链')),
                subtitle: Text(
                  l10n.t(
                    'AIC.Thinking.EnableSub',
                    '关闭后 Agent 直接产出结果，不再构造/解析思维步骤',
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (s.thinkingEnabled) ...[
              Text(
                l10n.t('AIC.Thinking.Intensity', '思考强度'),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              SegmentedButton<ThinkingIntensity>(
                segments: <ButtonSegment<ThinkingIntensity>>[
                  ButtonSegment<ThinkingIntensity>(
                    value: ThinkingIntensity.low,
                    label: Text(l10n.t('AIC.Thinking.Low', '低')),
                  ),
                  ButtonSegment<ThinkingIntensity>(
                    value: ThinkingIntensity.medium,
                    label: Text(l10n.t('AIC.Thinking.Medium', '中')),
                  ),
                  ButtonSegment<ThinkingIntensity>(
                    value: ThinkingIntensity.high,
                    label: Text(l10n.t('AIC.Thinking.High', '高')),
                  ),
                ],
                selected: <ThinkingIntensity>{s.thinkingIntensity},
                onSelectionChanged: (Set<ThinkingIntensity> sel) async {
                  final AiRuntimeSettings next = s.copyWith(
                    thinkingIntensity: sel.first,
                  );
                  setState(() => aiRuntimeSettings = next);
                  await _persist(next);
                },
              ),
              const SizedBox(height: 4),
              Text(
                l10n.t(
                  'AIC.Thinking.IntensitySub',
                  '低 = 仅正文/大纲/续写/角色等核心长文任务；中 = 复杂任务（默认）；高 = 全部任务',
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _labelKey(String key) => switch (key) {
    'top_k' => 'AIC.Sampling.TopK',
    'top_p' => 'AIC.Sampling.TopP',
    'alpha_presence' => 'AIC.Sampling.AlphaPresence',
    'alpha_frequency' => 'AIC.Sampling.AlphaFrequency',
    'alpha_decay' => 'AIC.Sampling.AlphaDecay',
    'dry_multiplier' => 'AIC.Sampling.DryMultiplier',
    'dry_base' => 'AIC.Sampling.DryBase',
    'dry_allowed_length' => 'AIC.Sampling.DryAllowed',
    'dry_penalty_last_n' => 'AIC.Sampling.DryLastN',
    _ => key,
  };

  String _labelFallback(String key) => switch (key) {
    'top_k' => 'top_k（候选数）',
    'top_p' => 'top_p（核采样）',
    'alpha_presence' => 'alpha_presence（重复惩罚）',
    'alpha_frequency' => 'alpha_frequency（频率惩罚）',
    'alpha_decay' => 'alpha_decay（惩罚衰减）',
    'dry_multiplier' => 'dry_multiplier（DRY 强度）',
    'dry_base' => 'dry_base（DRY 衰减底数）',
    'dry_allowed_length' => 'dry_allowed_length（DRY 容忍长度）',
    'dry_penalty_last_n' => 'dry_penalty_last_n（DRY 窗口）',
    _ => key,
  };
}

class _ChapterSyncCard extends ConsumerStatefulWidget {
  const _ChapterSyncCard();

  @override
  ConsumerState<_ChapterSyncCard> createState() => _ChapterSyncCardState();
}

class _ChapterSyncCardState extends ConsumerState<_ChapterSyncCard> {
  bool _loading = true;
  bool _ruleEnabled = true;
  bool _aiEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final post = ref.read(chapterPostProcessServiceProvider);
    final bool rule = await post.ruleEnabled();
    final bool ai = await post.aiEnabled();
    if (!mounted) return;
    setState(() {
      _ruleEnabled = rule;
      _aiEnabled = ai;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('SYN.GroupTitle', '章节自动同步（世界观联动）'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: scheme.primary),
            ),
            if (_loading) ...[
              const SizedBox(height: 12),
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ] else ...[
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _ruleEnabled,
                  onChanged: (bool v) async {
                    setState(() => _ruleEnabled = v);
                    await ref
                        .read(chapterPostProcessServiceProvider)
                        .setRuleEnabled(v);
                  },
                  title: Text(l10n.t('SYN.ToggleTitle', '章节保存后自动同步世界观')),
                  subtitle: Text(
                    l10n.t(
                      'SYN.ToggleSub',
                      '按名字匹配追加人物履历 / 势力记录 / 剧情进度 / 时间线事件（不消耗模型调用）',
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _aiEnabled,
                  onChanged: (bool v) async {
                    setState(() => _aiEnabled = v);
                    await ref
                        .read(chapterPostProcessServiceProvider)
                        .setAiEnabled(v);
                  },
                  title: Text(l10n.t('SYN.AIToggleTitle', 'AI 状态抽取（实验）')),
                  subtitle: Text(
                    l10n.t(
                      'SYN.AIToggleSub',
                      '保存后由模型从正文抽取人物 / 势力状态变化并更新对应字段（每章额外一次模型调用，失败自动跳过）',
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
