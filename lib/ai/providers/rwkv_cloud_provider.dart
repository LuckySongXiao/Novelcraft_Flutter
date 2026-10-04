// RWKV 云端 Provider —— 官方推理端点（`api-7b.rwkvos.com`）。
//
// 端点上跑的是 `rwkv_lightning_cuda`（engine `albatross`），API 契约见
// `docs/rwkv_lightning_api/`，实测校准见 `PITFALLS.md` §30 / §31。
//
// 与本地 Provider 的三点差异：
//  1. **每个请求都必须带 Cloudflare Access Service Token 的两个头**。
//     头名按字节精确比较（不是 RFC 7230 的不区分大小写），拼错**不会返回 401**，
//     而是静默给你一段 HTML 登录页 / 403 页 —— 然后 `jsonDecode` 炸 FormatException。
//     所以这里用 const 锁死拼写，禁止任何地方写字面量（PITFALLS §27.2）。
//  2. 服务端是 RWKV 原生引擎：**只吃 `/v1/chat/completions`**，`/openai/v1/*` 不存在；
//     会话续跑走 `/state/chat/completions`；能力/显存/队列看 `/v1/server/status`。
//  3. 鉴权是 CF Service Token（两个头），**不是** Bearer apiKey。
library;

import 'dart:convert';

import 'package:logging/logging.dart';

import '../models/batch_chat.dart';
import '../models/batch_chat_model.dart';
import '../observability/ai_runtime_stats.dart';
import '../models/provider.dart';
import '../rwkv/rwkv_batch_client.dart';
import '../rwkv/rwkv_concurrency.dart';
import '../workflow/workflow_branch.dart';
import 'openai_compatible_provider.dart';

/// Cloudflare Access 的 Service Token 头名（**按字节精确**，别改大小写）。
///
/// 官方约定是 `Id`（I 大写 + d 小写），不是 `ID`；`Secret` 同理。
/// 全项目只能引用这两个常量，禁止写字面量字符串。
const String kHeaderCfAccessClientId = 'CF-Access-Client-Id';
const String kHeaderCfAccessClientSecret = 'CF-Access-Client-Secret';

/// 云端默认 baseUrl。
///
/// ⚠ 必须带 `/v1` 后缀：服务端的路由是 `/v1/chat/completions`，
/// `/openai/v1/chat/completions` 实测 404（PITFALLS §31.5）。
const String kRwkvCloudDefaultBaseUrl = 'https://api-7b.rwkvos.com/v1';

/// 模型由当前端点的 `/v1/models` 自动发现，不预填模型 ID。
const String kRwkvCloudDefaultModel = '';

/// 官方云端端点模板。凭据和模型选择均由用户配置，不在源码中预置。
const List<RwkvCloudEndpointProfile> kRwkvOfficialEndpointProfiles =
    <RwkvCloudEndpointProfile>[
      RwkvCloudEndpointProfile(
        id: 'official-1b5',
        name: 'RWKV 官方 1.5B',
        baseUrl: 'https://api-1b5.rwkvos.com/v1',
      ),
      RwkvCloudEndpointProfile(
        id: 'official-3b',
        name: 'RWKV 官方 3B',
        baseUrl: 'https://api-3b.rwkvos.com/v1',
      ),
      RwkvCloudEndpointProfile(
        id: 'official-7b',
        name: 'RWKV 官方 7B',
        baseUrl: 'https://api-7b.rwkvos.com/v1',
      ),
      RwkvCloudEndpointProfile(
        id: 'official-13b',
        name: 'RWKV 官方 13B',
        baseUrl: 'https://api-13b.rwkvos.com/v1',
      ),
    ];

/// 按 endpoint 分开的云端配置，切换地址不会覆盖各自的 Key/模型选择。
class RwkvCloudEndpointProfile {
  const RwkvCloudEndpointProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.defaultModel = '',
    this.cfAccessClientId = '',
    this.cfAccessClientSecret = '',
    this.timeoutSeconds = 180,
    this.defaultMaxTokens = 4000,
    this.defaultTemperature = 1.0,
    this.enableStreaming = true,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String defaultModel;
  final String cfAccessClientId;
  final String cfAccessClientSecret;
  final int timeoutSeconds;
  final int defaultMaxTokens;
  final double defaultTemperature;
  final bool enableStreaming;

