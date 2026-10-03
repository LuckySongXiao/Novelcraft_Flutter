// 项目结构化文件夹组导出（纯渲染部分）单元验证。
//
// 运行：flutter test test/project_folder_export_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/application/services/project_folder_export_service.dart';

ProjectFolderExportInput _sampleInput() => ProjectFolderExportInput(
  projectName: '玄穹剑主',
  projectFields: <String, dynamic>{
    'name': '玄穹剑主',
    'description': '一个修仙世界的故事',
    'type': 'Xianxia',
    'status': 'Writing',
  },
  volumes: <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'v1',
      'title': '第一卷 出山',
      'orderIndex': 1,
      'description': '主角下山',
      'status': 'Writing',
    },
    <String, dynamic>{
      'id': 'v2',
      'title': '第二卷 入世',
      'orderIndex': 2,
      'status': 'Planning',
    },
  ],
  chapters: <Map<String, dynamic>>[
    <String, dynamic>{
      'volumeId': 'v1',
      'title': '第一章 雪夜下山',
      'orderIndex': 2,
      'content': '雪落无声。\n叶知秋背起剑。',
      'summary': '主角下山',
      'status': 'Completed',
      'wordCount': 207,
      'versionNumber': 3,
      'notes': '定稿',
    },
    <String, dynamic>{
      'volumeId': 'v1',
      'title': '序章',
      'orderIndex': 1,
      'content': '风起。',
      'status': 'Draft',
      'wordCount': 3,
    },
    <String, dynamic>{
      'volumeId': '',
      'title': '散稿一章',
      'orderIndex': 9,
      'content': '未归卷。',
      'status': 'Draft',
    },
    <String, dynamic>{
      'volumeId': 'v2',
      'title': '第一章 进城',
      'orderIndex': 1,
      'content': '城门大开。',
      'status': 'Draft',
    },
  ],
  extraEntities: <String, EntityExportGroup>{
    'characterManagement': const EntityExportGroup(
      nameField: 'name',
      records: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'c1',
          'name': '叶知秋',
          'status': 'Active',
          'summary': '主角',
          'notes': '剑修',
        },
      ],
    ),
  },
);

void main() {
  group('sanitizeFileName', () {
    test('替换 Windows 非法字符并去尾点', () {
      expect(
        ProjectFolderExporter.sanitizeFileName('a<b>c:d"e/f\\g|h?i*j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
      expect(ProjectFolderExporter.sanitizeFileName('  ..标题.. '), '标题');
      expect(ProjectFolderExporter.sanitizeFileName('   '), '未命名');
    });
  });

  group('buildFileTree', () {
    test('markdown：卷内章节按 orderIndex 排序、未分卷归组、文件计数正确', () {
      final Map<String, String> files = ProjectFolderExporter.buildFileTree(
        _sampleInput(),
        markdown: true,
      );

      final List<String> chapterFiles = files.keys
          .where((String k) => k.startsWith('03_章节/'))
          .toList(growable: false);
      // 第一卷 2 章（按 orderIndex：序章 → 雪夜）+ 第二卷 1 章 + 未分卷 1 章
      expect(
        chapterFiles.any((String k) => k.contains('第一卷 出山/001_序章.md')),
        isTrue,
      );
      expect(
        chapterFiles.any((String k) => k.contains('第一卷 出山/002_第一章 雪夜下山.md')),
        isTrue,
      );
      expect(chapterFiles.any((String k) => k.contains('第二卷 入世/')), isTrue);
      expect(
        chapterFiles.any((String k) => k.startsWith('03_章节/未分卷/')),
        isTrue,
      );
      // README + 项目信息 + 2 卷 + 4 章 + 1 人物
      expect(files.length, 1 + 1 + 2 + 4 + 1);
      expect(files.containsKey('README.md'), isTrue);
      expect(files.containsKey('01_项目信息.md'), isTrue);
      expect(files.containsKey('04_人物/001_叶知秋.md'), isTrue);
    });

    test('章节正文与元信息进入文件；txt 模式无 Markdown 标记', () {
      final Map<String, String> md = ProjectFolderExporter.buildFileTree(
        _sampleInput(),
        markdown: true,
      );
      final String snow = md.entries
          .firstWhere((MapEntry<String, String> e) => e.key.contains('雪夜下山'))
          .value;
      expect(snow, contains('# 第2章　第一章 雪夜下山'));
      expect(snow, contains('雪落无声。'));
      expect(snow, contains('> **梗概**：主角下山'));
      expect(snow, contains('版本：v3'));

      final Map<String, String> txt = ProjectFolderExporter.buildFileTree(
        _sampleInput(),
        markdown: false,
      );
      final String snowTxt = txt.entries
          .firstWhere((MapEntry<String, String> e) => e.key.contains('雪夜下山'))
          .value;
      expect(snowTxt.startsWith('【第2章　第一章 雪夜下山】'), isTrue);
      expect(snowTxt, isNot(contains('# ')));
      expect(txt.containsKey('README.txt'), isTrue);
    });
  });

  test('writeTree rejects traversal keys', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('nc_tree_');
    addTearDown(() => tmp.delete(recursive: true));
    await expectLater(
      ProjectFolderExporter.writeTree(
        destDir: tmp.path,
        rootName: 'book',
        files: const <String, String>{'../outside.txt': 'must not escape'},
      ),
      throwsArgumentError,
    );
    expect(
      File(
        '${tmp.parent.path}${Platform.pathSeparator}outside.txt',
      ).existsSync(),
      isFalse,
    );
  });
}
