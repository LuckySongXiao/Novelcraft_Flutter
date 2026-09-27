// 新书概念（书名 / 类型 / 简介）解析 —— 对应 C# `OneClickNovelGenerationService.ParseConcept`
// / `CleanConceptValue` / `ContainsConceptInstructionMarker` / `FirstNonEmptyEn`。
//
// 为什么单独成文件：这段解析是**纯字符串处理**，且真机验收时连踩两个坑
// （详见下面两处 ⚠），抽成纯 Dart 后可由 `tool/verify_concept_parser.dart` 直接回归。
//
//  两处**有意修的 C# bug**：
// 1. 行首装饰符集合漏了 `>`：小模型常把首行写成 markdown 引用 `>书名：xxx`，
//    C# 的 `Trim(' ', '\t', '-', '*', '•', '#')` 不含 `>` ⇒ 整行不被识别 ⇒ **书名丢失**、
//    最终退化成兜底名（真机实测：书名变成《AI新书》）。
// 2. 只认全角「：」：模型偶发写半角 `:` ⇒ 该字段整行丢弃。这里两种冒号都认。
library;

/// 三行概念解析结果。
typedef ParsedBookConcept = ({String title, String genre, String premise});

/// 行首/行尾装饰符（含 `>`，见文件头 ⚠1）。
const String _kDecorationChars = r'\s\-\*•#>';

/// 解析 RWKV 输出的「书名 / 类型 / 简介」三行。
///
/// 字段标签固定为中文（`书名：/类型：/简介：`），**英文模式下也一样** ——
/// 这样英文输出也能复用同一套解析器（C# 明确如此设计）。
ParsedBookConcept parseBookConcept(
  String content, {
  required bool isEnglish,
  DateTime? now,
}) {
  String title = '';
  String genre = isEnglish ? 'Fiction' : '长篇书籍';
  String premise = '';

  for (final String rawLine in content.replaceAll('\r\n', '\n').split('\n')) {
    final String line = _trimDecoration(rawLine);
    final String? titleValue = labelValue(line, const <String>['书名']);
    final String? genreValue = labelValue(line, const <String>['类型']);
    final String? premiseValue = labelValue(line, const <String>['简介', '梗概']);
    if (titleValue != null) {
      // ⚠ 小模型常把**模板行原样回显**（实测：`书名：（不超过12个字的中文书名，不要书名号）`）。
      // C# 只在"兜底扫描"里过滤指令行，标签命中路径不过滤 ⇒ 回显会被当成真书名入库。
      // 这里对**书名与类型**补上过滤（简介不做：故事简介里合法出现「输出/格式」等词的概率不可忽略）。
      if (!containsConceptInstructionMarker(titleValue)) {
        title = cleanConceptValue(titleValue);
      }
    } else if (genreValue != null) {
      if (!containsConceptInstructionMarker(genreValue)) {
        genre = cleanConceptValue(genreValue);
      }
      if (genre.trim().isEmpty) genre = isEnglish ? 'Fiction' : '长篇书籍';
    } else if (premiseValue != null) {
      premise = cleanConceptValue(premiseValue);
    }
  }

  if (title.trim().isEmpty) {
    // 兜底：取首个非空短文本，排除提示词回显/指令行，
    // 防止「（不超过12个字的中文书名…）」这类残留入库。
    String fallback = '';
    for (final String l in content.replaceAll('\r\n', '\n').split('\n')) {
      final String cleaned = cleanConceptValue(l);
      if (cleaned.trim().isNotEmpty &&
          cleaned.length <= 24 &&
          !containsConceptInstructionMarker(cleaned)) {
        fallback = cleaned;
        break;
      }
    }
    title = fallback.trim().isNotEmpty
        ? fallback
        : conceptPlaceholderTitle(isEnglish, now);
  }

  if (premise.trim().isEmpty) {
    premise = isEnglish
        ? 'A brand-new book project generated end-to-end by the RWKV dual agents.'
        : '由 RWKV 双 Agent 一键生成的全新书籍项目。';
  }

  return (title: title, genre: genre, premise: premise);
}

