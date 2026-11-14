// ignore_for_file: avoid_print
/// 目录调试脚本：用真实书源跑 search → toc 全链路，打印每一步的中间值
/// 用法：dart run tool/debug_toc.dart [关键词]
library;

import 'package:reading_app/sources/builtin/builtin_sources.dart';
import 'package:reading_app/sources/novel_source.dart';

Future<void> main(List<String> args) async {
  final keyword = args.isNotEmpty ? args.join(' ') : '开局签到荒古圣体';
  final src = SourceRepository().all.first;
  final ex = NovelSourceExecutor(src);

  print('书源: ${src.name}  id=${src.id}');
  print('搜索: $keyword');
  final sw = Stopwatch()..start();
  final books = await ex.search(keyword);
  print('搜索完成 ${sw.elapsedMilliseconds}ms，命中 ${books.length} 本');
  if (books.isEmpty) {
    print('!! 搜索无结果');
    return;
  }
  for (final b in books) {
    print('  - ${b.name} | ${b.author} | bookUrl=${b.bookUrl}');
  }

  final book = books.first;
  sw.reset();
  try {
    final toc = await ex.toc(book);
    print('目录完成 ${sw.elapsedMilliseconds}ms，共 ${toc.length} 章');
    print('  首章: ${toc.first.title} -> ${toc.first.url}');
    print('  末章: ${toc.last.title} -> ${toc.last.url}');
  } catch (e, st) {
    print('!! 目录失败 ${sw.elapsedMilliseconds}ms: $e');
    print(st);
  }
}
