// DeepSeek 提供者。
//
// 对应 C# 源文件 `Services/DeepSeek/DeepSeekApiService.cs`。在 `ModelManager`
// 中 DeepSeek 实际也是以 `OpenAICompatibleProvider`（ProviderKind=DeepSeek）形式
// 注册，因此本类直接继承通用实现，仅注入 DeepSeek 专属默认值：
// - `ProviderKind` = `DeepSeek`
// - 基础地址默认 `https://api.deepseek.com/v1`（C# 版会对 `/v1` 做归一化）
// - 默认模型 `deepseek-chat`
//
// 其余请求 / 流式 / 统计逻辑完全复用父类。
library;

import '../models/provider.dart';
import 'openai_compatible_provider.dart';

/// DeepSeek 配置（继承自通用配置，预置专属默认值）。
class DeepSeekConfiguration extends OpenAICompatibleConfiguration {
  /// 构造 DeepSeek 配置。
  DeepSeekConfiguration({
    super.apiKey = '',
    super.defaultModel = 'deepseek-chat',
    super.baseUrl = 'https://api.deepseek.com/v1',
    super.timeoutSeconds = 120,
    super.defaultMaxTokens = 4000,
  }) : super(providerName: 'DeepSeek', providerKind: 'DeepSeek');
}

/// DeepSeek 模型提供者。
class DeepSeekProvider extends OpenAICompatibleProvider {
  /// 构造 DeepSeek 提供者。
  DeepSeekProvider({super.client, super.logger})
      : super(registeredProviderName: 'DeepSeek');

  @override
  Future<bool> initialize(IModelConfiguration configuration) async {
    final cfg = _ensureConfig(configuration);
    if (cfg == null) return false;
    return super.initialize(cfg);
  }

  OpenAICompatibleConfiguration? _ensureConfig(IModelConfiguration configuration) {
    if (configuration is! OpenAICompatibleConfiguration) return null;
    return OpenAICompatibleConfiguration(
      providerName: 'DeepSeek',
      providerKind: 'DeepSeek',
      baseUrl: configuration.baseUrl.trim().isEmpty
          ? 'https://api.deepseek.com/v1'
          : configuration.baseUrl.trim(),
      apiKey: configuration.apiKey,
      defaultModel: configuration.defaultModel.trim().isEmpty
          ? 'deepseek-chat'
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
