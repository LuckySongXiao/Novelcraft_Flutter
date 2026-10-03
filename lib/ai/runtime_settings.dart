/// AI 运行时设置 —— 采样参数预设 + 思维链开关/强度。
///
/// 对应 AI 配置页「生成采样参数与思维链」卡片；持久化在
/// KVStore `(scope=ai_config, key=runtime_settings)`，启动时由
/// `appBootstrapProvider` 载入（见 core/di.dart）。
///
/// 采样参数数值出处（官方/社区实测，详见 `rwkv_sampling.dart` 头注）：
/// - **官方推荐（抗复读）**：RWKV 官方生成参数推荐值
///   （`alpha_presence=2.0 / alpha_frequency=0.2 / alpha_decay=0.996 /
///   top_k=50 / top_p=0.6`）+ llama.cpp DRY 默认（`0.8 / 1.75 / 2 / 2048`）。
/// - **强抗复读**：惩罚三件套整体加重（社区实测长文整段复读时的常用档），
///   DRY multiplier 提到 0.9、last_n 拉到 4096 覆盖更长窗口。
/// - **宽松（保文笔）**：惩罚降到最小档，避免高质量种子文本被误伤；
///   top_p 放宽到 0.8 保留更多采样多样性。
///
/// 复读问题的原理：RWKV 是 RNN，长上下文里出现过的 n-gram 会持续抬高
/// 自身的采样概率 —— 只调 temperature 治不了复读，必须靠重复惩罚
/// （alpha_* / DRY）把已出现内容的概率压下去。
library;

import 'rwkv/rwkv_sampling.dart';

/// 采样参数预设档位。
enum RwkvSamplingPresetId {
  /// 官方推荐（抗复读）—— RWKV 官方推荐值 + llama.cpp DRY 默认值。
  official,

  /// 强抗复读 —— 惩罚加重，专治整段复读。
  strong,

  /// 宽松（保文笔）—— 惩罚最小化，优先保留文风。
  relaxed,

  /// 自定义 —— 任一字段被手动修改后自动进入此档。
  custom,
}

/// 思维链思考强度。
enum ThinkingIntensity {
  /// 低 —— 仅核心长文任务（正文/大纲/续写/角色设计）。
  low,

  /// 中 —— 默认复杂任务集合（与历史行为一致）。
  medium,

  /// 高 —— 所有任务都走思维链。
  high,
}

/// 采样 + 思维链运行时设置（不可变，变更整体替换）。
class AiRuntimeSettings {
  /// 当前预设档位（仅用于 UI 回显；生效值以下面字段为准）。
  final RwkvSamplingPresetId samplingPreset;

  // ---- 采样微调值（null = 采用当前预设的默认值）----
  final int? topK;
  final double? topP;
  final double? alphaPresence;
  final double? alphaFrequency;
  final double? alphaDecay;
  final double? dryMultiplier;
  final double? dryBase;
  final int? dryAllowedLength;
  final int? dryPenaltyLastN;

  /// 思维链总开关（关 = Agent 不再构造/解析思维链）。
  final bool thinkingEnabled;

  /// 思考强度（开关打开时决定哪些任务走思维链）。
  final ThinkingIntensity thinkingIntensity;

  /// 模型最大参考长度（token）—— **恒等于「最大令牌数」**（用户约定）。
  ///
  /// 语义：可喂进提示词的参考上下文预算。生成链路用它折算字符预算决定
  /// 大纲/前文的截断上限，从而「模型参考长度 = 模型最大 Tokens」。
  ///
  /// ⚠ 实际生效值会被 [contextWindowTokens] 钳制 —— 见 [referenceBudgetTokens]。
  final int maxReferenceLength;

  /// 模型上下文窗口（token）—— 取自模型名里的 `ctxN`（如
  /// `rwkv7-g1j-7.2b-20260831-ctx16384` → 16384），默认 16384。
  final int contextWindowTokens;

