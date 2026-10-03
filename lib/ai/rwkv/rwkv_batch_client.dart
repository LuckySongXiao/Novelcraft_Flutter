// RWKV 批量补全传输层：SSE `index` 分组 + 实测校准过的重试策略。
//
// ⚠ 两条来自实测的硬约束（PITFALLS §27.3 / §31.3 / §31.4）：
//
//  1. **SSE 里不同 `index` 的事件会交错到达**（GPU warp 调度决定，不是 0→1→2）。
//     必须 `Map<int, StringBuffer>` 按 index 分组，**绝不能按到达顺序 append**
//     ——否则世界观分支 A/B/C 的内容会混成一锅粥。
//
//  2. **重试对象不是 429**（服务端错误码表里根本没有 429，只有 200/204/400/401/404/500）。
//     真正要处理的是四类：
//       a. `400 {"error":"bsz overflow, Max bsz=N","request_bsz":M}` → **拆小重试**
//       b. `500` → 指数退避
//       c. **HTTP 200 但 body 是 `{"error":"..."}`**（SSE 运行时异常也走 200！）→ 重试
//       d. 响应**条数不足 / JSON 被截断**（实测 N=16 时 UTF-8 从中间断掉）→ 子集重试
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/batch_chat.dart';
import '../observability/ai_runtime_stats.dart';
import 'rwkv_concurrency.dart';

/// 一次批量调用的进度（流式）。
class RwkvBatchProgress {
  /// 已收到内容的槽位号 → 文本
  final Map<int, String> partial;

  /// 已完成（收到 finish_reason）的槽位
  final Set<int> finished;

  /// 是否全部完成
  final bool done;

  /// `multi_state` 路由回传的新 dialogue_idx（非该路由时为 null）
  final int? dialogueIdx;

  const RwkvBatchProgress({
    required this.partial,
    required this.finished,
    this.done = false,
    this.dialogueIdx,
  });
}

/// 批量补全客户端。
class RwkvBatchClient {
  final http.Client client;

  /// 基础地址（不含 `/v1`，由 [route] 决定前缀）
  final String Function() baseUrl;

  /// 每次请求的公共头（CF Access Service Token 等）
  final Map<String, String> Function() headers;

  /// 并发容量控制器。
  ///
  /// **不是 final**：控制器本身需要一个「读 `/v1/server/status`」的 probe，
  /// 而那个 probe 用的就是这个 client —— 构成双向依赖，只能两段式装配：
  /// 先 new client，再 new controller(probe: client.capacity)，最后回填这里。
  RwkvConcurrencyController? concurrency;

  /// 运行时指标（P4-26 健康面板）。null = 不统计。
  AiRuntimeStats? stats;

  /// 指标里记录的 Provider 名。
  String statsProvider;

  final Logger _logger;

  /// 最多重试次数（不含首次）
  final int maxRetries;

  /// 退避基准（`retryBaseDelay * 2^n`，上限 8s）
  final Duration retryBaseDelay;

  /// 因 `bsz overflow` 自动折半的最大递归深度（防止无限拆）
  final int maxSplitDepth;

  RwkvBatchClient({
    required this.client,
    required this.baseUrl,
    required this.headers,
    this.concurrency,
    this.maxRetries = 3,
    this.retryBaseDelay = const Duration(milliseconds: 400),
    this.maxSplitDepth = 4,
    Logger? logger,
    this.stats,
    this.statsProvider = 'RWKV',
  }) : _logger = logger ?? Logger('RwkvBatchClient');

  String _url(String route) {
    final String base = baseUrl().trim().replaceAll(RegExp(r'/$'), '');
    final String rel = route.trim().replaceAll(RegExp(r'^/'), '');
    // `/v1/*` 与 `/state/*`、`/multi_state/*` 是两套前缀规则（PITFALLS §32.1）
    if (rel.startsWith('v1/') ||
        rel.startsWith('state/') ||
        rel.startsWith('multi_state/') ||
        rel.startsWith('translate/') ||
        rel.startsWith('openai/')) {
      final String root = base.endsWith('/v1')
          ? base.substring(0, base.length - 3)
          : base;
      return '$root/$rel';
    }
    return base.endsWith('/v1') ? '$base/$rel' : '$base/v1/$rel';
  }

