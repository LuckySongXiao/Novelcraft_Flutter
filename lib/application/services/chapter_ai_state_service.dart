// AI 状态抽取服务 —— 功能 C 二级。
//
// ⚠⚠ **本实现未被装配，属于历史遗留，请勿在此修复 BUG** ⚠⚠
//
// 线上跑的是 `lib/application/services/module_state_service.dart`
// （DI 见 `lib/core/di.dart` 的 `chapterPostProcessServiceProvider` →
// `post.aiStage = aiState.extractAndApply`）。两份实现的差异是**行为级**的：
//
//   本文件（遗留）                         module_state_service（在用）
//   ────────────────────────────────────  ──────────────────────────────────────
//   仅对**已存在**的实体做精确名匹配         `action:create` 会新建缺失实体
//     → 新角色/新设定永远抽不到（正是实测里「人物/世界观毫无变化」的成因之一）
//   只写 status / history / notes 三类      覆盖 12 类契约（含 timeline 事件）
//   无 Draft 章限制说明，实际由调用方过滤   已放宽为「正文非空且过质量闸即可」
//   失败一律返回 null（无原因）             失败返回带原因前缀的说明（可见、可重试）
//
// 保留它的唯一理由：它配套的 `ai/utils/state_extraction_parser.dart` 与
// `tool/verify_state_extraction_parser.dart` 仍在维护，可作对照参考。
// 若将来确认不再需要，请连同解析器与验证脚本一并删除（见完善计划 B5）。
//
// 章节落库后（可选开关，默认关）让写作模型从正文抽取结构化状态变化，
// **name 与库内实体精确相等才应用**，防幻觉行污染：
//   人物   status            ← 抽取（Characters.status）
//   势力   status            ← 抽取（Factions.status）
//   世界设  change            ← 追加到 History（「AI 抽取：…」）
//   剧情   change            ← 追加到 Notes（「AI 抽取：…」）
//
// 失败语义：provider 不可用 / 调用失败 / 解析失败 → 返回 null（调用方如实跳过），
// 不重试（每次章节保存至多 1 次额外调用），绝不写占位文本。
library;

import 'package:drift/drift.dart';

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/rwkv/rwkv_sampling.dart';
import '../../ai/runtime_settings.dart';
import '../../ai/utils/localized_text.dart';
import '../../ai/utils/state_extraction_parser.dart';
import '../../data/database.dart';
import '../../data/repositories/repository_base.dart' show notDeleted;
import 'chapter_sync_service.dart';

/// AI 状态抽取服务。
///
/// 见文件头：**未被装配的遗留实现**，在用实现是 `ModuleStateService`。
@Deprecated('未被装配（遗留实现）。在用实现见 module_state_service.dart。')
class ChapterAiStateService {
  ChapterAiStateService({
    required AppDatabase db,
    required AiTextSource texts,
    required IModelProvider? Function() writingProvider,
    required RwkvProvider Function() rwkv,
  }) : _db = db,
       _texts = texts,
       _writingProvider = writingProvider,
       _rwkv = rwkv;

  final AppDatabase _db;
  final AiTextSource _texts;
  final IModelProvider? Function() _writingProvider;
  final RwkvProvider Function() _rwkv;

