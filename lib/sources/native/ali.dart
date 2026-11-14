/// 爱丽丝书屋（alicesw.com）抓取层。
///
/// 移植自 shiguang `reader/ali.py`。**访客免登录就能读全文**（正文页直接吐 HTML）：
///   - 搜索 GET /search.html?q=关键词&f=_all&p=N
///   - 详情 GET /novel/{id}.html
///   - 目录 GET /other/chapters/id/{id}.html（ul.mulu_list 全量一页）
///   - 正文 GET /book/{bid}/{hash}.html（.j_readContent）
///
/// 关键：**这站非走代理不可**（大陆直连 443 超时）。请求层自带代理选择：
/// 先试直连（短超时），再试本机常见端口（Clash 7897/7890、v2rayN 10809、SS 1080），
/// 命中的代理会被记住，后续请求直接用。
///
/// 书籍页 id（/novel/{id}）与章节 bid（/book/{bid}/{hash}）不是同一个，章节地址原样保存。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../novel_source.dart';
import '../source.dart';

/// 爱丽丝域名（站点更换频繁）：默认用当前可用域名，探测时自动切换。
/// 当前真实站点经「发布页 → 线路选择」链指向 www.alicesw2/3/4.homes。
String _site = 'https://www.alicesw2.homes';
const List<String> _sites = [
  'https://www.alicesw2.homes',
  'https://www.alicesw3.homes',
  'https://www.alicesw4.homes',
  'https://www.alicesw.net',
  'https://www.alicesw.me',
  'https://www.alicesw.com',
];
const String _prefix = 'ali:';
const String _scheme = 'ali://';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const List<String> _candidates = [
  'http://127.0.0.1:7897',
  'http://127.0.0.1:7890',
  'http://127.0.0.1:10809',
  'http://127.0.0.1:1080',
];

class AliSource extends SourceBase {
  @override
  String get sourceId => 'ali';
  @override
  String get sourceName => '爱丽丝书屋';
  @override
  ContentType get type => ContentType.novel;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_site/'};

  // ---------- 代理检测（模块级缓存）----------

  static bool _detected = false;
  static String _activeProxy = ''; // '' 表示直连
  static DateTime _failAt = DateTime.fromMillisecondsSinceEpoch(0);
  static Dio? _proxiedDio;

  bool get _cooling =>
      _failAt.millisecondsSinceEpoch != 0 &&
      DateTime.now().difference(_failAt).inSeconds < 20;

  /// 探测一轮：各候选站点 ×（直连 → 候选代理）。命中后记住站点与代理。
  Future<String> _detectProxy() async {
    if (_detected) return _activeProxy;
    _detected = true;
    // 先各站点直连，再候选代理
    for (final site in _sites) {
      for (final proxy in ['', ..._candidates]) {
        try {
          final dio = _dioFor(proxy);
          final resp = await dio.get<String>(
            '$site/',
            options: Options(
              responseType: ResponseType.plain,
              receiveTimeout: proxy.isEmpty
                  ? const Duration(seconds: 4)
                  : const Duration(seconds: 8),
            ),
          ).timeout(proxy.isEmpty
              ? const Duration(seconds: 5)
              : const Duration(seconds: 10));
          if (resp.data != null && resp.data!.isNotEmpty) {
            if (_site != site) {
              _site = site;
              _proxiedDio = null; // 站点变了，重建缓存 Dio
            }
            _activeProxy = proxy;
            _failAt = DateTime.fromMillisecondsSinceEpoch(0);
            return proxy;
          }
        } catch (_) {
          // 该代理/站点不通，试下一个
        }
      }
    }
    _failAt = DateTime.now();
    return '';
  }

