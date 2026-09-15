// 本地推理进程启动器的条件导出入口。
//
// 对应 C# 中通过 `Process.Start` 拉起 RWKV 本地推理服务的平台相关逻辑
// （C# 版 `Services/RWKV/` 下涉及进程启动的部分）。
//
// 由于 Web 不支持 `dart:io` 的 `Process`，这里用条件导出隔离平台实现：
// - Native（含桌面 / 移动）平台：使用 `inference_launcher_native.dart`，
//   通过 `dart:io` 的 [Process.start] 启动本地 RWKV 服务；
// - Web 平台：使用 `inference_launcher_web.dart`，直接抛出 [UnsupportedError]；
// - 其余未知平台：回退到 `inference_launcher_stub.dart`（同样为不支持）。
//
// 三个实现文件都导出同名同签名的 [InferenceProcessLauncher] 类，调用方只需
// `import 'inference_launcher.dart'` 即可，无需关心当前平台。
library;

export 'inference_launcher_stub.dart'
    if (dart.library.io) 'inference_launcher_native.dart'
    if (dart.library.js_interop) 'inference_launcher_web.dart';
