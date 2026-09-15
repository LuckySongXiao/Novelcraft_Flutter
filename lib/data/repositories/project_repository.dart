import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 项目仓储 —— 对应 Infrastructure/Data/Repositories/ProjectRepository.cs
///
/// 注意：Project.Name 在数据库层面有 **唯一约束**（全库唯一的 unique index），
/// 插入同名项目会抛出 SqliteException，调用方需自行处理。
class ProjectRepository extends RepositoryBase {
  static const _table = 'projects';

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

  Future<ProjectRow?> getByName(String name) {
    return (db.select(db.projects)
          ..where((t) => t.name.equals(name) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
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
