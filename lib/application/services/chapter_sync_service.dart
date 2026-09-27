// 章节落库后的「规则同步」—— 1:1 移植 C# `ChapterContentSyncService` +
// `ChapterUpdateWorkflowService`（时间线部分），零模型调用。
//
// 同步面（对齐 C#）：
//   人物      History/KeyEvents 追加、首末出场章节回填、CharacterEvent 按章 upsert
//   势力      MemberCount 重算、History/Notes 追加
//   人物关系  同章两两配对：缺失则建「同章互动」，已有则 History/KeyEvents/Impact 追加
//   剧情      涉及章节挂接、Start/End 章节回填、ActualWordCount/进度/状态推进
//             （剧情进度与状态属于剧情自身的业务字段，**不动章节 status**）
//   世界设定  Content/History 追加
//   势力关系  章节势力两两配对：缺失则建「章节互动」，已有则追加
//   时间线    「剧情事件」按 chapterId upsert + 参与者重建（角色+势力）
//
// 安全设计：
//   * 只追加备注/历史类字段 + 剧情进度；**绝不改写章节 status**（硬约束）
//   * 名字匹配收紧：候选名长度 ≥ 2 才参与 contains 匹配（C# 子串匹配的误伤面）
//   * 全部幂等：History 追加前去重；事件/时间线按 chapterId upsert
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/database.dart';
import '../../data/repositories/repository_base.dart' show notDeleted;

/// 同步输入（由落库出口组装，避免依赖 ChapterRow 完整生命周期）。
class ChapterSyncInput {
  const ChapterSyncInput({
    required this.chapterId,
    required this.volumeId,
    required this.title,
    required this.orderIndex,
    required this.content,
    this.projectId = '',
    this.summary,
    this.tags,
    this.notes,
    this.status = 'Draft',
    this.versionNumber = 1,
    this.eventDate,
    this.characterHints = const <String>{},
  });

  final String chapterId;
  final String volumeId;
  final String projectId;
  final String title;
  final int orderIndex;

  /// 处理后的正文（改写后 / 新生成）。
  final String content;
  final String? summary;
  final String? tags;
  final String? notes;

  /// 仅用于时间线事件状态映射（含「完成」→ 已完成），不回写章节。
  final String status;

  /// 落库后的业务版本号（防重：同章同版本不重复同步）。
  final int versionNumber;
  final DateTime? eventDate;

  /// 关联改稿时可带上作者指名的人物提示（对应 C# relatedCharactersText）。
  final Set<String> characterHints;
}

/// 同步计数。
class ChapterSyncCounts {
  const ChapterSyncCounts({
    this.characters = 0,
    this.factions = 0,
    this.plots = 0,
    this.settings = 0,
    this.characterRelationships = 0,
    this.factionRelationships = 0,
    this.timelineEvents = 0,
  });

  final int characters;
  final int factions;
  final int plots;
  final int settings;
  final int characterRelationships;
  final int factionRelationships;
  final int timelineEvents;

  int get total =>
      characters +
      factions +
      plots +
      settings +
      characterRelationships +
      factionRelationships +
      timelineEvents;

  @override
  String toString() =>
      '人物 $characters · 势力 $factions · 剧情 $plots · 设定 $settings · '
      '人物关系 $characterRelationships · 势力关系 $factionRelationships · '
      '时间线 $timelineEvents';
}

/// 同步结果；[skippedReason] 非 null 表示本次未执行（机器码）。
class ChapterSyncOutcome {
  const ChapterSyncOutcome._({
    required this.applied,
    required this.counts,
    this.updatedCharacterNames = const <String>[],
    this.updatedFactionNames = const <String>[],
  })   : skippedReason = null;

  const ChapterSyncOutcome.skipped(this.skippedReason)
      : applied = false,
        counts = const ChapterSyncCounts(),
        updatedCharacterNames = const <String>[],
        updatedFactionNames = const <String>[];

  final bool applied;
  final ChapterSyncCounts counts;
  final List<String> updatedCharacterNames;
  final List<String> updatedFactionNames;

  /// 机器码：`noProject` / `emptyContent` / `alreadySynced` / `error:{0}`。
  final String? skippedReason;
}

/// 规则同步服务 —— 见文件头。
class ChapterSyncService {
  ChapterSyncService({required AppDatabase db}) : _db = db;

  static const Uuid _uuid = Uuid();

  final AppDatabase _db;

