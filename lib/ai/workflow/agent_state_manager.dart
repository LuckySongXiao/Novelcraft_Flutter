// 智能体 state 分组管理系统。
//
// 设计（对齐 dispatch_planner 的「纯 Dart + 回调注入」先例，可脱离 Flutter 单测）：
//   * 按「1 组长 + 9 写手」的章节团队分组，1 组 = 10 个**独享** state；
//     每个 state 持有自己的消息日志（system + 累积 user/assistant），
//     组长与写手互不共享，杜绝串号与上下文污染。
//   * 并发数强制为 10 的倍数：10 = 激活 1 个章节团队并行写 1 章，
//     20 = 2 章并行，以此类推（[quantizeConcurrency] 统一量化，
//     便于开发人员从数字直接读出「正在并行几个团队」）。
//   * [snapshot] 输出分组快照（组数 / 状态计数 / 每组活跃成员与轮次），
//     挂 AI 健康页面板，供开发人员判断 state 是否正常。
library;

import 'package:logging/logging.dart';

import '../agents/writer_personas.dart' show kWriterCount, personaForSlot;
import '../models/chat.dart';

/// 智能体在团队中的角色。
enum AgentRole { leader, writer }

/// 单个智能体 state 的状态。
enum AgentStateStatus {
  /// 已创建，尚未发送任何请求。
  idle,

  /// 至少完成一轮对话。
  active,

  /// 组已关闭，state 已释放。
  closed,
}

/// 单个智能体的独享 state。
class AgentStateEntry {
  AgentStateEntry._({
    required this.groupId,
    required this.agentId,
    required this.role,
    required this.slot,
    required this.personaId,
    required int nowMs,
  })  : status = AgentStateStatus.idle,
        turns = 0,
        lastActivityMs = nowMs;

  /// 所属分组 ID。
  final String groupId;

  /// 组内智能体 ID：`leader` / `writer-1` .. `writer-9`。
  final String agentId;

  final AgentRole role;

  /// 槽位：组长 0，写手 1..9。
  final int slot;

  /// 偏向人设 ID（组长为空串）。
  final String personaId;

  /// 独享消息日志（system + 累积 user/assistant），不与任何其它智能体共享。
  final List<ChatMessage> history = <ChatMessage>[];

  AgentStateStatus status;

  /// 完成的对话轮数（一次 user→assistant 记 1 轮）。
  int turns;

  int lastActivityMs;

  bool get isLeader => role == AgentRole.leader;

  bool get isClosed => status == AgentStateStatus.closed;

  Map<String, Object?> toMap() => <String, Object?>{
        'groupId': groupId,
        'agentId': agentId,
        'role': role.name,
        'slot': slot,
        'personaId': personaId,
        'status': status.name,
        'turns': turns,
        'lastActivityMs': lastActivityMs,
        'historyLength': history.length,
      };
}

/// 一个章节团队的 state 分组（恰好 10 个成员）。
class AgentStateGroup {
  AgentStateGroup._({
    required this.groupId,
    required this.label,
    required int nowMs,
  }) : createdAtMs = nowMs;

  final String groupId;
  final String label;
  final int createdAtMs;
  bool active = true;

  final Map<String, AgentStateEntry> _members = <String, AgentStateEntry>{};

  /// 全部成员（组长在前，写手按槽位排序）。
  List<AgentStateEntry> get members => <AgentStateEntry>[
        if (_members['leader'] != null) _members['leader']!,
        ..._members.values
            .where((AgentStateEntry e) => e.role == AgentRole.writer)
            .toList()
          ..sort((AgentStateEntry a, AgentStateEntry b) => a.slot.compareTo(b.slot)),
      ];

  AgentStateEntry? get leader => _members['leader'];

  List<AgentStateEntry> get writers => members
      .where((AgentStateEntry e) => e.role == AgentRole.writer)
      .toList(growable: false);

  int get activeMemberCount =>
      members.where((AgentStateEntry e) => !e.isClosed).length;

  int get totalTurns =>
      members.fold(0, (int sum, AgentStateEntry e) => sum + e.turns);
}

/// 智能体 state 分组管理器。
class AgentStateManager {
  AgentStateManager({Logger? logger, int Function()? clockMs})
      : _logger = logger ?? Logger('AgentStateManager'),
        _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Logger _logger;
  final int Function() _clockMs;

  final Map<String, AgentStateGroup> _groups = <String, AgentStateGroup>{};
  int _groupSeq = 0;

  /// 并发数量化：必须是 10 的倍数（10 = 1 个章节团队）。
  /// 小于 10 抬到 10；非 10 的倍数向下取整到最近的 10 的倍数。
  static int quantizeConcurrency(int n) {
    if (n < 10) return 10;
    return (n ~/ 10) * 10;
  }

  /// 校验：正数且为 10 的倍数。
  static bool isMultipleOfTen(int n) => n > 0 && n % 10 == 0;

  /// 由并发数换算可并行团队数（并发 30 → 3 个团队）。
  static int teamsForConcurrency(int concurrency) =>
      quantizeConcurrency(concurrency) ~/ 10;

