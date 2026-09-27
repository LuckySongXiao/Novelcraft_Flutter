import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../data/storage/key_value_store.dart';
import '../../l10n/l10n.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/openai_compatible_provider.dart';
import '../../ai/providers/ollama_provider.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/providers/rwkv_cloud_provider.dart';
import '../../ai/rwkv/rwkv_engine.dart' show RwkvEngineConfig, RwkvNativeOptions;
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
import '../../ai/providers/zhipu_provider.dart';
import '../../ai/workflow/dual_agent_workflow.dart';

enum _ProviderKind {
  deepseek,
  zhipu,
  ollama,
  rwkv,

  /// 云端 RWKV 官方端点（`api-7b.rwkvos.com`，Cloudflare Access 保护）
  rwkvCloud,
  custom,
}

String _pvdLabel(_ProviderKind kind, bool isEnglish) => switch (kind) {
      _ProviderKind.deepseek => 'DeepSeek',
      _ProviderKind.zhipu => isEnglish ? 'Zhipu AI' : '智谱 AI',
      _ProviderKind.ollama => isEnglish ? 'Ollama (Local)' : 'Ollama (本地)',
      _ProviderKind.rwkv => isEnglish ? 'RWKV (Local)' : 'RWKV (本地)',
      _ProviderKind.rwkvCloud =>
        isEnglish ? 'RWKV Cloud (Official)' : 'RWKV 云端（官方）',
      _ProviderKind.custom =>
        isEnglish ? 'OpenAI Compatible' : 'OpenAI 兼容',
    };

extension _ProviderKindX on _ProviderKind {
  IconData get icon => switch (this) {
        _ProviderKind.deepseek => Icons.auto_awesome,
        _ProviderKind.zhipu => Icons.lightbulb_outline,
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
          _ProviderKind.ollama => 'http://localhost:11434',
          _ProviderKind.rwkv => 'http://localhost:8000',
          _ProviderKind.rwkvCloud => kRwkvCloudDefaultBaseUrl,
          _ProviderKind.custom => 'https://api.openai.com/v1',
        },
        apiKey = '',
        defaultModel = switch (kind) {
          _ProviderKind.deepseek => 'deepseek-chat',
          _ProviderKind.zhipu => 'glm-4-flash',
          _ProviderKind.ollama => 'qwen2.5:7b',
          _ProviderKind.rwkv => 'rwkv7-g1i',
          _ProviderKind.rwkvCloud => kRwkvCloudDefaultModel,
          _ProviderKind.custom => 'gpt-3.5-turbo',
        },
        timeoutSeconds = 120,
        defaultTemperature = 0.7,
        defaultMaxTokens = 4000,
        enableStreaming = true;

  String get registeredName => switch (kind) {
        _ProviderKind.deepseek => 'DeepSeek',
        _ProviderKind.zhipu => 'ZhipuAI',
        _ProviderKind.ollama => 'Ollama',
        _ProviderKind.rwkv => 'RWKV',
        _ProviderKind.rwkvCloud => 'RWKV Cloud',
        _ProviderKind.custom => 'Custom',
      };
}

class AIConfigurationPage extends ConsumerStatefulWidget {
  const AIConfigurationPage({super.key});

  @override
  ConsumerState<AIConfigurationPage> createState() =>
      _AIConfigurationPageState();
}

/// 最大令牌数滑动档位节点：512 → 1M（12 档）。
const List<int> kMaxTokensSteps = <int>[
  512, // 512
  1024, // 1K
  2048, // 2K
  4096, // 4K
  8192, // 8K
  16384, // 16K
  32768, // 32K
  65536, // 64K
  131072, // 128K
  262144, // 256K
  524288, // 512K
  1048576, // 1M
];

