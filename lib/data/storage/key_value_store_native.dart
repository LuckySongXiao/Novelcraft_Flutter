import 'dart:convert';
import 'dart:io';

import 'key_value_store.dart';

/// Native 端实现：JSON 文件
///
/// 目录结构与 C# 版保持一致：
/// `{ApplicationDocumentsDirectory}/NovelManagement/{scope}/{key}.json`
/// 便于用户已有的数据目录被直接复用。
class NativeKeyValueStore implements KeyValueStore {
  Directory? _root;

  @override
  Future<void> init() async {
    if (_root != null) return;
    // 延迟获取，避免构造期触发平台通道
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    _root = Directory('$base${Platform.pathSeparator}NovelManagement');
    if (!_root!.existsSync()) {
      _root!.createSync(recursive: true);
    }
  }

  Directory _scopeDir(String scope) {
    final dir = Directory(
      '${_root!.path}${Platform.pathSeparator}$scope',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  @override
  Future<String?> readJson(String scope, String key) async {
    await init();
    final f = File(
      '${_scopeDir(scope).path}${Platform.pathSeparator}$key.json',
    );
    if (!f.existsSync()) return null;
    return f.readAsString();
  }

  @override
  Future<void> writeJson(String scope, String key, String json) async {
    await init();
    final f = File(
      '${_scopeDir(scope).path}${Platform.pathSeparator}$key.json',
    );
    await f.writeAsString(json);
  }

  @override
  Future<void> remove(String scope, String key) async {
    await init();
    final f = File(
      '${_scopeDir(scope).path}${Platform.pathSeparator}$key.json',
    );
    if (f.existsSync()) await f.delete();
  }

  @override
  Future<List<String>> listKeys(String scope) async {
    await init();
    final dir = _scopeDir(scope);
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
        .toList();
  }
}

/// 供 key_value_store.dart 条件导出使用的工厂
KeyValueStore createStore() => NativeKeyValueStore();

/// 工具：解析/序列化（native 与 web 共用逻辑）
String encodeJson(Object? value) => jsonEncode(value);

Object? decodeJson(String text) => jsonDecode(text);
