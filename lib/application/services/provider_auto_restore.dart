// 模型配置启动自动恢复 —— 读取持久化配置 → initialize 各 provider →
// 注册进 ModelManager → 恢复默认 provider。
//
// 在 appBootstrapProvider 里于 KVStore 初始化之后调用；任何单个 provider
// 恢复失败都折叠（只记日志），绝不阻塞启动。
library;

import 'package:logging/logging.dart';

import '../../ai/models/provider.dart';
import '../../ai/providers/model_manager.dart';
import '../../ai/providers/deepseek_provider.dart';
import '../../ai/providers/ollama_provider.dart';
import '../../ai/providers/openrouter_provider.dart';
import '../../ai/providers/openai_compatible_provider.dart';
import '../../ai/providers/rwkv_cloud_provider.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/providers/zhipu_provider.dart';
import '../../ai/rwkv/rwkv_engine.dart';
import '../../ai/rwkv/rwkv_official_resources.dart' show OfficialServerVariant;
import 'model_config_store.dart';

/// 启动时自动恢复已持久化的模型配置。
class ProviderAutoRestore {
  ProviderAutoRestore({
    required ModelConfigStore store,
    required ModelManager manager,
    required Map<String, IModelProvider> providers,
    Logger? logger,
  })  : _store = store,
        _manager = manager,
        _providers = providers,
        _logger = logger ?? Logger('ProviderAutoRestore');

  final ModelConfigStore _store;
  final ModelManager _manager;
  final Map<String, IModelProvider> _providers;
  final Logger _logger;

  /// 恢复全部已持久化 provider；返回成功恢复的个数。
  Future<int> restore() async {
    final Map<String, Map<String, Object?>> all;
    try {
      all = await _store.loadAll();
    } on Object catch (e) {
      _logger.warning('读取持久化模型配置失败：$e');
      return 0;
    }
    int restored = 0;
    for (final MapEntry<String, Map<String, Object?>> entry in all.entries) {
      final IModelProvider? prov = _providers[entry.key];
      if (prov == null) continue;
      final IModelConfiguration? cfg = _buildConfig(entry.key, entry.value);
      if (cfg == null) continue;
      try {
        await prov.initialize(cfg);
        if (_manager.getProvider(prov.providerName) == null) {
          _manager.registerProvider(prov);
        }
        restored++;
      } on Object catch (e) {
        _logger.warning('恢复 provider「${entry.key}」失败：$e');
      }
    }
    final String? def = await _store.loadDefault();
    if (def != null && def.isNotEmpty) {
      try {
        if (_manager.getProvider(def) != null) {
          _manager.setDefaultProvider(def);
        }
      } on Object catch (e) {
        _logger.warning('恢复默认 provider 失败：$e');
      }
    }
    if (restored > 0) {
      _logger.info('已自动恢复 $restored 个模型配置'
          '${def == null ? '' : '，默认=$def'}');
    }
    return restored;
  }

  // -----------------------------------------------------------------------
  // 反序列化：字段与 ai_configuration_page 的 _ProviderConfig 对齐
  // -----------------------------------------------------------------------

  IModelConfiguration? _buildConfig(String kind, Map<String, Object?> j) {
    String s(String k, String d) => (j[k] as String?) ?? d;
    int i(String k, int d) => (j[k] as num?)?.toInt() ?? d;
    double f(String k, double d) => (j[k] as num?)?.toDouble() ?? d;
    bool b(String k, bool d) => (j[k] as bool?) ?? d;

    switch (kind) {
      case 'deepseek':
        return DeepSeekConfiguration(
          apiKey: s('apiKey', ''),
          defaultModel: s('defaultModel', 'deepseek-chat'),
          baseUrl: s('baseUrl', 'https://api.deepseek.com/v1'),
          timeoutSeconds: i('timeoutSeconds', 120),
          defaultMaxTokens: i('defaultMaxTokens', 4000),
        );
      case 'zhipu':
        return ZhipuConfiguration(
          apiKey: s('apiKey', ''),
          defaultModel: s('defaultModel', 'glm-4-flash'),
          baseUrl: s('baseUrl', 'https://open.bigmodel.cn/api/paas/v4'),
          defaultMaxTokens: i('defaultMaxTokens', 4000),
        );
      case 'openrouter':
        // OpenRouter（OpenAI 兼容）：baseUrl 必须带 `/api/v1`。
        return OpenRouterConfiguration(
          apiKey: s('apiKey', ''),
          defaultModel: s('defaultModel', kOpenRouterDefaultModel),
          baseUrl: s('baseUrl', kOpenRouterDefaultBaseUrl),
          timeoutSeconds: i('timeoutSeconds', 180),
          defaultTemperature: f('defaultTemperature', 0.9),
          defaultMaxTokens: i('defaultMaxTokens', 4000),
          enableStreaming: b('enableStreaming', true),
        );
      case 'ollama':
        return OllamaConfiguration(
          baseUrl: s('baseUrl', 'http://localhost:11434'),
          defaultModel: s('defaultModel', 'qwen2.5:7b'),
        );
      case 'rwkv':
        return RwkvConfiguration(
          baseUrl: s('baseUrl', 'http://localhost:8000'),
          defaultModel: s('defaultModel', 'rwkv7-g1i'),
          defaultMaxTokens: i('defaultMaxTokens', 4000),
          localExecutable: (j['rwkvLocalExecutable'] as String?)?.isEmpty == false
              ? j['rwkvLocalExecutable'] as String
              : null,
          localModelPath: (j['rwkvLocalModelPath'] as String?)?.isEmpty == false
              ? j['rwkvLocalModelPath'] as String
              : null,
          localVocabPath: (j['rwkvLocalVocabPath'] as String?)?.isEmpty == false
              ? j['rwkvLocalVocabPath'] as String
              : null,
          localServerVariant: _variant((j['rwkvLocalServerVariant'] as String?) ?? ''),
          engineConfig: RwkvEngineConfig(
            baseUrl: s('baseUrl', 'http://localhost:8000'),
            maxConcurrentSessions: i('rwkvMaxConcurrentSessions', 16),
            nativeOptions: RwkvNativeOptions(
              thinkType: s('rwkvThinkType', 'fast'),
            ),
            useStatefulRoute: b('rwkvUseStatefulRoute', true),
          ),
        );
      case 'rwkvCloud':
        return RwkvCloudConfiguration(
          baseUrl: s('baseUrl', kRwkvCloudDefaultBaseUrl),
          apiKey: s('apiKey', ''),
          defaultModel: s('defaultModel', kRwkvCloudDefaultModel),
          timeoutSeconds: i('timeoutSeconds', 180),
          defaultMaxTokens: i('defaultMaxTokens', 16000),
          defaultTemperature: f('defaultTemperature', 1.0),
          enableStreaming: b('enableStreaming', true),
          cfAccessClientId: s('cfAccessClientId', ''),
          cfAccessClientSecret: s('cfAccessClientSecret', ''),
        );
      case 'custom':
        return OpenAICompatibleConfiguration(
          providerName: 'Custom',
          providerKind: 'Custom',
          baseUrl: s('baseUrl', 'https://api.openai.com/v1'),
          apiKey: s('apiKey', ''),
          defaultModel: s('defaultModel', 'gpt-3.5-turbo'),
          timeoutSeconds: i('timeoutSeconds', 120),
        );
    }
    return null;
  }

  OfficialServerVariant? _variant(String name) {
    for (final OfficialServerVariant v in OfficialServerVariant.values) {
      if (v.name == name) return v;
    }
    return null;
  }
}