  RwkvCloudEndpointProfile copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? apiKey,
    String? defaultModel,
    String? cfAccessClientId,
    String? cfAccessClientSecret,
    int? timeoutSeconds,
    int? defaultMaxTokens,
    double? defaultTemperature,
    bool? enableStreaming,
  }) => RwkvCloudEndpointProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    defaultModel: defaultModel ?? this.defaultModel,
    cfAccessClientId: cfAccessClientId ?? this.cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret ?? this.cfAccessClientSecret,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    defaultMaxTokens: defaultMaxTokens ?? this.defaultMaxTokens,
    defaultTemperature: defaultTemperature ?? this.defaultTemperature,
    enableStreaming: enableStreaming ?? this.enableStreaming,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'defaultModel': defaultModel,
    'cfAccessClientId': cfAccessClientId,
    'cfAccessClientSecret': cfAccessClientSecret,
    'timeoutSeconds': timeoutSeconds,
    'defaultMaxTokens': defaultMaxTokens,
    'defaultTemperature': defaultTemperature,
    'enableStreaming': enableStreaming,
  };

  factory RwkvCloudEndpointProfile.fromJson(Map<String, Object?> json) =>
      RwkvCloudEndpointProfile(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        baseUrl: (json['baseUrl'] as String?) ?? '',
        apiKey: (json['apiKey'] as String?) ?? '',
        defaultModel: (json['defaultModel'] as String?) ?? '',
        cfAccessClientId: (json['cfAccessClientId'] as String?) ?? '',
        cfAccessClientSecret: (json['cfAccessClientSecret'] as String?) ?? '',
        timeoutSeconds: (json['timeoutSeconds'] as num?)?.toInt() ?? 180,
        defaultMaxTokens: (json['defaultMaxTokens'] as num?)?.toInt() ?? 4000,
        defaultTemperature:
            (json['defaultTemperature'] as num?)?.toDouble() ?? 1.0,
        enableStreaming: (json['enableStreaming'] as bool?) ?? true,
      );

  RwkvCloudConfiguration toConfiguration() => RwkvCloudConfiguration(
    baseUrl: baseUrl,
    apiKey: apiKey,
    defaultModel: defaultModel,
    cfAccessClientId: cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret,
    timeoutSeconds: timeoutSeconds,
    defaultMaxTokens: defaultMaxTokens,
    defaultTemperature: defaultTemperature,
    enableStreaming: enableStreaming,
  );
}

/// Cloudflare Access 认证失败（拿到的是 HTML 而不是 JSON）。
class RwkvCloudAuthException implements Exception {
  final String message;
  const RwkvCloudAuthException(this.message);

  @override
  String toString() => 'RwkvCloudAuthException: $message';
}

/// 云端 RWKV 配置。
///
/// 继承 OpenAI 兼容配置以便复用整套请求逻辑；额外携带 CF Service Token，
/// 并在构造/初始化时把它们写进 [customHeaders]（provider 的
/// `_defaultHeaders()` 会把 customHeaders 合并进每个请求）。
class RwkvCloudConfiguration extends OpenAICompatibleConfiguration {
  /// CF Access Service Token 的 Client Id（形如 `xxx.access`）
  String cfAccessClientId;

  /// CF Access Service Token 的 Client Secret
  String cfAccessClientSecret;

  RwkvCloudConfiguration({
    this.cfAccessClientId = '',
    this.cfAccessClientSecret = '',
    super.baseUrl = kRwkvCloudDefaultBaseUrl,
    super.apiKey = '',
    super.defaultModel = kRwkvCloudDefaultModel,
    super.timeoutSeconds = 180,
    super.defaultMaxTokens = 4000,
    super.defaultTemperature = 1.0,
    super.enableStreaming = true,
    Map<String, String>? extraHeaders,
  }) : super(
         providerName: 'RWKV Cloud',
         providerKind: 'RwkvCloud',
         customHeaders: _mergeHeaders(
           cfAccessClientId,
           cfAccessClientSecret,
           extraHeaders,
         ),
       );

  @override
  List<String> getValidationErrors() =>
      baseUrl.trim().isEmpty ? <String>['API 基础地址不能为空'] : <String>[];

  /// 组出应当随每个请求发出的头（CF 两个 + 用户自定义）。
  ///
  /// **每次 initialize 都要重新调用**：用户可能在界面上改了 Token。
  Map<String, String> effectiveHeaders() => _mergeHeaders(
    cfAccessClientId,
    cfAccessClientSecret,
    customHeaders.isEmpty ? null : customHeaders,
  );

