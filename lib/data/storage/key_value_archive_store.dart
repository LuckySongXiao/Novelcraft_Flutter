import 'dart:convert';

// 把 [KeyValueStore] 适配成 [RwkvSessionArchiveStore]。
//
// 为什么不直接让 `RwkvSessionArchive` 依赖 `KeyValueStore`：
// 存档的**逻辑**（模型兼容校验、转录本序列化、键规则）是纯 Dart，
// 保持它零依赖才能用 `dart run tool/verify_session_archive.dart` 真跑；
// 而 [KeyValueStore] 带着数据层与平台实现。两者用这个小适配器解耦。
import '../../ai/rwkv/rwkv_session_archive.dart';
import 'key_value_store.dart';

/// [KeyValueStore] → [RwkvSessionArchiveStore] 适配器。
class KeyValueSessionArchiveStore implements RwkvSessionArchiveStore {
  final KeyValueStore kv;

  KeyValueSessionArchiveStore(this.kv);

  @override
  Future<void> write(String key, Map<String, Object?> json) =>
      kv.writeJson(RwkvSessionArchive.scope, key, jsonEncode(json));

  @override
  Future<String?> read(String key) => kv.readJson(RwkvSessionArchive.scope, key);

  @override
  Future<void> delete(String key) => kv.remove(RwkvSessionArchive.scope, key);

  @override
  Future<List<String>> keys() => kv.listKeys(RwkvSessionArchive.scope);
}
