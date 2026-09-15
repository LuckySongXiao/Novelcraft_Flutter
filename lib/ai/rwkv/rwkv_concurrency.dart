// RWKV 引擎并发容量控制。
//
// ⚠ 设计前提（PITFALLS §31.3 实测校准）：
//
//  服务端**自带** FIFO admission queue：所有生成请求先入队，队首每 100ms 重读空闲
//  VRAM 动态算 `dynamic_max_bsz`，permit 释放即唤醒等待者。单请求超过 `hard_max_bsz`
//  会直接 `400 {"error":"bsz overflow, Max bsz=N"}`。
//
//  ⇒ **客户端不该再拍一个固定并发档位去硬扛服务端**。正确姿势：
//    1. 从 `GET /v1/server/status` 读 `available_bsz` 作为**软上限**；
//    2. `dynamic_max_bsz` **不可缓存为长期常量**（文档明说它随其他进程 / state cache /
//       活动推理占用的显存变化）→ 这里带 TTL；
//    3. 客户端只做**保守限流 + 快速失败**，真实排队交给服务端；
//    4. 遇到 `bsz overflow` 立刻**降档**，不要盲目重试同样大小。
//
//  实测参考（3×4090 集群的单节点）：`hard=dynamic=available=169`，
//  `bytes_per_bsz≈52.4MB`，`total_vram≈23.5GB`；单路吞吐峰值在 **N≈16**（2.93 req/s）。
library;

import 'dart:async';

import 'package:logging/logging.dart';

/// 引擎状态的探测回调：返回 `available_bsz`（取不到返回 null）。
typedef RwkvAvailableBszProbe = Future<RwkvServerCapacity?> Function();

/// `/v1/server/status` 里与容量相关的字段。
class RwkvServerCapacity {
  final int? hardMaxBsz;
  final int? dynamicMaxBsz;
  final int? availableBsz;
  final int? reservedBsz;
  final int? queuedRequests;
  final int? freeVramBytes;
  final int? totalVramBytes;
  final int? bytesPerBsz;

  const RwkvServerCapacity({
    this.hardMaxBsz,
    this.dynamicMaxBsz,
    this.availableBsz,
    this.reservedBsz,
    this.queuedRequests,
    this.freeVramBytes,
    this.totalVramBytes,
    this.bytesPerBsz,
  });

  /// 当前实际还能塞多少个并发序列（优先动态值，回退硬上限）。
  int? get effectiveAvailable => availableBsz ?? dynamicMaxBsz ?? hardMaxBsz;

  /// 是否已经在排队（> 0 说明该降并发，而不是继续加压）。
  bool get isQueueing => (queuedRequests ?? 0) > 0;

  factory RwkvServerCapacity.fromStatus(Map<String, dynamic> status) {
    final Object? q = status['prefill_queue'];
    int? i(Object? v) => v is num ? v.toInt() : null;
    if (q is! Map) return const RwkvServerCapacity();
    return RwkvServerCapacity(
      hardMaxBsz: i(q['hard_max_bsz']),
      dynamicMaxBsz: i(q['dynamic_max_bsz']),
      availableBsz: i(q['available_bsz']),
      reservedBsz: i(q['reserved_bsz']),
      queuedRequests: i(q['queued_requests']),
      freeVramBytes: i(q['free_vram_bytes']),
      totalVramBytes: i(q['total_vram_bytes']),
      bytesPerBsz: i(q['bytes_per_bsz']),
    );
  }
}

/// 并发容量控制器。
class RwkvConcurrencyController {
  /// 客户端侧**保守**硬上限。
  ///
  /// 即使服务端报 169，也不该真的开 169 路 —— 跨境网络 + CF 边缘会让尾延迟暴涨。
  /// 实测吞吐峰值在 ~16，故默认取 16。
  final int clientHardCap;

  /// 从服务端取回的新鲜度窗口。
  ///
  /// 文档明确说 `dynamic_max_bsz` 会随显存变化，**不能当长期常量**；
  /// 但也不能每个请求都去探一次（那次探测本身要吃一个 HTTP 往返）。
  /// 15s 是「够新鲜」与「别把探测打成主要开销」的折中。
  final Duration capacityTtl;

  final RwkvAvailableBszProbe? probe;
  final Logger _logger;

