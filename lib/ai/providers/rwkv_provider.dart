// RWKV 本地推理提供者（State 增强版）。
//
// 对应 C# 源文件 `Services/RWKV/RwkvLightningService.cs` 及 `ModelManager` 中将
// RWKV 注册为 `OpenAICompatibleProvider`（BaseUrl=`<base>/openai/v1`）的逻辑。
//
// 关键增强（相对于阶段二的空壳 extends）：
// 1. **RwkvEngine 内嵌**：不再 extends `OpenAICompatibleProvider`；内部组合
//    一个 [RwkvEngine] 负责真正的 State 管理、会话隔离、并发限流、
//    本地 server 进程桥接、GGUF 模型自动扫描。
// 2. **配置签名保持 3 参数**：`{baseUrl, defaultModel, defaultMaxTokens}`
//    与阶段三修复的 ai_configuration_page.dart#L202-L206 精确对齐；
//    绝不随意加 named 参数以免 analyze 爆。
// 3. **会话级 API**：对 Agent/Workflow 层暴露 `openSession`、
//    `chatInSession`、`closeSession`，让 NovelCraft 的 8 Agent、
//    4 大工作流能**跨请求复用 RWKV state**，把「世界观 + 人设 + 大纲」
//    预编码一次、后续增量，不必每步都把 3000 字 prompt 重新烧 token。
// 4. **不直接 import 'dart:io'**：进程启动、模型扫描的 Native 逻辑通过
//    [InferenceProcessLauncher] / [RwkvModelScanner] 条件导出桥接，
//    Web 端可编译（走远程 HTTP server 模式时 Web 端也能用 State 复用）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../inference/inference_launcher.dart';
import '../models/chat.dart';
import '../models/provider.dart';
import '../utils/semaphore.dart';
import '../rwkv/rwkv_engine.dart';
import '../rwkv/rwkv_models.dart';
import '../rwkv/rwkv_official_resources.dart';

/// RWKV 配置。
///
/// 阶段三签名（ai_configuration_page#L202-206）：**仅 3 个 named 参数**
/// `{baseUrl, defaultModel, defaultMaxTokens}`；其它高级引擎参数
/// （并发数 / state 缓存上限 / TTL）通过 [engineConfig] 覆盖，保持和 UI
/// 层的契约严格稳定。
class RwkvConfiguration implements IModelConfiguration {
  /// server 的 HTTP 基础地址（默认本地 8000）。
  final String baseUrl;

  /// 默认模型 ID（文件名或 server 侧注册的模型名）。
  final String defaultModel;

  /// 默认最大生成 token 数。
  final int defaultMaxTokens;

  /// 引擎级覆盖配置（高级用）。
  final RwkvEngineConfig? engineConfig;

  /// 本地 server 可执行文件路径（Native 下自动拉起时用，可空）。
  final String? localExecutable;

  /// 本地模型文件绝对路径（可空；若空则扫描 `rwkv_models/` 找最大的）。
  final String? localModelPath;

  /// 本地 server 的引擎变体（可空 = 默认 llama.cpp 路线）。
  ///
  /// 选 `cuda12` / `cuda13` 表示走**内置引擎 rwkv_lightning_cuda**：
  /// 此时 `localModelPath` 必须是 `.pth` / `.rwkvq`（不能是 GGUF），
  /// 且必须额外提供 [localVocabPath]（PITFALLS §27.1）。
  final OfficialServerVariant? localServerVariant;

  /// 内置引擎**强制外置**的词表路径（`rwkv_vocab_v20230424.txt`）。
  /// llama.cpp 路线不需要；`rwkv_lightning_cuda` 缺它必秒退（PITFALLS §27.1）。
  final String? localVocabPath;

  @override
  String get providerName => 'RWKV';

  RwkvConfiguration({
    this.baseUrl = 'http://localhost:8000',
    this.defaultModel = 'rwkv7-g1j',
    this.defaultMaxTokens = 4000,
    this.engineConfig,
    this.localExecutable,
    this.localModelPath,
    this.localServerVariant,
    this.localVocabPath,
  });

  @override
  bool isValid() => getValidationErrors().isEmpty;

