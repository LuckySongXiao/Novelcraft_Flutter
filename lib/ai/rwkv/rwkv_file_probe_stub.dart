// 文件探测 —— stub 回退实现（未知平台 / 无 dart:io）。
//
// 与 Native 版保持**同名同签名**：[rwkvFileSizeOrNull] / [rwkvPathIsDirectory]。
library;

/// stub：无文件系统，恒返回 null（调用方需容忍"未知"并跳过校验）。
int? rwkvFileSizeOrNull(String path) => null;

/// stub：无文件系统，恒返回 false。
bool rwkvPathIsDirectory(String path) => false;
