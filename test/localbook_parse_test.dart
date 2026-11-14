/// 本地书解析单元测试（章节切分 + EPUB 解析）。
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reading_app/sources/native/localbook.dart';

void main() {
  test('TXT 章节切分', () {
    final txt = '第一章 起源\n这是第一章的内容。\n第二章 风云\n这是第二章的内容。\n'
        '第三章 决战\n这是第三章的内容。';
    final chs = LocalBookSource.splitTxt(txt);
    expect(chs.length, 3);
    expect(chs[0].$1, '第一章 起源');
    expect(chs[0].$2.trim(), '这是第一章的内容。');
    expect(chs[2].$1, '第三章 决战');
  });

  test('TXT 无章节标记按节分', () {
    final plain = List.generate(10, (i) => '这是第$i段比较长的正文内容，用来凑够字数。').join('\n');
    final chs = LocalBookSource.splitTxt(plain);
    expect(chs, isNotEmpty);
  });

  test('EPUB 解析（OPF + spine）', () async {
    final epub = _makeEpub();
    final (title, author, intro, chapters) =
        await LocalBookSource.parseEpub(epub, '测试书');
    expect(title, '测试书名');
    expect(author, '测试作者');
    expect(intro, '简介内容');
    expect(chapters.length, 2);
    expect(chapters[0].$1, '第1章');
    expect(chapters[0].$2.any((p) => p.contains('第一页内容')), true);
    expect(chapters[1].$2.any((p) => p.contains('第二页内容')), true);
  });

}

List<int> _makeEpub() {
  final archive = Archive();
  void add(String name, String content) {
    archive.addFile(ArchiveFile(name, content.length, utf8.encode(content)));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml',
      '<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>');
  add('OEBPS/content.opf',
      '<?xml version="1.0"?><package><metadata>'
      '<dc:title>测试书名</dc:title>'
      '<dc:creator>测试作者</dc:creator>'
      '<dc:description>简介内容</dc:description>'
      '</metadata><manifest>'
      '<item id="c1" href="c1.xhtml"/>'
      '<item id="c2" href="c2.xhtml"/>'
      '</manifest><spine>'
      '<itemref idref="c1"/><itemref idref="c2"/>'
      '</spine></package>');
  add('OEBPS/c1.xhtml',
      '<html><head><title>第1章</title></head><body><p>第一页内容，正文。<p>第二段。</body></html>');
  add('OEBPS/c2.xhtml',
      '<html><head><title>第2章</title></head><body><p>第二页内容，正文。</body></html>');
  return ZipEncoder().encode(archive)!;
}