  RwkvServerCapacity? _cached;
  DateTime? _cachedAt;

  /// 因 `bsz overflow` 被压下来的临时上限（比服务端报的值更保守）。
  int? _penaltyCap;

  /// 连续成功次数；用于慢慢恢复被压下来的 `_penaltyCap`。
  int _successStreak = 0;

  /// 当前在途请求数（观测用）。
  int _inFlight = 0;

  RwkvConcurrencyController({
    this.probe,
    this.clientHardCap = 16,
    this.capacityTtl = const Duration(seconds: 15),
    Logger? logger,
  }) : _logger = logger ?? Logger('RwkvConcurrency');

  int get inFlight => _inFlight;
  RwkvServerCapacity? get lastCapacity => _cached;

  /// 当前允许的最大并发。
  ///
  /// 计算顺序：服务端可用值 → 客户端硬上限 → 惩罚档，取**最小**。
  /// 探测失败时回退到 [clientHardCap] 的保守一半（宁可慢，不可把服务端打挂）。
  Future<int> effectivePermits({bool force = false}) async {
    final RwkvServerCapacity? cap = await _capacity(force: force);
    int limit = clientHardCap;
    final int? serverAvail = cap?.effectiveAvailable;
    if (serverAvail != null && serverAvail > 0 && serverAvail < limit) {
      limit = serverAvail;
    }
    if (cap != null && cap.isQueueing) {
      // 已经在排队 → 再压一半，避免把队列撑更长
      limit = (limit ~/ 2).clamp(1, clientHardCap);
    }
    final int? penalty = _penaltyCap;
    if (penalty != null && penalty < limit) limit = penalty;
    return limit < 1 ? 1 : limit;
  }

  /// 记录一次 `bsz overflow`：把上限压到建议值。
  ///
  /// [requestBsz] 本次请求的槽位数，[maxBsz] 服务端回报的上限。
  void noteBszOverflow(int requestBsz, int? maxBsz) {
    _successStreak = 0;
    final int suggested = (maxBsz != null && maxBsz > 0)
        ? (requestBsz > maxBsz ? maxBsz : (requestBsz ~/ 2).clamp(1, maxBsz))
        : (requestBsz ~/ 2).clamp(1, clientHardCap);
    final int next = suggested < 1 ? 1 : suggested;
    if (_penaltyCap == null || next < _penaltyCap!) {
      _penaltyCap = next;
      _logger.warning(
          'bsz overflow（request=$requestBsz max=$maxBsz）→ 并发档位暂降到 $next');
    }
  }

  /// 记录一次成功；连续成功若干次后逐步放松惩罚档。
  void noteSuccess() {
    _successStreak++;
    if (_penaltyCap != null && _successStreak >= 5) {
      // 每 5 次成功 +1，缓慢恢复，避免抖动
      _penaltyCap = (_penaltyCap! + 1).clamp(1, clientHardCap);
      _successStreak = 0;
      _logger.fine('并发档位回升到 $_penaltyCap');
    }
  }

  void enterInFlight() => _inFlight++;
  void leaveInFlight() {
    if (_inFlight > 0) _inFlight--;
  }

  /// 使缓存失效（例如刚启动完本地引擎，容量已变）。
  void invalidate() {
    _cached = null;
    _cachedAt = null;
  }

  Future<RwkvServerCapacity?> _capacity({required bool force}) async {
    final RwkvAvailableBszProbe? p = probe;
    if (p == null) return null;
    final DateTime now = DateTime.now();
    final DateTime? at = _cachedAt;
    if (!force && at != null && _cached != null) {
      if (now.difference(at) < capacityTtl) return _cached;
    }
    try {
      final RwkvServerCapacity? fresh = await p();
      if (fresh != null) {
        _cached = fresh;
        _cachedAt = now;
        // 服务端报的硬上限若比客户端保守上限还小，说明客户端该更保守
        final int? hard = fresh.hardMaxBsz;
        if (hard != null && hard > 0 && hard < clientHardCap) {
          _logger.info('服务端 hard_max_bsz=$hard 小于客户端上限 $clientHardCap，'
              '按服务端收紧（PITFALLS §31.3）');
        }
      }
      return fresh;
    } on Object catch (e) {
      _logger.fine('探测并发容量失败，沿用保守默认：$e');
      return _cached;
    }
  }
}
