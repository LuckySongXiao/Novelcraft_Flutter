import 'dart:async';
import 'dart:convert';
import '../application/services/writing_prompt_templates.dart';
import '../application/services/writing_prompt_catalog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/storage/key_value_store.dart';
import '../data/storage/key_value_archive_store.dart';
import '../data/repositories/volume_repository.dart';
import '../data/repositories/chapter_repository.dart';
import '../data/repositories/character_repository.dart';
import '../data/repositories/character_event_repository.dart';
import '../data/repositories/character_relationship_repository.dart';
import '../data/repositories/faction_repository.dart';
import '../data/repositories/faction_relationship_repository.dart';
import '../data/repositories/world_setting_repository.dart';
import '../data/repositories/plot_repository.dart';
import '../data/repositories/race_repository.dart';
import '../data/repositories/race_relationship_repository.dart';
import '../data/repositories/resource_repository.dart';
import '../data/repositories/secret_realm_repository.dart';
import '../data/repositories/cultivation_system_repository.dart';
import '../data/repositories/cultivation_level_repository.dart';
import '../data/repositories/political_system_repository.dart';
import '../data/repositories/political_position_repository.dart';
import '../data/repositories/currency_system_repository.dart';
import '../data/repositories/relationship_network_repository.dart';
import '../data/repositories/timeline_event_repository.dart';
import '../data/repositories/timeline_event_participant_repository.dart';
import '../data/repositories/project_repository.dart';
import '../application/services/project_service.dart';
import '../application/services/volume_service.dart';
import '../application/services/chapter_service.dart';
import '../application/services/character_service.dart';
import '../application/services/character_event_service.dart';
import '../application/services/character_relationship_service.dart';
import '../application/services/faction_service.dart';
import '../application/services/faction_relationship_service.dart';
import '../application/services/world_setting_service.dart';
import '../application/services/plot_service.dart';
import '../application/services/race_service.dart';
import '../application/services/race_relationship_service.dart';
import '../application/services/resource_service.dart';
import '../application/services/secret_realm_service.dart';
import '../application/services/cultivation_system_service.dart';
import '../application/services/cultivation_level_service.dart';
import '../application/services/political_system_service.dart';
import '../application/services/political_position_service.dart';
import '../application/services/currency_system_service.dart';
import '../application/services/relationship_network_service.dart';
import '../application/services/timeline_event_service.dart';
import '../application/services/project_statistics_service.dart';
import '../application/services/database_seeder.dart';
import '../application/services/project_context_assembler.dart';
import '../application/services/project_content_archive_service.dart';
import '../application/services/ai_writing_service.dart';
import '../application/services/prerequisite_generation_service.dart';
import '../application/services/one_click_novel_generation_service.dart';
import '../application/services/multi_agent_book_generation_service.dart';
import '../application/services/writing_archive_service.dart';
import '../application/services/continue_story_service.dart';
import '../application/services/chapter_revision_service.dart';
import '../application/services/module_state_service.dart';
import '../application/services/chapter_export_service.dart';
import '../application/services/chapter_post_process_service.dart';
import '../application/services/chapter_rewrite_service.dart';
import '../application/services/entity_profile_synthesizer.dart';
import '../application/services/style_digest_service.dart';
import '../application/services/style_rule.dart';
import '../application/services/style_rule_store.dart';
import '../application/services/model_config_store.dart';
import '../application/services/agent_endpoint_registry.dart';
import '../application/services/provider_auto_restore.dart';
import '../application/services/team_update_dispatch_service.dart';
import '../application/services/project_archive_audit_service.dart';
import '../application/services/agent_module_router.dart';
import '../application/services/book_content_review_service.dart';
import '../application/services/book_review_settings.dart';

import '../l10n/l10n.dart';
import '../core/l10n_text_source.dart';
import '../core/prompt_template_loader.dart';
import '../ai/prompts/prompt_template.dart';
import '../ai/utils/localized_text.dart';
import '../ai/workflow/dual_agent_workflow.dart';
import '../ai/models/provider.dart';
import '../ai/providers/model_manager.dart';
import '../ai/providers/bound_model_provider.dart';
import '../ai/providers/deepseek_provider.dart';
import '../ai/providers/zhipu_provider.dart';
import '../ai/providers/openrouter_provider.dart';
import '../ai/providers/ollama_provider.dart';
import '../ai/providers/rwkv_provider.dart';
import '../ai/providers/rwkv_cloud_provider.dart';
import '../ai/rwkv/rwkv_cloud_state.dart';
import '../ai/rwkv/g1k_model_preset.dart';
import '../ai/rwkv/rwkv_session_archive.dart';
import '../ai/observability/ai_runtime_stats.dart';
import '../ai/workflow/agent_batch_settings.dart';
import '../ai/workflow/agent_state_manager.dart';
import '../ai/workflow/batch_agent_executor.dart';
import '../ai/workflow/dispatch_planner.dart';
import '../ai/rwkv/rwkv_concurrency.dart' show RwkvServerCapacity;
import '../ai/models/chat.dart' show ChatMessage, ChatRequest, ChatResponse;
import '../ai/rwkv/rwkv_sampling.dart' show isRwkvFamilyProvider;
import '../ai/runtime_settings.dart';
import '../ai/providers/openai_compatible_provider.dart';
import '../ai/workflow/task_queue.dart';
import '../ai/workflow/workflow_engine.dart';
import '../ai/agents/agent_factory.dart';
import '../ai/agents/agent.dart';
import '../ai/memory/memory_manager.dart';
import '../ai/memory/memory.dart';
import '../ai/thinking/thinking_processor.dart';

/// 依赖装配 —— 替代 C# 的 Microsoft.Extensions.DependencyInjection
///
/// 关键差异：
/// 1. EF Core 的 DbContext 是 **Scoped** 生命周期，Dart 侧改为全局单例
///    （sqflite/drift 官方推荐的用法，避免重复打开文件句柄）。
/// 2. C# 的 `IUnitOfWork` 承载 21 个仓储 + SaveChanges/事务。Dart 侧**有意丢弃**
///    变更追踪与延迟提交：每个 Repository 方法调用即落库，跨表写入统一走
///    [databaseProvider] 暴露的 `transaction()` 包裹。
///    理由是 C# 版的 21 个服务里没有任何一处真正依赖"多次修改一次提交"，
///    保留该机制只会带来额外的复杂度和内存开销。

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final projectRepositoryProvider = Provider<ProjectRepository>(
  (ref) => ProjectRepository(ref.watch(databaseProvider)),
);
final volumeRepositoryProvider = Provider<VolumeRepository>(
  (ref) => VolumeRepository(ref.watch(databaseProvider)),
);
final chapterRepositoryProvider = Provider<ChapterRepository>(
  (ref) => ChapterRepository(ref.watch(databaseProvider)),
);
final characterRepositoryProvider = Provider<CharacterRepository>(
  (ref) => CharacterRepository(ref.watch(databaseProvider)),
);
final characterEventRepositoryProvider = Provider<CharacterEventRepository>(
  (ref) => CharacterEventRepository(ref.watch(databaseProvider)),
);
final characterRelationshipRepositoryProvider =
    Provider<CharacterRelationshipRepository>(
      (ref) => CharacterRelationshipRepository(ref.watch(databaseProvider)),
    );
final factionRepositoryProvider = Provider<FactionRepository>(
  (ref) => FactionRepository(ref.watch(databaseProvider)),
);
final factionRelationshipRepositoryProvider =
    Provider<FactionRelationshipRepository>(
      (ref) => FactionRelationshipRepository(ref.watch(databaseProvider)),
    );
final worldSettingRepositoryProvider = Provider<WorldSettingRepository>(
  (ref) => WorldSettingRepository(ref.watch(databaseProvider)),
);
final plotRepositoryProvider = Provider<PlotRepository>(
  (ref) => PlotRepository(ref.watch(databaseProvider)),
);
final raceRepositoryProvider = Provider<RaceRepository>(
  (ref) => RaceRepository(ref.watch(databaseProvider)),
);
final raceRelationshipRepositoryProvider = Provider<RaceRelationshipRepository>(
  (ref) => RaceRelationshipRepository(ref.watch(databaseProvider)),
);
final resourceRepositoryProvider = Provider<ResourceRepository>(
  (ref) => ResourceRepository(ref.watch(databaseProvider)),
);
final secretRealmRepositoryProvider = Provider<SecretRealmRepository>(
  (ref) => SecretRealmRepository(ref.watch(databaseProvider)),
);
final cultivationSystemRepositoryProvider =
    Provider<CultivationSystemRepository>(
      (ref) => CultivationSystemRepository(ref.watch(databaseProvider)),
    );
