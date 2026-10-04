// 提示词模板注册表。
//
// 对应 C# 源文件 `NovelManagement.AI/Utilities/PromptTemplate.cs`。
//
// C# 侧目录结构是 `{AppContext.BaseDirectory}/PromptTemplates/{模板ID}/{语种}.txt`；
// Dart 侧等价物是打包资源 `assets/prompts/{模板ID}/{语种}.txt`（见 `pubspec.yaml`）。
// 语种规则：`en / zh`；当前语种缺失时**回退中文**，中文也缺失时返回 null（调用方走代码内置默认值）。
//
// 纯 Dart：不依赖 `package:flutter`，因此 `tool/verify_prompt_templates.dart` 可用 `dart run` 直跑。
library;

/// 已登记的模板 ID —— 与磁盘目录一一对应，允许 '/' 分层。
///
/// 对应 C# 注释里列举的模板 ID 集合；C# 是运行时按需拼路径，Dart 声明 assets 需要静态清单，
/// 所以这里显式列出（`loadPromptTemplateRegistry()` 按此清单加载）。
const List<String> kPromptTemplateIds = <String>[
  'RWKV/ChapterWriting.Instruction',
  'Prerequisite/Cultivation.System',
  'Prerequisite/Cultivation.User',
  'Workflow/MainAgent.System',
  'Workflow/SubAgentRequirement.System',
  'Workflow/SubAgentRefine.System',
  'WriterAgent/GenerateChapterContent.System',
  'WriterAgent/GenerateChapterContent.User',
  'WriterAgent/ContinueChapter.System',
];

/// 模板语种（C# 只区分 zh / en，二次开发者可追加）。
const List<String> kPromptTemplateLangs = <String>['zh', 'en'];

/// 模板资源路径 —— 对应 C# `Resolve(templateId, lang)` 的拼接结果。
String promptTemplateAssetPath(String templateId, String lang) =>
    'assets/prompts/$templateId/$lang.txt';

/// 提示词模板注册表（内存态，由 [loadPromptTemplateRegistry] 在启动后填充）。
class PromptTemplateRegistry {
  /// [files] 的 key 约定为 `模板ID/语种`。
  PromptTemplateRegistry(Map<String, String> files)
      : _files = Map<String, String>.unmodifiable(files);

  /// 空注册表：任何 `get` 都返回 null，调用方自然回退到代码内置默认值。
  const PromptTemplateRegistry.empty() : _files = const <String, String>{};

  /// 从「原始路径 → 内容」映射构建。
  ///
  /// key 允许三种写法，统一归一化为 `模板ID/语种`：
  /// `RWKV/ChapterWriting.Instruction/zh`、`RWKV/ChapterWriting.Instruction/zh.txt`、
  /// `assets/prompts/RWKV/ChapterWriting.Instruction/zh.txt`。
  factory PromptTemplateRegistry.fromRaw(Map<String, String> raw) {
    final Map<String, String> normalized = <String, String>{};
    raw.forEach((String key, String value) {
      final String path = key.replaceAll('\\', '/');
      // 末段是语种（可能带 .txt 后缀）
      final int slash = path.lastIndexOf('/');
      if (slash <= 0) return;
      String file = path.substring(slash + 1).trim();
      if (file.toLowerCase().endsWith('.txt')) {
        file = file.substring(0, file.length - 4);
      }
      final String lang = file.trim().toLowerCase();
      String id = path.substring(0, slash);
      const String assetPrefix = 'assets/prompts/';
      if (id.toLowerCase().startsWith(assetPrefix)) {
        id = id.substring(assetPrefix.length);
      }
      id = sanitizeId(id);
      if (id.isEmpty || lang.isEmpty) return;
      normalized['$id/$lang'] = value;
    });
    return PromptTemplateRegistry(normalized);
  }

  final Map<String, String> _files;

  PromptTemplateRegistry withOverrides(Map<String, String> overrides) =>
      PromptTemplateRegistry({..._files, ...overrides});

  /// 对应 C# `PromptTemplate.Get(templateId)`。
  String? get(String templateId, {required bool isEnglish}) {
    if (templateId.trim().isEmpty) return null;
    final String lang = isEnglish ? 'en' : 'zh';
    return _read(templateId, lang) ?? _read(templateId, 'zh');
  }

  /// 对应 C# `PromptTemplate.Get(templateId, language)`（显式语种，供工具/测试用）。
  String? getForLang(String templateId, String language) =>
      _read(templateId, normalizeLang(language));

  /// 对应 C# `PromptTemplate.Exists(templateId)` —— **只查当前语种**，不回退。
  bool exists(String templateId, {required bool isEnglish}) =>
      _read(templateId, isEnglish ? 'en' : 'zh') != null;

  /// 已加载的模板数量（`模板ID/语种` 条目数）。
  int get length => _files.length;

  /// 对应 C# `Resolve` 的 `templateId.Replace("..", "").TrimStart('/', '\\')`：防目录穿越。
  static String sanitizeId(String templateId) {
    var id = templateId.replaceAll('..', '');
    while (id.startsWith('/') || id.startsWith('\\')) {
      id = id.substring(1);
    }
    return id.trim();
  }

  /// 对应 C# `Normalize(language)`：按 '-' 截断取主语言码，空值回落 zh。
  static String normalizeLang(String? language) {
    if (language == null || language.trim().isEmpty) return 'zh';
    final String code = language.trim();
    final int dash = code.indexOf('-');
    return dash > 0 ? code.substring(0, dash) : code;
  }

  /// 对应 C# `Read`：**返回原文（不做 trim）**，异常/缺失一律 null。
  String? _read(String templateId, String lang) {
    final String id = sanitizeId(templateId);
    if (id.isEmpty || lang.isEmpty) return null;
    return _files['$id/$lang'];
  }
}
