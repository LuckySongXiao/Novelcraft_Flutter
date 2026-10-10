// 章节落库后的自动后处理编排 —— 功能 C。
//
//   章节保存/改写/一键生成首章 → runForChapter()
//     ├─ 防重：同章同 versionNumber 不重跑（KVStore scope=chapter_sync）
//     ├─ [开关1 默认开]  规则同步（ChapterSyncService，零模型调用）
//     └─ [开关2 默认关]  AI 状态抽取（ChapterSyncAiStage，功能 C 二级注入）
//
// 原则：
//   * 后处理**绝不阻塞**章节保存 —— 任何异常被折叠成 skippedReason；
//   * **如实报告**：applied/skipped/计数全部返回给调用方渲染，不谎报成功；
//   * 开关持久化在 KVStore（scope=chapter_sync），缺省 规则=开 / AI=关。
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../data/database.dart';
import '../../data/storage/key_value_store.dart';
import '../../ai/utils/localized_text.dart';
import 'chapter_sync_service.dart';

/// AI 状态抽取阶段（功能 C 二级）的函数签名。
///
/// 输入章节上下文，返回**本地化的人类可读结果说明**（如「AI 抽取：更新 3 项」）；
/// 返回 null 或抛异常都视为「AI 未产出」，由调用方如实标注跳过。
///
/// ⚠ 还有一个容易漏的第三态：**以 [kAiExtractionFailurePrefix] 开头的字符串**
/// 也是「未产出」（只是带上了失败原因）。调用方必须用该前缀把它与真正的成功
/// 说明区分开，否则一句失败说明会被当成成功记进防重签名。
typedef ChapterSyncAiStage = Future<String?> Function(ChapterSyncInput input);

/// 后处理结果摘要。
class ChapterPostProcessSummary {
  const ChapterPostProcessSummary({
    required this.ruleApplied,
    this.ruleCounts = const ChapterSyncCounts(),
    required this.aiApplied,
    this.aiNote = '',
    this.skippedReason,
  });

  const ChapterPostProcessSummary.skipped(String reason)
      : this(
          ruleApplied: false,
          aiApplied: false,
          skippedReason: reason,
        );

  /// 规则同步是否执行（计数见 [ruleCounts]）。
  final bool ruleApplied;
  final ChapterSyncCounts ruleCounts;

  /// AI 状态抽取是否产出（说明见 [aiNote]）。
  final bool aiApplied;
  final String aiNote;

  /// 机器码：`alreadySynced` / `disabled` / `noProject` / `emptyContent` / `error:{0}`。
  final String? skippedReason;

  /// 是否有任何一级/二级同步生效。
  bool get applied => ruleApplied || aiApplied;

  /// 供 UI 附注的计数串（本地化由调用方包装）。
  String countsForDisplay(AiTextSource texts) => texts.tf(
        'SYN.CountsFmt',
        '人物 {0} · 势力 {1} · 剧情 {2} · 设定 {3} · 时间线 {4}',
        <Object>[
          ruleCounts.characters,
          ruleCounts.factions,
          ruleCounts.plots,
          ruleCounts.settings,
          ruleCounts.timelineEvents,
        ],
      );
}

/// 章节后处理编排服务。
class ChapterPostProcessService {
  ChapterPostProcessService({
    required AppDatabase db,
    required Future<KeyValueStore> Function() kv,
    required AiTextSource texts,
    ChapterSyncAiStage? aiStage,
  })  : _sync = ChapterSyncService(db: db),
        _kv = kv,
        _texts = texts,
        _aiStage = aiStage;

  static const String scope = 'chapter_sync';
  static const String _keyRuleEnabled = 'rule.enabled';
  static const String _keyAiEnabled = 'ai.enabled';
  static String _lastVersionKey(String chapterId) => 'last_success_v2:$chapterId';

  final ChapterSyncService _sync;
  final Future<KeyValueStore> Function() _kv;
  final AiTextSource _texts;

  /// 二级阶段（null = 未装配，AI 路径按 disabled 跳过）。
  ChapterSyncAiStage? _aiStage;

  /// 功能 C 二级装配入口（DI 在解析器就绪后注入）。
  set aiStage(ChapterSyncAiStage? stage) => _aiStage = stage;

  // ---------------------------------------------------------------------------
  // 开关（供设置页读写）
  // ---------------------------------------------------------------------------

  Future<bool> ruleEnabled() async => _toggleEnabled(_keyRuleEnabled, dflt: true);

