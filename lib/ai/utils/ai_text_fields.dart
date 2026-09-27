// AI 输出字段解析原语。
//
// 对应 C# `NovelManagement.AI/Utilities/AiAutoFillFormatter.cs`（其中的解析部分）+
// `PrerequisiteGenerationService.ParseCultivationSystemSectionAsync` 的解析逻辑。
//
// 为什么单独成文件：这是**纯字符串处理**，不含任何领域/存储依赖 ⇒ `dart run tool/verify_ai_text_fields.dart`
// 可直接验证（而 `PrerequisiteGenerationService` 依赖 drift，无法脚本直跑）。
//
//  两个必须记住的坑：
// 1. **必须在"未清洗的原始文本"上解析**：`AIOutputSanitizer` 与格式化清洗会剥掉行首
//    「N.」编号，而等级块切分完全依赖编号行。
// 2. C# 用 `(?m)` 内联多行标志，Dart 的 `RegExp` 不支持 → 改用 `multiLine: true`。
library;

/// 解析出的一个等级。
class ParsedCultivationLevel {
  const ParsedCultivationLevel({
    required this.name,
    this.description,
    this.breakthrough,
    this.abilities,
  });

  final String name;
  final String? description;
  final String? breakthrough;
  final String? abilities;
}

/// 解析出的【修炼体系】板块。
class ParsedCultivationSection {
  const ParsedCultivationSection({
    required this.name,
    required this.type,
    this.method,
    required this.levels,
  });

  final String name;
  final String type;
  final String? method;
  final List<ParsedCultivationLevel> levels;

  /// 与 C# 一致的有效性判定：**体系名为空 或 等级数 < 2 视为失败**。
  bool get isValid => name.isNotEmpty && levels.length >= 2;
}

/// 字段解析原语集合。
abstract final class AiTextFields {
  /// 字段名候选（中文标签 + 英文标签），与 C# 调用处逐字对齐。
  static const List<String> systemNameHeadings = <String>[
    '体系名称',
    '体系名',
    '名称',
    'System Name',
    'System',
    'Name',
  ];
  static const List<String> systemTypeHeadings = <String>[
    '体系类型',
    '类型',
    'System Type',
    'Type',
  ];
  static const List<String> methodHeadings = <String>[
    '修炼方法',
    '修炼方式',
    '核心理念',
    'Cultivation Method',
    'Method',
    'Core Concept',
  ];
  static const List<String> levelNameHeadings = <String>[
    '等级名',
    '等级',
    '境界',
    '名称',
    'Rank Name',
    'Rank',
    'Level',
    'Realm',
    'Name',
  ];
  static const List<String> descriptionHeadings = <String>['描述', '简介'];
  static const List<String> breakthroughHeadings = <String>[
    '突破条件',
    '突破',
    'Breakthrough Condition',
    'Breakthrough',
  ];
  static const List<String> abilitiesHeadings = <String>[
    '能力特点',
    '能力',
    'Ability Features',
    'Abilities',
  ];

