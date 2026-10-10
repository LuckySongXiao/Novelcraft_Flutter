// 统一清理各模型返回结果中的思维链、代码围栏和常见 JSON 包装。
//
// 对应 C# 源文件 `Utilities/AIOutputSanitizer.cs`。纯字符串处理，无平台依赖。
//
// 与 C# 的差异：
// 1. 改用 `dart:convert` 的 `jsonDecode` 进行宽松 JSON 解析（字段缺失即视为无）；
// 2. 不依赖 Newtonsoft 的 `JsonElement` 递归，改为手写递归遍历 `Map` / `List`。
library;

import 'dart:convert';

/// 输出清理器。
class AIOutputSanitizer {
  static const List<String> _defaultJsonKeys = [
    'content',
    'text',
    'output',
    'answer',
    'result',
    'final_answer',
    'final',
    'message',
  ];

  /// 提取干净的可见输出。
  ///
  /// 流程：拆代码围栏 → 抽 JSON 字段 → 反转义 → 剥 `<thinking>` 块 → 剥客套前缀。
  static String extractCleanOutput(String? rawContent, [List<String>? preferredJsonKeys]) {
    if (rawContent == null || rawContent.trim().isEmpty) return '';

    var content = rawContent.trim();
    content = _tryUnwrapCodeFence(content);
    content = _tryExtractFromJson(content, preferredJsonKeys ?? const []);
    content = _unescapeCommonSequences(content);
    // 聊天模板 token 泄漏清理（须在思维链剥离前，避免模板标记干扰段落识别）：
    // rwkv-g1k 等 chat 模板模型在 state 端点偶发输出原始模板标记
    // （C# 版真机冒烟实测同款问题，见 RwkvThinkingStripper 修复）。
    content = _stripChatTemplateTokens(content);
    content = _stripThinkingBlocks(content);
    content = _stripLeadingQuoteBlock(content);
    content = _stripPolitenessPreamble(content);
    // 元话语 / 元信息抬头（「我是…主编智能体」「---润色后版本：」「【出场人物】…」）：
    // 这里可以安全生效 —— 它只吃**元信息**，绝不碰 JSON 载荷，所以设定抽取链路
    // （`AgentModuleRouter` 也用本方法）拿到的 `{"updates":[…]}` 原样保留。
    // ⚠ 对比：[stripStateUpdateBlocks] **不能**放进来，那条链路的尾部状态块
    //   里就装着抽取要用的 JSON。
    content = stripMetaPreambles(content);
    return content.trim();
  }

  /// 聊天模板 token：`<|im_start|>`（含紧随 role 名）、`<|im_end|>`、``。
  static final RegExp _chatTemplateTokenRegex = RegExp(
    r'<\|\s*im_start\s*\|>\s*(system|user|assistant|tool)?'
    r'|<\|\s*im_end\s*\|>'
    r'|<\|\s*endoftext\s*\|>',
    caseSensitive: false,
  );

  /// 模板续写形态：`<|im_end|>` 后紧跟 `<|im_start|>` —— 模型已在续写
  /// 对话模板而非正文，其后内容属于其他回合的模板文本，全部丢弃。
  /// `im_end` 后跟普通文本则不截断（保守保留，避免误伤正文）。
  static final RegExp _templateContinuationRegex = RegExp(
    r'<\|\s*im_end\s*\|>\s*<\|\s*im_start\s*\|>',
    caseSensitive: false,
  );

  static String _stripChatTemplateTokens(String content) {
    final continuation = _templateContinuationRegex.firstMatch(content);
    if (continuation != null) {
      content = content.substring(0, continuation.start);
    }
    return content.replaceAll(_chatTemplateTokenRegex, '');
  }

  /// 提取可见内容。
  ///
  /// 若可见内容为空（例如模型只输出了 reasoning），则明确返回空字符串，
  /// reasoning 绝不作为最终可见输出。
  static String extractVisibleContent(String? visibleContent, [String? reasoningContent]) {
    final sanitized = extractCleanOutput(visibleContent);
    if (sanitized.isNotEmpty) return sanitized;
    return '';
  }

  static final RegExp _codeFenceRegex =
      RegExp(r'^\s*```(?:json|text|markdown|md)?\s*([\s\S]*?)\s*```\s*$', caseSensitive: false);

  static String _tryUnwrapCodeFence(String content) {
    final match = _codeFenceRegex.firstMatch(content);
    return match == null ? content : match.group(1)!.trim();
  }

