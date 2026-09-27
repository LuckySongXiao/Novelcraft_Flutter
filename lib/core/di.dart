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
import '../application/services/project_context_assembler.dart';
import '../application/services/project_content_archive_service.dart';
import '../application/services/ai_writing_service.dart';
import '../application/services/prerequisite_generation_service.dart';
import '../application/services/one_click_novel_generation_service.dart';
import '../application/services/chapter_revision_service.dart';
import '../application/services/chapter_ai_state_service.dart';
import '../application/services/chapter_post_process_service.dart';

import '../l10n/l10n.dart';
import '../core/l10n_text_source.dart';
import '../core/prompt_template_loader.dart';
import '../ai/prompts/prompt_template.dart';
import '../ai/utils/localized_text.dart';
import '../ai/workflow/dual_agent_workflow.dart';
import '../ai/models/provider.dart';
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
import '../ai/workflow/dispatch_planner.dart';
import '../ai/rwkv/rwkv_concurrency.dart' show RwkvServerCapacity;
import '../ai/models/chat.dart' show ChatMessage, ChatRequest, ChatResponse;
import '../ai/rwkv/rwkv_sampling.dart'
    show isRwkvFamilyProvider, kRwkvAntiRepeatSampling;
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
  await ref.watch(keyValueStoreProvider.future);
  final seeder = ref.watch(databaseSeederProvider);
  await seeder.ensureSeeded();
  // 预热提示词模板：否则首个双 Agent 调用时 `_lazyTemplates` 读到的是 null，
  // 会静默回落代码内置提示词（资产已打包却用不上）。
  await ref.watch(promptTemplatesProvider.future);
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
              ? Map<String, dynamic>.of(kRwkvAntiRepeatSampling)
              : <String, dynamic>{},
        ),
      );
      return resp.isSuccess ? resp.content : null;
    },
  );
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
PromptTemplateRegistry _lazyTemplates(Ref ref) =>
    ref.read(promptTemplatesProvider).value ??
    const PromptTemplateRegistry.empty();

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

/// 双 Agent 的提供者表：先取 ModelManager 注册表，再用 RWKV 单例兜底。
///
/// 兜底的必要性：`ModelManager` 只在用户进过「AI 配置」并保存/测试后才注册 provider，
/// 全新会话里注册表可能是空的，而本地 RWKV 单例始终存在。
Map<String, IModelProvider> _dualAgentProviders(Ref ref) {
  final Map<String, IModelProvider> map = <String, IModelProvider>{};
  for (final IModelProvider p
      in ref.read(modelManagerProvider).getAllProviders()) {
    map[p.providerName] = p;
  }
  map.putIfAbsent('RWKV', () => ref.read(rwkvProviderInstanceProvider));
  map.putIfAbsent(
    'RWKV Cloud',
    () => ref.read(rwkvCloudProviderInstanceProvider),
  );
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
        writingProvider: () => resolveExactProvider(
          ref,
          ref.read(dualAgentSettingsProvider).subAgentProvider,
        ),
        texts: ref.watch(aiTextSourceProvider),
        // 功能 C：首章落库后联动同步世界观（可关闭；失败如实汇报）
        postProcess: ref.watch(chapterPostProcessServiceProvider),
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
  final ChapterAiStateService aiState = ChapterAiStateService(
    db: ref.watch(databaseProvider),
    texts: ref.watch(aiTextSourceProvider),
    writingProvider: () => resolveExactProvider(
      ref,
      ref.read(dualAgentSettingsProvider).subAgentProvider,
    ),
    rwkv: () => ref.read(rwkvProviderInstanceProvider),
  );
  post.aiStage = aiState.extractAndApply;
  return post;
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
    sliceProvider: () => resolveExactProvider(
      ref,
      ref.read(dualAgentSettingsProvider).subAgentProvider,
    ),
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
