// CopilotChatLog.clear() 契约验证：清空 → 重置为单条开场白 + 持久化写入。
//
// 用假 KeyValueStore（内存 Map）注入，隔离 drift/FFI。
//
// 运行：flutter test test/copilot_chat_log_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/core/di.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';
import 'package:novelcraft/ui/state/copilot_chat_log.dart';

/// 内存假 KV：记录写入供断言，可预置历史供恢复测试。
class _FakeKv extends KeyValueStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<void> init() async {}

  @override
  Future<String?> readJson(String scope, String key) async => data['$scope/$key'];

  @override
  Future<void> writeJson(String scope, String key, String json) async =>
      data['$scope/$key'] = json;

  @override
  Future<void> remove(String scope, String key) async =>
      data.remove('$scope/$key');

  @override
  Future<List<String>> listKeys(String scope) async => data.keys
      .where((k) => k.startsWith('$scope/'))
      .map((k) => k.split('/').last)
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('clear() 重置为单条开场白并持久化', () async {
    final kv = _FakeKv();
    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWith((ref) async => kv),
    ]);
    addTearDown(container.dispose);

    final ctrl = container.read(copilotChatLogProvider.notifier);

    // 追加几条真实消息
    await ctrl.append(ChatMessage.user('第一条'));
    await ctrl.append(ChatMessage.assistant('第二条'));
    await container.pump();
    expect(container.read(copilotChatLogProvider).messages.length, 2);

    // 清空
    await ctrl.clear();
    await container.pump();

    final messages = container.read(copilotChatLogProvider).messages;
    expect(messages.length, 1, reason: '清空后应只剩一条开场白');
    expect(messages.first.role, ChatRole.system, reason: '开场白是 system 角色');

    // 持久化：KV 里写入的就是这一条开场白
    final persisted = kv.data['copilot/chat_log'];
    expect(persisted, isNotNull, reason: '清空后必须落盘（否则重启恢复旧记录）');
    expect(persisted, contains('NovelCraft'), reason: '落盘内容为开场白');
  });

  test('append 后再 clear：恢复链路一致（重启后不残留旧消息）', () async {
    final kv = _FakeKv();
    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWith((ref) async => kv),
    ]);
    addTearDown(container.dispose);

    final ctrl = container.read(copilotChatLogProvider.notifier);
    await ctrl.append(ChatMessage.user('秘密内容XYZ'));
    await ctrl.clear();

    // 新容器（模拟重启恢复）：读到的只能是开场白，不含秘密内容
    final container2 = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWith((ref) async => kv),
    ]);
    addTearDown(container2.dispose);
    // 触发恢复（Notifier 构造时 _restore 已在 build 中 unawaited 启动）
    container2.read(copilotChatLogProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await container2.pump();
    final restored = container2.read(copilotChatLogProvider).messages;
    expect(restored.any((m) => m.content.contains('秘密内容XYZ')), isFalse,
        reason: '重启后不得恢复已被清空的消息');
  });
}
