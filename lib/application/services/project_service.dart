// 项目服务
//
// 对应 C# 版 Application/Services/ProjectService.cs。
//
// 与 C# 版的差异：
// 1. 去掉 EF 的 `try { ... } catch (e) { log; rethrow; }` 模板，异常直接上抛由 UI 层统一处理。
// 2. 不持有 ILogger（Dart 侧无对应约定）。
// 3. 项目聚合统计拆分到 [ProjectStatisticsService]，本服务只做项目自身的 CRUD / 查询。
// 4. 仓储已把软删除、审计时间戳、按项目查询等 EF 隐式行为显式落地，这里仅做薄封装。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';

/// 项目管理服务
class ProjectService {
  ProjectService(this._repo);
  final ProjectRepository _repo;

  Future<ProjectRow?> getById(String id) => _repo.getById(id);

  Future<List<ProjectRow>> getAll() => _repo.getAll();

  Future<ProjectRow> create(ProjectsCompanion companion) => _repo.create(companion);

  Future<bool> updateById(String id, ProjectsCompanion companion) =>
      _repo.updateById(id, companion);

  /// 软删除项目（级联删除其子实体由数据库外键完成）
  Future<void> delete(String id) => _repo.delete(id);

  Future<List<ProjectRow>> search(String keyword) => _repo.search(keyword);

  Future<ProjectRow?> getByName(String name) => _repo.getByName(name);

  Future<List<ProjectRow>> getByStatus(String status) => _repo.getByStatus(status);

  Future<List<ProjectRow>> getByType(String type) => _repo.getByType(type);

  Future<List<ProjectRow>> getRecentlyAccessed({int limit = 10}) =>
      _repo.getRecentlyAccessed(limit: limit);

  /// 打卡最后访问时间（进入项目时调用）
  Future<void> touchLastAccessed(String id) => _repo.touchLastAccessed(id);

  Future<int> countActive() => _repo.countActive();
}
