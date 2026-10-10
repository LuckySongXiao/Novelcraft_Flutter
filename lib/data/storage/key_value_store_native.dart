import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'key_value_store.dart';

/// Native 端实现：JSON 文件
///
/// 目录结构：
/// - Windows：`%APPDATA%\NovelManagement\{scope}\{key}.json`
///   （与 C# 版保持一致，用户已有的数据目录被直接复用）；
/// - 其它平台（安卓/iOS/macOS/Linux）：`{应用支持目录}/NovelManagement/{scope}/{key}.json`
///   （path_provider 解析到应用私有可写目录，安卓上无需任何权限）。
///
/// ⚠ 不能用 `Platform.environment['APPDATA']` 一把梭：安卓上 APPDATA/HOME
/// 均为 null，退到 `Directory.current`（只读的根目录 `/`），创建
/// `//NovelManagement` 直接报 `FileSystemException errno 30`（真机已踩）。
class NativeKeyValueStore implements KeyValueStore {
  Directory? _root;

  @override
  Future<void> init() async {
    if (_root != null) return;
    // 延迟获取，避免构造期触发平台通道
    if (Platform.isWindows) {
      final base = Platform.environment['APPDATA'] ?? Directory.current.path;
      _root = Directory('$base${Platform.pathSeparator}NovelManagement');
    } else {
      final support = await getApplicationSupportDirectory();
      _root = Directory(
        '${support.path}${Platform.pathSeparator}NovelManagement',
      );
    }
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

  /// 作用域目录下的目标文件。
  ///
  /// 路径拼接一律走 [storeFilePath]（纯函数、有离线自检）。
  /// ⚠ 绝不要在这里内联写 `'...${Platform.pathSeparator}$_fileOf(key)'`：
  /// `$identifier` 只插值简单标识符，`$_fileOf` 插进去的是**函数对象**，
  /// `(key)` 会退化成字面文本 → 启动即 `PathNotFoundException errno 123`。
  File _file(String scope, String key) =>
      File(storeFilePath(_scopeDir(scope).path, key, Platform.pathSeparator));

  @override
  Future<String?> readJson(String scope, String key) async {
    await init();
    final f = _file(scope, key);
    if (!f.existsSync()) return null;
    return f.readAsString();
  }

  @override
  Future<void> writeJson(String scope, String key, String json) async {
    await init();
    final f = _file(scope, key);
    await f.writeAsString(json);
  }

  @override
  Future<void> remove(String scope, String key) async {
    await init();
    final f = _file(scope, key);
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
        // 只剥结尾那一个 `.json`，且必须与 writeJson 的命名互为逆运算 ——
        // 否则返回的键走 readJson 会命中另一个文件（见 storeKeyFromFileName）。
        .map((f) => storeKeyFromFileName(f.uri.pathSegments.last))
        .toList();
  }
}

/// 供 key_value_store.dart 条件导出使用的工厂
KeyValueStore createStore() => NativeKeyValueStore();

/// 工具：解析/序列化（native 与 web 共用逻辑）
String encodeJson(Object? value) => jsonEncode(value);

Object? decodeJson(String text) => jsonDecode(text);
