// RWKV 核心推理引擎。
//
// 这是整个 NovelCraft 本地 RWKV 能力的中枢：**向上**对 [RwkvProvider] 暴露
// 会话化的 chat / chatStream（可选 sessionId，内部自动复用 state）；
// **向下** 协调三件事：
//   1. [RwkvStateCache] —— LRU state 缓存 + 序列化/反序列化元数据
//   2. [RwkvSessionManager] —— 多会话隔离 + 单会话内串行化推理（防止
//      state 演化分支错乱）
//   3. [Semaphore] —— 引擎级并发上限（默认 4 个并行 session，同时跑
//      多个 Agent / Workflow 互不阻塞）
//
// 真正的 HTTP 请求仍然由底层 `OpenAICompatibleProvider.chat*` 发出
// （因为 RWKV server 端导出 OpenAI 兼容 API），但本层在发请求前：
//   - 若命中「已有 state」：把 state 作为 `extraBody['state_id']` 或通过
//     server 原生 `/state` API 注入，让 server 端跳过「重新编码完整历史」
//     这一步（RNN = O(1) 上下文接续，Transformer 的 KV Cache 则做不到）
//   - 响应返回后：把新派生的 state 存回 cache
//
// 本文件不直接 `import 'dart:io'`，可在 Web 端编译通过（Server 是远端
// HTTP 的模式下 Web 端也能用 State 复用；只是 Scanner 自动扫 gguf 仅
// Native 生效）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../inference/inference_launcher.dart';
import '../models/chat.dart';
import '../utils/output_sanitizer.dart';
import '../utils/semaphore.dart';
import '../observability/ai_runtime_stats.dart';
import 'rwkv_session_archive.dart';
import 'rwkv_file_probe.dart';
import 'rwkv_lightning_launch_args.dart';
import 'rwkv_models.dart';
import 'rwkv_official_resources.dart' show OfficialServerVariant;
import 'rwkv_session.dart';
import '../runtime_settings.dart';
import 'rwkv_state.dart';

/// 单次推理的引擎级结果（比 [ChatResponse] 多了 state 指针信息）。
class RwkvEngineResult {
  final ChatResponse chat;

  /// 本轮推理后派生的新 state ID（会话模式下永远非空）。
  final String newStateId;

  /// 本轮处理的 token 增量（prompt 增量 + 生成）。
  final int tokenDelta;

  const RwkvEngineResult({
    required this.chat,
    required this.newStateId,
    required this.tokenDelta,
  });
}

/// RWKV **原生**生成参数（对应官方文档 §4「通用生成参数」）。
///
/// 这些字段 OpenAI 标准里没有，必须**展平到请求体顶层**透传 ——
/// 早期实现把它们塞进 `extra_body`，服务端只读顶层，于是**全部静默失效**
/// （HTTP 恒 200、回答正常，完全看不出问题）。见 PITFALLS §31.1。
///
/// 默认值取自官方文档 §4，与 `null`（= 让服务端用自己的默认）语义不同：
/// 明确给出值可以避免服务端默认值随版本漂移。
class RwkvNativeOptions {
  /// 思考前缀模式：`none` / `fast` / `free` / `preferChinese` / `en` /
  /// `enShort` / `enLong`。null = 不传（服务端默认 `fast`）。
  final String? thinkType;

  /// Top-K 采样（文档默认 20）
  final int? topK;

  /// Top-P 采样（文档默认 0.3）
  final double? topP;

  /// presence 重复惩罚（文档默认 2.0）
  final double? alphaPresence;

  /// frequency 重复惩罚（文档默认 0.2）
  final double? alphaFrequency;

  /// 重复惩罚衰减（文档默认 0.996）
  final double? alphaDecay;

  /// 停止 **token ID**（不是停止字符串）。
  ///
  /// ⚠ 文档默认 `[0, 261, 24281]`，但**实测 `/v1/batch/completions` 不传该字段时
  /// 每个槽位返回空文本**（HTTP 200 + index 正确，极易误判成模型问题）——
  /// 故本类默认**显式带上**，批量场景尤其必须。见 PITFALLS §30.2 / §31.6。
  final List<int>? stopTokens;

  /// 流式**输出**累计多少 token 后发一次（不是 prefill 分块；
  /// prefill 分块由启动参数 `--chunk-size` 全局控制）。
  /// 文档：chat 路由与 batch 路由默认值不同（batch 流式默认 8）。
  final int? chunkSize;

  /// 启用内部 reasoning token mask；传 think 字段时会被其覆盖。
  final bool? forceReasoning;

  /// 官方文档 §4 的默认停止 token。
  static const List<int> defaultStopTokens = <int>[0, 261, 24281];

  const RwkvNativeOptions({
    this.thinkType,
    this.topK,
    this.topP,
    this.alphaPresence,
    this.alphaFrequency,
    this.alphaDecay,
    this.stopTokens = defaultStopTokens,
    this.chunkSize,
    this.forceReasoning,
  });

  /// 只保留显式设置过的字段，交给调用方展平进请求体。
  Map<String, dynamic> toRequestBody() {
    final Map<String, dynamic> m = <String, dynamic>{};
    if (thinkType != null && thinkType!.isNotEmpty) m['think_type'] = thinkType;
    if (topK != null) m['top_k'] = topK;
    if (topP != null) m['top_p'] = topP;
    if (alphaPresence != null) m['alpha_presence'] = alphaPresence;
    if (alphaFrequency != null) m['alpha_frequency'] = alphaFrequency;
    if (alphaDecay != null) m['alpha_decay'] = alphaDecay;
    if (stopTokens != null && stopTokens!.isNotEmpty) {
      m['stop_tokens'] = stopTokens;
    }
    if (chunkSize != null) m['chunk_size'] = chunkSize;
    if (forceReasoning != null) m['force_reasoning'] = forceReasoning;
    return m;
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'thinkType': thinkType,
        'topK': topK,
        'topP': topP,
        'alphaPresence': alphaPresence,
        'alphaFrequency': alphaFrequency,
        'alphaDecay': alphaDecay,
        'stopTokens': stopTokens,
        'chunkSize': chunkSize,
        'forceReasoning': forceReasoning,
      };