  Dio _dioFor(String proxy) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.bytes,
      followRedirects: true,
      headers: {
        'User-Agent': _ua,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': '$_site/',
      },
    ));
    if (proxy.isNotEmpty) {
      final hostPort = proxy.replaceFirst('http://', '');
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.findProxy = (uri) => 'PROXY $hostPort';
          return c;
        },
      );
    }
    return dio;
  }

  Dio _dio() {
    if (_activeProxy.isEmpty) return _dioFor('');
    return _proxiedDio ??= _dioFor(_activeProxy);
  }

  Future<String> _get(String url, {int timeout = 25}) async {
    if (_cooling) {
      throw SourceException(
          '爱丽丝书屋 打不开：刚才试过直连和本机代理都不通，先确认代理软件在跑');
    }
    if (!_detected) await _detectProxy();
    final resp = await _dio().get<ResponseBody>(
      url,
      options: Options(responseType: ResponseType.stream),
    );
    final body = resp.data;
    if (body == null) return '';
    final builder = BytesBuilder(copy: false);
    await for (final chunk
        in body.stream.timeout(Duration(seconds: timeout))) {
      builder.add(chunk);
      if (builder.length >= 6 * 1024 * 1024) break;
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  // ---------- 文本工具 ----------

  String _text(String frag) {
    var s = frag
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll(' ', ' ')
        .replaceAll('　', ' ')
        .replaceAll(' ', ' ')
        .replaceAll(' ', ' ');
    return s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ').trim();
  }

  String _one(String pattern, String html, {int group = 1}) {
    final m = RegExp(pattern, caseSensitive: false).firstMatch(html);
    return m == null ? '' : _text(m.group(group) ?? '');
  }

  String _nativeId(String bookUrl) {
    var v = bookUrl.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length);
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    final m = RegExp(r'^(\d+)').firstMatch(v);
    return m?.group(1) ?? '';
  }

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    await _detectProxy();
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final p = page < 1 ? 1 : page;
    final url = '$_site/search.html?q=${Uri.encodeComponent(kw)}&f=_all&p=$p';
    final html = await _get(url);

    final books = <Book>[];
    final seen = <String>{};
    final blocks = html.split(RegExp(r'<div class="list-group-item">')).skip(1);
    for (final blk in blocks) {
      final hm = RegExp(r'<h5>\s*<a href="/novel/(\d+)\.html"[^>]*>([\s\S]*?)</a>')
          .firstMatch(blk);
      if (hm == null) continue;
      final bid = hm.group(1)!;
      if (!seen.add(bid)) continue;
      var title = _text(hm.group(2)!);
      title = title.replaceFirst(RegExp(r'^\d+\.\s*'), '');
      var author = '';
      final am = RegExp(r'作\s*者[：:]\s*<a[^>]*>([\s\S]*?)</a>').firstMatch(blk);
      if (am != null) author = _text(am.group(1)!);
      final intro = _one(r'<p class="content-txt">([\s\S]*?)</p>', blk);
      books.add(Book(
        name: title,
        author: author,
        cover: '',
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        lastChapter: '',
        intro: intro,
      ));
    }
    return books;
  }

  // ---------- 详情 ----------

  @override
  Future<Book> detail(Book book) async {
    await _detectProxy();
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少爱丽丝书屋书籍 id');
    final html = await _get('$_site/novel/$bid.html');
    final title = _one(r'<div class="novel_title">([\s\S]*?)</div>', html);
    final author = _one(r'作\s*者[：:]\s*<a[^>]*>([\s\S]*?)</a>', html);
    var intro = _one(r'<div class="jianjie">[\s\S]*?<p>([\s\S]*?)</p>', html);
    intro = intro.replaceAll(RegExp(r'\n{2,}'), '\n').trim();

    final chapters = await _loadTocList(bid);
    if (chapters.isEmpty) throw SourceException('爱丽丝书屋：这本暂时取不到目录');

    return Book(
      name: title.isEmpty ? book.name : title,
      author: author,
      cover: '',
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.novel,
      lastChapter: chapters.last.title,
      intro: intro,
    );
  }

  Future<List<Chapter>> _loadTocList(String bid) async {
    await _detectProxy();
    final html = await _get('$_site/other/chapters/id/$bid.html');
    final chapters = <Chapter>[];
    final seen = <String>{};
    final tm = RegExp(r'<ul class="mulu_list">([\s\S]*?)</ul>').firstMatch(html);
    final scope = tm?.group(1) ?? html;
    final re = RegExp(
        r'<li>\s*<a href="(/book/\d+/[0-9a-z]+\.html)"[^>]*>([\s\S]*?)</a>\s*</li>',
        caseSensitive: false);
    for (final m in re.allMatches(scope)) {
      final href = m.group(1)!;
      final cid = RegExp(r'/book/\d+/([0-9a-z]+)\.html', caseSensitive: false)
          .firstMatch(href)
          ?.group(1);
      if (cid == null || !seen.add(cid)) continue;
      final nm = _text(m.group(2)!);
      if (nm.isEmpty) continue;
      chapters.add(Chapter(title: nm, url: '$_scheme${href.replaceFirst('/', '')}'));
    }
    return chapters;
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少爱丽丝书屋书籍 id');
    final chapters = await _loadTocList(bid);
    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    if (chapters.isEmpty) throw SourceException('爱丽丝书屋目录为空，规则可能已失效');
    return TocResult(chapters: chapters);
  }

  // ---------- 正文 ----------

  final RegExp _junk = RegExp(
      r'(爱丽丝书屋|alicesw|请记住本站|最新网址|本章未完|点击下一页|加入书签'
      r'|一秒记住|手机用户请|最新章节|（本章完）|\(本章完\)|本站域名)');

  @override
  Future<Content> content(Chapter chapter) async {
    await _detectProxy();
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length);
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    final m = RegExp(r'^(?:book/)?(\d+)/([0-9a-z]+)(?:\.html)?').firstMatch(v);
    if (m == null) throw SourceException('爱丽丝书屋章节地址不对：${chapter.url}');
    final bid = m.group(1)!;
    final cid = m.group(2)!;
    final html = await _get('$_site/book/$bid/$cid.html');

    var title = _one(r'<h3 class="j_chapterName">([\s\S]*?)</h3>', html);
    if (title.isEmpty) {
      title = _one(r'<title>([\s\S]*?)</title>', html).split('_').first.trim();
    }

    final body = RegExp(
            r'<div class="read-content j_readContent[^"]*">([\s\S]*?)</div>')
        .firstMatch(html);
    if (body == null) throw SourceException('这一章没有取到内容（站点可能改了正文容器）');

    final paras = <String>[];
    for (final line in _text(body.group(1)!).split('\n')) {
      final l = line.trim();
      if (l.isEmpty || _junk.hasMatch(l)) continue;
      paras.add(l);
    }
    if (paras.isNotEmpty && (paras.first == title || paras.first.startsWith(title))) {
      paras.removeAt(0);
    }
    if (paras.isEmpty) throw SourceException('这一章没有取到内容');

    return Content(
      title: title,
      paras: paras,
      kind: ContentType.novel,
    );
  }

  // ---------- 发现：官方榜单 ----------

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'hits_day', name: '日榜', isRank: true),
    DiscoverTab(key: 'hits_week', name: '周榜', isRank: true),
    DiscoverTab(key: 'hits_month', name: '月榜', isRank: true),
    DiscoverTab(key: 'hits', name: '总榜', isRank: true),
  ];

  @override
  List<DiscoverTab> get discoverTabs => _ranks;

  /// 官方人气榜行：`<ul>` 块 + `<li class="two|three|four">`。
  List<Book> _rankRows(String html) {
    final books = <Book>[];
    final seen = <String>{};
    final start = html.indexOf('class="clearfix rec_rullist"');
    if (start < 0) return books;
    final end = (start + 200000).clamp(0, html.length);
    final tail = html.substring(start, end);
    for (final m in RegExp(r'<ul>([\s\S]*?)</ul>').allMatches(tail)) {
      final block = m.group(1)!;
      if (!block.contains('/novel/')) continue;
      final hm = RegExp(r'<li class="two"><a href="/novel/(\d+)\.html"')
          .firstMatch(block);
      if (hm == null) continue;
      final bid = hm.group(1)!;
      if (!seen.add(bid)) continue;
      final title = _one(r'<li class="two"><a[^>]*>([\s\S]*?)</a>', block);
      final author = _one(r'<li class="four">([\s\S]*?)</li>', block);
      final latest = _one(r'<li class="three"><a[^>]*>([\s\S]*?)</a>', block);
      books.add(Book(
        name: title,
        author: author,
        cover: '',
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        lastChapter: latest,
        intro: '',
      ));
    }
    return books;
  }

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    await _detectProxy();
    if (isRank) {
      final kind =
          _ranks.any((t) => t.key == key) ? key : 'hits_day';
      final html =
          await _get('$_site/other/rank_hits/order/$kind.html');
      final books = _rankRows(html);
      final name =
          _ranks.firstWhere((t) => t.key == kind, orElse: () => _ranks.first).name;
      return DiscoverResult(
        title: '$name · $sourceName',
        books: books,
        page: 1,
        pages: 1,
      );
    }
    // 爱丽丝书库分类走榜单同构列表，无独立分类接口；暂回退到总榜。
    throw SourceException('$sourceName分类暂不支持');
  }
}