  /// 激活一个团队分组：恰好 10 个独享 state（1 组长 + 9 偏向写手）。
  AgentStateGroup activateGroup({String? groupId, String label = ''}) {
    final String id =
        (groupId == null || groupId.trim().isEmpty) ? _nextGroupId() : groupId.trim();
    if (_groups.containsKey(id)) {
      throw StateError('AgentStateGroup already exists: $id');
    }
    final int now = _clockMs();
    final AgentStateGroup group = AgentStateGroup._(
      groupId: id,
      label: label.isEmpty ? id : label,
      nowMs: now,
    );
    group._members['leader'] = AgentStateEntry._(
      groupId: id,
      agentId: 'leader',
      role: AgentRole.leader,
      slot: 0,
      personaId: '',
      nowMs: now,
    );
    for (int slot = 1; slot <= kWriterCount; slot++) {
      group._members['writer-$slot'] = AgentStateEntry._(
        groupId: id,
        agentId: 'writer-$slot',
        role: AgentRole.writer,
        slot: slot,
        personaId: personaForSlot(slot).id,
        nowMs: now,
      );
    }
    _groups[id] = group;
    _logger.info(
        'AgentState 组已激活: ${group.label} ($id)，成员=${group.members.length}（1组长+9写手）');
    return group;
  }

  /// 取分组；不存在返回 null。
  AgentStateGroup? group(String groupId) => _groups[groupId.trim()];

  /// 取某个智能体的独享 state；组或成员不存在抛 StateError（快速暴露编码错误）。
  AgentStateEntry stateOf(String groupId, String agentId) {
    final AgentStateGroup? g = group(groupId);
    if (g == null) {
      throw StateError('AgentStateGroup not found: $groupId');
    }
    final AgentStateEntry? e = g._members[agentId.trim()];
    if (e == null) {
      throw StateError('AgentState not found: $groupId/$agentId');
    }
    return e;
  }

  /// 记录一轮对话（user → assistant）到指定智能体的独享 state。
  void recordTurn({
    required String groupId,
    required String agentId,
    required String userText,
    required String assistantText,
  }) {
    final AgentStateEntry e = stateOf(groupId, agentId);
    if (e.isClosed) {
      throw StateError('AgentState closed: $groupId/$agentId');
    }
    e.history
      ..add(ChatMessage.user(userText))
      ..add(ChatMessage.assistant(assistantText));
    e.turns++;
    e.lastActivityMs = _clockMs();
    e.status = AgentStateStatus.active;
  }

  /// 关闭分组并释放全部 state（防内存膨胀；快照保留 closed 计数）。
  /// 组不存在或已关闭返回 false（幂等）。
  bool closeGroup(String groupId) {
    final AgentStateGroup? g = group(groupId);
    if (g == null || !g.active) return false;
    for (final AgentStateEntry e in g.members) {
      e
        ..history.clear()
        ..status = AgentStateStatus.closed;
    }
    g.active = false;
    _logger.fine('AgentState 组已关闭: $groupId');
    return true;
  }

  /// 关闭全部分组（App 退出 / 服务 dispose 兜底）。
  int closeAll() {
    final List<String> ids = _groups.keys.toList(growable: false);
    for (final String id in ids) {
      closeGroup(id);
    }
    return ids.length;
  }

  int get activeGroupCount =>
      _groups.values.where((AgentStateGroup g) => g.active).length;

  int get totalGroups => _groups.length;

  /// 非关闭态 state 总数。
  int get activeStateCount {
    int n = 0;
    for (final AgentStateGroup g in _groups.values) {
      n += g.activeMemberCount;
    }
    return n;
  }

  /// 开发者诊断快照：判断 state 是否正常的数据源。
  Map<String, Object?> snapshot() {
    final Map<String, int> statusCounts = <String, int>{
      for (final AgentStateStatus s in AgentStateStatus.values) s.name: 0,
    };
    int turns = 0;
    final List<Map<String, Object?>> groups = <Map<String, Object?>>[];
    for (final AgentStateGroup g in _groups.values) {
      for (final AgentStateEntry e in g.members) {
        statusCounts[e.status.name] = (statusCounts[e.status.name] ?? 0) + 1;
        turns += e.turns;
      }
      groups.add(<String, Object?>{
        'groupId': g.groupId,
        'label': g.label,
        'active': g.active,
        'memberCount': g.members.length,
        'activeMembers': g.activeMemberCount,
        'totalTurns': g.totalTurns,
        'members': <Map<String, Object?>>[
          for (final AgentStateEntry e in g.members) e.toMap(),
        ],
      });
    }
    return <String, Object?>{
      'activeGroups': activeGroupCount,
      'totalGroups': totalGroups,
      'activeStates': activeStateCount,
      'statusCounts': statusCounts,
      'totalTurns': turns,
      'groupSize': kWriterCount + 1,
      'groups': groups,
    };
  }

  String _nextGroupId() {
    _groupSeq++;
    return 'team-$_groupSeq';
  }
}
