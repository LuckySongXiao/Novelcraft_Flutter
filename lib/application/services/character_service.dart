// 角色服务
//
// 对应 C# 版 Application/Services/CharacterService.cs。
//
// 与 C# 版差异（务必保留的业务逻辑）：
// 1. **幂等防重**：同项目内「同名 + 性格 + 背景」完全一致的角色自动复用，杜绝 AI
//    生成重复角色。C# 版在 Create 内做此比对；Dart 侧同样在 `create` 内做
//    （Companion 字段为 `Value<T>`，用 `.present` 判空后取 `.value` 比较）。
// 2. **引用检查 / 安全删除**：`checkCharacterReferences` 与 `safeDeleteCharacter`
//    对应 C# 同名方法，弱类型 `CharacterReferenceInfo` 改为强类型
//    [CharacterReferenceInfo] / [CharacterDeleteResult]。C# 检查「角色关系 / 剧情 /
//    所属势力」三类引用；Dart 侧另外补上「履历事件 / 时间线参与者 / 关系网络中心角色」
//    （这些都有独立 Repository 可查），剧情引用经 CharacterPlotEntries 联结表，
//    该联结表当前未暴露 Repository，故不纳入检查。
// 3. 去掉 `try/catch(rethrow)` 模板与 ILogger。
// 4. C# 从 Notes/Tags 文本里解析临时势力/种族名的 hack 属于 AI 落库产物，Dart 侧
//    不保留（角色经 Companion 直接建，无此中间标记）。
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/character_repository.dart';
import 'package:novelcraft/data/repositories/character_event_repository.dart';
import 'package:novelcraft/data/repositories/character_relationship_repository.dart';
import 'package:novelcraft/data/repositories/faction_repository.dart';
import 'package:novelcraft/data/repositories/relationship_network_repository.dart';
import 'package:novelcraft/data/repositories/timeline_event_participant_repository.dart';
import 'package:novelcraft/application/models/stats.dart';

/// 角色服务
class CharacterService {
  CharacterService(
    this._repo, {
    required CharacterEventRepository characterEventRepository,
    required CharacterRelationshipRepository characterRelationshipRepository,
    required FactionRepository factionRepository,
    required RelationshipNetworkRepository relationshipNetworkRepository,
    required TimelineEventParticipantRepository timelineEventParticipantRepository,
  })  : _eventRepo = characterEventRepository,
        _relationshipRepo = characterRelationshipRepository,
        _factionRepo = factionRepository,
        _networkRepo = relationshipNetworkRepository,
        _participantRepo = timelineEventParticipantRepository;

  final CharacterRepository _repo;
  final CharacterEventRepository _eventRepo;
  final CharacterRelationshipRepository _relationshipRepo;
  final FactionRepository _factionRepo;
  final RelationshipNetworkRepository _networkRepo;
  final TimelineEventParticipantRepository _participantRepo;

  /// 归一化描述用于重复比对（null/空白视为空串，去首尾空白）
  static String _norm(String? value) => (value ?? '').trim();

  Future<CharacterRow?> getById(String id) => _repo.getById(id);

  Future<List<CharacterRow>> getByProjectId(String projectId) =>
      _repo.getByProjectId(projectId);

  Future<List<CharacterRow>> getByType(String projectId, String type) =>
      _repo.getByType(projectId, type);

  Future<List<CharacterRow>> getByFactionId(String factionId) =>
      _repo.getByFactionId(factionId);

  Future<List<CharacterRow>> getByImportance(String projectId, int importance) =>
      _repo.getByImportance(projectId, importance);

  Future<List<CharacterRelationshipRow>> getCharacterRelationships(
          String characterId) =>
      _relationshipRepo.getByCharacterId(characterId);

  Future<void> delete(String id) => _repo.delete(id);

  /// 按 id 更新角色。
  ///
  /// C# 版在 CharacterService 里漏了 UpdateAsync（UI 直接改实体后靠
  /// UnitOfWork.SaveChanges 落库），Dart 侧没有变更追踪，必须显式补上。
  Future<bool> updateById(String id, CharactersCompanion companion) =>
      _repo.updateById(id, companion);

  Future<List<CharacterRow>> search(String projectId, String keyword) =>
      _repo.search(projectId, keyword);

  Future<int> countByProject(String projectId) => _repo.countByProject(projectId);

