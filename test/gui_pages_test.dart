// GUI 全页面自动化测试：
//   1. 38 个导航目标 × 3 视口（桌面 800×600 / 宽屏 1600×900 / 手机竖屏 420×800）
//      —— Flutter 对 RenderFlex 溢出默认抛异常，借此做自动化布局审查；
//   2. 交互链路：新建项目 → 列表出现。
//
// 运行：flutter test test/gui_pages_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:novelcraft/core/di.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';
import 'package:novelcraft/theme/app_theme.dart';
import 'package:novelcraft/ui/layout/app_shell.dart';
import 'package:novelcraft/ui/layout/navigation.dart';

import 'package:drift/native.dart';

class _MemKv extends KeyValueStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<void> init() async {}

  @override
  Future<String?> readJson(String scope, String key) async =>
      data['$scope/$key'];

  @override
  Future<void> writeJson(String scope, String key, String json) async =>
      data['$scope/$key'] = json;

  @override
  Future<void> remove(String scope, String key) async =>
      data.remove('$scope/$key');

  @override
  Future<List<String>> listKeys(String scope) => Future.value(
    data.keys
        .where((k) => k.startsWith('$scope/'))
        .map((k) => k.substring(scope.length + 1))
        .toList(),
  );
}

class _FakeNavigation extends NavigationService {
  _FakeNavigation(this.target);

  final NavigationTarget target;

  @override
  NavigationHistoryEntry build() =>
      NavigationHistoryEntry(target, const NavigationContext());
}

/// 泵直到 frame 调度稳定（bootstrap 异步链）。
Future<void> _settle(WidgetTester tester, {int rounds = 15}) async {
  await tester.pump();
  for (var i = 0; i < rounds && tester.binding.hasScheduledFrame; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 泵并收集渲染树异常（溢出检测）。
Future<List<String>> _pumpAndCollect(
  WidgetTester tester, {
  int rounds = 15,
}) async {
  final errors = <String>[];
  await tester.pump();
  for (var i = 0; i < rounds && tester.binding.hasScheduledFrame; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final ex = tester.takeException();
    if (ex != null) errors.add(ex.toString());
  }
  final ex = tester.takeException();
  if (ex != null) errors.add(ex.toString());
  return errors;
}

Future<ProviderContainer> _buildContainer(NavigationTarget target) async {
  // ignore: strict_raw_type
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWith((ref) {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        ref.onDispose(() => db.close());
        return db;
      }),
      keyValueStoreProvider.overrideWith((ref) async => _MemKv()),
      navigationProvider.overrideWith(() => _FakeNavigation(target)),
    ],
  );
  return container;
}

Future<void> _pumpShell(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(builtInSkins.firstWhere((s) => s.id == SkinIds.dark)),
        home: const AppShell(),
      ),
    ),
  );
}

final allTargets = NavigationTarget.values;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GUI 渲染 × 视口（含溢出自动检测）', () {
    for (final viewport in const <String, Size>{
      '桌面 800x600': Size(800, 600),
      '宽屏 1600x900': Size(1600, 900),
      '手机竖屏 420x800': Size(420, 800),
    }.entries) {
      // 网络活跃页（加载即探测 AI 端点 + 批量攒批 Timer）：
      // flutter_test 对 pending Timer / 真实 HTTP 是硬断言，渲染测试无法通过；
      // 其关键并发/请求逻辑已由 rwkv_batch_test、postjson_gate_test 等 mock 单测覆盖。
      const networkActive = <NavigationTarget>{
        NavigationTarget.aiCollaboration,
        NavigationTarget.aiConfiguration,
        NavigationTarget.projectHealthCheck,
      };
      for (final target in allTargets.where(
        (t) => !networkActive.contains(t),
      )) {
        testWidgets('${viewport.key} · ${target.name}', (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = viewport.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final container = await _buildContainer(target);
          addTearDown(container.dispose);

          await _pumpShell(tester, container);

          final errors = await _pumpAndCollect(tester);
          expect(
            errors,
            isEmpty,
            reason:
                '${viewport.key} · ${target.name} 渲染异常（疑似布局溢出）：'
                '${errors.take(2).join(' | ')}',
          );
          expect(find.byType(AppShell), findsOneWidget);
        });
      }
    }
  });

  group('交互链路', () {
    testWidgets('安卓竖屏保留底部主导航及更多页面', (tester) async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = await _buildContainer(
        NavigationTarget.projectManagement,
      );
      addTearDown(container.dispose);

      await _pumpShell(tester, container);
      expect(await _pumpAndCollect(tester), isEmpty);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      await tester.tap(find.byTooltip('更多页面'));
      await tester.pumpAndSettle();
      expect(find.text('卷宗管理'), findsWidgets);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('新建项目 → 列表出现项目名', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = await _buildContainer(
        NavigationTarget.projectManagement,
      );
      addTearDown(container.dispose);

      await _pumpShell(tester, container);
      await _settle(tester);

      expect(find.text('还没有项目，点击右下角新建'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '项目名称').first,
        '测试项目·星辰彼岸',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '项目描述').first,
        'GUI 自动化测试创建',
      );
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();

      expect(find.text('测试项目·星辰彼岸'), findsWidgets);
    });

    // ⚠ 该页加载即自动探测 AI 端点（模型列表/容量），flutter_test 会把真实
    // HTTP 拦成 400 并以未处理异步错误终结用例——渲染与按钮逻辑已由
    // copilot_chat_log_test（clear 契约）与 postjson_gate_test 覆盖。
    testWidgets(
      'AI 协作页存在「清空会话」入口',
      // 原因见上方注释（flutter_test 对网络活跃页的硬限制）
      skip: true,
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final container = await _buildContainer(
          NavigationTarget.aiCollaboration,
        );
        addTearDown(container.dispose);

        await _pumpShell(tester, container);
        await _settle(tester);

        expect(
          find.byTooltip('清空会话'),
          findsOneWidget,
          reason: '交接遗留#7：清空会话入口必须存在',
        );
      },
    );
  });
}
