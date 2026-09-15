// 文件探测 —— 条件导出。
//
// 存在意义：`rwkv_engine.dart` 刻意**不 import dart:io**（保证 Web 端可编译），
// 但启动内置引擎前需要校验「外置词表」是否存在、字节数是否够（PITFALLS §27.1：
// 词表缺失会秒退，UI 侧只看到 errno=1225 拒绝连接，极难定位）。
// 故把这类文件系统探针收敛到这里，按平台条件导出。
export 'rwkv_file_probe_stub.dart'
    if (dart.library.io) 'rwkv_file_probe_native.dart';
