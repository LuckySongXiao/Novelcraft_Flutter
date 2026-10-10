import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 角色履历事件仓储 —— 对应 Infrastructure/Data/Repositories/CharacterEventRepository.cs
///
/// 差异（对齐 C# 版的已知行为）：
/// 1. C# 版漏把本实体加入软删除全局过滤器，这里 1:1 保留 —— 所有查询**不**附加 notDeleted。
/// 2. 由于查询不过滤软删，软删除实际上不会隐藏数据，因此 delete 改用 hardDeleteRow
///    （基类注释把 CharacterEvent 列为 hardDeleteRow 的特殊场景）。
class CharacterEventRepository extends RepositoryBase {
  static const _table = 'character_events';

  CharacterEventRepository(super.db);

  Future<CharacterEventRow?> getById(String id) {
    return (db.select(db.characterEvents)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<CharacterEventRow> create(CharacterEventsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.characterEvents).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, CharacterEventsCompanion companion) async {
    final rows = await (db.update(db.characterEvents)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  /// 物理删除：软删除查询不生效，故直接硬删。
  Future<void> delete(String id) => hardDeleteRow(_table, id);

  /// 角色事件表**没有** project_id 列（C# 实体没有，见
  /// `content_tables.dart` 的 `CharacterEvents` 注释），所以「本项目的事件」
  /// 只能经 `characters.project_id` 二次 JOIN 得到。
  ///
  /// ⚠ 历史缺陷：实体页与项目导出此前一律走 [getAll]，把**全库**事件都拉了出来
  /// —— 示例项目的种子事件（`demo-ch-linyue / 林月拜入玄穹剑宗`、
  /// `demo-ch-yaohuang / 妖皇破关·兵临剑宗`）于是出现在**每一个项目**的
  /// 「角色事件管理」页与导出目录 `20_人物事件/` 里（用户实测 BUG）。
  /// 作品间隔离必须走本方法。
  Future<List<CharacterEventRow>> getByProjectId(String projectId) {
    return db
        .customSelect(
          'SELECT ce.* FROM character_events ce '
          'INNER JOIN characters c ON c.id = ce.character_id '
          'WHERE c.project_id = ? AND c.is_deleted = 0 '
          'ORDER BY ce.order_index',
          variables: [Variable<String>(projectId)],
          readsFrom: {db.characterEvents, db.characters},
        )
        .map((row) => db.characterEvents.map(row.data))
        .get();
  }

  /// 全量读取。**仅供跨项目场景使用**（迁移、审计、去重）。
  /// 面向「某一个项目」的 UI / 导出一律改用 [getByProjectId]。
  Future<List<CharacterEventRow>> getAll() {
    return (db.select(db.characterEvents)
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<List<CharacterEventRow>> getEventsByCharacterId(String characterId) {
    return (db.select(db.characterEvents)
          ..where((t) => t.characterId.equals(characterId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<List<CharacterEventRow>> getEventsByType(
      String characterId, String eventType) {
    return (db.select(db.characterEvents)
          ..where((t) =>
              t.characterId.equals(characterId) &
              t.eventType.equals(eventType))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  /// 用 raw SQL 逐个更新 orderIndex 以重排事件顺序。
  Future<void> reorderEvents(
      String characterId, List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      await db.customStatement(
        'UPDATE $_table SET order_index = ?, updated_at = ? '
        'WHERE id = ? AND character_id = ?',
        [i, now.millisecondsSinceEpoch, orderedIds[i], characterId],
      );
    }
  }
}
