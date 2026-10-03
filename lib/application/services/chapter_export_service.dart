// 章节结构化导出服务 —— 定稿/草稿章节自动落盘为本地文件（Markdown + JSON），
// 供离线检查分析写作问题、改良输出模板。
//
// 目录结构：
//   {root}/{projectId}/
//     ├─ index.md / index.json              —— 项目级索引（主线大纲 + 卷大纲 + 章节清单）
//     └─ chapters/
//          ├─ {序号}_{标题}.md              —— 单章结构化过程档案
//          └─ {序号}_{标题}.json            —— 机器可读（供脚本/分析）
//
// 单章 Markdown 含：档案四段描述、本章大纲、段落过程（写手偏向 / 目标字数 /
// 实际字数 / 验收判定 / 问题 / 返工 / 补写）、定稿正文、写作指标。
library;

import 'dart:convert';

import 'export_paths.dart';
import 'writing_archive_service.dart';

/// 单段写作过程记录（用于分析「谁写崩了、怎么崩的」）。
class ChapterExportSection {
  const ChapterExportSection({
    required this.slot,
    required this.personaId,
    required this.personaName,
    required this.title,
    required this.brief,
    required this.boundary,
    required this.wordTarget,
    required this.draft,
    required this.accepted,
    required this.problems,
    required this.reworked,
    required this.leaderFixed,
  });

  final int slot;
  final String personaId;
  final String personaName;
  final String title;
  final String brief;
  final String boundary;
  final int wordTarget;
  final String draft;
  final bool accepted;
  final String problems;
  final bool reworked;
  final bool leaderFixed;

  int get draftWords => draft.trim().length;

  /// 字数达标率（0..∞；>1 表示超目标）。
  double get wordRatio => wordTarget <= 0 ? 0 : draftWords / wordTarget;

  Map<String, Object?> toJson() => <String, Object?>{
    'slot': slot,
    'personaId': personaId,
    'personaName': personaName,
    'title': title,
    'brief': brief,
    'boundary': boundary,
    'wordTarget': wordTarget,
    'draft': draft,
    'draftWords': draftWords,
    'accepted': accepted,
    'problems': problems,
    'reworked': reworked,
    'leaderFixed': leaderFixed,
    'wordRatio': wordRatio,
  };
}

/// 单章导出的入参（服务层把过程数据打包传入）。
class ChapterExportInput {
  const ChapterExportInput({
    required this.projectId,
    required this.projectName,
    required this.volumeTitle,
    required this.chapterId,
    required this.title,
    required this.orderIndex,
    required this.status,
    required this.wordCount,
    this.content = '',
    this.mainOutline = '',
    this.volumeOutline = '',
    this.chapterOutline = '',
    this.minFinalWords = 4000,
    this.concurrency = 1,
    this.sections = const <ChapterExportSection>[],
    this.archive = const ArchiveDescription(
      timeRange: '',
      themeTask: '',
      gainsLosses: '',
      safeguards: '',
    ),
    this.exportedAt,
  });

  final String projectId;
  final String projectName;
  final String volumeTitle;
  final String chapterId;
  final String title;
  final int orderIndex;
  final String status;
  final int wordCount;
  final String content;
  final String mainOutline;
  final String volumeOutline;
  final String chapterOutline;
  final int minFinalWords;
  final int concurrency;
  final List<ChapterExportSection> sections;
  final ArchiveDescription archive;
  final DateTime? exportedAt;
}

/// 章节结构化导出服务。
class ChapterExportService {
  const ChapterExportService({this.rootOverride});

  /// 测试注入导出根目录；缺省走平台实现 [exportRootDirectory]。
  final Future<String> Function()? rootOverride;

  Future<String> _root() async => await (rootOverride ?? exportRootDirectory)();

  /// 导出单章；返回 Markdown 文件绝对路径（失败抛出，调用方折叠）。
  Future<String> exportChapter(ChapterExportInput input) async {
    final String root = await _root();
    final String sep = exportPathSeparator;
    final String projDir = '$root$sep${_sanitize(input.projectId)}';
    final String chDir = '$projDir${sep}chapters';
    _ensureDir(chDir);

    final String base =
        '${input.orderIndex.toString().padLeft(3, '0')}_${_sanitize(input.title)}';
    final String mdPath = '$chDir$sep$base.md';
    final String jsonPath = '$chDir$sep$base.json';

    _write(mdPath, _markdown(input));
    _write(jsonPath, jsonEncode(_json(input)));
    return mdPath;
  }

