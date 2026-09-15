// 智谱（Zhipu / GLM）提供者。
//
// 对应 C# 源文件 `Services/Zhipu/ZhipuApiService.cs`。在 `ModelManager` 中
// 智谱同样以 `OpenAICompatibleProvider`（ProviderKind=ZhipuAI）注册。本类继承
// 通用实现并注入智谱专属默认值：
// - `ProviderKind` = `ZhipuAI`
// - 基础地址 `https://open.bigmodel.cn/api/paas/v4`
// - 默认模型 `glm-4-flash`
//
// 父类已内置智谱特例：`temperature` 被收敛到 (0,1] 区间（OpenAI 兼容教程要求）。
library;

import '../models/provider.dart';
import 'openai_compatible_provider.dart';

/// 智谱配置。
class ZhipuConfiguration extends OpenAICompatibleConfiguration {
  /// 构造智谱配置。
  ZhipuConfiguration({
    super.apiKey = '',
    super.defaultModel = 'glm-4-flash',
    super.baseUrl = 'https://open.bigmodel.cn/api/paas/v4',
    super.defaultMaxTokens = 4000,
  }) : super(providerName: 'ZhipuAI', providerKind: 'ZhipuAI');
}

/// 智谱（GLM）模型提供者。
class ZhipuProvider extends OpenAICompatibleProvider {
  /// 构造智谱提供者。
  ZhipuProvider({super.client, super.logger})
      : super(registeredProviderName: 'ZhipuAI');

  @override
  Future<bool> initialize(IModelConfiguration configuration) async {
    final cfg = _ensureConfig(configuration);
    if (cfg == null) return false;
    return super.initialize(cfg);
  }

  OpenAICompatibleConfiguration? _ensureConfig(IModelConfiguration configuration) {
    if (configuration is! OpenAICompatibleConfiguration) return null;
    return OpenAICompatibleConfiguration(
      providerName: 'ZhipuAI',
      providerKind: 'ZhipuAI',
      baseUrl: configuration.baseUrl.trim().isEmpty
          ? 'https://open.bigmodel.cn/api/paas/v4'
          : configuration.baseUrl.trim(),
      apiKey: configuration.apiKey,
      defaultModel: configuration.defaultModel.trim().isEmpty
          ? 'glm-4-flash'
          : configuration.defaultModel,
      timeoutSeconds: configuration.timeoutSeconds,
      maxRetries: configuration.maxRetries,
      defaultTemperature: configuration.defaultTemperature,
      defaultMaxTokens: configuration.defaultMaxTokens,
      enableStreaming: configuration.enableStreaming,
      customHeaders: configuration.customHeaders,
    );
  }
}