  factory RwkvNativeOptions.fromJson(Map<String, Object?> map) =>
      RwkvNativeOptions(
        thinkType: map['thinkType'] as String?,
        topK: (map['topK'] as num?)?.toInt(),
        topP: (map['topP'] as num?)?.toDouble(),
        alphaPresence: (map['alphaPresence'] as num?)?.toDouble(),
        alphaFrequency: (map['alphaFrequency'] as num?)?.toDouble(),
        alphaDecay: (map['alphaDecay'] as num?)?.toDouble(),
        stopTokens: (map['stopTokens'] as List<Object?>?)
            ?.map((Object? e) => (e as num).toInt())
            .toList(growable: false),
        chunkSize: (map['chunkSize'] as num?)?.toInt(),
        forceReasoning: map['forceReasoning'] as bool?,
      );

  RwkvNativeOptions copyWith({
    String? thinkType,
    int? topK,
    double? topP,
    double? alphaPresence,
    double? alphaFrequency,
    double? alphaDecay,
    List<int>? stopTokens,
    int? chunkSize,
    bool? forceReasoning,
  }) =>
      RwkvNativeOptions(
        thinkType: thinkType ?? this.thinkType,
        topK: topK ?? this.topK,
        topP: topP ?? this.topP,
        alphaPresence: alphaPresence ?? this.alphaPresence,
        alphaFrequency: alphaFrequency ?? this.alphaFrequency,
        alphaDecay: alphaDecay ?? this.alphaDecay,
        stopTokens: stopTokens ?? this.stopTokens,
        chunkSize: chunkSize ?? this.chunkSize,
        forceReasoning: forceReasoning ?? this.forceReasoning,
      );
}

/// RWKV 推理引擎配置。
class RwkvEngineConfig {
  /// HTTP 基础地址（server 监听地址）。
  final String baseUrl;

  /// 本地模型目录（Native 下自动扫 .gguf）。
  final String modelsDir;

  /// 引擎级并发上限（同机可并行多少个 session；7B 模型建议 2~4）。
  final int maxConcurrentSessions;

  /// State 缓存上限条目数（LRU）。
  final int maxStateCacheSize;

  /// State 存活 TTL。
  final Duration stateTtl;

  /// 会话默认空闲超时（超过自动关闭）。
  final Duration sessionIdleTtl;

  /// RWKV 原生生成参数（think_type / 采样 / stop_tokens / chunk_size）。
  final RwkvNativeOptions nativeOptions;

  /// 会话推理是否走官方的 **`/state/chat/completions`**（服务端三级 state 缓存）。
  ///
  /// - `true`（推荐，配合 rwkv_lightning_cuda）：会话内只把**本轮新增的**对话
  ///   作为 `contents`（必须恰好 1 条）发给服务端，由服务端按 `session_id`
  ///   维护 state —— 真正实现 RNN 的 O(1) 上下文接续，不必每轮重编码全部历史。
  /// - `false`：每轮把完整历史发 `/v1/chat/completions`。语义永远正确，
  ///   但长对话会反复重编码，性能差。
  ///
  /// ⚠ 该路由**没有 `/v1` 前缀**（文档 §9），且**不可并发写同一 `session_id`**
  /// （后完成者会覆盖先完成者的 state）—— 会话层已用 `runSerialized` 串行化。
  final bool useStatefulRoute;

  const RwkvEngineConfig({
    this.baseUrl = 'http://localhost:8000',
    this.modelsDir = 'rwkv_models',
    this.maxConcurrentSessions = 4,
    this.maxStateCacheSize = 64,
    this.stateTtl = const Duration(minutes: 30),
    this.sessionIdleTtl = const Duration(minutes: 60),
    this.nativeOptions = const RwkvNativeOptions(),
    this.useStatefulRoute = false,
  });

  Map<String, Object?> toMap() => <String, Object?>{
        'baseUrl': baseUrl,
        'modelsDir': modelsDir,
        'maxConcurrentSessions': maxConcurrentSessions,
        'maxStateCacheSize': maxStateCacheSize,
        'stateTtlSeconds': stateTtl.inSeconds,
        'sessionIdleTtlSeconds': sessionIdleTtl.inSeconds,
        'nativeOptions': nativeOptions.toMap(),
        'useStatefulRoute': useStatefulRoute,
      };

  factory RwkvEngineConfig.fromJson(Map<String, Object?> map) =>
      RwkvEngineConfig(
        baseUrl: (map['baseUrl'] as String?) ?? 'http://localhost:8000',
        modelsDir: (map['modelsDir'] as String?) ?? 'rwkv_models',
        maxConcurrentSessions:
            (map['maxConcurrentSessions'] as num?)?.toInt() ?? 4,
        maxStateCacheSize:
            (map['maxStateCacheSize'] as num?)?.toInt() ?? 64,
        stateTtl: Duration(
            seconds: (map['stateTtlSeconds'] as num?)?.toInt() ?? 30 * 60),
        sessionIdleTtl: Duration(
            seconds:
                (map['sessionIdleTtlSeconds'] as num?)?.toInt() ?? 60 * 60),
        nativeOptions: (() {
          final Object? n = map['nativeOptions'];
          if (n is Map<String, Object?>) return RwkvNativeOptions.fromJson(n);
          return const RwkvNativeOptions();
        })(),
        useStatefulRoute: (map['useStatefulRoute'] as bool?) ?? false,
      );

  RwkvEngineConfig copyWith({
    String? baseUrl,
    String? modelsDir,
    int? maxConcurrentSessions,
    int? maxStateCacheSize,
    Duration? stateTtl,
    Duration? sessionIdleTtl,
    RwkvNativeOptions? nativeOptions,
    bool? useStatefulRoute,
  }) =>
      RwkvEngineConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        modelsDir: modelsDir ?? this.modelsDir,
        maxConcurrentSessions: maxConcurrentSessions ?? this.maxConcurrentSessions,
        maxStateCacheSize: maxStateCacheSize ?? this.maxStateCacheSize,
        stateTtl: stateTtl ?? this.stateTtl,
        sessionIdleTtl: sessionIdleTtl ?? this.sessionIdleTtl,
        nativeOptions: nativeOptions ?? this.nativeOptions,
        useStatefulRoute: useStatefulRoute ?? this.useStatefulRoute,
      );
}

/// 核心推理引擎。
class RwkvEngine {
  final RwkvEngineConfig config;
  final Logger _logger;
  final http.Client _client;

