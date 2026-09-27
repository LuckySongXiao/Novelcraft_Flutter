import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置皮肤 ID —— 对应 C# ThemeSkins.cs
abstract final class SkinIds {
  static const light = 'light';
  static const dark = 'dark';
  static const pink = 'pink';

  /// 按时间自动切换（19:00–07:00 走黑夜），对应 C# 的 auto
  static const auto = 'auto';

  static const all = [light, dark, pink, auto];
}

/// 皮肤定义
class ThemeSkin {
  const ThemeSkin({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.brightness,
    required this.seed,
    this.isBuiltIn = true,
  });

  final String id;
  final String nameZh;
  final String nameEn;
  final Brightness brightness;
  final Color seed;

  /// 内置皮肤不可删除（对应用户自定义皮肤可删）
  final bool isBuiltIn;

  /// 按当前语言返回显示名
  String displayName(bool isEnglish) => isEnglish ? nameEn : nameZh;
}

/// 内置皮肤表
const builtInSkins = <ThemeSkin>[
  ThemeSkin(
    id: SkinIds.light,
    nameZh: '白昼',
    nameEn: 'Light',
    brightness: Brightness.light,
    seed: Color(0xFF3F51B5),
  ),
  ThemeSkin(
    id: SkinIds.dark,
    nameZh: '黑夜',
    nameEn: 'Dark',
    brightness: Brightness.dark,
    seed: Color(0xFF90CAF9),
  ),
  ThemeSkin(
    id: SkinIds.pink,
    nameZh: '花漾少女',
    nameEn: 'Pink Blossom',
    brightness: Brightness.light,
    seed: Color(0xFFF06292),
  ),
];

/// 主题状态
class ThemeState {
  const ThemeState({
    this.skinId = SkinIds.dark,
    this.autoByTime = false,
    this.darkStartHour = 19,
    this.darkEndHour = 7,
    this.customSkins = const {},
  });

  final String skinId;
  final bool autoByTime;

  /// 自动切换的起止小时（C# 侧为 19 / 7）
  final int darkStartHour;
  final int darkEndHour;

  /// 用户自定义皮肤（id → 自定义种子色）
  final Map<String, int> customSkins;

  ThemeState copyWith({
    String? skinId,
    bool? autoByTime,
    int? darkStartHour,
    int? darkEndHour,
    Map<String, int>? customSkins,
  }) {
    return ThemeState(
      skinId: skinId ?? this.skinId,
      autoByTime: autoByTime ?? this.autoByTime,
      darkStartHour: darkStartHour ?? this.darkStartHour,
      darkEndHour: darkEndHour ?? this.darkEndHour,
      customSkins: customSkins ?? this.customSkins,
    );
  }

  /// 解析出实际生效的皮肤 ID（处理 auto 时段逻辑）
  String resolveSkinId(DateTime now) {
    if (!autoByTime) return skinId;
    final h = now.hour;
    final isNight = h >= darkStartHour || h < darkEndHour;
    return isNight ? SkinIds.dark : SkinIds.light;
  }

  ThemeSkin skin(DateTime now) {
    final id = resolveSkinId(now);
    for (final s in builtInSkins) {
      if (s.id == id) return s;
    }
    // 用户自定义皮肤
    final seedValue = customSkins[id];
    if (seedValue != null) {
      return ThemeSkin(
        id: id,
        nameZh: id,
        nameEn: id,
        brightness: Brightness.light,
        seed: Color(seedValue),
        isBuiltIn: false,
      );
    }
    return builtInSkins.firstWhere(
      (s) => s.id == SkinIds.dark,
      orElse: () => builtInSkins.first,
    );
  }
}

/// 主题控制器 —— 对应 C# Services/ThemeManager.cs
class ThemeController extends Notifier<ThemeState> {
  static const _kSkin = 'theme.skin_id';
  static const _kAuto = 'theme.auto_by_time';
  static const _kStart = 'theme.dark_start_hour';
  static const _kEnd = 'theme.dark_end_hour';
  static const _kCustom = 'theme.custom_skins';

  @override
  ThemeState build() {
    _load();
    return const ThemeState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kCustom);
    final custom = <String, int>{};
    if (raw != null && raw.isNotEmpty) {
      for (final part in raw.split(';')) {
        final kv = part.split(':');
        if (kv.length == 2) {
          final v = int.tryParse(kv[1]);
          if (v != null) custom[kv[0]] = v;
        }
      }
    }
    state = ThemeState(
      skinId: prefs.getString(_kSkin) ?? SkinIds.dark,
      autoByTime: prefs.getBool(_kAuto) ?? false,
      darkStartHour: prefs.getInt(_kStart) ?? 19,
      darkEndHour: prefs.getInt(_kEnd) ?? 7,
      customSkins: custom,
    );
  }

  Future<void> _save(ThemeState s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkin, s.skinId);
    await prefs.setBool(_kAuto, s.autoByTime);
    await prefs.setInt(_kStart, s.darkStartHour);
    await prefs.setInt(_kEnd, s.darkEndHour);
    await prefs.setString(
      _kCustom,
      s.customSkins.entries.map((e) => '${e.key}:${e.value}').join(';'),
    );
  }

  Future<void> selectSkin(String id) async {
    state = state.copyWith(skinId: id);
    await _save(state);
  }

  Future<void> setAutoByTime(bool value) async {
    state = state.copyWith(autoByTime: value);
    await _save(state);
  }

  /// 保存用户自定义皮肤（C# 的 SaveCustomSkin）
  Future<void> saveCustomSkin(String id, Color seed) async {
    final next = Map<String, int>.from(state.customSkins)
      ..[id] = seed.toARGB32();
    state = state.copyWith(skinId: id, customSkins: next);
    await _save(state);
  }

  Future<void> deleteCustomSkin(String id) async {
    if (id == SkinIds.light || id == SkinIds.dark || id == SkinIds.pink) return;
    final next = Map<String, int>.from(state.customSkins)..remove(id);
    state = state.copyWith(skinId: SkinIds.dark, customSkins: next);
    await _save(state);
  }
}

final themeControllerProvider = NotifierProvider<ThemeController, ThemeState>(
  ThemeController.new,
);

/// 由主题状态生成 ThemeData
///
/// C# 版靠「运行时替换 ResourceDictionary + 24 个动态画刷」实现换肤，
/// Flutter 侧改为 Material 3 的 ColorScheme 派生，语义更清晰且无需维护 24 个键。
ThemeData buildTheme(ThemeSkin skin) {
  final scheme = ColorScheme.fromSeed(
    seedColor: skin.seed,
    brightness: skin.brightness,
  );
  final isDark = skin.brightness == Brightness.dark;
  // 安卓触控优化：桌面保持紧凑输入框（isDense + 窄内边距），
  // 移动端放宽高度 —— isDense 的输入框在触屏上难点准（操控性反馈）。
  final bool isTouchPlatform =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: skin.brightness,
    // C# 版中文用 SimSun、英文用 Segoe UI；Flutter 侧交给默认字体族
    scaffoldBackgroundColor: isDark
        ? const Color(0xFF121212)
        : const Color(0xFFFAFAFA),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 1,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
      selectedLabelTextStyle: TextStyle(color: scheme.onSurface),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: isTouchPlatform ? 14 : 10,
      ),
      isDense: !isTouchPlatform,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
      thickness: 1,
    ),
  );
}
