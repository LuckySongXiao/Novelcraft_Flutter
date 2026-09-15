// 世界观分支（P3-23）：同一会话下并行推演多条剧情线（BE / A线 / B线 / C线）。
//
// ⚠ 关键实测结论（PITFALLS §33.3）：
//
//  官方完整文档里写着 `POST /multi_state/chat/completions`（可分叉 stateful 补全，
//  `session_id` + `dialogue_idx`，state 存为 `<session_id>:<dialogue_idx>`），
//  但它被标为「**可选**」能力 —— **线上 1.3.0 实测 404**。
//
//  ⇒ 所以这里做成**三级能力降级**，绝不假设路由存在：
//      L1 `multi_state` 可用  → 真·服务端 O(1) 分叉（一次 prefill 出多条线）
//      L2 仅 `state/chat` 可用 → 每条分支用**独立 session_id** 模拟分叉：
//                               首次播种父上下文（付一次 prefill），之后各自 O(1) 增量
//      L3 非 RWKV Provider     → 串行重编码 + 空 branches，并打 warning
//
//  判定「可用」的方式：`RwkvBatchClient.routeExists()`（404 → 不存在）。
library;

import 'dart:async';

import 'package:logging/logging.dart';

/// 一条世界观分支。
class WorkflowBranch {
  /// 分支标识（`BE` / `A` / `B` / `C`…），用于拼独立 sessionId
  final String branchId;

  /// 人类可读标签
  final String? label;

  /// 分叉点的父节点号（`multi_state` 模式用；根节点为 0）
  final int dialogueIdx;

  /// 父 state 标识（`<session_id>:<idx>`）；为 null 表示从根分叉
  final String? parentStateId;

  /// **分叉提示词**：这条分支与父节点不同的那部分指令
  /// （例如「如果主角选择复仇…」/「如果主角选择放手…」）
  final String divergencePrompt;

  /// 分支自己的参数（会与调用方给的公共参数合并）
  final Map<String, dynamic> parameters;

  /// 服务端为该分支分配的最新节点号（首次生成本地先用 [dialogueIdx]）
  int allocatedIdx;

  /// 该分支本次产出的文本
  String text;

  /// 是否成功
  bool isSuccess;

  /// 错误信息
  String? errorMessage;

  /// 本分支是否走了降级路径（独立 session 播种，而不是真·服务端分叉）
  bool usedFallback;

  WorkflowBranch({
    required this.branchId,
    required this.divergencePrompt,
    this.label,
    this.dialogueIdx = 0,
    this.parentStateId,
    Map<String, dynamic>? parameters,
    int? allocatedIdx,
    this.text = '',
    this.isSuccess = false,
    this.errorMessage,
    this.usedFallback = false,
  })  : parameters = parameters ?? <String, dynamic>{},
        allocatedIdx = allocatedIdx ?? dialogueIdx;

  /// 服务端保存 state 的实际键（文档：`<session_id>:<dialogue_idx>`）
  String stateKey(String baseSessionId) => '$baseSessionId:$allocatedIdx';

  /// 降级路径下该分支独自使用的 sessionId。
  ///
  /// 实测 `session_id` 接受任意字符串（含 `:` 和 `/`），
  /// 所以 `wf42:branch-BE` 这样一个 id 完全可用。
  String fallbackSessionId(String baseSessionId) =>
      '$baseSessionId:branch-$branchId';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'branchId': branchId,
        'label': label,
        'dialogueIdx': dialogueIdx,
        'allocatedIdx': allocatedIdx,
        'parentStateId': parentStateId,
        'divergencePrompt': divergencePrompt,
        'parameters': parameters,
        'text': text,
        'isSuccess': isSuccess,
        'errorMessage': errorMessage,
        'usedFallback': usedFallback,
      };

  factory WorkflowBranch.fromJson(Map<String, dynamic> json) => WorkflowBranch(
        branchId: json['branchId'] as String,
        label: json['label'] as String?,
        dialogueIdx: (json['dialogueIdx'] as num?)?.toInt() ?? 0,
        allocatedIdx: (json['allocatedIdx'] as num?)?.toInt(),
        parentStateId: json['parentStateId'] as String?,
        divergencePrompt: (json['divergencePrompt'] as String?) ?? '',
        parameters: (json['parameters'] as Map<String, dynamic>?) ??
            <String, dynamic>{},
        text: (json['text'] as String?) ?? '',
        isSuccess: (json['isSuccess'] as bool?) ?? false,
        errorMessage: json['errorMessage'] as String?,
        usedFallback: (json['usedFallback'] as bool?) ?? false,
      );
}