  Map<String, String> _requestHeaders({bool sse = false}) => <String, String>{
    'Content-Type': 'application/json',
    if (sse) 'Accept': 'text/event-stream',
    ...headers(),
  };

  // -------------------------------------------------------------------------
  // 非流式批量
  // -------------------------------------------------------------------------

  /// 执行一次批量补全，返回**按 index 对齐**的内容列表（长度 = contents.length）。
  ///
  /// 内部会自动处理 4 类失败（见文件头注释）：`bsz overflow` 拆小、
  /// 5xx 退避、200+error 重试、条数不足子集重试。
  Future<List<String?>> chat(RwkvBatchRequest request) async {
    _logger.info(
      '批量补全 ${request.contents.length} 条'
      '（max_tokens=${request.maxTokens} stream=false）',
    );
    final Stopwatch sw = Stopwatch()..start();
    // 统计**实际**发出的 POST 次数：拆批/子集重试都会让它 > 1，
    // 这正是面板要暴露的"拆批开销"（PITFALLS §33.2）。
    int posts = 0;
    try {
      final List<String?> out = await _chatWithRetry(
        request,
        depth: 0,
        onPost: () => posts++,
      );
      sw.stop();
      stats?.record(
        AiRequestSample(
          provider: statsProvider,
          operation: 'batch',
          success: true,
          latency: sw.elapsed,
          itemCount: request.contents.length,
          httpPosts: posts,
        ),
      );
      return out;
    } on RwkvBatchException catch (e) {
      sw.stop();
      stats?.record(
        AiRequestSample(
          provider: statsProvider,
          operation: 'batch',
          success: false,
          latency: sw.elapsed,
          itemCount: request.contents.length,
          // 直接用失败分类名：面板上「该拆批」和「该换 Token」天然分开
          failureKind: e.kind.name,
          httpPosts: posts,
        ),
      );
      rethrow;
    } on Object {
      sw.stop();
      stats?.record(
        AiRequestSample(
          provider: statsProvider,
          operation: 'batch',
          success: false,
          latency: sw.elapsed,
          itemCount: request.contents.length,
          failureKind: 'unexpected',
          httpPosts: posts,
        ),
      );
      rethrow;
    }
  }

  Future<List<String?>> _chatWithRetry(
    RwkvBatchRequest request, {
    required int depth,
    int attempt = 0,
    void Function()? onPost,
  }) async {
    final int n = request.contents.length;
    if (n == 0) return <String?>[];

    // 功能：动态并发许可 —— 吃满服务端容量的同时防本地在途失控
    await concurrency?.waitForPermit();
    concurrency?.enterInFlight();
    http.Response? resp;
    try {
      onPost?.call();
      resp = await client
          .post(
            Uri.parse(_url(kRouteRwkvBatchCompletions)),
            headers: _requestHeaders(),
            body: jsonEncode(request.toJson()),
          )
          .timeout(Duration(seconds: 60 + 20 * n));
    } on Object catch (e) {
      concurrency?.leaveInFlight();
      final RwkvBatchException ex = RwkvBatchException(
        kind: RwkvBatchFailureKind.network,
        message: '网络异常：$e',
      );
      return _handleFailure(
        request,
        ex,
        depth: depth,
        attempt: attempt,
        onPost: onPost,
      );
    }
    concurrency?.leaveInFlight();

    final String body = resp.body;

    // --- 认证失败：CF 把 HTML 当响应体（不是 401，而是 403/200 + HTML）---
    if (body.trimLeft().startsWith('<')) {
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.authFailed,
        statusCode: resp.statusCode,
        message:
            'Cloudflare Access 认证失败：返回的是 HTML 而不是 JSON。'
            '请检查 CF-Access-Client-Id / CF-Access-Client-Secret 的精确大小写。'
            '（PITFALLS §27.2）前 160 字：'
            '${body.length > 160 ? body.substring(0, 160) : body}',
      );
    }

