// 项目导出为结构化文件夹组（.txt / .md）。
//
// 分层约定：取数在 UI 层（导入导出页 —— 项目/卷宗/章节走服务，其余实体走
// `entityConfigByTarget` 通用映射），本文件只做**纯渲染 + 落盘**：
//   输入快照 → 文件树（相对路径 → 文本内容）→ 写入用户选择的目录。
// 渲染逻辑不碰数据库，可脱离运行环境做单元测试。
//
// 目录结构（markdown = true 时）：
// ```
// <项目名>/
// ├── README.md                导出说明与统计
// ├── 01_项目信息.md
// ├── 02_卷宗/<NN>_<卷名>.md
// ├── 03_章节/<NN>_<卷名>/<NNN>_<章节名>.md（未挂卷的归「未分卷」）
// ├── 04_人物/…、05_势力/…、06_剧情/…（其余实体每条记录一个文件）
// ```
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 一类实体的导出组（文件命名取 [nameField] 字段）。
class EntityExportGroup {
  final String nameField;
  final List<Map<String, dynamic>> records;
  const EntityExportGroup({required this.nameField, required this.records});
}

/// 导出输入快照（由调用方取数后组装；本类只读）。
class ProjectFolderExportInput {
  final String projectName;
  final Map<String, Object?> projectFields;
  final List<Map<String, dynamic>> volumes;
  final List<Map<String, dynamic>> chapters;
  final Map<String, EntityExportGroup> extraEntities;

  const ProjectFolderExportInput({
    required this.projectName,
    required this.projectFields,
    required this.volumes,
    required this.chapters,
    required this.extraEntities,
  });
}

/// 项目 → 结构化文件夹组导出器（纯函数渲染 + 落盘）。
abstract final class ProjectFolderExporter {
  /// 常见字段 → 中文标签（其余键原样输出）。
  static const Map<String, String> _keyLabels = <String, String>{
    'name': '名称',
    'title': '标题',
    'summary': '梗概',
    'description': '简介',
    'content': '正文',
    'status': '状态',
    'type': '类型',
    'tags': '标签',
    'notes': '备注',
    'importance': '重要性',
    'wordCount': '字数',
    'orderIndex': '排序',
    'versionNumber': '版本',
    'lastEditedAt': '最后修改',
    'createdAt': '创建时间',
    'updatedAt': '更新时间',
    'priority': '优先级',
    'progress': '进度',
  };