final cultivationLevelRepositoryProvider = Provider<CultivationLevelRepository>(
  (ref) => CultivationLevelRepository(ref.watch(databaseProvider)),
);
final politicalSystemRepositoryProvider = Provider<PoliticalSystemRepository>(
  (ref) => PoliticalSystemRepository(ref.watch(databaseProvider)),
);
final politicalPositionRepositoryProvider =
    Provider<PoliticalPositionRepository>(
      (ref) => PoliticalPositionRepository(ref.watch(databaseProvider)),
    );
final currencySystemRepositoryProvider = Provider<CurrencySystemRepository>(
  (ref) => CurrencySystemRepository(ref.watch(databaseProvider)),
);
final relationshipNetworkRepositoryProvider =
    Provider<RelationshipNetworkRepository>(
      (ref) => RelationshipNetworkRepository(ref.watch(databaseProvider)),
    );
final timelineEventRepositoryProvider = Provider<TimelineEventRepository>(
  (ref) => TimelineEventRepository(ref.watch(databaseProvider)),
);
final timelineEventParticipantRepositoryProvider =
    Provider<TimelineEventParticipantRepository>(
      (ref) => TimelineEventParticipantRepository(ref.watch(databaseProvider)),
    );

/// 世界观体系 JSON 存储（10 个无数据库表的体系页共用）
/// KeyValueStore（JSON 体系的持久化）。
///
/// 平台实现由 `key_value_store.dart` 的条件导出决定：
/// Native 写文件、Web 写 localStorage。与数据库 provider 相互独立。
final keyValueStoreProvider = FutureProvider<KeyValueStore>((ref) async {
  final store = createStore();
  await store.init();
  return store;
});

/// 首次启动种子数据服务。一次调用，幂等可重入。
final databaseSeederProvider = Provider<DatabaseSeeder>(
  (ref) => DatabaseSeeder(ref),
);

/// 启动初始化 Future：打开 keyValueStore 后立即执行 seeding，
/// 完成后标志为 true。供 AppShell 在启动页阶段 wait。
final appBootstrapProvider = FutureProvider<bool>((ref) async {
  final KeyValueStore kv = await ref.watch(keyValueStoreProvider.future);
  // 载入采样/思维链运行时设置（缺失或损坏时回落官方推荐默认，不阻塞启动）
  try {
    final String? json = await kv.readJson('ai_config', 'runtime_settings');
    if (json != null && json.isNotEmpty) {
      final Object? decoded = jsonDecode(json);
      if (decoded is Map<String, Object?>) {
        aiRuntimeSettings = AiRuntimeSettings.fromJson(decoded);
      }
    }
  } catch (_) {}
  // 自动恢复上次持久化的模型配置（配置过的 provider 下次启动直接可用）
  try {
    await ref.read(providerAutoRestoreProvider).restore();
  } catch (_) {}
  await ref.read(g1kBookPresetProvider.notifier).load();
  await ref.read(bookReviewSettingsProvider.notifier).load();
  // 拆书规则集：整书生成每章都要读「当前启用规则」，必须常驻内存。
  await ref.read(styleRuleLibraryProvider.notifier).load();
  final profileJson = await kv.readJson('ai_config', 'rwkv.cloud_profiles');
  if (profileJson != null) {
    try {
      final list = jsonDecode(profileJson) as List;
      await ref.read(agentEndpointRegistryProvider).replace([
        for (final item in list.whereType<Map<String, dynamic>>())
          RwkvCloudEndpointProfile.fromJson(item),
      ]);
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('Agent 端点配置恢复失败：${e.runtimeType}');
    }
  }
  final seeder = ref.watch(databaseSeederProvider);
  await seeder.ensureSeeded();
  // 预热提示词模板：否则首个双 Agent 调用时 `_lazyTemplates` 读到的是 null，
  // 会静默回落代码内置提示词（资产已打包却用不上）。
  await ref.watch(promptTemplatesProvider.future);
  await ref.watch(writingPromptTemplatesProvider.future);
  return true;
});

// ---------------------------------------------------------------------------
// 服务层装配
//
// C# 侧 21 个服务通过 DI 容器注入，生命周期为 Scoped。
// Dart 侧同样交给 Riverpod 托管；由于 Repository 本身无状态，
// 这里统一用 `Provider`（懒加载 + 全局缓存）。
// ---------------------------------------------------------------------------

final projectServiceProvider = Provider<ProjectService>(
  (ref) => ProjectService(ref.watch(projectRepositoryProvider)),
);

final volumeServiceProvider = Provider<VolumeService>(
  (ref) => VolumeService(ref.watch(volumeRepositoryProvider)),
);

final chapterServiceProvider = Provider<ChapterService>(
  (ref) => ChapterService(ref.watch(chapterRepositoryProvider)),
);

final characterServiceProvider = Provider<CharacterService>(
  (ref) => CharacterService(
    ref.watch(characterRepositoryProvider),
    characterEventRepository: ref.watch(characterEventRepositoryProvider),
    characterRelationshipRepository: ref.watch(
      characterRelationshipRepositoryProvider,
    ),
    factionRepository: ref.watch(factionRepositoryProvider),
    relationshipNetworkRepository: ref.watch(
      relationshipNetworkRepositoryProvider,
    ),
    timelineEventParticipantRepository: ref.watch(
      timelineEventParticipantRepositoryProvider,
    ),
  ),
);

final characterEventServiceProvider = Provider<CharacterEventService>(
  (ref) => CharacterEventService(ref.watch(characterEventRepositoryProvider)),
);

final characterRelationshipServiceProvider =
    Provider<CharacterRelationshipService>(
      (ref) => CharacterRelationshipService(
        ref.watch(characterRelationshipRepositoryProvider),
      ),
    );

final factionServiceProvider = Provider<FactionService>(
  (ref) => FactionService(ref.watch(factionRepositoryProvider)),
);

final factionRelationshipServiceProvider = Provider<FactionRelationshipService>(
  (ref) => FactionRelationshipService(
    ref.watch(factionRelationshipRepositoryProvider),
  ),
);

final worldSettingServiceProvider = Provider<WorldSettingService>(
  (ref) => WorldSettingService(ref.watch(worldSettingRepositoryProvider)),
);

final plotServiceProvider = Provider<PlotService>(
  (ref) => PlotService(ref.watch(plotRepositoryProvider)),
);

final raceServiceProvider = Provider<RaceService>(
  (ref) => RaceService(ref.watch(raceRepositoryProvider)),
);

final raceRelationshipServiceProvider = Provider<RaceRelationshipService>(
  (ref) =>
      RaceRelationshipService(ref.watch(raceRelationshipRepositoryProvider)),
);

final resourceServiceProvider = Provider<ResourceService>(
  (ref) => ResourceService(ref.watch(resourceRepositoryProvider)),
);

final secretRealmServiceProvider = Provider<SecretRealmService>(
  (ref) => SecretRealmService(ref.watch(secretRealmRepositoryProvider)),
);

final cultivationSystemServiceProvider = Provider<CultivationSystemService>(
  (ref) => CultivationSystemService(
    ref.watch(cultivationSystemRepositoryProvider),
    cultivationLevelRepository: ref.watch(cultivationLevelRepositoryProvider),
  ),
);

final cultivationLevelServiceProvider = Provider<CultivationLevelService>(
  (ref) => CultivationLevelService(
    ref.watch(cultivationLevelRepositoryProvider),
    cultivationSystemRepository: ref.watch(cultivationSystemRepositoryProvider),
  ),
);

final politicalSystemServiceProvider = Provider<PoliticalSystemService>(
  (ref) => PoliticalSystemService(
    ref.watch(politicalSystemRepositoryProvider),
    politicalPositionRepository: ref.watch(politicalPositionRepositoryProvider),
  ),
);