    Map<String, dynamic>? json;
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException catch (e) {
      // --- 截断：实测 N=16 时 UTF-8 从中间断掉 ---
      return _handleFailure(
        request,
        RwkvBatchException(
          kind: RwkvBatchFailureKind.truncated,
          statusCode: resp.statusCode,
          message: 'JSON 解析失败（疑似响应被截断）：$e',
        ),
        depth: depth,
        attempt: attempt,
        onPost: onPost,
      );
    }

    // --- 400 bsz overflow：拆小重试 ---
    if (resp.statusCode == 400) {
      final int? maxBsz = (json?['max_bsz'] as num?)?.toInt();
      final int? reqBsz = (json?['request_bsz'] as num?)?.toInt();
      if (maxBsz != null || reqBsz != null) {
        concurrency?.noteBszOverflow(n, maxBsz);
        return _handleFailure(
          request,
          RwkvBatchException(
            kind: RwkvBatchFailureKind.bszOverflow,
            statusCode: 400,
            maxBsz: maxBsz,
            requestBsz: reqBsz ?? n,
            message: 'bsz overflow, Max bsz=$maxBsz',
          ),
          depth: depth,
          attempt: attempt,
        );
      }
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.fatal,
        statusCode: 400,
        message: '参数错误 400：$body',
      );
    }

    // --- 5xx：退避重试 ---
    if (resp.statusCode >= 500) {
      return _handleFailure(
        request,
        RwkvBatchException(
          kind: RwkvBatchFailureKind.serverError,
          statusCode: resp.statusCode,
          message: '服务端错误：$body',
        ),
        depth: depth,
        attempt: attempt,
        onPost: onPost,
      );
    }

    if (resp.statusCode == 404) {
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.fatal,
        statusCode: 404,
        message: '路由不存在（$kRouteRwkvBatchCompletions）：$body',
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.fatal,
        statusCode: resp.statusCode,
        message: 'HTTP ${resp.statusCode}: $body',
      );
    }

    // --- HTTP 200 但 body 是 {"error": ...}：SSE 运行时异常也走 200 ---
    final Object? errField = json?['error'];
    if (errField != null) {
      return _handleFailure(
        request,
        RwkvBatchException(
          kind: RwkvBatchFailureKind.runtimeErrorEvent,
          statusCode: 200,
          message: '服务端运行时错误（HTTP 200）：$errField',
        ),
        depth: depth,
        attempt: attempt,
        onPost: onPost,
      );
    }

    if (json == null) {
      return _handleFailure(
        request,
        const RwkvBatchException(
          kind: RwkvBatchFailureKind.truncated,
          message: '响应不是 JSON 对象',
        ),
        depth: depth,
        attempt: attempt,
        onPost: onPost,
      );
    }

    final RwkvBatchResponse parsed = RwkvBatchResponse.fromJson(json);
    final List<int> missing = parsed.missingIndices(n);
    if (missing.isNotEmpty) {
      // --- 条数不足：子集重试（只重发缺的槽位）---
      _logger.warning('批量返回缺 ${missing.length}/$n 个槽位，子集重试：$missing');
      final List<String?> out = parsed.contentsByIndex(n);
      if (depth >= maxSplitDepth || attempt >= maxRetries) {
        _logger.severe('子集重试达到上限，缺失槽位将保持为空：$missing');
        return out;
      }
      final RwkvBatchRequest sub = request.subset(missing);
      final List<String?> subOut = await _chatWithRetry(
        sub,
        depth: depth + 1,
        attempt: attempt + 1,
        onPost: onPost,
      );
      for (int i = 0; i < missing.length; i++) {
        out[missing[i]] = subOut.length > i ? subOut[i] : null;
      }
      return out;
    }

    concurrency?.noteSuccess();
    return parsed.contentsByIndex(n);
  }

  /// 四类可重试失败的统一处置。
  Future<List<String?>> _handleFailure(
    RwkvBatchRequest request,
    RwkvBatchException ex, {
    required int depth,
    required int attempt,
    void Function()? onPost,
  }) async {
    final int n = request.contents.length;

    // ① bsz overflow → 折半拆分（不是退避等待）
    if (ex.kind == RwkvBatchFailureKind.bszOverflow) {
      if (n <= 1 || depth >= maxSplitDepth) {
        throw ex; // 单条都塞不下 → 交给上层
      }
      final int suggested = ex.suggestedBatchSize() ?? (n ~/ 2).clamp(1, n);
      final int half = suggested < n ? suggested : (n ~/ 2).clamp(1, n);
      _logger.warning('并发超限，把 $n 条拆成 $half + ${n - half} 条重试');
      final List<String?> head = await _chatWithRetry(
        request.subset(<int>[for (int i = 0; i < half; i++) i]),
        depth: depth + 1,
        attempt: attempt,
        onPost: onPost,
      );
      final List<String?> tail = await _chatWithRetry(
        request.subset(<int>[for (int i = half; i < n; i++) i]),
        depth: depth + 1,
        attempt: attempt,
        onPost: onPost,
      );
      return <String?>[...head, ...tail];
    }

    // ② 其余可重试 → 指数退避
    if (ex.isRetryable && attempt < maxRetries) {
      final Duration delay = _backoff(attempt);
      _logger.warning(
        '${ex.kind.name} 第 ${attempt + 1} 次重试，'
        '${delay.inMilliseconds}ms 后：${ex.message}',
      );
      await Future<void>.delayed(delay);
      return _chatWithRetry(
        request,
        depth: depth,
        attempt: attempt + 1,
        onPost: onPost,
      );
    }

    throw ex;
  }

  Duration _backoff(int attempt) {
    final int ms = retryBaseDelay.inMilliseconds * (1 << attempt);
    return Duration(milliseconds: ms > 8000 ? 8000 : ms);
  }

  // -------------------------------------------------------------------------
  // 流式批量
  // -------------------------------------------------------------------------

  /// 流式批量补全。
  ///
  /// yield 的是**累积快照**（已收内容 + 已结束槽位），方便 UI 实时刷新；
  /// 结束时最后一个事件的 `done=true` 且 `partial` 已按 index 对齐。
  Stream<RwkvBatchProgress> chatStream(RwkvBatchRequest request) async* {
    final int n = request.contents.length;
    final Stopwatch sw = Stopwatch()..start();
    _logger.info(
      '流式批量补全 $n 条（chunk_size=${request.chunkSize ?? kRwkvDefaultBatchChunkSize}）',
    );
    // ⚠ SSE 里不同 index 交错到达 → 按 index 分组，绝不按到达顺序 append
    final Map<int, StringBuffer> buffers = <int, StringBuffer>{
      for (int i = 0; i < n; i++) i: StringBuffer(),
    };
    final Set<int> finished = <int>{};
    int? dialogueIdx;

    final http.Request req = http.Request(
      'POST',
      Uri.parse(_url(kRouteRwkvBatchCompletions)),
    );
    req.headers.addAll(_requestHeaders(sse: true));
    req.body = jsonEncode(request.toJson());

    // 功能：动态并发许可 —— 吃满服务端容量的同时防本地在途失控
    await concurrency?.waitForPermit();
    concurrency?.enterInFlight();
    http.StreamedResponse resp;
    try {
      resp = await client.send(req);
    } catch (_) {
      concurrency?.leaveInFlight();
      rethrow;
    }

    try {
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final String body = await resp.stream.bytesToString();
        throw RwkvBatchException(
          kind: resp.statusCode >= 500
              ? RwkvBatchFailureKind.serverError
              : RwkvBatchFailureKind.fatal,
          statusCode: resp.statusCode,
          message: '流式请求失败：$body',
        );
      }

      final StringBuffer raw = StringBuffer();
      await for (final String line
          in resp.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        if (!line.startsWith('data:')) continue;
        final String payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;
        raw.write(payload);

        Map<String, dynamic>? ev;
        try {
          final Object? d = jsonDecode(payload);
          if (d is Map<String, dynamic>) ev = d;
        } on FormatException {
          continue; // 半行/截断的 chunk，跳过（最后会由 done 事件兜）
        }
        if (ev == null) continue;

        // multi_state 的 dialogue_idx 元数据事件
        if (ev['object'] == 'multi_state.dialogue_idx') {
          dialogueIdx = (ev['dialogue_idx'] as num?)?.toInt();
          continue;
        }

        // ⚠ HTTP 200 也可能塞 error 事件
        final Object? err = ev['error'];
        if (err != null) {
          throw RwkvBatchException(
            kind: RwkvBatchFailureKind.runtimeErrorEvent,
            statusCode: 200,
            message: '流式运行时错误事件：$err',
          );
        }

        final Object? choices = ev['choices'];
        if (choices is! List) continue;
        for (final Object? c in choices) {
          if (c is! Map<String, dynamic>) continue;
          final RwkvBatchChoice ch = RwkvBatchChoice.fromJson(c);
          if (ch.index < 0 || ch.index >= n) continue;
          final String? text = ch.content;
          if (text != null && text.isNotEmpty) {
            buffers[ch.index]!.write(text);
          }
          if (ch.finishReason != null) finished.add(ch.index);
        }
        yield RwkvBatchProgress(
          // 每次吐的是**累积快照**，不是增量
          partial: <int, String>{
            for (final MapEntry<int, StringBuffer> e in buffers.entries)
              e.key: e.value.toString(),
          },
          finished: Set<int>.unmodifiable(finished),
          dialogueIdx: dialogueIdx,
        );
      }

      // 完整性校验：断流/槽位未收齐时绝不能静默当成功（PITFALLS §31.4 实测会截断）。
      // 缺槽只告警与统计 —— 不在此重试：调用方已收到部分快照，补拉语义由上层决定。
      final List<int> unfinished = <int>[
        for (int i = 0; i < n; i++)
          if (!finished.contains(i)) i,
      ];
      if (unfinished.isNotEmpty) {
        _logger.warning(
          '流式批量结束但有 ${unfinished.length}/$n 个槽位未收到 finish：$unfinished'
          '（连接可能中断；上层应把对应槽位视为缺失，勿静默成文）',
        );
      } else {
        concurrency?.noteSuccess();
      }
      stats?.record(
        AiRequestSample(
          provider: statsProvider,
          operation: 'batchStream',
          success: unfinished.isEmpty,
          latency: sw.elapsed,
          itemCount: n,
          failureKind: unfinished.isEmpty ? null : 'truncated',
          httpPosts: 1,
        ),
      );
      yield RwkvBatchProgress(
        partial: <int, String>{
          for (final MapEntry<int, StringBuffer> e in buffers.entries)
            e.key: e.value.toString(),
        },
        finished: Set<int>.unmodifiable(finished),
        done: true,
        dialogueIdx: dialogueIdx,
      );
    } finally {
      concurrency?.leaveInFlight();
    }
  }

  // -------------------------------------------------------------------------
  // 引擎状态
  // -------------------------------------------------------------------------

  /// 取 `/v1/server/status`（能力 / 显存 / 队列 / 吞吐）。
  Future<Map<String, dynamic>?> serverStatus() async {
    try {
      final http.Response resp = await client
          .get(Uri.parse(_url(kRouteRwkvServerStatus)), headers: headers())
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      if (resp.body.trimLeft().startsWith('<')) return null;
      final Object? d = jsonDecode(resp.body);
      return d is Map<String, dynamic> ? d : null;
    } on Object catch (e) {
      _logger.fine('取 server/status 失败：$e');
      return null;
    }
  }

  /// 只取容量部分（给 [RwkvConcurrencyController] 当 probe 用）。
  Future<RwkvServerCapacity?> capacity() async {
    final Map<String, dynamic>? st = await serverStatus();
    return st == null ? null : RwkvServerCapacity.fromStatus(st);
  }

  /// 通用 JSON POST（给 `/state/*`、`/multi_state/*` 这类非批量路由复用）。
  ///
  /// 统一处理四件事，避免每个调用点各写一遍：
  ///   1. **HTML 预检** —— CF 认证失败时返回的是登录页 HTML，不是 JSON（PITFALLS §27.2）
  ///   2. **HTTP 200 但 body 是 `{"error":...}`** —— SSE 运行时异常也走 200（§31.3）
  ///   3. 非 2xx 时抛出带状态码的异常，**绝不静默返回 null**
  ///   4. **并发门控下沉**（交接文档遗留）：非批量路由此前完全不过
  ///      waitForPermit —— 多会话并发写 state 时会无上限直压移动端
  ///      内存/套接字；现在与批量路径共用同一许可闸（min(硬上限, 服务端
  ///      available, 排队折半, 惩罚档)），超限排队而非裸发。
  Future<Map<String, dynamic>> postJson(
    String route,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    await concurrency?.waitForPermit();
    concurrency?.enterInFlight();
    try {
      final http.Response resp = await client
          .post(
            Uri.parse(_url(route)),
            headers: _requestHeaders(),
            body: jsonEncode(body),
          )
          .timeout(timeout);
      concurrency?.noteSuccess();
      return _parsePostJsonResponse(resp, route);
    } finally {
      concurrency?.leaveInFlight();
    }
  }

  Map<String, dynamic> _parsePostJsonResponse(
    http.Response resp,
    String route,
  ) {
    final String text = resp.body;
    if (text.trimLeft().startsWith('<')) {
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.authFailed,
        statusCode: resp.statusCode,
        message:
            'Cloudflare Access 认证失败：收到 HTML 而非 JSON。'
            '检查 CF-Access-Client-Id / CF-Access-Client-Secret 的精确大小写。'
            '前 160 字：${text.length > 160 ? text.substring(0, 160) : text}',
      );
    }
    Map<String, dynamic>? json;
    try {
      final Object? d = jsonDecode(text);
      if (d is Map<String, dynamic>) json = d;
    } on FormatException catch (e) {
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.truncated,
        statusCode: resp.statusCode,
        message: 'JSON 解析失败（疑似截断）：$e',
      );
    }
    if (resp.statusCode == 404) {
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.fatal,
        statusCode: 404,
        message:
            '路由不存在：$route（官方标为「可选」的能力，'
            '请先用 routeExists() 探测；PITFALLS §31.5）',
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw RwkvBatchException(
        kind: resp.statusCode >= 500
            ? RwkvBatchFailureKind.serverError
            : RwkvBatchFailureKind.fatal,
        statusCode: resp.statusCode,
        message: 'HTTP ${resp.statusCode}: $text',
      );
    }
    final Object? err = json?['error'];
    if (err != null) {
      throw RwkvBatchException(
        kind: RwkvBatchFailureKind.runtimeErrorEvent,
        statusCode: 200,
        message: '服务端运行时错误（HTTP 200）：$err',
      );
    }
    return json ?? <String, dynamic>{};
  }

  /// 能力探测：某条路由是否存在（用 OPTIONS/最小请求判 404）。
  ///
  /// 用途：`/multi_state/chat/completions`、`/v2/chat/completions`、
  /// `/big_batch/completions` 等都是官方标「**可选**」的能力，
  /// **线上 1.3.0 实测 404** —— 用之前必须先探（PITFALLS §31.5）。
  Future<bool> routeExists(String route) async {
    try {
      final http.Response resp = await client
          .post(
            Uri.parse(_url(route)),
            headers: _requestHeaders(),
            body: jsonEncode(<String, dynamic>{}),
          )
          .timeout(const Duration(seconds: 15));
      // 404 → 不存在；400/422 → 存在但参数不对（正是我们要的"存在"信号）
      return resp.statusCode != 404;
    } on Object catch (e) {
      _logger.fine('探测路由 $route 失败：$e');
      return false;
    }
  }
}
