// 世界设定服务
//
// 对应 C# 版 Application/Services/WorldSettingService.cs。
//
// 保留的关键业务逻辑（C# `CopyAsync` / `MoveAsync` / 树形装配）：
// 1. `getTree(projectId)`：递归把自引用表装配成树（C# 用导航属性 `Children`，
//    Dart 侧显式按 parentId 构建）。
// 2. `move(id, newParentId)`：改挂父节点，并做基本环检测（不允许挂到自身或自身后代）。
// 3. `copy(id, newName)`：深拷贝一条设定为新节点（沿用原 parentId）。
// 4. 统计从 `Dictionary<string, object>` 改为强类型 [WorldSettingStats]。
// 5. 去掉 `try/catch(rethrow)` 模板。
import 'package:drift/drift.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/world_setting_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 世界设定树节点（递归装配 Children）
class WorldSettingNode {
  WorldSettingNode(this.data, [this.children = const []]);

  final WorldSettingRow data;
  final List<WorldSettingNode> children;
}

/// 世界设定服务
class WorldSettingService {
  WorldSettingService(this._repo);
  final WorldSettingRepository _repo;

  Future<WorldSettingRow?> getById(String id) => _repo.getById(id);

  Future<List<WorldSettingRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<WorldSettingRow> create(WorldSettingsCompanion companion) =>
      _repo.create(companion);

  Future<bool> updateById(String id, WorldSettingsCompanion companion) =>
      _repo.updateById(id, companion);

  Future<void> delete(String id) => _repo.delete(id);

  Future<List<WorldSettingRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  Future<List<WorldSettingRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<List<WorldSettingRow>> getByCategory(String projectId, String category) =>
      _repo.getByCategory(projectId, category);

  Future<List<WorldSettingRow>> getRootSettings(String projectId) =>
      _repo.getRootSettings(projectId);

  /// 递归装配世界设定的树形结构（根节点 parentId 为空）。
  Future<List<WorldSettingNode>> getTree(String projectId) async {
    final all = await _repo.getByProjectId(projectId);
    final byId = {for (final s in all) s.id: s};
    final childrenOf = <String, List<WorldSettingRow>>{};
    final roots = <WorldSettingRow>[];
    for (final s in all) {
      final pid = s.parentId;
      if (pid != null && pid.isNotEmpty && byId.containsKey(pid)) {
        (childrenOf[pid] ??= []).add(s);
      } else {
        roots.add(s);
      }
    }
    List<WorldSettingNode> build(String? parentId) {
      final rows = parentId == null || parentId.isEmpty
          ? roots
          : childrenOf[parentId] ?? <WorldSettingRow>[];
      return [
        for (final row in rows)
          WorldSettingNode(row, build(row.id)),
      ];
    }

    return build(null);
  }

  /// 改挂父节点。禁止把节点挂到自身或其后代之下，避免形成环。
  Future<WorldSettingRow> move(String id, String? newParentId) async {
    if (newParentId != null && newParentId.isNotEmpty && newParentId == id) {
      throw ArgumentError('不能把世界设定挂到自身之下');
    }
    if (newParentId != null && newParentId.isNotEmpty) {
      final descendantIds = await _descendantIds(id);
      if (descendantIds.contains(newParentId)) {
        throw ArgumentError('不能把世界设定挂到自身后代之下');
      }
    }
    final ok = await _repo.updateById(
      id,
      WorldSettingsCompanion(parentId: Value(newParentId)),
    );
    final updated = await _repo.getById(id);
    if (updated == null || !ok) {
      throw StateError('世界设定 $id 不存在或更新失败');
    }
    return updated;
  }

  /// 深拷贝一条世界设定为新节点（沿用原 parentId，仅改名）。
  Future<WorldSettingRow> copy(String id, String newName) async {
    final original = await _repo.getById(id);
    if (original == null) {
      throw ArgumentError('世界设定 $id 不存在');
    }
    final companion = WorldSettingsCompanion(
      name: Value(newName),
      type: Value(original.type),
      category: Value(original.category),
      description: Value(original.description),
      content: Value(original.content),
      rules: Value(original.rules),
      history: Value(original.history),
      relatedSettings: Value(original.relatedSettings),
      importance: Value(original.importance),
      projectId: Value(original.projectId),
      parentId: Value(original.parentId),
      imagePath: Value(original.imagePath),
      tags: Value(original.tags),
      notes: Value(original.notes),
      status: Value(original.status),
      orderIndex: Value(original.orderIndex),
      isPublic: Value(original.isPublic),
      settingVersion: Value(original.settingVersion),
    );
    return _repo.create(companion);
  }

  /// 收集某节点的全部后代 id（含直接/间接）
  Future<Set<String>> _descendantIds(String id) async {
    final result = <String>{};
    final children = await _repo.getChildren(id);
    for (final c in children) {
      result.add(c.id);
      result.addAll(await _descendantIds(c.id));
    }
    return result;
  }

  /// 世界设定统计（按项目聚合，含树最大深度）
  Future<WorldSettingStats> getStats(String projectId) async {
    final tree = await getTree(projectId);
    final all = await _repo.getByProjectId(projectId);
    final typeStats = <String, int>{};
    final categoryStats = <String, int>{};
    for (final s in all) {
      final t = (s.type).trim();
      typeStats[t] = (typeStats[t] ?? 0) + 1;
      final c = (s.category?.trim().isEmpty ?? true) ? '未分类' : s.category!.trim();
      categoryStats[c] = (categoryStats[c] ?? 0) + 1;
    }
    var maxDepth = 0;
    void measure(List<WorldSettingNode> nodes, int depth) {
      if (depth > maxDepth) maxDepth = depth;
      for (final n in nodes) {
        measure(n.children, depth + 1);
      }
    }

    measure(tree, 1);
    return WorldSettingStats(
      totalSettings: all.length,
      typeStatistics: typeStats,
      categoryStatistics: categoryStats,
      rootCount: tree.length,
      maxDepth: maxDepth,
    );
  }
}
