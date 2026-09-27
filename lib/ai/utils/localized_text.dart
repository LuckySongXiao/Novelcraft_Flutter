// AI 层取词接口。
//
// 对应 C# 的 `Localization/LocalizationManager`（`T` / `TF` / `IsEnglish`）。
//
// 为什么用接口而不是直接 import `lib/l10n/l10n.dart`：
// `lib/ai/**` 必须保持纯 Dart（`tool/verify_*.dart` 靠 `dart run` 直跑，不启动 Flutter 运行时），
// 而 `l10n.dart` 依赖 `package:flutter/widgets.dart`。桥接实现放在 `lib/core/l10n_text_source.dart`。
//
// 注意 `isEnglish` 是**功能性开关**而非纯展示开关：它同时决定
// ① 提示词模板取 `en.txt` 还是 `zh.txt`；② 生成内容的目标语种。
library;

/// AI 层取词接口。
abstract class AiTextSource {
  /// 对应 C# `LocalizationManager.T(key, fallback)`。
  String t(String key, String fallback);

  /// 对应 C# `LocalizationManager.TF(key, fallback, args)`（`{0}` 位置占位符）。
  String tf(String key, String fallback, List<Object> args);

  /// 对应 C# `LocalizationManager.IsEnglish`。
  bool get isEnglish;
}

/// 纯 Dart 的固定语种实现 —— 供 `tool/verify_*.dart` 等无 Flutter 场景使用。
class StaticTextSource implements AiTextSource {
  const StaticTextSource({this.isEnglish = false, this.overrides = const {}});

  @override
  final bool isEnglish;

  /// 覆盖某些 key 的返回（测试用）；未命中则返回 fallback 本身。
  final Map<String, String> overrides;

  @override
  String t(String key, String fallback) => overrides[key] ?? fallback;

  @override
  String tf(String key, String fallback, List<Object> args) {
    var text = t(key, fallback);
    for (var i = 0; i < args.length; i++) {
      text = text.replaceAll('{$i}', args[i].toString());
    }
    return text;
  }
}