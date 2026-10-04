import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';
import '../../application/services/chapter_ordering.dart';

/// 章节仓储 —— 对应 Infrastructure/Data/Repositories/ChapterRepository.cs
///
/// 差异：新增冗余 projectId 字段，getByProjectId / countByProject / search 直接按该字段过滤，
/// 不再经 Volume 反查 JOIN（C# 版本需 JOIN）。
class ChapterRepository extends RepositoryBase {
  static const _table = 'chapters';

  ChapterRepository(super.db);

  Future<ChapterRow?> getById(String id) {
    return (db.select(db.chapters)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<List<ChapterRow>> getByProjectId(String projectId) {
    return (db.select(db.chapters)
          ..where((t) =>
              t.projectId.equals(projectId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get()
        .then((List<ChapterRow> chapters) async {
          final List<VolumeRow> volumes = await (db.select(db.volumes)
                ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
              .get();
          return ChapterOrdering.sort(chapters, volumes);
        });
  }

  Future<ChapterRow> create(ChaptersCompanion companion) async {
    final nowStamp = now;
    return db.into(db.chapters).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(String id, ChaptersCompanion companion) async {
    final rows = await (db.update(db.chapters)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<ChapterRow>> searchInProject(String projectId, String keyword) {
    if (keyword.trim().isEmpty) return getByProjectId(projectId);
    final lower = keyword.trim().toLowerCase();
    return (db.select(db.chapters)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              t.projectId.equals(projectId) &
              searchAnyColumn(
                  [t.title, t.summary, t.content, t.type, t.tags, t.notes],
                  lower))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get()
        .then((List<ChapterRow> chapters) async {
          final List<VolumeRow> volumes = await (db.select(db.volumes)
                ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
              .get();
          return ChapterOrdering.sort(chapters, volumes);
        });
  }

  Future<List<ChapterRow>> search(String projectId, String keyword) =>
      searchInProject(projectId, keyword);

  Future<int> countByProject(String projectId) async {
    final count = db.chapters.id.count();
    final row = await (db.selectOnly(db.chapters)
          ..addColumns([count])
          ..where(db.chapters.projectId.equals(projectId) &
              notDeleted(db.chapters.isDeleted)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<ChapterRow>> getByVolumeId(String volumeId) {
    return (db.select(db.chapters)
          ..where((t) =>
              t.volumeId.equals(volumeId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<List<ChapterRow>> getByStatus(String projectId, String status) {
    return (db.select(db.chapters)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.status.equals(status) &
              notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get()
        .then((List<ChapterRow> chapters) async {
          final List<VolumeRow> volumes = await (db.select(db.volumes)
                ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
              .get();
          return ChapterOrdering.sort(chapters, volumes);
        });
  }

  Future<int> getNextOrderIndex(String volumeId) async {
    final maxOrder = db.chapters.orderIndex.max();
    final row = await (db.selectOnly(db.chapters)
          ..addColumns([maxOrder])
          ..where(db.chapters.volumeId.equals(volumeId) &
              notDeleted(db.chapters.isDeleted)))
        .getSingleOrNull();
    final max = row?.read(maxOrder);
    return (max ?? -1) + 1;
  }

  Future<bool> updateOrder(String chapterId, int newIndex) async {
    final rows = await (db.update(db.chapters)
          ..where((t) => t.id.equals(chapterId)))
        .write(ChaptersCompanion(
          orderIndex: Value(newIndex),
          updatedAt: Value(now),
        ));
    return rows > 0;
  }
}