/// 对应 C# `FirstNonEmptyEn`，但**去掉了 `startsWith("AI新书")` 那一条**。
///
/// 原因：C# 那条只为"英文模式下把中文占位书名换成英文占位"，
/// 而这里 [parseBookConcept] 已按语种生成各自占位；再按前缀拒绝会把**带时间戳的占位**
/// 降级成常量 `AI新书`，丢掉唯一性。
String firstNonEmptyConcept(String? value, String fallback) {
  final String v = (value ?? '').trim();
  if (v.isEmpty || containsConceptInstructionMarker(v)) return fallback;
  return v;
}

/// 空书名占位（带时间戳保证唯一）。
///
/// 公开给服务层复用：兜底路径不能退化成常量 `AI新书`，否则同名项目只能靠
/// `EnsureUniqueProjectName` 事后加时间戳，UI 上却已经显示成重复书名。
String conceptPlaceholderTitle(bool isEnglish, [DateTime? now]) {
  final DateTime t = now ?? DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  final String stamp = '${p(t.month)}${p(t.day)}${p(t.hour)}${p(t.minute)}';
  return isEnglish ? 'New Book $stamp' : 'AI新书$stamp';
}

/// 若该行是 `{label}：值` / `{label}:值` 形态，返回值部分；否则 null。
String? labelValue(String line, List<String> labels) {
  for (final String label in labels) {
    if (!line.startsWith(label)) continue;
    final String rest = line.substring(label.length);
    for (final String sep in <String>['：', ':']) {
      if (rest.startsWith(sep)) return rest.substring(sep.length).trim();
    }
  }
  return null;
}

/// 对应 C# `ContainsConceptInstructionMarker`（标记清单逐字移植）。
bool containsConceptInstructionMarker(String value) {
  final String v = value;
  final String lower = v.toLowerCase();
  return v.contains('书名') ||
      v.contains('不要') ||
      v.contains('输出') ||
      v.contains('类型') ||
      v.contains('简介') ||
      v.contains('格式') ||
      v.contains('EXACTLY') ||
      v.contains('label') ||
      lower.startsWith('assistant') ||
      lower.startsWith('user') ||
      v.contains('thinking') ||
      v.contains('We need');
}

/// 对应 C# `CleanConceptValue`：去装饰字符 → 非法文件名字符换 `_` → 截断 60。
///
/// 装饰字符除行首行尾的 `[\s\-*•#>]`（见 [_trimDecoration]）外，还要剥书名号与引号
/// —— C# 原实现是 `Trim(' ', '\t', '*', '#', '《', '》', '"', '"', '「', '」')`，
/// 少剥一层会让 `《异界战神》` 带着书名号入库。
String cleanConceptValue(String value) {
  final String cleaned =
      _trimDecoration(value).replaceAll(RegExp(r'^[《》""「」]+|[《》""「」]+$'), '');
  final StringBuffer sb = StringBuffer();
  for (final int code in cleaned.runes) {
    sb.write(_invalidFileNameChars.contains(code) ? '_' : String.fromCharCode(code));
  }
  final String out = sb.toString();
  return out.length > 60 ? out.substring(0, 60) : out;
}

/// `Path.GetInvalidFileNameChars()`（Windows）等价集合。
Set<int> get _invalidFileNameChars => <int>{
      for (int c = 0; c < 32; c++) c,
      ...'<>:"/\\|?*'.codeUnits,
    };

/// 去行首/行尾装饰符（`>` 也在内 —— C# 漏了它，见文件头 ⚠1）。
String _trimDecoration(String line) =>
    line.replaceAll(RegExp('^[$_kDecorationChars]+|[$_kDecorationChars]+\$'), '');