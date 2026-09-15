// RWKV 会话存档（P4-27）—— 存「对话转录本」，不是 state 字节。
//
// ⚠⚠ 先说清一个被实测推翻的前提（HANDOFF P4-27 的原话是
//    "把 session 当前 state 快照字节写 KeyValueStore"）：
//
//    **客户端拿不到 state 字节。** 引擎里 `RwkvState.bytes` 一直是
//    `Uint8List(0)` 假占位（`rwkv_engine.dart` 的 chat 路径：
//    `bytes: parentState?.bytes ?? Uint8List(0)`），因为
//    rwkv_lightning 的接口**没有 state 导出端点** —— 只有
//    `/state/chat/completions`、`/state/status`、`/state/delete`。
//    也就是说"存几 MB 的 state 字节、下次直接恢复"这件事**物理上不可实现**。
//
//    ⇒ 正确做法是存**对话转录本**（role + content），恢复时把它
//    **重放一次**进 `/state/chat/completions` 重建服务端 state（付一次 prefill），
//    之后每轮继续 O(1) 增量。这反而是更对的设计，因为：
//      1. state 字节与**模型 + 引擎版本**强绑定，转录本可跨模型迁移（可校验）；
//      2. 转录本人类可读，能在 UI 上告诉用户"恢复后会记得什么"；
//      3. 云端与本地通用（本地引擎的 `--state-db-path` 本就会把 state 落盘，
//         重放只在 DB 丢失/换模型时才需要）。
//
// 纯 Dart、零 Flutter 依赖 ⇒ `dart run tool/verify_session_archive.dart` 可真跑。
library;

import 'dart:convert';

/// 一轮对话（存档的最小单元）。
class RwkvArchivedTurn {
  /// `user` / `assistant` / `system`
  final String role;
  final String content;

  const RwkvArchivedTurn({required this.role, required this.content});

  Map<String, Object?> toMap() => <String, Object?>{
        'role': role,
        'content': content,
      };

  factory RwkvArchivedTurn.fromJson(Map<String, Object?> json) =>
      RwkvArchivedTurn(
        role: (json['role'] as String?) ?? 'user',
        content: (json['content'] as String?) ?? '',
      );
}

/// 一个会话的存档。
class RwkvSessionArchiveEntry {
  /// 存档键（**稳定的**业务键，例如 `workflow-玄穹剑主`；
  /// 不要用引擎生成的 sessionId —— 那个每次开新会话都会变，存了也找不回来）
  final String archiveKey;

  /// ⚠ 产生这份 state 的模型 ID。state 与模型**强绑定**：
  ///   换模型后重放，得到的是另一个模型的"记忆"，语义完全不同。
  ///   恢复时若不匹配必须拒绝，而不是静默张冠李戴。
  final String modelId;

  final int archivedAtMs;

  final List<RwkvArchivedTurn> turns;

  const RwkvSessionArchiveEntry({
    required this.archiveKey,
    required this.modelId,
    required this.archivedAtMs,
    required this.turns,
  });

  bool get isEmpty => turns.isEmpty;

  int get totalChars => turns.fold<int>(0, (int s, RwkvArchivedTurn t) => s + t.content.length);

  Map<String, Object?> toMap() => <String, Object?>{
        'archiveKey': archiveKey,
        'modelId': modelId,
        'archivedAtMs': archivedAtMs,
        'turns': <Object?>[for (final RwkvArchivedTurn t in turns) t.toMap()],
      };

  factory RwkvSessionArchiveEntry.fromJson(Map<String, Object?> json) {
    final Object? raw = json['turns'];
    final List<RwkvArchivedTurn> turns = <RwkvArchivedTurn>[];
    if (raw is List) {
      for (final Object? t in raw) {
        if (t is Map) {
          turns.add(RwkvArchivedTurn.fromJson(
              t.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v))));
        }
      }
    }
    return RwkvSessionArchiveEntry(
      archiveKey: (json['archiveKey'] as String?) ?? '',
      modelId: (json['modelId'] as String?) ?? '',
      archivedAtMs: (json['archivedAtMs'] as num?)?.toInt() ?? 0,
      turns: turns,
    );
  }
}

/// 存档不兼容的原因（恢复失败时给用户可读的解释）。
enum RwkvArchiveMismatch {
  /// 存档是用别的模型产生的 —— 重放会得到"另一个模型的记忆"
  modelMismatch,

  /// 存档为空 / 损坏
  empty,
}

/// 会话存档仓库（[KeyValueStore] 注入，键稳定可跨重启找回）。
abstract class RwkvSessionArchiveStore {
  Future<void> write(String key, Map<String, Object?> json);
  Future<String?> read(String key);
  Future<void> delete(String key);
  Future<List<String>> keys();
}

class RwkvSessionArchive {
  /// KVStore 的 scope（与 `ai_config` 分开：这是**大块文本**，别混进小配置）
  static const String scope = 'rwkv_state_archive';

  static String keyFor(String archiveKey) => 'session_${archiveKey.trim()}';

  final RwkvSessionArchiveStore store;

  RwkvSessionArchive(this.store);

  /// 保存/覆盖某个键的存档。
  Future<void> save(RwkvSessionArchiveEntry entry) async {
    if (entry.archiveKey.trim().isEmpty) {
      throw ArgumentError('archiveKey 不能为空（它必须是一个稳定的业务键）');
    }
    await store.write(keyFor(entry.archiveKey), entry.toMap());
  }

  /// 读取存档；不存在返回 null。
  Future<RwkvSessionArchiveEntry?> load(String archiveKey) async {
    final String? raw = await store.read(keyFor(archiveKey));
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? d = jsonDecode(raw);
      if (d is Map<String, Object?>) return RwkvSessionArchiveEntry.fromJson(d);
      return null;
    } on FormatException {
      // 存档损坏：当作不存在处理（调用方会走"从零开始"），但绝不抛出去炸 UI
      return null;
    }
  }

  /// 读取并做**兼容性校验**。
  ///
  /// 返回 null 且带原因 = 不该恢复（调用方应从零开始，而不是硬塞错误记忆）。
  Future<(RwkvSessionArchiveEntry?, RwkvArchiveMismatch?)> loadCompatible({
    required String archiveKey,
    required String currentModelId,
  }) async {
    final RwkvSessionArchiveEntry? e = await load(archiveKey);
    if (e == null || e.isEmpty) return (null, RwkvArchiveMismatch.empty);
    if (e.modelId.isNotEmpty &&
        currentModelId.isNotEmpty &&
        e.modelId != currentModelId) {
      return (null, RwkvArchiveMismatch.modelMismatch);
    }
    return (e, null);
  }

  Future<void> delete(String archiveKey) => store.delete(keyFor(archiveKey));

  /// 列出所有存档键（去掉 `session_` 前缀），供 UI 展示"有哪些可恢复的会话"。
  Future<List<String>> listKeys() async {
    final List<String> all = await store.keys();
    return all
        .where((String k) => k.startsWith('session_'))
        .map((String k) => k.substring('session_'.length))
        .toList()
      ..sort();
  }

  /// 把引擎侧的会话历史转成可存档的转录本。
  static List<RwkvArchivedTurn> turnsFromHistory(
      Iterable<Map<String, String>> history) => <RwkvArchivedTurn>[
        for (final Map<String, String> m in history)
          RwkvArchivedTurn(role: m['role'] ?? 'user', content: m['content'] ?? ''),
      ];
}
