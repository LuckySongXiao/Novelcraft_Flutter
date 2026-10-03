import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../database.dart';
import 'repository_base.dart';

/// [ProjectRepository.createResolvingName] 的创建结果。
///
/// - [renamed]：因存在**活跃**同名项目而追加了 `(2)` 之类后缀；
/// - [revived]：因存在**软删除**同名项目而复活复用了原行（名字不变）。
class ProjectNameResolution {
  const ProjectNameResolution({
    required this.row,
    required this.actualName,
    this.renamed = false,
    this.revived = false,
  });

  final ProjectRow row;
  final String actualName;
  final bool renamed;
  final bool revived;

  /// 是否发生了「用户输入名 ≠ 实际落库名」的调整。
  bool get adjusted => renamed || revived;
}

/// 项目仓储 —— 对应 Infrastructure/Data/Repositories/ProjectRepository.cs
///
/// 注意：Project.Name 在数据库层面有 **唯一约束**（全库唯一的 unique index），
/// 插入同名项目会抛出 SqliteException，调用方需自行处理。
class ProjectRepository extends RepositoryBase {
  static const _table = 'projects';

  /// 级联删除的诊断日志（单表失败只记日志，不拖垮整次删除）。
  static final Logger _logger = Logger('ProjectRepository');

  ProjectRepository(super.db);

