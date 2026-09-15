import 'key_value_store.dart';

/// 兜底实现（理论上不会被选中，仅用于满足条件导出的静态分析）
class StubKeyValueStore implements KeyValueStore {
  @override
  Future<void> init() async {}

  @override
  Future<String?> readJson(String scope, String key) async => null;

  @override
  Future<void> writeJson(String scope, String key, String json) async {
    throw UnsupportedError('当前平台不支持本地 JSON 存储');
  }

  @override
  Future<void> remove(String scope, String key) async {}

  @override
  Future<List<String>> listKeys(String scope) async => const [];
}

/// 供 key_value_store.dart 条件导出使用的工厂
KeyValueStore createStore() => StubKeyValueStore();

/// 工具：与 native / web 侧保持同名同签名
String encodeJson(Object? value) => value.toString();

Object? decodeJson(String text) => text;