  /// 中文 token 折算系数。
  ///
  /// 实测（RWKV7-G1J 云端 7.2B）：中文正文 ≈ **1.0 token/字**
  /// （旧代码按 1.6 字/token 估算，把 token 数量低估了约 60% —— 这正是
  /// 「最大令牌数填 16000 时提示词自己就撑爆 16K 窗口」的根因）。
  static const double kTokensPerChineseChar = 1.0;

  /// chat 模板 / 角色标记等固定开销的安全余量（token）。
  static const int kContextSafetyMargin = 512;

  /// 参考上下文预算（token）：与「最大令牌数」同源（用户约定两者相等），
  /// 但被窗口钳制到 **窗口的 40%**，给输出留出空间。
  int get referenceBudgetTokens {
    final int cap = (contextWindowTokens * 0.40).floor();
    final int v = maxReferenceLength < cap ? maxReferenceLength : cap;
    return v < 1024 ? 1024 : v;
  }

  /// 生成时**真正下发**的 max_tokens。
  ///
  /// 三重钳制，保证「提示词 + 输出 + 余量 ≤ 上下文窗口」：
  /// ① 不超过窗口的 55%；② 不超过「窗口 − 参考预算 − 余量」；
  /// ③ 不超过用户设定的最大令牌数。
  int get outputBudgetTokens {
    final int capByShare = (contextWindowTokens * 0.55).floor();
    final int capByWindow =
        contextWindowTokens - referenceBudgetTokens - kContextSafetyMargin;
    int v = maxReferenceLength;
    if (v <= 0) v = capByShare;
    if (v > capByShare) v = capByShare;
    if (v > capByWindow) v = capByWindow;
    return v < 512 ? 512 : v;
  }

  /// 由模型名解析上下文窗口（`ctx16384` → 16384）；解析不到回落 16384。
  static int parseContextWindow(String modelName) {
    final RegExpMatch? m =
        RegExp(r'ctx[_-]?(\d+)', caseSensitive: false).firstMatch(modelName);
    if (m == null) return 16384;
    final int? n = int.tryParse(m.group(1) ?? '');
    if (n == null || n < 512) return 16384;
    return n;
  }

  const AiRuntimeSettings({
    this.samplingPreset = RwkvSamplingPresetId.official,
    this.topK,
    this.topP,
    this.alphaPresence,
    this.alphaFrequency,
    this.alphaDecay,
    this.dryMultiplier,
    this.dryBase,
    this.dryAllowedLength,
    this.dryPenaltyLastN,
    this.thinkingEnabled = true,
    this.thinkingIntensity = ThinkingIntensity.medium,
    this.maxReferenceLength = 4000,
    this.contextWindowTokens = 16384,
  });

  /// 出厂默认：官方推荐档 + 思维链开（中档）—— 与历史行为完全一致。
  factory AiRuntimeSettings.defaults() =>
      const AiRuntimeSettings(
        samplingPreset: RwkvSamplingPresetId.official,
        thinkingEnabled: true,
        thinkingIntensity: ThinkingIntensity.medium,
      );

  /// 各预设的基线值（custom 档的 null 字段回落到官方推荐值）。
  ///
  /// ⚠ 必须返回**可变**副本：`samplingParams()` 会在基线上叠加用户微调值。
  static Map<String, Object?> presetValues(RwkvSamplingPresetId id) =>
      switch (id) {
        RwkvSamplingPresetId.strong => <String, Object?>{
            'top_k': 40,
            'top_p': 0.5,
            'alpha_presence': 3.0,
            'alpha_frequency': 0.4,
            'alpha_decay': 0.995,
            'dry_multiplier': 0.9,
            'dry_base': 1.75,
            'dry_allowed_length': 2,
            'dry_penalty_last_n': 4096,
          },
        RwkvSamplingPresetId.relaxed => <String, Object?>{
            'top_k': 80,
            'top_p': 0.8,
            'alpha_presence': 1.0,
            'alpha_frequency': 0.1,
            'alpha_decay': 0.997,
            'dry_multiplier': 0.6,
            'dry_base': 1.75,
            'dry_allowed_length': 2,
            'dry_penalty_last_n': 2048,
          },
        _ => Map<String, Object?>.of(kRwkvAntiRepeatSampling),
      };

