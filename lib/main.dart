import 'dart:async';
// `AppExitResponse` 在 Flutter 3.13+ 由 `dart:ui` 定义（services.dart 不再导出它）
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai/inference/inference_launcher.dart';
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
  // 启动即回收上次异常退出遗留的本地推理进程（显存被孤儿进程长期占用是本项目的
  // 已知问题）。不阻塞首帧：没有 pid 记录文件时几乎零开销。
  unawaited(InferenceProcessLauncher.reclaimOrphaned());
  runApp(const ProviderScope(child: NovelCraftApp()));
}

class NovelCraftApp extends ConsumerStatefulWidget {
  const NovelCraftApp({super.key});

  @override
  ConsumerState<NovelCraftApp> createState() => _NovelCraftAppState();
}

class _NovelCraftAppState extends ConsumerState<NovelCraftApp> {
  /// 应用级生命周期监听：窗口关闭 / 进程分离时回收本地推理进程。
  ///
  /// 桌面端「关窗口」若走不到 Riverpod 的 dispose（例如直接结束进程），
  /// 本地 server 会变成孤儿并持续占用 GPU 显存 —— 这里按 pid 记录文件兜底。
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _reclaimLocalInference();
        return AppExitResponse.exit;
      },
      onDetach: () => unawaited(_reclaimLocalInference()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _reclaimLocalInference() async {
    try {
      await InferenceProcessLauncher.reclaimOrphaned();
    } on Object {
      // 退出路径不允许抛异常，否则会卡住关窗流程
    }
  }

  @override
  Widget build(BuildContext context) {
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
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        // 安卓：系统字体缩放常被调到 1.3+，而本应用按桌面密度设计，
        // 直接把布局挤爆（真机横屏踩坑：导航标签换行、卡片溢出、
        // 内容区控件看不全）。真机反馈 1.2 仍偏大 → 干脆钳到 1.0，
        // 完全按设计密度渲染；桌面 / Web 不干预。
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler:
                  MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.0),
            ),
            child: child,
          );
        }
        return child;
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
