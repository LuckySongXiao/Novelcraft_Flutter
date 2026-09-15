// RWKV 会话层：把多次 chat 请求聚合到同一个 state 演化链上。
//
// 典型场景：
// 1. **同一 Agent 的多轮对话**：新对话开 session，每一步都派生 state；
//    下一轮直接 resume sessionId → 继承上一轮世界观记忆，不必重新把
//    2000 字历史塞进 systemPrompt。
// 2. **工作流多步骤**：WorkflowEngine 给每个 workflow 分配一个 sessionId；
//    CreateWorldSetting → DesignCharacters → GenerateOutline → GenerateChapters
//    四步全共享 state，前一步的输出自动进入后续步骤的「隐性记忆」。
// 3. **批量并发**：同一个引擎上可以跑 N 个并行 session，每个 session
//    独立 state（LRU 控制内存），并发度由 [Semaphore] 限制。
//
// 与 [RwkvEngine] 关系：
// - [RwkvSession] 只做会话级编排（记录 message log、管理 stateId 指针、
//   负责快照/恢复）；真正的 HTTP 调用、token 计数、state 序列化交给 Engine。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../models/chat.dart';
import '../utils/semaphore.dart';
import 'rwkv_state.dart';

/// 会话状态。
enum RwkvSessionStatus {
  /// 刚创建，还未发送任何请求。
  fresh,

  /// 进行中（有 1+ 次成功推理）。
  active,

  /// 已暂停（state 仍然存在于 cache）。
  paused,

  /// 已关闭（state 已清除）。
  closed,
}

/// RWKV 会话实例。
class RwkvSession {
  /// 全局唯一会话 ID。
  final String sessionId;

  /// 人类可读标签（例如「OutlineAgent-玄穹剑主」「Workflow-7 卷生成」）。
  final String label;

  /// 所属引擎日志。
  final Logger _logger;

  /// 会话状态。
  RwkvSessionStatus _status = RwkvSessionStatus.fresh;

  /// 当前持有的 state ID（null = 全新，下一次推理从 0 开始预编码）。
  String? _currentStateId;

  /// 完整消息历史（用于生成新请求时的 messages 拼接，同时为 UI 回放准备）。
  final List<ChatMessage> _history = <ChatMessage>[];

  /// 创建时间。
  final DateTime createdAt = DateTime.now();

  /// 最后活动时间。
  DateTime _lastActivity = DateTime.now();

  /// 累计 token 处理量（仅供观测）。
  int _totalTokens = 0;

  /// 内部信号量：**单个 session 串行化**。
  /// RWKV 的 state 演化是有严格顺序的单链，不能并行推理同一个 session，
  /// 否则 state 演化分支错乱 → 上下文丢失。
  final Semaphore _mutex = Semaphore(1);

  RwkvSession({
    required this.sessionId,
    required this.label,
    required Logger logger,
  }) : _logger = logger;

  RwkvSessionStatus get status => _status;
  String? get currentStateId => _currentStateId;
  List<ChatMessage> get history => List<ChatMessage>.unmodifiable(_history);
  DateTime get lastActivity => _lastActivity;
  int get totalTokens => _totalTokens;
  int get turnCount => _history.where((m) => m.role == ChatRole.assistant).length;

  /// 追加一条用户/助手消息（引擎调用完 chat 后回填）。
  void appendMessage(ChatMessage msg) {
    _history.add(msg);
    _lastActivity = DateTime.now();
    if (_status == RwkvSessionStatus.fresh) {
      _logger.fine('会话 $label 从 fresh 进入 active，首条消息长度=${msg.content.length}');
      _status = RwkvSessionStatus.active;
    }
  }

  /// 清空历史（重放转录本前调用，避免把同一批轮次记两遍）。
  ///
  /// ⚠ 只清本地记录，**不清服务端 state** —— 重放本来就是要重建服务端那份。
  /// 清完之后 `history` 会由重放逻辑重新填满，因此后续轮仍走「只发增量」。
  void resetHistory() {
    if (_history.isNotEmpty) {
      _logger.fine('会话 $label 清空本地历史（${_history.length} 条，准备重放）');
    }
    _history.clear();
  }

  /// 更新当前 state 指针 + token 计数。
  void advanceState(String newStateId, int tokenDelta) {
    _currentStateId = newStateId;
    _totalTokens += tokenDelta;
    _lastActivity = DateTime.now();
    _logger.finer('会话 $label state 前进: $newStateId, delta_tokens=$tokenDelta, total=$_totalTokens');
  }

  /// 标记为暂停（用户手动关闭对话，但 state 保留在 cache）。
  void pause() {
    if (_status != RwkvSessionStatus.closed) {
      _status = RwkvSessionStatus.paused;
      _logger.fine('会话 $label 已暂停（state 仍在缓存）');
    }
  }

  /// 恢复暂停的会话。
  void resume() {
    if (_status == RwkvSessionStatus.paused) {
      _status = RwkvSessionStatus.active;
      _logger.fine('会话 $label 恢复为 active');
    }
  }

  /// 关闭会话（state 会在 cache 里被 dropSession 清除）。
  void close() {
    _status = RwkvSessionStatus.closed;
    _logger.fine('会话 $label 关闭，准备回收 state');
  }

  /// 串行化执行单轮会话内的推理（保证 state 顺序正确）。
  Future<R> runSerialized<R>(Future<R> Function() action) async {
    await _mutex.acquire();
    try {
      return await action();
    } finally {
      _mutex.release();
    }
  }
}

/// 会话仓库 + 生命周期。
class RwkvSessionManager {
  final Logger _logger;
  final Map<String, RwkvSession> _sessions = <String, RwkvSession>{};
  final RwkvStateCache stateCache;

  RwkvSessionManager({
    required this.stateCache,
    Logger? logger,
  }) : _logger = logger ?? Logger('RwkvSessionManager');

  int get activeCount =>
      _sessions.values.where((s) => s.status != RwkvSessionStatus.closed).length;

  /// 创建新会话。
  RwkvSession create({String label = ''}) {
    final id = rwkvGenerateId('sess_');
    final s = RwkvSession(
      sessionId: id,
      label: label.isEmpty ? '会话-${id.substring(id.length - 6)}' : label,
      logger: _logger,
    );
    _sessions[id] = s;
    _logger.fine('创建 RWKV 会话: ${s.label} ($id)');
    return s;
  }

  /// 获取会话；不存在返回 null。
  RwkvSession? get(String sessionId) => _sessions[sessionId];

  /// 获取或创建（幂等）。
  RwkvSession getOrCreate(String? sessionId, {String label = ''}) {
    if (sessionId != null) {
      final s = _sessions[sessionId];
      if (s != null) {
        if (s.status == RwkvSessionStatus.paused) s.resume();
        return s;
      }
    }
    return create(label: label);
  }

  /// 关闭并清理会话 state。
  bool close(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null) return false;
    s.close();
    stateCache.dropSession(sessionId);
    return true;
  }

  /// 批量关闭全部会话。
  int closeAll() {
    final ids = _sessions.keys.toList(growable: false);
    for (final id in ids) {
      close(id);
    }
    return ids.length;
  }

  /// 清理长期不活动的会话（ttl 内无任何交互）。
  int evictIdle(Duration ttl) {
    final now = DateTime.now();
    final idle = _sessions.values
        .where((s) =>
            s.status != RwkvSessionStatus.closed &&
            now.difference(s.lastActivity) > ttl)
        .toList(growable: false);
    for (final s in idle) {
      close(s.sessionId);
    }
    return idle.length;
  }
}
