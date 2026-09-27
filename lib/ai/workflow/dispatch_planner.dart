// 工作流分派规划器 —— 「跑之前探测最大并发 → 存配置 → 主 Agent 自主定分派数」。
//
// 数据流：
//   executeWorkflow 前
//     ├─ probeAndPersist()   探测 RWKV 最大并发（服务端 available_bsz，
//     │                      失败回退本地配置的会话上限），60s TTL 缓存，
//     │                      持久化到 KVStore `ai_config/rwkv.probed_concurrency`
//     ├─ askMainAgentDecision() 让**主 Agent**（双代理的 Main provider）对
//     │                      「本次分派多少个子 Agent 并行」给出整数决策
//     └─ decide()            生效值 = clamp(主Agent决策 ?? 探测值, 1, 探测值)
//                            → 引擎用它临时抬高/压低 TaskQueue 并发上限
//
// 纯 Dart（存储走回调注入，对齐 rwkv_session_archive 先例）；失败全部折叠：
// 探测/决策任何一步失败都回退到「按原并发执行」，绝不阻塞工作流。
library;

import 'dart:convert';

typedef JsonScopeReader = Future<String?> Function(String scope, String key);
typedef JsonScopeWriter =
    Future<void> Function(String scope, String key, String json);

/// 一次分派规划的结果快照。
class DispatchPlan {
  const DispatchPlan({
    required this.probedMax,
    required this.source,
    required this.mainAgentDecision,
    required this.effective,
    required this.probedAtMs,
  });

  /// 探测到的最大并发（服务端容量或本地配置值）。
  final int probedMax;

  /// 探测来源：`server`（服务端状态）/ `config`（本地配置回退）。
  final String source;

  /// 主 Agent 的决策值（0 = 未表态 / 决策失败）。
  final int mainAgentDecision;

  /// 最终生效的并行分派数（已 clamp 到 [1, probedMax]）。
  final int effective;

  final int probedAtMs;

  Map<String, Object?> toMap() => <String, Object?>{
    'probedMax': probedMax,
    'source': source,
    'mainAgentDecision': mainAgentDecision,
    'effective': effective,
    'probedAtMs': probedAtMs,
  };

  static DispatchPlan fromMap(Map<String, Object?> m) => DispatchPlan(
    probedMax: (m['probedMax'] as num?)?.toInt() ?? 0,
    source: (m['source'] as String?) ?? 'config',
    mainAgentDecision: (m['mainAgentDecision'] as num?)?.toInt() ?? 0,
    effective: (m['effective'] as num?)?.toInt() ?? 0,
    probedAtMs: (m['probedAtMs'] as num?)?.toInt() ?? 0,
  );
}

/// 分派规划器。
class WorkflowDispatchPlanner {
  WorkflowDispatchPlanner({
    required JsonScopeReader readJson,
    required JsonScopeWriter writeJson,
    required Future<int?> Function() probe,
    required int Function() configuredFallback,
    Future<String?> Function(String prompt)? askMainAgent,
    Duration probeTtl = const Duration(seconds: 60),
  }) : _readJson = readJson,
       _writeJson = writeJson,
       _probe = probe,
       _configuredFallback = configuredFallback,
       _askMainAgent = askMainAgent,
       _probeTtl = probeTtl;

  /// KVStore 作用域/键（与 ai_config 同域：这是小配置，不是大文本）。
  static const String scope = 'ai_config';
  static const String key = 'rwkv.probed_concurrency';

  final JsonScopeReader _readJson;
  final JsonScopeWriter _writeJson;
  final Future<int?> Function() _probe;
  final int Function() _configuredFallback;
  final Future<String?> Function(String prompt)? _askMainAgent;
  final Duration _probeTtl;

  int _cachedMax = 0;
  String _cachedSource = 'config';
  DateTime? _cachedAt;

