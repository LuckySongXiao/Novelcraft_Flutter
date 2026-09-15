import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 世界设定仓储 —— 对应 Infrastructure/Data/Repositories/WorldSettingRepository.cs
///
/// 差异：C# 版用 `new string? Version` 隐藏基类行版本字段，Dart 重命名为 settingVersion；
/// Order → orderIndex。
class WorldSettingRepository extends RepositoryBase {
  static const _table = 'world_settings';

  WorldSettingRepository(super.db);

  Future<WorldSettingRow?> getById(String id) {
    return (db.select(db.worldSettings)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<WorldSettingRow>> getByProjectId(String projectId) {
    return (db.select(db.worldSettings)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<WorldSettingRow> create(WorldSettingsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.worldSettings).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, WorldSettingsCompanion companion) async {
    final rows = await (db.update(db.worldSettings)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<WorldSettingRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.worldSettings)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.category,
                t.description,
                t.content,
                t.tags,
                t.notes,
                t.rules
              ], lower))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.worldSettings.id.count();
    final row = await (db.selectOnly(db.worldSettings)
          ..addColumns([count])
          ..where(db.worldSettings.projectId.equals(projectId) &
              notDeleted(db.worldSettings.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<WorldSettingRow>> getByType(String projectId, String type) {
    return (db.select(db.worldSettings)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<WorldSettingRow>> getByCategory(
      String projectId, String category) {
    return (db.select(db.worldSettings)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.category.equals(category) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<WorldSettingRow>> getRootSettings(String projectId) {
    return (db.select(db.worldSettings)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.parentId.isNull() &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<WorldSettingRow>> getChildren(String parentId) {
    return (db.select(db.worldSettings)
          ..where((t) =>
              t.parentId.equals(parentId) & notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<WorldSettingRow>> getByImportance(
      String projectId, int importance) {
    return (db.select(db.worldSettings)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.importance.equals(importance) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