  @override
  List<String> getValidationErrors() {
    final errors = <String>[];
    if (baseUrl.trim().isEmpty) errors.add('RWKV 基础地址不能为空');
    if (defaultMaxTokens <= 0) errors.add('RWKV defaultMaxTokens 必须 > 0');
    return errors;
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'baseUrl': baseUrl,
        'defaultModel': defaultModel,
        'defaultMaxTokens': defaultMaxTokens,
        'engineConfig': engineConfig?.toMap(),
        'localExecutable': localExecutable,
        'localModelPath': localModelPath,
        'localServerVariant': localServerVariant?.name,
        'localVocabPath': localVocabPath,
      };

  factory RwkvConfiguration.fromJson(Map<String, Object?> map) =>
      RwkvConfiguration(
        baseUrl: (map['baseUrl'] as String?) ?? 'http://localhost:8000',
        defaultModel: (map['defaultModel'] as String?) ?? 'rwkv7-g1j',
        defaultMaxTokens:
            (map['defaultMaxTokens'] as num?)?.toInt() ?? 4000,
        engineConfig: (() {
          final Object? ec = map['engineConfig'];
          if (ec is Map<String, Object?>) return RwkvEngineConfig.fromJson(ec);
          return null;
        })(),
        localExecutable: map['localExecutable'] as String?,
        localModelPath: map['localModelPath'] as String?,
        localServerVariant: (() {
          final Object? v = map['localServerVariant'];
          if (v is! String || v.isEmpty) return null;
          for (final OfficialServerVariant e in OfficialServerVariant.values) {
            if (e.name == v) return e;
          }
          return null;
        })(),
        localVocabPath: map['localVocabPath'] as String?,
      );
}

/// 内置引擎（rwkv_lightning_cuda）一键装齐的结果。
class BuiltInEngineProvision {
  /// 引擎可执行文件绝对路径（写入 `localExecutable`）
  final String executablePath;

  /// 外置词表绝对路径（写入 `localVocabPath`）
  final String vocabPath;

  /// 本次一并下载的模型绝对路径（未下载模型时为 null）
  final String? modelPath;

  /// 使用的引擎变体
  final OfficialServerVariant variant;

  const BuiltInEngineProvision({
    required this.executablePath,
    required this.vocabPath,
    required this.variant,
    this.modelPath,
  });

  /// 是否可以直接写入 [RwkvConfiguration] 并拉起。
  bool get isReady => executablePath.isNotEmpty && vocabPath.isNotEmpty;
}

/// RWKV 本地推理提供者（State 增强版）。
///
/// 实现 [IModelProvider] 以便注册到 [ModelManager]；同时暴露一组
/// 扩展 API 供 [BaseAgent] / [WorkflowEngine] 直接使用会话化推理（
/// 这些扩展 API 在类型上不破坏 IModelProvider 契约）。
class RwkvProvider implements IModelProvider {
  final String registeredProviderName;
  final Logger _logger;
  final http.Client _httpClient;
  final Semaphore _globalSemaphore;

  late RwkvEngine _engine;
  late final RwkvOfficialResourcesBridge _officialResources;
  RwkvConfiguration _configuration = RwkvConfiguration();

  var _disposed = false;
  var _isAvailable = false;
  ProviderStatistics _statistics = const ProviderStatistics();

  final StreamController<ModelConfigurationChangedEventArgs>
      _configChangedController =
      StreamController<ModelConfigurationChangedEventArgs>.broadcast();
  final StreamController<ConnectionStatusChangedEventArgs>
      _connectionChangedController =
      StreamController<ConnectionStatusChangedEventArgs>.broadcast();

  /// 构造 RWKV 提供者。
  RwkvProvider({
    this.registeredProviderName = 'RWKV',
    http.Client? client,
    Logger? logger,
    RwkvEngine? engine,
    RwkvOfficialResourcesBridge? officialResources,
    int globalConcurrency = 4,
  })  : _httpClient = client ?? http.Client(),
        _logger = logger ?? Logger('RwkvProvider.$registeredProviderName'),
        _globalSemaphore = Semaphore(globalConcurrency) {
    _engine = engine ??
        RwkvEngine(
          config: const RwkvEngineConfig(),
          client: _httpClient,
          logger: _logger,
          processLauncher: InferenceProcessLauncher(),
          modelScanner: RwkvModelScanner(),
        );
    _officialResources =
        officialResources ?? createRwkvOfficialResourcesBridge();
  }

  // ---------- 扩展：会话 / State API（给 Agent / Workflow 直接用） ----------

  RwkvEngine get engine => _engine;

