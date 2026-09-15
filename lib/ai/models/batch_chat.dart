// RWKV 批量补全的数据模型与路由常量。
//
// ⚠⚠ 路由常量按 **线上实测** 定，不照抄文档 —— 官方两份文档**互相矛盾**：
//
//  | 文档 | 声称 `/v1/chat/completions` 是 |
//  |---|---|
//  | `docs/http-api.zh-CN.md`（示例，**与线上 1.3.0 一致**） | OpenAI 风格 `messages` 单路 |
//  | `rwkv_lightning_api_doc.md`（完整参考，较新/异构后端） | 原生多 prompt 批量（`contents`） |
//
//  实测（`api-7b.rwkvos.com`，engine `albatross-1.3.0`）结论：
//   - `/v1/batch/completions` + `contents[]` → **N 条带 `index` 的 choices** ✅ 批量走它
//   - `/v1/chat/completions` + `contents[2]` → **只回 1 条 choice**（只取第一项当额外
//     User 消息），**不是批量**
//   - `/openai/v1/chat/completions` → **404（不存在）**
//   - `stop_tokens` 是**整数 token ID**（CUDA 后端约定），不是字符串停止序列
//
//  所以 HANDOFF 里 `kRouteRwkvNativeBatch='/v1/chat/completions'` 与
//  `kRouteRwkvOpenAiChat='/openai/v1/chat/completions'` **都要更正**（PITFALLS §31.5 / §33.1）。
library;

// ---------------------------------------------------------------------------
// 路由常量（禁止在别处写字面量字符串）
// ---------------------------------------------------------------------------

/// 原生**批量**补全：`contents: string[]` → N 条带 `index` 的 choices。
const String kRouteRwkvBatchCompletions = '/v1/batch/completions';

/// OpenAI 风格**单路**聊天：`messages: [{role, content}]`。
const String kRouteRwkvChatCompletions = '/v1/chat/completions';

/// 批量翻译（固定生成参数：max_tokens=2048 / temperature=1.0 / top_k=1 / top_p=0.0）。
const String kRouteRwkvBatchTranslate = '/translate/v1/batch-translate';

/// 有状态单分支补全：`session_id` + `contents`（**必须恰好 1 条**）。
/// ⚠ 该路由**没有 `/v1` 前缀**。
const String kRouteRwkvStateChat = '/state/chat/completions';

/// 可分叉 stateful 补全：`session_id` + `dialogue_idx`（根节点 0）。
/// ⚠ **可选能力**，线上 1.3.0 实测 404 → 使用前必须 `probeMultiState()`。
/// ⚠ 该路由**没有 `/v1` 前缀**。
const String kRouteRwkvMultiStateChat = '/multi_state/chat/completions';

/// 查询三级 state cache（L1 VRAM / L2 RAM / SQLite）。
const String kRouteRwkvStateStatus = '/state/status';

/// 删除 state；`delete_prefix=true` 时连同 `<session_id>:*` 分支一起删。
const String kRouteRwkvStateDelete = '/state/delete';

/// 引擎状态：能力 / 显存 / 队列 / 实时吞吐。
/// ⚠ 这条**有 `/v1` 前缀**（与其它 `/state/*` 不同）。
const String kRouteRwkvServerStatus = '/v1/server/status';

/// token 计数（`text` > `messages` > `contents` 优先级）。
const String kRouteRwkvTokenCount = '/v1/tokens/count';

// ---------------------------------------------------------------------------
// 生成参数默认值（官方文档 §4，实测生效）
// ---------------------------------------------------------------------------

/// 官方默认停止 token（**整数 ID**，CUDA 后端约定）。
///
/// ⚠ 实测 `/v1/batch/completions` **不传该字段时每个槽位返回空文本**
/// （HTTP 200 + index 正确，极易误判成模型问题）→ 批量**一律显式携带**。
const List<int> kRwkvDefaultStopTokens = <int>[0, 261, 24281];

/// 批量流式刷新粒度默认值（文档：batch 路由 SSE 默认 8，不是 1）。
const int kRwkvDefaultBatchChunkSize = 8;

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

