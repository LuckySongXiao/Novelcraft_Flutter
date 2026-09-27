// 长文分段改写工艺 —— 对应 C# `Services/Copilot/CreationPipelineService` 的
// `RewriteChapterCoreAsync` / `RewriteSegmentChars` / `RewriteSliceTokens` /
// `IsDuplicateSlice` / `Stitch` / `TailOf` / `CleanSlice` 一组方法。
//
// 为什么必须分段：关联章节正文动辄数千字，而**单次生成的输出预算有限** ——
// 一次性改写的结果是「后段被截断 / 全文被压缩变短」。C# 的工艺是：
//   ① 按固定字数把原文切片；
//   ② 逐片携带「处理要求 + 上一片已处理结尾」滚动改写，保证段间衔接；
//   ③ 尾部复读检测：输出与原文片段几乎相同（或与上一片尾部重复）→ 换更强提示词重试；
//   ④ 拼接成完整正文，**整体成功才落库**（中途失败不写半个章节）。
//
// 本文件是**纯函数集合**：不 import Flutter、不发任何请求，
// 因此 `tool/verify_segment_rewrite.dart` 可用 `dart run` 直跑。
//
// 与 C# 的两处有意差异（不照抄明显缺陷）：
//   1. C# 用 `cleaned.Replace("---", string.Empty)` **全局**删除三个连字符，
//      正文里合法出现的 `---`（破折号、分隔线以外的场景）会被吃掉；这里只删除
//      「独占一行的分隔线」，语义等价且不会误伤正文。
//   2. C# 的 `IsDuplicateSlice` 用 `previous.EndsWith(head)` 判断「上一片尾部」
//      与「下一片头部」重复；这里保持同一判据（忠实现有工艺），
//      但把比对字符数抽成常量便于验证。
library;

import 'output_sanitizer.dart';

/// 分段计划（[SegmentRewrite.plan] 的返回值）。
///
/// 存在的意义是把「切片」与「闸门判定」绑在一起：调用方拿到计划后**先看
/// [exceedsLimit]**，超限就在做任何模型调用之前退出。
class SegmentPlan {
  /// 切好的原文片段（顺序即改写顺序）。
  final List<String> slices;

  /// 段数上限。
  final int limit;

  const SegmentPlan({required this.slices, required this.limit});

  /// 实际段数。
  int get count => slices.length;

  /// 是否超过段数上限（true → 调用方直接拒绝，不做任何模型调用）。
  bool get exceedsLimit => count > limit;
}

/// 分段改写工艺常量与纯函数。
abstract final class SegmentRewrite {
  /// 单段原文长度（对应 C# `RewriteSegmentChars`）。
  static const int segmentChars = 1800;

  /// 单段输出 token 预算（对应 C# `RewriteSliceTokens`）。
  static const int sliceTokens = 1800;

  /// 携带给下一段参考的「已处理结尾」字数（对应 C# `TailOf(parts[^1], 500)`）。
  static const int carryTailChars = 500;

  /// 处理要求写进提示词时的截断长度（对应 C# `Truncate(instruction, 300)`）。
  static const int instructionChars = 300;

  /// 复读判定的比对字符数（对应 C# `IsDuplicateSlice` 的 60）。
  static const int duplicateHeadChars = 60;

  /// 判定是否必须走分段工艺：原文超过单段容量即为长文。
  static bool needsSegmentation(String text, {int size = segmentChars}) =>
      text.length > size;

  /// **段数上限**（闸门）。
  ///
  /// 分段成本是线性的：每段一次模型调用，还可能要复读重试。按 [segmentChars]
  /// 算，上限 12 段 ≈ 2.16 万字；再长说明这一章本身该拆章，或者该走「长篇批量
  /// 生成」通道，而不是靠几十轮请求硬啃。
  ///
  /// 超限时必须**直接拒绝**，绝不能「只改前 N 段」—— 那会把正文切成
  /// 「改过的前半 + 原样的后半」，风格断层且作者看不出原因。
  static const int maxSegments = 12;

  /// 制定分段计划（切片 + 是否超上限）。
  ///
  /// 调用方应在**发起任何模型调用之前**检查 [SegmentPlan.exceedsLimit]。
  static SegmentPlan plan(
    String text, {
    int size = segmentChars,
    int limit = maxSegments,
  }) =>
      SegmentPlan(slices: split(text, size: size), limit: limit);

