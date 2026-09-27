// GUI 探针：验证「内存库 + 假 KV + 真实启动链」在测试 VM 中可跑通，
// 项目管理页真实渲染（此前 widget_test 刻意绕开了真实开库页）。
//
// 运行：flutter test test/gui_probe_test.dart
import 'package:flutter/material.dart';
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
  Future<List<String>> listKeys(String scope) async => data.keys
      .where((k) => k.startsWith('$scope/'))
      .map((k) => k.substring(scope.length + 1))
      .toList();
}

class _FakeNavigation extends NavigationService {
  _FakeNavigation(this.target);

  final NavigationTarget target;

  @override
  NavigationHistoryEntry build() =>
      NavigationHistoryEntry(target, const NavigationContext());
}

Future<ProviderContainer> _buildContainer(NavigationTarget target) async {
  // ignore: strict_raw_type
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWith((ref) {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      ref.onDispose(() => db.close());
      return db;
    }),
    keyValueStoreProvider.overrideWith((ref) async => _MemKv()),
    navigationProvider.overrideWith(() => _FakeNavigation(target)),
  ]);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('探针：启动链 + 项目管理页真实渲染（含种子数据）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container =
        await _buildContainer(NavigationTarget.projectManagement);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(builtInSkins.firstWhere(
            (s) => s.id == SkinIds.dark,
          )),
          home: const AppShell(),
        ),
      ),
    );

    // bootstrap（建表 + 种子 + 模板预热）是异步的：反复 pump 直到稳定
    await tester.pump();
    for (var i = 0; i < 12 && tester.binding.hasScheduledFrame; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(AppShell), findsOneWidget);
  });
}
