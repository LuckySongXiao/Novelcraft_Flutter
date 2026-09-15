import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 人物角色仓储 —— 对应 Infrastructure/Data/Repositories/CharacterRepository.cs
class CharacterRepository extends RepositoryBase {
  static const _table = 'characters';

  CharacterRepository(super.db);

  Future<CharacterRow?> getById(String id) {
    return (db.select(db.characters)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<CharacterRow>> getByProjectId(String projectId) {
    return (db.select(db.characters)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<CharacterRow> create(CharactersCompanion companion) async {
    final nowStamp = now;
    return db.into(db.characters).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, CharactersCompanion companion) async {
    final rows = await (db.update(db.characters)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<CharacterRow>> search(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.characters)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.name,
                t.type,
                t.tags,
                t.notes,
                t.background,
                t.personality,
                t.appearance
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.characters.id.count();
    final row = await (db.selectOnly(db.characters)
          ..addColumns([count])
          ..where(db.characters.projectId.equals(projectId) &
              notDeleted(db.characters.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<CharacterRow>> getByType(String projectId, String type) {
    return (db.select(db.characters)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.type.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CharacterRow>> getByFactionId(String factionId) {
    return (db.select(db.characters)
          ..where((t) =>
              t.factionId.equals(factionId) & notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CharacterRow>> getByImportance(
      String projectId, int importance) {
    return (db.select(db.characters)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.importance.equals(importance) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CharacterRow>> getByRaceId(String raceId) {
    return (db.select(db.characters)
          ..where((t) => t.raceId.equals(raceId) & notDeleted(t.isDeleted)))
        .get();
  }
}
