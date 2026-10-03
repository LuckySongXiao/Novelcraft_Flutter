// 章节结构化导出测试：Markdown + JSON 双格式、目录结构、过程数据、写作指标。
//
// 运行：flutter test test/chapter_export_service_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/application/services/chapter_export_service.dart';
import 'package:novelcraft/application/services/writing_archive_service.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nc_export_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('exportChapter 生成 Markdown + JSON，含过程数据与指标', () async {
    final ChapterExportService svc = ChapterExportService(
      rootOverride: () async => tmp.path,
    );

    final String mdPath = await svc.exportChapter(
      ChapterExportInput(
        projectId: 'p1',
        projectName: '测试书',
        volumeTitle: '第一卷',
        chapterId: 'c1',
        title: '第三章',
        orderIndex: 3,
        status: '落库定稿',
        wordCount: 4200,
        content: '刀光剑影，傀儡应声而倒。',
        chapterOutline: '主角突破筑基。',
        minFinalWords: 4000,
        concurrency: 10,
        sections: const <ChapterExportSection>[
          ChapterExportSection(
            slot: 1,
            personaId: 'combat',
            personaName: '打斗',
            title: '试炼之战',
            brief: '打斗场景',
            boundary: '止于傀儡倒下',
            wordTarget: 500,
            draft: '刀光剑影，傀儡应声而倒。',
            accepted: true,
            problems: '',
            reworked: false,
            leaderFixed: false,
          ),
          ChapterExportSection(
            slot: 7,
            personaId: 'psych',
            personaName: '心理刻画',
            title: '入门心声',
            brief: '心理刻画',
            boundary: '止于拜师',
            wordTarget: 500,
            draft: '太短',
            accepted: false,
            problems: '字数不足',
            reworked: false,
            leaderFixed: true,
          ),
        ],
        archive: const ArchiveDescription(
          timeRange: '入门第一天',
          themeTask: '拜入宗门',
          gainsLosses: '埋下伏笔',
          safeguards: '注意师姐身份线',
        ),
      ),
    );

    expect(mdPath, contains('003_第三章.md'));
    final File md = File(mdPath);
    expect(md.existsSync(), isTrue);
    final String mdText = md.readAsStringSync();
    expect(mdText, contains('## 档案描述'));
    expect(mdText, contains('时间范围：入门第一天'));
    expect(mdText, contains('[打斗]'));
    expect(mdText, contains('组长补写'));
    expect(mdText, contains('## 写作指标'));
    expect(mdText, contains('## 定稿正文（4200 字）'));
    expect(mdText, contains('刀光剑影，傀儡应声而倒。'));

    // JSON 同目录同名前缀
    final String jsonPath = mdPath.replaceAll('.md', '.json');
    final File jsonFile = File(jsonPath);
    expect(jsonFile.existsSync(), isTrue);
    final Map<String, Object?> decoded =
        jsonDecode(jsonFile.readAsStringSync()) as Map<String, Object?>;
    expect(decoded['title'], '第三章');
    expect(decoded['content'], '刀光剑影，傀儡应声而倒。');
    expect((decoded['sections'] as List).length, 2);
  });

  test(
    'project id dot segment is replaced instead of escaping export root',
    () async {
      final ChapterExportService svc = ChapterExportService(
        rootOverride: () async => tmp.path,
      );
      final String path = await svc.exportChapter(
        const ChapterExportInput(
          projectId: '..',
          projectName: '测试书',
          volumeTitle: '第一卷',
          chapterId: 'c1',
          title: '第一章',
          orderIndex: 1,
          status: '草稿',
          wordCount: 0,
        ),
      );
      expect(path, startsWith(tmp.path));
      expect(path, contains('untitled'));
      expect(File(path).existsSync(), isTrue);
    },
  );

  test('exportProjectIndex 生成 index.md + index.json', () async {
    final ChapterExportService svc = ChapterExportService(
      rootOverride: () async => tmp.path,
    );

    final String idx = await svc.exportProjectIndex(
      projectId: 'p1',
      projectName: '测试书',
      mainOutline: '主线大纲正文',
      volumes: const <({String title, String outline})>[
        (title: '第一卷', outline: '卷大纲'),
      ],
      chapters:
          const <({int order, String title, String status, int wordCount})>[
            (order: 1, title: '第一章', status: '落库定稿', wordCount: 4200),
          ],
    );
    expect(idx, endsWith('index.md'));
    final File f = File(idx);
    expect(f.existsSync(), isTrue);
    expect(f.readAsStringSync(), contains('## 主线大纲'));
    expect(File(idx.replaceAll('.md', '.json')).existsSync(), isTrue);
  });
}