  static String _tryExtractFromJson(String content, List<String> preferredJsonKeys) {
    final trimmed = content.trim();
    final isJsonObject = trimmed.startsWith('{') && trimmed.endsWith('}');
    final isJsonArray = trimmed.startsWith('[') && trimmed.endsWith(']');
    final candidate = isJsonObject || isJsonArray
        ? trimmed
        : _findEmbeddedJson(trimmed);
    if (candidate == null) return content;

    try {
      final decoded = jsonDecode(candidate);
      final extracted = _extractFromNode(decoded, preferredJsonKeys);
      return extracted == null || extracted.isEmpty ? content : extracted;
    } on FormatException {
      return content;
    }
  }

  static String? _findEmbeddedJson(String content) {
    for (var start = 0; start < content.length; start++) {
      final opening = content[start];
      if (opening != '{' && opening != '[') continue;
      final closing = opening == '{' ? '}' : ']';
      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var i = start; i < content.length; i++) {
        final ch = content[i];
        if (escaped) {
          escaped = false;
          continue;
        }
        if (ch == '\\' && inString) {
          escaped = true;
          continue;
        }
        if (ch == '"') {
          inString = !inString;
          continue;
        }
        if (inString) continue;
        if (ch == opening) depth++;
        if (ch == closing) {
          depth--;
          if (depth == 0) {
            final candidate = content.substring(start, i + 1);
            try {
              jsonDecode(candidate);
              return candidate;
            } on FormatException {
              break;
            }
          }
        }
      }
    }
    return null;
  }

  static String? _extractFromNode(dynamic node, List<String> preferredJsonKeys) {
    if (node is String) return node;
    if (node is Map) {
      final keys = <String>{...preferredJsonKeys, ..._defaultJsonKeys};
      for (final key in keys) {
        if (!node.containsKey(key)) continue;
        final extracted = _extractFromNode(node[key], preferredJsonKeys);
        if (extracted != null && extracted.isNotEmpty) return extracted;
      }

      if (node.containsKey('choices')) {
        final choices = node['choices'];
        if (choices is List && choices.isNotEmpty) {
          final choice = choices.first;
          if (choice is Map && choice.containsKey('message')) {
            final extracted = _extractFromNode(choice['message'], preferredJsonKeys);
            if (extracted != null && extracted.isNotEmpty) return extracted;
          }
        }
      }

      if (node.containsKey('data')) {
        final extracted = _extractFromNode(node['data'], preferredJsonKeys);
        if (extracted != null && extracted.isNotEmpty) return extracted;
      }
      return null;
    }
    if (node is List) {
      for (final item in node) {
        final extracted = _extractFromNode(item, preferredJsonKeys);
        if (extracted != null && extracted.isNotEmpty) return extracted;
      }
      return null;
    }
    return null;
  }

  static String _unescapeCommonSequences(String content) =>
      content.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t').replaceAll(r'\"', '"');

  static final RegExp _thinkingRegex =
      RegExp(r'<think>[\s\S]*?</think>|<thinking>[\s\S]*?</thinking>', caseSensitive: false);

  /// **未闭合**的思考块：内容以 `<think>` / `<thinking>` 开头，但全程没有闭合标签。
  ///
  /// 实测（`/v1/batch/completions`，2026-09-15）：批量路由**不受 `think_type`
  /// 控制**（`none`/`fast`/`enable_think=false` 试过都一样），模型会**偶发**地
  /// 自发吐 `<think>好的，用户让我…`，而 `max_tokens` 一旦在"思考中"用尽，
  /// 闭合标签就永远不会出现 —— 于是整段推理会被当成正文暴露给用户。
  ///
  /// 这种形态 `_thinkingRegex` 匹配不到（它要求成对），所以必须单独处理：
  /// 一律视为「通篇都是推理」，正文为空。
  static final RegExp _unclosedThinkingRegex =
      RegExp(r'^\s*<(?:think|thinking)>[\s\S]*$', caseSensitive: false);

  static String _stripThinkingBlocks(String content) {
    final String withoutPaired = content.replaceAll(_thinkingRegex, '');
    // ⚠ 只处理**开头**的未闭合块：正文中间出现的字面 `<think>` 多半是作者内容，
    //   不能连带删掉（宁可少删，不可误删正文）。
    if (_unclosedThinkingRegex.hasMatch(withoutPaired)) return '';
    return withoutPaired;
  }

  static final RegExp _quoteLineRegex = RegExp(r'^\s*>\s?');

  /// 剥掉**开头连续**的 Markdown 引用块标记（`>`）。
  ///
  /// 实测（`rwkv7-g1j-7.2b`，2026-09-17 真机验收）：该模型在「给定原文 + 处理要求」
  /// 的提示结构下，习惯把产出当成引用 —— **改写正文与章节问答的产出首行都以 `>`
  /// 开头**（12 秒内两条用例全部复现，属系统性行为而非偶发）。不剥的话，
  /// 写进章节的正文第一行就带脏字符。
  ///
  /// 只剥「从开头起连续」的引用行：正文中间出现的 `>` 一律保留
  /// （宁可少删，不可误删正文）。
  static String _stripLeadingQuoteBlock(String content) {
    if (!_quoteLineRegex.hasMatch(content)) return content;
    final List<String> lines = content.split('\n');
    int stripped = 0;
    while (stripped < lines.length &&
        _quoteLineRegex.hasMatch(lines[stripped])) {
      lines[stripped] = lines[stripped].replaceFirst(_quoteLineRegex, '');
      stripped++;
    }
    if (stripped == 0) return content;
    return lines.join('\n').trim();
  }

  static final RegExp _politenessRegex =
      RegExp(r'^(好的|当然|没问题|明白了|收到|遵照|根据您|以下)', caseSensitive: false);

  /// 去掉小模型常见的客套前缀（如“好的，遵照您的指示，以下是……”），
  /// 仅当首行命中模式且后续仍有正文时才移除，避免误删正文。
  static String _stripPolitenessPreamble(String content) {
    final newlineIndex = content.indexOf('\n');
    final firstLine = (newlineIndex >= 0 ? content.substring(0, newlineIndex) : content).trim();
    if (firstLine.isEmpty || firstLine.length > 120) return content;

    final isPoliteness = _politenessRegex.hasMatch(firstLine);
    final mentionsDelivery =
        firstLine.contains('以下是') || firstLine.contains('为您') || firstLine.contains('遵照');

    if (!isPoliteness || !mentionsDelivery) return content;

    final remainder =
        newlineIndex >= 0 ? content.substring(newlineIndex + 1).trim() : '';
    return remainder.isEmpty ? content : remainder;
  }

  // ---------------------------------------------------------------------------
  // 参考素材 / 状态更新块的剥离（**仅用于「正文」通道，不要放进 [extractCleanOutput]**）
  // ---------------------------------------------------------------------------

  /// 状态/设定类小标题的词汇表（中文简体 + 繁体 + 常见英文）。
  ///
  /// 只有**整行**都是一个方括号小标题、且标题里命中这些词才判为非正文块 ——
  /// 宁可少删，不可误删（`【剑气纵横】` 这种正文小标题不在此列）。
  static const List<String> _stateBlockKeywords = <String>[
    '设定', '設定', '状态', '狀態', '履历', '履歷', '参考素材', '參考素材',
    '素材', '世界观', '世界觀', '人物', '角色', '更新', '变更', '變更',
    '登记', '登記', '出场', '出場', '大纲', '大綱', '提要', '摘要', '梗概',
    'state', 'updates', 'history', 'status',
  ];

  /// **整行**方括号小标题：`【设定更新】` / `[状态变更]` / `【人物履历】`。
  static final RegExp _stateHeadingLineRegex = RegExp(
    r'^[ \t]*(?:[【\[])([^】\]\n]{1,16})(?:[】\]])[ \t]*$',
    multiLine: true,
  );

  /// 代码围栏整块（含 ```json / ``` 两种）。
  static final RegExp _codeFenceBlockRegex =
      RegExp(r'^[ \t]*```[^\n]*\n[\s\S]*?^[ \t]*```[ \t]*$', multiLine: true);

  /// 行首的 `设定更新：` / `状态变更：` 形态（后面**不再**跟正文的整行）。
  ///
  /// 与 [_politenessRegex] 同理：只删「整行就是个标签」的行，
  /// 例如 `状态更新：叶知秋晋升金丹期` 这类**信息在同行**的写法也一并删掉 ——
  /// 因为这类行几乎不可能出现在小说正文里（正文里的人物状态是叙事，不是标签）。
  static final RegExp _stateLabelledLineRegex = RegExp(
    r'^[ \t]*(?:\*\*)?(?:设定|設定|状态|狀態|履历|履歷|参考素材|參考素材|'
    r'世界观|世界觀|人物履历|人物履歷|更新清单|更新清單|'
    r'updates?|state)\s*(?:更新|变更|變更|记录|記錄|清单|清單)?\s*[：:][^\n]*$',
    multiLine: true,
    caseSensitive: false,
  );

  /// 状态块里的**条目行**：`- 叶知秋：晋升金丹期` / `* …` / `1. …` / `· …`。
  static final RegExp _stateEntryLineRegex = RegExp(r'^[ \t]*(?:[-*·•+]|\d+[.、)])\s+\S');

  /// 水平分隔线（`---` / `***` / `___`）。
  static final RegExp _hrLineRegex = RegExp(r'^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$');

  /// 该行是否为「状态块小标题」（整行方括号 + 命中关键词）。
  static bool _isStateHeadingLine(String line) {
    final Match? m = _stateHeadingLineRegex.firstMatch(line);
    if (m == null) return false;
    final String inner = (m.group(1) ?? '').trim().toLowerCase();
    if (inner.isEmpty) return false;
    return _stateBlockKeywords.any(inner.contains);
  }

  /// 该行是否为「行首标签行」（`设定更新：…`）。
  static bool _isStateLabelledLine(String line) =>
      _stateLabelledLineRegex.hasMatch(line) &&
      _stateBlockKeywords.any(line.toLowerCase().contains);

  /// 剥掉**贴在正文末尾**的整块状态更新（小标题 + 其下的条目行）。
  ///
  /// 为什么单靠「逐行删标题」不够（用户实测的 BUG 形态）：G1K 串行写书时模型
  /// 常常在正文后补一整个**区块**，而不是一行：
  ///
  ///     …正文最后一句。
  ///
  ///     【参考素材履历】
  ///     - 叶知秋：晋升金丹期，执掌青云剑
  ///     - 林雪：被逐出师门
  ///     【世界观更新】
  ///     - 青云门：新增禁地「寒潭」
  ///
  /// 只删 `【…】` 标题行，那几条 `- 角色：…` 条目会**原样留在正文里**被读成小说。
  /// 所以这里按「块」处理。
  ///
  /// 保险，宁可少删不可误删：
  ///  1. 必须存在**锚点行**（命中关键词的小标题 / 标签行），取**最后一个**；
  ///  2. 锚点之后的**每一行**都必须是状态块形态（空行 / 条目行 / 分隔线 /
  ///     另一个锚点）—— 只要锚点后面还跟着一句正常散文，就整块放弃，
  ///     这样「正文中间恰好出现一个【设定】标题」不会被误伤；
  ///  3. 整篇都是状态块（无正文可留）→ 返回空串，让质量闸按「无产出」处理，
  ///     而不是把一块状态登记当成章节正文存下去。
  static String _stripTrailingStateBlock(String content) {
    final List<String> lines = content.split('\n');
    if (lines.length < 2) return content;

    bool stateLike(String line) {
      final String t = line.trim();
      if (t.isEmpty) return true;
      if (_hrLineRegex.hasMatch(line)) return true;
      if (_isStateHeadingLine(line) || _isStateLabelledLine(line)) return true;
      return _stateEntryLineRegex.hasMatch(line);
    }

    // 1) 找**最后一个**锚点行。
    int anchor = -1;
    for (int i = lines.length - 1; i >= 0; i--) {
      if (_isStateHeadingLine(lines[i]) || _isStateLabelledLine(lines[i])) {
        anchor = i;
        break;
      }
    }
    if (anchor < 0) return content;

    // 2) 锚点之后必须全是状态块形态。
    for (int i = anchor + 1; i < lines.length; i++) {
      if (!stateLike(lines[i])) return content;
    }

    // 3) 向上吸收紧邻的空行与条目行（块首可能有前置条目）。
    int start = anchor;
    while (start > 0) {
      final String prev = lines[start - 1];
      if (prev.trim().isEmpty || _stateEntryLineRegex.hasMatch(prev)) {
        start--;
        continue;
      }
      break;
    }
    // 4) 全篇都是状态块 → 没有正文可留，返回空串（质量闸会按「无产出」处理，
    //    不会把一块状态登记当章节正文存下去）。
    if (start == 0) return '';

    return lines.sublist(0, start).join('\n');
  }

  /// 剥掉模型在正文之后**额外**补的「参考素材 / 状态更新」块。
  ///
  /// 为什么需要（RWKV 家族实测，G1K 串行写书尤其明显）：模型交出正文后，
  /// 常会继续按「线性状态更新参考素材履历」的隐含约定，补一段**供上游登记用**
  /// 的文本，常见三种形态：
  ///
  ///   1. ```json 围栏或裸 JSON —— `{"updates":[{"target":"character",…}]}`；
  ///   2. 中文小标题块 —— `【设定更新】` / `【状态变更】` / `【人物履历】` 等；
  ///   3. 行首标签行 —— `设定更新：……` / `状态：……`。
  ///
  /// 这些都不是正文，写进章节里会被当成小说读出来（用户实测 BUG）。
  ///
  /// ⚠ **不要**把它并进 [extractCleanOutput]：设定抽取链路
  /// （`ModuleStateService` / `AgentModuleRouter`）正是要拿那个 `updates`
  /// JSON，提前剥掉会让抽取全部落空。它只属于「产出正文」的通道。
  static String stripStateUpdateBlocks(String? rawContent) {
    if (rawContent == null || rawContent.trim().isEmpty) return '';
    String content = rawContent;

    // 1) 围栏代码块（正文里不可能出现整段代码围栏）。
    content = content.replaceAll(_codeFenceBlockRegex, '');

    // 2) 裸 JSON（含 `updates` 键）—— 逐个平衡对象尝试解析，命中即整段移除。
    content = _stripEmbeddedStateJson(content);

    // 3) **贴在末尾的整块**（小标题 + 其下条目行）—— 必须排在「逐行删」之前：
    //    一旦小标题先被删掉，剩下的 `- 角色：…` 条目就再没有锚点可认，
    //    会永远留在正文里（这正是用户实测的 BUG 形态）。
    content = _stripTrailingStateBlock(content);

    // 4) 兜底：正文**中间**零散出现的整行小标题 / 行首标签行。
    content = content.replaceAllMapped(_stateHeadingLineRegex, (Match m) {
      final String inner = (m.group(1) ?? '').trim().toLowerCase();
      if (inner.isEmpty) return m.group(0)!;
      final bool isState = _stateBlockKeywords.any(inner.contains);
      return isState ? '' : m.group(0)!;
    });
    content = content.replaceAllMapped(_stateLabelledLineRegex, (Match m) {
      final String line = m.group(0) ?? '';
      final String lower = line.toLowerCase();
      final bool isState = _stateBlockKeywords.any(lower.contains);
      return isState ? '' : line;
    });

    // 5) 收尾：折叠被掏空后留下的多余空行与分隔线残渣。
    content = content
        .replaceAll(RegExp(r'\n[ \t]*-{3,}[ \t]*(?=\n|$)'), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return content.trim();
  }

  /// 移除文本中「可解析为 JSON 对象且含 `updates` 键」的平衡片段。
  static String _stripEmbeddedStateJson(String content) {
    final StringBuffer out = StringBuffer();
    int cursor = 0;
    int i = 0;
    while (i < content.length) {
      if (content[i] != '{') {
        i++;
        continue;
      }
      int depth = 0;
      bool inString = false;
      bool escaped = false;
      int? end;
      for (int j = i; j < content.length; j++) {
        final String ch = content[j];
        if (escaped) {
          escaped = false;
          continue;
        }
        if (ch == '\\' && inString) {
          escaped = true;
          continue;
        }
        if (ch == '"') {
          inString = !inString;
          continue;
        }
        if (inString) continue;
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) {
            end = j;
            break;
          }
        }
      }
      if (end == null) break;
      final String candidate = content.substring(i, end + 1);
      bool isStateJson = false;
      try {
        final Object? decoded = jsonDecode(candidate);
        isStateJson = decoded is Map && decoded.containsKey('updates');
      } on FormatException {
        isStateJson = false;
      }
      if (!isStateJson) {
        i++;
        continue;
      }
      out.write(content.substring(cursor, i));
      cursor = end + 1;
      i = end + 1;
    }
    out.write(content.substring(cursor));
    return out.toString();
  }

  // ---------------------------------------------------------------------------
  // 正文**前**的「元话语 / 元信息抬头」剥离（用户实测 BUG 的三种真实形态）
  // ---------------------------------------------------------------------------
  //
  // G1K 串行写书 / 主编修订 / 续写优选三条链路的真机样本（2026-10-07 用户截图）：
  //
  //   ① 自我介绍 + 处理说明前缀（**混在同一段里**，正文紧随其后）：
  //      `你好，我是NovelCraft的主编智能体。我将严格保留原文中的人物对话、情节
  //       脉络与核心悬念（…），仅优化措辞、增强氛围张力与细节质感，使行文更具
  //       沉浸感与文学性。---润色后版本：“你们到底是谁？”她问道，……`
  //      → 必须切到 `---润色后版本：` **之后**，前面的都是元话语。
  //
  //   ② 修订稿抬头 + 星号字段，正文**紧跟在同一行**：
  //      `【主编修订稿】---第一章北极圈基地（正式）*目标：尤里通过乌拉尔系统……*1991年，莫斯科苏联阵营总部。……`
  //      → 必须切到 `*目标：…*` 的收尾星号之后，不能整行丢掉（会把正文一起丢掉）。
  //
  //   ③ 整行章节元信息区块（4~5 个字段挤一行）：
  //      `---【本章正式章名】《北极圈基地》【出场人物】-尤里·卡普斯京（主角）……
  //       【场景与时间线】……【关键冲突与转折】……【章末钩子】……为第二卷奠定基础。`
  //      → 这种行里【章末钩子】后面还跟着**元信息散文**，所以不能「切到最后一个字段」，
  //        必须**整行丢弃**（真正的正文在下一段）。
  //
  // 三条形态的处理顺序因此是：先判「整行元信息」（③）→ 再判「整行元话语」（①无标记时）
  // → 最后做「行内标记切前缀」（①②）。
  //
  // ⚠ 与 [stripStateUpdateBlocks] 的分工：那张表管**尾部**状态块（`{"updates":[…]}` /
  // `【设定更新】`），这张表管**前部**元信息抬头。两者都**不是**给设定抽取链路用的 ——
  // 但本表可以安全并进 [extractCleanOutput]（它不碰任何 JSON 载荷）。

  /// 元信息抬头类小标题的词汇表（= 章节元数据 + 修订稿抬头 + 状态块词表的并集）。
  ///
  /// 只用于「整行就是这个小标题」或「一行里塞了 ≥2 个这类小标题」两种判据，
  /// 所以可以放宽收录 —— 小说正文里不会有一整行恰好是 `【出场人物】`。
  static const List<String> _metaHeadingKeywords = <String>[
    // ① 章节元数据
    '章名', '章節名', '章节标题', '章節標題',
    '出场人物', '登場人物', '人物表', '人物设定', '人物設定', '人物简介', '人物簡介',
    '场景与时间', '場景與時間', '场景', '場景', '时间线', '時間線', '地点', '地點',
    '关键冲突', '關鍵衝突', '冲突', '衝突', '转折', '轉折',
    '章末钩子', '章末鉤子', '钩子', '鉤子', '伏笔', '伏筆', '悬念', '懸念',
    '字数', '字數', '目标', '目標', '主题', '主題', '本章', '本節',
    '大纲', '大綱', '摘要', '提要', '梗概',
    // ② 修订 / 校订抬头
    '修订稿', '修訂稿', '修订', '修訂', '主编', '主編', '校对', '校對', '版本',
    '润色', '潤色', '说明', '說明', '备注', '備註', '正文',
    // ③ 状态块词表（前部出现时同样按元信息丢弃）
    '设定', '設定', '状态', '狀態', '履历', '履歷', '参考素材', '參考素材',
    '素材', '世界观', '世界觀', '人物', '角色', '更新', '变更', '變更',
    '登记', '登記', 'updates', 'state',
    // ④ 续写衔接标记（用户实测 BUG：`【上文结尾】` 会被模型连同被回灌的
    //    上文原文一起吐进正文 —— 见 [_echoBackLineRegex] 的完整说明）。
    //    这里放**多字**关键词，避免「结尾」「上文」这类短词误伤正文。
    '上文结尾', '前文结尾', '上文末尾', '前文末尾', '前文末尾段',
    '上文内容', '前文内容', '接上文', '续写衔接',
  ];

  /// 行内任意位置的方括号小标题（`【出场人物】` / `[场景与时间线]`）。
  static final RegExp _anyBracketHeadingRegex = RegExp(r'[【\[]([^】\]\n]{1,18})[】\]]');

  /// 行内的**元信息分界标记**：命中即把「行首 → 标记收尾」之间的元话语整段切掉。
  ///
  /// 两种形态：带 `---` 前缀时冒号可省（`---润色后版本：`）；不带前缀则**必须**有冒号，
  /// 否则「润色后」三个字出现在普通文本里就会被误切。
  static final RegExp _metaInlineMarkerRegex = RegExp(
    r'-{2,}\s*(?:润色后版本|润色後版本|润色后|润色版|修订后版本|修訂後版本|修改后版本|'
    r'修改後版本|修订版|正式版|正文如下|以下是正文|以下為正文|以下是修改后)'
    r'|(?:润色后版本|润色後版本|润色后|润色版|修订后版本|修訂後版本|修改后版本|修改後版本|'
    r'修订版|正文如下|以下是正文|以下為正文)\s*[：:]'
    // 行内的续写标记（`…上文结尾是：「…」`）—— 行首形态由 [_echoBackLineRegex]
    // 整行丢弃，这里只负责「夹在行中间」的情况，必须带冒号才切。
    r'|(?:上文|前文)\s*(?:的)?\s*(?:结尾|末尾)\s*(?:是|为)?\s*[：:]',
  );

  /// `*目标：……*` 这类被星号包住的元信息字段（主编 / 修订稿抬头最常见）。
  static final RegExp _metaStarredFieldRegex = RegExp(
    r'\*\s*[^*\n]{0,80}?(?:目标|目標|主题|主題|字数|字數|章名|概要|摘要)[^*\n]{0,600}?\*',
  );

  /// 名单条目：`- 尤里·卡普斯京（主角）`。
  static final RegExp _rosterBulletRegex = RegExp(
    r'^[-*·•+]\s*\S{1,24}\s*[（(](?:主角|配角|女主|男主|反派|同伴|对象|對象|'
    r'间谍|間諜|系统|系統|智能体|智能體|NPC)[^）)]{0,14}[）)]',
  );

  /// AI 自我身份宣言：`你好，我是NovelCraft的主编智能体。`
  ///
  /// 必须同时命中「我是……」与「智能体 / 助手 / 主编 / 编辑」，
  /// 小说里的 `我是叶知秋。` 不会命中。
  static final RegExp _authorSelfIntroRegex = RegExp(
    r'^(?:你好[，,、]?\s*)?我是[^。！？!?\n]{0,40}?'
    r'(?:智能体|智能體|助手|AI|模型|主编|主編|编辑|編輯|写作助理|寫作助理)',
  );

  /// 处理说明句：`我将严格保留原文……仅优化措辞……`。
  ///
  /// 必须「动作词 + 对象词」同时命中（`我将` + `原文 / 正文 / 措辞 / 行文 / 文学性`），
  /// 否则小说里 `我会保留这份记忆。` 这类正常句子会被误删。
  static final RegExp _authorProcessSentenceRegex = RegExp(
    r'^(?:我将|我會|我会|已经|已經|下面|以下|接下来|接下來|本次)'
    r'[^。！？!?\n]{0,120}?(?:原文|正文|措辞|措辭|行文|文学性|文學性|润色|潤色|修订稿|修訂稿)',
  );

  /// 元信息标签句：`字数统计：1234` / `说明：……`。
  static final RegExp _metaLabelSentenceRegex = RegExp(
    r'^(?:润色说明|润色說明|修改说明|修改說明|修订说明|修訂說明|'
    r'字数统计|字數統計|本章摘要|本章提要|说明|說明|备注|備註)\s*[：:]',
  );

  /// 续写衔接标记的**整行**形态（用户实测 BUG，2026-10-09）。
  ///
  /// 分段续写 / 续写优选的提示词里带着「上文尾部」原文，模型经常先把标记连同
  /// 这段原文一起复述一遍再往下写，于是章节正文里出现：
  ///
  ///     …那个笑容比刚才还冷一度：
  ///
  ///     【上文结尾】她笑了。那个笑容比刚才还冷一度：薇拉。两个字像钉子…
  ///
  /// 以及另一种变体（同章后段）：
  ///
  ///     上文结尾是："不要写，不要说，不要想，我会选择你的父亲。"她感到…
  ///
  /// 这两行**整行都是元信息 + 被回灌的上文**，不是新正文，必须整行丢弃
  /// （只切前缀会把复述的上文留在正文里）。判据刻意收紧到「上文/前文」+「结尾/
  /// 末尾/最后一段」相邻出现 —— 小说正文里不会出现这种搭配。
  static final RegExp _echoBackLineRegex = RegExp(
    r'^[ \t]*(?:[-*·•+>]\s*)?(?:[【\[])?\s*'
    r'(?:上文|前文|上文内容|前文内容)\s*(?:的)?\s*'
    r'(?:结尾|末尾|最后一段|收尾)',
  );

  /// 该行是否为「续写标记 + 回灌上文」的整行残留。
  static bool _isEchoBackLine(String line) =>
      _echoBackLineRegex.hasMatch(line);

  /// 剥掉**正文之前**的元话语 / 元信息抬头（三种真实形态见本节顶部注释）。
  ///
  /// 与 [stripStateUpdateBlocks] 一样是「宁可少删不可误删」的保守实现：
  /// 每条判据都要求**结构性证据**（成对括号 / 字面标记 / 动作+对象双命中）。
  static String stripMetaPreambles(String? rawContent) {
    if (rawContent == null || rawContent.trim().isEmpty) return '';
    final List<String> kept = <String>[];
    for (final String line in rawContent.split('\n')) {
      // ⓪ 续写衔接标记整行（`【上文结尾】…` / `上文结尾是：…`）—— 最先判，
      //    因为这类行往往同时命中后面的「整行元信息」判据，但它们的特征
      //    （带被回灌的上文）更明确。
      if (_isEchoBackLine(line)) continue;
      // ① 整行元信息（一行塞了 ≥2 个元信息小标题，或整行就是一个小标题）。
      if (_isMetaDominatedLine(line)) continue;
      // ② 整行都是元话语句子（`你好，我是……智能体。我将严格保留原文……`）。
      if (_isPureMetaLine(line)) continue;
      // ③ 行内标记：把「行首 → 标记收尾」之间的元话语切掉。
      kept.add(_cutInlineMetaPrefix(line));
    }
    // ④ 开头残留的纯元信息行（名单条目 / 分隔线 / 小标题）。
    return _stripLeadingMetaRegion(kept.join('\n')).trim();
  }

  /// 判「整行都是元信息」时允许的最大行长。
  ///
  /// 安全阀：形态 ③（章名 / 出场人物 / 场景时间线 / 关键冲突 / 章末钩子挤一行）
  /// 实测在 200~600 字之间；而**一章正文无论如何都 ≥ `minFinalWords`（3200 字）**。
  /// 没有这道闸时，「一行塞了 ≥2 个元信息小标题」的判据会被**单行长文**满足 ——
  /// 只要章节正文里恰好出现两个 `【人物】`/`【本章】` 之类的方括号小标题，
  /// 整章会被当元信息整行丢掉（模型偶发不换行输出时后果尤其严重）。
  /// 800 字既覆盖真实抬头，又远小于任何一章正文。
  static const int _kMaxMetaLineChars = 800;

  static bool _isMetaDominatedLine(String line) {
    if (line.trim().isEmpty) return false;
    final List<String> heads = _metaHeadingsIn(line);
    if (heads.isEmpty) return false;
    // 整行就是一个方括号小标题 → 元信息行。
    if (_stateHeadingLineRegex.hasMatch(line)) return true;
    // 一行里塞了 ≥2 个元信息字段 → 结构化抬头，整行丢弃。
    // （形态 ③：一行里【章名】【出场人物】【场景与时间线】【关键冲突】【章末钩子】
    //   全挤在一起，字段后面还跟着元信息散文，所以只能整行丢。）
    // ⚠ 但必须加长度上限 —— 见 [_kMaxMetaLineChars]。
    return heads.length >= 2 && line.length <= _kMaxMetaLineChars;
  }

  static List<String> _metaHeadingsIn(String line) {
    final List<String> out = <String>[];
    for (final Match m in _anyBracketHeadingRegex.allMatches(line)) {
      final String inner = (m.group(1) ?? '').trim().toLowerCase();
      if (inner.isEmpty) continue;
      if (_metaHeadingKeywords.any(inner.contains)) out.add(inner);
    }
    return out;
  }

  static bool _isPureMetaLine(String line) {
    if (line.trim().isEmpty) return false;
    final List<String> sentences = _splitSentences(line.trim());
    if (sentences.isEmpty) return false;
    return sentences.every(_looksMetaSentence);
  }

  static bool _looksMetaSentence(String sentence) {
    final String s = sentence.trim();
    if (s.isEmpty) return true;
    return _authorSelfIntroRegex.hasMatch(s) ||
        _authorProcessSentenceRegex.hasMatch(s) ||
        _metaLabelSentenceRegex.hasMatch(s);
  }

  /// 按中文/英文句末标点切句（不用 lookbehind —— Dart 的 RegExp 不保证支持）。
  static List<String> _splitSentences(String text) {
    final List<String> out = <String>[];
    final StringBuffer buf = StringBuffer();
    for (final int rune in text.runes) {
      final String ch = String.fromCharCode(rune);
      buf.write(ch);
      if (ch == '。' || ch == '！' || ch == '？' || ch == '!' || ch == '?') {
        out.add(buf.toString());
        buf.clear();
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// 把「行首 → 行内最后一个元信息标记」之间的元话语切掉（保留标记之后的内容）。
  static String _cutInlineMetaPrefix(String line) {
    if (line.trim().isEmpty) return line;
    int cut = 0;
    for (final RegExp re in <RegExp>[
      _metaStarredFieldRegex,
      _metaInlineMarkerRegex,
    ]) {
      for (final Match m in re.allMatches(line)) {
        if (m.end > cut) cut = m.end;
      }
    }
    if (cut <= 0) return line;
    // 切点之后紧跟的装饰字符（星号 / 破折号 / 空白 / 冒号）一并去掉。
    return line.substring(cut).replaceFirst(RegExp(r'^[ \t*\-—–:：]+'), '');
  }

  /// 开头连续若干行的纯元信息（小标题 / 名单条目 / 分隔线）—— 直到第一行正常正文为止。
  static String _stripLeadingMetaRegion(String content) {
    final List<String> lines = content.split('\n');
    int start = 0;
    int dropped = 0;
    while (start < lines.length) {
      final String t = lines[start].trim();
      if (t.isEmpty) {
        start++;
        continue;
      }
      if (_hrLineRegex.hasMatch(t) ||
          _isMetaDominatedLine(lines[start]) ||
          _rosterBulletRegex.hasMatch(t)) {
        start++;
        dropped++;
        continue;
      }
      break;
    }
    if (dropped == 0) return content;
    final String rest = lines.sublist(start).join('\n').trim();
    // 整篇都被吃光 → 保守放弃（交给质量闸判「无产出」）。
    return rest.isEmpty ? content : rest;
  }
}
