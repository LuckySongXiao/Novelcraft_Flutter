// 选节 AI 结果的「采纳应用」—— 纯 Dart 文本规则（零 import，可离线自检）。
//
// 用户实测（2026-10-10 第四次完善）：
//   「章节预览中对选中文本进行续写或者润色、扩写等操作后，没有让用户确认是否
//   应用。通常来说用户采纳之后，续写的文本需要被插入到所选文本的下一段，
//   润色和扩写的文本被采纳后需要替换所选文本段。」
//
// 此前预览页是只读快照，AI 结果只有「复制结果」—— 用户必须手工粘贴回编辑表单。
// 本文件只放**纯文本手术规则**；确认对话框 / 落库 / 表单回填在
// `chapter_ai_panel.dart` / `chapter_preview_page.dart` / `entity_page.dart`。
//
// ⚠ 输入的 `content` 约定为**展示态正文**（段落已被 trim 并用空行连接，
// 见 `chapter_preview_page._displayContent`）—— 选区文本来自阅读视图，
// 只有对同一份串做 indexOf 才永远命中。这也让应用结果是幂等的规范化文本。
library;

/// 把选节 AI 结果应用到正文中。
///
/// [content]  展示态正文（段落以空行连接）。
/// [selected] 当前选中的文本（必须原样出现在 [content] 中）。
/// [result]   AI 结果（采纳前已由用户确认）。
/// [insertAfter] true = 续写语义：结果作为**新的一段**插到所选文本所在段落的
///               下一段（原选中文本保留）；false = 替换语义：结果覆盖选中文本
///               （润色 / 去重润色 / 扩写 / 重写）。
///
/// 抛 `StateError` 当选区已不在正文中（选区过期，调用方如实报错）。
String applySelectionResult({
  required String content,
  required String selected,
  required String result,
  required bool insertAfter,
}) {
  final String cleanResult = result.trim();
  if (cleanResult.isEmpty) {
    throw StateError('AI result is empty; nothing to apply');
  }
  final int index = content.indexOf(selected);
  if (index < 0) {
    throw StateError('Selection no longer belongs to the chapter content');
  }
  final int end = index + selected.length;

  if (!insertAfter) {
    // 替换语义：选中文本 → AI 结果（原样原地）。
    return content.replaceRange(index, end, cleanResult);
  }

  // 续写语义：插到所选文本**所在段落的末尾之后**，作为独立的一段。
  // 选区可能停在段中 —— 此时必须先把该段剩余部分留在前面，
  // 不能把续写内容硬插进句子中间。
  int cut = content.indexOf('\n', end);
  if (cut < 0) cut = content.length;
  final String before = content.substring(0, cut).trimRight();
  final String rest = content.substring(cut).replaceFirst(RegExp(r'^\n+'), '');
  return rest.isEmpty
      ? '$before\n\n$cleanResult'
      : '$before\n\n$cleanResult\n\n$rest';
}

/// 「结果明显短于选区」的截断判据（纯函数，供选节编辑的 validate 复用）。
///
/// ⚠ 只有**替换语义**（润色 / 去重润色 / 扩写 / 重写）才成立 —— 结果覆盖选区，
/// 长度理应与选区相当。**续写语义是「新增」文本**（插到所选段落之后，原选区保留），
/// 其长度与选区长度没有任何可比性。
///
/// 用户实测 BUG（v1.0.0+46）：此前 validate 一律按 `result < selected * 0.6` 判截断，
/// 于是「选中一段 3000 字的长文 → 续写」时，模型产出的 1200 字合格续写
/// （≥ 续写下限 600 字）会被判成 `truncated_selection` → 两次重试都失败 → 整个
/// 续写动作如实报错。选区越长越必失败，正是「长选区续写永远失败」的根因。
///
/// [additive] 为 true（续写）时**恒返回 false**；[selectedLength] 非正时同样不判
/// （没有可比基线）。[minRatio] 为允许的最小长度比。
bool isTruncatedSelection({
  required int resultLength,
  required int selectedLength,
  required bool additive,
  double minRatio = 0.6,
}) {
  if (additive) return false;
  if (selectedLength <= 0) return false;
  return resultLength < selectedLength * minRatio;
}
