import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novelcraft/ai/rwkv/g1k_model_preset.dart';
import 'package:novelcraft/core/di.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';

class _MemoryStore extends KeyValueStore {
  final Map<String, String> data = {};

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
      .where((key) => key.startsWith('$scope/'))
      .map((key) => key.substring(scope.length + 1))
      .toList();
}

void main() {
  test('family prefix resolves the full model ID at its endpoint', () {
    expect(
      resolveG1kModel(kG1kMainModelFamily, [
        'rwkv7-g1j-7.2b-20260831-ctx16384',
        'rwkv7-g1k-7.2b-20260930-ctx25600',
      ]),
      'rwkv7-g1k-7.2b-20260930-ctx25600',
    );
    expect(
      resolveG1kModel(kG1kWriterModelFamily, [
        'rwkv7-g1k-2.9b-20260930-ctx25600',
      ]),
      'rwkv7-g1k-2.9b-20260930-ctx25600',
    );
  });

  test('ambiguous or missing versions do not guess an ID', () {
    expect(
      resolveG1kModel(kG1kMainModelFamily, [
        'rwkv7-g1k-7.2b-20260930-ctx25600',
        'rwkv7-g1k-7.2b-20261001-ctx25600',
      ]),
      isNull,
    );
    expect(resolveG1kModel(kG1kMainModelFamily, []), isNull);
    expect(
      resolveG1kModel('rwkv7-g1k-7.2b-wrong', [
        'rwkv7-g1k-7.2b-20260930-ctx25600',
      ]),
      isNull,
    );
  });

  test('book preset restores independently and never edits dual-agent roles',
      () async {
    final store = _MemoryStore();
    ProviderContainer container() => ProviderContainer(overrides: [
          keyValueStoreProvider.overrideWith((ref) async => store),
        ]);
    final first = container();
    final before = first.read(dualAgentSettingsProvider);
    await first.read(g1kBookPresetProvider.notifier).update(
          const G1kBookPreset(
            mainModel: 'rwkv7-g1k-7.2b-full',
            writerModel: 'rwkv7-g1k-2.9b-full',
          ),
        );
    expect(first.read(dualAgentSettingsProvider).mainAgentModel,
        before.mainAgentModel);
    expect(first.read(dualAgentSettingsProvider).subAgentProvider,
        before.subAgentProvider);
    first.dispose();

    final second = container();
    await second.read(g1kBookPresetProvider.notifier).load();
    expect(second.read(g1kBookPresetProvider).enabled, isTrue);
    expect(second.read(g1kBookPresetProvider).writerModel,
        'rwkv7-g1k-2.9b-full');
    await second
        .read(g1kBookPresetProvider.notifier)
        .update(const G1kBookPreset());
    expect(store.data.containsKey('ai_config/book.g1k_preset'), isFalse);
    second.dispose();
  });
}