/// 分叉能力级别 —— 由 [WorkflowBranchRunner] 探测后决定。
enum BranchCapability {
  /// 服务端支持 `/multi_state/chat/completions` → 真·O(1) 分叉
  multiState,

  /// 只有 `/state/chat/completions` → 独立 session 播种模拟分叉
  sessionSeed,

  /// 完全没有 state 能力（非 RWKV Provider）→ 串行重编码
  serialOnly,
}

extension BranchCapabilityX on BranchCapability {
  bool get isTrueForking => this == BranchCapability.multiState;

  String get label => switch (this) {
        BranchCapability.multiState => '多状态分叉（服务端 O(1)）',
        BranchCapability.sessionSeed => '独立会话播种（客户端模拟分叉）',
        BranchCapability.serialOnly => '串行重编码（无 state 能力）',
      };
}

/// 支持 state 分叉的模型契约。
abstract class IBranchingChatModel {
  /// 探测服务端分叉能力（内部应做缓存，别每次调用都发请求）。
  Future<BranchCapability> probeBranchCapability();

  /// 真·分叉：`session_id` + `dialogue_idx`。
  /// 返回 (文本, 服务端新分配的 dialogue_idx)。
  Future<(String text, int? newIdx)> multiStateChat({
    required String sessionId,
    required int dialogueIdx,
    required String prompt,
    int? maxTokens,
  });

  /// 单分支有状态续跑：`session_id` + `contents`（恰好 1 条）。
  Future<String> statefulChat({
    required String sessionId,
    required String prompt,
    int? maxTokens,
  });
}

/// 分支运行器：探测能力 → 选路径 → 跑完全部分支。
class WorkflowBranchRunner {
  /// 具备分叉能力的模型（可空 = 非 RWKV Provider）
  final IBranchingChatModel? model;

  /// 无分叉能力时的**串行**兜底（接收完整 prompt，返回文本）。
  ///
  /// 由调用方注入（通常是 Provider 的普通 `chat`）。为空且 [model] 也不支持时，
  /// 所有分支会直接标记失败并给出明确原因，而不是静默返回空。
  final Future<String> Function(String prompt, int? maxTokens)? serialChat;

  /// 并发跑几条分支（服务端会自己排队，这里只做保守限流）
  final int maxParallelBranches;

  final Logger _logger;

  WorkflowBranchRunner({
    required this.model,
    this.serialChat,
    this.maxParallelBranches = 4,
    Logger? logger,
  }) : _logger = logger ?? Logger('WorkflowBranchRunner');

  /// 跑一批世界观分支。
  ///
  /// [seedContext] 是分叉点之前的**公共上下文**（世界观/人物/前情）。
  /// [baseSessionId] 是这条工作流会话的 id。
  Future<List<WorkflowBranch>> run(
    List<WorkflowBranch> branches, {
    required String baseSessionId,
    String seedContext = '',
    int? maxTokens,
  }) async {
    if (branches.isEmpty) return branches;

    BranchCapability cap = BranchCapability.serialOnly;
    if (model != null) {
      try {
        cap = await model!.probeBranchCapability();
      } on Object catch (e) {
        _logger.warning('分叉能力探测失败，按串行降级：$e');
        cap = BranchCapability.serialOnly;
      }
    } else if (serialChat != null) {
      // 非 RWKV Provider：按 HANDOFF 要求打明确的降级日志
      _logger.warning('Provider 不支持 O(1) state 分叉，'
          '降级为串行重编码（branches 将不带服务端 state）');
    }
    _logger.info('世界观分支：${branches.length} 条，能力档=${cap.label}');

    switch (cap) {
      case BranchCapability.multiState:
        await _runMultiState(branches,
            baseSessionId: baseSessionId,
            seedContext: seedContext,
            maxTokens: maxTokens);
      case BranchCapability.sessionSeed:
        await _runSessionSeed(branches,
            baseSessionId: baseSessionId,
            seedContext: seedContext,
            maxTokens: maxTokens);
      case BranchCapability.serialOnly:
        await _runSerial(branches,
            seedContext: seedContext, maxTokens: maxTokens);
    }
    return branches;
  }

