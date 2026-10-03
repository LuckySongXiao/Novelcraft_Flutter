// 模型配置本地持久化 —— 配置过的 provider 设置落 KVStore，下次启动自动恢复。
//
// 存储布局（scope=ai_config）：
//   `provider_cfg.{kind}`   单 provider 配置 JSON（kind = deepseek/zhipu/ollama/
//                           rwkv/rwkvCloud/custom）
//   `provider_default`      默认 provider 注册名（可空）
//
// 与 rwkv.configuration / rwkv.cloud_configuration 的旧键不冲突（本表是
// 「通用 provider 注册表」，RWKV 的引擎级细节仍走各自的专项键）。
library;

import 'dart:convert';

import '../../data/storage/key_value_store.dart';

/// 模型配置持久化存储（纯 KV 读写，无 provider 依赖，可单测）。
class ModelConfigStore {
  ModelConfigStore({required Future<KeyValueStore> Function() store})
      : _store = store;

  static const String scope = 'ai_config';
  static const String keyPrefix = 'provider_cfg.';
  static const String defaultKey = 'provider_default';

  final Future<KeyValueStore> Function() _store;

  Future<void> save(String kind, Map<String, Object?> json) async {
    final KeyValueStore kv = await _store();
    await kv.writeJson(scope, '$keyPrefix$kind', jsonEncode(json));
  }

  Future<void> remove(String kind) async {
    final KeyValueStore kv = await _store();
    await kv.remove(scope, '$keyPrefix$kind');
  }

  Future<void> saveDefault(String? providerName) async {
    final KeyValueStore kv = await _store();
    if (providerName == null || providerName.trim().isEmpty) {
      await kv.remove(scope, defaultKey);
    } else {
      await kv.writeJson(scope, defaultKey, jsonEncode(providerName.trim()));
    }
  }

  /// 读取全部已持久化的 provider 配置（kind → 配置 JSON Map）。
  Future<Map<String, Map<String, Object?>>> loadAll() async {
    final KeyValueStore kv = await _store();
    final Map<String, Map<String, Object?>> out =
        <String, Map<String, Object?>>{};
    for (final String key in await kv.listKeys(scope)) {
      if (!key.startsWith(keyPrefix)) continue;
      final String kind = key.substring(keyPrefix.length);
      try {
        final String? raw = await kv.readJson(scope, key);
        if (raw == null || raw.isEmpty) continue;
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          out[kind] = decoded.map(
            (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
          );
        }
      } on Object {
        // 损坏的配置跳过，不影响其它 provider 恢复
      }
    }
    return out;
  }

  Future<String?> loadDefault() async {
    final KeyValueStore kv = await _store();
    try {
      final String? raw = await kv.readJson(scope, defaultKey);
      if (raw == null || raw.isEmpty) return null;
      final Object? decoded = jsonDecode(raw);
      return decoded is String ? decoded.trim() : null;
    } on Object {
      return null;
    }
  }
}
