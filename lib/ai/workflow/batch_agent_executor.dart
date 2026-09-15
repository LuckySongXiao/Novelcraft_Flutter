// BatchAgentExecutor —— 把多个 Agent 的任务攒成**一次**原生批量补全。
//
// 为什么值得做：实测（`api-7b.rwkvos.com` / albatross-1.3.0）
//   8 个 Agent 任务 → **1 次 HTTP POST**（`contents` 长度 8）
//   墙钟 2.46s，返回 8 条带 `index` 的 choices（index 覆盖 0..7）
// 对比逐个串行发，省掉 N-1 次跨境 RTT（外网 → CF → 境内 GPU，单次 TLS+RTT
// 就 ~1.5s，是纯损耗）。这是「最大化 3×4090 吞吐」最直接的一刀。
//
// ⚠ 三个来自实测的硬约束（PITFALLS §27.3 / §30.2 / §31.4）：
//   1. **`stop_tokens` 必须显式传**，否则每个槽位返回空文本
//      （HTTP 200 + index 正确，极易误判成模型问题）。由 `RwkvBatchRequest` 默认带上。
//   2. **SSE 里不同 `index` 的事件交错到达** → 必须按 index 分组缓存
//      （由 `RwkvBatchClient.chatStream` 负责），最后再按 index 排序回填。
//   3. **`finish_reason` 不可信**（流式结束一律无条件发 `stop`），
//      不能用它判断是否被 max_tokens 截断；也不要依赖流式 `usage`（服务端不返回）。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../agents/agent.dart';
import '../utils/output_sanitizer.dart';
import '../models/batch_chat.dart';
import '../rwkv/rwkv_batch_client.dart';
import 'workflow.dart';

/// 一个待批量执行的条目。
class _BatchEntry {
  final BaseAgent agent;
  final WorkflowTask task;
  final Completer<AgentTaskResult> completer = Completer<AgentTaskResult>();
  final DateTime enqueuedAt = DateTime.now();

  _BatchEntry(this.agent, this.task);

  /// 分组键：同一 [batchGroupId] 才放一批（HANDOFF §28 需求）。
  ///
  /// 典型用法：Director 的 prompt 特别长，塞进同一批会把其他短 prompt 的
  /// 首 token 时间拖到跟它一样 —— 给它单独的 group 就能隔离。
  String get groupId {
    final Object? g = task.parameters['batchGroupId'];
    if (g is String && g.trim().isNotEmpty) return g.trim();
    return '__default__';
  }
}

/// 批量 Agent 执行器。
class BatchAgentExecutor {
  /// 一批最多几条（同时受服务端 `available_bsz` 约束，客户端只做保守上限）
  final int maxBatchSize;

  /// 攒批窗口：到点即发，不等满
  final Duration batchWaitWindow;

  final RwkvBatchClient batchClient;
  final Logger _logger;

  /// 每个分组当前攒着的条目
  final Map<String, List<_BatchEntry>> _pending =
      <String, List<_BatchEntry>>{};
  final Map<String, Timer> _flushTimers = <String, Timer>{};

  bool _disposed = false;

  /// 累计统计（观测用）
  int _totalSubmits = 0;
  int _totalHttpPosts = 0;

  BatchAgentExecutor({
    required this.batchClient,
    this.maxBatchSize = 8,
    this.batchWaitWindow = const Duration(milliseconds: 100),
    Logger? logger,
  }) : _logger = logger ?? Logger('BatchAgentExecutor') {
    _logger.info('BatchAgentExecutor init: maxBatchSize=$maxBatchSize '
        'window=$batchWaitWindow');
  }