/// 原生批量补全请求。
class RwkvBatchRequest {
  /// 响应标签（不会在单个请求内切换已加载模型）
  final String model;

  /// 输入 prompt 数组（**必须非空**，否则服务端 400 `bsr overflow`/`Empty`）
  final List<String> contents;

  final double temperature;
  final double? topP;
  final int? topK;
  final double? alphaPresence;
  final double? alphaFrequency;
  final double? alphaDecay;

  /// 每个 choice 的最大生成 token 数
  final int maxTokens;

  /// 停止 token ID 列表
  final List<int> stopTokens;

  final bool stream;

  /// 流式刷新粒度
  final int? chunkSize;

  /// 让服务端记录 prefill/decode 指标供 `/v1/server/status` 查询
  /// （**不会**把 metrics 加进响应）
  final bool metrics;

  /// 提交时**显式**要求服务端记录指标（默认 true，便于健康面板观测）
  const RwkvBatchRequest({
    required this.contents,
    this.model = 'rwkv7',
    this.temperature = 1.0,
    this.topP,
    this.topK,
    this.alphaPresence,
    this.alphaFrequency,
    this.alphaDecay,
    this.maxTokens = 1024,
    this.stopTokens = kRwkvDefaultStopTokens,
    this.stream = false,
    this.chunkSize,
    this.metrics = true,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> m = <String, dynamic>{
      'model': model,
      'contents': contents,
      'temperature': temperature,
      'max_tokens': maxTokens,
      // ⚠ 必须显式带：不传则服务端默认停词表会让首 token 立刻命中 → 空输出
      'stop_tokens': stopTokens,
      'stream': stream,
    };
    if (topP != null) m['top_p'] = topP;
    if (topK != null) m['top_k'] = topK;
    if (alphaPresence != null) m['alpha_presence'] = alphaPresence;
    if (alphaFrequency != null) m['alpha_frequency'] = alphaFrequency;
    if (alphaDecay != null) m['alpha_decay'] = alphaDecay;
    if (chunkSize != null) m['chunk_size'] = chunkSize;
    if (metrics) m['metrics'] = true;
    return m;
  }

  /// 造一个只含指定槽位的子集请求（用于**部分失败子集重试**）。
  RwkvBatchRequest subset(List<int> indices) => RwkvBatchRequest(
        contents: <String>[for (final int i in indices) contents[i]],
        model: model,
        temperature: temperature,
        topP: topP,
        topK: topK,
        alphaPresence: alphaPresence,
        alphaFrequency: alphaFrequency,
        alphaDecay: alphaDecay,
        maxTokens: maxTokens,
        stopTokens: stopTokens,
        stream: stream,
        chunkSize: chunkSize,
        metrics: metrics,
      );
}

/// 批量补全的一条 choice。
///
/// ⚠ `index` 是**原始输入位置**，SSE 中不同 index 的事件可能**交错到达** ——
/// 绝不能按到达顺序 append（PITFALLS §27.3）。
class RwkvBatchChoice {
  final int index;
  final String? content;
  final String? finishReason;
  final String? role;

  const RwkvBatchChoice({
    required this.index,
    this.content,
    this.finishReason,
    this.role,
  });

  factory RwkvBatchChoice.fromJson(Map<String, dynamic> json) {
    final Object? msg = json['message'];
    final Object? delta = json['delta'];
    String? text;
    String? role;
    if (msg is Map<String, dynamic>) {
      text = msg['content'] as String?;
      role = msg['role'] as String?;
    }
    if (delta is Map<String, dynamic>) {
      text = delta['content'] as String?;
      role ??= delta['role'] as String?;
    }
    // 兼容 `choices[].text`（老式 completions 风格）
    text ??= json['text'] as String?;
    return RwkvBatchChoice(
      index: (json['index'] as num?)?.toInt() ?? 0,
      content: text,
      finishReason: json['finish_reason'] as String?,
      role: role,
    );
  }
}

/// 批量补全响应。
///
/// ⚠ 文档明说 **batch / stateful / 全部流式响应都不返回标准 `usage`**；
/// 实测非流式 `/v1/batch/completions` 响应确实只有 `{choices,id,model,object}`。
/// 所以这里 `usage` 允许为 null，且**不要**用它判断是否被截断 ——
/// `finish_reason` 也不可信（所有流式结束都无条件发 `stop`，PITFALLS §31.4）。
class RwkvBatchResponse {
  final String? id;
  final String? model;
  final List<RwkvBatchChoice> choices;
  final Map<String, dynamic>? usage;

