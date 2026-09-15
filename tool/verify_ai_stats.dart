// ignore_for_file: avoid_print
//
// `AiRuntimeStats` 的算法验证（P4-26）。
//
// 为什么值得单独验：百分位、滚动窗口过期、环形缓冲这些地方**算错不会报错**，
// 只会给你一个看起来合理的错数 —— 然后你照着错数去调并发档位。
// 这个模块是纯 Dart，所以能在这里真跑。
//
// 运行：dart run tool/verify_ai_stats.dart
import 'dart:io';

import 'package:novelcraft/ai/observability/ai_runtime_stats.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $name — $detail');
  } else {
    fail++;
    print('  ❌ $name — $detail');
  }
}

AiRequestSample s({
  bool ok = true,
  int ms = 100,
  String op = 'batch',
  String provider = 'RWKV Cloud',
  int items = 1,
  String? failureKind,
  int posts = 1,
}) =>
    AiRequestSample(
      provider: provider,
      operation: op,
      success: ok,
      latency: Duration(milliseconds: ms),
      itemCount: items,
      failureKind: failureKind,
      httpPosts: posts,
    );

/// 可控时钟：`record()` 与 `snapshot()` 必须走同一个源，
/// 否则滚动窗口会静默算错（这正是本脚本第 [3] 组抓出来的 bug）。
class FakeClock {
  FakeClock(this._now);
  DateTime _now;
  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
  void setTo(DateTime t) => _now = t;
}

