// 键值 JSON 存储的平台抽象
//
// ⚠ 这是本次移植中一个容易被忽略的架构点：
// C# 版有 10 个世界观体系页（商业/维度/装备/司法/地图/宠物/生民/职业/功法/灵宝）
// **在数据库里根本没有对应表** —— 它们的数据以 JSON 文件存放在
// `%AppData%\NovelManagement\{scope}\{projectId}.json`。
// （另有 CultivationSystem / PoliticalSystem 两个体系是真正的数据库实体。）
//
// Web 平台没有文件系统，因此这里抽象一层：
//   - Native：文件（path_provider + dart:io）
//   - Web：shared_preferences（底层是 localStorage / IndexedDB）
export 'key_value_store_stub.dart'
    if (dart.library.io) 'key_value_store_native.dart'
    if (dart.library.js_interop) 'key_value_store_web.dart';

/// 存储键净化与路径拼接的**唯一真值**在 `store_key.dart`（纯 Dart，可离线自检）。
///
/// 这里只做转出，方便既有调用方继续 `import 'key_value_store.dart';` 就能拿到它们。
/// 注意：本文件条件导出了 native 实现（`dart:io` + `path_provider`），
/// 离线脚本请直接 import `store_key.dart`，不要 import 本文件。
export 'store_key.dart'
    show sanitizeStoreKey, storeFileName, storeFilePath, storeKeyFromFileName;

/// 存储接口：按「作用域 + 键」读写 JSON 文本
abstract class KeyValueStore {
  Future<void> init();

  Future<String?> readJson(String scope, String key);

  Future<void> writeJson(String scope, String key, String json);

  Future<void> remove(String scope, String key);

  Future<List<String>> listKeys(String scope);
}
