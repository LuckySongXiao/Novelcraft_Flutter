// AI 运行时指标聚合（P4-26 健康面板的数据源）。
//
// 设计原则：**纯 Dart，零 Flutter 依赖**。
//
// 理由不是洁癖 —— 本项目的沙箱跑不了 `flutter test`（reg.EXE 黑名单），
// 把「指标算得对不对」这件事放进无 Flutter 的模块，就能用
// `dart run tool/verify_ai_stats.dart` 真跑一遍验证百分位、滚动 QPS、
// 分桶过期这些**最容易悄悄算错**的地方。而百分位算错是最危险的：
// 它不会报错，只会给你一个看起来合理的错数，然后你照着错数去调并发。
//
// 三条来自实测的指标设计约束（PITFALLS §31.3 / §32.6 / §33.2）：
//   1. **必须区分「逻辑调用」与「HTTP POST」**：一次 8 槽批量 = 1 次 POST，
//      但服务端 400 bsz overflow 后自动拆成 2 次 —— 不分开统计就
//      既看不出批量收益、也看不出拆批开销。
//   2. **失败必须按原因分类**：`bsz overflow`（要拆批）和 `CF 认证失败`
//      （要改 Token）是完全不同的处置，平均成一个"失败率"就没用了。
//   3. **State 命中要分客户端/服务端两侧**：客户端只有「内存命中 / 未命中」；
//      服务端的 L1 VRAM / L2 RAM / SQLite 三级是**另一个进程**的事，
//      且多节点部署下 `state/status` 可能问到别的节点（PITFALLS §32.6）。
//      两侧分开呈现，别混成一个"命中率"。
library;

import 'dart:collection';

/// 一次逻辑调用的观测样本。
class AiRequestSample {
  /// Provider 名（`RWKV Cloud` / `RWKV` / `DeepSeek`…）
  final String provider;

  /// 操作类型：`chat` / `batch` / `batchStream` / `stateful` / `multiState` /
  /// `testConnection` / `serverStatus`
  final String operation;

  final bool success;

  /// 端到端耗时（含拆批重试的全部时间）
  final Duration latency;

  /// 处理条目数（批量 = 槽位数；单路 = 1）
  final int itemCount;

  /// 失败分类（成功时为 null）。建议直接用 `RwkvBatchFailureKind.name`，
  /// 这样「该拆批」和「该换 Token」在面板上天然分开。
  final String? failureKind;

  /// 该逻辑调用**实际发出**的 HTTP POST 次数（拆批后才 > 1）。
  final int httpPosts;

  const AiRequestSample({
    required this.provider,
    required this.operation,
    required this.success,
    required this.latency,
    this.itemCount = 1,
    this.failureKind,
    this.httpPosts = 1,
  });
}

/// 延迟统计（毫秒）。
class AiLatencyStats {
  final int count;
  final double p50;
  final double p95;
  final double p99;
  final double max;
  final double avg;

  const AiLatencyStats({
    this.count = 0,
    this.p50 = 0,
    this.p95 = 0,
    this.p99 = 0,
    this.max = 0,
    this.avg = 0,
  });

  static const AiLatencyStats empty = AiLatencyStats();

  bool get hasData => count > 0;

  /// p95 与 p50 的比值 —— 「长尾严重度」。
  ///
  /// 批量工作流最怕长尾：p50 很漂亮但 p95 是它的 10 倍，整条流水线就是在等那
  /// 最慢的一次。只看平均值会完全看不出来。
  double get tailRatio => p50 > 0 ? p95 / p50 : 0;
}

/// 一次快照（面板直接消费）。
class AiStatsSnapshot {
  /// 滚动 60s 请求速率（逻辑调用/秒）
  final double qps;

  /// 滚动 60s 吞吐速率（条目/秒，批量按槽位数计）
  final double itemsPerSecond;

  final int totalCalls;
  final int successCalls;
  final int failedCalls;

  /// 失败分类计数（`failureKind` → 次数）
  final Map<String, int> failuresByKind;

  /// 按 Provider 拆分的调用数
  final Map<String, int> callsByProvider;

  final AiLatencyStats latency;

  /// 逻辑调用数（一次批量 = 1）
  final int logicalCalls;

  /// 处理的**条目**总数（批量按槽位数累加；单路 = 1）
  ///
  /// ⚠ 这是攒批收益的正确分母：8 个 Agent 合成 1 次 POST，
  /// 是「8 个条目 / 1 次 POST」，不是「8 次调用 / 1 次 POST」。
  final int totalItems;

