import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/application/services/epub_export_service.dart';

void main() {
  test('build 生成 EPUB 3 必需文件并保留正文与 XML 特殊字符', () {
    final List<int> bytes = EpubExportService.build(const EpubExportInput(
      title: '测试书 & 续集',
      author: '作者 <A>',
      chapters: <EpubChapter>[
        EpubChapter(
          title: '第一章 <启程>',
          volumeTitle: '第一卷',
          content: '风起 & 云开\n他抬头。',
        ),
      ],
    ));
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final Set<String> names = archive.files.map((ArchiveFile f) => f.name).toSet();
    expect(names, containsAll(<String>[
      'mimetype',
      'META-INF/container.xml',
      'OEBPS/content.opf',
      'OEBPS/nav.xhtml',
      'OEBPS/styles.css',
      'OEBPS/text/chapter-1.xhtml',
    ]));
    final ArchiveFile chapter = archive.findFile('OEBPS/text/chapter-1.xhtml')!;
    final String text = utf8.decode(chapter.content as List<int>);
    expect(text, contains('风起 &amp; 云开'));
    expect(text, contains('&lt;启程&gt;'));
    expect(utf8.decode(archive.findFile('mimetype')!.content as List<int>),
        'application/epub+zip');
  });

  test('没有章节时拒绝生成空电子书', () {
    expect(
      () => EpubExportService.build(const EpubExportInput(title: '空书', chapters: <EpubChapter>[])),
      throwsArgumentError,
    );
  });
}
