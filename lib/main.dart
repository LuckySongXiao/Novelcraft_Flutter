import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/di.dart';
import 'l10n/l10n.dart';
import 'theme/app_theme.dart';
import 'ui/layout/app_shell.dart';

/// 应用入口
///
/// 对应 C# 的 `App.xaml.cs` + `MainWindow.xaml.cs` 启动流程：
///   C#：OnStartup → 建 Host（DI 容器）→ 初始化数据库 → 建 MainWindow
///   Dart：ensureInitialized → ProviderScope（DI）→ 等待 appBootstrapProvider（KeyValueStore + 首启动 seeding）→ AppShell
///
/// 关键差异：C# 在启动时同步做完所有初始化（包括 `DatabaseInitializer.SeedAsync`
/// 播种默认数据），Dart 侧数据库是懒加载的 —— 但首次启动需要 seed，因此通过
/// `appBootstrapProvider` 串行完成：先开 KVStore（保证 seeded-v1 标记可写），
/// 再走 DatabaseSeeder。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: NovelCraftApp()));
}

class NovelCraftApp extends ConsumerWidget {
  const NovelCraftApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeControllerProvider);
    final themeState = ref.watch(themeControllerProvider);

    // auto 皮肤按当前时间解析（C# 的 ThemeManager 同样在每次切换时读系统时间）
    final skin = themeState.skin(DateTime.now());

    final boot = ref.watch(appBootstrapProvider);
    final home = boot.when(
      loading: () => const _BootLoadingPage(),
      error: (e, _) => _BootErrorPage(error: e),
      data: (_) => const AppShell(),
    );

    return MaterialApp(
      title: 'NovelCraft',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(skin),
      locale: locale,
      supportedLocales: AppLocales.supported,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeListResolutionCallback: (systemLocales, supported) {
        if (systemLocales == null || systemLocales.isEmpty) {
          return AppLocales.zh;
        }
        for (final loc in systemLocales) {
          for (final s in supported) {
            if (s.languageCode == loc.languageCode) return s;
          }
          if (loc.languageCode == 'zh') return AppLocales.zh;
          if (loc.languageCode == 'en') return AppLocales.en;
        }
        return AppLocales.zh;
      },
      home: home,
    );
  }
}

class _BootLoadingPage extends StatelessWidget {
  const _BootLoadingPage();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'NovelCraft 正在启动...',
              style: TextStyle(color: scheme.onSurfaceVariant, letterSpacing: 1.2),
            ),
            const SizedBox(height: 4),
            Text(
              '首次启动会自动插入示例项目，便于立刻体验。',
              style: TextStyle(color: scheme.onSurfaceVariant.withAlpha(160), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _BootErrorPage extends StatelessWidget {
  const _BootErrorPage({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56, color: Colors.red),
              const SizedBox(height: 16),
              const Text('启动失败'),
              const SizedBox(height: 8),
              SelectableText(
                error.toString(),
                style: const TextStyle(color: Colors.red, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