  /// 实际发出的 HTTP POST 次数（拆批后 > 逻辑调用数）
  final int httpPosts;

  /// 攒批省下的 HTTP 往返次数 = 条目数 - POST 数
  ///
  /// 8 个 Agent 一次批 = 7（省 7 次）；若某次 200 条被拆成 2 次，
  /// 则 200 条/2 次 = 省 198 —— 仍是大赚，但拆批本身的开销要看 [httpPosts]。
  final int httpPostsSaved;

  /// 客户端 state 缓存：命中 / 未命中
  final int stateCacheHits;
  final int stateCacheMisses;

  /// 客户端 state 缓存当前占用的估算字节
  final int stateCacheBytes;

  const AiStatsSnapshot({
    this.qps = 0,
    this.itemsPerSecond = 0,
    this.totalCalls = 0,
    this.successCalls = 0,
    this.failedCalls = 0,
    this.failuresByKind = const <String, int>{},
    this.callsByProvider = const <String, int>{},
    this.latency = AiLatencyStats.empty,
    this.logicalCalls = 0,
    this.totalItems = 0,
    this.httpPosts = 0,
    this.httpPostsSaved = 0,
    this.stateCacheHits = 0,
    this.stateCacheMisses = 0,
    this.stateCacheBytes = 0,
  });

  double get successRate =>
      totalCalls == 0 ? 1.0 : successCalls / totalCalls;

  /// 客户端 state 缓存命中率。
  ///
  /// ⚠ 这是**客户端**的命中率，不代表服务端的 L1/L2/DB 三级缓存
  /// （那是另一侧，见 PITFALLS §32.6）。
  double get stateCacheHitRate {
    final int t = stateCacheHits + stateCacheMisses;
    return t == 0 ? 0 : stateCacheHits / t;
  }

  /// 每次 HTTP POST 平均处理多少条目 —— **这个数越大越省**。
  ///
  /// `1.0` = 完全没攒批（一条一发）；`8.0` = 每次 POST 打 8 条；
  /// 拆批后会掉下来（例如 200 条拆 2 次 → 100.0，其实仍很高）。
  double get itemsPerPost => httpPosts == 0 ? 0 : totalItems / httpPosts;
}

/// 运行时指标聚合器（线程内单例，注意只统计本客户端）。
class AiRuntimeStats {
  /// 滚动窗口（秒）——QPS 用
  final int windowSeconds;

  /// 延迟样本环形缓冲容量（避免长跑内存无界增长）
  final int _latencyCapacity;

  int get latencyCapacity => _latencyCapacity;

  /// 时钟注入点。
  ///
  /// ⚠ 必须注入而不是直接 `DateTime.now()`：否则 `record()` 用真实时钟打桶、
  /// 而 `snapshot()` 若用别的时钟取窗口，**过期判定与逐秒序列会静默算错** ——
  /// 不报错，只给你一个看起来合理的错数（见 tool/verify_ai_stats.dart 第 [3] 组）。
  final DateTime Function() _clock;

  AiRuntimeStats({
    this.windowSeconds = 60,
    int latencyCapacity = 512,
    DateTime Function()? clock,
  })  : _latencyCapacity = latencyCapacity < 16 ? 16 : latencyCapacity,
        _clock = clock ?? DateTime.now;

  /// 按「秒 → 请求数 / 条目数」分桶
  final Map<int, _Bucket> _buckets = <int, _Bucket>{};

  /// 延迟环形缓冲（毫秒）
  final ListQueue<double> _latencies = ListQueue<double>();

  int _totalCalls = 0;
  int _successCalls = 0;
  int _failedCalls = 0;
  int _logicalCalls = 0;
  int _totalItems = 0;
  int _httpPosts = 0;
  final Map<String, int> _failuresByKind = <String, int>{};
  final Map<String, int> _callsByProvider = <String, int>{};

  int _stateCacheHits = 0;
  int _stateCacheMisses = 0;
  int _stateCacheBytes = 0;