  /// 导出项目级索引；返回 index.md 绝对路径。
  Future<String> exportProjectIndex({
    required String projectId,
    required String projectName,
    String mainOutline = '',
    List<({String title, String outline})> volumes =
        const <({String title, String outline})>[],
    List<({int order, String title, String status, int wordCount})> chapters =
        const <({int order, String title, String status, int wordCount})>[],
  }) async {
    final String root = await _root();
    final String sep = exportPathSeparator;
    final String projDir = '$root$sep${_sanitize(projectId)}';
    _ensureDir(projDir);

    final StringBuffer md = StringBuffer()
      ..writeln('# 项目导出索引 · $projectName')
      ..writeln()
      ..writeln('- 项目 ID：$projectId')
      ..writeln('- 导出时间：${DateTime.now()}')
      ..writeln()
      ..writeln('## 主线大纲')
      ..writeln(mainOutline.trim().isEmpty ? '（无）' : mainOutline.trim())
      ..writeln()
      ..writeln('## 分卷大纲');
    if (volumes.isEmpty) {
      md.writeln('（无）');
    } else {
      for (final v in volumes) {
        md
          ..writeln('### ${v.title}')
          ..writeln(v.outline.trim().isEmpty ? '（无）' : v.outline.trim())
          ..writeln();
      }
    }
    md
      ..writeln('## 章节清单')
      ..writeln('| 序号 | 标题 | 状态 | 字数 |')
      ..writeln('|---|---|---|---|');
    for (final c in chapters) {
      md.writeln('| ${c.order} | ${c.title} | ${c.status} | ${c.wordCount} |');
    }
    final String mdPath = '$projDir${sep}index.md';
    _write(mdPath, md.toString());
    _write(
      '$projDir${sep}index.json',
      jsonEncode(<String, Object?>{
        'projectId': projectId,
        'projectName': projectName,
        'mainOutline': mainOutline,
        'volumes': <Object?>[
          for (final v in volumes)
            <String, Object?>{'title': v.title, 'outline': v.outline},
        ],
        'chapters': <Object?>[
          for (final c in chapters)
            <String, Object?>{
              'order': c.order,
              'title': c.title,
              'status': c.status,
              'wordCount': c.wordCount,
            },
        ],
      }),
    );
    return mdPath;
  }

  // -----------------------------------------------------------------------

  static void _ensureDir(String path) => ensureDirSync(path);

  static void _write(String path, String content) =>
      writeTextFileSync(path, content);

  static String _sanitize(String s) {
    String t = s.trim();
    t = t.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    t = t.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_');
    t = t.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();
    if (t.isEmpty) t = 'untitled';
    if (t.length > 100) t = t.substring(0, 100);
    return t;
  }

  static String _markdown(ChapterExportInput i) {
    final StringBuffer b = StringBuffer()
      ..writeln('# ${i.title}　·　[${i.status}]')
      ..writeln()
      ..writeln('| 项目 | 分卷 | 序号 | 字数 | 定稿下限 | 并发团队 |')
      ..writeln('|---|---|---|---|---|---|')
      ..writeln(
        '| ${i.projectName} | ${i.volumeTitle} | ${i.orderIndex} | '
        '${i.wordCount} | ${i.minFinalWords} | ${i.concurrency} |',
      )
      ..writeln()
      ..writeln('## 档案描述')
      ..writeln(i.archive.format())
      ..writeln()
      ..writeln('## 本章大纲')
      ..writeln(
        i.chapterOutline.trim().isEmpty ? '（无）' : i.chapterOutline.trim(),
      )
      ..writeln()
      ..writeln('## 段落过程（写手偏向 → 目标/实际字数 → 验收判定）');
    if (i.sections.isEmpty) {
      b.writeln('（无过程数据）');
    } else {
      for (final s in i.sections) {
        final String verdict = s.leaderFixed
            ? '组长补写'
            : (s.reworked ? '返工通过' : (s.accepted ? '通过' : '未通过'));
        b
          ..writeln('### 段落${s.slot} [${s.personaName}] ${s.title}')
          ..writeln('- 边界：${s.boundary.isEmpty ? '（无）' : s.boundary}')
          ..writeln(
            '- 目标字数：${s.wordTarget} · 实际字数：${s.draftWords}'
            '（达标率 ${(s.wordRatio * 100).toStringAsFixed(0)}%）',
          )
          ..writeln('- 验收：$verdict')
          ..writeln('- 问题：${s.problems.isEmpty ? '（无）' : s.problems}')
          ..writeln()
          ..writeln(s.draft.trim().isEmpty ? '（无稿件）' : s.draft.trim())
          ..writeln();
      }
    }
    b
      ..writeln('## 定稿正文（${i.wordCount} 字）')
      ..writeln()
      ..writeln(i.content.trim().isEmpty ? '（空）' : i.content.trim())
      ..writeln('## 写作指标（供模板改良分析）')
      ..writeln('- 段落数：${i.sections.length}')
      ..writeln(
        '- 返工/补写段数：'
        '${i.sections.where((s) => s.reworked || s.leaderFixed).length}',
      )
      ..writeln('- 字数达标率：${_passRate(i)}')
      ..writeln('- 定稿字数：${i.wordCount}（下限 ${i.minFinalWords}）');
    return b.toString();
  }

  static String _passRate(ChapterExportInput i) {
    if (i.sections.isEmpty) return '—';
    final int ok = i.sections
        .where((s) => s.accepted || s.reworked || s.leaderFixed)
        .length;
    return '$ok/${i.sections.length}';
  }

  static Map<String, Object?> _json(ChapterExportInput i) => <String, Object?>{
    'projectId': i.projectId,
    'projectName': i.projectName,
    'volumeTitle': i.volumeTitle,
    'chapterId': i.chapterId,
    'title': i.title,
    'orderIndex': i.orderIndex,
    'status': i.status,
    'wordCount': i.wordCount,
    'content': i.content,
    'minFinalWords': i.minFinalWords,
    'concurrency': i.concurrency,
    'exportedAt': (i.exportedAt ?? DateTime.now()).toIso8601String(),
    'archive': <String, Object?>{
      'timeRange': i.archive.timeRange,
      'themeTask': i.archive.themeTask,
      'gainsLosses': i.archive.gainsLosses,
      'safeguards': i.archive.safeguards,
    },
    'mainOutline': i.mainOutline,
    'volumeOutline': i.volumeOutline,
    'chapterOutline': i.chapterOutline,
    'sections': <Object?>[for (final s in i.sections) s.toJson()],
  };
}
