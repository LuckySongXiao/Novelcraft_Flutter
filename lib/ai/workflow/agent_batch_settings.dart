// Agent 攒批配置（P4-28）—— 用户手动指定哪些 Agent 参与攒批、各自归到哪个组。
//
// 纯 Dart、零 Flutter 依赖 ⇒ 可用 `dart run tool/verify_batch_settings.dart` 真跑验证
// （合并/覆盖/分组/往返序列化这些地方很容易写错，且错了不会报错）。
//
// ⚠ 两个必须搞清楚的语义：
//
//  1. **「支持攒批」是能力，不是开关。** 唯一判定依据是
//     `BaseAgent.buildPromptForBatch()` 是否返回非 null。默认返回 null
//     —— 因为批量路由**无状态**（不带 `rwkvSessionId` 的 state 续跑），
//     prompt 必须自包含；拿"拍平参数"的兜底文本去攒批只会**静默降质**。
//     所以本配置只能**关掉**能力，不能**赋予**能力：对未实现该方法的 Agent
//     置 enabled=true 也不会有任何效果（`describe()` 会明确说明）。
//
//  2. **为什么需要分组（`batchGroupId`）**：HANDOFF §28 的原话场景 ——
//     「Director 的 prompt 特别长，不适合和其他短 prompt 一起 batch
//     （会被长 prompt 拖慢整个 batch 的首 token 时间）」。
//     攒批是**同批同速**的：一个长 prompt 会把整批的首 token 时间拉到跟它一样。
//     所以长任务单独成组，短任务归另一个组，两组各发各的。
library;

/// 「未提供小组」哨兵。
///
/// 用来区分 **「不传这个参数」** 与 **「显式传 null（清除分组）」** ——
/// 没有它就没法用 `copyWith`/`update` 清掉一个已设置的分组。
/// 放在顶层是为了让 `di.dart` 等其它库也能引用（私有成员跨库不可见）。
const Object kAgentBatchGroupUnset = Object();

/// 单个 Agent 的攒批配置。
class AgentBatchEntry {
  /// 是否参与攒批。
  ///
  /// ⚠ 这只表示"允许"。该 Agent 若未实现 `buildPromptForBatch`，
  /// 实际仍不会攒批（见文件头注释 1）。
  final bool enabled;

  /// 分组名。相同分组才放同一批；null / 空 = 默认组。
  final String? groupId;

  const AgentBatchEntry({this.enabled = false, this.groupId});

  bool get hasGroup => groupId != null && groupId!.trim().isNotEmpty;

  Map<String, Object?> toMap() => <String, Object?>{
        'enabled': enabled,
        'groupId': groupId,
      };

  factory AgentBatchEntry.fromJson(Map<String, Object?> json) =>
      AgentBatchEntry(
        enabled: (json['enabled'] as bool?) ?? false,
        groupId: json['groupId'] as String?,
      );

  AgentBatchEntry copyWith({bool? enabled, Object? groupId = kAgentBatchGroupUnset}) =>
      AgentBatchEntry(
        enabled: enabled ?? this.enabled,
        groupId: identical(groupId, kAgentBatchGroupUnset)
            ? this.groupId
            : (groupId == null ? null : '$groupId'),
      );

  @override
  String toString() =>
      'AgentBatchEntry(enabled=$enabled, group=${groupId ?? "默认"})';
}

/// 全体 Agent 的攒批配置。
class AgentBatchSettings {
  /// 按 **Agent 名**（不是 id，因为 id 是时间戳、每次启动都变）索引。
  final Map<String, AgentBatchEntry> byAgent;

  const AgentBatchSettings._(this.byAgent);

  /// 空配置（全部关闭 → 与改动前行为完全一致）。
  static const AgentBatchSettings empty = AgentBatchSettings._(
      <String, AgentBatchEntry>{});

  factory AgentBatchSettings(Map<String, AgentBatchEntry> byAgent) =>
      AgentBatchSettings._(Map<String, AgentBatchEntry>.unmodifiable(byAgent));

  bool get isEmpty => byAgent.isEmpty;