  /// 记录一次逻辑调用。
  void record(AiRequestSample s) {
    _totalCalls++;
    _logicalCalls++;
    _totalItems += s.itemCount < 0 ? 0 : s.itemCount;
    _httpPosts += s.httpPosts < 1 ? 1 : s.httpPosts;
    if (s.success) {
      _successCalls++;
    } else {
      _failedCalls++;
      final String k = s.failureKind ?? 'unknown';
      _failuresByKind[k] = (_failuresByKind[k] ?? 0) + 1;
    }
    _callsByProvider[s.provider] = (_callsByProvider[s.provider] ?? 0) + 1;

    final int ms = s.latency.inMilliseconds;
    _latencies.addLast(ms.toDouble());
    while (_latencies.length > _latencyCapacity) {
      _latencies.removeFirst();
    }

    final int sec = _nowSeconds();
    final _Bucket b = _buckets.putIfAbsent(sec, () => _Bucket());
    b.calls += 1;
    b.items += s.itemCount < 0 ? 0 : s.itemCount;
    _evictOldBuckets(sec);
  }

  /// 记录一次客户端 state 缓存查询。
  void recordStateCacheLookup({required bool hit, int bytes = 0}) {
    if (hit) {
      _stateCacheHits++;
      if (bytes > 0) _stateCacheBytes += bytes;
    } else {
      _stateCacheMisses++;
    }
  }

  /// 缓存被 drop / 清空时同步扣减占用（否则字节数只增不减）。
  void recordStateCacheDropped(int bytes) {
    _stateCacheBytes -= bytes;
    if (_stateCacheBytes < 0) _stateCacheBytes = 0;
  }

  void reset() {
    _buckets.clear();
    _latencies.clear();
    _totalCalls = 0;
    _successCalls = 0;
    _failedCalls = 0;
    _logicalCalls = 0;
    _totalItems = 0;
    _httpPosts = 0;
    _failuresByKind.clear();
    _callsByProvider.clear();
    _stateCacheHits = 0;
    _stateCacheMisses = 0;
    _stateCacheBytes = 0;
  }

  /// 取快照（面板用；可安全在 UI 线程调，O(n log n) on ≤512 样本）。
  AiStatsSnapshot snapshot() {
    final int sec = _nowSeconds();
    _evictOldBuckets(sec);

    int calls = 0;
    int items = 0;
    for (final _Bucket b in _buckets.values) {
      calls += b.calls;
      items += b.items;
    }
    final double win = windowSeconds <= 0 ? 60 : windowSeconds.toDouble();

    return AiStatsSnapshot(
      qps: calls / win,
      itemsPerSecond: items / win,
      totalCalls: _totalCalls,
      successCalls: _successCalls,
      failedCalls: _failedCalls,
      failuresByKind: Map<String, int>.unmodifiable(_failuresByKind),
      callsByProvider: Map<String, int>.unmodifiable(_callsByProvider),
      latency: _latency(),
      logicalCalls: _logicalCalls,
      totalItems: _totalItems,
      httpPosts: _httpPosts,
      httpPostsSaved: _totalItems - _httpPosts,
      stateCacheHits: _stateCacheHits,
      stateCacheMisses: _stateCacheMisses,
      stateCacheBytes: _stateCacheBytes,
    );
  }

  /// 滚动窗口内的逐秒请求数（给折线图用，长度 = windowSeconds）。
  List<int> qpsSeries() {
    final int sec = _nowSeconds();
    _evictOldBuckets(sec);
    return <int>[
      for (int i = windowSeconds - 1; i >= 0; i--)
        _buckets[sec - i]?.calls ?? 0,
    ];
  }

  // -------------------------------------------------------------------------

  AiLatencyStats _latency() {
    if (_latencies.isEmpty) return AiLatencyStats.empty;
    final List<double> sorted = _latencies.toList()..sort();
    double at(double p) {
      if (sorted.isEmpty) return 0;
      final int idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
      return sorted[idx];
    }

    double sum = 0;
    for (final double v in sorted) {
      sum += v;
    }
    return AiLatencyStats(
      count: sorted.length,
      p50: at(0.50),
      p95: at(0.95),
      p99: at(0.99),
      max: sorted.last,
      avg: sum / sorted.length,
    );
  }

  int _nowSeconds() => _clock().millisecondsSinceEpoch ~/ 1000;

  void _evictOldBuckets(int nowSec) {
    final int cutoff = nowSec - windowSeconds;
    _buckets.removeWhere((int sec, _Bucket _) => sec < cutoff);
  }
}

class _Bucket {
  int calls = 0;
  int items = 0;
}
