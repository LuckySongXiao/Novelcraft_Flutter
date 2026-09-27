import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:novelcraft/l10n/l10n.dart';
import 'package:novelcraft/theme/app_theme.dart';
import 'package:novelcraft/ui/layout/app_shell.dart';
import 'package:novelcraft/ui/layout/navigation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 语言/主题控制器都会读本地存储，测试里给一份内存态初始值
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('应用外壳可渲染，侧边栏与状态栏就位', (tester) async {
    // 宽屏表面：侧栏展开（>=1000 逻辑宽）时才会渲染品牌字「NovelCraft」；
    // 默认 800x600 测试面会走窄屏图标栏（手机横屏适配），品牌字不渲染。
    // ⚠ binding.setSurfaceSize 在新版已失效，必须用 tester.view 显式设物理尺寸。
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // 默认页（项目管理）会真实开库，测试环境无 FFI 原生库，
        // 因此把初始目标改成「设置」占位页，只验证外壳本身
        overrides: [navigationProvider.overrideWith(_FakeNavigation.new)],
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pump();

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('NovelCraft'), findsWidgets);
  });

  testWidgets('语言切换：中 → 英', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(localeControllerProvider).languageCode, 'zh');

    await container.read(localeControllerProvider.notifier).toggle();
    expect(container.read(localeControllerProvider).languageCode, 'en');
    expect(container.read(l10nProvider).isEnglish, isTrue);
  });

  testWidgets('主题切换：黑夜 → 白昼', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(themeControllerProvider).skinId, SkinIds.dark);

    await container
        .read(themeControllerProvider.notifier)
        .selectSkin(SkinIds.light);

    final state = container.read(themeControllerProvider);
    expect(state.skinId, SkinIds.light);
    expect(state.skin(DateTime.now()).brightness, Brightness.light);
  });

  test('导航：前进与回退', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final nav = container.read(navigationProvider.notifier);
    expect(container.read(navigationProvider).target,
        NavigationTarget.projectManagement);

    nav.navigateTo(NavigationTarget.characterManagement);
    expect(container.read(navigationProvider).target,
        NavigationTarget.characterManagement);

    nav.goBack();
    expect(container.read(navigationProvider).target,
        NavigationTarget.projectManagement);
  });

  test('导航：10 个 JSON 体系都能映射到 scope', () {
    expect(SystemScopes.of(NavigationTarget.techniques), 'techniques');
    expect(SystemScopes.of(NavigationTarget.dimensions), 'dimensions');
    expect(SystemScopes.of(NavigationTarget.characterManagement), isNull);
    expect(SystemScopes.isJsonSystem(NavigationTarget.maps), isTrue);
    expect(SystemScopes.isJsonSystem(NavigationTarget.race), isFalse);
  });
}

/// 固定把初始目标设为「设置」，避免默认页触发数据库
class _FakeNavigation extends NavigationService {
  @override
  NavigationHistoryEntry build() {
    return NavigationHistoryEntry(
      NavigationTarget.settings,
      const NavigationContext(),
    );
  }
}
