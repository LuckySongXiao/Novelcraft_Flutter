// 角色履历事件服务
//
// 对应 C# 版 Application/Services（CharacterEvent 在 C# 中由 CharacterService
// 内聚管理；Dart 侧按任务要求拆为独立服务，便于实体页复用统一数据源）。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/character_event_repository.dart';

/// 角色履历事件服务
class CharacterEventService {
  CharacterEventService(this._repo);

  final CharacterEventRepository _repo;

  Future<CharacterEventRow?> getById(String id) => _repo.getById(id);

  Future<CharacterEventRow> create(CharacterEventsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, CharacterEventsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  /// 角色事件无 projectId 列，按项目读取需经 characters 表 JOIN。
  /// 实体页与项目导出走本方法（作品间隔离）；[getAll] 仅供跨项目场景。
  Future<List<CharacterEventRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  /// 全量读取。**仅供跨项目场景使用**，不要用于项目内 UI / 导出。
  Future<List<CharacterEventRow>> getAll() => _repo.getAll();
}