final politicalPositionServiceProvider = Provider<PoliticalPositionService>(
  (ref) => PoliticalPositionService(
    ref.watch(politicalPositionRepositoryProvider),
    politicalSystemRepository: ref.watch(politicalSystemRepositoryProvider),
  ),
);

final currencySystemServiceProvider = Provider<CurrencySystemService>(
  (ref) => CurrencySystemService(ref.watch(currencySystemRepositoryProvider)),
);

final relationshipNetworkServiceProvider = Provider<RelationshipNetworkService>(
  (ref) => RelationshipNetworkService(
    ref.watch(relationshipNetworkRepositoryProvider),
    characterRelationshipRepository: ref.watch(
      characterRelationshipRepositoryProvider,
    ),
    characterRepository: ref.watch(characterRepositoryProvider),
  ),
);

final timelineEventServiceProvider = Provider<TimelineEventService>(
  (ref) => TimelineEventService(
    ref.watch(timelineEventRepositoryProvider),
    participantRepository: ref.watch(
      timelineEventParticipantRepositoryProvider,
    ),
  ),
);

final projectStatisticsServiceProvider = Provider<ProjectStatisticsService>(
  (ref) => ProjectStatisticsService(
    ref.watch(projectRepositoryProvider),
    volumeRepository: ref.watch(volumeRepositoryProvider),
    chapterRepository: ref.watch(chapterRepositoryProvider),
    characterRepository: ref.watch(characterRepositoryProvider),
    factionRepository: ref.watch(factionRepositoryProvider),
    plotRepository: ref.watch(plotRepositoryProvider),
    worldSettingRepository: ref.watch(worldSettingRepositoryProvider),
    raceRepository: ref.watch(raceRepositoryProvider),
    resourceRepository: ref.watch(resourceRepositoryProvider),
    secretRealmRepository: ref.watch(secretRealmRepositoryProvider),
    cultivationSystemRepository: ref.watch(cultivationSystemRepositoryProvider),
    politicalSystemRepository: ref.watch(politicalSystemRepositoryProvider),
    currencySystemRepository: ref.watch(currencySystemRepositoryProvider),
    relationshipNetworkRepository: ref.watch(
      relationshipNetworkRepositoryProvider,
    ),
    timelineEventRepository: ref.watch(timelineEventRepositoryProvider),
  ),
);

// ---------------------------------------------------------------------------
// AI 层装配
//
// 对应 C# 的 App.xaml.cs：ModelManager / Agents / WorkflowEngine
// 所有实例化为单例，每个 Provider 都带 dispose 释放。
// ---------------------------------------------------------------------------

final aiLoggerProvider = Provider<Logger>((ref) {
  Logger.root.level = Level.INFO;
  return Logger('NovelCraft.AI');
});

final memoryManagerProvider = Provider<IMemoryManager>((ref) {
  return MemoryManager(logger: ref.watch(aiLoggerProvider));
});

final thinkingProcessorProvider = Provider<IThinkingChainProcessor>((ref) {
  return ThinkingChainProcessor();
});

final modelManagerProvider = Provider<ModelManager>((ref) {
  final mm = ModelManager(logger: ref.watch(aiLoggerProvider));
  ref.onDispose(() => mm.dispose());
  return mm;
});

/// 模型配置本地持久化（provider 注册表 + 默认 provider）。
final modelConfigStoreProvider = Provider<ModelConfigStore>((ref) {
  return ModelConfigStore(store: () => ref.read(keyValueStoreProvider.future));
});

/// 启动时自动恢复已持久化的模型配置。
final providerAutoRestoreProvider = Provider<ProviderAutoRestore>((ref) {
  return ProviderAutoRestore(
    store: ref.watch(modelConfigStoreProvider),
    manager: ref.watch(modelManagerProvider),
    providers: <String, IModelProvider>{
      'deepseek': ref.watch(deepSeekProviderInstanceProvider),
      'zhipu': ref.watch(zhipuProviderInstanceProvider),
      'openrouter': ref.watch(openRouterProviderInstanceProvider),
      'ollama': ref.watch(ollamaProviderInstanceProvider),
      'rwkv': ref.watch(rwkvProviderInstanceProvider),
      'rwkvCloud': ref.watch(rwkvCloudProviderInstanceProvider),
      'custom': ref.watch(customOAICompatibleProviderInstanceProvider),
    },
    logger: ref.watch(aiLoggerProvider),
  );
});

/// 章节结构化导出（Markdown + JSON 落盘到本地 exports 目录）。
final chapterExportServiceProvider = Provider<ChapterExportService>((ref) {
  return const ChapterExportService();
});

final rwkvProviderInstanceProvider = Provider<RwkvProvider>((ref) {
  final p = RwkvProvider(logger: ref.watch(aiLoggerProvider));
  ref.onDispose(() => p.dispose());
  return p;
});

/// RWKV 云端 Provider **单例**（`api-7b.rwkvos.com`，Cloudflare Access 保护）。
///
/// 必须是单例：①CF Service Token 与 baseUrl 是全局唯一的；②`ModelManager`
/// 注册表里同名提供者重复注册会抛异常；③云端的 `/state/*` 会话缓存挂在服务端，
/// 客户端多实例会导致会话状态不一致。
///
/// ⚠ 端点上跑的是 `rwkv_lightning_cuda`：路由前缀是 `/v1`（不是 `/openai/v1`），
/// 会话续跑走 `/state/chat/completions`。见 PITFALLS §31。
/// AI 运行时指标单例（P4-26 健康面板的数据源）。
///
/// 全局单例：面板要看到的是**整个 App** 的请求统计，多实例会各算一半。
final aiRuntimeStatsProvider = Provider<AiRuntimeStats>((ref) {
  return AiRuntimeStats(windowSeconds: 60, latencyCapacity: 512);
});

final rwkvCloudProviderInstanceProvider = Provider<RwkvCloudProvider>((ref) {
  final p = RwkvCloudProvider(
    logger: ref.watch(aiLoggerProvider),
    stats: ref.watch(aiRuntimeStatsProvider),
    // BUG 2：把 RWKV state 的**会话身份与转写本**交给客户端持有并持久化。
    sessionLedger: ref.watch(rwkvCloudSessionLedgerProvider),
    clientStateEnabled: true,
  );
  ref.onDispose(() => p.dispose());
  return p;
});

/// 云端 RWKV 的**客户端会话台账**（BUG 2 —— 「把 state 做到客户端」的落点）。
///
/// 方案：**端点重放 + 本地台账**。
/// - 会话 ID 由客户端生成，按「作用域 × 智能体角色」粒度持久化在本地
///   （规划组 `<书名>::plan`；写作组 `<项目 id>::chapter::<章 id>`，
///   于是**每章每个角色一条独立 state 链**，全书章节并行开队时章间零依赖）；
/// - 续跑时只把本轮增量发给 `/state/chat/completions`，服务端按 id 接着算
///   （RWKV 的 O(1) 上下文接续，Transformer 的 KV Cache 做不到）；
/// - 服务端丢了会话（重启 / 三级缓存淘汰 / 换端点）时，用本地转写本重放重建。
///
/// ⚠ native 端 `KeyValueStore` 把 key 直接当文件名（`<scope>/<key>.json`），
/// 而逻辑会话 key 形如 `<项目 id>::chapter::<章 id>::leader` **含冒号** ——
/// Windows 文件名不允许冒号，必须经 [RwkvCloudSessionLedger.storageKey] 转义；
/// 否则会「静默写失败」（[RwkvCloudSessionLedger.persist] 的 try/catch 吞掉），
/// 现象是「记忆永远不落盘」。
final rwkvCloudSessionLedgerProvider = Provider<RwkvCloudSessionLedger>((ref) {
  const String scope = 'rwkv_state';
  Future<KeyValueStore> kv() => ref.read(keyValueStoreProvider.future);
  return RwkvCloudSessionLedger(
    read: (String key) async =>
        (await kv()).readJson(scope, RwkvCloudSessionLedger.storageKey(key)),
    write: (String key, String value) async =>
        (await kv()).writeJson(scope, RwkvCloudSessionLedger.storageKey(key), value),
    remove: (String key) async =>
        (await kv()).remove(scope, RwkvCloudSessionLedger.storageKey(key)),
  );
});