  Future<ProjectRow?> getById(String id) {
    return (db.select(db.projects)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<ProjectRow>> getAll() {
    return (db.select(db.projects)
          ..where((t) => notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<ProjectRow> create(ProjectsCompanion companion) async {
    final nowStamp = now;
    final stamped = companion.copyWith(
      createdAt: Value(nowStamp),
      updatedAt: Value(nowStamp),
    );
    return db.into(db.projects).insertReturning(stamped);
  }

  /// 更新指定 id 的行。
  ///
  /// id 以显式参数传入而非从 companion 里取 —— drift 的 UpdateCompanion
  /// 在字段缺失与值为 null 之间用 Value.absent/present 区分，
  /// 直接从 companion 读 id 容易把「未设置」误判成「空值」。
  Future<bool> updateById(String id, ProjectsCompanion companion) async {
    final rows = await (db.update(db.projects)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  /// 软删除（对齐 EF 把 Remove() 改写成 IsDeleted 标记的行为）
  Future<void> delete(String id) => softDeleteRow(_table, id);

  /// 级联删除：项目本体 + **除「角色库」外**的全部关联数据。
  ///
  /// 用户约定：删除项目时与之相关的数据一并删除，但角色库保留
  /// （人物 Characters 及其人物事件 / 人物关系）—— 便于把人物资产复用到新项目。
  ///
  /// ⚠ 实现要点（踩坑修复，2026-09-30「项目无法删除」）：
  /// 1. **先删项目本体**，再逐表级联 —— 旧实现把整条链塞进一个
  ///    `db.transaction`，任何一步 SQL 报错都会整体回滚，表现为
  ///    「点删除毫无反应」；
  /// 2. **不存在的列不能写进批量清单**：`cultivation_levels` /
  ///    `political_positions` **没有 `project_id`**（走 `cultivation_system_id` /
  ///    `political_system_id`），旧实现按 project_id 批量软删直接抛
  ///    `no such column: project_id` → 事务回滚 → 项目删不掉；
  /// 3. **每张表独立 try/catch**：单表失败只记日志，不再拖垮整次删除；
  /// 4. 联结表（ChapterPlotEntries 等无 is_deleted 列）按父表子查询**物理清理**，
  ///    避免留下孤儿关联。
  Future<void> deleteCascade(String projectId) async {
    // ① 项目本体：任何级联失败都不能让项目留在列表里
    await delete(projectId);

    final int ts = now.millisecondsSinceEpoch;

    Future<void> softByProject(String table) async {
      try {
        await softDeleteByProject(table, projectId);
      } on Object catch (e) {
        _logger.warning('级联删除 $table 失败（已跳过）：$e');
      }
    }

    Future<void> softBySubquery(
      String table,
      String whereExpr,
      List<Object?> args,
    ) async {
      try {
        await db.customStatement(
          'UPDATE $table SET is_deleted = 1, deleted_at = ?, updated_at = ? '
          'WHERE is_deleted = 0 AND ($whereExpr)',
          <Object?>[ts, ts, ...args],
        );
        notifyTable(table);
      } on Object catch (e) {
        _logger.warning('级联删除 $table 失败（已跳过）：$e');
      }
    }

    Future<void> hardBySubquery(
      String table,
      String whereExpr,
      List<Object?> args,
    ) async {
      try {
        await db.customStatement(
          'DELETE FROM $table WHERE $whereExpr',
          args,
        );
        notifyTable(table);
      } on Object catch (e) {
        _logger.warning('清理关联表 $table 失败（已跳过）：$e');
      }
    }

    // ② 直接带 project_id 的表（含可空 project_id 的关系表）
    for (final String table in const <String>[
      'volumes', 'chapters', 'plots', 'races', 'race_relationships',
      'resources', 'secret_realms', 'world_settings', 'cultivation_systems',
      'political_systems', 'currency_systems', 'relationship_networks',
      'factions', 'faction_relationships', 'timeline_events',
    ]) {
      await softByProject(table);
    }

    // ③ 无 project_id、按父表子查询级联的表
    await softBySubquery(
      'cultivation_levels',
      'cultivation_system_id IN '
          '(SELECT id FROM cultivation_systems WHERE project_id = ?)',
      <Object?>[projectId],
    );
    await softBySubquery(
      'political_positions',
      'political_system_id IN '
          '(SELECT id FROM political_systems WHERE project_id = ?)',
      <Object?>[projectId],
    );
    await softBySubquery(
      'timeline_event_participants',
      'timeline_event_id IN '
          '(SELECT id FROM timeline_events WHERE project_id = ?)',
      <Object?>[projectId],
    );

    // ④ 联结表（无 is_deleted 列）：按父表子查询物理清理
    await hardBySubquery(
      'chapter_plot_entries',
      'chapter_id IN (SELECT id FROM chapters WHERE project_id = ?) '
          'OR plot_id IN (SELECT id FROM plots WHERE project_id = ?)',
      <Object?>[projectId, projectId],
    );
    await hardBySubquery(
      'character_plot_entries',
      'plot_id IN (SELECT id FROM plots WHERE project_id = ?)',
      <Object?>[projectId],
    );
    await hardBySubquery(
      'resource_secret_realm_entries',
      'resource_id IN (SELECT id FROM resources WHERE project_id = ?) '
          'OR secret_realm_id IN (SELECT id FROM secret_realms WHERE project_id = ?)',
      <Object?>[projectId, projectId],
    );
    await hardBySubquery(
      'currency_system_faction_entries',
      'currency_system_id IN (SELECT id FROM currency_systems WHERE project_id = ?) '
          'OR faction_id IN (SELECT id FROM factions WHERE project_id = ?)',
      <Object?>[projectId, projectId],
    );
    await hardBySubquery(
      'character_network_entries',
      'network_id IN '
          '(SELECT id FROM relationship_networks WHERE project_id = ?)',
      <Object?>[projectId],
    );
  }

  Future<ProjectRow?> getByName(String name) {
    return (db.select(db.projects)
          ..where((t) => t.name.equals(name) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  // -------------------------------------------------------------------------
  // 项目重名解决（UNIQUE constraint failed: projects.name 的根治点）
  // -------------------------------------------------------------------------

  /// 名称是否已被占用 —— ⚠ **含软删除行**。
  ///
  /// `idx_projects_name` 建在整表的 `name` 上（**不是** `WHERE is_deleted = 0`
  /// 的部分索引），所以软删除的项目**仍然占着名字**。只按 [notDeleted] 过滤去
  /// 查重会漏判「删过的同名项目」，插入时直接炸
  /// `SqliteException(2067): UNIQUE constraint failed: projects.name`
  /// —— 表现为「新建项目 / 多智能体写书莫名失败」。
  Future<bool> isNameTaken(String name) async {
    final ProjectRow? row = await (db.select(db.projects)
          ..where((t) => t.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// 取**任意删除状态**下的同名行（供「软删除同名项目复活复用」使用）。
  Future<ProjectRow?> getAnyByName(String name) {
    return (db.select(db.projects)
          ..where((t) => t.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
  }

  /// 在 [desired] 基础上避让重名：`名字` → `名字 (2)` → `名字 (3)` … → `(99)`。
  ///
  /// 兜底路径（99 个都被占用）追加毫秒时间戳，保证一定返回可用名。
  Future<String> resolveAvailableName(String desired) async {
    final String base = desired.trim().isEmpty ? '未命名作品' : desired.trim();
    if (!await isNameTaken(base)) return base;
    for (int i = 2; i <= 99; i++) {
      final String candidate = '$base ($i)';
      if (!await isNameTaken(candidate)) return candidate;
    }
    return '$base (${now.millisecondsSinceEpoch})';
  }

  /// 唯一约束冲突识别（本地库抛 sqlite3 的 `SqliteException`，扩展错误码 2067）。
  static bool isUniqueViolation(Object error) {
    if (error.toString().contains('UNIQUE constraint failed')) return true;
    try {
      final dynamic dyn = error;
      final Object? code = dyn.extendedResultCode;
      if (code is int && code == 2067) return true;
    } on Object {
      // 非 sqlite3 异常：按消息判定即可
    }
    return false;
  }

  /// 创建项目并自动解决重名 —— **推荐入口**（替代裸 [create]）：
  /// - 名字空闲 → 直接插入；
  /// - **软删除的同名项目** → 复活复用该行（改名/描述/设定覆盖为本次输入；
  ///   其关联数据在删除时已被级联清理，语义上等价于新项目）；
  /// - **活跃的同名项目** → 追加序号后缀 `(2)(3)…` 插入，绝不动用户已有项目；
  /// - 极端并发下仍冲突 → 继续尝试下一个序号，绝不把 UNIQUE 异常抛给 UI。
  Future<ProjectNameResolution> createResolvingName(
    ProjectsCompanion companion,
  ) async {
    try {
      final ProjectRow row = await create(companion);
      return ProjectNameResolution(row: row, actualName: row.name);
    } on Object catch (e) {
      if (!isUniqueViolation(e)) rethrow;
    }

    final String desired = companion.name.value;
    final ProjectRow? existing = await getAnyByName(desired);

    if (existing != null && existing.isDeleted) {
      try {
        // ⚠ **不要写 id**：`projects.id` 自身也有唯一约束，把调用方的新 id 塞进
        // 旧行会直接撞 `UNIQUE constraint failed: projects.id`（code 1555），
        // 而该异常消息同样含 "UNIQUE constraint failed"，会被上面的冲突判定
        // 误当成「还是重名」，导致后续补号插入复用同一个 id → 99 次全失败。
        // 复活语义本就该沿用原行 id（返回给调用方时用的也是这个 id）。
        await (db.update(db.projects)..where((t) => t.id.equals(existing.id)))
            .write(ProjectsCompanion(
          name: companion.name,
          type: companion.type,
          description: companion.description,
          settings: companion.settings,
          status: companion.status,
          tags: companion.tags,
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          deletedBy: const Value(null),
          createdAt: Value(now),
          updatedAt: Value(now),
          version: const Value(0),
        ));
        notifyTable(_table);
        final ProjectRow? row = await getById(existing.id);
        if (row != null) {
          return ProjectNameResolution(
            row: row,
            actualName: row.name,
            revived: true,
          );
        }
      } on Object catch (e) {
        _logger.warning('复活软删除同名项目失败，改为追加序号：$e');
      }
    }

    for (int i = 2; i <= 99; i++) {
      final String candidate = '$desired ($i)';
      try {
        final ProjectRow row =
            await create(companion.copyWith(name: Value(candidate)));
        return ProjectNameResolution(
          row: row,
          actualName: row.name,
          renamed: true,
        );
      } on Object catch (e) {
        if (!isUniqueViolation(e)) rethrow;
      }
    }
    throw StateError('项目名「$desired」重名过多（已试到 (99)），请改名后重试');
  }

  Future<List<ProjectRow>> getByStatus(String status) {
    return (db.select(db.projects)
          ..where((t) => t.status.equals(status) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<List<ProjectRow>> getByType(String type) {
    return (db.select(db.projects)
          ..where((t) => t.type.equals(type) & notDeleted(t.isDeleted)))
        .get();
  }

  /// 最近访问的项目（默认 10 条，对应 GetRecentlyAccessedAsync）
  Future<List<ProjectRow>> getRecentlyAccessed({int limit = 10}) {
    return (db.select(db.projects)
          ..where((t) => notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.lastAccessedAt)])
          ..limit(limit))
        .get();
  }

  /// 关键字搜索：匹配名称 / 描述 / 标签
  ///
  /// 可空列直接参与 OR 即可 —— SQL 语义下 `lower(NULL) LIKE '%x%'` 恒为假，
  /// 无需先做判空合并。
  Future<List<ProjectRow>> search(String keyword) {
    if (keyword.trim().isEmpty) return getAll();
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.projects)
          ..where(
            (t) =>
                notDeleted(t.isDeleted) &
                (containsKeyword(t.name, lower) |
                    containsKeyword(t.description, lower) |
                    containsKeyword(t.tags, lower)),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  /// 更新最后访问时间（打卡）
  Future<void> touchLastAccessed(String id) {
    return db.customStatement(
      'UPDATE $_table SET last_accessed_at = ?, updated_at = ? WHERE id = ?',
      [now.millisecondsSinceEpoch, now.millisecondsSinceEpoch, id],
    );
  }

  Future<int> countActive() async {
    final count = db.projects.id.count();
    final row = await (db.selectOnly(db.projects)
          ..addColumns([count])
          ..where(notDeleted(db.projects.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// 观察所有未删除项目（用于 UI 响应式刷新）
  Stream<List<ProjectRow>> watchAll() {
    return (db.select(db.projects)
          ..where((t) => notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .watch();
  }
}
