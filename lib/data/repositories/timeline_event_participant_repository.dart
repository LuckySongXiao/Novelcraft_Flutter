import 'package:drift/drift.dart';

import '../database.dart';
import 'repository_base.dart';

/// 时间线事件参与者仓储 —— 对应 Infrastructure/Data/Repositories/TimelineEventParticipantRepository.cs
///
/// 无 projectId，按 timelineEventId / characterId 归属。
class TimelineEventParticipantRepository extends RepositoryBase {
  static const _table = 'timeline_event_participants';

  TimelineEventParticipantRepository(super.db);

  Future<TimelineEventParticipantRow?> getById(String id) {
    return (db.select(db.timelineEventParticipants)
          ..where((t) => t.id.equals(id) & notDeleted(t.isDeleted)))
        .getSingleOrNull();
  }

  Future<TimelineEventParticipantRow> create(
      TimelineEventParticipantsCompanion companion) async {
    final nowStamp = now;
    return db.into(db.timelineEventParticipants).insertReturning(
          companion.copyWith(
            createdAt: Value(nowStamp),
            updatedAt: Value(nowStamp),
          ),
        );
  }

  Future<bool> updateById(
      String id, TimelineEventParticipantsCompanion companion) async {
    final rows = await (db.update(db.timelineEventParticipants)
          ..where((t) => t.id.equals(id)))
        .write(companion.copyWith(updatedAt: Value(now)));
    return rows > 0;
  }

  Future<void> delete(String id) => softDeleteRow(_table, id);

  Future<List<TimelineEventParticipantRow>> getByEventId(String eventId) {
    return (db.select(db.timelineEventParticipants)
          ..where((t) =>
              t.timelineEventId.equals(eventId) & notDeleted(t.isDeleted))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  Future<List<TimelineEventParticipantRow>> getByCharacterId(
      String characterId) {
    return (db.select(db.timelineEventParticipants)
          ..where((t) =>
              t.characterId.equals(characterId) & notDeleted(t.isDeleted)))
        .get();
  }
}