final deepSeekProviderInstanceProvider = Provider<DeepSeekProvider>((ref) {
  final p = DeepSeekProvider(logger: ref.watch(aiLoggerProvider));
  ref.onDispose(() => p.dispose());
  return p;
});

final zhipuProviderInstanceProvider = Provider<ZhipuProvider>((ref) {
  final p = ZhipuProvider(logger: ref.watch(aiLoggerProvider));
  ref.onDispose(() => p.dispose());
  return p;
});

/// OpenRouter 实例（全局单例，与其它云端 provider 一致）。
final openRouterProviderInstanceProvider = Provider<OpenRouterProvider>((ref) {
  final p = OpenRouterProvider(logger: ref.watch(aiLoggerProvider));
  ref.onDispose(() => p.dispose());
  return p;
});

final ollamaProviderInstanceProvider = Provider<OllamaProvider>((ref) {
  final p = OllamaProvider(logger: ref.watch(aiLoggerProvider));
  ref.onDispose(() => p.dispose());
  return p;
});

final customOAICompatibleProviderInstanceProvider =
    Provider<OpenAICompatibleProvider>((ref) {
      final p = OpenAICompatibleProvider(
        registeredProviderName: 'Custom',
        logger: ref.watch(aiLoggerProvider),
      );
      ref.onDispose(() => p.dispose());
      return p;
    });

final aiTaskQueueProvider = Provider<TaskQueue>((ref) {
  final queue = TaskQueue(ref.watch(aiLoggerProvider), maxConcurrentTasks: 5);
  ref.onDispose(() => queue.dispose());
  return queue;
});

/// 功能：分派规划器 —— 探测 RWKV 最大并发（存 KVStore）+ 主 Agent 决策分派数。
///
/// - 探测：云端 `capacity().effectiveAvailable`（服务端 available_bsz），
///   不可达/未配置时回退本地引擎配置的会话上限（默认 16）。
/// - 主 Agent：双代理的 Main provider 对「分派多少个子 Agent 并行」表态，
///   解析出整数后 clamp 到 [1, 探测值]；任何一步失败 = 未表态（用满探测值）。
final workflowDispatchPlannerProvider = Provider<WorkflowDispatchPlanner>((
  ref,
) {
  return WorkflowDispatchPlanner(
    readJson: (String scope, String key) async =>
        (await ref.read(keyValueStoreProvider.future)).readJson(scope, key),
    writeJson: (String scope, String key, String json) async => (await ref.read(
      keyValueStoreProvider.future,
    )).writeJson(scope, key, json),
    probe: () async {
      final RwkvCloudProvider cloud = ref.read(
        rwkvCloudProviderInstanceProvider,
      );
      final RwkvServerCapacity? c = await cloud.capacity();
      final int? avail = c?.effectiveAvailable;
      if (avail == null) return null;
      // 与云端门控取小：服务端容量再大（实测 167），TaskQueue 放出的并行任务
      // 也不超过 clientHardCap —— 非批量路由（chat/state）不过 waitForPermit，
      // 这里是它们唯一的并发闸，超限全压在移动端内存/套接字上。
      final int cap = cloud.concurrency.clientHardCap;
      return avail < cap ? avail : cap;
    },
    // 探测失败时的回退值：读引擎配置的会话上限（与 AI 配置页
    // rwkvMaxConcurrentSessions 同源），而非硬编码 —— 此前写死 16，
    // 用户在小显存设备上配置的低上限会被规划器无视。
    configuredFallback: () {
      try {
        final int n = ref
            .read(rwkvProviderInstanceProvider)
            .engine
            .config
            .maxConcurrentSessions;
        return n > 0 ? n : 16;
      } on Object {
        return 16;
      }
    },
    askMainAgent: (String prompt) async {
      final AgentRoleWorkflowSettings s = ref.read(dualAgentSettingsProvider);
      if (!s.enableDualAgentWorkflow) return null;
      final IModelProvider? provider = resolveExactProvider(
        ref,
        s.mainAgentProvider,
      );
      if (provider == null) return null;
      final ChatResponse resp = await provider.chat(
        ChatRequest(
          systemPrompt: '你是调度规划器。只回复一个整数，禁止任何其它内容。',
          messages: <ChatMessage>[ChatMessage.user(prompt)],
          temperature: 0.2,
          maxTokens: 16,
          parameters: isRwkvFamilyProvider(provider.providerName)
              ? Map<String, dynamic>.of(aiRuntimeSettings.samplingParams())
              : <String, dynamic>{},
        ),
      );
      return resp.isSuccess ? resp.content : null;
    },
  );
});

/// 智能体 state 分组管理（按「1 组长 + 9 写手」团队分组，并发为 10 的倍数）。
///
/// 多智能体写书等团队流程在运行期激活分组，组内 10 个 state 独享；
/// 快照（snapshot）挂 AI 健康页面板供开发人员判断 state 是否正常。
final agentStateManagerProvider = Provider<AgentStateManager>((ref) {
  final AgentStateManager m = AgentStateManager(
    logger: ref.watch(aiLoggerProvider),
  );
  ref.onDispose(m.closeAll);
  return m;
});

final allAgentsProvider = Provider<List<BaseAgent>>((ref) {
  return createAllAgents(
    logger: ref.watch(aiLoggerProvider),
    memoryManager: ref.watch(memoryManagerProvider),
    thinkingChainProcessor: ref.watch(thinkingProcessorProvider),
    modelManager: ref.watch(modelManagerProvider),
    rwkvService: ref.watch(rwkvProviderInstanceProvider),
  );
});

/// 批量 Agent 执行器（P3-22）单例。
///
/// 攒批要求「多个独立任务在 100ms 窗口内并发抵达」，所以队列并发上限必须
/// **大于等于** `maxBatchSize`，否则永远攒不满（`NovelWorkflowEngine` 构造时
/// 会 warning 自查这一点）。
///
/// ⚠ 批量路由是**无状态**的：走批量时不带 `rwkvSessionId` 的 state 续跑，
/// 因此 `BaseAgent.buildPromptForBatch` 产出的 prompt 必须自包含上下文。
final batchAgentExecutorProvider = Provider<BatchAgentExecutor>((ref) {
  final cloud = ref.watch(rwkvCloudProviderInstanceProvider);
  final ex = BatchAgentExecutor(
    batchClient: cloud.batchClient,
    maxBatchSize: 8,
    batchWaitWindow: const Duration(milliseconds: 100),
    logger: ref.watch(aiLoggerProvider),
  );
  ref.onDispose(ex.dispose);
  return ex;
});

/// Agent 攒批配置（P4-28）：KVStore 持久化 + 运行时可变。
///
/// ⚠ 用 `AgentBatchSettings` 的**能力语义**：配置只能"关掉"攒批，
/// 不能给一个没实现 `buildPromptForBatch` 的 Agent 开出来。
/// UI 会用 `describe()` 明确展示"已开启但不会生效"的情况。
class AgentBatchSettingsNotifier extends Notifier<AgentBatchSettings> {
  static const String _scope = 'ai_config';
  static const String _key = 'agent.batch_settings';

  @override
  AgentBatchSettings build() {
    unawaited(_load());
    return AgentBatchSettings.empty;
  }

  Future<void> _load() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final String? raw = await kv.readJson(_scope, _key);
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        state = AgentBatchSettings.fromJson(decoded);
      }
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('读取 Agent 攒批配置失败：$e');
    }
  }

  Future<void> update(
    String agentName, {
    bool? enabled,
    Object? groupId = kAgentBatchGroupUnset,
  }) async {
    state = state.withEntry(agentName, enabled: enabled, groupId: groupId);
    await _save();
  }

  Future<void> clearAgent(String agentName) async {
    state = state.withoutAgent(agentName);
    await _save();
  }

  Future<void> _save() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      await kv.writeJson(_scope, _key, jsonEncode(state.toMap()));
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('保存 Agent 攒批配置失败：$e');
    }
  }
}

final agentBatchSettingsProvider =
    NotifierProvider<AgentBatchSettingsNotifier, AgentBatchSettings>(
      AgentBatchSettingsNotifier.new,
    );

