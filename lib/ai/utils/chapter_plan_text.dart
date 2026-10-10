// 续写切片规划 —— 纯 Dart 文本工具（零 import，可被离线自检直接引用）。
//
// 为什么需要它（用户实测，2026-10-10 第二次完善）：
//
//   「草稿按要求重写后，正文总篇幅未达预期」—— +43 的 `rewrite()` 是**单发生成**：
//   「目标约 4200 字」只写在提示词里，输出预算一次押完。7B 模型单发实际只出
//   1200~3100 字，过不了 3200 字的定稿质量闸；而质量闸不过 → **整稿不落库**
//   （坏稿绝不覆盖原稿的安全设计）→ `status` 停在 Draft、履历/时间线被一起卡住。
//
//   正解是把「重写」升级为**规划-续写-润色**管线（用户拍板的工艺）：
//     ① 调纲之后，先规划**续写切片数与每片目标字数**；
//     ② 按规划逐片续写（每片接在上一片末尾之后），不足自动补片；
//     ③ 达标后由主 Agent（7B）**逐段审查润色**；
//     ④ 过质量闸 → 落库（Draft → Completed）→ 更新履历 → 刷新项目进度。
//
// 本文件只放**纯文本规则**：规划解析、程序兜底规划、润色分块、续写回声去重。
// 编排逻辑在 `ChapterRewriteService.rewriteWithPlan()`。
//
// 设计约束（与 `outline_repair_text.dart` 同源）：
//   * 模型输出永远不可信 —— 解析要宽容、校验要严格，解析不出就程序兜底，
//     绝不因「模型没按格式给」让整次修复失败；
//   * 所有规则可离线自检（`tools/chapter_plan_selftest.dart`）。
library;

/// 一片续写任务：序号 + 目标字数 + 内容要点。
class ContinuationSlice {
  const ContinuationSlice({
    required this.index,
    required this.targetWords,
    required this.goal,
  });

  /// 1 起始的片序号（提示词里用于「第 N 片 / 共 M 片」）。
  final int index;

  /// 本片目标字数（程序校验后落在 300~2200）。
  final int targetWords;

  /// 本片要写的内容要点（空串 = 只按大纲写）。
  final String goal;

  @override
  String toString() => ' #$index ~${targetWords}字 ${goal.isEmpty ? '' : '· $goal'}';
}

