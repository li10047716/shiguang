/// 漫客栈真实链路验证（搜索退化为链接探测）。
/// 用法：dart run tool/verify_mkz_live.dart [作品链接]
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:reading_app/sources/source_registry.dart';

void main(List<String> args) async {
  final reg = SourceRegistry();
  final src = reg.all.where((s) => s.sourceName == '漫客栈').firstOrNull;
  if (src == null) {
    stderr.writeln('✗ 漫客栈书源未加载');
    exit(1);
  }
  stdout.writeln('书源: ${src.sourceName}');

  var failed = 0;
  void check(String label, bool ok, String detailText) {
    stdout.writeln('${ok ? "✓" : "✗"} $label: $detailText');
    if (!ok) failed++;
  }

  try {
    final probeUrl = args.isNotEmpty
        ? args.first
        : 'https://www.mkzhan.com/217087/';
    final books = await src.search(probeUrl);
    check('链接探测返回书籍', books.isNotEmpty, '${books.length} 本');
    if (books.isEmpty) exit(1);
    final b = books.first;
    check('书名', b.name.isNotEmpty, b.name);
    check('作者', b.author.isNotEmpty, b.author);
    check('书Url(含mkz id)', b.bookUrl.startsWith('mkz:'), b.bookUrl);
    stdout.writeln('首本: ${b.name} / ${b.author} / ${b.bookUrl}');

    final detail = await src.detail(b);
    check('详情书名', detail.name.isNotEmpty, detail.name);

    final toc = await src.loadToc(detail);
    check('目录章节', toc.chapters.isNotEmpty, '${toc.chapters.length} 章');
    if (toc.chapters.isNotEmpty) {
      final first = toc.chapters.first;
      stdout.writeln('首话: ${first.title} / ${first.url}');
      final content = await src.content(first);
      check('漫画页数', content.pages.isNotEmpty, '${content.pages.length} 页');
      check('isComic', content.isComic, '${content.isComic}');
      if (content.pages.isNotEmpty) {
        stdout.writeln('首图: ${content.pages.first.substring(0, content.pages.first.length.clamp(0, 80))}');
      }
    }
  } catch (e) {
    check('请求不抛异常', false, '$e');
  }

  stdout.writeln(failed == 0 ? '\n全部通过' : '\n$failed 项失败');
  exit(failed == 0 ? 0 : 1);
}