  /// 当前配置的模型 ID（会话存档的兼容性校验用）。
  ///
  /// ⚠ RWKV 的 state 与模型**强绑定**：换模型后重放旧转录本，
  /// 得到的是另一个模型的"记忆"，语义完全不同 —— 所以存档必须带上它，
  /// 恢复时不匹配就拒绝。
  String get modelId => _configuration.defaultModel;

  /// 开启一个新会话；返回 sessionId。
  String openSession({String label = ''}) =>
      _engine.sessionManager.create(label: label).sessionId;

  /// 关闭会话并回收其 state。
  bool closeSession(String sessionId) => _engine.closeSession(sessionId);

  /// 在指定会话内做非流式推理；state 自动派生。
  Future<ChatResponse> chatInSession(
    ChatRequest request, {
    required String sessionId,
    String sessionLabel = '',
  }) async {
    final r = await _engine.chatWithSession(
      request,
      sessionId: sessionId,
      sessionLabel: sessionLabel,
    );
    return r.chat;
  }

  /// 在指定会话内做流式推理；state 自动派生。
  Future<ChatResponse> chatStreamInSession(
    ChatRequest request,
    void Function(ChatChunk) onChunk, {
    required String sessionId,
    String sessionLabel = '',
  }) async {
    final r = await _engine.chatStreamWithSession(
      request,
      onChunk,
      sessionId: sessionId,
      sessionLabel: sessionLabel,
    );
    return r.chat;
  }

  /// 获取某个会话当前 State ID（用于外部存档 / 调试）。
  String? currentStateId(String sessionId) =>
      _engine.sessionManager.get(sessionId)?.currentStateId;

  /// **手动停止**本地 RWKV server 进程。
  ///
  /// 与 [launchLocalServer] 对称：停止后可以再次拉起。
  /// 返回是否真的停掉了一个在跑的进程。
  Future<bool> stopLocalServer() => _engine.stopLocalServer();

  /// 原始 prompt 补全 —— 对应 C# `IRwkvLightningService.CompleteAsync`。
  ///
  /// 与 [chatInSession] 的区别：本方法**不套 chat 模板**，把 [prompt] 原样
  /// 作为 `contents` 发给服务端续写。调用方（如前置条件生成的修炼体系）
  /// 传入的 prompt 已自带 `User: … \n\nAssistant:  thinking</think` 结构。
  ///
  /// 不可用或失败时返回 null —— 调用方据此回退代码内置模板，不抛异常。
  Future<String?> completeRawPrompt(
    String prompt, {
    int maxTokens = 2048,
    double temperature = 0.9,
    double topP = 0.85,
    int topK = 0,
  }) async {
    if (!isAvailable) return null;
    try {
      return await _engine.rawCompletion(
        prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        topK: topK,
      );
    } on Object {
      return null;
    }
  }

  /// 扫描本地 `rwkv_models/` 下的 GGUF 模型列表（UI 可选下拉）。
  Future<List<RwkvLocalModel>> listLocalModels() => _engine.scanLocalModels();

  /// 引擎级并发上限（P4-26 健康面板用）。
  ///
  /// ⚠ 这只是**客户端侧的保守限流**，真实并发由服务端 FIFO 队列决定
  /// （读 `/v1/server/status` 的 `available_bsz`，PITFALLS §31.3）。
  int get concurrencyLimit => _globalSemaphore.max;

  /// 当前还可并行的槽位（> 0 说明没排队）。
  int get concurrencyAvailable => _globalSemaphore.available;

  /// 最近一次启动本地 server 的诊断信息（失败时返回详情，成功返回 null）。
  String? get lastLaunchDiagnostics => _engine.lastLaunchDiagnostics;

  /// 本地 server 当前是否在运行（探测成功并保持 alive 后为 true）。
  bool get localServerRunning => _engine.localServerRunning;

