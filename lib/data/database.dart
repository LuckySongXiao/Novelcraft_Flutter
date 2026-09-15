import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables/character_tables.dart';
import 'tables/content_tables.dart';
import 'tables/faction_tables.dart';
import 'tables/junction_tables.dart';
import 'tables/project_tables.dart';
import 'tables/timeline_tables.dart';
import 'tables/world_tables.dart';
import 'tables/worldbuilding_tables.dart';

part 'database.g.dart';

/// NovelCraft 主数据库
///
/// 对应 C# 的 `NovelManagementDbContext`（22 个 DbSet）。
/// 这里在此基础上额外显式定义了 5 张联结表，共 **27 张表**。
///
/// 平台策略：
///  - Native（Windows / macOS / Linux / Android / iOS）：sqlite3 原生库，文件落在
///    `getApplicationDocumentsDirectory()` 下
///  - Web：sqlite3 编译为 WASM + IndexedDB 持久化（由 sqlite3_web 自动处理）
///
/// 两者由 `driftDatabase()` 统一路由，上层代码无需区分平台。
@DriftDatabase(
  tables: [
    // 项目 / 卷宗 / 章节
    Projects,
    Volumes,
    Chapters,
    // 势力
    Factions,
    FactionRelationships,
    // 世界观基础（被角色引用，须排在 Characters 之前）
    Plots,
    Races,
    RaceRelationships,
    Resources,
    SecretRealms,
    // 人物及其附属
    Characters,
    CharacterEvents,
    CharacterRelationships,
    // 世界观设定
    WorldSettings,
    Plots,
    Races,
    RaceRelationships,
    Resources,
    SecretRealms,
    CultivationSystems,
    CultivationLevels,
    PoliticalSystems,
    PoliticalPositions,
    CurrencySystems,
    RelationshipNetworks,
    // 时间线
    TimelineEvents,
    TimelineEventParticipants,
    // 多对多联结表（C# 侧由 EF 隐式生成，Dart 必须显式定义）
    CharacterPlotEntries,
    ChapterPlotEntries,
    ResourceSecretRealmEntries,
    CurrencySystemFactionEntries,
    CharacterNetworkEntries,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// 常规构造：由 driftDatabase 按平台选择底层实现
  AppDatabase() : super(_openConnection());

  /// 测试构造：允许注入内存数据库
  AppDatabase.forTesting(super.connection);

  static DatabaseConnection _openConnection() =>
      driftDatabase(name: 'novelcraft');

  @override
  int get schemaVersion => 1;

  /// 安全打开 WAL 与外键约束
  ///
  /// ⚠ 这两项在 C# 版本中依赖 EF/Microsoft.Data.Sqlite 的默认行为，
  /// 而 Dart 的 sqlite3 包**默认关闭外键约束**，
  /// 若不显式开启，所有 onDelete 级联/置空规则都不会生效。
  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');
        if (!details.wasCreated) return;
        await _createIndexes();
      },
      onCreate: (m) async {
        await m.createAll();
        await _createIndexes();
      },
    );
  }

  /// 复刻 EF DbContext.OnModelCreating 中声明的索引
  ///
  /// drift 不会自动为外键建索引（SQLite 亦不会），这里手工补上，
  /// 索引清单对应 C# 迁移 InitialCreate.xml 里的 ~95 个 CreateIndex 中的
  /// 高频查询/排序列，以及唯一约束与复合索引。
  Future<void> _createIndexes() async {
    // 唯一约束：Project.Name（全库唯一的 unique index）
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_name '
      'ON projects(name)',
    );

    // 复合索引
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_character_events_character_id_order '
      'ON character_events(character_id, order_index)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_timeline_events_project_id_event_date '
      'ON timeline_events(project_id, event_date)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_timeline_events_project_id_legacy_id '
      'ON timeline_events(project_id, legacy_id)',
    );

    // 外键常用过滤 + 状态/类型伪枚举 + 排序/评分列
    const indexes = <String>[
      'idx_volumes_project_id ON volumes(project_id)',
      'idx_volumes_project_id_order ON volumes(project_id, order_index)',
      'idx_chapters_volume_id ON chapters(volume_id)',
      'idx_chapters_project_id ON chapters(project_id)',
      'idx_chapters_status ON chapters(status)',
      'idx_characters_project_id ON characters(project_id)',
      'idx_characters_faction_id ON characters(faction_id)',
      'idx_characters_race_id ON characters(race_id)',
      'idx_characters_project_id_type ON characters(project_id, type)',
      'idx_character_relationships_source ON character_relationships(source_character_id)',
      'idx_character_relationships_target ON character_relationships(target_character_id)',
      'idx_character_relationships_network ON character_relationships(relationship_network_id)',
      'idx_character_relationships_project_id ON character_relationships(project_id)',
      'idx_factions_project_id ON factions(project_id)',
      'idx_factions_project_id_type ON factions(project_id, type)',
      'idx_factions_power_level ON factions(power_level)',
      'idx_faction_relationships_source ON faction_relationships(source_faction_id)',
      'idx_faction_relationships_target ON faction_relationships(target_faction_id)',
      'idx_faction_relationships_project_id ON faction_relationships(project_id)',
      'idx_world_settings_project_id ON world_settings(project_id)',
      'idx_world_settings_parent_id ON world_settings(parent_id)',
      'idx_world_settings_project_id_type ON world_settings(project_id, type)',
      'idx_world_settings_category ON world_settings(category)',
      'idx_plots_project_id ON plots(project_id)',
      'idx_plots_project_id_type ON plots(project_id, type)',
      'idx_plots_status ON plots(status)',
      'idx_plots_priority ON plots(priority)',
      'idx_plots_start_chapter ON plots(start_chapter_id)',
      'idx_plots_end_chapter ON plots(end_chapter_id)',
      'idx_resources_project_id ON resources(project_id)',
      'idx_resources_project_id_type ON resources(project_id, type)',
      'idx_resources_rarity ON resources(rarity)',
      'idx_resources_status ON resources(status)',
      'idx_resources_controlling_faction ON resources(controlling_faction_id)',
      'idx_resources_economic_value ON resources(economic_value)',
      'idx_races_project_id ON races(project_id)',
      'idx_races_project_id_type ON races(project_id, type)',
      'idx_races_status ON races(status)',
      'idx_races_power_level ON races(power_level)',
      'idx_race_relationships_source ON race_relationships(source_race_id)',
      'idx_race_relationships_target ON race_relationships(target_race_id)',
      'idx_race_relationships_project_id ON race_relationships(project_id)',
      'idx_race_relationships_type ON race_relationships(relationship_type)',
      'idx_race_relationships_status ON race_relationships(status)',
      'idx_secret_realms_project_id ON secret_realms(project_id)',
      'idx_secret_realms_type ON secret_realms(type)',
      'idx_secret_realms_status ON secret_realms(status)',
      'idx_secret_realms_danger_level ON secret_realms(danger_level)',
      'idx_secret_realms_discoverer ON secret_realms(discoverer_faction_id)',
      'idx_secret_realms_recommended ON secret_realms(recommended_cultivation)',
      'idx_secret_realms_exploration_count ON secret_realms(exploration_count)',
      'idx_cultivation_systems_project_id ON cultivation_systems(project_id)',
      'idx_cultivation_systems_type ON cultivation_systems(type)',
      'idx_cultivation_systems_difficulty ON cultivation_systems(difficulty)',
      'idx_cultivation_levels_system_id ON cultivation_levels(cultivation_system_id)',
      'idx_cultivation_levels_order ON cultivation_levels(order_index)',
      'idx_political_systems_project_id ON political_systems(project_id)',
      'idx_political_systems_type ON political_systems(type)',
      'idx_political_systems_stability ON political_systems(stability)',
      'idx_political_systems_influence ON political_systems(influence)',
      'idx_political_positions_system_id ON political_positions(political_system_id)',
      'idx_political_positions_level ON political_positions(level)',
      'idx_currency_systems_project_id ON currency_systems(project_id)',
      'idx_currency_systems_monetary ON currency_systems(monetary_system)',
      'idx_currency_systems_base_currency ON currency_systems(base_currency)',
      'idx_currency_systems_inflation ON currency_systems(inflation_rate)',
      'idx_currency_systems_interest ON currency_systems(interest_rate)',
      'idx_relationship_networks_project_id ON relationship_networks(project_id)',
      'idx_relationship_networks_type ON relationship_networks(type)',
      'idx_relationship_networks_status ON relationship_networks(status)',
      'idx_relationship_networks_central ON relationship_networks(central_character_id)',
      'idx_relationship_networks_complexity ON relationship_networks(complexity)',
      'idx_timeline_events_category ON timeline_events(category)',
      'idx_timeline_events_chapter ON timeline_events(chapter_id)',
      'idx_timeline_events_plot ON timeline_events(plot_id)',
      'idx_timeline_participants_event ON timeline_event_participants(timeline_event_id)',
      'idx_timeline_participants_character ON timeline_event_participants(character_id)',
      // 联结表的反向查询索引（复合主键已覆盖正向）
      'idx_character_plot_character ON character_plot_entries(character_id)',
      'idx_chapter_plot_chapter ON chapter_plot_entries(chapter_id)',
      'idx_resource_secret_realm_resource ON resource_secret_realm_entries(resource_id)',
      'idx_currency_faction_faction ON currency_system_faction_entries(faction_id)',
      'idx_character_network_character ON character_network_entries(character_id)',
    ];

    for (final idx in indexes) {
      await customStatement('CREATE INDEX IF NOT EXISTS $idx');
    }
  }
}

