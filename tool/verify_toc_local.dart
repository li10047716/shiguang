// ignore_for_file: avoid_print
/// 目录加载端到端验证（本地 HTTP 服务 + 真实页面样本，不依赖外网）
///
/// 验证点：
/// 1. 第 1 页 1000 章能正确解析
/// 2. 第 1 页有分页区 → 翻到第 2 页
/// 3. 第 2 页没有分页区（该站真实情况）→ 用 pageUrlTemplate 兜底继续
/// 4. 第 3 页起是 404 → 连续空页后优雅停止并给出 warning
///
/// 用法：dart run tool/verify_toc_local.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:reading_app/models/book.dart';
import 'package:reading_app/services/http_client.dart';
import 'package:reading_app/models/book_source.dart';
import 'package:reading_app/sources/novel_source.dart';

Future<void> main() async {
  final root = Directory('test/fixtures');
  if (!root.existsSync()) {
    print('!! 缺少 test/fixtures 目录');
    exit(1);
  }

  var requestCount = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  server.listen((req) async {
    requestCount++;
    final path = req.uri.path;
    String? file;
    if (path == '/1670/' || path == '/1670') {
      file = 'toc_p1.html';
    } else if (path == '/1670/2' || path == '/1670/2/') {
      file = 'toc_p2.html';
    }
    if (file == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    // 把样本页里的真实站点域名替换成本地地址，让翻页请求也落在本地
    var content = File('${root.path}/$file').readAsStringSync();
    content = content.replaceAll('https://www.sudugu.cc', 'http://127.0.0.1:$port');
    req.response.headers.set('content-type', 'text/html; charset=utf-8');
    req.response.write(content);
    await req.response.close();
  });

  final source = BookSource.fromJson(
      jsonDecode(jsonEncode({
    'sourceName': '本地测试',
    'sourceUrl': 'http://127.0.0.1:$port',
    'sourceType': 'novel',
    'search': {'url': '', 'bookList': ''},
    'detail': {},
    'toc': {
      'chapterList': '#list li a',
      'chapterName': 'text',
      'chapterUrl': 'href',
      'nextTocUrl': '#pages a.gr@href',
      'pageUrlTemplate': '{{bookUrl}}{{page}}',
      'pageCount': '#pages@text',
    },
    'content': {'content': '.con@html'},
  })) as Map<String, dynamic>);

  final book = Book(
    name: '开局签到荒古圣体',
    author: 'J神',
    cover: '',
    bookUrl: 'http://127.0.0.1:$port/1670/',
    sourceId: source.id,
    sourceName: source.name,
  );

  final sw = Stopwatch()..start();
  var firstChunkMs = -1;
  var ok = true;
  try {
    final r = await NovelSourceExecutor(source).loadToc(
      book,
      onProgress: (page, count) => print('  进度：第 $page 页，已取 $count 章'),
      onPageChunk: (page, list) {
        if (firstChunkMs < 0) firstChunkMs = sw.elapsedMilliseconds;
        print('  第 $page 页上屏：+${sw.elapsedMilliseconds}ms，${list.length} 章');
      },
    );
    print('耗时 ${sw.elapsedMilliseconds}ms');
    print('章节总数：${r.chapters.length}');
    print('加载页数：${r.pagesLoaded}');
    print('是否部分：${r.partial}');
    print('提示：${r.warning}');
    print('首章：${r.chapters.first.title}');
    print('末章：${r.chapters.last.title}');

    // 断言
    void check(String name, bool cond) {
      print('${cond ? "PASS" : "FAIL"}  $name');
      if (!cond) ok = false;
    }

    print('首屏耗时 ${firstChunkMs}ms / 全部耗时 ${sw.elapsedMilliseconds}ms');
    check('首屏先于全部完成（边收边显示）',
        firstChunkMs > 0 && firstChunkMs <= sw.elapsedMilliseconds);
    check('第 1 页解析出 1000 章', r.chapters.length >= 1000);
    check('翻页生效（超过 1000 章）', r.chapters.length > 1000);
    check('页码模板兜底生效（>=2 页）', r.pagesLoaded >= 2);
    check('章节 URL 绝对化', r.chapters.first.url.startsWith('http://127.0.0.1'));
    check('章节 URL 无重复', r.chapters.map((c) => c.url).toSet().length ==
        r.chapters.length);

    // 缓存验证：预热详情页 URL 后，loadToc 的首屏应命中缓存（请求数至少少 1）
    HttpClient.clearCache();
    var before = requestCount;
    await NovelSourceExecutor(source).loadToc(book);
    final noCacheRequests = requestCount - before;

    HttpClient.clearCache();
    await HttpClient.getText(book.bookUrl,
        charset: 'utf-8', referer: 'http://127.0.0.1:$port');
    before = requestCount;
    await NovelSourceExecutor(source).loadToc(book);
    final withCacheRequests = requestCount - before;

    print('请求数：无缓存 $noCacheRequests，预热后 $withCacheRequests');
    check('首屏命中缓存（请求数更少）', withCacheRequests < noCacheRequests);
  } catch (e, st) {
    ok = false;
    print('!! 失败：$e');
    print(st);
  }

  await server.close(force: true);
  print(ok ? '\n全部通过' : '\n存在失败项');
  exit(ok ? 0 : 1);
}
