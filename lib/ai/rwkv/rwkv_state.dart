// RWKV 状态抽象与 LRU 缓存。
//
// RWKV v7 的核心优势：**RNN 架构**——每前进一步都产出一个可序列化的 state
// tensor（形状约 [n_layer * n_head * head_dim]，但对外视为 opaque Uint8List），
// 下次推理只需 load state + 增量 token，无需重新编码完整上下文。
//
// 相对于 Transformer 的 KV Cache（O(n²) 空间 + 每次全量 recalc），
// RWKV state = O(1) 持久化、O(1) 克隆、O(1) 跨请求复用，完美契合：
//   - 同一 Agent 的多轮对话记忆（不需要反复把历史塞进 prompt）
//   - 工作流多步骤的上下文累积（大纲 → 人设 → 章节的 state 渐进）
//   - 并发多会话隔离（每个 session 独立 state，互不干扰）
//
// 实现要点：
// - [RwkvState] 对底层张量做 opaque 封装（Uint8List + metadata），与 server
//   端的 serialize/deserialize 协议对齐；上层只感知 stateId / tokenCount /
//   createdAt 三类观测字段。
// - [RwkvStateCache] 基于时间戳的 LRU 驱逐；默认上限 64 个 state
//   （~每个 state 10~30MB，7B 模型下 64*20MB ≈ 1.3GB，合理）。
// - 所有方法都不 `import 'dart:io'`，Web 端可编译（state 存在内存即可）。
library;

import 'dart:typed_data';

/// RWKV 运行时状态快照（opaque 封装）。
///
/// 对应 RWKV v7 规范中 `rwkv_state`：一组可序列化/反序列化的张量。
/// 上层代码**绝不**直接操作 [bytes]，只能通过 [RwkvEngine] 的接口让
/// state 在 provider ↔ server 之间流转。
class RwkvState {
  /// 全局唯一 state ID（由引擎分配）。
  final String stateId;

  /// 生成该 state 时累计处理的 token 数（预编码 + 生成）。
  final int tokenCount;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近一次访问时间（LRU 用）。
  DateTime lastAccessedAt;

  /// 父 state ID（用于追溯 state 演化链；null 表示全新）。
  final String? parentStateId;

  /// 所属会话 ID（会话结束时批量回收）。
  final String? sessionId;

  /// 不透明字节；格式与 RWKV server（llama.cpp / rwkv.cpp）的
  /// `GET /state` / `POST /state` 响应保持一致。
  final Uint8List bytes;

  /// 大致内存占用（字节）。
  int get sizeInBytes => bytes.lengthInBytes;

  RwkvState({
    required this.stateId,
    required this.tokenCount,
    required this.bytes,
    DateTime? createdAt,
    DateTime? lastAccessedAt,
    this.parentStateId,
    this.sessionId,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastAccessedAt = lastAccessedAt ?? DateTime.now();

  RwkvState._cloneWithBytes(this.stateId, this.tokenCount, this.bytes,
      {this.parentStateId, this.sessionId})
      : createdAt = DateTime.now(),
        lastAccessedAt = DateTime.now();

  /// 派生一份新的 state（同一个 session 内的下一步推理）。
  RwkvState derive(String newStateId, int newTokenCount, Uint8List newBytes) =>
      RwkvState._cloneWithBytes(
        newStateId,
        newTokenCount,
        newBytes,
        parentStateId: stateId,
        sessionId: sessionId,
      );
}

/// LRU State Cache（线程安全通过调用方单 Isolate 的事件循环保证，不引
/// 额外 package）。
///
/// 语义：
/// - 存：[put] 写入，超过 [maxSize] 则驱逐最久未访问。
/// - 取：[get] 获取并更新 [lastAccessedAt]。
/// - 回收：[dropSession] 按会话 ID 批量清除；[evictExpired] 按时长清理。
class RwkvStateCache {
  final int maxSize;
  final Duration ttl;
  final Map<String, RwkvState> _byId = <String, RwkvState>{};

  /// 查询回调：`(是否命中, 命中的字节数)`。
  ///
  /// 供 P4-26 健康面板统计**客户端侧**命中率用。
  /// ⚠ 客户端只有「内存命中 / 未命中」两级；服务端的 L1 VRAM / L2 RAM /
  /// SQLite 三级是**另一个进程**的事（`/state/status`），别把两者混成一个数
  /// （PITFALLS §32.6）。
  void Function(bool hit, int bytes)? onLookup;

  /// 驱逐回调：被淘汰的字节数（让面板的占用估算能回落）。
  void Function(int bytes)? onEvicted;

  /// 构造 state 缓存。
  ///
  /// [maxSize] 最大缓存条目；[ttl] 单个 state 的最长存活时间（默认 30 分钟）。
  RwkvStateCache({
    this.maxSize = 64,
    this.ttl = const Duration(minutes: 30),
  });

  /// 当前条目数（观测用）。
  int get length => _byId.length;

  /// 估算总内存占用（字节）。
  int get estimatedBytes =>
      _byId.values.fold<int>(0, (sum, s) => sum + s.sizeInBytes);

  /// 取 state；命中返回 state 并触碰访问时间；未命中返回 null。
  RwkvState? get(String stateId) {
    final s = _byId[stateId];
    if (s == null) {
      onLookup?.call(false, 0);
      return null;
    }
    if (DateTime.now().difference(s.createdAt) > ttl) {
      _byId.remove(stateId);
      onEvicted?.call(s.sizeInBytes);
      // ⚠ 过期也算**未命中**：对调用方而言它就是"拿不到"，
      // 统计成命中会让面板误报"缓存很有效"。
      onLookup?.call(false, 0);
      return null;
    }
    s.lastAccessedAt = DateTime.now();
    onLookup?.call(true, s.sizeInBytes);
    return s;
  }

  /// 写入 state；若超过上限则按 lastAccessedAt 驱逐 1 条最旧的。
  void put(RwkvState state) {
    if (_byId.containsKey(state.stateId)) {
      _byId[state.stateId] = state;
      return;
    }
    while (_byId.length >= maxSize && _byId.isNotEmpty) {
      var oldest = _byId.values.reduce((a, b) =>
          a.lastAccessedAt.isBefore(b.lastAccessedAt) ? a : b);
      _byId.remove(oldest.stateId);
      onEvicted?.call(oldest.sizeInBytes);
    }
    _byId[state.stateId] = state;
  }

  /// 按 [stateId] 移除。
  bool remove(String stateId) => _byId.remove(stateId) != null;

  /// 按会话批量清除（会话结束时调用）。
  int dropSession(String sessionId) {
    final keys = _byId.values
        .where((s) => s.sessionId == sessionId)
        .map((s) => s.stateId)
        .toList(growable: false);
    for (final k in keys) {
      _byId.remove(k);
    }
    return keys.length;
  }

  /// 清理全部超时 state；返回被驱逐条目数。
  int evictExpired() {
    final now = DateTime.now();
    final expired = _byId.values
        .where((s) => now.difference(s.lastAccessedAt) > ttl)
        .toList(growable: false);
    for (final s in expired) {
      _byId.remove(s.stateId);
    }
    return expired.length;
  }

  /// 清空。
  void clear() => _byId.clear();
}

/// 生成唯一 ID 工具（避免引 uuid）。
String rwkvGenerateId([String prefix = '']) {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = BigInt.from(DateTime.now().microsecond).toRadixString(36);
  return '$prefix$ts$rand';
}
