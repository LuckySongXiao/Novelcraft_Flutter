import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 人物关系仓储 —— 对应 Infrastructure/Data/Repositories/CharacterRelationshipRepository.cs
///
/// 差异：新增冗余 projectId 字段（C# 版本需经 Character 二次 JOIN 才能按项目过滤）。
class CharacterRelationshipRepository extends RepositoryBase {
  static const _table = 'character_relationships';

  CharacterRelationshipRepository(super.db);

  Future<CharacterRelationshipRow?> getById(String id) {
    return (db.select(db.characterRelationships)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<CharacterRelationshipRow>> getByProjectId(String projectId) {
    return (db.select(db.characterRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
  }

  Future<CharacterRelationshipRow> create(
      CharacterRelationshipsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.characterRelationships).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, CharacterRelationshipsCompanion companion) async {
    final rows = await (db.update(db.characterRelationships)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<CharacterRelationshipRow>> search(
      String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.characterRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn([
                t.relationshipType,
                t.relationshipName,
                t.description,
                t.tags,
                t.notes
              ], lower)))
        .get();
  }

  Future<int> countByProject(String projectId) async {
    final count = db.characterRelationships.id.count();
    final row = await (db.selectOnly(db.characterRelationships)
          ..addColumns([count])
          ..where(db.characterRelationships.projectId.equals(projectId) &
              notDeleted(db.characterRelationships.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<CharacterRelationshipRow>> getByCharacterId(
      String characterId) {
    return (db.select(db.characterRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              (t.sourceCharacterId.equals(characterId) |
                  t.targetCharacterId.equals(characterId))))
        .get();
  }

  Future<CharacterRelationshipRow?> getByCharacterPair(
      String sourceId, String targetId) {
    return (db.select(db.characterRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.sourceCharacterId.equals(sourceId) &
              t.targetCharacterId.equals(targetId)))
        .getSingleOrNull();
  }

  Future<List<CharacterRelationshipRow>> getByType(
      String projectId, String type) {
    return (db.select(db.characterRelationships)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.relationshipType.equals(type) &
              notDeleted(t.isDeleted)))
        .get();
  }

  Future<List<CharacterRelationshipRow>> getByNetworkId(String networkId) {
    return (db.select(db.characterRelationships)
          ..where((t) =>
              t.relationshipNetworkId.equals(networkId) &
              notDeleted(t.isDeleted)))
        .get();
  }
}
