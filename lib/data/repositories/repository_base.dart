import 'package:drift/drift.dart';

import '../database.dart';

/// Repository 基类 —— 承载 C# 侧由 EF 自动完成、但 drift 必须手工处理的行为
///
/// 三个 EF 隐式机制在这里显式落地：
/// 1. **软删除**：EF 把 `Remove()` 改写成 `IsDeleted = true` 的 UPDATE
/// 2. **审计回填**：EF 在 SaveChanges 时按 EntityState 回填 CreatedAt/UpdatedAt
/// 3. **延迟提交**：EF 的 Add/Update/Delete 不落库，由 UnitOfWork.SaveChanges 统一 flush
///    —— 这点在 Dart 侧**有意丢弃**（详见 [UnitOfWork] 注释），改为调用即写入。
abstract class RepositoryBase {
  final AppDatabase db;

  RepositoryBase(this.db);

  DateTime get now => DateTime.now();

  /// 把一行标记为软删除，并回填 deletedAt / updatedAt
  Future<void> softDeleteRow(String tableName, String id) {
    return db.customStatement(
      'UPDATE $tableName SET is_deleted = 1, deleted_at = ?, updated_at = ? '
      'WHERE id = ?',
      [now.millisecondsSinceEpoch, now.millisecondsSinceEpoch, id],
    );
  }

  /// 按 projectId 批量软删除
  Future<void> softDeleteByProject(String tableName, String projectId) {
    return db.customStatement(
      'UPDATE $tableName SET is_deleted = 1, deleted_at = ?, updated_at = ? '
      'WHERE project_id = ? AND is_deleted = 0',
      [now.millisecondsSinceEpoch, now.millisecondsSinceEpoch, projectId],
    );
  }

  /// 物理删除（仅供清理软删数据或 CharacterEvent 等特殊场景使用）
  Future<void> hardDeleteRow(String tableName, String id) {
    return db.customStatement(
      'DELETE FROM $tableName WHERE id = ?',
      [id],
    );
  }

  /// 回填 updatedAt（EF 的 EntityState.Modified 钩子）
  Future<void> touchRow(String tableName, String id) {
    return db.customStatement(
      'UPDATE $tableName SET updated_at = ? WHERE id = ?',
      [now.millisecondsSinceEpoch, id],
    );
  }
}

/// 可参与软删除的查询条件构造帮助函数
///
/// EF 用 `HasQueryFilter(e => !e.IsDeleted)` 全局生效；
/// drift 没有该机制，需要在每个查询里显式追加。
///
/// 用法：
/// ```dart
/// (db.select(db.projects)
///   ..where((t) => notDeleted(t.isDeleted)))
///  .get();
/// ```
Expression<bool> notDeleted(GeneratedColumn<bool> column) =>
    column.equals(false);

/// 关键字搜索的通用谓词（忽略大小写）
///
/// C# 侧对应 `x.ToLower().Contains(lowerKeyword)`，
/// SQLite 上 drift 会把 `.lower()` 下推成 SQL 的 lower()，无需拉到内存。
Expression<bool> containsKeyword(
  GeneratedColumn<String> column,
  String keyword,
) =>
    column.lower().contains(keyword.toLowerCase());

/// 多列 OR 搜索
Expression<bool> searchAnyColumn(
  List<GeneratedColumn<String>> columns,
  String keyword,
) {
  final lower = keyword.toLowerCase();
  Expression<bool> result = const CustomExpression<bool>('1 = 0');
  for (final c in columns) {
    result = result | c.lower().contains(lower);
  }
  return result;
}