  /// 抽取并应用；返回**本地化的人类可读说明**（空/null = 没有可应用的产出）。
  Future<String?> extractAndApply(ChapterSyncInput input) async {
    final StateExtractionResult? result = await _extract(input);
    if (result == null || result.isEmpty) return null;

    final String projectId = input.projectId.trim();
    if (projectId.isEmpty) return null;

    int applied = 0;
    int chars = 0, facs = 0, sets = 0, plotsN = 0;

    // ---- 人物：精确名匹配 → status ----
    if (result.characters.isNotEmpty) {
      final List<CharacterRow> rows =
          await (_db.select(_db.characters)..where(
                (t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted),
              ))
              .get();
      for (final ExtractedEntityState e in result.characters) {
        final CharacterRow? row = _exact<CharacterRow>(
          rows,
          e.name,
          (CharacterRow r) => r.name,
        );
        if (row == null || e.status == null) continue;
        await (_db.update(
          _db.characters,
        )..where((t) => t.id.equals(row.id))).write(
          CharactersCompanion(
            status: Value(e.status!),
            updatedAt: Value(DateTime.now()),
          ),
        );
        applied++;
        chars++;
      }
    }

    // ---- 势力：精确名匹配 → status ----
    if (result.factions.isNotEmpty) {
      final List<FactionRow> rows =
          await (_db.select(_db.factions)..where(
                (t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted),
              ))
              .get();
      for (final ExtractedEntityState e in result.factions) {
        final FactionRow? row = _exact<FactionRow>(
          rows,
          e.name,
          (FactionRow r) => r.name,
        );
        if (row == null || e.status == null) continue;
        await (_db.update(
          _db.factions,
        )..where((t) => t.id.equals(row.id))).write(
          FactionsCompanion(
            status: Value(e.status!),
            updatedAt: Value(DateTime.now()),
          ),
        );
        applied++;
        facs++;
      }
    }

    // ---- 世界设定：精确名匹配 → change 追加 History ----
    if (result.worldSettings.isNotEmpty) {
      final List<WorldSettingRow> rows =
          await (_db.select(_db.worldSettings)..where(
                (t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted),
              ))
              .get();
      for (final ExtractedEntityState e in result.worldSettings) {
        final WorldSettingRow? row = _exact<WorldSettingRow>(
          rows,
          e.name,
          (WorldSettingRow r) => r.name,
        );
        if (row == null || e.change == null) continue;
        await (_db.update(
          _db.worldSettings,
        )..where((t) => t.id.equals(row.id))).write(
          WorldSettingsCompanion(
            history: Value(_appendUnique(row.history, 'AI 抽取：${e.change!}')),
            updatedAt: Value(DateTime.now()),
          ),
        );
        applied++;
        sets++;
      }
    }

    // ---- 剧情：精确题名匹配 → change 追加 Notes ----
    if (result.plots.isNotEmpty) {
      final List<PlotRow> rows =
          await (_db.select(_db.plots)..where(
                (t) => t.projectId.equals(projectId) & notDeleted(t.isDeleted),
              ))
              .get();
      for (final ExtractedEntityState e in result.plots) {
        final PlotRow? row = _exact<PlotRow>(
          rows,
          e.name,
          (PlotRow r) => r.title,
        );
        if (row == null || e.change == null) continue;
        await (_db.update(_db.plots)..where((t) => t.id.equals(row.id))).write(
          PlotsCompanion(
            notes: Value(_appendUnique(row.notes, 'AI 抽取：${e.change!}')),
            updatedAt: Value(DateTime.now()),
          ),
        );
        applied++;
        plotsN++;
      }
    }

    if (applied == 0) return null;
    return _texts.tf(
      'SYN.AIDoneFmt',
      'AI 抽取：更新 {0} 项（人物 {1} · 势力 {2} · 设定 {3} · 剧情 {4}）',
      <Object>[applied, chars, facs, sets, plotsN],
    );
  }

  // ---------------------------------------------------------------------------
  // 私有工具
  // ---------------------------------------------------------------------------

  Future<StateExtractionResult?> _extract(ChapterSyncInput input) async {
    final String prompt = buildStateExtractionPrompt(
      input.title,
      input.content,
    );
    String? raw;
    final IModelProvider? provider = _writingProvider();
    if (provider != null) {
      try {
        final ChatResponse resp = await provider.chat(
          ChatRequest(
            systemPrompt: _texts.isEnglish
                ? 'You are a precise data extractor. Output only the JSON object.'
                : '你是严谨的数据抽取器。只输出 JSON 对象本身，禁止任何解释。',
            messages: <ChatMessage>[ChatMessage.user(prompt)],
            temperature: 0.3,
            maxTokens: 800,
            // RWKV 家族才下发防复读采样参数（其它厂商会 400）
            parameters: isRwkvFamilyProvider(provider.providerName)
                ? Map<String, dynamic>.of(aiRuntimeSettings.samplingParams())
                : <String, dynamic>{},
          ),
        );
        if (resp.isSuccess) raw = resp.content;
      } on Object {
        raw = null;
      }
    }
    raw ??= await _rwkvRaw(prompt);
    if (raw == null || raw.trim().isEmpty) return null;
    return parseStateExtraction(raw);
  }

  Future<String?> _rwkvRaw(String prompt) async {
    try {
      return await _rwkv().completeRawPrompt(
        prompt,
        maxTokens: 800,
        temperature: 0.3,
        topP: 0.85,
      );
    } on Object {
      return null;
    }
  }

  /// name 精确相等（trim + 忽略大小写）才允许应用 —— 防幻觉行污染。
  T? _exact<T>(List<T> rows, String name, String Function(T) nameOf) {
    final String key = name.trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final T r in rows) {
      if (nameOf(r).trim().toLowerCase() == key) return r;
    }
    return null;
  }

  static String? _appendUnique(String? original, String entry) {
    if (entry.trim().isEmpty) return original;
    if (original == null || original.trim().isEmpty) return entry;
    if (original.contains(entry)) return original;
    return '${original.trim()}\n$entry';
  }
}