  /// 查询 llama.cpp 官方最新 Windows 预编译包信息（返回 tag、大小、下载 URL）。
  Future<RwkvServerBuildInfo> fetchOfficialServerBuild({
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      _officialResources.fetchLatestServerBuild(
        variant: variant,
        onProgress: onProgress,
      );

  /// 安装官方 llama-server.exe 到 `rwkv_models/_tools/` 下；
  /// 返回安装好的可执行文件绝对路径，方便写入 RwkvConfiguration.localExecutable。
  Future<String> installOfficialLlamaServer({
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    RwkvServerBuildInfo? buildInfo,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      _officialResources.installLlamaServer(
        variant: variant,
        buildInfo: buildInfo,
        installDir: installDir,
        onProgress: onProgress,
        onHandleReady: onHandleReady,
      );

  /// 获取 RWKV 官方 HuggingFace 仓库内所有可用 GGUF 模型（带量化级别、体积、URL）。
  Future<List<RwkvOfficialModel>> listOfficialModels({
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      _officialResources.listOfficialRwkvModels(
        onProgress: onProgress,
      );

  /// 下载一个官方原生 RWKV GGUF 模型到 `rwkv_models/` 下；
  /// 支持断点续传；下载完返回文件绝对路径。
  Future<String> downloadOfficialModel(
    RwkvOfficialModel model, {
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      _officialResources.downloadOfficialModel(
        model,
        targetDir: targetDir,
        onProgress: onProgress,
        onHandleReady: onHandleReady,
      );

  // ---------------------------------------------------------------------------
  // 内置推理引擎：rwkv_lightning_cuda（albatross）
  //
  // 与上面的 llama.cpp 路线完全独立：只吃 .pth / .rwkvq + 强制外置词表。
  // 官方 release 带 .sha256，安装时强校验（PITFALLS §30）。
  // ---------------------------------------------------------------------------

  /// 查询内置引擎官方最新预编译包（Windows/Linux × CUDA 12.9 / 13.2）。
  Future<RwkvLightningRelease> fetchBuiltInEngineRelease({
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      _officialResources.fetchLatestLightningRelease(
        variant: variant,
        onProgress: onProgress,
      );

  /// 下载并安装内置引擎（下载 → SHA-256 校验 → 解压）；返回 exe 绝对路径。
  Future<String> installBuiltInEngine({
    RwkvLightningRelease? release,
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      _officialResources.installLightningServer(
        release: release,
        variant: variant,
        installDir: installDir,
        onProgress: onProgress,
        onHandleReady: onHandleReady,
      );

  /// 确保引擎**强制外置**的词表就位；返回其绝对路径。
  Future<String> ensureBuiltInEngineVocab({
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      _officialResources.ensureLightningVocab(
        targetDir: targetDir,
        onProgress: onProgress,
        onHandleReady: onHandleReady,
      );

  /// 官方 `.pth` 原生权重清单（引擎只吃 `.pth` / `.rwkvq`，**不吃 GGUF**）。
  Future<List<RwkvOfficialModel>> listBuiltInEngineModels({
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      _officialResources.listLightningPthModels(onProgress: onProgress);

  /// 一键装齐「引擎 + 词表（+ 可选模型）」。
  ///
  /// 返回结果可直接写入 [updateConfiguration] 的 `localExecutable` /
  /// `localVocabPath` / `localModelPath` 与 `localServerVariant`，随后调用
  /// [launchLocalServer] 即可拉起。
  Future<BuiltInEngineProvision> provisionBuiltInEngine({
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    RwkvLightningRelease? release,
    RwkvOfficialModel? model,
    bool downloadModel = false,
    String? installDir,
    String? modelsDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) async {
    onProgress?.call(const RwkvDownloadProgress(
      phase: RwkvDownloadPhase.installing,
      message: '开始安装内置推理引擎…',
    ));
    final String exe = await installBuiltInEngine(
      release: release,
      variant: variant,
      installDir: installDir,
      onProgress: onProgress,
      onHandleReady: onHandleReady,
    );
    final String vocab = await ensureBuiltInEngineVocab(
      onProgress: onProgress,
      onHandleReady: onHandleReady,
    );
    String? modelPath;
    if (downloadModel && model != null) {
      modelPath = await downloadOfficialModel(
        model,
        targetDir: modelsDir,
        onProgress: onProgress,
        onHandleReady: onHandleReady,
      );
    }
    onProgress?.call(RwkvDownloadProgress(
      phase: RwkvDownloadPhase.done,
      message: '内置引擎已就绪：$exe'
          '${modelPath == null ? '' : '，模型：$modelPath'}',
    ));
    return BuiltInEngineProvision(
      executablePath: exe,
      vocabPath: vocab,
      variant: variant,
      modelPath: modelPath,
    );
  }

  /// 尝试自动拉起本地 server（需要配置了 localExecutable 或扫描到模型）。
  ///
  /// [serverVariant] / [vocabPath] 用于内置引擎 `rwkv_lightning_cuda`：
  /// 传 `cuda12` / `cuda13` 时走它的 CLI（`--model-path` / `--vocab-path`），
  /// 并在启动前做「GGUF 混入」「词表缺失」两项硬拦（PITFALLS §27.1）。
  Future<bool> launchLocalServer({
    String? overrideExecutable,
    String? overrideModelPath,
    String? overrideVocabPath,
    OfficialServerVariant? serverVariant,
    int port = 8000,
    List<String> extraArgs = const [],
  }) async {
    final exec = overrideExecutable ?? _configuration.localExecutable;
    if (exec == null || exec.isEmpty) return false;
    final variant = serverVariant ?? _configuration.localServerVariant;
    final bool isBuiltInEngine =
        variant == OfficialServerVariant.cuda12 ||
            variant == OfficialServerVariant.cuda13;
    String? model = overrideModelPath ?? _configuration.localModelPath;
    if (model == null || model.isEmpty) {
      // 内置引擎走 .pth/.rwkvq；llama.cpp 走 .gguf —— 两者扫描口径不同
      final models = await listLocalModels();
      final matching = models.where((RwkvLocalModel m) =>
          isBuiltInEngine
              ? !m.filePath.toLowerCase().endsWith('.gguf')
              : m.filePath.toLowerCase().endsWith('.gguf'));
      final pick = matching.isNotEmpty ? matching : models;
      if (pick.isNotEmpty) model = pick.first.filePath;
    }
    if (model == null) return false;
    return _engine.ensureLocalServer(
      executable: exec,
      modelFilePath: model,
      port: port,
      extraArgs: extraArgs,
      serverVariant: variant,
      vocabPath: overrideVocabPath ?? _configuration.localVocabPath,
    );
  }

  // ---------- IModelProvider 契约实现 ----------

  @override
  String get providerName => registeredProviderName;

  @override
  ModelProviderType get providerType => ModelProviderType.local;

  @override
  bool get isAvailable => _isAvailable && !_disposed;

  @override
  Stream<ModelConfigurationChangedEventArgs> get configurationChanged =>
      _configChangedController.stream;

  @override
  Stream<ConnectionStatusChangedEventArgs> get connectionStatusChanged =>
      _connectionChangedController.stream;

  @override
  Future<bool> initialize(IModelConfiguration configuration) async {
    if (_disposed) return false;
    if (configuration is! RwkvConfiguration) {
      _logger.severe('配置类型不匹配，期望 RwkvConfiguration');
      return false;
    }
    try {
      final old = _configuration;
      _configuration = configuration;

      // ⚠ 引擎配置必须**跟随 baseUrl 重建**。
      //
      // 早期实现只在 `configuration.engineConfig != null` 时重建引擎，而 UI
      // 从来不传 engineConfig ⇒ 引擎永远拿默认 `http://localhost:8000`，
      // 用户在界面上填的远端地址完全没生效（PITFALLS §31.7）。
      final RwkvEngineConfig desired =
          (configuration.engineConfig ?? const RwkvEngineConfig())
              .copyWith(baseUrl: configuration.baseUrl);
      final bool needRebuild = jsonEncode(desired.toMap()) !=
          jsonEncode(_engine.config.toMap());
      if (needRebuild) {
        _logger.info('RWKV 引擎配置变更，重建引擎: '
            'baseUrl=${desired.baseUrl} '
            'stateful=${desired.useStatefulRoute}');
        _engine.dispose();
        _reassignEngine(RwkvEngine(
          config: desired,
          client: _httpClient,
          logger: _logger,
          processLauncher: InferenceProcessLauncher(),
          modelScanner: RwkvModelScanner(),
        ));
      }
      _configChangedController
          .add(ModelConfigurationChangedEventArgs(_configuration, old));
      final test = await testConnection();
      _setAvailable(test.isSuccess);
      _logger.info('RWKV 提供者初始化: baseUrl=${_configuration.baseUrl}, '
          '可用: $_isAvailable');
      return _isAvailable;
    } catch (e, st) {
      _logger.severe('RWKV 提供者初始化失败', e, st);
      _setAvailable(false);
      return false;
    }
  }

  @override
  Future<ConnectionTestResult> testConnection() async {
    final startTime = DateTime.now();
    final base = _configuration.baseUrl.trim().replaceAll(RegExp(r'/$'), '');
    try {
      // 先探 /health，再探 /v1/models，兼容 llama.cpp / rwkv.cpp server。
      String resolvedBase = base;
      for (final suffix in const ['', '/openai/v1', '/v1']) {
        final probe = '$base$suffix/models';
        try {
          final resp = await _httpClient
              .get(Uri.parse(probe))
              .timeout(const Duration(seconds: 5));
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            resolvedBase = '$base$suffix';
            break;
          }
        } catch (_) {}
      }
      final resp = await _httpClient
          .get(Uri.parse('$resolvedBase/models'))
          .timeout(const Duration(seconds: 5));
      final elapsed = DateTime.now().difference(startTime);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        Map<String, dynamic> info = const {};
        try {
          info = jsonDecode(resp.body) as Map<String, dynamic>;
        } catch (_) {}
        _setAvailable(true);
        return ConnectionTestResult(
          isSuccess: true,
          responseTime: elapsed,
          serverInfo: info,
        );
      }
      _setAvailable(false, 'HTTP ${resp.statusCode}');
      return ConnectionTestResult(
        isSuccess: false,
        responseTime: elapsed,
        errorMessage: 'HTTP ${resp.statusCode}: ${resp.body}',
      );
    } catch (e) {
      _setAvailable(false, e.toString());
      return ConnectionTestResult(
        isSuccess: false,
        responseTime: DateTime.now().difference(startTime),
        errorMessage: e.toString(),
      );
    }
  }

  @override
  Future<List<ModelInfo>> getAvailableModels() async {
    final base = _configuration.baseUrl.trim().replaceAll(RegExp(r'/$'), '');
    try {
      final remote = <ModelInfo>[];
      for (final suffix in const ['/v1/models', '/openai/v1/models', '/models']) {
        try {
          final resp = await _httpClient
              .get(Uri.parse('$base$suffix'))
              .timeout(const Duration(seconds: 5));
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
            final list = parsed['data'] as List<dynamic>? ?? const [];
            for (final item in list) {
              if (item is Map<String, dynamic>) {
                remote.add(ModelInfo(
                  id: item['id'] as String? ?? '',
                  name: item['id'] as String? ?? '',
                ));
              }
            }
            if (remote.isNotEmpty) break;
          }
        } catch (_) {}
      }
      final local = (await listLocalModels()).map((m) => m.toModelInfo()).toList();
      return [...remote, ...local];
    } catch (e, st) {
      _logger.warning('获取 RWKV 可用模型失败', e, st);
      return const [];
    }
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    final startTime = DateTime.now();
    await _globalSemaphore.acquire();
    try {
      final r = await _engine.chatOnce(request);
      _updateStats(r, DateTime.now().difference(startTime));
      return r;
    } finally {
      _globalSemaphore.release();
    }
  }

  @override
  Future<ChatResponse> chatStream(
    ChatRequest request,
    void Function(ChatChunk) onChunkReceived,
  ) async {
    final startTime = DateTime.now();
    await _globalSemaphore.acquire();
    try {
      final r = await _engine.chatStreamOnce(request, onChunkReceived);
      _updateStats(r, DateTime.now().difference(startTime));
      return r;
    } finally {
      _globalSemaphore.release();
    }
  }

  @override
  Future<ProviderStatistics> getStatistics() async => _statistics;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _engine.dispose();
    _configChangedController.close();
    _connectionChangedController.close();
    _httpClient.close();
  }

  // ---------- 内部实现 ----------

  void _reassignEngine(RwkvEngine newEngine) {
    _engine = newEngine;
  }

  void _setAvailable(bool connected, [String? errorMessage]) {
    if (_isAvailable != connected) {
      _isAvailable = connected;
      _connectionChangedController
          .add(ConnectionStatusChangedEventArgs(connected, errorMessage));
    } else {
      _isAvailable = connected;
    }
  }

  void _updateStats(ChatResponse response, Duration elapsed) {
    final total = _statistics.totalRequests + 1;
    final success =
        _statistics.successfulRequests + (response.isSuccess ? 1 : 0);
    final failed = _statistics.failedRequests + (response.isSuccess ? 0 : 1);
    final avgMs = _statistics.totalRequests == 0
        ? elapsed.inMilliseconds
        : ((_statistics.averageResponseTime.inMilliseconds *
                        _statistics.totalRequests +
                    elapsed.inMilliseconds) /
                total)
            .round();
    _statistics = ProviderStatistics(
      totalRequests: total,
      successfulRequests: success,
      failedRequests: failed,
      averageResponseTime: Duration(milliseconds: avgMs),
      totalTokensUsed: _statistics.totalTokensUsed,
      lastRequestTime: DateTime.now(),
    );
  }
}