/// RWKV 会话存档（P4-27）—— 存「对话转录本」，恢复时重放重建 state。
///
/// ⚠ 不是存 state 字节：rwkv_lightning 没有 state 导出端点，
/// 客户端的 `RwkvState.bytes` 一直是空占位（PITFALLS §39.1）。
final rwkvSessionArchiveProvider = FutureProvider<RwkvSessionArchive>((
  ref,
) async {
  final KeyValueStore kv = await ref.watch(keyValueStoreProvider.future);
  return RwkvSessionArchive(KeyValueSessionArchiveStore(kv));
});

/// 惰性取会话存档（KVStore 未就绪时返回 null = 不存档，不阻塞工作流）。
RwkvSessionArchive? _lazySessionArchive(Ref ref) {
  final AsyncValue<RwkvSessionArchive> v = ref.watch(
    rwkvSessionArchiveProvider,
  );
  return v.value;
}

final workflowEngineProvider = Provider<NovelWorkflowEngine>((ref) {
  final engine = NovelWorkflowEngine(
    ref.watch(aiLoggerProvider),
    ref.watch(aiTaskQueueProvider),
    memoryManager: ref.watch(memoryManagerProvider),
    rwkvProvider: ref.watch(rwkvProviderInstanceProvider),
    // 攒批执行器：单条件「任务显式 useBatch: true 或引擎级全开」才生效，
    // 默认不会改变任何既有任务的行为。
    batchExecutor: ref.watch(batchAgentExecutorProvider),
    // 用 read（不是 watch）：配置变更不该重建引擎，引擎每轮现取即可
    batchSettings: () => ref.read(agentBatchSettingsProvider),
    // 存档：KVStore 是异步初始化的，用惰性闭包取，拿不到就当"不存档"
    sessionArchive: _lazySessionArchive(ref),
    // 功能：跑之前探测最大并发（存 KVStore）+ 主 Agent 自主决定分派数
    dispatchPlanner: ref.watch(workflowDispatchPlannerProvider),
  );
  ref.onDispose(() => engine.dispose());
  final agents = ref.watch(allAgentsProvider);
  for (final a in agents) {
    engine.registerAgent(a);
  }
  return engine;
});

// ============================================================================
// Batch 1：上层 AI 编排（对齐 C# AIAssistantService / AIAgentRoleWorkflowService /
// PrerequisiteGenerationService / OneClickNovelGenerationService / 项目级 AI 上下文）
// ============================================================================

/// AI 层取词桥 —— `lib/ai` 是纯 Dart 层，不能直接依赖 `lib/l10n` 的 Flutter 实现。
final aiTextSourceProvider = Provider<AiTextSource>(
  (ref) => L10nTextSource(ref.watch(l10nProvider)),
);

/// 提示词模板注册表（`assets/prompts/{模板ID}/{语种}.txt`）。
///
/// 异步加载：未就绪时调用方用 `PromptTemplateRegistry.empty`，
/// 各服务会自然回退到代码内置默认提示词（与 C# `Get() == null` 同语义）。
final promptTemplatesProvider = FutureProvider<PromptTemplateRegistry>(
  (ref) => loadPromptTemplateRegistry(),
);

/// 惰性取模板注册表（未就绪 = 空注册表，不阻塞业务流程）。
PromptTemplateRegistry _lazyTemplates(Ref ref) {
  final base = ref.read(promptTemplatesProvider).value ??
      const PromptTemplateRegistry.empty();
  return ref.read(writingPromptTemplatesProvider).value?.overlay(base) ?? base;
}

final writingPromptTemplatesProvider = AsyncNotifierProvider<WritingPromptTemplatesNotifier, WritingPromptTemplates>(WritingPromptTemplatesNotifier.new);

class WritingPromptTemplatesNotifier extends AsyncNotifier<WritingPromptTemplates> {
  bool _saving = false;

  @override
  Future<WritingPromptTemplates> build() async {
    final base = await ref.watch(promptTemplatesProvider.future);
    final stages = <WritingPromptStage>[...bookPromptStages];
    const titles = {
      'Prerequisite/Cultivation.System': '修炼体系生成 · 角色',
      'Prerequisite/Cultivation.User': '修炼体系生成 · 任务',
      'Workflow/MainAgent.System': '双代理 · 主编写作',
      'Workflow/SubAgentRequirement.System': '双代理 · 需求整理',
      'Workflow/SubAgentRefine.System': '双代理 · 草稿精修',
    };
    for (final id in kPromptTemplateIds) {
      if (!id.startsWith('Workflow/') && !id.startsWith('Prerequisite/')) continue;
      for (final lang in kPromptTemplateLangs) {
        final body = base.getForLang(id, lang);
        if (body == null) continue;
        stages.add(WritingPromptStage(
          id: 'Asset/$id/$lang', title: '${titles[id] ?? id} · ${lang == 'zh' ? '中文' : 'English'}',
          defaultBody: body, asset: true,
          variables: {
            for (final match in RegExp(r'\{([A-Za-z]\w*)\}').allMatches(body)) match[1]!: '运行时填入，保留原变量名',
          },
        ));
      }
    }
    return WritingPromptTemplates.load(await ref.watch(keyValueStoreProvider.future), stages);
  }

  Future<void> saveStage(String id, List<WritingPromptVariant> items, String active) async {
    if (_saving) throw StateError('正在保存模板，请稍后重试');
    _saving = true;
    try {
      final next = state.requireValue.withStage(id, items, active);
      await next.save(await ref.read(keyValueStoreProvider.future));
      state = AsyncData(next);
    } finally {
      _saving = false;
    }
  }
}

/// 项目级 AI 上下文组装（对应 C# `ProjectContextAssembler`）。
final projectContextAssemblerProvider = Provider<ProjectContextAssembler>(
  (ref) => ProjectContextAssembler(
    projects: ref.watch(projectRepositoryProvider),
    plots: ref.watch(plotRepositoryProvider),
    characters: ref.watch(characterRepositoryProvider),
    worldSettings: ref.watch(worldSettingRepositoryProvider),
  ),
);

/// 项目纯净内容归档（对应 C# `ProjectArchiveService`，存储换成 KeyValueStore）。
final projectContentArchiveProvider = Provider<ProjectContentArchiveService>(
  (ref) => ProjectContentArchiveService(
    store: () => ref.read(keyValueStoreProvider.future),
    projects: ref.watch(projectRepositoryProvider),
  ),
);

/// 双 Agent 配置（KVStore 持久化 + 运行时可变）。
///
/// 写法照 [AgentBatchSettingsNotifier]：`build()` 先给默认值保证首帧可用，再从 KV 异步恢复。
class DualAgentSettingsNotifier extends Notifier<AgentRoleWorkflowSettings> {
  static const String _scope = 'ai_config';
  static const String _key = 'agent.dual_settings';

  @override
  AgentRoleWorkflowSettings build() {
    unawaited(_load());
    return AgentRoleWorkflowSettings.defaults;
  }

  Future<void> _load() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final String? raw = await kv.readJson(_scope, _key);
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        state = AgentRoleWorkflowSettings.fromJson(decoded);
      }
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('读取双代理配置失败：$e');
    }
  }

  Future<void> update(AgentRoleWorkflowSettings next) async {
    state = next;
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      await kv.writeJson(_scope, _key, jsonEncode(next.toJson()));
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('保存双代理配置失败：$e');
    }
  }
}

final dualAgentSettingsProvider =
    NotifierProvider<DualAgentSettingsNotifier, AgentRoleWorkflowSettings>(
      DualAgentSettingsNotifier.new,
    );

/// 多智能体写书专用双模型预设，与普通双代理的三阶段写作设置隔离。
class G1kBookPresetNotifier extends Notifier<G1kBookPreset> {
  static const String _scope = 'ai_config';
  static const String _key = 'book.g1k_preset';

  @override
  G1kBookPreset build() => const G1kBookPreset();

  Future<void> load() async {
    try {
      final kv = await ref.read(keyValueStoreProvider.future);
      final raw = await kv.readJson(_scope, _key);
      if (raw == null || raw.isEmpty) return;
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        state = G1kBookPreset.fromJson(parsed);
      }
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('读取 G1K 写书预设失败：$e');
    }
  }

  Future<void> update(G1kBookPreset next) async {
    final kv = await ref.read(keyValueStoreProvider.future);
    if (next.enabled) {
      await kv.writeJson(_scope, _key, jsonEncode(next.toJson()));
    } else {
      await kv.remove(_scope, _key);
    }
    state = next;
  }
}

