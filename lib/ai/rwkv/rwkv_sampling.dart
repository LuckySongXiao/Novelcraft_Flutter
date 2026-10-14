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

import '../models/batch_chat.dart' show kRwkvDefaultStopTokens;

/// RWKV 家族防复读采样参数（全集）。
///
/// ⚠ +47 真机实测修正（5 组参数 × 3 次 + 6 组隔离 × 3 次，同一提示词、真实 RWKV Cloud）：
///   * `alpha_decay` **0.996 → 0.999**：这是抗复读**最有效的单一旋钮** ——
///     decay 0.99 → 1/3 退化（ngram 均值 0.254，最差 0.434）；
///     decay 0.999 → **0/3，ngram 0.000**。官方文档解释得最清楚：
///     「Penalty Decay 是模型的记性」—— 0.99 时生成 100 token 后对早期 token
///     的惩罚只剩 0.366（几乎忘记），0.999 时仍有 0.905（牢记）。
///     长文 n-gram 循环正是「忘了自己写过」造成的。
///   * `alpha_presence 2.0` / `alpha_frequency 0.2` / `top_p 0.6` / `top_k 50`：
///     与官方 G1 创意写作推荐一致，实测该组合（温度 1.0）**0/3 退化**、
///     字数最高（2262 字均值），优于 App 长文夹区间后的版本。
const Map<String, Object?> kRwkvAntiRepeatSampling = <String, Object?>{
  // RWKV 原生（rwkv_lightning）
  'top_k': 50,
  'top_p': 0.6,
  'alpha_presence': 2.0,
  'alpha_frequency': 0.2,
  'alpha_decay': 0.999,
  // 官方默认停止 token（整数 token ID，CUDA 后端约定）。
  //
  // ⚠ +46 修复：此前**只有有状态路由**（/state/*、/v1/batch/*）会带这个键，
  // 无状态 `/v1/chat/completions` 一直没发 → 长文退化复读在停止符层面完全裸奔
  // （采样惩罚 + 正则清洗都只是「事后补救」，stop token 是「事中止损」）。
  // 现在经 OpenAI 兼容基类 `_buildExtraFields` 白名单（'stop_tokens' 已在其中）
  // 展平到请求顶层，对齐有状态路由的既有行为。见交接文档 docs/交接-复读问题。
  'stop_tokens': kRwkvDefaultStopTokens,
  // llama.cpp DRY 采样器
  'dry_multiplier': 0.8,
  'dry_base': 1.75,
  'dry_allowed_length': 2,
  'dry_penalty_last_n': 2048,
};

/// provider 名是否属于 RWKV 家族（只有它们认上面这套参数）。
bool isRwkvFamilyProvider(String providerName) =>
    providerName.toLowerCase().contains('rwkv');