  /// [http.Client] 是否为引擎自建。
  ///
  /// ⚠ 只有自建的才允许在 [dispose] 里 close —— 若客户端是外部注入（provider
  /// 会把自己的 client 传进来），close 掉会连带废掉 provider 自己的请求能力。
  /// 这个坑在「重建引擎」时必现（先 dispose 旧的，再用同一个 client 建新的）。
  final bool _ownsClient;
  final Semaphore _semaphore;
  final RwkvStateCache _stateCache;
  late final RwkvSessionManager _sessionManager;
  final InferenceProcessLauncher? _processLauncher;
  final RwkvModelScanner _modelScanner;

  /// 运行时指标（P4-26）。null = 不统计。
  final AiRuntimeStats? stats;

  var _disposed = false;
  bool _launcherStarted = false;
  Timer? _idleGCTimer;
  String? _lastLaunchDiagnostics;

  /// 构造引擎。
  RwkvEngine({
    this.config = const RwkvEngineConfig(),
    http.Client? client,
    Logger? logger,
    InferenceProcessLauncher? processLauncher,
    RwkvModelScanner? modelScanner,
    this.stats,
  })  : _ownsClient = client == null,
        _client = client ?? http.Client(),
        _logger = logger ?? Logger('RwkvEngine'),
        _semaphore = Semaphore(config.maxConcurrentSessions),
        _stateCache = RwkvStateCache(
          maxSize: config.maxStateCacheSize,
          ttl: config.stateTtl,
        ),
        _processLauncher = processLauncher ?? InferenceProcessLauncher(),
        _modelScanner = modelScanner ?? RwkvModelScanner() {
    _sessionManager = RwkvSessionManager(
      stateCache: _stateCache,
      logger: _logger,
    );
    // 客户端 state 缓存命中率 → 运行时指标（P4-26）。
    // 引擎**不持有** AiRuntimeStats 的所有权：外部注入 null 就不统计。
    final AiRuntimeStats? st = stats;
    if (st != null) {
      _stateCache.onLookup = (bool hit, int bytes) =>
          st.recordStateCacheLookup(hit: hit, bytes: bytes);
      _stateCache.onEvicted = st.recordStateCacheDropped;
    }
    _idleGCTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_disposed) return;
      final freedSessions =
          _sessionManager.evictIdle(config.sessionIdleTtl);
      final freedStates = _stateCache.evictExpired();
      if (freedSessions > 0 || freedStates > 0) {
        _logger.fine('RWKV GC: 回收 $freedSessions 会话 / $freedStates 状态');
      }
    });
  }

  // ---------- 公共：观测 ----------

  RwkvStateCache get stateCache => _stateCache;
  RwkvSessionManager get sessionManager => _sessionManager;

  /// 当前活跃 session 数。
  int get activeSessions => _sessionManager.activeCount;

  /// 当前 state 条目数。
  int get cachedStates => _stateCache.length;

  /// 引擎级并发上限（客户端保守限流，见 PITFALLS §31.3）。
  int get concurrencyLimit => _semaphore.max;

  /// 当前空闲的并发槽位。
  int get concurrencyAvailable => _semaphore.available;

  /// 最近一次启动本地 server 的诊断信息（失败时写入详情，成功清空）。
  String? get lastLaunchDiagnostics => _lastLaunchDiagnostics;

  /// 本地 server 是否正在运行（启动成功后返回 true）。
  bool get localServerRunning {
    final launcher = _processLauncher;
    return launcher != null && launcher.isRunning;
  }

  /// **手动停止**本地 server 进程。
  ///
  /// 走 `InferenceProcessLauncher.stop()`：先 `SIGTERM` 等 5s，超时强杀。
  /// 停止后把 `_launcherStarted` 复位，用户可再次 [ensureLocalServer] 重新拉起；
  /// 同时清空上一次的启动诊断（否则「停止后」还会显示旧的报错面板内容）。
  ///
  /// 最后再调一次 `reclaimOrphaned()`：引擎重建 / App 上次异常退出遗留的进程
  /// 不在本 launcher 句柄里，只能按 pid 记录文件回收 —— 否则「点了停止，显存
  /// 还是被占着」，这正是用户报的显存残留问题。
  ///
  /// 返回是否真的停掉了本地 server（含回收到的孤儿进程；都没有 → false）。
  Future<bool> stopLocalServer() async {
    final launcher = _processLauncher;
    bool stopped = false;
    if (launcher != null && launcher.isRunning) {
      final int? pid = launcher.pid;
      await launcher.stop();
      stopped = true;
      _logger.info('本地 RWKV server 已停止${pid == null ? '' : '（pid=$pid）'}');
    }
    _launcherStarted = false;
    _lastLaunchDiagnostics = null;
    final int reclaimed = await InferenceProcessLauncher.reclaimOrphaned();
    if (reclaimed > 0) {
      _logger.info('额外回收了 $reclaimed 个遗留的本地推理进程');
    }
    return stopped || reclaimed > 0;
  }

  // ---------- 公共：生命周期 ----------

  /// 启动本地 server 进程（若配置了本地 server 可执行文件与模型路径）。
  ///
  /// 返回是否启动成功（无 launcher / server 已经 running / Web 平台返回 true 静默跳过）。
  Future<bool> ensureLocalServer({
    String? executable,
    String? modelFilePath,
    int port = 8000,
    List<String> extraArgs = const [],
    Duration startupTimeout = const Duration(seconds: 45),
    OfficialServerVariant? serverVariant,
    String? vocabPath,
    bool enableDynamicModelLoading = false,
    String? stateDbPath,
  }) async {
    if (_disposed) return false;
    if (_launcherStarted) return true;
    final launcher = _processLauncher;
    if (launcher == null || executable == null || executable.isEmpty) {
      return true; // 默认走远端 HTTP server，不算失败
    }
    final Stopwatch sw = Stopwatch()..start();
    _lastLaunchDiagnostics = null;
    try {
      final bool isLightning = serverVariant == OfficialServerVariant.cuda12 ||
          serverVariant == OfficialServerVariant.cuda13;

      // ---------------- 参数构造（两套引擎的 CLI 完全不同）----------------
      final List<String> args;
      if (isLightning) {
        final String mp = modelFilePath ?? '';
        final String vp = vocabPath ?? '';
        // 探测（本文件不 import dart:io，走条件导入的探针）
        final bool modelIsDir = rwkvPathIsDirectory(mp);
        final RwkvLightningLaunchArgs la = RwkvLightningLaunchArgs(
          modelPath: mp,
          vocabPath: vp,
          port: port,
          enableDynamicModelLoading: enableDynamicModelLoading,
          stateDbPath: stateDbPath,
        );
        // 硬校验集中在 RwkvLightningLaunchArgs 那边（纯函数，可单测）：
        // ①GGUF 混入 ②词表缺失/过小 —— 两条都会让进程秒退，
        // 而 UI 侧只能看到 "连接被拒"，极难定位（PITFALLS §27.1）。
        final RwkvLightningPreflight pf = preflightLightningArgs(
          la,
          isDirectory: modelIsDir,
          vocabSizeBytes: rwkvFileSizeOrNull(vp),
          modelSizeBytes: modelIsDir ? null : rwkvFileSizeOrNull(mp),
        );
        if (!pf.ok) {
          _lastLaunchDiagnostics = '${pf.message}\n'
              'args=${la.describeRedacted()}';
          _logger.severe(_lastLaunchDiagnostics);
          return false;
        }
        args = <String>[...la.toArgs(), ...extraArgs];
      } else {
        // llama.cpp / llama-server CLI
        args = <String>[
          '--model', modelFilePath ?? '',
          '--host', '127.0.0.1',
          '--port', '$port',
          '--ctx-size', '8192',
          '--n-gpu-layers', '99',
          ...extraArgs,
        ];
      }
      final ok = await launcher.start(
        executable: executable,
        arguments: args,
        startupTimeout: startupTimeout,
      );
      if (!ok) {
        final errs = launcher.recentStderr;
        final sb = StringBuffer('启动失败：Process.start 返回 false。')
          ..writeln('executable=$executable')
          ..writeln('args=${args.join(' ')}');
        if (errs.isNotEmpty) sb.writeln('stderr:\n${errs.join('\n')}');
        _lastLaunchDiagnostics = sb.toString();
        _logger.severe(_lastLaunchDiagnostics);
        return false;
      }
      final healthEnd = sw.elapsed + startupTimeout;
      bool alive = false;
      final base = 'http://127.0.0.1:$port';
      Object? lastErr;
      while (sw.elapsed < healthEnd && !_disposed) {
        if (!launcher.isRunning) {
          final code = launcher.lastExitCode;
          final errlines = launcher.recentStderr;
          final outlines = launcher.recentStdout;
          final sb = StringBuffer('进程在探活前已退出：exitCode=$code')
            ..writeln('耗时 ${sw.elapsed.inSeconds}s')
            ..writeln('executable=$executable')
            ..writeln('args=${args.join(' ')}');
          if (errlines.isNotEmpty) sb.writeln('STDERR:\n${errlines.join('\n')}');
          if (outlines.isNotEmpty) sb.writeln('STDOUT:\n${outlines.join('\n')}');
          _lastLaunchDiagnostics = sb.toString();
          _logger.severe(_lastLaunchDiagnostics);
          return false;
        }
        // 依次探测三条「就绪」判据，任一 2xx 即认为已就绪：
        //   1. `/health`            —— llama.cpp / rwkv.cpp 的约定
        //   2. `/v1/models`         —— OpenAI 兼容层通用
        //   3. `/v1/server/status`  —— rwkv_lightning_cuda 的**权威**状态端点
        //      （该引擎 **没有** `/health`，实测 404；只探前两条会白白等满整个
        //        startupTimeout 才判失败。见 PITFALLS §30.8 / §31.2）
        for (final String probe in <String>[
          '$base/health',
          '$base/v1/models',
          '$base/v1/server/status',
        ]) {
          try {
            final resp = await _client
                .get(Uri.parse(probe))
                .timeout(const Duration(seconds: 3));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              alive = true;
              break;
            }
          } on Exception catch (e) {
            lastErr ??= e;
          }
          if (alive) break;
        }
        if (alive) break;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      if (!alive) {
        final code = launcher.lastExitCode;
        final errlines = launcher.recentStderr;
        final sb = StringBuffer(
            '端口探活失败：无法连接 http://127.0.0.1:$port')
          ..writeln('耗时 ${sw.elapsed.inSeconds}s, running=${launcher.isRunning}, exit=$code')
          ..writeln('lastErr=$lastErr');
        if (errlines.isNotEmpty) sb.writeln('STDERR:\n${errlines.join('\n')}');
        _lastLaunchDiagnostics = sb.toString();
        _logger.severe(_lastLaunchDiagnostics);
        unawaited(launcher.stop());
        return false;
      }
      _launcherStarted = true;
      _logger.info(
          'RWKV 本地 server 已就绪: port=$port model=$modelFilePath '
          'elapsed=${sw.elapsed.inSeconds}s');
      return true;
    } on Exception catch (e, st) {
      final errlines = launcher.recentStderr.join('\n');
      final sb = StringBuffer('启动异常：$e')
        ..writeln('耗时 ${sw.elapsed.inSeconds}s');
      if (errlines.isNotEmpty) sb.writeln('STDERR:\n$errlines');
      sb.writeln('stacktrace:\n$st');
      _lastLaunchDiagnostics = sb.toString();
      _logger.severe(_lastLaunchDiagnostics);
      return false;
    }
  }

  /// 扫描本地模型目录。
  Future<List<RwkvLocalModel>> scanLocalModels() async {
    try {
      // await 后异步异常才能落入 catch 返回空表，而不是变成未处理异步错误。
      return await _modelScanner.scan(config.modelsDir);
    } catch (e, st) {
      _logger.warning('扫描本地 RWKV 模型失败', e, st);
      return const <RwkvLocalModel>[];
    }
  }

  /// 关闭会话（回收 state）。
  bool closeSession(String sessionId) => _sessionManager.close(sessionId);

  // ---------- 公共：核心推理 ----------

  /// 会话化非流式推理（推荐）。
  ///
  /// [sessionId] 传入 = 在该会话内派生 state；不传入 = 一次性临时会话。
  Future<RwkvEngineResult> chatWithSession(
    ChatRequest request, {
    String? sessionId,
    String sessionLabel = '',
  }) async {
    final session = _sessionManager.getOrCreate(sessionId, label: sessionLabel);
    return session.runSerialized(() async {
      await _semaphore.acquire();
      try {
        return await _runOneTurn(request, session);
      } finally {
        _semaphore.release();
      }
    });
  }

  /// 会话化流式推理（推荐）。
  Future<RwkvEngineResult> chatStreamWithSession(
    ChatRequest request,
    void Function(ChatChunk) onChunk, {
    String? sessionId,
    String sessionLabel = '',
  }) async {
    final session = _sessionManager.getOrCreate(sessionId, label: sessionLabel);
    return session.runSerialized(() async {
      await _semaphore.acquire();
      try {
        return await _runOneTurnStreaming(request, session, onChunk);
      } finally {
        _semaphore.release();
      }
    });
  }

  /// 一次性裸推理（无 state 复用）。保留给 Provider 层的 legacy 接口用。
  Future<ChatResponse> chatOnce(ChatRequest request) async {
    final r = await chatWithSession(request);
    return r.chat;
  }

  /// 一次性裸流式推理。
  Future<ChatResponse> chatStreamOnce(
    ChatRequest request,
    void Function(ChatChunk) onChunk,
  ) async {
    final r = await chatStreamWithSession(request, onChunk);
    return r.chat;
  }

  /// 原始 prompt 补全 —— 对应 C# `IRwkvLightningService.CompleteAsync(prompt, maxTokens)`。
  ///
  ///  为什么不能复用 [chatWithSession]：调用方传入的 [prompt] **已经自带**
  /// `User: … \n\nAssistant:  thinking</think` 完整模板（C# 侧就是这么硬拼的，
  /// 见 `PrerequisiteGenerationService` 的修炼体系生成）。走 chat 通道会被再包一层
  /// `messages` 模板，小模型几乎必然跑偏。这里走 `contents`（纯文本数组）通道，
  /// 服务端原样续写。
  ///
  /// 采样参数：只暴露 `temperature / topP / topK`；RWKV 原生的
  /// `alpha_presence` / `alpha_frequency` / `alpha_decay` / `stop_tokens` / `chunk_size`
  /// 由 [config] 的 `nativeOptions` 提供（**不额外暴露 presence/frequency penalty**——
  /// 那两个是 OpenAI 系参数名，原生路由不认，传了会被静默忽略 = 假开关）。
  ///
  /// 失败/不可用时返回 null（调用方回退代码内置模板），绝不抛异常。
  Future<String?> rawCompletion(
    String prompt, {
    int maxTokens = 2048,
    double temperature = 0.9,
    double topP = 0.85,
    int topK = 0,
  }) async {
    final String text = prompt;
    if (text.trim().isEmpty) return null;

    // 并发闸对齐 chatWithSession：rawCompletion 是引擎内唯一绕过 _semaphore
    // 的推理入口（工作流的 Agent 前置探测/一次性生成都会走这里），
    // 并发风暴时同样会打满本地 HTTP 在途。
    await _semaphore.acquire();
    try {
      return await _rawCompletionLocked(
        text,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        topK: topK,
      );
    } finally {
      _semaphore.release();
    }
  }

  Future<String?> _rawCompletionLocked(
    String text, {
    int maxTokens = 2048,
    double temperature = 0.9,
    double topP = 0.85,
    int topK = 0,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'contents': <String>[text],
      'stream': false,
      'max_tokens': maxTokens < 1 ? 1 : maxTokens,
      'temperature': temperature.clamp(0.0, 2.0),
      'top_p': topP,
    };
    if (topK > 0) body['top_k'] = topK;
    // 防复读采样参数（RWKV alpha_* + llama.cpp DRY）打底，调用方显式给的值优先。
    // 与 chat 通道保持一致：长文生成最容易踩的坑就是复读。
    aiRuntimeSettings
        .samplingParams()
        .forEach((String k, Object? v) => body.putIfAbsent(k, () => v));
    // 原生生成参数（含 stop_tokens：批量/contents 路由不传它会返回空文本）展平到顶层。
    // 调用方显式给的值优先。
    config.nativeOptions
        .toRequestBody()
        .forEach((String k, dynamic v) => body.putIfAbsent(k, () => v));

    try {
      final http.Response resp = await _client.post(
        Uri.parse(_endpoint('chat/completions')),
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _logger.warning('rawCompletion 失败：HTTP ${resp.statusCode}');
        return null;
      }
      final Object? parsed = jsonDecode(resp.body);
      if (parsed is! Map<String, dynamic>) return null;
      final List<dynamic> choicesRaw =
          parsed['choices'] as List<dynamic>? ?? const <dynamic>[];
      if (choicesRaw.isEmpty) return null;
      final Map<String, dynamic> first =
          choicesRaw.first as Map<String, dynamic>;
      // 兼容两种响应形态：`choices[0].text`（completions 风格）
      // 与 `choices[0].message.content`（chat 风格）。
      final String raw = (first['text'] as String?) ??
          ((first['message'] as Map<String, dynamic>?)?['content'] as String?) ??
          '';
      return raw.isEmpty ? null : raw;
    } on Object catch (e) {
      _logger.warning('rawCompletion 异常：$e');
      return null;
    }
  }

  /// 用「重放转录本」重建服务端 state —— **P4-27 的真正实现**。
  ///
  /// ⚠ 为什么不是"恢复 state 字节"：rwkv_lightning **没有 state 导出端点**，
  /// 客户端 `RwkvState.bytes` 一直是 `Uint8List(0)` 假占位（旧实现的
  /// `takeSnapshot`/`restoreSnapshot` 据此写的 `POST $base/state`、
  /// `GET $base/state?session=` 两个端点**实测都是 404**，且从未被调用过）。
  /// 所以"存几 MB state 字节、下次直接恢复"物理上不可实现。
  ///
  /// 正确做法：把**对话转录本**重放一次进 `/state/chat/completions`
  /// （付一次 prefill）重建服务端 state，之后每轮继续 O(1) 增量。
  ///
  /// 成功后：
  ///   - 服务端已为 [sessionId] 建好 state（后续轮只发增量即可）
  ///   - 本地 `session.history` 被填上这些轮次（增量判定依赖它非空）
  ///
  /// [maxTokens] 默认 1：重放只为建 state，不需要生成内容。
  Future<bool> replayTranscript(
    String sessionId,
    List<RwkvArchivedTurn> turns, {
    int maxTokens = 1,
  }) async {
    if (turns.isEmpty) return false;
    final session = _sessionManager.getOrCreate(sessionId);
    // 拼成经典单条 prompt（与 _buildStatefulPrompt 同一格式，system 内联）
    final StringBuffer sb = StringBuffer();
    for (final RwkvArchivedTurn t in turns) {
      final String text = t.content.trim();
      if (text.isEmpty) continue;
      switch (t.role) {
        case 'user':
          sb.write('User: $text\n\n');
        case 'assistant':
          sb.write('Assistant: $text\n\n');
        case 'system':
          sb.write('System: $text\n\n');
      }
    }
    sb.write('Assistant:');

    try {
      final resp = await _client.post(
        Uri.parse(_stateEndpoint('chat/completions')),
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'session_id': sessionId,
          'contents': <String>[sb.toString()],
          'stream': false,
          'max_tokens': maxTokens < 1 ? 1 : maxTokens,
          'stop_tokens': const <int>[0, 261, 24281],
        }),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _logger.warning('重放转录本失败: HTTP ${resp.statusCode}');
        return false;
      }
      // 本地会话补齐历史：让后续轮走「只发增量」的分支
      session.resetHistory();
      for (final RwkvArchivedTurn t in turns) {
        switch (t.role) {
          case 'user':
            session.appendMessage(ChatMessage.user(t.content));
          case 'assistant':
            session.appendMessage(ChatMessage.assistant(t.content));
          case 'system':
            session.appendMessage(ChatMessage.system(t.content));
        }
      }
      _logger.info('会话 $sessionId 已从转录本重建 state（${turns.length} 轮）');
      return true;
    } catch (e, st) {
      _logger.severe('重放转录本异常', e, st);
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _idleGCTimer?.cancel();
    _sessionManager.closeAll();
    _stateCache.clear();
    // ⚠ 必须连本地 server 进程一起回收。
    //
    // 早期实现只关 client：引擎被重建（改 baseUrl）或 App 退出后，llama-server /
    // rwkv_lightning 进程仍在跑，GPU 显存被长期占用，下一轮拉模型直接 OOM。
    // dispose 是同步签名，这里 fire-and-forget；pid 记录文件保证「App 被强杀」
    // 也能在下次启动时被 reclaimOrphaned 精确回收。
    final launcher = _processLauncher;
    if (launcher != null && launcher.isRunning) {
      _launcherStarted = false;
      unawaited(launcher.stop());
    }
    // 只关自建的 client；外部注入的由注入方负责（见 _ownsClient 注释）
    if (_ownsClient) _client.close();
  }

  // ---------- 内部实现 ----------

  String _configBaseUrl() =>
      config.baseUrl.trim().replaceAll(RegExp(r'/$'), '');

  /// 把消息列表拼成 `rwkv_lightning_cuda` 的**经典单条 prompt**。
  ///
  /// `/state/chat/completions` 只接受**恰好 1 条** `contents`（文档 §9：
  /// 传 2 条直接 `400 Request must contain exactly one prompt`）。
  /// 格式对齐官方示例 `User: ...\n\nAssistant:`；**思考前缀由服务端按
  /// `think_type` 自行追加**，这里绝不手工拼 `<think>`，否则会双重前缀。
  String _buildStatefulPrompt(
    Iterable<ChatMessage> msgs, {
    String? systemPrompt,
  }) {
    final bool hasExternalSystem =
        systemPrompt != null && systemPrompt.trim().isNotEmpty;
    final StringBuffer sb = StringBuffer();
    if (hasExternalSystem) {
      sb.write('System: ${systemPrompt.trim()}\n\n');
    }
    for (final ChatMessage m in msgs) {
      final String text = m.content.trim();
      if (text.isEmpty) continue;
      switch (m.role) {
        case ChatRole.user:
          sb.write('User: $text\n\n');
        case ChatRole.assistant:
          sb.write('Assistant: $text\n\n');
        case ChatRole.system:
          // 有外部 systemPrompt 时跳过，避免重复
          if (!hasExternalSystem) sb.write('System: $text\n\n');
      }
    }
    sb.write('Assistant:');
    return sb.toString();
  }

  /// 构造 `/state/chat/completions` 的请求体（文档 §9）。
  ///
  /// **只发本轮增量**：历史已由服务端按 `session_id` 保在三级缓存
  /// （L1 VRAM / L2 RAM / SQLite）里，这正是 RNN 的 O(1) 上下文接续 ——
  /// 每轮重发全部历史就退化成了 Transformer 式的重编码。
  Map<String, dynamic> _buildStatefulBody(
    ChatRequest request,
    RwkvSession session, {
    required bool stream,
  }) {
    final List<ChatMessage> delta = session.history.isEmpty
        // 首轮：system + 本轮全部消息（服务端从此建立 state）
        ? _mergeWithHistory(request, session)
        // 后续轮：只发本轮的 messages，历史交给服务端 state
        : request.messages;
    final String prompt = _buildStatefulPrompt(
      delta,
      systemPrompt: request.systemPrompt,
    );
    final Map<String, dynamic> body = <String, dynamic>{
      'session_id': session.sessionId,
      'contents': <String>[prompt],
      'stream': stream,
      'temperature': request.temperature.clamp(0.0, 2.0),
      'max_tokens': request.maxTokens,
    };
    config.nativeOptions
        .toRequestBody()
        .forEach((String k, dynamic v) => body.putIfAbsent(k, () => v));
    request.parameters.forEach((String k, dynamic v) {
      // state_id / session_id 不来自 parameters：本路由的会话身份就是 session_id
      if (k == 'state_id' || k == 'session_id') return;
      body[k] = v;
    });
    return body;
  }

  /// 构造 `/v1/*` 路由。
  ///
  /// ⚠ 前缀是 **`/v1`**，**不是 `/openai/v1`** —— 早期实现默认拼成
  /// `/openai/v1/chat/completions`，实测 rwkv_lightning_cuda 上是 **404**
  /// （文档 §3 接口总览也只有 `/v1/chat/completions`）。见 PITFALLS §31.5。
  String _endpoint(String relative) {
    final base = _configBaseUrl();
    final rel = relative.trim().replaceAll(RegExp(r'^/'), '');
    return base.endsWith('/v1') ? '$base/$rel' : '$base/v1/$rel';
  }

  /// 构造 **`/state/*`** 路由（文档 §9）。
  ///
  /// ⚠ 状态类路由**没有 `/v1` 前缀**：是 `/state/chat/completions`、
  /// `/state/status`、`/state/delete`，写成 `/v1/state/...` 会 404。
  String _stateEndpoint(String relative) {
    final base = _configBaseUrl();
    final rel = relative.trim().replaceAll(RegExp(r'^/'), '');
    final root =
        base.endsWith('/v1') ? base.substring(0, base.length - '/v1'.length) : base;
    return '$root/state/$rel';
  }

  Future<RwkvEngineResult> _runOneTurn(
    ChatRequest request,
    RwkvSession session,
  ) async {
    final startTime = DateTime.now();
    // 1) 组装消息：系统 prompt + 会话历史 + 本轮 messages
    final merged = _mergeWithHistory(request, session);
    // 2) 请求体：若有 stateId，透传给 server（llama.cpp / rwkv.cpp 的
    //    OpenAI 兼容层支持 extra body `state_id`，表示「从这个 state 接着跑」）
    final bool useStateful = config.useStatefulRoute;
    final body = useStateful
        ? _buildStatefulBody(request, session, stream: false)
        : _buildChatBody(
            request,
            merged: merged,
            session: session,
            stream: false,
          );
    final tokenEstimate = _estimateTokens(merged);
    try {
      final resp = await _client.post(
        Uri.parse(useStateful
            ? _stateEndpoint('chat/completions')
            : _endpoint('chat/completions')),
        // 走 stateful 路由时**不发** X-RWKV-State-Id：会话身份由 session_id 表达，
        // 服务端按 session_id 维护 state（显式 state_id 会优先于 session 缓存）。
        headers: useStateful
            ? const <String, String>{'Content-Type': 'application/json'}
            : _chatHeaders(session),
        body: jsonEncode(body),
      );
      final elapsed = DateTime.now().difference(startTime);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final err = ChatResponse(
          isSuccess: false,
          errorMessage: 'HTTP ${resp.statusCode}: ${resp.body}',
          responseTime: elapsed,
        );
        return RwkvEngineResult(
          chat: err,
          newStateId: session.currentStateId ?? '',
          tokenDelta: 0,
        );
      }
      final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
      final choices = parsed['choices'] as List<dynamic>? ?? const [];
      final first = choices.isEmpty
          ? null
          : (choices.first as Map<String, dynamic>);
      final msg = first == null ? null : (first['message'] as Map<String, dynamic>?);
      final rawContent = msg == null ? '' : (msg['content'] as String? ?? '');
      final content = AIOutputSanitizer.extractVisibleContent(rawContent);
      final finishReason = first == null ? '' : (first['finish_reason'] as String? ?? 'stop');
      final model = parsed['model'] as String? ?? request.model;

      // 3) 记录 assistant 消息到会话
      session.appendMessage(ChatMessage.assistant(content));

      // 4) 派生 state：从 server 响应 header/body 读取新 stateId；
      //    如果 server 没给，用客户端生成的 ID 作为逻辑占位（保证链不断）。
      final serverStateId = parsed['state_id'] as String? ??
          resp.headers['x-rwkv-state-id'];
      final newStateId = serverStateId ?? rwkvGenerateId('st_');
      final genTokens = content.length ~/ 2; // 中文 ≈ 2 字/token，保守估算
      final tokenDelta = tokenEstimate + genTokens;
      final fakeBytes = Uint8List(0);
      final parentState = session.currentStateId == null
          ? null
          : _stateCache.get(session.currentStateId!);
      final state = RwkvState(
        stateId: newStateId,
        tokenCount: (parentState?.tokenCount ?? 0) + tokenDelta,
        bytes: parentState?.bytes ?? fakeBytes,
        parentStateId: parentState?.stateId,
        sessionId: session.sessionId,
      );
      _stateCache.put(state);
      session.advanceState(newStateId, tokenDelta);

      final chatResp = ChatResponse(
        content: content,
        model: model,
        finishReason: finishReason,
        responseTime: elapsed,
        isSuccess: true,
      );
      return RwkvEngineResult(
        chat: chatResp,
        newStateId: newStateId,
        tokenDelta: tokenDelta,
      );
    } catch (e, st) {
      _logger.severe('RWKV 非流式推理异常', e, st);
      final err = ChatResponse(
        isSuccess: false,
        errorMessage: e.toString(),
        responseTime: DateTime.now().difference(startTime),
      );
      return RwkvEngineResult(
        chat: err,
        newStateId: session.currentStateId ?? '',
        tokenDelta: 0,
      );
    }
  }

  Future<RwkvEngineResult> _runOneTurnStreaming(
    ChatRequest request,
    RwkvSession session,
    void Function(ChatChunk) onChunk,
  ) async {
    final startTime = DateTime.now();
    final merged = _mergeWithHistory(request, session);
    final bool useStateful = config.useStatefulRoute;
    final body = useStateful
        ? _buildStatefulBody(request, session, stream: true)
        : _buildChatBody(
            request,
            merged: merged,
            session: session,
            stream: true,
          );
    final tokenEstimate = _estimateTokens(merged);
    final fullContent = StringBuffer();
    String? finishReason;
    String? serverStateId;

    try {
      final httpRequest = http.Request(
        'POST',
        Uri.parse(useStateful
            ? _stateEndpoint('chat/completions')
            : _endpoint('chat/completions')),
      );
      if (useStateful) {
        httpRequest.headers['Content-Type'] = 'application/json';
      } else {
        httpRequest.headers.addAll(_chatHeaders(session));
      }
      httpRequest.headers['Accept'] = 'text/event-stream';
      httpRequest.body = jsonEncode(body);

      final resp = await _client.send(httpRequest);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final errBody = await resp.stream.bytesToString();
        final err = ChatResponse(
          isSuccess: false,
          errorMessage: 'HTTP ${resp.statusCode}: $errBody',
          responseTime: DateTime.now().difference(startTime),
        );
        return RwkvEngineResult(
          chat: err,
          newStateId: session.currentStateId ?? '',
          tokenDelta: 0,
        );
      }

      // 解析 SSE：`data: {...}` 一行一条；末尾 `data: [DONE]`
      await for (final line
          in resp.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') break;
        try {
          final obj = jsonDecode(payload) as Map<String, dynamic>;
          final choices = obj['choices'] as List<dynamic>? ?? const [];
          if (choices.isEmpty) continue;
          final c0 = choices.first as Map<String, dynamic>;
          final delta = c0['delta'] as Map<String, dynamic>?;
          final content = delta == null ? null : (delta['content'] as String? ?? '');
          final visible = AIOutputSanitizer.extractVisibleContent(content);
          if (visible.isNotEmpty) {
            fullContent.write(visible);
            onChunk(ChatChunk(content: visible, isComplete: false));
          }
          if (c0['finish_reason'] != null) {
            finishReason = c0['finish_reason'] as String?;
          }
          if (obj['state_id'] != null) {
            serverStateId = obj['state_id'] as String;
          }
        } catch (_) {
          // 忽略坏行。
        }
      }
      final elapsed = DateTime.now().difference(startTime);
      final finalContent = fullContent.toString();
      onChunk(ChatChunk(
        isComplete: true,
        finishReason: finishReason ?? 'stop',
      ));

      session.appendMessage(ChatMessage.assistant(finalContent));

      final newStateId = serverStateId ?? rwkvGenerateId('st_');
      final genTokens = finalContent.length ~/ 2;
      final tokenDelta = tokenEstimate + genTokens;
      final parentState = session.currentStateId == null
          ? null
          : _stateCache.get(session.currentStateId!);
      final state = RwkvState(
        stateId: newStateId,
        tokenCount: (parentState?.tokenCount ?? 0) + tokenDelta,
        bytes: parentState?.bytes ?? Uint8List(0),
        parentStateId: parentState?.stateId,
        sessionId: session.sessionId,
      );
      _stateCache.put(state);
      session.advanceState(newStateId, tokenDelta);

      final chatResp = ChatResponse(
        content: finalContent,
        model: request.model,
        finishReason: finishReason ?? 'stop',
        responseTime: elapsed,
        isSuccess: true,
      );
      return RwkvEngineResult(
        chat: chatResp,
        newStateId: newStateId,
        tokenDelta: tokenDelta,
      );
    } catch (e, st) {
      _logger.severe('RWKV 流式推理异常', e, st);
      onChunk(ChatChunk(isComplete: true, finishReason: 'error'));
      final err = ChatResponse(
        isSuccess: false,
        errorMessage: e.toString(),
        content: fullContent.toString(),
        responseTime: DateTime.now().difference(startTime),
      );
      return RwkvEngineResult(
        chat: err,
        newStateId: session.currentStateId ?? '',
        tokenDelta: 0,
      );
    }
  }

  List<ChatMessage> _mergeWithHistory(
    ChatRequest request,
    RwkvSession session,
  ) {
    final out = <ChatMessage>[];
    // 系统 prompt 放在 request 上更清晰，但历史里已有 system 的话会冲突，
    // 这里以 request.systemPrompt 优先，历史中重复的 system 跳过。
    for (final m in session.history) {
      if (m.role == ChatRole.system &&
          (request.systemPrompt?.isNotEmpty ?? false)) {
        continue;
      }
      out.add(m);
    }
    for (final m in request.messages) {
      out.add(m);
    }
    return out;
  }

  int _estimateTokens(List<ChatMessage> msgs) {
    // 简化估算：中文字符 2 字/token，英文单词 1 词/token，换行/标点算 0.2。
    int total = 0;
    for (final m in msgs) {
      final content = m.content;
      final chinese = RegExp(r'[\u4e00-\u9fff]').allMatches(content).length;
      final asciiWords = RegExp(r'[A-Za-z0-9]+').allMatches(content).length;
      total += (chinese / 2 + asciiWords).ceil();
    }
    return total;
  }

  Map<String, dynamic> _buildChatBody(
    ChatRequest request, {
    required List<ChatMessage> merged,
    required RwkvSession session,
    required bool stream,
  }) {
    final messages = <Map<String, dynamic>>[];
    if (request.systemPrompt != null && request.systemPrompt!.isNotEmpty) {
      messages.add({'role': 'system', 'content': request.systemPrompt!});
    }
    for (final m in merged) {
      if (m.role == ChatRole.system &&
          (request.systemPrompt?.isNotEmpty ?? false)) {
        continue;
      }
      messages.add({'role': m.role.name, 'content': m.content});
    }
    final result = <String, dynamic>{
      'model': request.model.isEmpty ? 'rwkv-local' : request.model,
      'messages': messages,
      'temperature': request.temperature.clamp(0.0, 2.0),
      'max_tokens': request.maxTokens,
      'stream': stream,
    };

    // ⚠ 必须**展平到顶层**，不能嵌套成 `extra_body`。
    //
    // 服务端只读顶层字段；实测（PITFALLS §31.1）：把参数字典塞进 `extra_body`
    // 会被静默忽略（多余字段一律容忍、不报错），于是 `think_type` / `top_k` /
    // `alpha_*` / `chunk_size` / `state_id` **全都没到服务端** ——
    // 「State 复用」在旧实现里实际从未生效。
    //
    // 但 `state_id` / `session_id` 这两个**绝不走 body**：
    //   - `state_id`：body 通道服务端会校验，未上传过的 id 直接
    //     HTTP 400 `uploaded state not found`；改走 `X-RWKV-State-Id` 表头
    //     （实测未知 id 被容忍，不报错）。见 [_chatHeaders]，PITFALLS §31.2。
    //   - `session_id`：只属于 `/state/*` 路由，在 `/v1/chat/completions` 上
    //     是无效字段（实测 200 但无任何语义）。
    request.parameters.forEach((String k, dynamic v) {
      if (k == 'state_id' || k == 'session_id') return;
      result[k] = v;
    });

    // RWKV 原生生成参数（文档 §4）同样展平到顶层。
    // `config.nativeOptions` 默认带 `stop_tokens: [0,261,24281]` ——
    // 批量路由不传它会返回空文本（PITFALLS §30.2）。
    // 调用方可在 request.parameters 里覆盖同名键（上面已写入，这里用 putIfAbsent 语义）。
    config.nativeOptions.toRequestBody().forEach((String k, dynamic v) {
      result.putIfAbsent(k, () => v);
    });
    return result;
  }

  /// 会话感知的请求头。
  ///
  /// `state_id` 走 `X-RWKV-State-Id` 表头而非 body：body 通道会校验
  /// 「这个 state 是否已上传」，未上传直接 400；表头通道实测容忍
  /// （PITFALLS §31.2）。这是本引擎与 llama.cpp 兼容层的关键差异。
  Map<String, String> _chatHeaders(RwkvSession session) {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final String? sid = session.currentStateId;
    if (sid != null && sid.isNotEmpty) {
      headers['X-RWKV-State-Id'] = sid;
    }
    return headers;
  }
}