  /// 按固定长度切片（对应 C# `original[i .. i + RewriteSegmentChars]`）。
  ///
  /// 空串返回空列表；长度不足一段时返回单元素列表。
  static List<String> split(String text, {int size = segmentChars}) {
    if (text.isEmpty) return const <String>[];
    if (size <= 0) return <String>[text];
    final List<String> out = <String>[];
    for (int i = 0; i < text.length; i += size) {
      final int end = i + size < text.length ? i + size : text.length;
      out.add(text.substring(i, end));
    }
    return out;
  }

  /// 拼接各段（对应 C# `Stitch`：跳过空白段，段间单个换行，段内 trim）。
  static String stitch(List<String> parts) {
    final StringBuffer sb = StringBuffer();
    for (final String part in parts) {
      if (part.trim().isEmpty) continue;
      if (sb.isNotEmpty) sb.write('\n');
      sb.write(part.trim());
    }
    return sb.toString();
  }

  /// 取文本尾部（对应 C# `TailOf`，用于跨段衔接）。
  static String tailOf(String? text, {int maxChars = carryTailChars}) {
    if (text == null || text.isEmpty) return '（缺失）';
    if (text.length <= maxChars) return text;
    return '……${text.substring(text.length - maxChars)}';
  }

  /// 截断（对应 C# `Truncate`）；空值返回 null。
  static String? truncate(String? text, int maxChars) {
    if (text == null || text.isEmpty) return null;
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}……';
  }

  /// 复读检测（对应 C# `IsDuplicateSlice`）。
  ///
  /// 判定「下一片」是否只是把「上一片」又抄了一遍：完全相同，或下一片开头
  /// [duplicateHeadChars] 个字符就是上一片的结尾。
  static bool isDuplicateSlice(String previous, String next) {
    if (previous.trim().isEmpty || next.trim().isEmpty) return false;
    final String a = previous.trim();
    final String b = next.trim();
    if (a == b) return true;
    final String head =
        b.length >= duplicateHeadChars ? b.substring(0, duplicateHeadChars) : b;
    return a.endsWith(head);
  }

  /// 把提示词正文包成 RWKV 官方经典单条 prompt
  /// （对应 C# `"User: " + … + "\n\nAssistant:  thinking</think\n"`）。
  static String wrapRawPrompt(String body) =>
      'User: $body\n\nAssistant:  thinking</think\n';

  /// 单段改写提示词（**不含** [wrapRawPrompt] 的包裹）。
  ///
  /// C# 版把书名/卷序/章序写进提示词作为定位信息；Dart 侧只带书名与章节标题
  /// （卷/章序在 drift 侧是 orderIndex，语义随页面写法漂移，写错不如不写）。
  static String buildSegmentPrompt({
    required String projectName,
    required String chapterTitle,
    required String instruction,
    required String carryTail,
    required int index,
    required int total,
    required String segment,
    required bool isEnglish,
  }) {
    if (isEnglish) {
      final List<String> lines = <String>[
        'You are a top-tier fiction editor. You are revising the chapter "$chapterTitle"'
            '${projectName.trim().isEmpty ? '' : ' of "$projectName"'}, following the author\'s instruction.',
        '[Instruction] $instruction',
        '[End of the text you already revised]',
        carryTail.trim().isEmpty ? '(this is the opening)' : carryTail,
        '[Source segment $index/$total]',
        segment,
        '[Requirements] Output only the revised text for the source segment above'
            '${index > 1 ? ', keeping it coherent with the previous part' : ''}.'
            ' Keep the length close to the source. No explanations, no headings, no echoing this prompt.',
      ];
      return lines.join('\n');
    }
    final List<String> lines = <String>[
      '你是顶级中文网文编辑，正在按作者要求处理${projectName.trim().isEmpty ? '' : '《${projectName.trim()}》'}'
          '的章节《$chapterTitle》。',
      '【处理要求】$instruction',
      '【已处理正文结尾】',
      carryTail.trim().isEmpty ? '（本段为开头）' : carryTail,
      '【原文片段 $index/$total】',
      segment,
      '【要求】输出上述片段处理后的正文（长度与片段相近，可略有增减）：直接输出正文，'
          '${index > 1 ? '与上文已处理内容衔接连贯；' : ''}禁止解释、禁止小标题、禁止输出提示词内容。',
    ];
    return lines.join('\n');
  }

  /// 复读后的更强重试提示词（对应 C# 的 `retryPrompt` 分支）。
  static String buildRetryPrompt({
    required String instruction,
    required int index,
    required int total,
    required String segment,
    required bool isEnglish,
  }) {
    if (isEnglish) {
      final List<String> lines = <String>[
        'Note: your previous output was almost identical to the source. Actually apply the instruction below'
            ' and produce a substantially different text (sentence patterns, details and pacing must change).'
            ' Output the revised text only.',
        '[Instruction] $instruction',
        '[Source segment $index/$total]',
        segment,
      ];
      return lines.join('\n');
    }
    final List<String> lines = <String>[
      '注意：上一次输出与原文几乎相同。请切实执行【处理要求】对下面的片段做实质性改写，'
          '输出必须与原文明显不同（句式、细节、节奏都要调整），直接输出改写后的正文。',
      '【处理要求】$instruction',
      '【原文片段 $index/$total】',
      segment,
    ];
    return lines.join('\n');
  }

  /// 切片清洗（对应 C# `CleanSlice`）：
  /// ① 统一净化（去思维链 / 提示词残留）→ ② 去 Markdown 标题行与分隔线
  /// → ③ 去「未完待续」占位 → ④ 去客套前缀行 → ⑤ 去提示词结构行回显。
  static String cleanSlice(String? text) {
    String cleaned = AIOutputSanitizer.extractCleanOutput(text ?? '').trim();

    // ② Markdown 标题行（`## 第一章`）与独占一行的分隔线
    cleaned = cleaned
        .replaceAll(RegExp(r'^#+\s.*$', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*-{3,}\s*$', multiLine: true), '');

    // ③ 「（未完待续）」占位
    cleaned = cleaned.replaceAll(RegExp(r'[（(]?未完待续[）)]?'), '');

    // ④ 客套前缀（只在首行很短且是典型口吻时剥掉一行）
    final int firstBreak = cleaned.indexOf('\n');
    if (firstBreak > 0) {
      final String firstLine = cleaned.substring(0, firstBreak).trim();
      if (firstLine.length <= 60 &&
          RegExp(r'^(好的|当然|没问题|明白了|收到|以下是|遵照)').hasMatch(firstLine)) {
        cleaned = cleaned.substring(firstBreak + 1).trim();
      }
    }

    // ⑤ 提示词结构行回显（只剥开头的连续结构行）
    while (true) {
      final int idx = cleaned.indexOf('\n');
      if (idx <= 0) break;
      final String line = cleaned.substring(0, idx).trim();
      if (!_isStructureLine(line)) break;
      cleaned = cleaned.substring(idx + 1).trim();
    }

    return cleaned.trim();
  }

  /// 一行是否为提示词/大纲结构行（对应 C# `IsStructureLine`）。
  ///
  /// 相比 C# 多列了本工艺**自己**用到的段落标记（【处理要求】【原文片段】等）——
  /// 模型回显自家提示词时同样要清掉。
  static bool _isStructureLine(String line) {
    if (line.trim().isEmpty) return true;
    // ⚠ 不能用 C# 的 `^【(标记)】`：本工艺自己的标记带尾部内容
    // （`【原文片段 1/3】`、`【处理要求】…`），必须允许 `】` 之前有其它字符。
    if (RegExp(
            r'^【(?:全书总纲|全书大纲|本卷大纲|本章梗概|爆款工艺|本章要求|上一章结尾|已写正文结尾|处理要求|原文片段|已处理正文结尾|要求)[^】]*】')
        .hasMatch(line)) {
      return true;
    }
    if (RegExp(r'^第[0-9一二三四五六七八九十百]{1,4}章[:：·]').hasMatch(line)) {
      return true;
    }
    if (RegExp(r'^(\*+\s*|-{1,2}\s+|\d+\.\s+)').hasMatch(line) ||
        line.startsWith('**')) {
      return true;
    }
    return false;
  }
}