final g1kBookPresetProvider =
    NotifierProvider<G1kBookPresetNotifier, G1kBookPreset>(
        G1kBookPresetNotifier.new);

class BookReviewSettingsNotifier extends Notifier<BookReviewSettings> {
  @override
  BookReviewSettings build() => const BookReviewSettings();

  Future<void> load() async {
    state = await BookReviewSettingsStore(
      () => ref.read(keyValueStoreProvider.future),
    ).load();
  }

  Future<void> update(BookReviewSettings next) async {
    await BookReviewSettingsStore(
      () => ref.read(keyValueStoreProvider.future),
    ).save(next);
    state = next;
  }
}

final bookReviewSettingsProvider =
    NotifierProvider<BookReviewSettingsNotifier, BookReviewSettings>(
  BookReviewSettingsNotifier.new,
);

/// 拆书规则集库（全局一份）—— 启动时载入，UI 与整书生成都读它。
///
/// 为什么要常驻内存而不是每次 `await store.load()`：整书生成在**每章**都要
/// 拿一次当前启用的规则去拼提示词，每次都读一遍文件/JSON 是白白浪费；
/// 而且异步读会让提示词拼装链路多一层 async 传染。
class StyleRuleLibraryNotifier extends Notifier<StyleRuleLibrary> {
  @override
  StyleRuleLibrary build() => const StyleRuleLibrary();

  Future<void> load() async {
    state = await ref.read(styleRuleStoreProvider).load();
  }

  Future<void> save(StyleRuleLibrary next) async {
    await ref.read(styleRuleStoreProvider).save(next);
    state = next;
  }