  /// 提交一个 Agent 任务，返回它的执行结果。
  ///
  /// 内部会攒批：**攒满 [maxBatchSize] 或 [_pending] 窗口到期，谁先到谁触发**。
  Future<AgentTaskResult> submit(BaseAgent agent, WorkflowTask task) {
    if (_disposed) {
      return Future<AgentTaskResult>.value(AgentTaskResult(
        isSuccess: false,
        errorMessage: 'BatchAgentExecutor 已 dispose',
      ));
    }
    final _BatchEntry entry = _BatchEntry(agent, task);
    final String group = entry.groupId;
    final List<_BatchEntry> list =
        _pending.putIfAbsent(group, () => <_BatchEntry>[]);
    list.add(entry);
    _totalSubmits++;

    if (list.length >= maxBatchSize) {
      _flushTimers.remove(group)?.cancel();
      // 不 await：让本调用立即返回 future，批量在后台跑
      unawaited(_flush(group));
    } else if (!_flushTimers.containsKey(group)) {
      _flushTimers[group] = Timer(batchWaitWindow, () {
        _flushTimers.remove(group);
        unawaited(_flush(group));
      });
    }
    return entry.completer.future;
  }

  /// 立刻冲掉所有待发批次（例如工作流收尾时）。
  Future<void> flushAll() async {
    for (final String g in _pending.keys.toList(growable: false)) {
      _flushTimers.remove(g)?.cancel();
      await _flush(g);
    }
  }

  /// 统计：提交数 / 实际 HTTP POST 数（用来验证「攒批真的省了请求」）。
  Map<String, int> get stats => <String, int>{
        'submits': _totalSubmits,
        'httpPosts': _totalHttpPosts,
        'pendingGroups': _pending.length,
      };

  void dispose() {
    _disposed = true;
    for (final Timer t in _flushTimers.values) {
      t.cancel();
    }
    _flushTimers.clear();
    _pending.clear();
  }

  // -------------------------------------------------------------------------

  Future<void> _flush(String group) async {
    final List<_BatchEntry>? entries = _pending.remove(group);
    if (entries == null || entries.isEmpty) return;

    // ① 组 prompt（每个 Agent 自己拼，保证与单路等价）
    // ⚠ `buildPromptForBatch` 返回 null = 该 Agent 未实现批量 prompt。
    //   这类条目**直接判失败并说明原因**，绝不塞一个兜底文本去降质。
    final List<String> prompts = <String>[];
    final List<_BatchEntry> valid = <_BatchEntry>[];
    for (final _BatchEntry e in entries) {
      final String? p =
          e.agent.buildPromptForBatch(e.task.taskType, e.task.parameters);
      if (p == null || p.trim().isEmpty) {
        if (!e.completer.isCompleted) {
          e.completer.complete(AgentTaskResult(
            isSuccess: false,
            errorMessage: 'Agent ${e.agent.name} 未实现 buildPromptForBatch '
                '（返回到 null），不能参与攒批。\n'
                '请在 ${e.agent.runtimeType} 里覆写该方法，产出与单路等价的'
                '自包含 prompt；或在配置里关掉它的攒批开关。',
            metadata: <String, dynamic>{'batch': true, 'unsupported': true},
          ));
        }
      } else {
        prompts.add(p);
        valid.add(e);
      }
    }
    if (valid.isEmpty) return;
    if (valid.length != entries.length) {
      _logger.warning('冲批 group=$group：${entries.length - valid.length} 个条目'
          '因未实现批量 prompt 被剔除，实际发 ${valid.length} 条');
    }
    entries.clear();
    entries.addAll(valid);
    if (prompts.length == 1) {
      // 只有一条就没必要走批量（还要多付一次批处理的固定开销）
      await _runSingle(group, entries.single, prompts.single);
      return;
    }

    _logger.info('冲批 group=$group：${prompts.length} 个 Agent '
        '(${entries.map((_BatchEntry e) => e.agent.name).join(", ")})');
    final Stopwatch sw = Stopwatch()..start();
    try {
      final RwkvBatchRequest req = RwkvBatchRequest(
        contents: prompts,
        // ⚠ 与单路对齐：`executeTaskWithAI` 用的是 temperature 0.7。
        //   注意批量整批只有**一个** temperature，无法逐槽位区分。
        temperature: 0.7,
        maxTokens: _maxTokensFor(entries),
        // 批量流式用官方默认刷新粒度 8（文档 §7）
        stream: false,
        metrics: true,
      );
      _totalHttpPosts++;
      final List<String?> texts = await batchClient.chat(req);
      sw.stop();

      // ② 按 index 回填（client 已按 index 对齐，这里只做结构化）
      _logger.info('冲批完成 group=$group：${prompts.length} 槽位，'
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s，'
          'HTTP POST=$_totalHttpPosts/$_totalSubmits 次');
      for (int i = 0; i < entries.length; i++) {
        final _BatchEntry e = entries[i];
        final String raw = (i < texts.length ? texts[i] : null) ?? '';
        if (e.completer.isCompleted) continue;
        // ⚠ **必须过滤思考前缀**：批量路由不受 `think_type` 控制（实测 5 种取值
        //   都一样），模型会偶发自发吐 `<think>好的，用户让我…`；`max_tokens`
        //   一旦在"思考中"用尽就永远没有闭合标签，整段推理会被当成正文。
        //   单路走 /v1/chat/completions 时由服务端管住，批量这边只能自己清。
        final String text = AIOutputSanitizer.extractVisibleContent(raw);
        if (text.isEmpty && raw.trim().isNotEmpty) {
          _logger.warning('槽位 $i（${e.agent.name}）清理后为空 —— 多半是 max_tokens '
              '被思考过程吃满了，建议提高该任务的 maxTokens');
        }
        try {
          // ⚠ 单个槽位失败不影响整批：分别结构化
          e.completer.complete(
              e.agent.processBatchResponse(e.task.taskType, e.task.parameters, text));
        } on Object catch (err) {
          e.completer.complete(AgentTaskResult(
            isSuccess: false,
            errorMessage: '批量结果结构化失败：$err',
          ));
        }
      }
      _totalSubmits = _totalSubmits; // 无操作，保留可读性
    } on Object catch (e, st) {
      _logger.severe('冲批失败 group=$group', e, st);
      // 整批失败 → 每个条目各自失败（**不做静默降级为串行**，
      // 否则用户会以为批量生效了却在付串行的代价）
      for (final _BatchEntry en in entries) {
        if (en.completer.isCompleted) continue;
        en.completer.complete(AgentTaskResult(
          isSuccess: false,
          errorMessage: '批量执行失败：$e',
          metadata: <String, dynamic>{'batch': true, 'batchSize': entries.length},
        ));
      }
    }
  }

