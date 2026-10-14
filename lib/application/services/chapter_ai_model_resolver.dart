// 章节预览「选节 AI 助手」的默认模型解析。
//
// 用户要求（+48）：「章节预览界面的AI助手默认使用13B的模型」。
//
// 为什么要单独一层解析，而不是直接把默认 provider 换成 13B：
//   ① `ModelManager` 只有一个 `RWKV Cloud` 实例，它指向用户上次在
//      「AI 配置」里启用的端点（默认 official-7b）。「选节助手用 13B」
//      不能影响全局默认，否则整书生成、内容复盘等链路会被一起换掉。
//   ② 官方四个端点共享同一套 Cloudflare Access 凭证（同一 CF 区域），
//      所以只要用户配过**任意一个**官方云端端点，就能直接复用凭据开 13B。
//   ③ 解析失败（没配 RWKV 云、13B 不可达、只有本地 GGUF）时**必须回落**
//      到原来的链路（双 Agent 设置 → 默认 provider），保证助手永远可用。
//
// 解析顺序（任何一步不可用都向后回落，不抛异常）：
//   1. Agent 端点注册表里已有**带凭据**的 `RWKV Cloud::official-13b`；
//   2. 用持久化的云端档案拼出 13B 端点（缺凭据时从其它档案补），
//      configure(probe: true) 核实可达后注册进注册表（本次会话复用）；
//   3. 全局 `RWKV Cloud` 实例本身指向 api-13b（用户手动配过）；
//   4. 回落：双 Agent 设置（启用双代理时取 mainAgent）→ 默认 provider。
//
// ⚠ 用 `FutureProvider` 暴露：首次解一次（含一次 `/models` 探活）后按
// Riverpod 语义缓存，后续每次点击写作按钮都不会重新探活。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/models/provider.dart';
import '../../ai/providers/rwkv_cloud_provider.dart';
import '../../application/services/agent_endpoint_registry.dart';
import '../../core/di.dart';
import '../../data/storage/key_value_store.dart';

/// 选节 AI 助手本次要用的模型。
class ChapterAiModel {
  const ChapterAiModel({
    required this.provider,
    required this.model,
    required this.endpointLabel,
    required this.fallback,
    this.fallbackReason = '',
  });

  final IModelProvider provider;

  /// 随请求下发的模型名（云端端点可为空串 = 用服务端默认）。
  final String model;

  /// 端点展示名（如「RWKV 官方 13B」），供面板如实回显。
  final String endpointLabel;

  /// 是否为回落结果（true = 没能用上 13B，面板要提示）。
  final bool fallback;

  /// 回落原因（fallback 为 true 时非空），供面板提示。
  final String fallbackReason;
}

/// 选节 AI 助手的默认模型 provider（默认 13B，失败回落）。
///
/// 首次求值时会做一次 `/models` 探活；之后按 FutureProvider 语义缓存。
/// 想强制重解（例如用户刚在「AI 配置」里填好云端凭据）：
/// `ref.invalidate(chapterAiModelProvider)`。
final chapterAiModelProvider = FutureProvider<ChapterAiModel?>((Ref ref) {
  return ChapterAiModelResolver.resolveOrDefault(ref);
});

abstract final class ChapterAiModelResolver {
  /// 首选的官方端点档案 id（13B）。
  static const String preferredProfileId = 'official-13b';

  /// 注册表键（与 `AgentEndpointRegistry.key` 同规则）。
  static String get _registryKey =>
      AgentEndpointRegistry.key(preferredProfileId);

  /// 对外唯一入口：先试 13B，拿不到再回落。
  static Future<ChapterAiModel?> resolveOrDefault(Ref ref) async {
    try {
      final ChapterAiModel? preferred = await _resolve(ref);
      return preferred ?? _fallback(ref);
    } on Object {
      // 解析本身绝不能把「用不了助手」变成异常 —— 回落链路已尽力而为。
      return null;
    }
  }