  Future<ChapterSyncOutcome> sync(ChapterSyncInput input) async {
    try {
      return await _sync(input);
    } on Object catch (e) {
      // 同步是章节保存的**后处理**：任何异常都不允许冒泡炸掉保存流程
      return ChapterSyncOutcome.skipped('error:$e');
    }
  }

  Future<ChapterSyncOutcome> _sync(ChapterSyncInput input) async {
    // ---- 0. 项目定位：chapter.projectId 缺失时经卷宗反查（对齐 C# 经 Volume 反查）----
    String projectId = input.projectId.trim();
    if (projectId.isEmpty && input.volumeId.trim().isNotEmpty) {
      final VolumeRow? volume = await (_db.select(_db.volumes)
            ..where((t) => t.id.equals(input.volumeId) & notDeleted(t.isDeleted)))
          .getSingleOrNull();
      projectId = volume?.projectId ?? '';
    }
    if (projectId.isEmpty) return const ChapterSyncOutcome.skipped('noProject');
    if (input.content.trim().isEmpty && (input.summary ?? '').trim().isEmpty) {
      return const ChapterSyncOutcome.skipped('emptyContent');
    }

    // ---- 1. 全局章节序（按卷序 + 章序，供首末出场/剧情首末章换算）----
    final List<ChapterRow> chapters = await (_db.select(_db.chapters)
          ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
    final List<VolumeRow> volumes = await (_db.select(_db.volumes)
          ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
    final Map<String, int> volumeOrder = <String, int>{
      for (final VolumeRow v in volumes) v.id: v.orderIndex,
    };
    chapters.sort((ChapterRow a, ChapterRow b) {
      final int va = volumeOrder[a.volumeId] ?? 1 << 30;
      final int vb = volumeOrder[b.volumeId] ?? 1 << 30;
      return (va - vb) != 0 ? va - vb : a.orderIndex - b.orderIndex;
    });
    final Map<String, int> orderLookup = <String, int>{
      for (int i = 0; i < chapters.length; i++) chapters[i].id: i,
    };
    final Map<String, ChapterRow> chapterById = <String, ChapterRow>{
      for (final ChapterRow c in chapters) c.id: c,
    };

    final String context = <String>[
      input.title,
      input.summary ?? '',
      input.content,
      input.tags ?? '',
      input.notes ?? '',
    ].where((String s) => s.trim().isNotEmpty).join('\n');
    final String summaryText = _summaryText(input);
    final String marker = '第${input.orderIndex + 1}章《${input.title}》';
    final DateTime now = DateTime.now();

    // ---- 2. 人物 ----
    final List<CharacterRow> characters = await (_db.select(_db.characters)
          ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
    final List<CharacterRow> matchedCharacters = <CharacterRow>[
      for (final CharacterRow c in characters)
        if (_isCharacterMatched(c, context, input.characterHints)) c,
    ];
    final int currentOrder = orderLookup[input.chapterId] ?? 1 << 30;
    for (final CharacterRow c in matchedCharacters) {
      final String entry = '$marker：$summaryText';
      // 首末出场章节（对齐 C# UpdateAppearanceRange）
      // ⚠ firstOrder 为 null 有两种含义：①从未设定首出场 → 应设本章；
      // ②首出场章节已被删除（orderLookup 查不到）→ **保持原值不动**，
      //   否则本章会误抢首出场（last 侧用 -(1<<30) 兜底自愈，属可接受）。
      final String? firstId = c.firstAppearanceChapterId;
      final int? firstOrder =
          firstId != null ? orderLookup[firstId] : null;
      final String firstAppearance = firstId == null
          ? input.chapterId
          : (firstOrder != null && currentOrder < firstOrder
              ? input.chapterId
              : firstId);
      final int lastOrder = c.lastAppearanceChapterId != null
          ? (orderLookup[c.lastAppearanceChapterId!] ?? -(1 << 30))
          : -(1 << 30);
      final String? lastAppearance = currentOrder >= lastOrder
          ? input.chapterId
          : c.lastAppearanceChapterId;

      await (_db.update(_db.characters)..where((t) => t.id.equals(c.id))).write(
        CharactersCompanion(
          history: Value(_appendUnique(c.history, entry)),
          keyEvents: Value(_appendUnique(c.keyEvents, entry)),
          firstAppearanceChapterId: Value(firstAppearance),
          lastAppearanceChapterId: Value(lastAppearance),
          updatedAt: Value(now),
        ),
      );

      // 角色履历事件：按 (characterId, chapterId) upsert
      final List<CharacterEventRow> events = await (_db.select(_db.characterEvents)
            ..where((t) => t.characterId.equals(c.id)))
          .get();
      final CharacterEventRow? existing = events
          .where((CharacterEventRow e) => e.chapterId == input.chapterId)
          .firstOrNull;
      if (existing == null) {
        await _db.into(_db.characterEvents).insert(
              CharacterEventsCompanion.insert(
                id: _uuid.v4(),
                characterId: c.id,
                title: marker,
                description: Value(summaryText),
                eventType: const Value('章节更新'),
                storyTime: Value(marker),
                orderIndex: Value(events.length),
                chapterId: Value(input.chapterId),
                tags: Value(input.tags ?? c.tags),
              ),
            );
      } else {
        await (_db.update(_db.characterEvents)
              ..where((t) => t.id.equals(existing.id)))
            .write(CharacterEventsCompanion(
          title: Value(marker),
          description: Value(summaryText),
          storyTime: Value(marker),
          tags: Value(input.tags ?? existing.tags),
          updatedAt: Value(now),
        ));
      }
    }

    // ---- 3. 势力 ----
    final List<FactionRow> factions = await (_db.select(_db.factions)
          ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
    final Set<String> factionIdsFromCharacters = <String>{
      for (final CharacterRow c in matchedCharacters)
        if (c.factionId != null) c.factionId!,
    };
    final List<FactionRow> matchedFactions = <FactionRow>[
      for (final FactionRow f in factions)
        if (factionIdsFromCharacters.contains(f.id) || _contains(context, f.name)) f,
    ];
    for (final FactionRow f in matchedFactions) {
      final List<CharacterRow> members = await (_db.select(_db.characters)
            ..where((t) =>
                t.factionId.equals(f.id) & notDeleted(t.isDeleted)))
          .get();
      final bool mentionedInText = _contains(context, f.name);
      await (_db.update(_db.factions)..where((t) => t.id.equals(f.id))).write(
        FactionsCompanion(
          memberCount: Value(members.length),
          // 噪音收紧：只有正文**确实提到**势力名才追加历史/备注——
          // 「出场角色所属势力」每章必触发追加，会把 notes 刷成噪音墙
          history: Value(mentionedInText
              ? _appendUnique(f.history, '$marker：$summaryText')
              : f.history),
          notes: Value(mentionedInText
              ? _appendUnique(f.notes, '$marker：同步更新')
              : f.notes),
          updatedAt: Value(now),
        ),
      );
    }

    // ---- 4. 人物关系（同章两两配对）----
    final List<CharacterRow> uniqueCharacters = <String, CharacterRow>{
      for (final CharacterRow c in matchedCharacters) c.id: c,
    }.values.toList()
      ..sort((CharacterRow a, CharacterRow b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    int charRelCount = 0;
    for (int i = 0; i < uniqueCharacters.length - 1; i++) {
      for (int j = i + 1; j < uniqueCharacters.length; j++) {
        final CharacterRow a = uniqueCharacters[i];
        final CharacterRow b = uniqueCharacters[j];
        final CharacterRelationshipRow? rel =
            await _characterPair(a.id, b.id);
        final String entry = '$marker：$summaryText';
        if (rel == null) {
          await _db.into(_db.characterRelationships).insert(
                CharacterRelationshipsCompanion.insert(
                  id: _uuid.v4(),
                  sourceCharacterId: a.id,
                  targetCharacterId: b.id,
                  relationshipType: '同章互动',
                  relationshipName: Value('${a.name}-${b.name}'),
                  description: Value('$marker 中发生了新的同章互动。'),
                  developmentHistory: Value(entry),
                  keyEvents: Value(entry),
                  impact: const Value('由章节保存后的自动更新工艺同步生成'),
                  importance: Value(a.importance > b.importance ? a.importance : b.importance),
                  intensity: const Value(5),
                  startDate: Value(now),
                  projectId: Value(projectId),
                ),
              );
        } else {
          await (_db.update(_db.characterRelationships)
                ..where((t) => t.id.equals(rel.id)))
              .write(CharacterRelationshipsCompanion(
            description: Value('$marker 中发生了新的同章互动。'),
            developmentHistory:
                Value(_appendUnique(rel.developmentHistory, entry)),
            keyEvents: Value(_appendUnique(rel.keyEvents, entry)),
            impact: Value(
                _appendUnique(rel.impact, '$marker：关系随章节推进自动更新')),
            importance: Value(_maxOf(rel.importance, a.importance, b.importance)),
            intensity: Value(rel.intensity < 5
                ? 5
                : (rel.intensity > 10 ? 10 : rel.intensity)),
            updatedAt: Value(now),
          ));
        }
        charRelCount++;
      }
    }

    // ---- 5. 剧情 ----
    final List<PlotRow> plots = await (_db.select(_db.plots)
          ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
    final List<PlotRow> matchedPlots = <PlotRow>[
      for (final PlotRow p in plots)
        if (_contains(context, p.title)) p,
    ];
    for (final PlotRow p in matchedPlots) {
      final List<ChapterPlotEntry> entries = await (_db.select(
              _db.chapterPlotEntries)
            ..where((t) => t.plotId.equals(p.id)))
          .get();
      final Set<String> involvedIds = <String>{for (final e in entries) e.chapterId}
        ..add(input.chapterId);
      final List<String> ordered = involvedIds
          .where(orderLookup.containsKey)
          .toList()
        ..sort((String x, String y) => orderLookup[x]! - orderLookup[y]!);
      if (!entries.any((ChapterPlotEntry e) => e.chapterId == input.chapterId)) {
        await _db.into(_db.chapterPlotEntries).insert(
              ChapterPlotEntriesCompanion.insert(
                plotId: p.id,
                chapterId: input.chapterId,
              ),
            );
      }
      final List<ChapterRow> involvedChapters = <ChapterRow>[
        for (final String id in ordered)
          if (chapterById[id] != null) chapterById[id]!,
      ];
      // ⚠ wordCount 兜底：章节表单的「字数」靠手填，多数章节是 0 ——
      // 不兜底会让 actualWords 恒 0、剧情进度永远不动（状态更新的最大暗坑）。
      // content 长度是唯一可靠的落库事实。
      final int actualWords = involvedChapters.fold(0,
          (int sum, ChapterRow c) => sum + (c.wordCount > 0
              ? c.wordCount
              : (c.content?.length ?? 0)));
      final int estimated = p.estimatedWordCount ?? 0;
      double progress;
      if (estimated > 0) {
        progress = (actualWords * 100 / estimated).clamp(0.0, 100.0);
      } else {
        final double inferred = involvedChapters.length * 20.0;
        progress = p.progress > inferred
            ? (p.progress > 100 ? 100 : p.progress)
            : (inferred > 100 ? 100 : inferred);
      }
      String status = p.status;
      // 状态推进保护：达标时只把「规划中/进行中」推进为「已完成」，
      // 不动用户手动设置的「暂停」等状态——自动更新不得覆盖人工意图。
      const autoAdvancable = <String>{'规划中', '进行中'};
      if (progress >= 100 && autoAdvancable.contains(status)) {
        status = '已完成';
      } else if (status == '规划中') {
        status = '进行中';
      }
      await (_db.update(_db.plots)..where((t) => t.id.equals(p.id))).write(
        PlotsCompanion(
          startChapterId: Value(ordered.isEmpty ? p.startChapterId : ordered.first),
          endChapterId: Value(ordered.isEmpty ? p.endChapterId : ordered.last),
          actualWordCount: Value(actualWords),
          progress: Value(progress),
          status: Value(status),
          updatedAt: Value(now),
        ),
      );
    }

    // ---- 6. 世界设定 ----
    final List<WorldSettingRow> settings = await (_db.select(_db.worldSettings)
          ..where((t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted)))
        .get();
    final List<WorldSettingRow> matchedSettings = <WorldSettingRow>[
      for (final WorldSettingRow s in settings)
        if (_contains(context, s.name)) s,
    ];
    for (final WorldSettingRow s in matchedSettings) {
      await (_db.update(_db.worldSettings)..where((t) => t.id.equals(s.id))).write(
        WorldSettingsCompanion(
          content: Value(_appendUnique(s.content, '$marker：$summaryText')),
          history: Value(_appendUnique(s.history, '$marker：章节推进同步')),
          updatedAt: Value(now),
        ),
      );
    }

    // ---- 7. 势力关系（章节势力两两配对）----
    final Map<String, FactionRow> factionById = <String, FactionRow>{
      for (final FactionRow f in factions) f.id: f,
    };
    final List<FactionRow> chapterFactions = <String, FactionRow>{
      for (final FactionRow f in matchedFactions) f.id: f,
      for (final CharacterRow c in matchedCharacters)
        if (c.factionId != null && factionById.containsKey(c.factionId))
          c.factionId!: factionById[c.factionId!]!,
    }.values.toList()
      ..sort((FactionRow a, FactionRow b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    int factionRelCount = 0;
    for (int i = 0; i < chapterFactions.length - 1; i++) {
      for (int j = i + 1; j < chapterFactions.length; j++) {
        final FactionRow a = chapterFactions[i];
        final FactionRow b = chapterFactions[j];
        final FactionRelationshipRow? rel = await _factionPair(a.id, b.id);
        final String entry = '$marker：$summaryText';
        if (rel == null) {
          await _db.into(_db.factionRelationships).insert(
                FactionRelationshipsCompanion.insert(
                  id: _uuid.v4(),
                  sourceFactionId: a.id,
                  targetFactionId: b.id,
                  relationshipType: '章节互动',
                  relationshipName: Value('${a.name}-${b.name}'),
                  description: Value('$marker 中两方产生了新的章节关联。'),
                  developmentHistory: Value(entry),
                  keyEvents: Value(entry),
                  impact: const Value('由章节保存后的自动更新工艺同步生成'),
                  importance: Value(a.importance > b.importance ? a.importance : b.importance),
                  intensity: const Value(5),
                  startDate: Value(now),
                  projectId: Value(projectId),
                ),
              );
        } else {
          await (_db.update(_db.factionRelationships)
                ..where((t) => t.id.equals(rel.id)))
              .write(FactionRelationshipsCompanion(
            description: Value('$marker 中两方产生了新的章节关联。'),
            developmentHistory:
                Value(_appendUnique(rel.developmentHistory, entry)),
            keyEvents: Value(_appendUnique(rel.keyEvents, entry)),
            impact: Value(_appendUnique(
                rel.impact, '$marker：势力关系随章节推进自动更新')),
            importance: Value(_maxOf(rel.importance, a.importance, b.importance)),
            intensity: Value(rel.intensity < 5
                ? 5
                : (rel.intensity > 10 ? 10 : rel.intensity)),
            updatedAt: Value(now),
          ));
        }
        factionRelCount++;
      }
    }

    // ---- 8. 时间线（「剧情事件」按 chapterId upsert + 参与者重建）----
    final List<TimelineEventRow> existingTimeline = await (_db.select(
            _db.timelineEvents)
          ..where((t) =>
              t.projectId.equals(projectId) &
              t.chapterId.equals(input.chapterId) &
              notDeleted(t.isDeleted)))
        .get();
    final TimelineEventRow? existingEvent = existingTimeline.firstOrNull;
    final int total = matchedCharacters.length +
        matchedFactions.length +
        matchedPlots.length +
        matchedSettings.length +
        charRelCount +
        factionRelCount;
    final String tlImportance = total >= 8
        ? '极高'
        : total >= 5
            ? '高'
            : total >= 2
                ? '中'
                : '低';
    final String tlStatus =
        input.status.contains('完成') ? '已完成' : '进行中';
    final String impact = '人物 ${matchedCharacters.length}；势力 ${matchedFactions.length}；'
        '剧情 ${matchedPlots.length}；设定 ${matchedSettings.length}；'
        '人物关系 $charRelCount；势力关系 $factionRelCount';
    String eventId;
    if (existingEvent == null) {
      eventId = _uuid.v4();
      await _db.into(_db.timelineEvents).insert(
            TimelineEventsCompanion.insert(
              id: eventId,
              projectId: projectId,
              title: input.title.trim().isEmpty ? '未命名章节' : input.title,
              category: const Value('剧情事件'),
              eventDate: input.eventDate ?? now,
              location: Value(marker),
              importance: Value(tlImportance),
              status: Value(tlStatus),
              description: Value(summaryText),
              impact: Value(impact),
              chapterId: Value(input.chapterId),
            ),
          );
    } else {
      eventId = existingEvent.id;
      await (_db.update(_db.timelineEvents)
            ..where((t) => t.id.equals(eventId)))
          .write(TimelineEventsCompanion(
        title: Value(input.title.trim().isEmpty ? '未命名章节' : input.title),
        category: const Value('剧情事件'),
        eventDate: Value(input.eventDate ?? now),
        location: Value(marker),
        importance: Value(tlImportance),
        status: Value(tlStatus),
        description: Value(summaryText),
        impact: Value(impact),
      ));
    }

    // 参与者：全量重建（对齐 C# 的整体替换语义；派生数据，物删无妨）
    await (_db.delete(_db.timelineEventParticipants)
          ..where((t) => t.timelineEventId.equals(eventId)))
        .go();
    final Set<String> seen = <String>{};
    int participantOrder = 0;
    for (final CharacterRow c in matchedCharacters) {
      final String key = '角色:${c.name.toLowerCase()}';
      if (!seen.add(key)) continue;
      await _db.into(_db.timelineEventParticipants).insert(
            TimelineEventParticipantsCompanion.insert(
              id: _uuid.v4(),
              timelineEventId: eventId,
              name: c.name,
              type: const Value('角色'),
              role: const Value('章节参与者'),
              characterId: Value(c.id),
              orderIndex: Value(participantOrder++),
            ),
          );
    }
    for (final FactionRow f in matchedFactions) {
      final String key = '势力:${f.name.toLowerCase()}';
      if (!seen.add(key)) continue;
      await _db.into(_db.timelineEventParticipants).insert(
            TimelineEventParticipantsCompanion.insert(
              id: _uuid.v4(),
              timelineEventId: eventId,
              name: f.name,
              type: const Value('势力'),
              role: const Value('章节关联势力'),
              orderIndex: Value(participantOrder++),
            ),
          );
    }

    return ChapterSyncOutcome._(
      applied: true,
      counts: ChapterSyncCounts(
        characters: matchedCharacters.length,
        factions: matchedFactions.length,
        plots: matchedPlots.length,
        settings: matchedSettings.length,
        characterRelationships: charRelCount,
        factionRelationships: factionRelCount,
        timelineEvents: 1,
      ),
      updatedCharacterNames: <String>[
        for (final CharacterRow c in matchedCharacters)
          if (c.name.trim().isNotEmpty) c.name,
      ],
      updatedFactionNames: <String>[
        for (final FactionRow f in matchedFactions)
          if (f.name.trim().isNotEmpty) f.name,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 私有工具
  // ---------------------------------------------------------------------------

  Future<CharacterRelationshipRow?> _characterPair(String a, String b) async {
    // ⚠ 用 get()+firstOrNull 而非 getSingleOrNull：历史脏数据（同一对
    // 存在双向重复记录）会让 getSingleOrNull 抛 StateError，炸掉整条
    // 同步链（剧情/时间线全部停摆）——取第一条即可，脏数据容错。
    final List<CharacterRelationshipRow> rows = await (_db.select(
            _db.characterRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              ((t.sourceCharacterId.equals(a) & t.targetCharacterId.equals(b)) |
                  (t.sourceCharacterId.equals(b) &
                      t.targetCharacterId.equals(a)))))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<FactionRelationshipRow?> _factionPair(String a, String b) async {
    // 同 _characterPair：脏数据容错，取第一条
    final List<FactionRelationshipRow> rows = await (_db.select(
            _db.factionRelationships)
          ..where((t) =>
              notDeleted(t.isDeleted) &
              ((t.sourceFactionId.equals(a) & t.targetFactionId.equals(b)) |
                  (t.sourceFactionId.equals(b) &
                      t.targetFactionId.equals(a)))))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  static bool _isCharacterMatched(
      CharacterRow character, String context, Set<String> hints) {
    final String name = character.name.trim();
    // 误伤收紧：单字名不参与 contains 匹配（「影」「云」这类会满篇命中）
    if (hints.contains(character.name)) return true;
    if (name.length < 2) return false;
    return _contains(context, name);
  }

  /// 对齐 C# `BuildSummaryText`：梗概优先，其次正文前 120 字。
  static String _summaryText(ChapterSyncInput input) {
    final String? summary = input.summary?.trim();
    if (summary != null && summary.isNotEmpty) return summary;
    final String content = input.content.trim();
    if (content.isNotEmpty) {
      return content.length > 120 ? content.substring(0, 120) : content;
    }
    return '章节内容已更新';
  }

  /// 对齐 C# `AppendUniqueEntry`：去重追加，换行分隔。
  static String? _appendUnique(String? original, String entry) {
    if (entry.trim().isEmpty) return original;
    if (original == null || original.trim().isEmpty) return entry;
    return _contains(original, entry) ? original : '${original.trim()}\n$entry';
  }

  static bool _contains(String? source, String? value) {
    if (source == null || source.trim().isEmpty) return false;
    if (value == null || value.trim().isEmpty) return false;
    return source.toLowerCase().contains(value.toLowerCase());
  }

  static int _maxOf(int a, int b, int c) {
    int m = a;
    if (b > m) m = b;
    if (c > m) m = c;
    return m;
  }
}