  /// 单条时退回普通路径：仍用批量客户端（保证参数一致），但只有 1 个槽位。
  Future<void> _runSingle(
      String group, _BatchEntry entry, String prompt) async {
    try {
      _totalHttpPosts++;
      final List<String?> texts = await batchClient.chat(RwkvBatchRequest(
        contents: <String>[prompt],
        temperature: 0.7,
        maxTokens: _maxTokensFor(<_BatchEntry>[entry]),
        metrics: true,
      ));
      final String text = texts.isEmpty ? '' : (texts.first ?? '');
      if (!entry.completer.isCompleted) {
        entry.completer.complete(entry.agent
            .processBatchResponse(entry.task.taskType, entry.task.parameters, text));
      }
    } on Object catch (e) {
      if (!entry.completer.isCompleted) {
        entry.completer.complete(
            AgentTaskResult(isSuccess: false, errorMessage: '$e'));
      }
    }
  }

  /// 取该批的 `max_tokens`。
  ///
  /// 优先级：任务参数里的显式 `maxTokens` > `BaseAgent.resolveRwkvMaxTokens(taskType)`
  /// （与单路 RWKV 路径**同一套映射**）> 1024 兜底；
  /// 整批取**最大值**（批量接口是"每个 choice 各自最多生成 N 个 token"，
  /// 但请求里只能给一个上限）。
  int _maxTokensFor(List<_BatchEntry> entries) {
    int best = 0;
    int fallback = 1024;
    for (final _BatchEntry e in entries) {
      final Object? v = e.task.parameters['maxTokens'];
      if (v is num) {
        final int iv = v.toInt();
        if (iv > best) best = iv;
      } else {
        // 与单路一致：按 taskType 查 Agent 自己的映射
        final int mapped = e.agent.resolveRwkvMaxTokens(e.task.taskType);
        if (mapped > fallback) fallback = mapped;
      }
    }
    if (best == 0) best = fallback;
    // 与服务端默认 8192 对齐前先夹一下，避免单个长任务把整批拖爆
    return best > 4096 ? 4096 : best;
  }
}