  static Future<ChapterAiModel?> _resolve(Ref ref) async {
    final AgentEndpointRegistry registry =
        ref.read(agentEndpointRegistryProvider);

    // ---- 1. 已持久化的云端档案（凭据的唯一可靠来源）----
    final List<RwkvCloudEndpointProfile> saved =
        await _loadSavedProfiles(ref);
    final RwkvCloudEndpointProfile? effective =
        _buildEffectiveProfile(saved);

    if (effective != null && _hasCredentials(effective)) {
      // 注册表里已就绪且档案一致 → 直接复用（不重复 configure + 探活）。
      final RwkvCloudEndpointProfile? registered =
          registry.profiles[_registryKey];
      final IModelProvider? ready = _registryProvider(registry);
      if (ready != null &&
          registered != null &&
          jsonEncode(registered.toJson()) == jsonEncode(effective.toJson())) {
        return ChapterAiModel(
          provider: ready,
          model: effective.defaultModel,
          endpointLabel: effective.name,
          fallback: false,
        );
      }
      // 现开一个 13B 端点；probe: true 用一次 `/models` 探活，凭证不匹配时
      // 直接判不可用（否则请求会拿到 CF 的 HTML 登录页，报错更难懂）。
      final RwkvCloudProvider fresh = RwkvCloudProvider();
      if (await fresh.configure(effective.toConfiguration(), probe: true)) {
        // 合并进注册表：保留用户已保存的其它端点，只覆盖/追加 13B 这一条。
        await registry.replace(<RwkvCloudEndpointProfile>[
          for (final RwkvCloudEndpointProfile p in saved)
            if (p.id != preferredProfileId) p,
          effective,
        ]);
        // ⚠ 用注册表里那一份（replace 会为变更过的档案重建 provider），
        // 自己这个 fresh 实例放掉 —— 否则同一端点会有两个 provider 实例
        //（各自持有 CF header / http client）。
        final IModelProvider? adopted = _registryProvider(registry);
        fresh.dispose();
        if (adopted != null) {
          return ChapterAiModel(
            provider: adopted,
            model: effective.defaultModel,
            endpointLabel: effective.name,
            fallback: false,
          );
        }
        return ChapterAiModel(
          provider: fresh,
          model: effective.defaultModel,
          endpointLabel: effective.name,
          fallback: false,
        );
      }
      fresh.dispose();
      return null; // 13B 配了但不可达 —— 让调用方回落，而不是反复重试
    }

    // ---- 2. 注册表里恰好已有可用的 13B（档案里凭据为空的情形）----
    final IModelProvider? registeredProvider = _registryProvider(registry);
    if (registeredProvider != null) {
      final RwkvCloudEndpointProfile? p = registry.profiles[_registryKey];
      return ChapterAiModel(
        provider: registeredProvider,
        model: p?.defaultModel ?? '',
        endpointLabel: p?.name ?? 'RWKV 官方 13B',
        fallback: false,
      );
    }

    // ---- 3. 全局 RWKV Cloud 实例本身就指向 13B ----
    final IModelProvider? cloud = resolveExactProvider(ref, 'RWKV Cloud');
    if (cloud is RwkvCloudProvider) {
      final String host =
          Uri.tryParse(cloud.configuration.baseUrl)?.host.trim() ?? '';
      if (host == 'api-13b.rwkvos.com') {
        return ChapterAiModel(
          provider: cloud,
          model: cloud.configuration.defaultModel,
          endpointLabel: 'RWKV 官方 13B',
          fallback: false,
        );
      }
    }
    return null;
  }

  /// 注册表里 13B 端点是否可用。
  static IModelProvider? _registryProvider(AgentEndpointRegistry registry) {
    final IModelProvider? p = registry.providers[_registryKey];
    return p != null && p.isAvailable ? p : null;
  }

  /// 回落链路（与面板原逻辑一致）：双 Agent 设置 → 默认 provider。
  static ChapterAiModel? _fallback(Ref ref) {
    final settings = ref.read(dualAgentSettingsProvider);
    if (settings.enableDualAgentWorkflow) {
      final IModelProvider? main =
          resolveExactProvider(ref, settings.mainAgentProvider);
      if (main != null) {
        return ChapterAiModel(
          provider: main,
          model: settings.mainAgentModel,
          endpointLabel: main.providerName,
          fallback: true,
          fallbackReason: '13B 端点不可用，已回落到双 Agent 主写手',
        );
      }
    }
    final IModelProvider? def = ref.read(modelManagerProvider).getDefaultProvider();
    if (def != null) {
      return ChapterAiModel(
        provider: def,
        model: '',
        endpointLabel: def.providerName,
        fallback: true,
        fallbackReason: '13B 端点不可用，已回落到默认模型',
      );
    }
    return null;
  }

  static bool _hasCredentials(RwkvCloudEndpointProfile p) =>
      p.cfAccessClientId.trim().isNotEmpty &&
      p.cfAccessClientSecret.trim().isNotEmpty;

  /// 拼出「生效的 13B 端点档案」：优先持久化里的 official-13b；
  /// 没有则用官方模板，并从其它档案里补 CF 凭据。
  static RwkvCloudEndpointProfile? _buildEffectiveProfile(
    List<RwkvCloudEndpointProfile> saved,
  ) {
    RwkvCloudEndpointProfile? target;
    for (final RwkvCloudEndpointProfile p in saved) {
      if (p.id == preferredProfileId) {
        target = p;
        break;
      }
    }
    if (target == null) {
      for (final RwkvCloudEndpointProfile p in kRwkvOfficialEndpointProfiles) {
        if (p.id == preferredProfileId) {
          target = p;
          break;
        }
      }
    }
    if (target == null) return null; // 连官方模板都没有（源码被改过）
    if (_hasCredentials(target)) return target;

    // 凭据补齐：同属一个 CF 区域，Service Token 在四个官方端点间通用。
    for (final RwkvCloudEndpointProfile p in saved) {
      if (p.id == preferredProfileId || !_hasCredentials(p)) continue;
      return target.copyWith(
        cfAccessClientId: p.cfAccessClientId,
        cfAccessClientSecret: p.cfAccessClientSecret,
        apiKey: p.apiKey,
        defaultModel: target.defaultModel.isNotEmpty
            ? target.defaultModel
            : p.defaultModel,
        timeoutSeconds: p.timeoutSeconds,
        defaultMaxTokens: p.defaultMaxTokens,
        defaultTemperature: p.defaultTemperature,
        enableStreaming: p.enableStreaming,
      );
    }
    return target; // 没有任何档案带凭据 —— 交给 probe 判定
  }

  /// 读持久化的云端档案（`ai_config/rwkv.cloud_profiles`），失败返回空表。
  static Future<List<RwkvCloudEndpointProfile>> _loadSavedProfiles(
    Ref ref,
  ) async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final String? raw = await kv.readJson('ai_config', 'rwkv.cloud_profiles');
      if (raw == null || raw.isEmpty) return const <RwkvCloudEndpointProfile>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <RwkvCloudEndpointProfile>[];
      return <RwkvCloudEndpointProfile>[
        for (final Object? item in decoded)
          if (item is Map)
            RwkvCloudEndpointProfile.fromJson(
              item.map(
                (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
              ),
            ),
      ];
    } on Object {
      return const <RwkvCloudEndpointProfile>[];
    }
  }
}
