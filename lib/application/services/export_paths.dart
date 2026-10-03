// 章节结构化导出 —— 根目录的平台抽象（条件导出）。
//
// 导出目录约定：
//   * Windows：`%APPDATA%\NovelManagement\exports\{projectId}\`
//   * 其它原生平台（安卓等）：`{应用支持目录}/NovelManagement/exports/{projectId}/`
//   * Web：不支持（stub 抛 UnsupportedError）
//
// 用途：生成的章节内容自动落盘为本地文件（Markdown + JSON 双格式），
// 便于对写作过程（段落计划 / 写手稿件 / 验收判定 / 质量指标）做离线
// 检查分析，并据此改良输出模板。
export 'export_paths_stub.dart' if (dart.library.io) 'export_paths_native.dart';
