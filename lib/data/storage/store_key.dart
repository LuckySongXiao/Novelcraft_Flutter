// 存储键净化 —— **纯 Dart，无任何 import**。
//
// 为什么单独成文件：`key_value_store.dart` 条件导出了 native 实现
// （`dart:io` + `package:path_provider`），谁 import 它就会被拖进 Flutter
// framework，独立 `dart` 脚本直接编译失败（工程里踩过多次的
// `Offset isn't defined`）。把这条规则放在这里，离线自检才能引到它
// （见 `tools/kv_key_selftest.dart` A 组）。
library;

/// 把**逻辑键**转成**文件名安全**的存储键。
///
/// ⚠ 必须做：native 端 `KeyValueStore` 直接拿 key 当文件名
/// （`<scope>/<key>.json`）。Windows 文件名不允许 `< > : " / \ | ? *`
/// 与控制字符，而工程里的逻辑键恰好会含 `:` ——
///   * 审查留言：`'{项目id}:{章节id}'`（`book_content_review_service`）
///   * 章节同步防重签名：`'last_success_v2:{章节id}'`（`chapter_post_process_service`）
/// 不转义就会在 `File.writeAsString` 抛 `FileSystemException`，再被调用方的
/// `try/catch` 静默吞掉，现象是「审查留言永远为空 / 同步防重永远失效」。
/// （`RwkvCloudSessionArchive.storageKey` 早已为同一原因单独做过转义，
/// 这里把它下沉到存储层，任何新键都不必再各自记得。）
///
/// 只替换**非法字符**（而非像 RWKV 会话那样把非 ASCII 全换成 `_`），
/// 以便中文 / 点号键保持可读。副作用：同一作用域内 `a:b` 与 `a_b` 归一到
/// 同一个键 —— 逻辑键里不存在这种撞车，可接受。
///
/// 幂等：`sanitizeStoreKey(sanitizeStoreKey(k)) == sanitizeStoreKey(k)`。
/// 这一点很重要 —— `listKeys()` 返回的已经是净化后的文件名，
/// 调用方拿它再走 `readJson` 时必须仍然命中同一条记录。
String sanitizeStoreKey(String key) {
  final String replaced = key
      // Windows 非法字符 + C0 控制字符
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      // Windows 不允许文件名以点或空格结尾
      .replaceAll(RegExp(r'[. ]+$'), '');
  return replaced.isEmpty ? '_' : replaced;
}

/// 逻辑键 → 存储**文件名**（含 `.json` 后缀）。
String storeFileName(String key) => '${sanitizeStoreKey(key)}.json';

/// 拼出 `<scope 目录><分隔符><文件名>`。
///
/// ⚠ 为什么把路径拼接也放到这里（而不是留在 `key_value_store_native.dart`
/// 里内联）：那里最初写成
///
/// ```dart
/// File('...${Platform.pathSeparator}$_fileOf(key)')   // ← 错误
/// ```
///
/// Dart 的 `$identifier` 只能插值**简单标识符** —— `$_fileOf` 插进去的是
/// **函数对象本身**，后面的 `(key)` 退化成字面文本。于是路径成了
/// `...\internal\Closure: (String) => String from Function '_fileOf@...': static (key)`，
/// 启动即抛 `PathNotFoundException (errno 123)`。类型检查**发现不了**
/// （插值一个函数是合法的 Dart），只能在运行期炸。
///
/// 所以这条规则现在只允许写一次，并且**是纯函数、可被离线自检覆盖**
/// （见 `tools/kv_key_selftest.dart` D 组，含「结果不得含 `Closure`」的回归断言）。
String storeFilePath(String scopeDir, String key, String separator) =>
    '$scopeDir$separator${storeFileName(key)}';

/// [storeFileName] 的逆：文件名 → 逻辑键。
///
/// 只剥**结尾**那一个 `.json`。`listKeys()` 必须返回「能被 `readJson` 原样命中」
/// 的键 —— 先前实现用 `replaceAll('.json', '')`，键名中间含 `.json` 时
/// （如 `a.json.b` → 文件 `a.json.b.json` → 被削成 `a.b`）就破坏了这条契约。
String storeKeyFromFileName(String fileName) =>
    fileName.endsWith('.json')
        ? fileName.substring(0, fileName.length - '.json'.length)
        : fileName;