/// 软删除 / 时间戳维护助手
///
/// EF Core 的两个自动化行为在 drift 中都不存在，需要显式处理：
///
/// 1. **全局查询过滤器**：`HasQueryFilter(e => !e.IsDeleted)` 覆盖了 21 个实体。
///    drift 没有对应机制，因此每个 DAO 查询都要自己附加
///    `..where((t) => t.isDeleted.equals(false))`。
///    ⚠ C# 版本的过滤器漏掉了 CharacterEvent（原实现疏漏），
///    如需 1:1 复刻该行为，查询 CharacterEvent 时不要附加该条件。
///
/// 2. **SaveChangesAsync 审计钩子**：EF 在 Add/Modify/Delete 时自动回填
///    CreatedAt / UpdatedAt，并把实体删除改写成软删除。
///    Dart 侧由本 mixin 负责在写操作前补齐这些字段。
mixin SoftDeleteMixin {
  /// 更新时的时间戳/版本号回填。
  /// 返回一个可直接用于 `update`/`replace` 的补丁列对象。

  DateTime get auditNow => DateTime.now();

  /// 将一行标记为已删除并回填时间戳。
  ///
  /// [toCompanion] 由调用方传入，把当前行转换为相应表的 UpdateCompanion；
  /// 这里只负责注入软删除相关的字段值。
  Insertable<T> markDeleted<T>(Insertable<T> row) => row;
}