  /// 跑之前探测最大并发并持久化；带 TTL 缓存（默认 60s 内不重复探测）。
  Future<int> probeAndPersist() async {
    if (_cachedAt != null &&
        _cachedMax > 0 &&
        DateTime.now().difference(_cachedAt!) < _probeTtl) {
      return _cachedMax;
    }
    int probed = 0;
    String source = 'config';
    try {
      final int? server = await _probe();
      if (server != null && server > 0) {
        probed = server;
        source = 'server';
      }
    } on Object {
      // 探测失败 → 回退本地配置值
    }
    if (probed <= 0) probed = _configuredFallback();
    probed = probed.clamp(1, 4096);
    _cachedMax = probed;
    _cachedSource = source;
    _cachedAt = DateTime.now();
    try {
      await _writeJson(
        scope,
        key,
        jsonEncode(<String, Object?>{
          'probedMax': probed,
          'source': source,
          'probedAtMs': _cachedAt!.millisecondsSinceEpoch,
        }),
      );
    } on Object {
      // 持久化失败不阻塞（内存里仍有效）
    }
    return probed;
  }

  /// 读取上次持久化的规划快照（无 / 损坏 → null）。
  Future<DispatchPlan?> lastPlan() async {
    try {
      final String? raw = await _readJson(scope, key);
      if (raw == null || raw.isEmpty) return null;
      final Object? v = jsonDecode(raw);
      if (v is Map) {
        return DispatchPlan.fromMap(
          v.map((Object? k, Object? val) => MapEntry('$k', val)),
        );
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// 让主 Agent 对「本次分派多少个子 Agent 并行」表态（纯提示词，只回整数）。
  String buildDispatchQuestion({
    required String workflowName,
    required int taskCount,
    required int parallelizable,
    required int probedMax,
  }) {
    return '你是工作流「$workflowName」的主 Agent（调度者）。本次共 $taskCount 个任务，'
        '其中 $parallelizable 个可立即并行执行；服务端探测到的最大并发为 $probedMax。\n'
        '请作为主 Agent 决策：本次分派多少个子 Agent 并行执行任务？\n'
        '权衡：任务多且相互独立时用大并行度吃满算力；依赖链长或任务本身耗 token 时'
        '适当收窄避免尾延迟。只回复一个 $probedMax 以内的正整数，禁止任何其它内容。';
  }

  /// 解析主 Agent 的回复（提取首个整数；失败返回 null = 未表态）。
  int? parseDispatchDecision(String? raw) {
    final RegExpMatch? m = RegExp(r'\d+').firstMatch((raw ?? '').trim());
    if (m == null) return null;
    return int.tryParse(m.group(0)!);
  }

  /// 完整决策：主 Agent 表态 → clamp 到探测值内；未表态 → 用满探测值。
  Future<DispatchPlan> decide({
    required String workflowName,
    required int taskCount,
    required int parallelizable,
    int? mainAgentDecision,
  }) async {
    final int probed = await probeAndPersist();
    int? decision =
        mainAgentDecision ??
        parseDispatchDecision(
          await _askMainAgent?.call(
                buildDispatchQuestion(
                  workflowName: workflowName,
                  taskCount: taskCount,
                  parallelizable: parallelizable,
                  probedMax: probed,
                ),
              ) ??
              '',
        );
    if (decision != null && (decision < 1 || decision > probed)) {
      decision = decision.clamp(1, probed);
    }
    final int effective = (decision == null || decision < 1)
        ? probed
        : decision.clamp(1, probed);
    final DispatchPlan plan = DispatchPlan(
      probedMax: probed,
      source: _cachedSource,
      mainAgentDecision: decision ?? 0,
      effective: effective,
      probedAtMs: _cachedAt?.millisecondsSinceEpoch ?? 0,
    );
    // 持久化**完整**规划（含主Agent表态与生效值），与 DispatchPlan.fromMap
    // 的读取字段对齐 —— 此前只写 probeAndPersist 的三元组，
    // 导致 lastPlan() 永远读回 0（读写不对称）。
    try {
      await _writeJson(scope, key, jsonEncode(plan.toMap()));
    } on Object {
      // 持久化失败不阻塞（内存里仍有效）
    }
    return plan;
  }
}