  /// 服务端返回的原始 JSON（排障用）
  final Map<String, dynamic> raw;

  const RwkvBatchResponse({
    required this.choices,
    required this.raw,
    this.id,
    this.model,
    this.usage,
  });

  factory RwkvBatchResponse.fromJson(Map<String, dynamic> json) {
    final List<RwkvBatchChoice> out = <RwkvBatchChoice>[];
    final Object? rawChoices = json['choices'];
    if (rawChoices is List) {
      for (final Object? c in rawChoices) {
        if (c is Map<String, dynamic>) out.add(RwkvBatchChoice.fromJson(c));
      }
    }
    out.sort((RwkvBatchChoice a, RwkvBatchChoice b) =>
        a.index.compareTo(b.index));
    return RwkvBatchResponse(
      id: json['id'] as String?,
      model: json['model'] as String?,
      choices: out,
      usage: json['usage'] is Map<String, dynamic>
          ? json['usage'] as Map<String, dynamic>
          : null,
      raw: json,
    );
  }

  /// 按 index 取出内容，缺失的槽位为 null（**不补齐、不臆造**）。
  List<String?> contentsByIndex(int expected) {
    final List<String?> out = List<String?>.filled(expected, null);
    for (final RwkvBatchChoice c in choices) {
      if (c.index >= 0 && c.index < expected) out[c.index] = c.content;
    }
    return out;
  }

  /// 缺失的槽位下标（用于部分失败子集重试）。
  List<int> missingIndices(int expected) {
    final Set<int> got = <int>{
      for (final RwkvBatchChoice c in choices)
        if (c.content != null && c.content!.isNotEmpty) c.index,
    };
    return <int>[
      for (int i = 0; i < expected; i++)
        if (!got.contains(i)) i,
    ];
  }
}

/// 批量请求失败的原因分类 —— **决定重试策略**（PITFALLS §31.3）。
enum RwkvBatchFailureKind {
  /// 服务端并发上限：`400 {"error":"bsz overflow, Max bsz=N","request_bsz":M}`
  /// → **拆小 batch 重试**（不是退避等待）
  bszOverflow,

  /// 服务端 5xx → 指数退避重试
  serverError,

  /// HTTP 200 但 body 是 `{"error":"..."}`（**SSE 运行时异常也走 200**）→ 重试
  runtimeErrorEvent,

  /// 响应条数不足 / JSON 解析失败（网络截断，实测 N=16 时 UTF-8 被截断）→ 子集重试
  truncated,

  /// 认证失败（CF 返回 HTML 登录页）
  authFailed,

  /// 不该重试（参数错、404 等）
  fatal,
}

/// 一次批量调用失败的描述。
class RwkvBatchException implements Exception {
  final RwkvBatchFailureKind kind;
  final String message;
  final int? statusCode;

  /// 服务端声明的上限（`bsz overflow` 时有值）
  final int? maxBsz;

  /// 本次请求的槽位数（`bsz overflow` 时有值）
  final int? requestBsz;

  const RwkvBatchException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.maxBsz,
    this.requestBsz,
  });

  /// 是否值得重试。
  bool get isRetryable =>
      kind != RwkvBatchFailureKind.fatal &&
      kind != RwkvBatchFailureKind.authFailed;

  /// `bsz overflow` 时建议的下一次槽位数（取服务端上限与折半的较小值）。
  int? suggestedBatchSize() {
    if (kind != RwkvBatchFailureKind.bszOverflow) return null;
    final int? cap = maxBsz;
    final int? req = requestBsz;
    if (cap == null || cap <= 0) return null;
    final int half = req == null ? cap : (req ~/ 2);
    return half < cap ? (half < 1 ? 1 : half) : cap;
  }

  @override
  String toString() => 'RwkvBatchException(${kind.name}'
      '${statusCode == null ? '' : ' HTTP $statusCode'}): $message';
}
