// 客户端侧 RWKV 云端会话台账 —— 「把 state 做到客户端」的落点。
//
// ## 为什么不是「存 state 字节」
//
// `rwkv_lightning_cuda` **没有 state 导出端点**：`rwkv_engine.dart` 顶部注释已
// 记录实测结果 —— `POST /state`、`GET /state?session=` 两个端点都是 **404**，
// 所以客户端 `RwkvState.bytes` 一直是 `Uint8List(0)` 的假占位。
// 「把几 MB state 字节存本地、下次直接恢复」在这套服务端上物理不可实现。
//
// ## 可行且等价的方案（本文件实现）
//
// 让**客户端**持有会话身份与转写本，并把它们持久化在本地：
//
//   1. `session_id` 由**客户端**生成（不再让服务端分配）→ 「哪个 state 对应
//      哪个并发」由客户端说了算，服务端只按 id 存；
//   2. 续跑时只把**本轮增量**发给 `/state/chat/completions`，服务端按
//      `session_id` 在 L1 VRAM / L2 RAM / SQLite 三级缓存里接着算 ——
//      这才是 RNN 的 O(1) 上下文接续（Transformer 的 KV Cache 做不到）；
//   3. 服务端丢了会话（进程重启 / 三级缓存被淘汰 / 换端点）时，客户端拿本地
//      转写本**重放**一次重建 state，付一次 prefill 即可（`RwkvEngine.replayTranscript`
//      已有同款先例）。
//
// 会话的逻辑身份（[RwkvCloudSessionRecord.sessionKey]）取
// **「作用域 × 智能体角色」**，其中作用域由调用方决定：
//   * 大纲规划组 → `<书名>::plan`（一条链贯穿整本书的规划，主线串行、
//     支线大纲由 9 条写手链并行产出）；
//   * 章节写作组 → `<项目id>::chapter::<章id>`（**每章每个角色一条链**——
//     全书章节并行开队时，章与章之间零依赖；章内严格串行）。
// 键最终还会被 `RwkvCloudProvider` 前缀上端点 host、被 [storageKey] 转义成
// 文件名安全串，`lib/ai` 这一层不必关心。
//
// 本文件不 `import 'dart:io'`，Web 端可编译（持久化由注入的回调决定）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../models/chat.dart';

/// 一个客户端托管的云端 RWKV 会话。
class RwkvCloudSessionRecord {
  RwkvCloudSessionRecord({
    required this.sessionKey,
    required this.sessionId,
    List<ChatMessage>? transcript,
    this.turnCount = 0,
    int? lastActiveMs,
  })  : transcript = transcript ?? <ChatMessage>[],
        lastActiveMs = lastActiveMs ?? DateTime.now().millisecondsSinceEpoch;

  /// 逻辑身份：`<项目或大纲分组>::<智能体角色>`。
  final String sessionKey;

  /// 下发给服务端的会话 ID（**客户端生成**，持久化后跨重启不变）。
  final String sessionId;

  /// 已发生的对话（user/assistant 成对），仅用于**重放重建**服务端 state。
  final List<ChatMessage> transcript;

  /// 已完成的轮数。
  int turnCount;

  /// 最近活动时间（毫秒）。
  int lastActiveMs;

  /// 是否尚未与服务端建立过 state。
  bool get isFresh => turnCount == 0 || transcript.isEmpty;

  /// 构造本轮要下发的**增量**提示词；首轮带上 system 与全部 messages。
  ///
  /// ⚠ 客户端 state 模式的调用契约：**每次调用只把 `messages` 的最后一条
  /// 视为本轮新增输入**（`/state/chat/completions` 的 `contents` 必须恰好
  /// 1 条，服务端只吃增量）。首轮例外：system + 全部 messages 一起发，
  /// 由服务端据此建立 state。
  ({String prompt, bool isFirstTurn}) buildTurnPrompt(ChatRequest request) {
    final bool first = isFresh;
    final List<ChatMessage> effective;
    if (first) {
      effective = <ChatMessage>[...request.messages];
    } else {
      final List<ChatMessage> tail = request.messages.isEmpty
          ? const <ChatMessage>[]
          : <ChatMessage>[request.messages.last];
      effective = tail;
    }
    return (
      prompt: buildPrompt(effective, systemPrompt: first ? request.systemPrompt : null),
      isFirstTurn: first,
    );
  }

  /// 把 messages 拼成 rwkv_lightning 的经典单条 prompt
  /// （`System: … / User: … / Assistant:`，与 `RwkvEngine._buildStatefulPrompt` 同格式）。
  static String buildPrompt(
    Iterable<ChatMessage> msgs, {
    String? systemPrompt,
  }) {
    final bool hasSystem = systemPrompt != null && systemPrompt.trim().isNotEmpty;
    final StringBuffer sb = StringBuffer();
    if (hasSystem) sb.write('System: ${systemPrompt.trim()}\n\n');
    for (final ChatMessage m in msgs) {
      final String text = m.content.trim();
      if (text.isEmpty) continue;
      switch (m.role) {
        case ChatRole.user:
          sb.write('User: $text\n\n');
        case ChatRole.assistant:
          sb.write('Assistant: $text\n\n');
        case ChatRole.system:
          // 有外部 systemPrompt 时跳过，避免重复注入。
          if (!hasSystem) sb.write('System: $text\n\n');
      }
    }
    sb.write('Assistant:');
    return sb.toString();
  }

