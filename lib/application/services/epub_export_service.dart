// EPUB 3 电子书导出。只负责把已排序的章节快照编码为 EPUB ZIP，
// 不依赖文件系统，因此 Windows、Android 和 Web 都能复用同一套逻辑。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class EpubChapter {
  const EpubChapter({
    required this.title,
    required this.content,
    this.volumeTitle = '',
    this.order = 0,
  });

  final String title;
  final String content;
  final String volumeTitle;
  final int order;
}

class EpubExportInput {
  const EpubExportInput({
    required this.title,
    required this.chapters,
    this.author = '',
    this.language = 'zh-CN',
    this.identifier = 'urn:novelcraft:book',
  });

  final String title;
  final String author;
  final String language;
  final String identifier;
  final List<EpubChapter> chapters;
}

/// EPUB 3 最小合规打包器。
abstract final class EpubExportService {
  static List<int> build(EpubExportInput input) {
    if (input.chapters.isEmpty) {
      throw ArgumentError('至少需要一章有正文内容才能导出 EPUB');
    }
    final String title = _text(input.title, '未命名作品');
    final String author = _text(input.author, 'NovelCraft');
    final String language = _text(input.language, 'zh-CN');
    final String identifier = _xml(input.identifier.trim().isEmpty
        ? 'urn:novelcraft:book'
        : input.identifier.trim());
    final String modified = DateTime.now().toUtc().toIso8601String();
    final List<EpubChapter> chapters = List<EpubChapter>.of(input.chapters);

    final Archive archive = Archive();
    // EPUB 规范要求 mimetype 是第一个条目、未压缩且内容完全匹配。
    final ArchiveFile mimetype = ArchiveFile('mimetype', 20,
        Uint8List.fromList(utf8.encode('application/epub+zip')));
    mimetype.compress = false;
    archive.addFile(mimetype);
    archive.addFile(_file('META-INF/container.xml', _containerXml()));

    final List<String> manifest = <String>[
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
      '<item id="css" href="styles.css" media-type="text/css"/>',
    ];
    final List<String> spine = <String>[];
    final List<String> nav = <String>[];
    for (int index = 0; index < chapters.length; index++) {
      final EpubChapter chapter = chapters[index];
      final String id = 'chapter-${index + 1}';
      final String href = 'text/$id.xhtml';
      manifest.add(
          '<item id="$id" href="$href" media-type="application/xhtml+xml"/>');
      spine.add('<itemref idref="$id"/>');
      nav.add('<li><a href="$href">${_xml(chapter.title)}</a></li>');
      archive.addFile(_file(
        'OEBPS/$href',
        _chapterXhtml(title, chapter, language),
      ));
    }
    archive.addFile(_file('OEBPS/styles.css', _styles()));
    archive.addFile(_file(
      'OEBPS/nav.xhtml',
      _navXhtml(title, language, nav),
    ));
    archive.addFile(_file(
      'OEBPS/content.opf',
      _opf(
        title: title,
        author: author,
        language: language,
        identifier: identifier,
        modified: modified,
        manifest: manifest,
        spine: spine,
      ),
    ));
    final List<int>? bytes = ZipEncoder().encode(archive);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('EPUB 打包失败：ZIP 编码器没有返回内容');
    }
    return bytes;
  }

  static ArchiveFile _file(String path, String text) {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(text));
    return ArchiveFile(path, bytes.length, bytes);
  }

  static String _containerXml() => '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';

  static String _opf({
    required String title,
    required String author,
    required String language,
    required String identifier,
    required String modified,
    required List<String> manifest,
    required List<String> spine,
  }) => '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">$identifier</dc:identifier>
    <dc:title>${_xml(title)}</dc:title>
    <dc:language>${_xml(language)}</dc:language>
    <dc:creator>${_xml(author)}</dc:creator>
    <meta property="dcterms:modified">$modified</meta>
  </metadata>
  <manifest>${manifest.join()}</manifest>
  <spine>${spine.join()}</spine>
</package>''';

  static String _navXhtml(String title, String language, List<String> items) =>
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="${_xml(language)}">
<head><title>${_xml(title)} 目录</title><link rel="stylesheet" type="text/css" href="styles.css"/></head>
<body><nav epub:type="toc" id="toc"><h1>${_xml(title)}</h1><ol>${items.join()}</ol></nav></body>
</html>''';

  static String _chapterXhtml(String bookTitle, EpubChapter chapter, String language) {
    final String body = chapter.content
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((String line) => line.trim().isEmpty ? '<p>&#160;</p>' : '<p>${_xml(line)}</p>')
        .join();
    final String heading = chapter.volumeTitle.trim().isEmpty
        ? chapter.title
        : '${chapter.volumeTitle} · ${chapter.title}';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="${_xml(language)}">
<head><title>${_xml(heading)}</title><link rel="stylesheet" type="text/css" href="../styles.css"/></head>
<body><h1>${_xml(heading)}</h1>$body</body>
</html>''';
  }

  static String _styles() =>
      'body { max-width: 42em; margin: 2em auto; line-height: 1.8; font-family: serif; } h1 { text-align: center; margin-bottom: 2em; } p { text-indent: 2em; margin: 0.7em 0; }';

  static String _xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _text(String value, String fallback) =>
      value.trim().isEmpty ? fallback : value.trim();
}