  /// 该 Agent 是否被允许攒批（**不代表它有能力**）。
  bool isEnabledFor(String agentName) =>
      byAgent[agentName]?.enabled ?? false;

  /// 该 Agent 的分组（null = 默认组）。
  String? groupIdFor(String agentName) {
    final AgentBatchEntry? e = byAgent[agentName];
    return e != null && e.hasGroup ? e.groupId!.trim() : null;
  }

  /// 已被允许攒批的 Agent 名列表。
  List<String> get enabledAgents => byAgent.entries
      .where((MapEntry<String, AgentBatchEntry> e) => e.value.enabled)
      .map((MapEntry<String, AgentBatchEntry> e) => e.key)
      .toList()
    ..sort();

  /// 分组分布（`groupId → Agent 名列表`），默认组用 `__default__` 表示。
  ///
  /// 用来在 UI 上告诉用户「你其实只开出了一个组」—— 那样攒批和没开差别不大
  /// （同组才合批），这是最常见的配置误解。
  Map<String, List<String>> groupDistribution() {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final MapEntry<String, AgentBatchEntry> e in byAgent.entries) {
      if (!e.value.enabled) continue;
      final String g = e.value.hasGroup ? e.value.groupId!.trim() : defaultGroup;
      out.putIfAbsent(g, () => <String>[]).add(e.key);
    }
    for (final List<String> v in out.values) {
      v.sort();
    }
    return out;
  }

  /// 默认分组名（未指定 groupId 的 Agent 都归它）。
  static const String defaultGroup = '__default__';

  /// 生成一份新配置（不可变更新）。
  AgentBatchSettings withEntry(
    String agentName, {
    bool? enabled,
    Object? groupId = kAgentBatchGroupUnset,
  }) {
    final Map<String, AgentBatchEntry> next =
        Map<String, AgentBatchEntry>.from(byAgent);
    final AgentBatchEntry cur = next[agentName] ?? const AgentBatchEntry();
    next[agentName] = cur.copyWith(enabled: enabled, groupId: groupId);
    return AgentBatchSettings(next);
  }

  AgentBatchSettings withoutAgent(String agentName) {
    final Map<String, AgentBatchEntry> next =
        Map<String, AgentBatchEntry>.from(byAgent)..remove(agentName);
    return AgentBatchSettings(next);
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'version': 1,
        'byAgent': <String, Object?>{
          for (final MapEntry<String, AgentBatchEntry> e in byAgent.entries)
            e.key: e.value.toMap(),
        },
      };

  factory AgentBatchSettings.fromJson(Map<String, Object?> json) {
    final Object? raw = json['byAgent'];
    if (raw is! Map) return empty;
    final Map<String, AgentBatchEntry> out = <String, AgentBatchEntry>{};
    raw.forEach((Object? k, Object? v) {
      if (k is String && v is Map) {
        out[k] = AgentBatchEntry.fromJson(
            v.map((Object? a, Object? b) => MapEntry<String, Object?>('$a', b)));
      }
    });
    return AgentBatchSettings(out);
  }

  /// 依据**实际能力**给出可读的生效结论（UI 直接展示，避免用户误解）。
  ///
  /// [supportsBatch] 是「该 Agent 是否实现了 `buildPromptForBatch`」的判定函数。
  List<String> describe(List<String> allAgentNames,
      bool Function(String agentName) supportsBatch) {
    final List<String> lines = <String>[];
    for (final String name in allAgentNames) {
      final bool allowed = isEnabledFor(name);
      final bool capable = supportsBatch(name);
      if (!allowed && !capable) {
        lines.add('$name：未开启（该 Agent 也未实现批量 prompt）');
      } else if (!allowed && capable) {
        lines.add('$name：可攒批但未开启');
      } else if (allowed && !capable) {
        lines.add('$name：⚠ 已开启但**未实现**批量 prompt → 实际不会攒批，'
            '请覆写 buildPromptForBatch 或关掉');
      } else {
        lines.add('$name：✅ 生效中（分组=${groupIdFor(name) ?? "默认"}）');
      }
    }
    return lines;
  }
}