  Future<bool> aiEnabled() async => _toggleEnabled(_keyAiEnabled, dflt: true);

  Future<void> setRuleEnabled(bool value) =>
      _writeToggle(_keyRuleEnabled, value);

  Future<void> setAiEnabled(bool value) => _writeToggle(_keyAiEnabled, value);

  Future<bool> _toggleEnabled(String key, {required bool dflt}) async {
    try {
      final KeyValueStore store = await _kv();
      final String? raw = await store.readJson(scope, key);
      if (raw == null || raw.isEmpty) return dflt;
      return raw == 'true';
    } on Object {
      return dflt;
    }
  }

  Future<void> _writeToggle(String key, bool value) async {
    final KeyValueStore store = await _kv();
    await store.writeJson(scope, key, value ? 'true' : 'false');
  }

  // ---------------------------------------------------------------------------
  // 编排
  // ---------------------------------------------------------------------------

  Future<ChapterPostProcessSummary> runForChapter(ChapterSyncInput input) async {
    try {
      final KeyValueStore store = await _kv();

      final bool ruleOn = await ruleEnabled();
      final bool aiOn = _aiStage != null && await aiEnabled();
      final signature = sha256.convert(utf8.encode(jsonEncode([
        input.versionNumber, input.content, input.status, ruleOn, aiOn,
      ]))).toString();
      // Fingerprint content as well: legacy save paths did not increment versions.
      final String? lastVersion =
          await store.readJson(scope, _lastVersionKey(input.chapterId));
      if (lastVersion == signature) {
        return const ChapterPostProcessSummary.skipped('alreadySynced');
      }

      if (!ruleOn && !aiOn) {
        return const ChapterPostProcessSummary.skipped('disabled');
      }

      // 一级：规则同步（零模型调用；内部自带异常折叠）
      bool ruleApplied = false;
      ChapterSyncCounts counts = const ChapterSyncCounts();
      String? reason;
      if (ruleOn) {
        final ChapterSyncOutcome outcome = await _sync.sync(input);
        if (outcome.applied) {
          ruleApplied = true;
          counts = outcome.counts;
        } else {
          reason = outcome.skippedReason;
        }
      }

      // 二级：AI 状态抽取（失败如实跳过，不重试、不阻塞）
      bool aiApplied = false;
      String aiNote = '';
      if (aiOn) {
        try {
          final String note = (await _aiStage!.call(input))?.trim() ?? '';
          if (note.isEmpty) {
            // null / 空串 = 没有可应用的产出（正文为空、质量不合格、模型不可用……）
            aiNote = _texts.t('SYN.AIFailFmt', 'AI 抽取失败已跳过');
          } else if (note.startsWith(kAiExtractionFailurePrefix)) {
            // ⚠ 「带原因的失败说明」**不是**成功产出。
            //
            // 旧实现只看「返回非空」就判成功 —— 于是 `ModuleStateService`
            // 在严格 JSON 与行式兜底都失败后返回的那句「AI 抽取未产出：…」
            // 被当成成功，写进 `last_success_v2` 防重签名，此后同版本章节
            // **再也不会重试**，失败被永久藏起来（用户实测「审核通过后人物 /
            // 世界观毫无变化」的直接原因之一）。
            aiApplied = false;
            aiNote = _texts.tf(
              'SYN.AIExtractNoOutput',
              'AI 抽取未产出：{0}',
              <Object>[
                note
                    .substring(kAiExtractionFailurePrefix.length)
                    .trim(),
              ],
            );
          } else {
            aiApplied = true;
            aiNote = note;
          }
        } on Object catch (e) {
          aiNote = _texts.tf('SYN.AIFailFmt', 'AI 抽取失败已跳过', <Object>[e]);
        }
      }

      // Newly extracted entities must receive appearances and timeline links too.
      if (aiApplied && ruleOn) {
        final outcome = await _sync.sync(input);
        ruleApplied = outcome.applied;
        counts = outcome.counts;
      }
      if ((!ruleOn || ruleApplied) && (!aiOn || aiApplied)) {
        await store.writeJson(scope, _lastVersionKey(input.chapterId), signature);
      }
      return ChapterPostProcessSummary(
        ruleApplied: ruleApplied,
        ruleCounts: counts,
        aiApplied: aiApplied,
        aiNote: aiNote,
        skippedReason: reason,
      );
    } on Object catch (e) {
      return ChapterPostProcessSummary.skipped('error:$e');
    }
  }
}