  /// 创建角色；命中「同名 + 性格 + 背景」重复时幂等返回既有角色，不新建。
  Future<CharacterRow> create(CharactersCompanion companion) async {
    final name = companion.name.present ? companion.name.value : null;
    if (name != null && name.trim().isNotEmpty) {
      final existing = await _repo.getByProjectId(
        companion.projectId.present ? companion.projectId.value : '',
      );
      final personality = companion.personality.present
          ? companion.personality.value
          : null;
      final background = companion.background.present
          ? companion.background.value
          : null;
      final duplicate = existing.where((c) =>
          _norm(c.name) == _norm(name) &&
          _norm(c.personality) == _norm(personality) &&
          _norm(c.background) == _norm(background));
      if (duplicate.isNotEmpty) return duplicate.first;
    }
    return _repo.create(companion);
  }

  /// 检查角色被哪些实体引用
  ///
  /// 返回强类型 [CharacterReferenceInfo]，含结构化计数与人类可读描述列表。
  Future<CharacterReferenceInfo> checkCharacterReferences(String characterId) async {
    final references = <String>[];
    var relationshipCount = 0;
    var eventCount = 0;
    var participantCount = 0;
    String? factionName;

    final relationships = await _relationshipRepo.getByCharacterId(characterId);
    if (relationships.isNotEmpty) {
      relationshipCount = relationships.length;
      references.add('存在 $relationshipCount 个角色关系');
    }

    final events = await _eventRepo.getEventsByCharacterId(characterId);
    if (events.isNotEmpty) {
      eventCount = events.length;
      references.add('存在 $eventCount 条履历事件');
    }

    final participants =
        await _participantRepo.getByCharacterId(characterId);
    if (participants.isNotEmpty) {
      participantCount = participants.length;
      references.add('作为参与者出现在 $participantCount 个时间线事件');
    }

    final character = await _repo.getById(characterId);
    if (character?.factionId != null) {
      final faction = await _factionRepo.getById(character!.factionId!);
      if (faction != null) {
        factionName = faction.name;
        references.add('属于势力「${faction.name}」');
      }
    }

    final networks = await _networkRepo.getByCentralCharacter(characterId);
    if (networks.isNotEmpty) {
      references.add('作为 $networks.length 个关系网络的中心角色');
    }

    return CharacterReferenceInfo(
      characterId: characterId,
      isReferenced: references.isNotEmpty,
      references: references,
      relationshipCount: relationshipCount,
      eventCount: eventCount,
      timelineParticipantCount: participantCount,
      factionName: factionName,
    );
  }

  /// 安全删除角色：仅当没有任何引用时才执行软删除。
  Future<CharacterDeleteResult> safeDeleteCharacter(String id) async {
    final character = await _repo.getById(id);
    if (character == null) {
      return const CharacterDeleteResult(
        success: false,
        message: '角色不存在',
      );
    }
    final referenceInfo = await checkCharacterReferences(id);
    if (referenceInfo.isReferenced) {
      return CharacterDeleteResult(
        success: false,
        message: '角色已被引用，无法删除',
        referenceInfo: referenceInfo,
      );
    }
    await _repo.delete(id);
    return const CharacterDeleteResult(
      success: true,
      message: '角色删除成功',
    );
  }

  /// 角色统计（按项目聚合）
  Future<CharacterStats> getStats(String projectId) async {
    final characters = await _repo.getByProjectId(projectId);
    String typeKey(CharacterRow c) => _norm(c.type);
    String genderKey(CharacterRow c) => c.gender?.trim().isEmpty ?? true
        ? '未知'
        : c.gender!.trim();
    String statusKey(CharacterRow c) => _norm(c.status);
    Map<String, int> group(String Function(CharacterRow) key) {
      final map = <String, int>{};
      for (final c in characters) {
        final k = key(c);
        map[k] = (map[k] ?? 0) + 1;
      }
      return map;
    }

    final avgImportance = characters.isEmpty
        ? 0.0
        : characters.fold(0, (sum, c) => sum + c.importance) /
            characters.length;
    return CharacterStats(
      totalCharacters: characters.length,
      typeStatistics: group(typeKey),
      genderStatistics: group(genderKey),
      statusStatistics: group(statusKey),
      mainCharacters: characters.where((c) => c.type == '主角').length,
      supportingCharacters: characters.where((c) => c.type == '配角').length,
      minorCharacters: characters.where((c) => c.type == '龙套').length,
      averageImportance: avgImportance,
    );
  }
}
