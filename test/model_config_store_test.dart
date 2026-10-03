// 模型配置本地持久化测试：save/loadAll/loadDefault/remove。
//
// 运行：flutter test test/model_config_store_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/providers/rwkv_cloud_provider.dart';
import 'package:novelcraft/application/services/model_config_store.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';

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
      .where((String k) => k.startsWith('$scope/'))
      .map((String k) => k.substring(scope.length + 1))
      .toList();
}

void main() {
  late _MemKv kv;
  late ModelConfigStore store;

  setUp(() {
    kv = _MemKv();
    store = ModelConfigStore(store: () async => kv);
  });

  test('save / loadAll 往返：多 provider 配置', () async {
    await store.save('deepseek', <String, Object?>{
      'baseUrl': 'https://api.deepseek.com/v1',
      'apiKey': 'sk-xxx',
      'defaultModel': 'deepseek-chat',
      'timeoutSeconds': 120,
      'defaultMaxTokens': 4000,
    });
    await store.save('ollama', <String, Object?>{
      'baseUrl': 'http://localhost:11434',
      'defaultModel': 'qwen2.5:7b',
    });

    final Map<String, Map<String, Object?>> all = await store.loadAll();
    expect(all.keys, containsAll(<String>['deepseek', 'ollama']));
    expect(all['deepseek']!['apiKey'], 'sk-xxx');
    expect(all['deepseek']!['timeoutSeconds'], 120);
  });

  test('saveDefault / loadDefault：有值与非空', () async {
    expect(await store.loadDefault(), isNull);

    await store.saveDefault('RWKV Cloud');
    expect(await store.loadDefault(), 'RWKV Cloud');

    await store.saveDefault(null);
    expect(await store.loadDefault(), isNull);
  });

  test('remove 删除单 provider，不影响其它', () async {
    await store.save('zhipu', <String, Object?>{'defaultModel': 'glm-4-flash'});
    await store.save('custom', <String, Object?>{'defaultModel': 'gpt-3.5'});
    await store.remove('zhipu');
    final Map<String, Map<String, Object?>> all = await store.loadAll();
    expect(all.keys, isNot(contains('zhipu')));
    expect(all.keys, contains('custom'));
  });

  test('rwkvCloud 配置往返：CF Access Token 不丢（云端保存/恢复回归）', () async {
    // 字段集与 ai_configuration_page._snapshotToJson 完全一致
    await store.save('rwkvCloud', <String, Object?>{
      'baseUrl': 'https://api-7b.rwkvos.com/v1',
      'apiKey': '',
      'defaultModel': 'rwkv7-g1j-7.2b-20260831-ctx16384',
      'timeoutSeconds': 180,
      'defaultTemperature': 1.0,
      'defaultMaxTokens': 16000,
      'enableStreaming': true,
      'cfAccessClientId': 'xxx.access',
      'cfAccessClientSecret': 'secret-yyy',
    });

    final Map<String, Map<String, Object?>> all = await store.loadAll();
    final Map<String, Object?> cfg = all['rwkvCloud']!;
    expect(cfg['cfAccessClientId'], 'xxx.access');
    expect(cfg['cfAccessClientSecret'], 'secret-yyy');

    // 反序列化路径（ProviderAutoRestore 恢复云端 provider 用的同一套键）
    final RwkvCloudConfiguration rc = RwkvCloudConfiguration.fromCloudMap(cfg);
    expect(rc.cfAccessClientId, 'xxx.access');
    expect(rc.cfAccessClientSecret, 'secret-yyy');
    expect(rc.hasCfCredentials, isTrue);
    expect(rc.defaultModel, 'rwkv7-g1j-7.2b-20260831-ctx16384');
    expect(rc.baseUrl, 'https://api-7b.rwkvos.com/v1');
  });

  test('损坏 JSON 不抛、不影响其它 provider', () async {
    kv.data['${ModelConfigStore.scope}/${ModelConfigStore.keyPrefix}broken'] =
        '{ not json';
    await store.save('ollama', <String, Object?>{'defaultModel': 'q'});
    final Map<String, Map<String, Object?>> all = await store.loadAll();
    expect(all.keys, contains('ollama'));
    expect(all.keys, isNot(contains('broken')));
  });
}
