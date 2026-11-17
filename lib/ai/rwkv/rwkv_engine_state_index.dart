// 推理引擎「已上传初始 state」索引 —— 文件名 → state_id。
//
// 为什么需要这一层：`rwkv_lightning_cuda` 的 `/v1/state/upload` 每次上传都会
// 生成一个带随机后缀的 `state_id`，而且**只活在进程内存里**（引擎重启即失效）。
// 因此 state 的 id 不能写死在配置里，只能在引擎起来之后按**原始文件名**去
// `/v1/state/list` 反查。
//
// 语义：
// * `fetched = true`：已经成功问过引擎。`byFilename` 里没有的文件说明
//   这个 state 没上传 → 调 state 的计划应如实回落基模（而不是发一个必然
//   400 的死 id）。
// * `fetched = false`：引擎没起 / 没问成。此时沿用产物上手工填的
//   `uploadedStateId`（用户自己保证它有效），避免彻底不可用。
library;

import 'dart:convert';

/// 引擎已上传 state 的索引（纯数据，可单测）。
class RwkvEngineStateIndex {
  const RwkvEngineStateIndex({
    this.fetched = false,
    this.byFilename = const <String, String>{},
    this.source = '',
  });

  /// 是否成功从引擎拉到过列表。
  final bool fetched;

  /// `original_filename`（如 `st1_prose-v2.pth`）→ `state_id`。
  final Map<String, String> byFilename;

  /// 成功查询时的引擎地址（诊断用）。
  final String source;

  /// 按产物文件路径取 state id（取 basename 去掉目录）。
  ///
  /// 找不到返回 null —— 调用方据此判断「这本书/岗位的 state 没上传」。
  String? stateIdForPath(String statePath) {
    final String path = statePath.trim();
    if (path.isEmpty) return null;
    final String base = path.split(RegExp(r'[\\/]')).last;
    final String? id = byFilename[base];
    return (id == null || id.isEmpty) ? null : id;
  }

  /// 解析 `/v1/state/list` 的响应体（`{"data":[{original_filename,state_id}]}`）。
  factory RwkvEngineStateIndex.fromListJson(Object? json, {String source = ''}) {
    final Map<String, String> map = <String, String>{};
    if (json is Map) {
      final Object? data = json['data'];
      final Iterable<Object?> rows = data is List
          ? data
          : (data is Map ? const <Object?>[] : const <Object?>[]);
      for (final Object? row in rows) {
        if (row is! Map) continue;
        final String name = (row['original_filename'] as String?)?.trim() ?? '';
        final String id = (row['state_id'] as String?)?.trim() ?? '';
        if (name.isEmpty || id.isEmpty) continue;
        map[name] = id;
      }
    }
    return RwkvEngineStateIndex(fetched: true, byFilename: map, source: source);
  }

  /// 解析原始 JSON 字符串（失败返回未查询状态）。
  factory RwkvEngineStateIndex.parse(String body, {String source = ''}) {
    try {
      return RwkvEngineStateIndex.fromListJson(jsonDecode(body), source: source);
    } on Object {
      return const RwkvEngineStateIndex();
    }
  }
}