/// 档位刻度标签（与 [kMaxTokensSteps] 一一对应）。
const List<String> kMaxTokensStepLabels = <String>[
  '512', '1K', '2K', '4K', '8K', '16K', '32K', '64K', '128K', '256K',
  '512K', '1M',
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
      _refreshFromManager();
      _ensureRwkvScanned();
    });
  }

  static const String _kvScopeAiConfig = 'ai_config';
  static const String _kvKeyRwkvCfg = 'rwkv.configuration';

  /// 云端 RWKV（api-7b.rwkvos.com）的配置：baseUrl + CF Service Token。
  static const String _kvKeyRwkvCloudCfg = 'rwkv.cloud_configuration';
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
        variantJson =
            await kv.readJson(_kvScopeUiPrefs, _kvKeyRwkvServerVariant);
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
                orElse: () => OfficialServerVariant.vulkan);
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
      String modelPath, OfficialServerVariant variant) {
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
          _kvScopeAiConfig, _kvKeyRwkvCfg, jsonEncode(rwkvCfg.toMap()));
      await kv.writeJson(
          _kvScopeUiPrefs, _kvKeyRwkvServerVariant, _serverVariant.name);
      // 云端配置（含 CF Service Token）单独持久化，与本地引擎互不影响
      final _ProviderConfig cloudCfg = _configs[_ProviderKind.rwkvCloud]!;
      await kv.writeJson(
        _kvScopeAiConfig,
        _kvKeyRwkvCloudCfg,
        jsonEncode(RwkvCloudConfiguration(
          baseUrl: cloudCfg.baseUrl,
          apiKey: cloudCfg.apiKey,
          defaultModel: cloudCfg.defaultModel,
          timeoutSeconds: cloudCfg.timeoutSeconds,
          defaultMaxTokens: cloudCfg.defaultMaxTokens,
          defaultTemperature: cloudCfg.defaultTemperature,
          enableStreaming: cloudCfg.enableStreaming,
          cfAccessClientId: cloudCfg.cfAccessClientId,
          cfAccessClientSecret: cloudCfg.cfAccessClientSecret,
        ).toCloudMap()),
      );
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
        port: int.tryParse(Uri.tryParse(cfg.baseUrl)?.port.toString() ?? '') ?? 8000,
      );
      if (!mounted) return;
      final diagnostics = prov.lastLaunchDiagnostics;
      setState(() {
        _lastTest = ok
            ? ConnectionTestResult(
                isSuccess: true,
                responseTime: const Duration(milliseconds: 50),
                serverInfo: <String, dynamic>{
                  'note': l10n.t('AIC.RwkvServerLaunchedNote',
                      '本地 RWKV server 已拉起，等待就绪…'),
                },
              )
            : ConnectionTestResult(
                isSuccess: false,
                responseTime: const Duration(milliseconds: 0),
                errorMessage: diagnostics != null && diagnostics.isNotEmpty
                    ? diagnostics
                    : l10n.t('AIC.RwkvLaunchFailed',
                        '拉起失败：请检查「RWKV Server 可执行文件」路径与模型文件路径'),
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
      final bool stopped =
          await ref.read(rwkvProviderInstanceProvider).stopLocalServer();
      if (!mounted) return;
      setState(() {
        _lastTest = ConnectionTestResult(
          isSuccess: stopped,
          responseTime: Duration.zero,
          serverInfo: <String, dynamic>{
            'note': stopped
                ? l10n.t('AIC.RwkvServerStoppedNote', '本地 RWKV server 已停止')
                : l10n.t('AIC.RwkvServerNotRunningNote',
                    '本地 RWKV server 当前没有在运行（无需停止）'),
          },
          errorMessage: stopped
              ? null
              : l10n.t('AIC.RwkvServerNotRunningNote',
                  '本地 RWKV server 当前没有在运行（无需停止）'),
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
        message: l10n.tf('AIC.PreparingOfficialServer',
            '准备下载官方 llama.cpp {variant} …',
            {'variant': _serverVariant.displayName}),
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
          message: l10n.tf('AIC.OfficialServerInstalled', '官方 server 已安装：{path}',
              {'path': exePath}),
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
          message: l10n.tf('AIC.InstallFailed', '安装失败：{error}', {'error': '$e'}),
        );
        _serverInstallCancelHandle = null;
      });
    }
  }

  Future<void> _showOfficialModelsDialog() async {
    final l10n = ref.read(l10nProvider);
    final mm = ScaffoldMessenger.of(context);
    final prov = ref.read(rwkvProviderInstanceProvider);
    final List<RwkvOfficialModel>? models = await showDialog<List<RwkvOfficialModel>>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return FutureBuilder<List<RwkvOfficialModel>>(
          future: prov.listOfficialModels(
            onProgress: (RwkvDownloadProgress p) {},
          ),
          builder: (BuildContext dialogCtx,
              AsyncSnapshot<List<RwkvOfficialModel>> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return AlertDialog(
                title: Text(l10n.t('AIC.QueryingOfficialModels', '正在查询官方模型列表…')),
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
              title: Text(l10n.t('AIC.SelectOfficialModel', '选择要下载的官方 RWKV 模型')),
              children: <Widget>[
                for (final m in list)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogCtx, <RwkvOfficialModel>[m]),
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
                                Text(m.displayName,
                                    style: Theme.of(ctx).textTheme.titleSmall),
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
                    child: Text(l10n.t('AIC.NoOfficialModels',
                        '未找到可用官方模型，请稍后再试或手动下载 GGUF 到 rwkv_models/ 目录。')),
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
    mm.showSnackBar(SnackBar(
      content: Text(l10n.tf('AIC.StartDownloadModel',
          '开始下载：{name}（{size}）', {
        'name': model.displayName,
        'size': model.sizeHumanReadable,
      })),
    ));
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
        message: l10n.tf('AIC.PreparingDownload', '准备下载：{name} …',
            {'name': model.displayName}),
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
          message: l10n.tf('AIC.DownloadComplete', '下载完成：{path}',
              {'path': filePath}),
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
      mm.showSnackBar(SnackBar(
        content: Text(l10n.tf('AIC.ModelDownloadedSelected',
            '✅ {name} 已下载并选中。', {'name': model.displayName})),
        duration: const Duration(seconds: 2),
      ));
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
      mm.showSnackBar(SnackBar(
        content: Text(l10n.tf('AIC.DownloadCancelledModel',
            '下载已取消：{name}', {'name': model.displayName})),
        duration: const Duration(seconds: 2),
      ));
    } on Exception catch (e, s) {
      if (!mounted) return;
      setState(() {
        _modelDownloadProgress = RwkvDownloadProgress(
          phase: RwkvDownloadPhase.failed,
          error: e,
          stackTrace: s,
          message: l10n.tf('AIC.DownloadFailed', '下载失败：{error}',
              {'error': '$e'}),
        );
        _modelDownloadCancelHandle = null;
      });
      mm.showSnackBar(SnackBar(
        content: Text(l10n.tf('AIC.DownloadFailedSnack', '下载失败：{error}',
            {'error': '$e'})),
        duration: const Duration(seconds: 4),
      ));
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
            nativeOptions: RwkvNativeOptions(
              thinkType: _cfg.rwkvThinkType,
            ),
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
    final ok = await prov.initialize(_buildConfig());
    if (ok) {
      if (mm.getProvider(prov.providerName) == null) {
        mm.registerProvider(prov);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tf('AIC.ConfigSavedRegistered',
              '{label} 配置已保存并注册', {
            'label': _pvdLabel(_cfg.kind, isEnglish),
          }))),
        );
        _refreshFromManager();
        _persistRwkvPrefs();
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(l10n.t('AIC.InitFailedCheckParams',
                '初始化失败，请检查地址与参数后重试')),
            backgroundColor: Colors.red),
      );
    }
  }

  void _setDefault(String name) {
    final mm = ref.read(modelManagerProvider);
    mm.setDefaultProvider(name);
    setState(() => _defaultProvider = name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isEnglish = l10n.isEnglish;
    final mm = ref.watch(modelManagerProvider);
    final registered = mm.getAllProviders();

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('AIC.Title', 'AI 配置'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Expanded(
              // 手机横屏逻辑宽 ~780：内容区只剩 ~500px，左右分栏（220 列表 + 卡片）
              // 会把配置卡挤爆 —— 窄屏改为「提供商列表在上、配置卡在下」整体滚动。
              child: LayoutBuilder(builder: (context, box) {
                final narrow = box.maxWidth < 560;
                final Widget cards = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                          _ConfigCard(
                            cfg: _cfg,
                            onChanged: () => setState(() {}),
                            testing: _testing,
                            onTest: _testConnection,
                            connectingTo: _connectingTo,
                            onSave: _saveAndRegister,
                            lastTest: _lastTest,
                            rwkvModels: _selectedKind == _ProviderKind.rwkv
                                ? _rwkvModels
                                : null,
                            rwkvScanning: _rwkvScanning,
                            rwkvLaunching: _rwkvLaunching,
                            rwkvStopping: _rwkvStopping,
                            rwkvServerRunning: ref
                                .watch(rwkvProviderInstanceProvider)
                                .localServerRunning,
                            onStopRwkvServer:
                                _selectedKind == _ProviderKind.rwkv
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
                            onServerVariantChanged: _selectedKind == _ProviderKind.rwkv
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
                                          h.cancel(l10n.t('Common.UserCancelled', '用户取消'));
                                        }
                                      }
                                    : null,
                            onCancelModelDownload:
                                _selectedKind == _ProviderKind.rwkv
                                    ? () {
                                        final h = _modelDownloadCancelHandle;
                                        if (h != null && !h.isCancelled) {
                                          h.cancel(l10n.t('Common.UserCancelled', '用户取消'));
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
                              onCredentialsChanged:
                                  (String id, String secret) {
                                setState(() {
                                  _cfg.cfAccessClientId = id;
                                  _cfg.cfAccessClientSecret = secret;
                                });
                              },
                              onPersist: _persistRwkvPrefs,
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
                          // ---- 功能 C：章节落库后自动同步世界观 ----
                          const SizedBox(height: 16),
                          const _ChapterSyncCard(),
                        ],
                );

                final Widget list = _ProviderList(
                  width: narrow ? double.infinity : 220,
                  selectedKind: _selectedKind,
                  onTap: (k) => setState(() => _selectedKind = k),
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
                      children: [
                        list,
                        const SizedBox(height: 16),
                        cards,
                      ],
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
              }),
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
      return '$phase  ${mb.toStringAsFixed(1)}/$totalMb.toStringAsFixed(1) MB$speed$eta';
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
      setState(() => _status = l10n.tf(
          'AIC.BuiltIn.EngineReadyFmt',
          '引擎已就位：{0}\n词表已就位：{1}',
          {'0': p.executablePath, '1': p.vocabPath}));
    } on RwkvDownloadCancelledException catch (_) {
      if (mounted) {
        setState(() => _status = l10n.t('AIC.StatusCancelled', '已取消'));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _status = l10n.tf(
            'AIC.InstallFailed', '安装失败：{error}', {'error': '$e'}));
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
          _status = l10n.t('AIC.BuiltIn.NoModel',
              '未找到可用 .pth 权重，请稍后重试或手动下载到 rwkv_models/。');
          _busy = false;
        });
        return;
      }
      // 先探一次显存（探不到就返回空列表 → 不做任何拦截）
      final List<RwkvGpuInfo> gpus = _gpus ?? await rwkvProbeGpus();
      _gpus = gpus;
      if (!mounted) return; // await 之后 context 可能已失效
      final int? vramFree =
          gpus.isEmpty ? null : gpus.first.freeBytes;

      // ⚠ 关键：**按参数量**挑推荐，不是按文件体积 ——
      //   真实清单里 `rwkv7b-g1b-0.1b-...` 有 3.4GB，比 1.5B 还大，
      //   按体积挑会挑到那个降智的架构变体（PITFALLS §38.3）。
      final RwkvOfficialModel? recommended = pickBestFittingModel<RwkvOfficialModel>(
        models,
        sizeOf: (RwkvOfficialModel m) => m.sizeBytes,
        rankOf: (RwkvOfficialModel m) => parseParamRankFromName(m.fileName),
        vramAvailableBytes: vramFree,
      );

      final RwkvOfficialModel? picked =
          await showDialog<RwkvOfficialModel>(
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
                      '${gpus.first.name} · 空闲 '
                      '${(vramFree / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB',
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.t('AIC.BuiltIn.NoGpuProbe',
                          '未探测到显卡显存，以下仅显示权重体积，请自行确认能否加载'),
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
                          recommended != null && recommended.fileName == m.fileName;
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
                              child: Text(m.fileName, maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (isRecommended)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .primaryContainer,
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
                        onTap: fit.shouldBlock ? null : () => Navigator.pop(ctx, m),
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
      setState(() => _status = l10n.tf(
          'AIC.ModelDownloadedPathFmt', '模型已下载：{0}', {'0': path}));
    } on RwkvDownloadCancelledException catch (_) {
      if (mounted) {
        setState(() => _status = l10n.t('AIC.StatusCancelled', '已取消'));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _status = l10n.tf(
            'AIC.DownloadFailed', '下载失败：{error}', {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用已装好的引擎拉起本地 server
  Future<void> _launch() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      final bool ok = await _provider.launchLocalServer(
        serverVariant: _variant,
      );
      final String? diag = _provider.lastLaunchDiagnostics;
      if (!mounted) return;
      setState(() => _status = ok
          ? '✅ 内置引擎已启动（/v1/server/status 可查能力与显存）'
          : '启动失败：\n${diag ?? "无诊断信息"}');
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
                  l10n.t('AIC.BuiltIn.Title',
                      '内置推理引擎 · rwkv_lightning_cuda'),
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
            l10n.t('AIC.BuiltIn.Desc',
                '官方预编译 CUDA 包，下载后校验 SHA-256 并自动解压。'
                '只支持 .pth / .rwkvq 权重，且必须配套外置词表（引擎不内嵌词表）。'),
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
                  items: const <DropdownMenuItem<OfficialServerVariant>>[
                    DropdownMenuItem<OfficialServerVariant>(
                      value: OfficialServerVariant.cuda13,
                      child: Text('CUDA 13.2（新驱动推荐）'),
                    ),
                    DropdownMenuItem<OfficialServerVariant>(
                      value: OfficialServerVariant.cuda12,
                      child: Text('CUDA 12.9（兼容旧驱动）'),
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
                  label: Text(l10n.t('AIC.BuiltIn.InstallBtn',
                      '⚡ 安装内置引擎 + 词表')),
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
                  icon: const Icon(Icons.download_for_offline_outlined,
                      size: 18),
                  label: Text(l10n.t('AIC.BuiltIn.DownloadModelBtn',
                      '📥 下载 .pth 原生权重')),
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
              l10n.t('AIC.BuiltIn.StatefulRouteHint',
                  '走 /state/chat/completions，由服务端按 session_id 维护 state。'
                  '实测有效；若换成不提供 /state/* 的引擎请关闭。'),
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
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(value: 'none', child: Text('none')),
                    DropdownMenuItem<String>(
                        value: 'fast', child: Text('fast（默认）')),
                    DropdownMenuItem<String>(value: 'free', child: Text('free')),
                    DropdownMenuItem<String>(
                        value: 'preferChinese', child: Text('preferChinese')),
                    DropdownMenuItem<String>(value: 'en', child: Text('en')),
                    DropdownMenuItem<String>(
                        value: 'enShort', child: Text('enShort')),
                    DropdownMenuItem<String>(
                        value: 'enLong', child: Text('enLong')),
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
                  l10n.t('AIC.BuiltIn.ThinkHint',
                      '控制助手思考前缀；采样参数（top_k/top_p/alpha_*）与 '
                      'stop_tokens 已按官方默认值固定透传。'),
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                Text(_fmtProgress(_progress!),
                    style: const TextStyle(fontSize: 11)),
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
                child: Text(_progress!.message!,
                    style: const TextStyle(fontSize: 11)),
              ),
          ],
          if (_status != null) ...<Widget>[
            const SizedBox(height: 8),
            SelectableText(_status!,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
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
  late final TextEditingController _idCtrl =
      TextEditingController(text: widget.clientId);
  late final TextEditingController _secretCtrl =
      TextEditingController(text: widget.clientSecret);
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
            ? ref.read(l10nProvider).t('AIC.Cloud.StatusUnavailable',
                '取不到引擎状态：端点未响应或不是 rwkv_lightning_cuda。')
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
                  l10n.t('AIC.Cloud.CfTitle',
                      'Cloudflare Access 凭证（Service Token）'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () async {
                  widget.onCredentialsChanged(
                      _idCtrl.text.trim(), _secretCtrl.text.trim());
                  await widget.onPersist();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(l10n.t('Common.Saved', '已保存'))));
                  }
                },
                child: Text(l10n.t('Common.Save', '保存')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.t('AIC.Cloud.CfHint',
                '头名按字节精确匹配：CF-Access-Client-Id / CF-Access-Client-Secret。'
                '拼错不会报 401，而是静默返回 HTML 登录页。'),
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
                label: Text(l10n.t('AIC.Cloud.FetchStatus',
                    '🩺 取引擎状态（验证是否真的连通）')),
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
            SelectableText(_error!,
                style: TextStyle(fontSize: 11, color: scheme.error)),
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
                child: Text(l10n.t('AIC.ProviderListTitle', '提供商'),
                    style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 4),
              for (final k in _ProviderKind.values)
                _ProviderTile(
                  kind: k,
                  selected: k == selectedKind,
                  onTap: () => onTap(k),
                  isAvailable: availableMap[configs[k]!.registeredName] ?? false,
                  isRegistered: registered
                      .any((p) => p.providerName == configs[k]!.registeredName),
                  isDefault:
                      defaultProvider == configs[k]!.registeredName,
                  onSetDefault: () =>
                      onSetDefault(configs[k]!.registeredName),
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
              Icon(kind.icon,
                  size: 18,
                  color: selected ? scheme.onSecondaryContainer : null),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_pvdLabel(kind, isEnglish),
                        style: TextStyle(
                            fontSize: 13,
                            color: selected
                                ? scheme.onSecondaryContainer
                                : null,
                            fontWeight: FontWeight.w500)),
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
                              : (isRegistered
                                  ? Colors.orange
                                  : scheme.outline),
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
                              color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isDefault)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l10n.t('AIC.DefaultBadge', '默认'),
                    style: TextStyle(
                        fontSize: 9,
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold),
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
                    l10n.tf('AIC.ParamsTitle', '{label} 参数',
                        {'label': _pvdLabel(cfg.kind, isEnglish)}),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: scheme.primary,
                        ),
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
                  label: Text(testing
                      ? l10n.t('AIC.Connecting', '连接中…')
                      : l10n.t('AIC.TestConnection', '测试连接')),
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
                  child: SizedBox(
                    width: 360,
                    child: TextField(
                      controller: TextEditingController(text: cfg.baseUrl)
                        ..selection = TextSelection.fromPosition(
                            TextPosition(offset: cfg.baseUrl.length)),
                      onChanged: (v) {
                        cfg.baseUrl = v;
                        onChanged();
                      },
                      decoration: InputDecoration(
                        hintText: l10n.t('AIC.HintBaseUrl',
                            'https://… 或 http://localhost:…'),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                if (!cfg.kind.isLocal)
                  _Field(
                    label: l10n.t('AIC.FieldApiKey', 'API Key'),
                    child: SizedBox(
                      width: 360,
                      child: TextField(
                        obscureText: true,
                        controller: TextEditingController(text: cfg.apiKey)
                          ..selection = TextSelection.fromPosition(
                              TextPosition(offset: cfg.apiKey.length)),
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
                  child: SizedBox(
                    width: 240,
                    child: TextField(
                      controller: TextEditingController(text: cfg.defaultModel)
                        ..selection = TextSelection.fromPosition(
                            TextPosition(offset: cfg.defaultModel.length)),
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
                _Field(
                  label: l10n.t('AIC.FieldTimeout', '超时 (秒)'),
                  child: SizedBox(
                    width: 120,
                    child: TextField(
                      keyboardType: TextInputType.number,
                      controller: TextEditingController(
                          text: cfg.timeoutSeconds.toString()),
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
                  child: SizedBox(
                    width: 120,
                    child: TextField(
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      controller: TextEditingController(
                          text: cfg.defaultTemperature.toString()),
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
                        value: maxTokensSliderIndex(cfg.defaultMaxTokens)
                            .toDouble(),
                        min: 0,
                        max: (kMaxTokensSteps.length - 1).toDouble(),
                        divisions: kMaxTokensSteps.length - 1,
                        label: maxTokensLabel(cfg.defaultMaxTokens),
                        onChanged: (v) {
                          cfg.defaultMaxTokens =
                              kMaxTokensSteps[v.round()];
                          onChanged();
                        },
                      ),
                      // 档位刻度
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final String lbl
                              in kMaxTokensStepLabels)
                            Text(
                              lbl,
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
                        Icon(Icons.cloud_download_outlined,
                            size: 18, color: scheme.tertiary),
                        const SizedBox(width: 6),
                        Text(l10n.t('AIC.OfficialResourcesTitle', '官方资源一键安装'),
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                )),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Builder(builder: (BuildContext _) {
                            final sv = serverVariant ??
                                OfficialServerVariant.vulkan;
                            return InputDecorator(
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: l10n.t('AIC.FieldHardwareVariant', '硬件加速版本'),
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
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
                                      .map((OfficialServerVariant v) =>
                                          DropdownMenuItem<
                                                  OfficialServerVariant>(
                                              value: v,
                                              child: Text(v.displayName)))
                                      .toList(growable: false),
                                ),
                              ),
                            );
                          }),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 4,
                          child: FilledButton.icon(
                            onPressed: (serverInstallProgress != null &&
                                    !serverInstallProgress!.phase.isTerminal)
                                ? null
                                : onInstallOfficialServer,
                            icon: serverInstallProgress != null &&
                                    !serverInstallProgress!.phase.isTerminal
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.install_desktop_outlined,
                                    size: 18),
                            label: Text(
                              serverInstallProgress != null &&
                                      serverInstallProgress!
                                          .phase.isTerminal &&
                                      serverInstallProgress!.phase ==
                                          RwkvDownloadPhase.done
                                  ? l10n.t('AIC.OfficialServerInstalledBtn',
                                      '✅ 已安装官方 Server')
                                  : l10n.t('AIC.InstallOfficialServerBtn',
                                      '📦 安装官方 llama.cpp Server'),
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
                        completedLabel: l10n.t('AIC.LlamaServerInstalled',
                            '✅ llama-server.exe 已安装'),
                        idleHide: false,
                        onCancel: (serverInstallProgress != null &&
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
                            onPressed: (modelDownloadProgress != null &&
                                    !modelDownloadProgress!.phase.isTerminal)
                                ? null
                                : onShowOfficialModelsDialog,
                            icon: modelDownloadProgress != null &&
                                    !modelDownloadProgress!.phase.isTerminal
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.download_for_offline_outlined,
                                    size: 18),
                            label: Text(
                              modelDownloadProgress != null &&
                                      modelDownloadProgress!.phase.isTerminal &&
                                      modelDownloadProgress!.phase ==
                                          RwkvDownloadPhase.done
                                  ? l10n.t('AIC.LatestModelDownloadedBtn',
                                      '✅ 已下载最新模型')
                                  : l10n.t('AIC.DownloadOfficialModelBtn',
                                      '📥 下载官方原生 RWKV 模型'),
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
                        completedLabel: l10n.t('AIC.OfficialModelDownloaded',
                            '✅ 官方模型已下载'),
                        idleHide: false,
                        onCancel: (modelDownloadProgress != null &&
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
                        Icon(Icons.memory_outlined,
                            size: 18, color: scheme.secondary),
                        const SizedBox(width: 6),
                        Text(l10n.t('AIC.LocalRwkvManagement', '本地 RWKV 管理'),
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  color: scheme.onSecondaryContainer,
                                )),
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
                                      strokeWidth: 2),
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
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.play_arrow, size: 18),
                          label: Text(rwkvLaunching
                              ? l10n.t('AIC.Starting', '启动中…')
                              : l10n.t('AIC.StartLocalRwkvServer',
                                  '启动本地 RWKV Server')),
                        ),
                        const SizedBox(width: 6),
                        // 手动停止：仅在进程确实在跑时可点（避免无意义点击）
                        OutlinedButton.icon(
                          onPressed:
                              (rwkvStopping || !rwkvServerRunning ||
                                      onStopRwkvServer == null)
                                  ? null
                                  : onStopRwkvServer,
                          icon: rwkvStopping
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.stop_circle_outlined, size: 18),
                          label: Text(rwkvStopping
                              ? l10n.t('AIC.Stopping', '停止中…')
                              : l10n.t('AIC.StopLocalRwkvServer',
                                  '停止本地 Server')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _Field(
                          label: l10n.t('AIC.FieldRwkvExecutable',
                              'RWKV Server 可执行文件'),
                          child: SizedBox(
                            width: 440,
                            child: TextField(
                              controller: TextEditingController(
                                  text: cfg.rwkvLocalExecutable ?? '')
                                ..selection = TextSelection.fromPosition(
                                    TextPosition(
                                        offset: (cfg.rwkvLocalExecutable ?? '')
                                            .length)),
                              onChanged: (v) {
                                cfg.rwkvLocalExecutable =
                                    v.isEmpty ? null : v;
                                onChanged();
                              },
                              decoration: InputDecoration(
                                hintText: l10n.t('AIC.HintRwkvExecutable',
                                    r'C:\path\to\llama-server.exe 或 rwkv.cpp\server.exe'),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ),
                        _Field(
                          label: l10n.t('AIC.FieldLocalGgufModel',
                              '本地 GGUF 模型（下拉选择）'),
                          child: SizedBox(
                            width: 320,
                            child: Builder(
                              builder: (context) {
                                final list = rwkvModels ?? const [];
                                final selected = list.isEmpty
                                    ? null
                                    : list.firstWhere(
                                        (m) =>
                                            m.filePath ==
                                            cfg.rwkvLocalModelPath,
                                        orElse: () => list.first);
                                return InputDecorator(
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 2),
                                    suffixIcon: onRefreshRwkvModels == null
                                        ? null
                                        : Padding(
                                            padding:
                                                const EdgeInsets.only(right: 4),
                                            child: rwkvScanning
                                                ? const SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child:
                                                        CircularProgressIndicator(
                                                            strokeWidth: 2),
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
                                            ? l10n.t('AIC.NoGgufFiles',
                                                'rwkv_models/ 无 GGUF 文件')
                                            : l10n.t('AIC.SelectModelHint',
                                                '请选择模型'),
                                        style: TextStyle(
                                            color: scheme.onSurfaceVariant),
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
                                                  Text(m.displayName,
                                                      style: const TextStyle(
                                                          fontSize: 13,
                                                          fontWeight: FontWeight
                                                              .w500)),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                      '${(m.sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB · ${m.fileName}',
                                                      style: TextStyle(
                                                          fontSize: 10,
                                                          color: scheme
                                                              .onSurfaceVariant)),
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
                          l10n.tf('AIC.CurrentModelPath', '当前模型路径: {path}',
                              {'path': cfg.rwkvLocalModelPath ?? ''}),
                          style: TextStyle(
                              fontSize: 10,
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const [FontFeature.tabularFigures()]),
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
                      color: lastTest!.isSuccess
                          ? scheme.primary
                          : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        lastTest!.isSuccess
                            ? l10n.tf('AIC.ConnectSuccess',
                                '连接成功 · 耗时 {ms}ms{versionInfo}', {
                                'ms': '${lastTest!.responseTime.inMilliseconds}',
                                'versionInfo': lastTest!.serverInfo
                                        .containsKey('version')
                                    ? l10n.tf('AIC.ServerVersion',
                                        ' · 服务版本: {v}', {
                                        'v': '${lastTest!.serverInfo['version']}'
                                      })
                                    : '',
                              })
                            : l10n.tf('AIC.ConnectFailed',
                                '连接失败: {msg}', {
                                'msg': '${lastTest!.errorMessage}'
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
              fontWeight: FontWeight.w500),
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
            Text(l10n.t('AIC.StatsTitle', '运行统计'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.primary,
                    )),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _StatChip(label: l10n.t('AIC.StatTotalRequests', '总请求'), value: '${s.totalRequests}'),
                _StatChip(
                    label: l10n.t('AIC.StatSuccess', '成功'),
                    value: '${s.successfulRequests}',
                    color: Colors.green),
                _StatChip(
                    label: l10n.t('AIC.StatFailed', '失败'),
                    value: '${s.failedRequests}',
                    color: Colors.red),
                _StatChip(
                    label: l10n.t('AIC.StatAvgResponse', '平均响应'),
                    value:
                        '${s.averageResponseTime.inMilliseconds}ms'),
                _StatChip(label: l10n.t('AIC.StatTotalTokens', '累计令牌'), value: '${s.totalTokensUsed}'),
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
                  color:
                      available == true ? Colors.green : scheme.outline,
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
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 16,
                  color: c,
                  fontWeight: FontWeight.bold)),
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
  late final TextEditingController _mainModelCtrl;
  late final TextEditingController _mainRoleCtrl;
  late final TextEditingController _subModelCtrl;
  late final TextEditingController _subRoleCtrl;

  @override
  void initState() {
    super.initState();
    final AgentRoleWorkflowSettings s = ref.read(dualAgentSettingsProvider);
    _mainModelCtrl = TextEditingController(text: s.mainAgentModel);
    _mainRoleCtrl = TextEditingController(text: s.mainAgentRoleDescription);
    _subModelCtrl = TextEditingController(text: s.subAgentModel);
    _subRoleCtrl = TextEditingController(text: s.subAgentRoleDescription);
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
    await ref.read(dualAgentSettingsProvider.notifier).update(
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
  }

  /// 可选项：ModelManager 已注册的 provider + 两个始终存在的 RWKV 单例。
  List<String> _providerOptions(List<IModelProvider> registered) {
    final Set<String> names = <String>{
      for (final IModelProvider p in registered) p.providerName,
      'RWKV',
      'RWKV Cloud',
    };
    final List<String> list = names.toList()..sort();
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final mm = ref.watch(modelManagerProvider);
    final AgentRoleWorkflowSettings s = ref.watch(dualAgentSettingsProvider);
    final List<String> options = _providerOptions(mm.getAllProviders());
    if (!options.contains(s.mainAgentProvider)) {
      options.add(s.mainAgentProvider);
    }
    if (!options.contains(s.subAgentProvider)) {
      options.add(s.subAgentProvider);
    }

    Future<void> patch({
      bool? enable,
      bool? archive,
      String? mainProvider,
      String? subProvider,
    }) async {
      await ref.read(dualAgentSettingsProvider.notifier).update(
            s.copyWith(
              enableDualAgentWorkflow: enable,
              enableArchiveWrite: archive,
              mainAgentProvider: mainProvider,
              subAgentProvider: subProvider,
            ),
          );
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
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(l10n.t('Common.Saved', '已保存'))));
                  }
                },
                child: Text(l10n.t('Common.Save', '保存')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.t('AICfg.DualAgentDesc',
                '建议由稠密模型承担 MainAgent，MoE 或本地 GGUF 模型承担 SubAgent。SubAgent 负责总结需求、整理定稿并归档。'),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: s.enableDualAgentWorkflow,
              onChanged: (bool v) => patch(enable: v),
              title: Text(l10n.t('AICfg.EnableDualAgent',
                  '启用 MainAgent / SubAgent 双代理写作流')),
            ),
          ),
          const SizedBox(height: 8),
          _Field(
            label: l10n.t('AICfg.HintMainAgentProvider', 'MainAgent 提供者'),
            child: DropdownButtonFormField<String>(
              initialValue: options.contains(s.mainAgentProvider)
                  ? s.mainAgentProvider
                  : options.first,
              items: <DropdownMenuItem<String>>[
                for (final String n in options)
                  DropdownMenuItem<String>(value: n, child: Text(n)),
              ],
              onChanged: (String? v) {
                if (v != null) patch(mainProvider: v);
              },
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: l10n.t('AICfg.HintMainAgentModel',
                'MainAgent 模型（可选，留空使用提供者默认模型）'),
            child: TextField(controller: _mainModelCtrl),
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
              initialValue: options.contains(s.subAgentProvider)
                  ? s.subAgentProvider
                  : options.first,
              items: <DropdownMenuItem<String>>[
                for (final String n in options)
                  DropdownMenuItem<String>(value: n, child: Text(n)),
              ],
              onChanged: (String? v) {
                if (v != null) patch(subProvider: v);
              },
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: l10n.t('AICfg.HintSubAgentModel',
                'SubAgent 模型（可选，留空使用提供者默认模型）'),
            child: TextField(controller: _subModelCtrl),
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
              title: Text(l10n.t('AICfg.AllowArchiveWrite',
                  '允许 SubAgent 将纯净定稿写入正式项目档案库')),
            ),
          )
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
  if (idleHide && progress.phase == RwkvDownloadPhase.idle &&
      (progress.message ?? '').isEmpty) {
    return const SizedBox.shrink();
  }
  switch (progress.phase) {
    case RwkvDownloadPhase.failed:
      final err =
          progress.error?.toString() ?? progress.message ?? l10n.t('AIC.UnknownError', '未知错误');
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
                    l10n.tf('AIC.PhaseFailedLabel', '❌ {phaseLabel}',
                        {
                          'phaseLabel': l10n.t(
                              progress.phase.labelKey, progress.phase.label)
                        }),
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onErrorContainer),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    err,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onErrorContainer),
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
              child: Text(l10n.tf('AIC.CancelledWithMessage', '已取消：{msg}',
                  {'msg': progress.message ?? ''}),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()]))),
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
            Icon(Icons.check_circle_outline,
                size: 16, color: scheme.primary),
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
                    fontFeatures: const [FontFeature.tabularFigures()]),
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
      final total = progress.totalBytes > 0 ? _formatBytes(progress.totalBytes) : '--';
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
                    Text(l10n.t(progress.phase.labelKey, progress.phase.label),
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary)),
                    const SizedBox(width: 10),
                    Text('$received / $total',
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    const Spacer(),
                    Text(speed,
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    const SizedBox(width: 10),
                    Text('ETA $eta',
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ],
                ),
                if ((progress.message ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(progress.message!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ])),
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
                      child: Icon(Icons.highlight_off_outlined,
                          size: 18, color: scheme.onSurfaceVariant),
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
            Text(l10n.t('SYN.GroupTitle', '章节自动同步（世界观联动）'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.primary,
                    )),
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
                    l10n.t('SYN.ToggleSub',
                        '按名字匹配追加人物履历 / 势力记录 / 剧情进度 / 时间线事件（不消耗模型调用）'),
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
                    l10n.t('SYN.AIToggleSub',
                        '保存后由模型从正文抽取人物 / 势力状态变化并更新对应字段（每章额外一次模型调用，失败自动跳过）'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              )
            ],
          ],
        ),
      ),
    );
  }
}