  /// 文件名净化：替换 Windows 非法字符、去首尾空白与点、限长 60。
  static String sanitizeFileName(String raw) {
    String cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    cleaned = cleaned.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();
    if (cleaned.isEmpty) return '未命名';
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  /// 生成文件树：相对路径（posix 风格）→ 文本内容。
  static Map<String, String> buildFileTree(
    ProjectFolderExportInput input, {
    required bool markdown,
  }) {
    final String ext = markdown ? 'md' : 'txt';
    final files = <String, String>{};

    // ---- README：结构说明 + 统计 ----
    final int chapterCount = input.chapters.length;
    final StringBuffer readme = StringBuffer();
    if (markdown) {
      readme.writeln('# ${input.projectName}');
      readme.writeln();
      readme.writeln('- 导出时间：${DateTime.now().toIso8601String()}');
      readme.writeln('- 卷宗：${input.volumes.length}');
      readme.writeln('- 章节：$chapterCount');
      int extra = 0;
      for (final EntityExportGroup g in input.extraEntities.values) {
        extra += g.records.length;
      }
      readme.writeln('- 其它实体记录：$extra');
      readme.writeln();
      readme.writeln('## 目录结构');
      readme.writeln();
      readme.writeln('```');
      readme.writeln('01_项目信息.$ext      项目元信息');
      readme.writeln('02_卷宗/              每卷一个文件');
      readme.writeln('03_章节/              每章一个文件（按卷分组，未分卷在 未分卷/）');
      readme.writeln('04_人物/ …            其余实体每条记录一个文件');
      readme.writeln('```');
    } else {
      readme
        ..writeln(input.projectName)
        ..writeln('导出时间：${DateTime.now().toIso8601String()}')
        ..writeln('卷宗：${input.volumes.length}  章节：$chapterCount');
    }
    files['README.$ext'] = readme.toString();

    // ---- 01_项目信息 ----
    files['01_项目信息.$ext'] = renderRecord(
      input.projectFields,
      title: input.projectName,
      markdown: markdown,
      headingLevel: 1,
    );

    // ---- 02_卷宗 ----
    for (int i = 0; i < input.volumes.length; i++) {
      final Map<String, dynamic> v = input.volumes[i];
      final String name = sanitizeFileName(
        (v['title'] ?? v['name'] ?? '未命名').toString(),
      );
      files['02_卷宗/${_padded(i + 1)}_$name.$ext'] = renderVolume(
        v,
        order: i + 1,
        markdown: markdown,
      );
    }

    // ---- 03_章节（按卷分组；卷内按 orderIndex 排序）----
    final Map<String, List<Map<String, dynamic>>> byVolume =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> c in input.chapters) {
      final String vid = (c['volumeId'] ?? '').toString();
      (byVolume[vid] ??= <Map<String, dynamic>>[]).add(c);
    }
    for (final List<Map<String, dynamic>> list in byVolume.values) {
      list.sort((a, b) {
        final int cmp = ((a['orderIndex'] as num?)?.toInt() ?? 0).compareTo(
          (b['orderIndex'] as num?)?.toInt() ?? 0,
        );
        if (cmp != 0) return cmp;
        return (a['title'] ?? '').toString().compareTo(
          (b['title'] ?? '').toString(),
        );
      });
    }
    for (int i = 0; i < input.volumes.length; i++) {
      final Map<String, dynamic> v = input.volumes[i];
      final List<Map<String, dynamic>>? chs = byVolume.remove(v['id']);
      if (chs == null || chs.isEmpty) continue;
      final String volName = sanitizeFileName(
        (v['title'] ?? v['name'] ?? '未命名').toString(),
      );
      _emitChapters(
        files,
        '03_章节/${_padded(i + 1)}_$volName',
        chs,
        ext,
        markdown,
      );
    }
    // 剩余未挂卷章节（多组合并后统一排序，避免文件名冲突）
    final List<Map<String, dynamic>> leftover = <Map<String, dynamic>>[];
    for (final List<Map<String, dynamic>> rest in byVolume.values) {
      leftover.addAll(rest);
    }
    if (leftover.isNotEmpty) {
      leftover.sort((a, b) {
        final int cmp = ((a['orderIndex'] as num?)?.toInt() ?? 0).compareTo(
          (b['orderIndex'] as num?)?.toInt() ?? 0,
        );
        if (cmp != 0) return cmp;
        return (a['title'] ?? '').toString().compareTo(
          (b['title'] ?? '').toString(),
        );
      });
      _emitChapters(files, '03_章节/未分卷', leftover, ext, markdown);
    }

    // ---- 其余实体：每条记录一个文件 ----
    for (final MapEntry<String, EntityExportGroup> e
        in input.extraEntities.entries) {
      final String folder = _entityFolders[e.key] ?? e.key;
      int idx = 0;
      for (final Map<String, dynamic> record in e.value.records) {
        final String name = sanitizeFileName(
          (record[e.value.nameField] ??
                  record['title'] ??
                  record['name'] ??
                  '未命名')
              .toString(),
        );
        idx++;
        files['$folder/${_padded(idx)}_$name.$ext'] = renderRecord(
          record,
          title: name,
          markdown: markdown,
        );
      }
    }

    return files;
  }

  /// 实体类目 → 文件夹（含序号前缀，保证目录树稳定有序）。
  static const Map<String, String> _entityFolders = <String, String>{
    'characterManagement': '04_人物',
    'factionManagement': '05_势力',
    'plotManagement': '06_剧情',
    'worldSettingManagement': '07_世界观设定',
    'race': '08_种族',
    'resource': '09_资源',
    'secretRealm': '10_秘境',
    'cultivationSystem': '11_修炼体系',
    'cultivationLevelManagement': '12_境界',
    'politicalSystem': '13_政治体系',
    'politicalPositionManagement': '14_官职',
    'currencySystem': '15_货币体系',
    'relationshipNetwork': '16_关系网',
    'characterRelationshipManagement': '17_人物关系',
    'factionRelationshipManagement': '18_势力关系',
    'raceRelationshipManagement': '19_种族关系',
    'characterEventManagement': '20_人物事件',
    'timelineEventManagement': '21_时间线事件',
  };

  static void _emitChapters(
    Map<String, String> files,
    String folder,
    List<Map<String, dynamic>> chapters,
    String ext,
    bool markdown,
  ) {
    for (int i = 0; i < chapters.length; i++) {
      final Map<String, dynamic> c = chapters[i];
      final String name = sanitizeFileName((c['title'] ?? '未命名').toString());
      files['$folder/${_padded(i + 1)}_$name.$ext'] = renderChapter(
        c,
        order: i + 1,
        markdown: markdown,
      );
    }
  }

  static String _padded(int n) => n.toString().padLeft(3, '0');

  /// 卷宗文件：字段清单（无正文）。
  static String renderVolume(
    Map<String, dynamic> v, {
    required int order,
    required bool markdown,
  }) {
    final String title = (v['title'] ?? v['name'] ?? '未命名').toString();
    final StringBuffer sb = StringBuffer();
    if (markdown) {
      sb
        ..writeln('# 第$order卷　$title')
        ..writeln();
      _appendFields(
        sb,
        v,
        markdown: markdown,
        skipKeys: const <String>{'id', 'projectId', 'title', 'name'},
      );
    } else {
      sb.writeln('【第$order卷　$title】');
      _appendFields(
        sb,
        v,
        markdown: markdown,
        skipKeys: const <String>{'id', 'projectId', 'title', 'name'},
      );
    }
    return sb.toString();
  }

