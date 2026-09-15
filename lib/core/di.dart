import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

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

import '../ai/providers/model_manager.dart';
import '../ai/providers/deepseek_provider.dart';
import '../ai/providers/zhipu_provider.dart';
import '../ai/providers/ollama_provider.dart';
import '../ai/providers/rwkv_provider.dart';
import '../ai/providers/rwkv_cloud_provider.dart';
import '../ai/rwkv/rwkv_session_archive.dart';
import '../ai/observability/ai_runtime_stats.dart';
import '../ai/workflow/agent_batch_settings.dart';
import '../ai/workflow/batch_agent_executor.dart';
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
final raceRelationshipRepositoryProvider =
    Provider<RaceRelationshipRepository>(
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
final cultivationLevelRepositoryProvider =
    Provider<CultivationLevelRepository>(
  (ref) => CultivationLevelRepository(ref.watch(databaseProvider)),
);
final politicalSystemRepositoryProvider =
    Provider<PoliticalSystemRepository>(
  (ref) => PoliticalSystemRepository(ref.watch(databaseProvider)),
);
final politicalPositionRepositoryProvider =
    Provider<PoliticalPositionRepository>(
  (ref) => PoliticalPositionRepository(ref.watch(databaseProvider)),
);
final currencySystemRepositoryProvider =
    Provider<CurrencySystemRepository>(
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
  await ref.watch(keyValueStoreProvider.future);
  final seeder = ref.watch(databaseSeederProvider);
  await seeder.ensureSeeded();
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
    characterRelationshipRepository:
        ref.watch(characterRelationshipRepositoryProvider),
    factionRepository: ref.watch(factionRepositoryProvider),
    relationshipNetworkRepository:
        ref.watch(relationshipNetworkRepositoryProvider),
    timelineEventParticipantRepository:
        ref.watch(timelineEventParticipantRepositoryProvider),
  ),
);

final characterEventServiceProvider = Provider<CharacterEventService>(
  (ref) => CharacterEventService(
    ref.watch(characterEventRepositoryProvider),
  ),
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

final factionRelationshipServiceProvider =
    Provider<FactionRelationshipService>(
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
  (ref) => RaceRelationshipService(ref.watch(raceRelationshipRepositoryProvider)),
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
    cultivationSystemRepository:
        ref.watch(cultivationSystemRepositoryProvider),
  ),
);

final politicalSystemServiceProvider = Provider<PoliticalSystemService>(
  (ref) => PoliticalSystemService(
    ref.watch(politicalSystemRepositoryProvider),
    politicalPositionRepository:
        ref.watch(politicalPositionRepositoryProvider),
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

final relationshipNetworkServiceProvider =
    Provider<RelationshipNetworkService>(
  (ref) => RelationshipNetworkService(
    ref.watch(relationshipNetworkRepositoryProvider),
    characterRelationshipRepository:
        ref.watch(characterRelationshipRepositoryProvider),
    characterRepository: ref.watch(characterRepositoryProvider),
  ),
);

final timelineEventServiceProvider = Provider<TimelineEventService>(
  (ref) => TimelineEventService(
    ref.watch(timelineEventRepositoryProvider),
    participantRepository: ref.watch(timelineEventParticipantRepositoryProvider),
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
  );
  ref.onDispose(() => p.dispose());
  return p;
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
        AgentBatchSettingsNotifier.new);

/// RWKV 会话存档（P4-27）—— 存「对话转录本」，恢复时重放重建 state。
///
/// ⚠ 不是存 state 字节：rwkv_lightning 没有 state 导出端点，
/// 客户端的 `RwkvState.bytes` 一直是空占位（PITFALLS §39.1）。
final rwkvSessionArchiveProvider = FutureProvider<RwkvSessionArchive>((ref) async {
  final KeyValueStore kv = await ref.watch(keyValueStoreProvider.future);
  return RwkvSessionArchive(KeyValueSessionArchiveStore(kv));
});

/// 惰性取会话存档（KVStore 未就绪时返回 null = 不存档，不阻塞工作流）。
RwkvSessionArchive? _lazySessionArchive(Ref ref) {
  final AsyncValue<RwkvSessionArchive> v =
      ref.watch(rwkvSessionArchiveProvider);
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
  );
  ref.onDispose(() => engine.dispose());
  final agents = ref.watch(allAgentsProvider);
  for (final a in agents) {
    engine.registerAgent(a);
  }
  return engine;
});