  static Map<String, String> _mergeHeaders(
    String id,
    String secret,
    Map<String, String>? extra,
  ) {
    final Map<String, String> h = <String, String>{};
    if (id.trim().isNotEmpty) h[kHeaderCfAccessClientId] = id.trim();
    if (secret.trim().isNotEmpty) {
      h[kHeaderCfAccessClientSecret] = secret.trim();
    }
    if (extra != null) {
      for (final MapEntry<String, String> e in extra.entries) {
        h[e.key] = e.value;
      }
    }
    return h;
  }

  /// 是否已填写了完整的 CF 凭证。
  bool get hasCfCredentials =>
      cfAccessClientId.trim().isNotEmpty &&
      cfAccessClientSecret.trim().isNotEmpty;

  /// 供 KVStore 持久化。
  Map<String, Object?> toCloudMap() => <String, Object?>{
    'cfAccessClientId': cfAccessClientId,
    'cfAccessClientSecret': cfAccessClientSecret,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'defaultModel': defaultModel,
    'timeoutSeconds': timeoutSeconds,
    'defaultMaxTokens': defaultMaxTokens,
    'defaultTemperature': defaultTemperature,
    'enableStreaming': enableStreaming,
  };

  factory RwkvCloudConfiguration.fromCloudMap(
    Map<String, Object?> map,
  ) => RwkvCloudConfiguration(
    cfAccessClientId: (map['cfAccessClientId'] as String?) ?? '',
    cfAccessClientSecret: (map['cfAccessClientSecret'] as String?) ?? '',
    baseUrl: (map['baseUrl'] as String?) ?? kRwkvCloudDefaultBaseUrl,
    apiKey: (map['apiKey'] as String?) ?? '',
    defaultModel: (map['defaultModel'] as String?) ?? kRwkvCloudDefaultModel,
    timeoutSeconds: (map['timeoutSeconds'] as num?)?.toInt() ?? 180,
    defaultMaxTokens: (map['defaultMaxTokens'] as num?)?.toInt() ?? 4000,
    defaultTemperature: (map['defaultTemperature'] as num?)?.toDouble() ?? 1.0,
    enableStreaming: (map['enableStreaming'] as bool?) ?? true,
  );
}