  /// 章节文件：元信息头 + 梗概 + 正文 + 备注。
  static String renderChapter(
    Map<String, dynamic> c, {
    required int order,
    required bool markdown,
  }) {
    final String title = (c['title'] ?? '未命名').toString();
    final String content = (c['content'] ?? '').toString();
    final String summary = (c['summary'] ?? '').toString().trim();
    final String notes = (c['notes'] ?? '').toString().trim();
    final Object? status = c['status'];
    final Object? wordCount = c['wordCount'];
    final Object? version = c['versionNumber'];
    final String sep = markdown ? '---' : '──────────';

    final StringBuffer sb = StringBuffer();
    if (markdown) {
      sb
        ..writeln('# 第$order章　$title')
        ..writeln();
    } else {
      sb.writeln('【第$order章　$title】');
    }
    final List<String> meta = <String>[
      if (status != null && status.toString().isNotEmpty)
        '${_label('status')}：$status',
      if (wordCount != null && wordCount.toString() != '0')
        '${_label('wordCount')}：$wordCount',
      if (version != null) '${_label('versionNumber')}：v$version',
    ];
    for (final String line in meta) {
      sb.writeln(markdown ? '- $line' : line);
    }
    if (summary.isNotEmpty) {
      sb
        ..writeln()
        ..writeln(
          markdown
              ? '> **${_label('summary')}**：$summary'
              : '${_label('summary')}：$summary',
        );
    }
    if (content.trim().isNotEmpty) {
      sb
        ..writeln()
        ..writeln(sep)
        ..writeln()
        ..writeln(content)
        ..writeln()
        ..writeln(sep);
    }
    if (notes.isNotEmpty) {
      sb
        ..writeln()
        ..writeln(
          markdown
              ? '> **${_label('notes')}**：$notes'
              : '${_label('notes')}：$notes',
        );
    }
    return sb.toString();
  }

  /// 通用记录渲染：标题 + 字段清单（长文本/多行文本独立成块）。
  static String renderRecord(
    Map<String, dynamic> record, {
    required String title,
    required bool markdown,
    int headingLevel = 2,
    Set<String> skipKeys = const <String>{'id', 'projectId'},
  }) {
    final StringBuffer sb = StringBuffer();
    final String prefix = markdown ? '#' * headingLevel : '';
    if (markdown) {
      sb
        ..writeln('$prefix $title')
        ..writeln();
    } else {
      sb.writeln('【$title】');
    }
    _appendFields(sb, record, markdown: markdown, skipKeys: skipKeys);
    return sb.toString();
  }

  static String _label(String key) => _keyLabels[key] ?? key;

  static void _appendFields(
    StringBuffer sb,
    Map<String, dynamic> record, {
    required bool markdown,
    Set<String> skipKeys = const <String>{},
  }) {
    for (final MapEntry<String, dynamic> e in record.entries) {
      if (skipKeys.contains(e.key)) continue;
      final Object? value = e.value;
      if (value == null) continue;
      final String text = value.toString().trim();
      if (text.isEmpty || text == 'null') continue;
      final String label = _label(e.key);
      final bool isLong = text.contains('\n') || text.length > 60;
      if (!isLong) {
        sb.writeln(markdown ? '- **$label**：$text' : '$label：$text');
        continue;
      }
      sb.writeln();
      if (markdown) {
        sb
          ..writeln('**$label**：')
          ..writeln();
        for (final String line in text.split('\n')) {
          sb.writeln('> $line'.trimRight());
        }
      } else {
        sb.writeln('$label：');
        sb.write(text);
        sb.writeln();
      }
      sb.writeln();
    }
  }

  /// 落盘：把文件树写入 `<destDir>/<rootName>/`，返回根目录路径。
  static Future<String> writeTree({
    required String destDir,
    required String rootName,
    required Map<String, String> files,
  }) async {
    final String root = p.join(destDir, sanitizeFileName(rootName));
    for (final MapEntry<String, String> e in files.entries) {
      final String relative = _validateRelativePath(e.key);
      final File f = File(p.joinAll(<String>[root, ...relative.split('/')]));
      await f.create(recursive: true);
      await f.writeAsString(e.value, flush: true);
    }
    return root;
  }

  static String _validateRelativePath(String raw) {
    final String normalized = raw.replaceAll('\\', '/');
    final List<String> segments = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.contains(':') ||
        segments.any((String s) => s == '..')) {
      throw ArgumentError.value(raw, 'files', 'must be a safe relative path');
    }
    final List<String> kept = segments
        .where((String s) => s.isNotEmpty && s != '.')
        .toList();
    if (kept.isEmpty) {
      throw ArgumentError.value(raw, 'files', 'must name a file');
    }
    return kept.join('/');
  }
}
