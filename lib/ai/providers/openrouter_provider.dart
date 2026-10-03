// OpenRouter 提供者（https://openrouter.ai）。
//
// 接入要点：
// - **完全 OpenAI 兼容**：`POST {baseUrl}/chat/completions`，鉴权
//   `Authorization: Bearer <apiKey>`，请求体与 OpenAI 一致
//   （`model/messages/temperature/max_tokens/stream/top_p`）。
// - 默认地址必须带 `/api/v1`（`https://openrouter.ai/api/v1`）——只写
//   `https://openrouter.ai/v1` 会 404，与 RWKV 云端同类坑。
// - OpenRouter 建议携带 `HTTP-Referer`（站点）与 `X-Title`（应用名）两个头
//   用于在他们的排行榜里归因；这里默认填 NovelCraft 官方仓库地址，不填也能用。
// - 模型 id 形如 `apodex/apodex-1.1-mini:free`（**含 `/` 与 `:`**），
//   属于纯字符串，配置页与持久化都无需特殊处理，但不要按 `/` 拆分。
// - 模型列表：`GET {baseUrl}/models`（父类已实现），免费模型带 `:free` 后缀。
//
// ⚠ 采样参数：OpenRouter 对未知字段会 400，**绝不能**下发 RWKV 家族的
// `alpha_*` / `dry_*` / `top_k`。调用方已用
// `isRwkvFamilyProvider(providerName)` 做家族判定（名称含 rwkv 才放行），
// OpenRouter 不匹配该判定，因此天然只发标准 OpenAI 字段。
library;

import '../models/provider.dart';
import 'openai_compatible_provider.dart';

/// OpenRouter 默认基础地址（**必须带 `/api/v1`**）。
const String kOpenRouterDefaultBaseUrl = 'https://openrouter.ai/api/v1';

/// OpenRouter 默认模型（用户指定的免费档）。
const String kOpenRouterDefaultModel = 'apodex/apodex-1.1-mini:free';

/// OpenRouter 归因头（可选，但官方建议带上）。
const Map<String, String> kOpenRouterDefaultHeaders = <String, String>{
  'HTTP-Referer': 'https://github.com/songquanpeng/NovelCraft',
  'X-Title': 'NovelCraft',
};

/// OpenRouter 配置（继承通用配置，预置专属默认值）。
class OpenRouterConfiguration extends OpenAICompatibleConfiguration {
  OpenRouterConfiguration({
    super.apiKey = '',
    super.defaultModel = kOpenRouterDefaultModel,
    super.baseUrl = kOpenRouterDefaultBaseUrl,
    super.timeoutSeconds = 180,
    super.defaultTemperature = 0.9,
    super.defaultMaxTokens = 4000,
    super.enableStreaming = true,
    super.customHeaders = kOpenRouterDefaultHeaders,
  }) : super(providerName: 'OpenRouter', providerKind: 'OpenRouter');
}

/// OpenRouter 模型提供者。
class OpenRouterProvider extends OpenAICompatibleProvider {
  OpenRouterProvider({super.client, super.logger})
      : super(registeredProviderName: 'OpenRouter');

  @override
  Future<bool> initialize(IModelConfiguration configuration) async {
    final cfg = _ensureConfig(configuration);
    if (cfg == null) return false;
    return super.initialize(cfg);
  }

  OpenAICompatibleConfiguration? _ensureConfig(
    IModelConfiguration configuration,
  ) {
    if (configuration is! OpenAICompatibleConfiguration) return null;
    // 归因头：用户没自定义时补上默认的 HTTP-Referer / X-Title。
    final Map<String, String> headers = <String, String>{
      ...kOpenRouterDefaultHeaders,
      ...configuration.customHeaders,
    };
    return OpenAICompatibleConfiguration(
      providerName: 'OpenRouter',
      providerKind: 'OpenRouter',
      baseUrl: configuration.baseUrl.trim().isEmpty
          ? kOpenRouterDefaultBaseUrl
          : configuration.baseUrl.trim(),
      apiKey: configuration.apiKey,
      defaultModel: configuration.defaultModel.trim().isEmpty
          ? kOpenRouterDefaultModel
          : configuration.defaultModel,
      timeoutSeconds: configuration.timeoutSeconds,
      maxRetries: configuration.maxRetries,
      defaultTemperature: configuration.defaultTemperature,
      defaultMaxTokens: configuration.defaultMaxTokens,
      enableStreaming: configuration.enableStreaming,
      customHeaders: headers,
    );
  }
}
