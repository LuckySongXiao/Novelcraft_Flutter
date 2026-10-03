// 章节查重守卫 —— 修复「同一章节标题被重复创建」。
//
// 纯函数：给定同卷已有章节列表 + 待创建的（序号，标题），
// 返回命中的既有章节（调用方复用/更新该行，不再 insert 新行）。
// 命中规则（按优先级）：
//   1. orderIndex 相同 —— 同卷同序号视为同一章（重跑幂等）；
//   2. 标题精确相等（trim 后）—— 同卷标题必须唯一。
library;

import '../../data/database.dart';

class ChapterDedupGuard {
  const ChapterDedupGuard._();

  /// 在同卷既有章节里查重；未命中返回 null。
  static ChapterRow? findExisting({
    required List<ChapterRow> existing,
    required int orderIndex,
    required String title,
  }) {
    for (final ChapterRow c in existing) {
      if (c.orderIndex == orderIndex) return c;
    }
    final String t = title.trim();
    if (t.isNotEmpty) {
      for (final ChapterRow c in existing) {
        if (c.title.trim() == t) return c;
      }
    }
    return null;
  }
}
