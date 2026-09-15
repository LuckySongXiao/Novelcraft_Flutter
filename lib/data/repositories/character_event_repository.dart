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

  /// 角色事件无 projectId，提供全量读取供实体页聚合展示。
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
