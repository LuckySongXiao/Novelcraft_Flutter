// 章节导出根目录 —— Web 桩实现（Web 无文件系统，不支持本地导出）。
library;

/// Web 平台不支持本地文件导出：抛 UnsupportedError（调用方应折叠该异常）。
Future<String> exportRootDirectory() async =>
    throw UnsupportedError('Web 平台不支持本地文件导出');

/// 路径分隔符（保持跨平台一致）。
String get exportPathSeparator => '/';

/// 递归创建目录（Web 不支持）。
void ensureDirSync(String path) =>
    throw UnsupportedError('Web 平台不支持本地文件导出');

/// 写文本文件（Web 不支持）。
void writeTextFileSync(String path, String content) =>
    throw UnsupportedError('Web 平台不支持本地文件导出');