/// 云端 RWKV Provider。
///
/// 直接复用 [OpenAICompatibleProvider] 的 chat / stream / 重试 / 错误处理，
/// 只额外做三件事：注入 CF 头、把 `/v1/server/status` 的引擎状态取回来、
/// 识别「CF 把 HTML 当成响应体」这种认证失败。
class RwkvCloudProvider extends OpenAICompatibleProvider
    with RwkvBatchChatModelMixin
    implements IBatchChatModel, IBranchingChatModel {
  RwkvCloudProvider({
    super.registeredProviderName = 'RWKV Cloud',
    super.client,
    super.logger,
    AiRuntimeStats? stats,
  }) : _stats = stats {
    _batch = RwkvBatchClient(
      client: httpClient,
      baseUrl: () => configuration.baseUrl,
      headers: _authHeaders,
      logger: _cloudLogger,
      stats: _stats,
      statsProvider: registeredProviderName,
    );
    _concurrency = RwkvConcurrencyController(
      probe: () => _batch.capacity(),
      logger: _cloudLogger,
    );
    _batch.concurrency = _concurrency;
  }

  static final Logger _cloudLogger = Logger('RwkvCloud');

  late final RwkvBatchClient _batch;
  late final RwkvConcurrencyController _concurrency;

  /// 运行时指标（P4-26）。null = 不统计。
  final AiRuntimeStats? _stats;

  /// 供健康面板读客户端指标。
  AiRuntimeStats? get runtimeStats => _stats;

  /// 分叉能力探测结果缓存（探测本身要发一次 HTTP，不能每次问）
  BranchCapability? _capability;

  /// 当前生效的 CF 头（每次请求现算，用户可能在界面上改过 Token）。
  Map<String, String> _authHeaders() =>
      _cloudConfig?.effectiveHeaders() ?? const <String, String>{};

  // ---------------------------------------------------------------------------
  // RWKV 引擎独有能力（HANDOFF 18c：batchChat / batchChatStream / statefulChat /
  // multiStateChat / stateCacheStatus / stateDelete）
  // ---------------------------------------------------------------------------

  /// 并发容量控制器（给 BatchAgentExecutor / Semaphore 自适应用）。
  RwkvConcurrencyController get concurrency => _concurrency;

  /// 底层批量客户端（供 `BatchAgentExecutor` 复用）。
  @override
  RwkvBatchClient get batchClient => _batch;

  /// 读引擎状态（能力 / 显存 / 队列 / 吞吐）。
  @override
  Future<RwkvServerCapacity?> capacity() => _batch.capacity();

  /// 未 initialize 就调用 RWKV 独有接口时的统一报错。
  ///
  /// ⚠ 必须有这道闸：`_configuration` 的初值是基类默认的
  /// `https://api.openai.com/v1` —— 不加守卫会**静默把 RWKV 原生的
  /// `contents` 请求打到 OpenAI 上**，拿到一个 400 然后让人一头雾水。
  void _requireInitialized() {
    if (_cloudConfig == null) {
      throw StateError(
        'RwkvCloudProvider 尚未 initialize()，'
        '当前 baseUrl=${configuration.baseUrl}（不是 RWKV 云端端点）。'
        '请先调用 initialize(RwkvCloudConfiguration(...))。',
      );
    }
  }

  /// 批量补全（**一次 POST 打多条 prompt**）—— 返回按 `index` 对齐的文本。
  ///
  /// 覆写 mixin 默认实现，只为补一道「未 initialize」守卫：
  /// `_configuration` 的初值是基类默认的 `https://api.openai.com/v1`，
  /// 不设闸会把 RWKV 原生 `contents` 请求静默打到 OpenAI 上（PITFALLS §33.8）。
  @override
  Future<List<String?>> batchChat(RwkvBatchRequest request) {
    _requireInitialized();
    return super.batchChat(request);
  }

  /// 流式批量补全（按 `index` 分组缓存，到达顺序无关）。
  @override
  Stream<RwkvBatchProgress> batchChatStream(RwkvBatchRequest request) {
    _requireInitialized();
    return super.batchChatStream(request);
  }

  /// 有状态单分支续跑：只发**本轮增量**，state 由服务端按 `session_id` 维护。
  @override
  Future<String> statefulChat({
    required String sessionId,
    required String prompt,
    int? maxTokens,
  }) async {
    _requireInitialized();
    final Stopwatch sw = Stopwatch()..start();
    try {
      final Map<String, dynamic> json = await _batch.postJson(
        kRouteRwkvStateChat,
        <String, dynamic>{
          'session_id': sessionId,
          // ⚠ 必须**恰好 1 条**，传 2 条服务端 400
          // `Request must contain exactly one prompt`（PITFALLS §31.6）
          'contents': <String>[prompt],
          'stream': false,
          'max_tokens': maxTokens ?? 1024,
          'stop_tokens': kRwkvDefaultStopTokens,
        },
      );
      sw.stop();
      _stats?.record(
        AiRequestSample(
          provider: registeredProviderName,
          operation: 'stateful',
          success: true,
          latency: sw.elapsed,
        ),
      );
      return _extractFirstContent(json);
    } on Object {
      sw.stop();
      _stats?.record(
        AiRequestSample(
          provider: registeredProviderName,
          operation: 'stateful',
          success: false,
          latency: sw.elapsed,
          failureKind: 'statefulError',
        ),
      );
      rethrow;
    }
  }

  /// 真·服务端分叉：`session_id` + `dialogue_idx`。
  ///
  /// 返回 (文本, 服务端新分配的 dialogue_idx)。非流式响应顶层带新 idx。
  @override
  Future<(String text, int? newIdx)> multiStateChat({
    required String sessionId,
    required int dialogueIdx,
    required String prompt,
    int? maxTokens,
  }) async {
    _requireInitialized();
    final Map<String, dynamic> json = await _batch.postJson(
      kRouteRwkvMultiStateChat,
      <String, dynamic>{
        'session_id': sessionId,
        'dialogue_idx': dialogueIdx,
        'contents': <String>[prompt],
        'stream': false,
        'max_tokens': maxTokens ?? 1024,
        'stop_tokens': kRwkvDefaultStopTokens,
      },
    );
    return (
      _extractFirstContent(json),
      (json['dialogue_idx'] as num?)?.toInt(),
    );
  }

  // ---------------------------------------------------------------------------
  // IBranchingChatModel
  // ---------------------------------------------------------------------------

  /// 探测分叉能力（结果缓存）。
  ///
  /// L1 `/multi_state/chat/completions`（官方标「可选」，线上 1.3.0 **实测 404**）
  /// L2 退回 `/state/chat/completions`（用它 + 独立 session_id 模拟分叉）
  /// L3 两者都没有 → 串行重编码
  @override
  Future<BranchCapability> probeBranchCapability() async {
    final BranchCapability? cached = _capability;
    if (cached != null) return cached;
    BranchCapability cap = BranchCapability.serialOnly;
    if (await _batch.routeExists(kRouteRwkvMultiStateChat)) {
      cap = BranchCapability.multiState;
    } else if (await _batch.routeExists(kRouteRwkvStateChat)) {
      cap = BranchCapability.sessionSeed;
    }
    _cloudLogger.info(
      '分叉能力探测：${cap.label}'
      '（multi_state=${cap == BranchCapability.multiState}）',
    );
    _capability = cap;
    return cap;
  }

  /// 从 OpenAI/原生风格响应里取第一条 choice 的文本。
  ///
  /// 兼容 `choices[].message.content`（chat 与 stateful 用这个）
  /// 与 `choices[].text`（老式 completions 风格）。
  static String _extractFirstContent(Map<String, dynamic> json) {
    final Object? choices = json['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final Object? first = choices.first;
    if (first is! Map<String, dynamic>) return '';
    final Object? msg = first['message'];
    if (msg is Map<String, dynamic>) {
      final Object? c = msg['content'];
      if (c is String) return c;
    }
    final Object? t = first['text'];
    return t is String ? t : '';
  }

  @override
  ModelProviderType get providerType => ModelProviderType.cloudApi;

  @override
  Future<bool> configure(IModelConfiguration configuration, {bool probe = true}) async {
    // ⚠ 每次初始化都要把 CF 头重新灌进 customHeaders：
    // 用户可能在界面上改过 Token，而 _normalize() 只做浅拷贝。
    if (configuration is RwkvCloudConfiguration) {
      configuration.customHeaders = configuration.effectiveHeaders();
      if (!configuration.hasCfCredentials) {
        _cloudLogger.warning(
          'RWKV Cloud 未配置 Cloudflare Access Service Token，'
          '请求会拿到 HTML 登录页而不是 JSON（PITFALLS §27.2）。',
        );
      }
    }
    return super.configure(configuration, probe: probe);
  }

  /// 取引擎状态：能力 / 显存 / 队列 / 实时吞吐（文档 §11）。
  ///
  /// 返回 null 表示端点不可用（老版本引擎或非 rwkv_lightning 服务端）。
  /// 该请求**不带 `/v1` 会 404**，所以用 baseUrl + `/server/status`。
  Future<Map<String, dynamic>?> fetchServerStatus() async {
    final cfg = _cloudConfig;
    if (cfg == null) return null;
    try {
      final uri = Uri.parse(
        '${cfg.baseUrl.replaceAll(RegExp(r'/$'), '')}/server/status',
      );
      final resp = await httpClient.get(uri, headers: cfg.effectiveHeaders());
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final body = resp.body;
      if (body.trimLeft().startsWith('<')) return null; // CF HTML 页
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      _cloudLogger.fine('取 /v1/server/status 失败（可忽略）：$e');
      return null;
    }
  }

  /// 从引擎状态里抽出给 UI 用的摘要（能力 / 显存 / 队列 / 吞吐）。
  Future<RwkvCloudServerSummary?> fetchServerSummary() async {
    final st = await fetchServerStatus();
    if (st == null) return null;
    return RwkvCloudServerSummary.fromStatus(st);
  }

  /// 连通性测试：失败时把「CF 返回 HTML」单独识别出来给可读提示。
  @override
  Future<ConnectionTestResult> testConnection() async {
    final result = await super.testConnection();
    if (result.isSuccess) return result;

    final msg = result.errorMessage ?? '';
    final looksHtml =
        msg.contains('<html') ||
        msg.contains('<!DOCTYPE') ||
        msg.contains('cloudflareaccess.com') ||
        msg.contains('Access login');
    if (looksHtml) {
      return ConnectionTestResult(
        isSuccess: false,
        responseTime: result.responseTime,
        errorMessage:
            'Cloudflare Access 认证失败：服务器返回的是 HTML 登录页而不是 JSON。'
            '请检查 $kHeaderCfAccessClientId / $kHeaderCfAccessClientSecret 的拼写'
            '（精确大小写）、Service Token 是否过期、出口 IP 是否被 CF WAF 拦截。'
            '（PITFALLS §27.2）原始响应前 200 字：'
            '${msg.length > 200 ? msg.substring(0, 200) : msg}',
        serverInfo: result.serverInfo,
      );
    }
    return result;
  }

  /// 当前配置若为云端配置则返回，否则 null。
  ///
  /// ⚠ 注意：`initialize()` 内部会走 `_normalize()`，它返回的是**基类**
  /// `OpenAICompatibleConfiguration`（会丢掉子类类型）。所以这里额外兜一层：
  /// 只要是 `RwkvCloud` 这类配置，就用基类字段重建一个等价视图。
  RwkvCloudConfiguration? get _cloudConfig {
    final c = configuration;
    if (c is RwkvCloudConfiguration) return c;
    if (c.providerKind != 'RwkvCloud') return null;
    return RwkvCloudConfiguration(
      baseUrl: c.baseUrl,
      apiKey: c.apiKey,
      defaultModel: c.defaultModel,
      timeoutSeconds: c.timeoutSeconds,
      defaultMaxTokens: c.defaultMaxTokens,
      defaultTemperature: c.defaultTemperature,
      enableStreaming: c.enableStreaming,
      cfAccessClientId: c.customHeaders[kHeaderCfAccessClientId] ?? '',
      cfAccessClientSecret: c.customHeaders[kHeaderCfAccessClientSecret] ?? '',
    );
  }
}

/// `/v1/server/status` 的 UI 摘要。
class RwkvCloudServerSummary {
  final String status;
  final String apiVersion;
  final String engineVersion;

  /// 引擎声明的能力开关（stream / session_cache / concurrent_generation …）
  final Map<String, bool> capabilities;

  /// 硬上限 / 动态上限 / 当前可用并发槽位
  final int? hardMaxBsz;
  final int? dynamicMaxBsz;
  final int? availableBsz;

  /// 排队中的请求数（> 0 说明已经该降并发）
  final int? queuedRequests;

  final double? freeVramGb;
  final double? totalVramGb;

  /// 最近一次完成的请求：prefill / decode 速度（tok/s）
  final double? lastPrefillSpeed;
  final double? lastDecodeSpeed;

  const RwkvCloudServerSummary({
    required this.status,
    required this.apiVersion,
    required this.engineVersion,
    required this.capabilities,
    this.hardMaxBsz,
    this.dynamicMaxBsz,
    this.availableBsz,
    this.queuedRequests,
    this.freeVramGb,
    this.totalVramGb,
    this.lastPrefillSpeed,
    this.lastDecodeSpeed,
  });

  factory RwkvCloudServerSummary.fromStatus(Map<String, dynamic> st) {
    final Map<String, bool> caps = <String, bool>{};
    final Object? rawCaps = st['capabilities'];
    if (rawCaps is Map) {
      rawCaps.forEach((Object? k, Object? v) {
        if (v is bool) caps['$k'] = v;
      });
    }
    final Object? q = st['prefill_queue'];
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    double gb(Object? v) => v is num ? v / (1024 * 1024 * 1024) : 0;
    final Object? last = st['last_request'];
    return RwkvCloudServerSummary(
      status: (st['status'] as String?) ?? 'unknown',
      apiVersion: (st['api_version'] as String?) ?? '',
      engineVersion: (st['engine_version'] as String?) ?? '',
      capabilities: caps,
      hardMaxBsz: q is Map ? asInt(q['hard_max_bsz']) : null,
      dynamicMaxBsz: q is Map ? asInt(q['dynamic_max_bsz']) : null,
      availableBsz: q is Map ? asInt(q['available_bsz']) : null,
      queuedRequests: q is Map ? asInt(q['queued_requests']) : null,
      freeVramGb: q is Map ? gb(q['free_vram_bytes']) : null,
      totalVramGb: q is Map ? gb(q['total_vram_bytes']) : null,
      lastPrefillSpeed: last is Map && last['prefill_speed'] is num
          ? (last['prefill_speed'] as num).toDouble()
          : null,
      lastDecodeSpeed: last is Map && last['decode_speed'] is num
          ? (last['decode_speed'] as num).toDouble()
          : null,
    );
  }
}