  /// 把整份转写本拼成单条 prompt（重放重建用，末尾停在 `Assistant:`）。
  String buildReplayPrompt() => buildPrompt(
        transcript.where((ChatMessage m) => m.role != ChatRole.system),
        systemPrompt: transcript
            .where((ChatMessage m) => m.role == ChatRole.system)
            .map((ChatMessage m) => m.content)
            .join('\n\n'),
      );

  /// 追加一轮并返回自身（链式）。
  RwkvCloudSessionRecord appendTurn(String userText, String assistantText) {
    transcript
      ..add(ChatMessage.user(userText))
      ..add(ChatMessage.assistant(assistantText));
    turnCount++;
    lastActiveMs = DateTime.now().millisecondsSinceEpoch;
    return this;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'sessionKey': sessionKey,
        'sessionId': sessionId,
        'turnCount': turnCount,
        'lastActiveMs': lastActiveMs,
        'transcript': <Object?>[for (final ChatMessage m in transcript) m.toJson()],
      };

  factory RwkvCloudSessionRecord.fromJson(Map<String, Object?> json) {
    final List<ChatMessage> transcript = <ChatMessage>[];
    final Object? raw = json['transcript'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map) {
          transcript.add(ChatMessage.fromJson(
            item.map(
              (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
            ),
          ));
        }
      }
    }
    return RwkvCloudSessionRecord(
      sessionKey: (json['sessionKey'] as String?) ?? '',
      sessionId: (json['sessionId'] as String?) ?? '',
      transcript: transcript,
      turnCount: (json['turnCount'] as num?)?.toInt() ?? 0,
      lastActiveMs: (json['lastActiveMs'] as num?)?.toInt(),
    );
  }
}

/// 本地持久化会话台账。
///
/// 持久化本身通过注入的两个回调完成（生产环境接 `KeyValueStore`），
/// 这样 `lib/ai` 不必反向依赖 `lib/data`，也便于单测打桩。
class RwkvCloudSessionLedger {
  RwkvCloudSessionLedger({
    required this.read,
    required this.write,
    this.remove,
    this.maxStoredChars = 240000,
  });

  /// 把逻辑 [sessionKey] 转成**文件名安全**的存储键。
  ///
  /// ⚠ 必须做：native 端 `KeyValueStore` 直接拿 key 当文件名
  /// （`<scope>/<key>.json`），而逻辑 key 形如 `abc-uuid::chapter::leader`
  /// **含 `:`** —— Windows 文件名不允许冒号，不转义就会写失败。
  /// 失败被 [persist] 的 try/catch 吞掉，现象是「记忆永远不落盘」。
  static String storageKey(String sessionKey) =>
      sessionKey.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// `(key) → 已存 JSON 字符串 | null`。
  final Future<String?> Function(String key) read;

  /// `(key, json 字符串)` 落盘。
  final Future<void> Function(String key, String value) write;

  /// 可选：删除一个 key。
  final Future<void> Function(String key)? remove;

  /// 单条会话转写本的落盘字符上限。
  ///
  /// 转写本**只用于重放重建 state**，真正的上下文在服务端 state 里；超过上限
  /// 时截掉最旧的轮次（重建出的 state 会损失最早的那部分记忆，属可接受降级，
  /// 总比把 KeyValueStore 撑爆好）。
  final int maxStoredChars;

  final Map<String, RwkvCloudSessionRecord> _memo =
      <String, RwkvCloudSessionRecord>{};

  /// 进程内已解析过的会话数（观测用）。
  int get cachedCount => _memo.length;

  /// 取（或新建）一个会话记录。[sessionKey] 为空时抛 StateError。
  Future<RwkvCloudSessionRecord> resolve(String sessionKey) async {
    final String key = sessionKey.trim();
    if (key.isEmpty) {
      throw StateError('RwkvCloudSessionLedger.resolve: sessionKey 不能为空');
    }
    final RwkvCloudSessionRecord? cached = _memo[key];
    if (cached != null) return cached;

    RwkvCloudSessionRecord? loaded;
    try {
      final String? raw = await read(key);
      if (raw != null && raw.trim().isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          final RwkvCloudSessionRecord parsed = RwkvCloudSessionRecord.fromJson(
            decoded.map(
              (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
            ),
          );
          // sessionId 缺失/损坏一律视为不可用，重建一个新的（宁可丢记忆，
          // 也不能把空 id 下发出去导致服务端把多个并发混成一条会话）。
          if (parsed.sessionId.trim().isNotEmpty) loaded = parsed;
        }
      }
    } on Object {
      loaded = null;
    }

    final RwkvCloudSessionRecord record =
        loaded ?? RwkvCloudSessionRecord(sessionKey: key, sessionId: newSessionId());
    _memo[key] = record;
    return record;
  }

