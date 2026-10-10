// 设定抽取结果的**文本归一与容错判定** —— 纯 Dart，无 Flutter / drift 依赖，
// 因此可以离线自检（`dart --disable-dart-dev tools/entity_update_selftest.dart`）。
//
// 为什么单独成文件：这两条规则最初埋在 `ModuleStateService` 里，而那个类 import 了
// drift → 会被 `database.dart` 把 Flutter framework 拖进来，脚本直跑必崩
// （满屏 `Offset isn't defined`）。抽到 `lib/ai/utils/` 后才能给它们写回归。
//
// 两条规则都来自 2026-10-09 的真机复现（7B 端点直连，用用户项目里的真实章节）：
//   1. `evidence` 被模型写成「拼接引用 + `正文：` 前缀」→ 旧的「必须是连续子串」
//      判据**条条必败** → 整章 0 条设定；
//   2. 行式兜底的表行带 Markdown 表格边框（行首 `|`）→ `split('|')` 切出空段 →
//      `类别 = ''` → **整行被丢弃** → 兜底等于没跑。
library;

/// 模型爱给 evidence 加的前缀标签（都取自提示词里的字段名）。
const List<String> kEvidencePrefixes = <String>[
  '正文：', '正文:', '原文：', '原文:', '证据：', '证据:',
  '引用：', '引用:', 'quote：', 'quote:', 'evidence：', 'evidence:',
  'Evidence：', 'Evidence:',
];

/// 去掉 evidence 上多余的字段名前缀（可叠加，`正文：evidence:xxx` 也能剥干净）。
String stripEvidencePrefix(String evidence) {
  String e = evidence.trim();
  bool changed = true;
  while (changed) {
    changed = false;
    for (final String prefix in kEvidencePrefixes) {
      if (e.length > prefix.length && e.startsWith(prefix)) {
        e = e.substring(prefix.length).trim();
        changed = true;
      }
    }
  }
  return e;
}

/// 判定 [evidence] 是否**在正文里有依据**。
///
/// 旧判据是 `source.contains(evidence)` —— 要求 evidence 是正文的**连续子串**。
/// 小模型（7B）习惯把 evidence 写成拼接引用：把多处原句连在一起、还带 `正文：`
/// 前缀，于是永远不是连续子串 → 每条都判非法 → 整章 0 条设定。
///
/// 这里改为**分段有据**：先脱前缀；整段命中最好；否则按句读 / 标点切段，
/// 任意一段长度 ≥ [minSegment] 且出现在正文即算有据。
///
/// 防幻觉的真正闸门是「实体名必须原样出现在正文」（见 `ModuleStateService.validate`），
/// evidence 只是佐证 —— 因此这里可以宽松，不放松名字那道闸。
bool evidenceSharesText(String evidence, String source, {int minSegment = 8}) {
  final String e = stripEvidencePrefix(evidence);
  if (e.isEmpty) return false;
  if (source.contains(e)) return true;
  final RegExp separators = RegExp(
    r'[。！？!?；;，,、\n\r\t…—\-（）()「」『』“”"\[\]【】\s]+',
  );
  for (final String segment in e.split(separators)) {
    final String s = segment.trim();
    if (s.length >= minSegment && source.contains(s)) return true;
  }
  return false;
}

/// 把一行「竖线分隔」的登记表切成单元格；**该行不是数据行时返回 `null`**。
///
/// 需要它的原因：7B 在实际运行里几乎总是加上 Markdown 表格外壳
/// （`|类别|名称|字段|变化|` 加一行 `|---|---|---|---|`）。旧解析器直接
/// `split('|')`，行首那个 `|` 会切出一个**空单元格**，于是 `类别 = ''` 查不到
/// 目标 → **整行被丢弃**，行式兜底等于没跑。
///
/// 处理：
///   * 剥掉列表符号 / 序号前缀（模型常画蛇添足）；
///   * 整行只是分隔线（`|---|:--:|`）→ 判为非数据；
///   * 去掉行首 / 行尾的表格边框空段，**中间的真空段保留**（模型漏写字段时
///     由调用方按 `cells.length < 4` 判非法，而不是在这里静默补齐）。
List<String>? pipeRowCells(String rawLine) {
  String line = rawLine.trim();
  line = line.replaceFirst(RegExp(r'^[-*·•+>]\s*'), '');
  line = line.replaceFirst(RegExp(r'^\d+\s*[.、)]\s*'), '').trim();
  if (line.isEmpty) return null;
  // 表格分隔线：只含 | - : 与空白，且至少有一个 '-'
  if (line.contains('-') && RegExp(r'^\|?[\s:|~-]+\|?$').hasMatch(line)) {
    return null;
  }
  final List<String> cells = <String>[
    for (final String c in line.split(RegExp(r'[|｜]'))) c.trim(),
  ];
  while (cells.isNotEmpty && cells.first.isEmpty) {
    cells.removeAt(0);
  }
  while (cells.isNotEmpty && cells.last.isEmpty) {
    cells.removeAt(cells.length - 1);
  }
  return cells.isEmpty ? null : cells;
}
