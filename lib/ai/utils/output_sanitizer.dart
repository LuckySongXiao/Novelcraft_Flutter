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
    content = _stripThinkingBlocks(content);
    content = _stripPolitenessPreamble(content);
    return content.trim();
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
    if (!isJsonObject && !isJsonArray) return content;

    try {
      final decoded = jsonDecode(trimmed);
      final extracted = _extractFromNode(decoded, preferredJsonKeys);
      return extracted == null || extracted.isEmpty ? content : extracted;
    } on FormatException {
      return content;
    }
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
}