  /// 解析【修炼体系】板块（C# `ParseCultivationSystemSectionAsync` 的解析部分）。
  static ParsedCultivationSection parseCultivationSection(
    String section, {
    required bool isEnglish,
  }) {
    // 按第一个「独立编号行」切 header / levels
    final RegExp numberedLine = RegExp(r'^\s*\d+[.)、]?\s*$', multiLine: true);
    final RegExpMatch? firstNumbered = numberedLine.firstMatch(section);
    final String header =
        firstNumbered == null ? section : section.substring(0, firstNumbered.start);
    final String levelsPart =
        firstNumbered == null ? section : section.substring(firstNumbered.start);

    // 兜底路径必须校验字段前缀，否则缺字段时会拿整段首行当值（C# 同款防护）
    final String? fallbackName = extractSingleLineValue(
      header,
      <String>['体系名称', '名称', 'System Name', 'Name'],
    );
    final String name = limitLength(
      firstNonEmpty(<String?>[
        extractSection(header, systemNameHeadings),
        hasFieldPrefix(
          fallbackName,
          <String>['体系名称', '名称', 'System Name', 'Name'],
        )
            ? fallbackName
            : null,
      ]),
      100,
    );
    final String type = limitLength(
      firstNonEmpty(<String?>[
        extractSection(header, systemTypeHeadings),
        isEnglish ? 'General' : '通用',
      ]),
      50,
    );
    final String? method = nullIfEmpty(extractSection(header, methodHeadings));

    final List<ParsedCultivationLevel> levels = <ParsedCultivationLevel>[];
    for (final String block in splitNumberedLevelBlocks(levelsPart)) {
      final String levelName =
          limitLength(firstNonEmpty(<String?>[
            extractSection(block, levelNameHeadings),
          ]), 100);
      if (levelName.isEmpty) continue;
      levels.add(ParsedCultivationLevel(
        name: levelName,
        description: nullIfEmpty(extractSection(block, descriptionHeadings)),
        breakthrough: nullIfEmpty(extractSection(block, breakthroughHeadings)),
        abilities: nullIfEmpty(extractSection(block, abilitiesHeadings)),
      ));
    }

    return ParsedCultivationSection(
      name: name,
      type: type,
      method: method,
      levels: levels,
    );
  }

  /// 在**未清洗的原始文本**上按「N.」编号行拆分等级块 —— 对应 C# `SplitNumberedLevelBlocks`。
  ///
  /// 规则（照抄 C#）：空行跳过；`N.` / `N)` / `N、` 单独成行为块分隔；
  /// `N. 内容` 行内编号则开启新块并把内容作为首行；其余行追加到当前块。
  static List<String> splitNumberedLevelBlocks(String? section) {
    final List<String> blocks = <String>[];
    if (section == null || section.trim().isEmpty) return blocks;

    final RegExp numberedOnly = RegExp(r'^\d+[.)、]?\s*$');
    final RegExp numberedContent = RegExp(r'^\d+[.)、]\s*(.+)$');
    List<String>? current;

    for (final String rawLine in section.replaceAll('\r\n', '\n').split('\n')) {
      final String line = rawLine.trim();
      if (line.isEmpty) continue;

      if (numberedOnly.hasMatch(line)) {
        if (current != null && current.isNotEmpty) blocks.add(current.join('\n'));
        current = <String>[];
        continue;
      }

      final RegExpMatch? m = numberedContent.firstMatch(line);
      if (m != null) {
        if (current != null && current.isNotEmpty) blocks.add(current.join('\n'));
        current = <String>[(m.group(1) ?? '').trim()];
        continue;
      }

      current ??= <String>[];
      current.add(line);
    }

    if (current != null && current.isNotEmpty) blocks.add(current.join('\n'));
    return blocks;
  }

