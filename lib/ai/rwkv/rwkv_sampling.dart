// RWKV 防复读采样参数（官方推荐 + 社区实测值）。
//
// 两个引擎家族认的键名不同，所以这里给一份**全集**，调用方按家族只挑需要的部分：
//
// | 家族 | 生效键 | 说明 |
// |---|---|---|
// | `rwkv_lightning`（原生 CUDA / 其 OpenAI 兼容路由） | `top_k` `top_p` `alpha_presence` `alpha_frequency` `alpha_decay` | alpha_* 是 RWKV 特有的「重复惩罚三件套」，比 OpenAI 的 presence/frequency_penalty 更贴合 RWKV 的采样分布 |
// | `llama.cpp` 兼容端点（本地 GGUF） | `top_k` `top_p` + `dry_multiplier` `dry_base` `dry_allowed_length` `dry_penalty_last_n` | DRY（Don't Repeat Yourself）采样器，专治「整段复读 / 换词复读」，是当前社区对长文最有效的方案 |
//
// 数值出处：
// - `alpha_presence=2.0` / `alpha_frequency=0.2` / `alpha_decay=0.996` / `top_k=50` / `top_p=0.6`：
//   RWKV 官方生成参数推荐值，也是 `rwkv_lightning` 文档给出的默认档（temperature 保持各任务自己的值）。
// - DRY 四件套：llama.cpp 官方默认值（0.8 / 1.75 / 2 / 2048），社区实测在 2k+ 上下文续写上最稳。
//
// 兼容性：两个服务端对**不认识的顶层字段都是容忍（忽略）而非报错**（实测记录见 PITFALLS §31.1），
// 所以整份下发是安全的；但**不要发给非 RWKV 家族**（DeepSeek/Zhipu 等严格 API 会 400），
// 调用方必须先用 [isRwkvFamilyProvider] 判断。
library;

/// RWKV 家族防复读采样参数（全集）。
const Map<String, Object?> kRwkvAntiRepeatSampling = <String, Object?>{
  // RWKV 原生（rwkv_lightning）
  'top_k': 50,
  'top_p': 0.6,
  'alpha_presence': 2.0,
  'alpha_frequency': 0.2,
  'alpha_decay': 0.996,
  // llama.cpp DRY 采样器
  'dry_multiplier': 0.8,
  'dry_base': 1.75,
  'dry_allowed_length': 2,
  'dry_penalty_last_n': 2048,
};

/// provider 名是否属于 RWKV 家族（只有它们认上面这套参数）。
bool isRwkvFamilyProvider(String providerName) =>
    providerName.toLowerCase().contains('rwkv');