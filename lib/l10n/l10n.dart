import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'strings.g.dart';

/// 支持的语言
abstract final class AppLocales {
  static const zh = Locale('zh', 'CN');
  static const en = Locale('en', 'US');

  static const supported = [zh, en];

  static Locale fromCode(String? code) {
    switch (code) {
      case 'en':
      case 'en-US':
      case 'en_US':
        return en;
      default:
        return zh;
    }
  }
}

/// 语言控制器 —— 对应 C# Localization/LocalizationManager.cs 的 SetLanguage
///
/// C# 侧切换语言时会触发 `LanguageChanged` 事件让各 View 刷新；
/// Dart 侧用 Riverpod 的 Notifier 自动驱动依赖它的 Widget 重建。
class LocaleController extends Notifier<Locale> {
  static const _k = 'localization.language';

  @override
  Locale build() {
    // 先给默认值保证首帧可渲染，再从本地存储异步恢复用户选择
    _load();
    return AppLocales.zh;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppLocales.fromCode(prefs.getString(_k));
  }

  Future<void> setLocale(Locale locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_k, locale.languageCode);
  }

  Future<void> toggle() async {
    await setLocale(
      state.languageCode == 'en' ? AppLocales.zh : AppLocales.en,
    );
  }
}

final localeControllerProvider =
    NotifierProvider<LocaleController, Locale>(LocaleController.new);

/// 本地化服务
///
/// API 与 C# 的 `LocalizationManager.T(key, fallback)` / `TF(key, fallback, args)`
/// 保持一一对应，便于对照移植。
class L10n {
  const L10n(this.locale);

  final Locale locale;

  bool get isEnglish => locale.languageCode == 'en';

  Map<String, String> get _table => isEnglish ? enStrings : zhStrings;

  /// 取一条文案。缺失时回退到 [fallback]，再缺失则返回 key 本身。
  String t(String key, [String? fallback]) {
    return _table[key] ?? fallback ?? key;
  }

  /// 带格式化参数，双模式兼容：
  /// - **位置占位符 (List)**：`tf('Key', 'fallback {0}', ['x'])`
  /// - **命名占位符 (Map)**：`tf('Key', 'fallback {name}', {'name':'x'})`
  ///
  /// C# 原版用的是 `{0}`，AIC/HC 新代码使用 `{label}` `{path}` 语义键。
  String tf(String key, String fallback, Object args) {
    var text = t(key, fallback);
    if (args is List) {
      for (var i = 0; i < args.length; i++) {
        text = text.replaceAll('{$i}', args[i].toString());
      }
    } else if (args is Map) {
      args.forEach((k, v) {
        text = text.replaceAll('{$k}', v.toString());
      });
    }
    return text;
  }

  /// 判断某个 key 是否存在（用于测试期排查漏翻）
  bool has(String key) => _table.containsKey(key);
}

final l10nProvider = Provider<L10n>(
  (ref) => L10n(ref.watch(localeControllerProvider)),
);

/// 便捷扩展：在 Widget 里用 `context.t('App.Name')`
extension L10nContextX on BuildContext {
  L10n get l10n => ProviderScope.containerOf(this).read(l10nProvider);
}