  /// 生成下发给 RWKV 家族端点的采样参数全集：
  /// 预设基线打底，用户手动微调值（非 null 字段）覆盖。
  Map<String, Object?> samplingParams() {
    final RwkvSamplingPresetId base = samplingPreset == RwkvSamplingPresetId.custom
        ? RwkvSamplingPresetId.official
        : samplingPreset;
    final Map<String, Object?> params = presetValues(base);
    void overlay(String key, Object? value) {
      if (value != null) params[key] = value;
    }

    overlay('top_k', topK);
    overlay('top_p', topP);
    overlay('alpha_presence', alphaPresence);
    overlay('alpha_frequency', alphaFrequency);
    overlay('alpha_decay', alphaDecay);
    overlay('dry_multiplier', dryMultiplier);
    overlay('dry_base', dryBase);
    overlay('dry_allowed_length', dryAllowedLength);
    overlay('dry_penalty_last_n', dryPenaltyLastN);
    return params;
  }

  /// 长文正文（章节段落 / 整章定稿）专用采样参数：
  /// 在用户预设之上叠加**抗复读下限**。
  ///
  /// 为什么需要下限：RWKV 是 RNN，上下文里出现过的 n-gram 会持续抬高自身
  /// 采样概率；官方档的 DRY 覆盖窗口只有 2048 token，压不住一整章的上下文
  ///（实测整章段落重复率可达 85%+）。这里只在「比下限更弱」时才抬高，
  /// 不覆盖用户更激进的配置，也不改预设本身。
  Map<String, Object?> longFormSamplingParams() {
    final Map<String, Object?> params = samplingParams();
    double asDouble(Object? v, double fallback) =>
        v is num ? v.toDouble() : fallback;

    // 夹到**实测安全区间**（两轮真机实验的共识）：
    //
    // ① 2026-09-30（用户 strong 档）：alpha_presence 3.0 + dry_penalty_last_n
    //    16000（覆盖全上下文）→ 模型「被罚得不敢写」，同提示词短 30%~51%。
    //    ⇒ DRY 覆盖窗口固定 4096（够覆盖整章即可），不要拉满。
    // ② 2026-10-01（对照官网教程，rwkv.cn/docs 的范例正是 7.2B G1 系列验证的）：
    //    官方创作类推荐 `Temperature 1 / Top_P 0.3 / Presence 0 / Frequency 1`。
    //    实测 **top_p 0.3 会让长篇续写过早停笔**（278/289 字 vs 1223 字 ——
    //    官方那些范例本身就是 220~350 字的短任务，不能直接套用到长篇叙事）；
    //    但官方的**惩罚方向是对的**：presence=0 / frequency 偏高。
    //    混合验证：top_p 0.5 + presence 0 + frequency 0.6~1.0 → 764/870 字，
    //    优于旧基线（562 字），且段落复读率同为 0.000。
    double band(String key, double lo, double hi, double fallback) {
      final double cur = asDouble(params[key], fallback);
      final double v = cur < lo ? lo : (cur > hi ? hi : cur);
      params[key] = v;
      return v;
    }

    // 惩罚方向按官方：presence 趋 0，frequency 取中高（专治「换词复读」）。
    band('alpha_presence', 0.0, 0.5, 0);
    band('alpha_frequency', 0.6, 1.0, 0.6);
    band('dry_multiplier', 0.8, 0.9, 0);
    // top_p 0.45~0.55：低于 0.4 会让长篇续写停笔过早，高于 0.6 复读抬头。
    band('top_p', 0.45, 0.55, 1);
    params['dry_penalty_last_n'] = 4096;
    return params;
  }

