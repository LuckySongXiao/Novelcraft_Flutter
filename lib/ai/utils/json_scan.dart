// 小模型输出的 JSON 抢救工具（纯 Dart）。
//
// 为什么需要它：本地/云端小模型几乎没有一次就吐纯 JSON 的 —— 前后总要加
// 「好的，以下是分析结果：」「希望对你有帮助」这类话，偶尔还会在字符串里
// 塞入未转义的引号。直接把整段丢给 `jsonDecode` 必然抛异常。
//
// 做法是**平衡扫描**：从某个起始括号开始数深度（跳过字符串内部），
// 深度归零时取这一段试 `jsonDecode`，失败就换下一个起点。
//
// 放在 `lib/ai/utils/` 并保持纯 Dart：设定抽取（`ModuleStateService.parse`）、
// 档案归纳（`profile_synthesis_text`）、拆书（`style_digest_text`）、
// 审查留言（`book_content_review_service`）四处共用，
// 且都要能被 `dart --disable-dart-dev` 直跑的离线自检覆盖
//（见 `tools/json_scan_selftest.dart`）。
library;

import 'dart:convert';

/// 从可能夹杂散文的文本里，扫出第一个合法的 JSON **对象**。
///
/// ⚠ 语义是「任意位置、指定类型」：文本是 `[{…}]` 时它会命中**内层对象**，
/// 是 `{"comments":[…]}` 时命中外层对象。需要「按模型实际给出的顶层结构」
/// 解析时用 [parseJsonPayload]。
///
/// 返回 null 表示确实没有可用的对象（半截 JSON、纯说明文字等）。
///
/// 顺带说明：**不需要**先剥 ```` ```json ```` 围栏 —— 扫描从每个 `{` 起算，
/// 围栏自然落到候选区间之外。
Map<String, dynamic>? parseJsonObject(String raw) {
  for (int start = 0; start < raw.length; start++) {
    if (raw[start] != '{') continue;
    final Object? value = _scanFrom(
      raw,
      start,
      '{',
      '}',
      (Object? v) => v is Map<String, dynamic>,
    );
    if (value != null) return value as Map<String, dynamic>;
  }
  return null;
}

/// 从可能夹杂散文的文本里，扫出第一个合法的 JSON **数组**。
///
/// ⚠ 同上：`{"comments":[…]}` 会被它命中**内层数组**。单独开这个入口是因为
/// 审查留言在模型那里有两种合法形态（`{"comments":[…]}` 与裸数组 `[{…}]`），
/// 旧实现只认前者且用贪婪正则 `\{[\s\S]*\}` 取「第一个 `{` 到最后一个 `}`」，
/// 正文里再出现一对花括号就整段截歪。
List<dynamic>? parseJsonArray(String raw) {
  for (int start = 0; start < raw.length; start++) {
    if (raw[start] != '[') continue;
    final Object? value = _scanFrom(raw, start, '[', ']', (Object? v) => v is List);
    if (value != null) return value as List<dynamic>;
  }
  return null;
}

/// 按**模型实际给出的顶层结构**解析出第一个平衡的 JSON 对象或数组。
///
/// 与 [parseJsonObject] / [parseJsonArray] 的关键差异：括号类型由「最先出现的
/// 那个结构字符」决定，因此
///   * `{"comments":[…]}` → 返回**外层对象**（不会被内层数组抢走）；
///   * `[{"severity":"error"}]` → 返回**整个数组**（不会被内层对象抢走）。
///
/// 这正是审查留言需要的语义 —— 两种形态都合法，且必须区分：
/// 若把 `[{…}]` 解析成内层对象，`decoded['comments']` 必然取不到，
/// 整章留言会被误判为「审查未产出」。
///
/// 起点不成立（半截 JSON / `{a:1}` 这类非 JSON）时继续往后找下一个结构字符。
Object? parseJsonPayload(String raw) {
  for (int start = 0; start < raw.length; start++) {
    final String ch = raw[start];
    final bool isObject = ch == '{';
    if (!isObject && ch != '[') continue;
    final Object? value = _scanFrom(
      raw,
      start,
      ch,
      isObject ? '}' : ']',
      (Object? v) => v is Map<String, dynamic> || v is List,
    );
    if (value != null) return value;
  }
  return null;
}

/// 从 [start]（必为 [open]）开始平衡扫描：只统计 **同类** 括号的深度，
/// 字符串内部的括号与另一种括号都不参与计数。深度归零时取该段试
/// `jsonDecode`；[accept] 判类型，不通过或解析失败返回 null（由调用方换起点）。
Object? _scanFrom(
  String raw,
  int start,
  String open,
  String close,
  bool Function(Object? value) accept,
) {
  int depth = 0;
  bool quoted = false;
  bool escaped = false;
  for (int i = start; i < raw.length; i++) {
    final String ch = raw[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch == '\\' && quoted) {
      escaped = true;
      continue;
    }
    if (ch == '"') quoted = !quoted;
    // 字符串内部的括号不参与计数 —— 否则正文里随便一个 `{` 就会把深度带偏。
    if (quoted) continue;
    if (ch == open) depth++;
    if (ch == close) depth--;
    if (depth < 0) break;
    if (depth != 0) continue;
    try {
      final Object? value = jsonDecode(raw.substring(start, i + 1));
      if (accept(value)) return value;
    } on FormatException {
      // 这个平衡片段不是合法 JSON（例如 `{a:1}`），换下一个起点再试。
    }
    break;
  }
  return null;
}