  /// 落盘（失败静默 —— 持久化是增强，绝不能拖垮推理链路）。
  Future<void> persist(RwkvCloudSessionRecord record) async {
    _truncate(record);
    try {
      await write(record.sessionKey, jsonEncode(record.toJson()));
    } on Object {
      // 忽略：下次 persist 会再试。
    }
  }

  /// 忘记某个会话（服务端确认已无该 session，或用户主动清理）。
  Future<void> forget(String sessionKey) async {
    final String key = sessionKey.trim();
    _memo.remove(key);
    final Future<void> Function(String)? del = remove;
    if (del == null) return;
    try {
      await del(key);
    } on Object {
      // 忽略。
    }
  }

  /// 清空进程内缓存（不动已落盘内容）。
  void clearMemo() => _memo.clear();

  /// 各会话的「队尾」future —— 用于把同一会话的调用**串成一条链**。
  ///
  /// ⚠ 为什么必须串行：`/state/chat/completions` 是**有状态写**接口，
  /// 服务端按 `session_id` 在缓存里就地推进 state。**同一 session 并发写
  /// 会让两次解码互相踩 state**（结果错乱 / 400 / 缓存被写坏），
  /// 这是 RWKV 官方文档与 `PITFALLS.md` 都点名的硬约束。
  ///
  /// 而写书时**多章并行**（`cfg.concurrency` 个 lane），章内又是「组长 + 9 写手」
  /// 多通道轮转派活（旧 team 工艺同一写手可能被派到多段）—— 同一个会话在同一
  /// 时刻被两条执行流拿到是完全可能的。解法不是在调用点到处加锁，而是
  /// **在这里把同一会话的调用排队**：不同会话（不同章 / 不同角色）仍并行，
  /// 同一会话的调用依次推进 state。
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// 当前排队中的会话数（观测用）。
  int get pendingSessionCount => _tails.length;

  /// 把 [body] 排到 `sessionKey` 这条链的队尾执行，返回它自己的结果。
  ///
  /// 前一个任务**无论成败**都会放行下一个（绝不让一次失败把整条链锁死）。
  Future<T> runExclusive<T>(String sessionKey, Future<T> Function() body) {
    final String key = sessionKey.trim();
    if (key.isEmpty) return Future<T>.sync(body);
    final Future<void> prev = _tails[key] ?? Future<void>.value();
    final Completer<T> out = Completer<T>();
    final Future<void> tail = prev.then((_) async {
      try {
        out.complete(await body());
      } on Object catch (e, s) {
        out.completeError(e, s);
      }
    });
    _tails[key] = tail;
    // 队尾回收：只在自己仍是链尾时清掉，避免 Map 随会话数无限增长。
    tail.whenComplete(() {
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
    return out.future;
  }

  /// 生成一个**客户端**会话 ID。
  ///
  /// 刻意带 `nc-` 前缀，并由「本机毫秒 + **进程内单调序号** + 随机后缀」三段组成：
  ///   * 毫秒给出跨重启的粗粒度区分；
  ///   * 单调序号保证**同一毫秒内连续创建多个会话也不会重复** —— 这是真实故障点：
  ///     旧实现只用了 `DateTime.now().microsecond * 7919 % 1000003`，在
  ///     Windows 上 `microsecond` 分辨率不足，**紧密循环 200 次只能得到 6 个不同值**；
  ///     而写书时「每章 × 每个角色」都是在极短时间内批量建会话的 ——
  ///     ID 一旦撞车，服务端就会把两条独立的 state 链当成同一条，
  ///     正好复现用户报的「服务器不知道哪个 state 对应哪个并发」；
  ///   * 随机后缀兜住「多进程/多设备」场景。
  String newSessionId() {
    _sessionSeq++;
    final int ms = DateTime.now().millisecondsSinceEpoch;
    final String seq = _sessionSeq.toRadixString(36);
    final String rand = _sessionRng
        .nextInt(1 << 20)
        .toRadixString(36)
        .padLeft(4, '0');
    return 'nc-$ms-$seq-$rand';
  }

  /// 进程内单调序号（[newSessionId] 的唯一性来源）。
  static int _sessionSeq = 0;

  static final Random _sessionRng = Random();

  /// 超出 [maxStoredChars] 时从最旧的轮次开始丢（成对丢，保持 user/assistant 对齐）。
  void _truncate(RwkvCloudSessionRecord record) {
    int total = 0;
    for (final ChatMessage m in record.transcript) {
      total += m.content.length;
    }
    if (total <= maxStoredChars) return;
    final List<ChatMessage> kept = List<ChatMessage>.of(record.transcript);
    while (total > maxStoredChars && kept.length >= 2) {
      total -= kept[0].content.length;
      total -= kept[1].content.length;
      kept.removeRange(0, 2);
    }
    record.transcript
      ..clear()
      ..addAll(kept);
  }
}