  AiRuntimeSettings copyWith({
    RwkvSamplingPresetId? samplingPreset,
    int? topK,
    double? topP,
    double? alphaPresence,
    double? alphaFrequency,
    double? alphaDecay,
    double? dryMultiplier,
    double? dryBase,
    int? dryAllowedLength,
    int? dryPenaltyLastN,
    bool? thinkingEnabled,
    ThinkingIntensity? thinkingIntensity,
    int? maxReferenceLength,
    int? contextWindowTokens,
    bool clearOverrides = false,
  }) =>
      AiRuntimeSettings(
        samplingPreset: samplingPreset ?? this.samplingPreset,
        topK: clearOverrides ? null : (topK ?? this.topK),
        topP: clearOverrides ? null : (topP ?? this.topP),
        alphaPresence:
            clearOverrides ? null : (alphaPresence ?? this.alphaPresence),
        alphaFrequency:
            clearOverrides ? null : (alphaFrequency ?? this.alphaFrequency),
        alphaDecay: clearOverrides ? null : (alphaDecay ?? this.alphaDecay),
        dryMultiplier:
            clearOverrides ? null : (dryMultiplier ?? this.dryMultiplier),
        dryBase: clearOverrides ? null : (dryBase ?? this.dryBase),
        dryAllowedLength:
            clearOverrides ? null : (dryAllowedLength ?? this.dryAllowedLength),
        dryPenaltyLastN:
            clearOverrides ? null : (dryPenaltyLastN ?? this.dryPenaltyLastN),
        thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
        thinkingIntensity: thinkingIntensity ?? this.thinkingIntensity,
        maxReferenceLength: maxReferenceLength ?? this.maxReferenceLength,
        contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'samplingPreset': samplingPreset.name,
        'topK': topK,
        'topP': topP,
        'alphaPresence': alphaPresence,
        'alphaFrequency': alphaFrequency,
        'alphaDecay': alphaDecay,
        'dryMultiplier': dryMultiplier,
        'dryBase': dryBase,
        'dryAllowedLength': dryAllowedLength,
        'dryPenaltyLastN': dryPenaltyLastN,
        'thinkingEnabled': thinkingEnabled,
        'thinkingIntensity': thinkingIntensity.name,
        'maxReferenceLength': maxReferenceLength,
        'contextWindowTokens': contextWindowTokens,
      };

  factory AiRuntimeSettings.fromJson(Map<String, Object?> map) =>
      AiRuntimeSettings(
        samplingPreset: RwkvSamplingPresetId.values
            .firstWhere((RwkvSamplingPresetId e) => e.name == map['samplingPreset'],
                orElse: () => RwkvSamplingPresetId.official),
        topK: (map['topK'] as num?)?.toInt(),
        topP: (map['topP'] as num?)?.toDouble(),
        alphaPresence: (map['alphaPresence'] as num?)?.toDouble(),
        alphaFrequency: (map['alphaFrequency'] as num?)?.toDouble(),
        alphaDecay: (map['alphaDecay'] as num?)?.toDouble(),
        dryMultiplier: (map['dryMultiplier'] as num?)?.toDouble(),
        dryBase: (map['dryBase'] as num?)?.toDouble(),
        dryAllowedLength: (map['dryAllowedLength'] as num?)?.toInt(),
        dryPenaltyLastN: (map['dryPenaltyLastN'] as num?)?.toInt(),
        thinkingEnabled: (map['thinkingEnabled'] as bool?) ?? true,
        thinkingIntensity: ThinkingIntensity.values.firstWhere(
            (ThinkingIntensity e) => e.name == map['thinkingIntensity'],
            orElse: () => ThinkingIntensity.medium),
        maxReferenceLength:
            (map['maxReferenceLength'] as num?)?.toInt() ?? 4000,
        contextWindowTokens:
            (map['contextWindowTokens'] as num?)?.toInt() ?? 16384,
      );
}

/// 全局当前生效设置（单写多读：AI 配置页写，请求链路读）。
///
/// 启动时由 `appBootstrapProvider` 从 KVStore 载入；配置页保存即整体替换，
/// 下一次模型调用立即生效（无需重启或重注册 Provider）。
AiRuntimeSettings _globalRuntimeSettings = AiRuntimeSettings.defaults();
AiRuntimeSettings get aiRuntimeSettings => _globalRuntimeSettings;
set aiRuntimeSettings(AiRuntimeSettings value) => _globalRuntimeSettings = value;