  /// L1：真·服务端分叉（每个分支一次调用，state 由服务端 `<sid>:<idx>` 维护）。
  Future<void> _runMultiState(
    List<WorkflowBranch> branches, {
    required String baseSessionId,
    required String seedContext,
    int? maxTokens,
  }) async {
    for (final WorkflowBranch b in branches) {
      try {
        final (String text, int? newIdx) = await model!.multiStateChat(
          sessionId: baseSessionId,
          dialogueIdx: b.dialogueIdx,
          prompt: b.divergencePrompt,
          maxTokens: maxTokens,
        );
        b.text = text;
        b.isSuccess = text.trim().isNotEmpty;
        b.usedFallback = false;
        if (newIdx != null) b.allocatedIdx = newIdx;
      } on Object catch (e) {
        // 单条分支失败不拖垮其他分支
        b.isSuccess = false;
        b.errorMessage = '$e';
        _logger.warning('分支 ${b.branchId} 分叉失败：$e');
      }
    }
  }

  /// L2：每条分支独立 session，**首次播种父上下文**，之后各自 O(1) 增量。
  Future<void> _runSessionSeed(
    List<WorkflowBranch> branches, {
    required String baseSessionId,
    required String seedContext,
    int? maxTokens,
  }) async {
    for (final WorkflowBranch b in branches) {
      final String sid = b.fallbackSessionId(baseSessionId);
      try {
        final String prompt = seedContext.trim().isEmpty
            ? b.divergencePrompt
            : '${seedContext.trim()}\n\n${b.divergencePrompt}';
        final String text = await model!.statefulChat(
          sessionId: sid,
          prompt: prompt,
          maxTokens: maxTokens,
        );
        b.text = text;
        b.isSuccess = text.trim().isNotEmpty;
        b.usedFallback = true;
        b.errorMessage = null;
      } on Object catch (e) {
        b.isSuccess = false;
        b.usedFallback = true;
        b.errorMessage = '$e';
        _logger.warning('分支 ${b.branchId} 独立会话播种失败：$e');
      }
    }
    if (branches.isNotEmpty) {
      _logger.info('已用「独立会话播种」模拟分叉：${branches.length} 条，'
          '每条首次需付一次父上下文 prefill（服务端未启用 /multi_state）');
    }
  }

  /// L3：串行重编码（无任何 state 能力）。
  Future<void> _runSerial(
    List<WorkflowBranch> branches, {
    required String seedContext,
    int? maxTokens,
  }) async {
    final Future<String> Function(String, int?)? chat = serialChat;
    if (chat == null) {
      for (final WorkflowBranch b in branches) {
        b.isSuccess = false;
        b.usedFallback = true;
        b.errorMessage = '无可用的分叉能力，且未注入 serialChat 兜底';
      }
      return;
    }
    for (final WorkflowBranch b in branches) {
      try {
        final String prompt = seedContext.trim().isEmpty
            ? b.divergencePrompt
            : '${seedContext.trim()}\n\n${b.divergencePrompt}';
        final String text = await chat(prompt, maxTokens);
        b.text = text;
        b.isSuccess = text.trim().isNotEmpty;
        b.usedFallback = true;
      } on Object catch (e) {
        b.isSuccess = false;
        b.usedFallback = true;
        b.errorMessage = '$e';
        _logger.warning('分支 ${b.branchId} 串行兜底失败：$e');
      }
    }
  }
}
