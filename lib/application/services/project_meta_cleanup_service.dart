// 「项目体检 → 一键清洗」服务 —— 批量修复章节的**元数据污染**。
//
// 背景（2026-10-12 用户真实库取证）：历史版本把模型原始输出直接落库，留下
//   ① 污染章名（`《青铜面具的秘密（约600字》`、`《第7/10章》`）；
//   ② 污染梗概（整段 Markdown 大纲 / 表格行 / 字段名）；
//   ③ 复读梗概（同一句循环十余遍）。
// 规则层在 `lib/ai/utils/chapter_meta_cleaner.dart`（纯 Dart，可离线自检）。
//
// ⚠ 安全边界（重要）：
//   * **只写 `chapters.title` / `chapters.summary` 两列，绝不触碰 `content`**
//     —— 正文复读属于内容问题，必须逐章确认或重写，不做批量自动改写；
//   * 先 `plan()`（dry-run，纯读）→ 用户确认 → 再 `apply()`；
//   * 幂等：清洗后的文本再过一次 `plan()` 不会产生新改动。
library;

import 'package:drift/drift.dart' show Value;

import '../../ai/utils/chapter_meta_cleaner.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';

/// 单章待清洗项。
class MetaCleanupItem {
  const MetaCleanupItem({
    required this.chapterId,
    required this.title,
    required this.summary,
    required this.fix,
  });

  final String chapterId;

  /// 原标题 / 原梗概（供预览）。
  final String title;
  final String summary;

  final ChapterMetaFix fix;

  bool get hasTitleFix => fix.newTitle != null;
  bool get hasSummaryFix => fix.newSummary != null;
  String get newTitle => fix.newTitle ?? title;
  String get newSummary => fix.newSummary ?? summary;
}

/// 一次清洗计划（dry-run 结果）。
class MetaCleanupPlan {
  const MetaCleanupPlan({required this.projectId, required this.items});

  final String projectId;
  final List<MetaCleanupItem> items;

  int get total => items.length;
  int get titleFixes =>
      items.where((MetaCleanupItem i) => i.hasTitleFix).length;
  int get summaryFixes =>
      items.where((MetaCleanupItem i) => i.hasSummaryFix).length;
  bool get isEmpty => items.isEmpty;
}

/// 章节元数据清洗服务（只动 title / summary，绝不碰 content）。
class ProjectMetaCleanupService {
  ProjectMetaCleanupService({required ChapterRepository chapters})
    : _chapters = chapters;

  final ChapterRepository _chapters;

  /// dry-run：算出该项目下所有需要清洗的章节，**不写库**。
  ///
  /// 章号用 `chapters.order_index`（与整书生成链路的「第N章」兜底口径一致）。
  Future<MetaCleanupPlan> plan(String projectId) async {
    final List<ChapterRow> rows = await _chapters.getByProjectId(projectId);
    final List<MetaCleanupItem> items = <MetaCleanupItem>[];
    for (final ChapterRow c in rows) {
      final ChapterMetaFix fix = ChapterMetaCleaner.plan(
        rawTitle: c.title,
        rawSummary: c.summary ?? '',
        chapterNo: c.orderIndex,
      );
      if (!fix.hasChange) continue;
      items.add(
        MetaCleanupItem(
          chapterId: c.id,
          title: c.title,
          summary: c.summary ?? '',
          fix: fix,
        ),
      );
    }
    return MetaCleanupPlan(projectId: projectId, items: items);
  }

  /// 应用清洗计划。返回实际写入的章节数。
  ///
  /// 只 patch `title` / `summary`；`Value.absent()` 表示该字段本次不改。
  Future<int> apply(
    MetaCleanupPlan plan, {
    void Function(int done, int total)? onProgress,
  }) async {
    int done = 0;
    for (final MetaCleanupItem item in plan.items) {
      final ChapterMetaFix fix = item.fix;
      await _chapters.updateById(
        item.chapterId,
        ChaptersCompanion(
          title: fix.newTitle == null
              ? const Value<String>.absent()
              : Value<String>(fix.newTitle!),
          summary: fix.newSummary == null
              ? const Value<String?>.absent()
              : Value<String?>(fix.newSummary!),
        ),
      );
      done++;
      onProgress?.call(done, plan.items.length);
    }
    return done;
  }
}
