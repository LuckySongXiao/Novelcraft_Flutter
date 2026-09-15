import 'package:shared_preferences/shared_preferences.dart';

import 'key_value_store.dart';

/// Web 端实现：用 shared_preferences 承载
///
/// Web 平台没有文件系统，C# 版那种「每个项目一个 JSON 文件」的布局无法直接复刻，
/// 这里退化为「每个 scope+key 一条字符串记录」，语义等价。
class WebKeyValueStore implements KeyValueStore {
  SharedPreferences? _prefs;

  @override
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  String _k(String scope, String key) => 'novelcraft/$scope/$key';

  @override
  Future<String?> readJson(String scope, String key) async {
    await init();
    return _prefs!.getString(_k(scope, key));
  }

  @override
  Future<void> writeJson(String scope, String key, String json) async {
    await init();
    await _prefs!.setString(_k(scope, key), json);
  }

  @override
  Future<void> remove(String scope, String key) async {
    await init();
    await _prefs!.remove(_k(scope, key));
  }

  @override
  Future<List<String>> listKeys(String scope) async {
    await init();
    final prefix = 'novelcraft/$scope/';
    return _prefs!
        .getKeys()
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .toList();
  }
}

/// 供 key_value_store.dart 条件导出使用的工厂
KeyValueStore createStore() => WebKeyValueStore();

/// 工具：与 native 侧保持同名同签名
String encodeJson(Object? value) => value.toString();

Object? decodeJson(String text) => text;
