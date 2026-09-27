// AI 状态抽取解析器 —— 功能 C 二级（纯 Dart，零 flutter import）。
//
// 输入：写作模型对「章节状态抽取」提示词的原始输出（预期是一段 JSON）。
// 输出：[StateExtractionResult]；解析失败返回 null —— 调用方如实跳过，不重试。
//
// 容错（对齐 concept_parser 的实战教训）：
//   1. 模型常在 JSON 外套话（“以下是抽取结果：”）→ 截取**首个配平的 {...}** 块；
//   2. 模型可能把提示词原样回显 → 条目里含抽取指令标记的整条丢弃；
//   3. name 为空 / 超长（>50 字）的条目丢弃（防幻觉行污染）；
//   4. 单引号 JSON 尝试一次修复性替换（中文正文里单引号罕见，风险可控）；
//   5. 任何条目字段截断到 200 字，防超长注入。
library;

import 'dart:convert' show jsonDecode;

/// 单个实体的状态变化。
class ExtractedEntityState {
  const ExtractedEntityState({
    required this.name,
    this.status,
    this.location,
    this.change,
  });

  final String name;
  final String? status;
  final String? location;
  final String? change;
}

/// 抽取结果：四类实体各自的更新清单（全部为空 = 模型没抽出东西）。
class StateExtractionResult {
  const StateExtractionResult({
    this.characters = const <ExtractedEntityState>[],
    this.factions = const <ExtractedEntityState>[],
    this.worldSettings = const <ExtractedEntityState>[],
    this.plots = const <ExtractedEntityState>[],
  });

  final List<ExtractedEntityState> characters;
  final List<ExtractedEntityState> factions;
  final List<ExtractedEntityState> worldSettings;
  final List<ExtractedEntityState> plots;

  int get total =>
      characters.length + factions.length + worldSettings.length + plots.length;

  bool get isEmpty => total == 0;
}

/// 提示词里的指令标记：条目 name 命中即视为回显污染（concept_parser 同思路）。
/// 包含模板占位名（模型回显模板时 name 会原样出现）。
const List<String> kStateExtractionMarkers = <String>[
  '抽取',
  '状态变化',
  '输出格式',
  'JSON',
  'json',
  '提取',
  // 模板占位名（防「照抄模板」式回显）
  '人物名',
  '势力名',
  '设定名',
  '剧情名',
  '当前状态',
  '所在位置',
  '本章带来的变化',
  '本章推进',
];

/// 从模型原始输出解析状态抽取结果；失败返回 null（绝不抛异常）。
StateExtractionResult? parseStateExtraction(String? raw) {
  final String? json = _firstBalancedJsonObject(raw ?? '');
  if (json == null) return null;

  Map<String, dynamic>? decoded = _tryDecode(json);
  decoded ??= _tryDecode(json.replaceAll("'", '"'));
  if (decoded == null) return null;

  return StateExtractionResult(
    characters: _items(decoded['characters']),
    factions: _items(decoded['factions']),
    worldSettings: _items(decoded['worldSettings']),
    plots: _items(decoded['plots']),
  );
}

/// 抽取提示词（中文标签固定，正文可英文）。
String buildStateExtractionPrompt(String chapterTitle, String content) {
  return '阅读以下章节正文，抽取人物/势力的状态变化与剧情、世界设定的最新进展。\n'
      '只输出一个 JSON 对象，不要任何解释、不要代码块标记。输出格式：\n'
      '{"characters":[{"name":"人物名","status":"当前状态","location":"所在位置"}],'
      '"factions":[{"name":"势力名","status":"当前状态"}],'
      '"worldSettings":[{"name":"设定名","change":"本章带来的变化"}],'
      '"plots":[{"title":"剧情名","change":"本章推进"}]}\n'
      '要求：只写正文里明确体现的内容；没有变化的类别输出空数组；name 必须与正文用词一致。\n\n'
      '章节标题：$chapterTitle\n章节正文：\n${_truncate(content, 4000)}';
}

// ---------------------------------------------------------------------------
// 私有工具
// ---------------------------------------------------------------------------

String _truncate(String s, int max) =>
    s.length <= max ? s : s.substring(0, max);

/// 截取首个花括号配平的 JSON 对象（处理模型前后加话/代码块围栏）。
String? _firstBalancedJsonObject(String raw) {
  final int start = raw.indexOf('{');
  if (start < 0) return null;
  int depth = 0;
  bool inString = false;
  bool escaped = false;
  for (int i = start; i < raw.length; i++) {
    final String ch = raw[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch == '\\') {
      escaped = true;
      continue;
    }
    if (ch == '"') inString = !inString;
    if (inString) continue;
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return raw.substring(start, i + 1);
    }
  }
  return null;
}

Map<String, dynamic>? _tryDecode(String s) {
  try {
    final Object? v = jsonDecode(s);
    if (v is Map<String, dynamic>) return v;
    if (v is Map) {
      return v.map(
        (Object? k, Object? val) => MapEntry<String, dynamic>('$k', val),
      );
    }
  } on Object {
    return null;
  }
  return null;
}

List<ExtractedEntityState> _items(Object? raw) {
  if (raw is! List) return const <ExtractedEntityState>[];
  final List<ExtractedEntityState> out = <ExtractedEntityState>[];
  for (final Object? item in raw) {
    if (item is! Map) continue;
    final String name = _cleanStr(
      item['name'] ?? item['title'] ?? item['Name'],
    );
    if (name.isEmpty || name.length > 50) continue;
    // 防回显：条目名带指令标记 → 整条丢弃
    if (kStateExtractionMarkers.any((String m) => name.contains(m))) continue;
    out.add(
      ExtractedEntityState(
        name: name,
        status: _cleanStr(item['status']),
        location: _cleanStr(item['location']),
        change: _cleanStr(item['change']),
      ),
    );
  }
  return out;
}

String _cleanStr(Object? v) {
  if (v == null) return '';
  String s = '$v'.trim();
  if (s.isEmpty) return '';
  // 剥掉常见装饰符（markdown 引用/列表符号）
  s = s.replaceFirst(RegExp(r'^[\s>\-*•#]+'), '').trim();
  return s.length > 200 ? s.substring(0, 200) : s;
}
