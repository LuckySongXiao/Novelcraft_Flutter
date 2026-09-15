// 通用批量/有状态补全能力（P4-29）。
//
// HANDOFF §29 的原话：「把 P3 的 batch API 做成通用接口（IBatchChatModel mixin），
// 后续如果引入其他原生 batch 能力的推理服务（比如本地 rwkv_lightning_cuda v1.5.0
// 也支持 batch），只要 with 一下这个 mixin 就能自动拿到 BatchAgentExecutor 的
// 工作流聚合，不用重写一遍。」
//
// 结构：
//   [IBatchChatModel]      —— 接口（BatchAgentExecutor 只认这个，不挑 Provider）
//   [RwkvBatchChatModelMixin] —— 默认实现，**全部委托给 [batchClient]**
//
// ⇒ 接入成本被压到最低：新 Provider 只要能提供一个 [RwkvBatchClient]
//   （构造时给 baseUrl + headers），`with RwkvBatchChatModelMixin` 就齐活了。
//
// ⚠ 这套方法**不是**OpenAI 标准面：`statefulChat` / `multiStateChat` /
//   `stateCacheStatus` / `stateDelete` 是 rwkv_lightning 独有的。
//   不支持它们的 Provider 应该不要 mixin，或者覆写成抛 `UnsupportedError`。
library;

import '../rwkv/rwkv_batch_client.dart';
import '../rwkv/rwkv_concurrency.dart';
import 'batch_chat.dart';

/// 批量 / 有状态补全能力的统一接口。
abstract interface class IBatchChatModel {
  /// 底层批量客户端（`BatchAgentExecutor` 直接复用它，避免再包一层）。
  RwkvBatchClient get batchClient;

  /// 批量补全（一次 POST 打多条 prompt），返回按 `index` 对齐的内容。
  Future<List<String?>> batchChat(RwkvBatchRequest request);

  /// 流式批量补全（按 `choices[].index` 分组，到达顺序无关）。
  Stream<RwkvBatchProgress> batchChatStream(RwkvBatchRequest request);

  /// 有状态单分支续跑（只发本轮增量）。
  Future<String> statefulChat({
    required String sessionId,
    required String prompt,
    int? maxTokens,
  });

  /// 查询三级 state 缓存。
  Future<Map<String, dynamic>?> stateCacheStatus();

  /// 删除会话 state（`deletePrefix` 时连同 `<sid>:*` 分支）。
  Future<bool> stateDelete({required String sessionId, bool deletePrefix});

  /// 引擎容量（`available_bsz` 等）。
  Future<RwkvServerCapacity?> capacity();
}

/// 默认实现：**全部委托给 [batchClient]**。
///
/// 子类只需：
/// ```dart
/// class MyProvider extends BaseProvider with RwkvBatchChatModelMixin {
///   @override
///   RwkvBatchClient get batchClient => _batch;   // 构造时建好
/// }
/// ```
/// 需要加前置校验（例如"必须先 initialize"）的，覆写对应方法并先做检查。
mixin RwkvBatchChatModelMixin implements IBatchChatModel {
  @override
  RwkvBatchClient get batchClient;

  @override
  Future<List<String?>> batchChat(RwkvBatchRequest request) =>
      batchClient.chat(request);

  @override
  Stream<RwkvBatchProgress> batchChatStream(RwkvBatchRequest request) =>
      batchClient.chatStream(request);

  @override
  Future<String> statefulChat({
    required String sessionId,
    required String prompt,
    int? maxTokens,
  }) async {
    final Map<String, dynamic> json = await batchClient.postJson(
      kRouteRwkvStateChat,
      <String, dynamic>{
        'session_id': sessionId,
        // ⚠ 必须**恰好 1 条**，传 2 条服务端 400
        'contents': <String>[prompt],
        'stream': false,
        'max_tokens': maxTokens ?? 1024,
        'stop_tokens': kRwkvDefaultStopTokens,
      },
    );
    return RwkvBatchContentExtractor.firstContent(json);
  }

  @override
  Future<Map<String, dynamic>?> stateCacheStatus() async {
    try {
      return await batchClient.postJson(kRouteRwkvStateStatus, <String, dynamic>{});
    } on Object {
      return null; // 面板展示用途，失败不该炸
    }
  }

  @override
  Future<bool> stateDelete({
    required String sessionId,
    bool deletePrefix = false,
  }) async {
    try {
      final Map<String, dynamic> r = await batchClient.postJson(
        kRouteRwkvStateDelete,
        <String, dynamic>{
          'session_id': sessionId,
          if (deletePrefix) 'delete_prefix': true,
        },
      );
      return (r['status'] as String?) != 'not_found';
    } on RwkvBatchException catch (e) {
      if (e.statusCode == 404) return false; // 本来就不存在
      rethrow;
    }
  }

  @override
  Future<RwkvServerCapacity?> capacity() => batchClient.capacity();
}

/// 从 OpenAI / 原生风格响应里取第一条 choice 的文本。
///
/// 兼容 `choices[].message.content`（chat/stateful）与 `choices[].text`
/// （老式 completions）。放在顶层而不是 Provider 里，是因为
/// mixin 与 Provider 都要用，避免复制一份。
class RwkvBatchContentExtractor {
  const RwkvBatchContentExtractor._();

  static String firstContent(Map<String, dynamic> json) {
    final Object? choices = json['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final Object? first = choices.first;
    if (first is! Map<String, dynamic>) return '';
    final Object? msg = first['message'];
    if (msg is Map<String, dynamic>) {
      final Object? c = msg['content'];
      if (c is String) return c;
    }
    final Object? t = first['text'];
    return t is String ? t : '';
  }
}