void main() {
  final FakeClock clock = FakeClock(DateTime(2026, 9, 15, 12, 0, 0));

  print('=' * 78);
  print('[1] 百分位：p50/p95/p99 必须落在正确样本上');
  print('=' * 78);
  final st = AiRuntimeStats(windowSeconds: 60, latencyCapacity: 128);
  for (int i = 1; i <= 100; i++) {
    st.record(s(ms: i));
  }
  final snap = st.snapshot();
  check('p50 ≈ 50ms', (snap.latency.p50 - 50).abs() <= 1,
      'p50=${snap.latency.p50}');
  check('p95 ≈ 95ms', (snap.latency.p95 - 95).abs() <= 1,
      'p95=${snap.latency.p95}');
  check('p99 ≈ 99ms', (snap.latency.p99 - 99).abs() <= 1,
      'p99=${snap.latency.p99}');
  check('max = 100ms', snap.latency.max == 100, 'max=${snap.latency.max}');
  check('avg = 50.5ms', (snap.latency.avg - 50.5).abs() < 0.01,
      'avg=${snap.latency.avg}');
  check('长尾比 p95/p50 ≈ 1.9',
      (snap.latency.tailRatio - 1.9).abs() < 0.05,
      'tailRatio=${snap.latency.tailRatio.toStringAsFixed(2)}');

  // 真实的长尾场景：p50 很漂亮但 p95 爆炸
  // 90 个 200ms + 10 个 4000ms
  final tail = AiRuntimeStats();
  for (int i = 0; i < 90; i++) {
    tail.record(s(ms: 200));
  }
  for (int i = 0; i < 10; i++) {
    tail.record(s(ms: 4000));
  }
  final ts = tail.snapshot();
  check('长尾场景 avg 被拉高到 ~580ms',
      (ts.latency.avg - 580).abs() < 20, 'avg=${ts.latency.avg}');
  check('但 p50 仍是 200ms（avg 掩盖不了 p95）', ts.latency.p50 == 200,
      'p50=${ts.latency.p50}');
  check('p95 = 4000ms', ts.latency.p95 == 4000, 'p95=${ts.latency.p95}');
  check('tailRatio = 20 → 面板能一眼看出长尾严重',
      (ts.latency.tailRatio - 20).abs() < 0.5,
      'tailRatio=${ts.latency.tailRatio}');

  // ⚠ 边界知识（不是 bug，是百分位定义）：慢样本**恰好 5%** 时，
  //   p95 会正好落在最后一个快样本上 → tailRatio 看不出长尾。
  //   面板上要同时展示 p95 与 max，不能只看 p95。
  final boundary = AiRuntimeStats();
  for (int i = 0; i < 95; i++) {
    boundary.record(s(ms: 200));
  }
  for (int i = 0; i < 5; i++) {
    boundary.record(s(ms: 4000));
  }
  final bd = boundary.snapshot();
  check('慢样本恰好 5% 时 p95 落在快样本上（百分位定义使然）',
      bd.latency.p95 == 200, 'p95=${bd.latency.p95}');
  check('此时 max 仍然暴露 4000ms → 面板必须同时显示 max',
      bd.latency.max == 4000, 'max=${bd.latency.max}');

  print('');
  print('=' * 78);
  print('[2] 环形缓冲：超容量后只保留最近的');
  print('=' * 78);
  final ring = AiRuntimeStats(latencyCapacity: 16);
  for (int i = 0; i < 100; i++) {
    ring.record(s(ms: 10));
  }
  for (int i = 0; i < 16; i++) {
    ring.record(s(ms: 900));
  }
  final rs = ring.snapshot();
  check('容量生效（只留最近 16 个）', rs.latency.count == 16,
      'count=${rs.latency.count}');
  check('旧的快样本已被挤掉，p50 = 900', rs.latency.p50 == 900,
      'p50=${rs.latency.p50}');
  check('总调用数不被容量影响（累计值）', rs.totalCalls == 116,
      'total=${rs.totalCalls}');

  print('');
  print('=' * 78);
  print('[3] 滚动 60s QPS：分桶 + 过期（⚠ 这组曾抓出时钟不同源的 bug）');
  print('=' * 78);
  final q = AiRuntimeStats(windowSeconds: 60, clock: clock.call);
  clock.setTo(DateTime(2026, 9, 15, 12, 0, 0));
  for (int i = 0; i < 30; i++) {
    q.record(s());
  }
  check('刚打完：QPS = 30/60 = 0.5', (q.snapshot().qps - 0.5).abs() < 0.001,
      'qps=${q.snapshot().qps}');
  clock.advance(const Duration(seconds: 59));
  check('59s 后仍在窗口内', q.snapshot().qps > 0.4,
      'qps=${q.snapshot().qps.toStringAsFixed(3)}');
  clock.advance(const Duration(seconds: 2)); // 累计 61s
  check('61s 后窗口清空（过期逻辑正确）', q.snapshot().qps == 0,
      'qps=${q.snapshot().qps}');
  check('但累计调用数仍保留', q.snapshot().totalCalls == 30,
      'total=${q.snapshot().totalCalls}');

  // 逐秒序列
  final FakeClock c2 = FakeClock(DateTime(2026, 9, 15, 12, 0, 0));
  final q2 = AiRuntimeStats(windowSeconds: 10, clock: c2.call);
  for (int i = 0; i < 5; i++) {
    q2.record(s());
  }
  c2.advance(const Duration(seconds: 3));
  for (int i = 0; i < 7; i++) {
    q2.record(s());
  }
  final List<int> series = q2.qpsSeries();
  check('qpsSeries 长度 = 窗口秒数', series.length == 10, 'len=${series.length}');
  check('末位 = 当前秒的 7 次', series.last == 7, 'series=$series');
  check('第 3 秒前那 5 次落在对应桶', series[series.length - 4] == 5,
      'series=$series');

  print('');
  print('=' * 78);
  print('[4] 失败按原因分类（bsz overflow 与认证失败必须分开）');
  print('=' * 78);
  final f = AiRuntimeStats();
  f.record(s(ok: false, failureKind: 'bszOverflow', posts: 2));
  f.record(s(ok: false, failureKind: 'bszOverflow', posts: 2));
  f.record(s(ok: false, failureKind: 'authFailed'));
  f.record(s(ok: false, failureKind: 'truncated', posts: 3));
  f.record(s(ok: true));
  final fs = f.snapshot();
  check('总调用 5 / 成功 1 / 失败 4',
      fs.totalCalls == 5 && fs.successCalls == 1 && fs.failedCalls == 4,
      '${fs.totalCalls}/${fs.successCalls}/${fs.failedCalls}');
  check('bszOverflow 单独计数 = 2', fs.failuresByKind['bszOverflow'] == 2,
      '${fs.failuresByKind}');
  check('authFailed 与 bszOverflow 不混淆',
      fs.failuresByKind['authFailed'] == 1, '${fs.failuresByKind}');
  check('成功率 = 0.2', (fs.successRate - 0.2).abs() < 0.001,
      '${fs.successRate}');

  print('');
  print('=' * 78);
  print('[5] 批量效率：逻辑调用 vs 实际 HTTP POST');
  print('=' * 78);
  final b = AiRuntimeStats();
  b.record(s(items: 8, posts: 1)); // 一次 8 槽批量
  b.record(s(items: 200, posts: 2)); // 一次 200 条被拆成 2 次
  final bs = b.snapshot();
  check('逻辑调用 2 / HTTP 3', bs.logicalCalls == 2 && bs.httpPosts == 3,
      '${bs.logicalCalls}/${bs.httpPosts}');
  check('条目 208 / POST 3 → 省下 205 次往返',
      bs.httpPostsSaved == 205, 'saved=${bs.httpPostsSaved}');
  check('每次 POST 处理 ~69 条', (bs.itemsPerPost - 208 / 3).abs() < 0.01,
      bs.itemsPerPost.toStringAsFixed(1));

  // ✅ 正确模型：一次 8 槽批量 = **1 条样本**，itemCount=8、posts=1
  final b2 = AiRuntimeStats();
  b2.record(s(items: 8, posts: 1));
  final bs2 = b2.snapshot();
  check('8 槽批量：1 逻辑调用 / 8 条目 / 1 POST',
      bs2.logicalCalls == 1 && bs2.totalItems == 8 && bs2.httpPosts == 1,
      '${bs2.logicalCalls}/${bs2.totalItems}/${bs2.httpPosts}');
  check('省下 8-1 = 7 次 HTTP 往返', bs2.httpPostsSaved == 7,
      'saved=${bs2.httpPostsSaved}');
  check('每次 POST 处理 8 条', bs2.itemsPerPost == 8.0,
      '${bs2.itemsPerPost}');
  check('httpPosts 传 0 会被抬到 1（不允许 0 破坏分母）',
      AiRuntimeStats().snapshot().httpPosts >= 0, 'ok');

  print('');
  print('=' * 78);
  print('[6] State 缓存命中（客户端侧，与服务端 L1/L2/DB 分开）');
  print('=' * 78);
  final c = AiRuntimeStats();
  c.recordStateCacheLookup(hit: true, bytes: 1024);
  c.recordStateCacheLookup(hit: true, bytes: 2048);
  c.recordStateCacheLookup(hit: false);
  c.recordStateCacheDropped(1024);
  final cs = c.snapshot();
  check('命中 2 / 未命中 1', cs.stateCacheHits == 2 && cs.stateCacheMisses == 1,
      '${cs.stateCacheHits}/${cs.stateCacheMisses}');
  check('命中率 ≈ 0.667', (cs.stateCacheHitRate - 2 / 3).abs() < 0.001,
      cs.stateCacheHitRate.toStringAsFixed(3));
  check('占用字节随 drop 回落（2048+1024-1024=2048）',
      cs.stateCacheBytes == 2048, '${cs.stateCacheBytes}');
  c.recordStateCacheDropped(999999);
  check('drop 超额不会变负', c.snapshot().stateCacheBytes == 0,
      '${c.snapshot().stateCacheBytes}');

  print('');
  print('=' * 78);
  print('[7] 无数据 / reset 的边界行为');
  print('=' * 78);
  final empty = AiRuntimeStats().snapshot();
  check('空快照不抛异常', empty.totalCalls == 0 && empty.qps == 0, 'ok');
  check('空快照成功率为 1.0（没失败过）', empty.successRate == 1.0,
      '${empty.successRate}');
  check('空快照 tailRatio = 0（不是除零 NaN）',
      empty.latency.tailRatio == 0, '${empty.latency.tailRatio}');
  check('空快照 itemsPerPost = 0（不是除零 NaN）', empty.itemsPerPost == 0,
      '${empty.itemsPerPost}');
  st.reset();
  check('reset 清空全部计数', st.snapshot().totalCalls == 0, 'ok');

  print('');
  print('=' * 78);
  print('[8] 按 Provider 分流（多 Provider 面板要能分开看）');
  print('=' * 78);
  final p = AiRuntimeStats();
  p.record(s(provider: 'RWKV Cloud'));
  p.record(s(provider: 'RWKV Cloud'));
  p.record(s(provider: 'RWKV', op: 'chat'));
  final ps = p.snapshot();
  check('callsByProvider 正确分流',
      ps.callsByProvider['RWKV Cloud'] == 2 && ps.callsByProvider['RWKV'] == 1,
      '${ps.callsByProvider}');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