/// 从模型输出里解析续写切片规划。
///
/// 接受的行形态（宽容匹配，逐行独立解析）：
/// ```text
/// 片1|1400|主角在地窖醒来，发现封条被动过
/// 2. 约1200字：与守夜人对质，亮出玉佩
/// 第3片 1600字 - 仪式开始，钩子留在火光熄灭前
/// Slice 4: 800 words — quiet aftermath
/// ```
/// 也接受只有「目标字数 + 一句话要点」、没有显式序号的行（序号按出现顺序补）。
///
/// [remainingWords] 还差多少字（用于**总量校验**：模型规划的总字数若连
/// 缺口的七成都不到，视为没规划 —— 返回 null，调用方走程序兜底）。
/// [maxSlices] 最多接受多少片（超出的行丢弃，防止模型把一章规划成 20 片）。
///
/// 返回 null = 不可用（空输出 / 没有合法行 / 总量校验不过）。
List<ContinuationSlice>? parseSlicePlan(
  String raw, {
  required int remainingWords,
  int maxSlices = 6,
}) {
  if (remainingWords <= 0) return const <ContinuationSlice>[];
  final List<ContinuationSlice> out = <ContinuationSlice>[];
  for (final String rawLine in raw.split(RegExp(r'\r?\n'))) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;
    // 剥 Markdown 列表符号与常见前后缀，只留主干。
    final String body = line
        .replaceFirst(RegExp(r'^[-*+]\s{1,2}'), '')
        .replaceFirst(RegExp(r'^\d+[.、)）]\s*'), '');
    final List<int> nums = RegExp(r'\d+')
        .allMatches(body)
        .map((Match m) => int.tryParse(m.group(0) ?? '') ?? 0)
        .where((int n) => n > 0)
        .toList();
    if (nums.isEmpty) continue;

    // 序号 = 第一个 ≤ maxSlices 的数（且后面还得有别数当字数，才认它是序号）；
    // 字数 = 第一个落在 300~3000 的数（含全角语境常见的 800/1200/1400…）。
    int target = 0;
    for (final int n in nums) {
      if (n >= 300 && n <= 3000) {
        target = n;
        break;
      }
    }
    if (target == 0) continue;
    // 要点 = 去掉字数数字后的剩余文字，再剥行首的序号 / 标签 / 分隔符。
    // ⚠ 顺序很关键：先删目标字数，再剥行首序号 —— 若先按序号删，会把
    // 「1500」里的「1」吃掉（自检 A10 锁死这一点）。
    String goal = body
        .replaceFirst('$target', '')
        .replaceAll(
            RegExp(r'\bwords?\b|约|目标字数|字数|目标', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^[\s|｜:：，,.\-—－··]+'), '')
        .replaceFirst(
            RegExp(r'^(?:第\s*\d+\s*[片段]|片\s*\d+|slice\s*\d*|part\s*\d*|'
                r'section\s*\d+)\s*',
                caseSensitive: false),
            '')
        .replaceFirst(RegExp(r'^[\s|｜:：，,.\-—－·]+'), '')
        .trim();
    if (goal.length > 120) goal = goal.substring(0, 120);
    out.add(ContinuationSlice(index: out.length + 1, targetWords: target, goal: goal));
  }
  if (out.isEmpty) return null;
  // 总量校验必须按**全量解析结果**算 —— 若先按 maxSlices 截断再验总量，
  // 「模型给了 9 片、系统只收 6 片」的合法规划会被误判成总量不足
  //（自检 A14 锁死这一点）。截断放在校验之后，缺口由调用方的补片循环兜底。
  final int total = out.fold<int>(0, (int s, ContinuationSlice x) => s + x.targetWords);
  if (total < remainingWords * 0.7) return null;
  if (out.length > maxSlices) {
    out.removeRange(maxSlices, out.length);
  }
  return out;
}

/// 程序兜底规划：把缺口按 [perSlice] 均分（片数不超过 [maxSlices]，
/// 单片目标不超过 2200 —— 每片的输出预算按 `target*2` 给，2200 字 ≈ 4400 token
/// 已接近单发可靠上限，再多就回到「押一次输出」的老问题）。
List<ContinuationSlice> fallbackSlices({
  required int remainingWords,
  int perSlice = 1400,
  int maxSlices = 6,
}) {
  if (remainingWords <= 0) return const <ContinuationSlice>[];
  final int effectivePer = perSlice.clamp(300, 2200);
  int count = (remainingWords / effectivePer).ceil();
  // 单片不得超过 2200：片数不够就加片。
  final int minCount = (remainingWords / 2200).ceil();
  if (count < minCount) count = minCount;
  if (count > maxSlices) count = maxSlices;
  final int each = ((remainingWords / count).ceil() / 50).ceil() * 50;
  return <ContinuationSlice>[
    for (int i = 0; i < count; i++)
      ContinuationSlice(index: i + 1, targetWords: each.clamp(300, 2200), goal: ''),
  ];
}

/// 把待润色全文按**句子边界**切块（每块约 [target] 字）。
///
/// 移植自整书生成链路的 `_polishDraft` 分块策略：优先在块尾附近找「。」，
/// 找不到（至少 [minKeep] 字起找）就按块长硬切。逐段润色必须保持块边界
/// 在句号上，否则润色稿拼回去会出现半句。
List<String> chunkForPolish(
  String text, {
  int target = 900,
  int minKeep = 450,
}) {
  final List<String> out = <String>[];
  int start = 0;
  while (start < text.length) {
    int end = (start + target).clamp(0, text.length);
    if (end < text.length) {
      final int sentence = text.lastIndexOf('。', end);
      if (sentence > start + minKeep) end = sentence + 1;
    }
    final String chunk = text.substring(start, end).trim();
    if (chunk.isNotEmpty) out.add(chunk);
    start = end;
  }
  return out;
}

/// 去掉续写片开头的**回声**：模型常把提示词里的「前文末尾」逐字抄一遍再往下写。
///
/// [tail] 是已积累正文的末尾（取最后 [window] 字）；若新片以它的某个后缀
/// 逐字开头且重叠 ≥ [minOverlap] 字，就把重叠部分切掉。顺带剥掉被回抄的
/// 提示词标记（`【前文末尾】` 等）—— 这些标记一旦混进正文，就是用户实测
/// 「章节正文里出现提示词原文」的直接来源。
String trimSliceEcho(
  String tail,
  String slice, {
  int window = 120,
  int minOverlap = 12,
}) {
  String s = slice.trim();
  // 回抄的提示词标记（含变体）一律剥掉。
  s = s.replaceAll(RegExp(r'【前文末尾[^】]*】'), '').trim();
  if (tail.isEmpty || s.isEmpty) return s;
  final String suffix =
      tail.length > window ? tail.substring(tail.length - window) : tail;
  int best = 0;
  for (int k = 0; k <= suffix.length; k++) {
    if (s.startsWith(suffix.substring(k))) {
      final int overlap = suffix.length - k;
      if (overlap > best) best = overlap;
    }
  }
  if (best < minOverlap) return s;
  s = s.substring(best);
  // 重叠点常落在句中：把残余的半句开头（到下一个句读符号为止）也去掉，
  // 让续写从干净的句子边界开始。
  final int boundary = s.indexOf(RegExp(r'[。！？!?…\n]'));
  if (boundary >= 0 && boundary < s.length - 1) {
    s = s.substring(boundary + 1);
  }
  return s.trim();
}
