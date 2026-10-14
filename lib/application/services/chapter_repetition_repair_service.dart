// 「逐章复读体检」服务 —— 把正文复读的**定位与修复**接到库上。
//
// 为什么不做批量自动改写：正文是作者的核心资产。复读章里绝大多数是
// 「前半章健康 + 后半章陷入循环」，**在退化起点截断**就能救回来；但仍有
// 一部分是整篇退化（只能重写）。因此本服务只做两件事：
//   1. `plan()` —— 逐章体检（纯读），给出复读指标 + 截断预览 + 修复稿；
//   2. `applyTruncate()` —— **作者逐章确认后**才把修复稿写回 `content`。
//
// ⚠ 与「元数据清洗」的区别：那个只动 title/summary（安全、可批量）；
// 这个动 content（**破坏性**），必须逐章确认，且调用方应先做备份。
library;

import 'package:drift/drift.dart' show Value;

import '../../ai/utils/repetition_repair_text.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';

/// 单章复读体检项。
class ChapterRepetitionItem {
  const ChapterRepetitionItem({
    required this.chapterId,
    required this.title,
    required this.status,
    required this.report,
  });

  final String chapterId;
  final String title;
  final String status;
  final RepetitionReport report;

  /// 能否靠截断救回（否则应走重写）。
  bool get truncatable => report.canTruncate;
}

/// 一次复读体检计划。
class ChapterRepetitionPlan {
  const ChapterRepetitionPlan({required this.projectId, required this.items});

  final String projectId;

  /// 仅含**判为退化复读**的章节。
  final List<ChapterRepetitionItem> items;

  int get total => items.length;
  int get truncatable =>
      items.where((ChapterRepetitionItem i) => i.truncatable).length;
  int get needsRewrite => total - truncatable;
  bool get isEmpty => items.isEmpty;
}

class ChapterRepetitionRepairService {
  ChapterRepetitionRepairService({required ChapterRepository chapters})
    : _chapters = chapters;

  final ChapterRepository _chapters;

  /// 逐章体检（纯读，不写库）。
  Future<ChapterRepetitionPlan> plan(String projectId) async {
    final List<ChapterRow> rows = await _chapters.getByProjectId(projectId);
    final List<ChapterRepetitionItem> items = <ChapterRepetitionItem>[];
    for (final ChapterRow c in rows) {
      final String content = c.content ?? '';
      if (content.trim().isEmpty) continue;
      final RepetitionReport report = RepetitionRepair.analyze(content);
      if (!report.degenerate) continue;
      items.add(
        ChapterRepetitionItem(
          chapterId: c.id,
          title: c.title,
          status: c.status,
          report: report,
        ),
      );
    }
    // 复读最严重的排前面（作者先处理大问题）。
    items.sort(
      (ChapterRepetitionItem a, ChapterRepetitionItem b) =>
          b.report.ngram.compareTo(a.report.ngram),
    );
    return ChapterRepetitionPlan(projectId: projectId, items: items);
  }

  /// 采纳「截断修复」：把修复稿写回 `content`。
  ///
  /// 只允许 [ChapterRepetitionItem.truncatable] 的章节调用（修复稿非空）。
  /// 同步更新 `word_count` / `last_edited_at` / `version_number`（与预览页
  /// 采纳 AI 结果的口径一致）。
  Future<void> applyTruncate(ChapterRepetitionItem item) async {
    final String repaired = item.report.repaired;
    if (repaired.isEmpty) {
      throw StateError('no repaired text available (chapter needs rewrite)');
    }
    final ChapterRow? row = await _chapters.getById(item.chapterId);
    if (row == null) throw StateError('chapter not found: ${item.chapterId}');
    await _chapters.updateById(
      item.chapterId,
      ChaptersCompanion(
        content: Value<String?>(repaired),
        wordCount: Value<int>(repaired.length),
        lastEditedAt: Value<DateTime?>(DateTime.now()),
        versionNumber: Value<int>(row.versionNumber + 1),
      ),
    );
  }
}