  /// 对应 C# `AiAutoFillFormatter.ExtractSection`。
  ///
  /// 逐行匹配 `{heading}：/：` `【{heading}】` `{heading} ` `{heading}\t` 或整行等于 heading；
  /// 命中后取同行内联值并向下收集，遇空行（已收集到内容时）或下一个标题即停。
  static String? extractSection(String? raw, List<String> headings) {
    if (raw == null || raw.trim().isEmpty) return null;
    final List<String> lines = raw.replaceAll('\r\n', '\n').split('\n');

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (line.isEmpty) continue;

      for (final String heading in headings) {
        final String? inline = matchHeadingInline(line, heading);
        if (inline == null) continue;

        final List<String> collected = <String>[];
        if (inline.isNotEmpty) collected.add(inline);

        for (int j = i + 1; j < lines.length; j++) {
          final String next = lines[j].trim();
          if (next.isEmpty) {
            if (collected.isNotEmpty) break;
            continue;
          }
          if (looksLikeHeading(next) ||
              looksLikeInlineHeadingWithValue(next) ||
              matchHeadingInline(next, heading) != null) {
            break;
          }
          collected.add(next);
        }
        final String joined = collected.join('\n').trim();
        return joined.isEmpty ? null : joined;
      }
    }
    return null;
  }

  /// 命中返回内联值（可能为空串 = 标题行无值）；未命中返回 null。
  static String? matchHeadingInline(String line, String heading) {
    final String trimmed = line.trim();
    final String bare =
        trimmed.replaceAll(RegExp(r'^[【\[]|[】\]]$'), '').trim();
    if (bare == heading) return '';

    for (final String sep in <String>['：', ':']) {
      if (trimmed.startsWith('$heading$sep')) {
        return trimmed.substring(heading.length + sep.length).trim();
      }
      if (trimmed.startsWith('【$heading】$sep')) {
        return trimmed.substring(heading.length + 3 + sep.length).trim();
      }
    }
    if (trimmed.startsWith('$heading ') || trimmed.startsWith('$heading\t')) {
      return trimmed.substring(heading.length).trim();
    }
    return null;
  }

  /// 对应 C# `LooksLikeHeading`（`【X】` 或 `X：` 空值形态）。
  ///
  /// ⚠ **有意修的 C# bug**：C# 的字符类不含空格，于是英文标签
  /// （`System Name:` / `System Type:` / `Cultivation Method:`）**不被识别为标题**，
  /// 多行值收集不会在下一个字段处停下 → 体系名会被污染成
  /// `Emberforge Path\nSystem Type: …`（英文模式必现）。这里把空格并入标签字符集。
  static bool looksLikeHeading(String line) {
    if (RegExp(r'^【[^】]{1,20}】$').hasMatch(line)) return true;
    return RegExp(r'^[\u4e00-\u9fa5A-Za-z0-9_（）()\- ]{1,30}\s*[:：]\s*$')
        .hasMatch(line);
  }

  /// 对应 C# `LooksLikeInlineHeadingWithValue`（`X：值` 形态）。
  ///
  ///  同上：字符类补空格，否则英文标签形态的下一字段行不会终止收集。
  static bool looksLikeInlineHeadingWithValue(String line) => RegExp(
        r'^(?:【)?[\u4e00-\u9fa5A-Za-z0-9_（）()\- ]{1,30}(?:】)?\s*[:：]\s*\S+',
      ).hasMatch(line);

  /// 对应 C# `AiAutoFillFormatter.ExtractSingleLineValue`（先剥前缀，再取首个非空行）。
  static String? extractSingleLineValue(String? value, List<String> headings) {
    final String? cleaned = cleanFieldValue(value, headings);
    if (cleaned == null || cleaned.trim().isEmpty) return null;
    for (final String line in cleaned.replaceAll('\r\n', '\n').split('\n')) {
      final String t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  /// 对应 C# `AiAutoFillFormatter.CleanFieldValue`：循环剥掉 `{heading}:` 前缀与装饰符。
  static String? cleanFieldValue(String? value, List<String> headings) {
    if (value == null || value.trim().isEmpty) return null;
    String text = value.trim();
    bool changed = true;
    while (changed) {
      changed = false;
      for (final String h in headings) {
        final RegExp re =
            RegExp('^(?:【)?${RegExp.escape(h)}(?:】)?\\s*[:：]?\\s*');
        final String replaced = text.replaceFirst(re, '');
        if (replaced != text) {
          text = replaced;
          changed = true;
        }
      }
    }
    return text.replaceAll(RegExp(r'^[•\-\s:：【】]+'), '').trim();
  }

  /// 对应 C# `AiAutoFillFormatter.HasFieldPrefix`
  /// （校验"这值确实是该字段的值"，防止拿整段首行当值）。
  static bool hasFieldPrefix(String? value, List<String> headings) {
    if (value == null || value.trim().isEmpty) return false;
    for (final String h in headings) {
      if (RegExp('^(?:【)?${RegExp.escape(h)}(?:】)?\\s*[:：]')
          .hasMatch(value.trim())) {
        return true;
      }
    }
    return false;
  }

  static String firstNonEmpty(List<String?> values) {
    for (final String? v in values) {
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static String limitLength(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  static String? nullIfEmpty(String? value) {
    if (value == null) return null;
    final String t = value.trim();
    return t.isEmpty ? null : t;
  }
}