  /// 插入/替换一套规则，并把 [activateForProject] 指向它。
  Future<StyleRuleSet> upsert(
    StyleRuleSet set, {
    String activateForProject = '',
  }) async {
    final StyleRuleSet withMeta = set.copyWith(
      id: set.id.isEmpty ? const Uuid().v4() : set.id,
      createdAt: set.createdAt > 0
          ? set.createdAt
          : DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    StyleRuleLibrary next = state.upsert(withMeta);
    if (activateForProject.isNotEmpty) {
      next = next.activate(activateForProject, withMeta.id);
    }
    await save(next);
    return withMeta;
  }

  Future<void> remove(String id) async => save(state.remove(id));

  Future<void> activate(String projectId, String setId) async =>
      save(state.activate(projectId, setId));

  /// 某项目当前启用的规则集（未启用 → null）。
  StyleRuleSet? activeSetFor(String projectId) => state.activeSetFor(projectId);
}

final styleRuleLibraryProvider =
    NotifierProvider<StyleRuleLibraryNotifier, StyleRuleLibrary>(
  StyleRuleLibraryNotifier.new,
);

/// 双 Agent 的提供者表：先取 ModelManager 注册表，再用**全部内置单例**兜底。
///
/// 兜底的必要性：`ModelManager` 只在用户进过「AI 配置」并保存/测试后才注册 provider，
/// 全新会话里注册表可能是空的。旧实现只兜底两个 RWKV 单例，导致
/// **OpenRouter / DeepSeek / ZhipuAI / Ollama / Custom 在 Agent 侧完全查不到**
/// —— 表现就是「Agent 模型只能选 RWKV，换不了别的平台」。
///
/// ⚠ 仍然**不会误接管**：`resolveExactProvider` 依旧要求 `isAvailable`，
/// 未 `initialize()` 过的单例返回 null，保持「指名精确匹配、不做首个可用者
/// 兜底」的既有语义；用户在该供应商页保存/测试后即可正常被指名。
final agentEndpointRegistryProvider = Provider<AgentEndpointRegistry>((ref) {
  final registry = AgentEndpointRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

Map<String, IModelProvider> _dualAgentProviders(Ref ref) {
  final Map<String, IModelProvider> map = <String, IModelProvider>{};
  for (final IModelProvider p
      in ref.read(modelManagerProvider).getAllProviders()) {
    map[p.providerName] = p;
  }
  map.putIfAbsent('DeepSeek', () => ref.read(deepSeekProviderInstanceProvider));
  map.putIfAbsent('ZhipuAI', () => ref.read(zhipuProviderInstanceProvider));
  map.putIfAbsent(
    'OpenRouter',
    () => ref.read(openRouterProviderInstanceProvider),
  );
  map.putIfAbsent('Ollama', () => ref.read(ollamaProviderInstanceProvider));
  map.putIfAbsent(
    'Custom',
    () => ref.read(customOAICompatibleProviderInstanceProvider),
  );
  map.putIfAbsent('RWKV', () => ref.read(rwkvProviderInstanceProvider));
  map.putIfAbsent(
    'RWKV Cloud',
    () => ref.read(rwkvCloudProviderInstanceProvider),
  );
  map.addAll(ref.read(agentEndpointRegistryProvider).providers);
  return map;
}

/// 按**指名**解析 provider（名字忽略大小写 + 必须可用）。
///
/// ⚠ 刻意不用 `ModelManager.resolvePreferredProviderName`：它有"首个可用者兜底"，
/// 会掩盖"用户指名的 provider 没配对"并做出与 C# 不同的接管决策。
IModelProvider? resolveExactProvider(Ref ref, String name) {
  final String target = name.trim().toLowerCase();
  if (target.isEmpty) return null;
  for (final MapEntry<String, IModelProvider> e in _dualAgentProviders(
    ref,
  ).entries) {
    if (e.key.toLowerCase() == target) {
      return e.value.isAvailable ? e.value : null;
    }
  }
  return null;
}

IModelProvider? resolveAgentProvider(Ref ref, {bool main = false}) {
  final s = ref.read(dualAgentSettingsProvider);
  final p = resolveExactProvider(ref, main ? s.mainAgentProvider : s.subAgentProvider);
  return p == null ? null : BoundModelProvider(p, main ? s.mainAgentModel : s.subAgentModel);
}

final agentProviderResolverProvider = Provider<IModelProvider? Function(String)>((ref) {
  return (name) => resolveExactProvider(ref, name);
});

/// MainAgent / SubAgent 双 Agent 写作流单例。
final dualAgentWorkflowProvider = Provider<DualAgentWorkflowService>((ref) {
  return DualAgentWorkflowService(
    logger: ref.watch(aiLoggerProvider),
    // 用 read（不是 watch）：配置变更不该重建服务，服务每轮现取即可
    settings: () => ref.read(dualAgentSettingsProvider),
    providers: () => _dualAgentProviders(ref),
    texts: ref.watch(aiTextSourceProvider),
    templates: () => _lazyTemplates(ref),
    archiver:
        ({
          required String? projectId,
          required String taskType,
          required String content,
          String? titleHint,
          Map<String, String>? metadata,
        }) async {
          final ProjectArchiveWriteResult r = await ref
              .read(projectContentArchiveProvider)
              .writeCleanContent(
                projectId: projectId,
                taskType: taskType,
                content: content,
                titleHint: titleHint,
                metadata: metadata,
              );
          return r.code;
        },
  );
});

/// AI 写作门面（对应 C# `AIAssistantService` 的 4 个创作入口）。
///
/// 双 Agent 的白名单任务是 `GenerateOutline / GenerateChapterContent /
/// ContinueChapter / PolishText`——命中就由双 Agent 接管，否则单 Agent。
final aiWritingServiceProvider = Provider<AiWritingService>((ref) {
  return AiWritingService(
    dualAgent: ref.watch(dualAgentWorkflowProvider),
    contextAssembler: ref.watch(projectContextAssemblerProvider),
    texts: ref.watch(aiTextSourceProvider),
    // 用 read：Agent 列表在会话内不变，且避免门面被 Agent 重建牵连
    agents: () => ref.read(allAgentsProvider),
  );
});

/// 前置条件生成（修炼体系 / 剧情大纲 / 主要角色 / 世界设定 / 势力）。
final prerequisiteGenerationServiceProvider =
    Provider<PrerequisiteGenerationService>((ref) {
      return PrerequisiteGenerationService(
        plots: ref.watch(plotRepositoryProvider),
        characters: ref.watch(characterRepositoryProvider),
        worldSettings: ref.watch(worldSettingRepositoryProvider),
        factions: ref.watch(factionRepositoryProvider),
        cultivationSystems: ref.watch(cultivationSystemRepositoryProvider),
        cultivationLevels: ref.watch(cultivationLevelRepositoryProvider),
        // 修炼体系的"真 AI 路径"需要 raw prompt 补全，这是 RwkvProvider 的扩展 API
        rwkv: () => ref.read(rwkvProviderInstanceProvider),
        templates: () => _lazyTemplates(ref),
        texts: ref.watch(aiTextSourceProvider),
      );
    });

/// 一键生成书籍（自命名 → 建项目 → 双 Agent 大纲 → 前置条件 → 双 Agent 首章）。
final oneClickNovelGenerationServiceProvider =
    Provider<OneClickNovelGenerationService>((ref) {
      return OneClickNovelGenerationService(
        dualAgent: ref.watch(dualAgentWorkflowProvider),
        prerequisites: ref.watch(prerequisiteGenerationServiceProvider),
        projects: ref.watch(projectRepositoryProvider),
        plots: ref.watch(plotRepositoryProvider),
        volumes: ref.watch(volumeRepositoryProvider),
        chapters: ref.watch(chapterRepositoryProvider),
        rwkv: () => ref.read(rwkvProviderInstanceProvider),
        // 写作 provider = 双代理配置里的 SubAgent provider（本地或云端都行）。
        // 这样"只用云端、不开本地 server"也能一键成书。
        writingProvider: () => resolveAgentProvider(ref),
        texts: ref.watch(aiTextSourceProvider),
        // 功能 C：首章落库后联动同步世界观（可关闭；失败如实汇报）
        postProcess: ref.watch(chapterPostProcessServiceProvider),
        // 写作档案：首章落库即生成章节档案
        writingArchive: ref.watch(writingArchiveServiceProvider),
      );
    });

/// 多智能体协同写书（向导式：书名/作者/分卷数/每卷章数/子智能体数；
/// 主线→分卷→章节三级大纲 + 每章「组长 + 写手」团队协作）。
/// 验收后更新分派（组长罗列待更新项 → 9 写手按固定模板产出 → 防幻觉应用）。
final teamUpdateDispatchServiceProvider = Provider<TeamUpdateDispatchService>((
  ref,
) {
  return TeamUpdateDispatchService(db: ref.watch(databaseProvider));
});

/// 写作档案（项目/分卷/章节三档 + 四段描述格式）。
final writingArchiveServiceProvider = Provider<WritingArchiveService>((ref) {
  return WritingArchiveService(
    archive: ref.watch(projectContentArchiveProvider),
  );
});

final projectArchiveAuditServiceProvider = Provider<ProjectArchiveAuditService>((ref) {
  return ProjectArchiveAuditService(
    projects: ref.watch(projectRepositoryProvider),
    volumes: ref.watch(volumeRepositoryProvider),
    chapters: ref.watch(chapterRepositoryProvider),
    archive: ref.watch(projectContentArchiveProvider),
  );
});

/// Every database module uses the same structured Agent contract. The model
/// binding is role-local and never mutates a provider's global default model.
final agentModuleRouterProvider = Provider<AgentModuleRouter>((ref) {
  return AgentModuleRouter(
    provider: (String name, String model) {
      final IModelProvider? base = resolveExactProvider(ref, name);
      if (base == null || model.trim().isEmpty) return base;
      return BoundModelProvider(base, model.trim());
    },
  );
});

final bookContentReviewServiceProvider = Provider<BookContentReviewService>((ref) {
  final BookReviewSettings settings = ref.watch(bookReviewSettingsProvider);
  IModelProvider? reviewProvider() {
    final G1kBookPreset preset = ref.read(g1kBookPresetProvider);
    final IModelProvider? base = preset.enabled
        ? resolveExactProvider(ref, 'RWKV Cloud')
        : resolveAgentProvider(ref, main: true);
    if (base == null || !preset.enabled) return base;
    return BoundModelProvider(base, preset.mainModel);
  }

  IModelProvider? writingProvider() {
    final G1kBookPreset preset = ref.read(g1kBookPresetProvider);
    if (!preset.enabled) return resolveAgentProvider(ref, main: false);
    final IModelProvider? base = resolveExactProvider(
      ref,
      AgentEndpointRegistry.key(preset.writerEndpointId),
    ) ?? resolveAgentProvider(ref, main: false);
    return base == null ? null : BoundModelProvider(base, preset.writerModel);
  }
  IModelProvider? seniorProvider() {
    final IModelProvider? base = resolveExactProvider(ref, settings.seniorProvider);
    if (base == null || settings.seniorModel.trim().isEmpty) return base;
    return BoundModelProvider(base, settings.seniorModel);
  }
  return BookContentReviewService(
    promptTemplates: ref.watch(writingPromptTemplatesProvider).value,
    chapters: ref.watch(chapterRepositoryProvider),
    store: () => ref.read(keyValueStoreProvider.future),
    reviewer: reviewProvider,
    seniorReviewer: seniorProvider,
    writer: writingProvider,
    guestReaders: () => settings.guestReaders,
    guestProvider: (GuestReaderProfile profile) {
      final IModelProvider? base = resolveExactProvider(ref, profile.provider);
      if (base == null || profile.model.trim().isEmpty) return base;
      return BoundModelProvider(base, profile.model);
    },
    outline: (String projectId, ChapterRow chapter) async {
      final ProjectContextData context = await ref
          .read(projectContextAssemblerProvider)
          .build(projectId);
      return context.promptSummary.isEmpty ? chapter.summary ?? '' : context.promptSummary;
    },
    // 功能 C：审查/审核通过（13B 认可）后自动同步人物管理与世界观子项。
    // 此前该路径未挂钩子 —— 审查跑完正文回写了，设定档案却纹丝不动。
    postProcess: ref.watch(chapterPostProcessServiceProvider),
  );
});

final multiAgentBookGenerationServiceProvider =
    Provider<MultiAgentBookGenerationService>((ref) {
      final G1kBookPreset g1k = ref.watch(g1kBookPresetProvider);
      final agentSettings = ref.watch(dualAgentSettingsProvider);
      return MultiAgentBookGenerationService(
        promptTemplates: ref.watch(writingPromptTemplatesProvider).value,
        projects: ref.watch(projectRepositoryProvider),
        plots: ref.watch(plotRepositoryProvider),
        volumes: ref.watch(volumeRepositoryProvider),
        chapters: ref.watch(chapterRepositoryProvider),
        // G1K 专属写书预设只作用于本服务，其余入口维持原双代理设置。
        writingProvider: () => resolveExactProvider(
          ref,
          g1k.enabled
              ? AgentEndpointRegistry.key(g1k.writerEndpointId)
              : agentSettings.subAgentProvider,
        ) ?? (g1k.enabled
            ? resolveExactProvider(ref, 'RWKV Cloud')
            : null),
        planningProvider: () => resolveExactProvider(
          ref,
          g1k.enabled
              ? 'RWKV Cloud'
              : agentSettings.mainAgentProvider,
        ),
        mainModel: g1k.enabled
            ? g1k.mainModel
            : agentSettings.mainAgentModel,
        subModel: g1k.enabled
            ? g1k.writerModel
            : agentSettings.subAgentModel,
        postProcess: ref.watch(chapterPostProcessServiceProvider),
        // 团队 state 分组与健康页快照共享同一实例 → 运行期可见。
        stateManager: ref.watch(agentStateManagerProvider),
        // 验收后更新分派（人物/世界观各子项）。
        updateDispatch:
            ({
              required String projectId,
              required List<Map<String, Object?>> items,
              required Future<String> Function(int writerSlot, String prompt)
              writerChat,
            }) => ref
                .read(teamUpdateDispatchServiceProvider)
                .dispatchUpdates(
                  projectId: projectId,
                  items: items,
                  writerChat: writerChat,
                ),
        // 章节结构化导出（Markdown + JSON 落盘，便于离线分析写作问题）。
        exportService: ref.watch(chapterExportServiceProvider),
        // 分卷档案归纳：全部章节写完后按卷把设定流水收敛成档案。
        profileSynthesizer: ref.watch(entityProfileSynthesizerProvider),
        // 失败章自动重写：章节池结束后对质量未达标的章按上下文补写一遍。
        // 复用「章节管理 → 单章重写」那条链路，保证清洗与质量闸只有一套口径。
        chapterRewriter: ref.watch(chapterRewriteServiceProvider),
        // 拆书文风规则：按 id 从全局规则库取。用闭包延迟到「真正要拼提示词」
        // 那一刻再读，避免规则库为空时也走一遍构建。
        styleRuleResolver: (String id) =>
            ref.read(styleRuleLibraryProvider).byId(id),
        // 写作档案：项目建档 / 分卷建档 / 验收通过章节建档（四段描述）。
        archiveHook:
            ({
              required String level,
              required String? projectId,
              required String title,
              required String content,
              required Map<String, String> metadata,
            }) async {
              final WritingArchiveService svc = ref.read(
                writingArchiveServiceProvider,
              );
              await svc.write(
                level: level,
                projectId: projectId,
                title: title,
                content: content,
                desc: ArchiveDescription.fromMetadata(metadata),
                volumeId: metadata['volumeId'],
                chapterId: metadata['chapterId'],
              );
            },
      );
    });

/// 继续规划剧情并续写（项目概览页按钮；基于最新 state 自主规划与续写）。
final continueStoryServiceProvider = Provider<ContinueStoryService>((ref) {
  return ContinueStoryService(
    projects: ref.watch(projectRepositoryProvider),
    plots: ref.watch(plotRepositoryProvider),
    volumes: ref.watch(volumeRepositoryProvider),
    chapters: ref.watch(chapterRepositoryProvider),
    dualAgent: ref.watch(dualAgentWorkflowProvider),
    writingProvider: () => resolveAgentProvider(ref),
    postProcess: ref.watch(chapterPostProcessServiceProvider),
    // 写作档案：续写章节落库即生成章节档案
    writingArchive: ref.watch(writingArchiveServiceProvider),
    // 章节结构化导出
    exportService: ref.watch(chapterExportServiceProvider),
  );
});

/// 功能 C：章节落库后的世界观自动同步 —— 规则同步（零模型）+ AI 状态抽取编排。
final chapterPostProcessServiceProvider = Provider<ChapterPostProcessService>((
  ref,
) {
  final ChapterPostProcessService post = ChapterPostProcessService(
    db: ref.watch(databaseProvider),
    kv: () => ref.read(keyValueStoreProvider.future),
    texts: ref.watch(aiTextSourceProvider),
  );
  // 功能 C 二级：AI 状态抽取（默认关，开关见上方卡片）
  final ModuleStateService aiState = ModuleStateService(
    promptTemplates: ref.watch(writingPromptTemplatesProvider).value,
    db: ref.watch(databaseProvider),
    provider: () => resolveAgentProvider(ref, main: true),
  );
  post.aiStage = aiState.extractAndApply;
  return post;
});

/// 单章重写 —— 按上下文（前章结尾 / 大纲 / 下章开头 / 项目设定）把一章从头重写。
///
/// 与 [chapterRevisionServiceProvider]（带作者意见的改稿）并列：
/// 那条链路要求作者先想好「怎么改」，本服务解决的是「这一章生成坏了，按上下文
/// 重来一遍」。清洗与质量闸与「一键生成书籍」共用同一套实现（见
/// `MultiAgentBookGenerationService.cleanFinalChapter` / `chapterQualityNote`）。
final chapterRewriteServiceProvider = Provider<ChapterRewriteService>((ref) {
  return ChapterRewriteService(
    chapters: ref.watch(chapterRepositoryProvider),
    contextAssembler: ref.watch(projectContextAssemblerProvider),
    texts: ref.watch(aiTextSourceProvider),
    // 与整书生成同一个主 Agent（7.2B）：整章重写属于「规划级」任务。
    provider: () => resolveAgentProvider(ref, main: true),
    rwkv: () => ref.read(rwkvProviderInstanceProvider),
    postProcess: ref.watch(chapterPostProcessServiceProvider),
    // 大纲修订要用本卷大纲（`volumes.description`）做定位依据。
    volumes: ref.watch(volumeRepositoryProvider),
    // 「规划-续写-润色」落库后刷新 projects.progress（已完成章 / 总章数）。
    projects: ref.watch(projectRepositoryProvider),
  );
});

/// 分卷档案归纳 —— 把逐章累积的设定流水收敛成「读得懂的档案」。
///
/// 与 [chapterPostProcessServiceProvider] 里的设定抽取是**互补**关系：
/// 抽取负责「这一章发生了什么变化」（按章、增量、写进 `history` 流水），
/// 归纳负责「到这一卷为止，这个角色/势力/设定是什么样」（按卷、收敛、写进
/// 结构化档案字段）。前者是证据链，后者是档案。
final entityProfileSynthesizerProvider =
    Provider<EntityProfileSynthesizer>((ref) {
      return EntityProfileSynthesizer(
        db: ref.watch(databaseProvider),
        promptTemplates: ref.watch(writingPromptTemplatesProvider).value,
        texts: ref.watch(aiTextSourceProvider),
        // 与设定抽取同源（主 Agent / 7.2B）：归纳是「规划级」任务，
        // 而且这样档案口径与设定抽取口径一致。
        provider: () => resolveAgentProvider(ref, main: true),
      );
    });

/// 文风规则集存储 —— 拆书产物是**可复用素材**，全局一份，按项目标记启用哪一个。
///
/// 与 `ai_config` 分开一个 scope：拆书产物体积大（几十条技法），
/// 混进 AI 配置的 JSON 里会让那份文件既难读也难手动修。
final styleRuleStoreProvider = Provider<StyleRuleStore>((ref) {
  return StyleRuleStore(() => ref.read(keyValueStoreProvider.future));
});

/// Agent 拆书 —— 把一本写得好的小说拆成一套可复用的写作规则。
///
/// 与 [entityProfileSynthesizerProvider] 同源（主 Agent / 7.2B）：拆书是
/// 「规划级」任务，需要的是归纳能力而不是文笔。
final styleDigestServiceProvider = Provider<StyleDigestService>((ref) {
  return StyleDigestService(
    promptTemplates: ref.watch(writingPromptTemplatesProvider).value,
    texts: ref.watch(aiTextSourceProvider),
    // 「已有项目」输入来源要读章节正文。
    chapters: ref.watch(chapterServiceProvider),
    provider: () => resolveAgentProvider(ref, main: true),
  );
});

/// 「边聊边写」的章节关联改稿（按意见改写 / 续写 → 回写 `Chapter.Content`）。
///
/// [ChapterRevisionService.hasWriter] 的判据刻意从宽但不能为空：双代理两个指名
/// provider 都可用，或 ModelManager 注册表里至少有一个可用 provider ——
/// 两者都没有时直接失败，避免单 Agent 的内置示例文本被写进正文章节。
final chapterRevisionServiceProvider = Provider<ChapterRevisionService>((ref) {
  return ChapterRevisionService(
    writing: ref.watch(aiWritingServiceProvider),
    chapters: ref.watch(chapterRepositoryProvider),
    contextAssembler: ref.watch(projectContextAssemblerProvider),
    texts: ref.watch(aiTextSourceProvider),
    // 功能 C：改写落库后自动同步世界观
    postProcess: ref.watch(chapterPostProcessServiceProvider),
    // 分段改写的单段通道 = 双代理的写作 provider（本地或云端都行）；
    // 没配则回落到本地 RWKV 的 raw prompt。
    sliceProvider: () => resolveAgentProvider(ref),
    rwkv: () => ref.read(rwkvProviderInstanceProvider),
    hasWriter: () {
      final AgentRoleWorkflowSettings s = ref.read(dualAgentSettingsProvider);
      if (s.enableDualAgentWorkflow &&
          resolveExactProvider(ref, s.mainAgentProvider) != null &&
          resolveExactProvider(ref, s.subAgentProvider) != null) {
        return true;
      }
      return ref
          .read(modelManagerProvider)
          .getAllProviders()
          .any((IModelProvider p) => p.isAvailable);
    },
  );
});
