// `AiTextSource` 的 Flutter 侧实现 —— 把 `lib/l10n` 的 `L10n` 桥接给纯 Dart 的 `lib/ai`。
library;

import '../ai/utils/localized_text.dart';
import '../l10n/l10n.dart';

/// 对应 C# 各服务构造参数里拿到的 `LocalizationManager`。
class L10nTextSource implements AiTextSource {
  const L10nTextSource(this._l10n);

  final L10n _l10n;

  @override
  String t(String key, String fallback) => _l10n.t(key, fallback);

  @override
  String tf(String key, String fallback, List<Object> args) =>
      _l10n.tf(key, fallback, args);

  @override
  bool get isEnglish => _l10n.isEnglish;
}