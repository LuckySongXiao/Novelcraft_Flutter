/// 应用版本号 —— 必须与 `pubspec.yaml` 的 `version:`、根目录 `version.txt` 保持一致。
///
/// 为什么不做成「运行时读取」：本工程同时跑 Windows / Android / Web，
/// 而 Web 上没有可执行文件版本的概念；为了底部状态栏那一行字引入
/// `package_info_plus` 插件（并在各平台分别注册）不划算。
/// 这里保持一个纯常量，升版本时三处一起改即可
/// （另有 `tools/sync_release_snapshot.py` / `tools/package_release.py`
/// 的 `DEFAULT_VERSION` 记录发布件版本号）。
const String kAppVersion = '1.0.0+46';

/// 带 `v` 前缀的显示形式，如 `v1.0.0+36`。
const String kAppVersionLabel = 'v$kAppVersion';
