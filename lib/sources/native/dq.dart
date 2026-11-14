/// 得奇小说网（deqixss.com）抓取层。
///
/// 移植自 shiguang `reader/dq.py`（杰奇 CMS 改版模板，正文异步拆分）：
///   - 搜索 GET /modules/article/search.php?searchkey=xxx（精确命中 302 到书页）
///   - 详情 /books/{id}/ 一次给全量目录（div#list-chapterAll）
///   - 正文 token/timestamp/nonce 由 /scripts/chapter.js.php 现发，绑定 cid，
///     /modules/article/ajax2.php 返回 JSON（必须带 X-Requested-With: XMLHttpRequest，
///     Referer 必须是本章页地址）。
///
/// 书籍 id 用 `dq:<bid>` 编码进 [Book.bookUrl]，章节 url 用 `dq://<bid>/<cid>.html`。
library;

import 'dart:convert';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

// 注意：本站 HTTPS 握手/传输在本网络下不稳定（偶发 3 分钟超时），
// 用 HTTP 实测更稳（首页 1.4s 返回 200）。shiguang 原版用 https，这里按实测调整。
const String _base = 'http://www.deqixss.com';
const String _prefix = 'dq:';
const String _scheme = 'dq://';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

class DqSource extends SourceBase {
  @override
  String get sourceId => 'dq';
  @override
  String get sourceName => '得奇小说网';
  @override
  ContentType get type => ContentType.novel;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_base/'};

  // ---------- 基础 ----------

  String _bookId(String href) {
    final m = RegExp(r'/books/(\d+)/?(?:[?#]|$)').firstMatch(href.trim());
    return m?.group(1) ?? '';
  }

  String _cidOf(String href) {
    final m = RegExp(r'/books/(\d+)/(\d+)\.html').firstMatch(href.trim());
    return m?.group(2) ?? '';
  }

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
        .replaceAll('　', ' ');
    s = s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
    return s.trim();
  }

  String _cover(String bid, String found) {
    if (found.trim().isNotEmpty) {
      var f = found.trim();
      if (f.startsWith('//')) return 'https:$f';
      if (f.startsWith('http')) return f;
      return Uri.parse('$_base/').resolve(f).toString();
    }
    if (bid.isEmpty || !RegExp(r'^\d+$').hasMatch(bid)) return '';
    final n = int.parse(bid);
    return '$_base/files/article/image/${n ~/ 1000}/$bid/${bid}s.jpg';
  }

  String _status(String raw) {
    final s = raw.trim();
    if (s == '全本' || s == '完结' || s == '完成') return '已完结';
    if (s == '连载' || s == '连载中') return '连载中';
    return s;
  }

  // ---------- 网络 ----------

  Future<(String, String)> _get(
    String url, {
    bool xhr = false,
    String? referer,
    int maxBytes = 4 * 1024 * 1024,
    Duration idleTimeout = const Duration(seconds: 20),
  }) async {
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer ?? '$_base/',
      if (xhr) 'X-Requested-With': 'XMLHttpRequest',
    };
    return HttpClient.getTextDetailed(
      url,
      charset: 'utf-8',
      headers: headers,
      maxBytes: maxBytes,
      idleTimeout: idleTimeout,
    );
  }

  /// 解析详情页的目录（div#list-chapterAll）。
  List<Chapter> _parseToc(String html, String bid) {
    final start = html.indexOf('<div id="list-chapterAll"');
    final end = start > 0 ? html.indexOf('</div>', start) : -1;
    final toc = (start > 0 && end > start) ? html.substring(start, end) : html;

    final chapters = <Chapter>[];
    final seen = <String>{};
    final re = RegExp(
        r'<dd>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
        caseSensitive: false);
    for (final m in re.allMatches(toc)) {
      final cid = _cidOf(m.group(1)!);
      if (cid.isEmpty || !seen.add(cid)) continue;
      final nm = _text(m.group(2)!);
      if (nm.isEmpty || nm.contains('查看全部章节')) continue;
      chapters.add(Chapter(title: nm, url: '$_scheme$bid/$cid.html'));
    }
    return chapters;
  }

  /// 抓详情页目录，空目录时重试（本站偶发返回截断/空目录页）。
  Future<List<Chapter>> _fetchToc(String bid) async {
    final url = '$_base/books/$bid/';
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final (html, _) = await _get(url, maxBytes: 6 * 1024 * 1024);
        final list = _parseToc(html, bid);
        if (list.isNotEmpty) return list;
        lastError = '详情页未含章节（长度 ${html.length}）';
      } catch (e) {
        lastError = e;
      }
      await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
    }
    throw SourceException('得奇小说网：这本暂时取不到目录（$lastError）');
  }

  // ---------- 列表行解析（搜索/书库/榜单共用 div.bookbox）----------

  List<Map<String, String>> _rows(String html) {
    final books = <Map<String, String>>[];
    final seen = <String>{};
    final rowRe = RegExp(r'<div class="bookbox">([\s\S]*?)<div class="delbutton">', caseSensitive: false);
    for (final m in rowRe.allMatches(html)) {
      final chunk = m.group(1)!;
      final nm = RegExp(
              r'<h4 class="bookname">\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
              caseSensitive: false)
          .firstMatch(chunk);
      if (nm == null) continue;
      final bid = _bookId(nm.group(1)!);
      if (bid.isEmpty || !seen.add(bid)) continue;

      var author = '';
      var reads = '';
      final authors = RegExp(r'<div class="author">([\s\S]*?)</div>', caseSensitive: false)
          .allMatches(chunk);
      for (final a in authors) {
        final t = _text(a.group(1)!);
        if (t.startsWith('作者')) {
          author = t.replaceFirst(RegExp(r'^作\s*者[：:]\s*'), '');
        } else if (t.startsWith('阅读量')) {
          final m2 = RegExp(r'([\d.]+)').firstMatch(t.replaceAll(',', ''));
          reads = m2?.group(1) ?? '';
        }
      }
      final wm = RegExp(r"towan\('(\d+)'\)").firstMatch(chunk);
      final words = wm == null ? '' : _words(wm.group(1)!);
      final lm = RegExp(r'<div class="cat">[\s\S]*?<a[^>]*>([\s\S]*?)</a>', caseSensitive: false)
          .firstMatch(chunk);
      final im = RegExp(r'<div class="update">([\s\S]*?)</div>', caseSensitive: false)
          .firstMatch(chunk);
      var intro = im == null ? '' : _text(im.group(1)!);
      intro = intro.replaceFirst(RegExp(r'^简\s*介[：:]\s*'), '');

      books.add({
        'id': '$_prefix$bid',
        'title': _text(nm.group(2)!),
        'author': author,
        'cover': _cover(bid, ''),
        'latest': lm == null ? '' : _text(lm.group(1)!),
        'intro': intro,
        'words': words,
        'read': reads,
      });
    }
    return books;
  }

  String _words(String raw) {
    final n = int.tryParse(raw.trim());
    if (n == null) return raw.trim();
    if (n >= 10000) return '${(n / 10000).round()} 万字';
    return '$n 字';
  }

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final url = '$_base/modules/article/search.php?searchkey=${Uri.encodeComponent(kw)}';
    final (html, finalUrl) = await _get(url);

    // 书名精确命中时站点 302 到书页，补一条结果
    final bid = _bookId(finalUrl);
    if (bid.isNotEmpty && html.contains('class="booktitle"')) {
      final core = _detailCore(html, bid);
      return [_rowToBook(core)];
    }

    final rows = _rows(html);
    return rows.map(_rowToBook).toList();
  }

  Book _rowToBook(Map<String, String> r) => Book(
        name: r['title'] ?? '',
        author: r['author'] ?? '',
        cover: r['cover'] ?? '',
        bookUrl: r['id'] ?? '',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        lastChapter: r['latest'] ?? '',
        intro: r['intro'] ?? '',
      );

  // ---------- 详情 / 目录 ----------

  Map<String, String> _detailCore(String html, String bid) {
    final tm = RegExp(r'<h1 class="booktitle">([\s\S]*?)</h1>', caseSensitive: false)
        .firstMatch(html);
    var title = tm == null ? '' : _text(tm.group(1)!);
    if (title.isEmpty) {
      final tm2 = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(html);
      title = tm2 == null ? '书籍$bid' : _text(tm2.group(1)!).split('_').first;
    }
    final am = RegExp(
            r'<p class="booktag">[\s\S]{0,200}?<a class="red"[^>]*>([\s\S]*?)</a>',
            caseSensitive: false)
        .firstMatch(html);
    final wm = RegExp(r"towan\('(\d+)'\)").firstMatch(html);
    final rd = RegExp(r'>\s*([\d,]+)\s*人读过').firstMatch(html);
    final sm = RegExp(r'<span class="red">([^<]{1,6})</span>')
        .allMatches(html)
        .map((m) => m.group(1)!)
        .toList();
    final cm = RegExp(
            r'<div class="bookcover[^"]*">\s*<img[^>]*src="([^"]+)"',
            caseSensitive: false)
        .firstMatch(html);
    final im = RegExp(r'<p class="bookintro">([\s\S]*?)</p>', caseSensitive: false)
        .firstMatch(html);
    final km = RegExp(r'<ol class="breadcrumb">([\s\S]*?)</ol>', caseSensitive: false)
        .firstMatch(html);
    final lm = RegExp(r'<a class="bookchapter"[^>]*>([\s\S]*?)</a>', caseSensitive: false)
        .firstMatch(html);
    var category = '';
    if (km != null) {
      final links = RegExp(
              r'<a[^>]*href="[^"]*sort/[^"]*"[^>]*>([\s\S]*?)</a>',
              caseSensitive: false)
          .allMatches(km.group(1)!)
          .map((m) => _text(m.group(1)!))
          .toList();
      category = links.isEmpty ? '' : links.first;
    }
    var intro = im == null ? '' : _text(im.group(1)!);
    intro = intro.replaceAll(RegExp(r'\n{2,}'), '\n').trim();

    return {
      'id': '$_prefix$bid',
      'title': title,
      'author': am == null ? '' : _text(am.group(1)!),
      'cover': _cover(bid, cm?.group(1) ?? ''),
      'category': category,
      'status': sm.isEmpty ? '' : _status(sm.last),
      'intro': intro,
      'words': wm == null ? '' : _words(wm.group(1)!),
      'read': rd == null ? '' : _num(rd.group(1)!),
      'latest': lm == null ? '' : _text(lm.group(1)!),
    };
  }

  String _num(String raw) {
    final m = RegExp(r'([\d.]+)').firstMatch(raw.replaceAll(',', ''));
    return m?.group(1) ?? '';
  }

  String _nativeId(String bookUrl) {
    var v = bookUrl.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length);
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    return v.split('/')[0];
  }

  @override
  Future<Book> detail(Book book) async {
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少得奇小说网书籍 id');
    final url = '$_base/books/$bid/';
    final (html, _) = await _get(url, maxBytes: 6 * 1024 * 1024);
    final core = _detailCore(html, bid);

    // 目录：div#list-chapterAll 正序全量
    final chapters = await _fetchToc(bid);

    return Book(
      name: core['title'] ?? book.name,
      author: core['author'] ?? '',
      cover: core['cover'] ?? '',
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.novel,
      lastChapter: (core['latest'] ?? '').isEmpty && chapters.isNotEmpty
          ? chapters.last.title
          : core['latest'],
      intro: core['intro'] ?? '',
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少得奇小说网书籍 id');
    final chapters = await _fetchToc(bid);

    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    if (chapters.isEmpty) throw SourceException('得奇小说网目录为空，规则可能已失效');
    return TocResult(chapters: chapters);
  }

  // ---------- 正文 ----------

  final RegExp _junk = RegExp(
      r'(速读谷|速\.读\.谷|速 读 谷|shudugu\.org|更新不易|邀请码|本章节未完'
      r'|得奇小说网|请记住本站|一秒记住|最新网址|\(本章完\)|（本章完）)');

  Future<(String, String, String)> _token(String bid, String cid) async {
    final url = '$_base/scripts/chapter.js.php?aid=$bid&cid=$cid&referrer=$_base/books/$bid/$cid.html';
    final (js, _) = await _get(
      url,
      referer: '$_base/books/$bid/$cid.html',
      maxBytes: 2 * 1024 * 1024,
    );
    final m = RegExp(
            r"chapterToken = '([^']*)'[\s\S]*?timestamp = (\d+)[\s\S]*?nonce = '([^']*)'")
        .firstMatch(js);
    if (m == null) throw SourceException('得奇小说网：这一章没拿到正文 token');
    return (m.group(1)!, m.group(2)!, m.group(3)!);
  }

  @override
  Future<Content> content(Chapter chapter) async {
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length);
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    final m = RegExp(r'^(\d+)/(\d+)(?:\.html)?').firstMatch(v);
    if (m == null) throw SourceException('得奇小说网章节地址不对：${chapter.url}');
    final bid = m.group(1)!;
    final cid = m.group(2)!;
    final pageUrl = '$_base/books/$bid/$cid.html';

    final (html, _) = await _get(pageUrl);
    final tm = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false).firstMatch(html);
    var title = tm == null ? '' : _text(tm.group(1)!);
    title = title.replaceFirst(RegExp(r'\s*\(第[^)]*页\)\s*$'), '');

    final (token, ts, nonce) = await _token(bid, cid);
    final api = '$_base/modules/article/ajax2.php?aid=$bid&cid=$cid'
        '&token=${Uri.encodeComponent(token)}&timestamp=$ts&nonce=${Uri.encodeComponent(nonce)}';
    final (raw, _) = await _get(api, xhr: true, referer: pageUrl, maxBytes: 3 * 1024 * 1024);

    dynamic payload;
    try {
      payload = jsonDecode(raw);
    } catch (_) {
      throw SourceException('得奇小说网：正文接口返回的不是 JSON');
    }
    if (payload is! Map) throw SourceException('得奇小说网：正文接口返回格式异常');
    if ('${payload['status'] ?? ''}' != '1') {
      throw SourceException('得奇小说网：正文接口拒绝了请求（${payload['message'] ?? 'status!=1'}）');
    }
    final data = payload['data'];
    final body = data is Map ? ('${data['content'] ?? ''}') : '';
    if (body.trim().isEmpty) throw SourceException('这一章没有取到内容');

    final paras = <String>[];
    for (final line in _text(body).split('\n')) {
      final l = line.trim();
      if (l.isEmpty || _junk.hasMatch(l)) continue;
      paras.add(l);
    }
    // 站点把章节名写在正文第一行，去掉以免重复
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

  // ---------- 发现：榜单 / 书库 ----------

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'allvisit', name: '总点击', isRank: true),
    DiscoverTab(key: 'monthvisit', name: '月点击', isRank: true),
    DiscoverTab(key: 'allvote', name: '总推荐', isRank: true),
    DiscoverTab(key: 'goodnum', name: '收藏', isRank: true),
    DiscoverTab(key: 'words', name: '字数', isRank: true),
    DiscoverTab(key: 'newhot', name: '新书', isRank: true),
    DiscoverTab(key: 'full', name: '全本', isRank: true),
  ];

  static const List<DiscoverTab> _cats = [
    DiscoverTab(key: '1', name: '玄幻', isRank: false),
    DiscoverTab(key: '2', name: '都市', isRank: false),
    DiscoverTab(key: '3', name: '仙侠', isRank: false),
    DiscoverTab(key: '4', name: '历史', isRank: false),
    DiscoverTab(key: '5', name: '科幻', isRank: false),
    DiscoverTab(key: '6', name: '诸天无限', isRank: false),
    DiscoverTab(key: '7', name: '悬疑', isRank: false),
    DiscoverTab(key: '8', name: '体育', isRank: false),
    DiscoverTab(key: '9', name: '游戏', isRank: false),
    DiscoverTab(key: '10', name: '综合', isRank: false),
  ];

  @override
  List<DiscoverTab> get discoverTabs => [..._ranks, ..._cats];

  int _maxPage(String html, RegExp re) {
    var max = 1;
    for (final m in re.allMatches(html)) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  Future<DiscoverResult> _rank(String kind, int page) async {
    if (page < 1) page = 1;
    final title =
        _ranks.firstWhere((t) => t.key == kind, orElse: () => _ranks.first).name;
    var total = 1;
    // 站点间歇返回 404 / 反爬小页 → 解析 0 本，用新鲜响应重试（_get 不走缓存）。
    for (var attempt = 0; attempt < 3; attempt++) {
      var url = kind == 'full'
          ? '$_base/modules/article/toplist.php?order=allvisit&fullflag=1&page=$page'
          : '$_base/top/$kind/$page.html';
      final (h, _) = await _get(url, idleTimeout: const Duration(seconds: 30));
      final html = h;
      total = kind == 'full'
          ? _maxPage(html, RegExp(r'fullflag=1&(?:amp;)?page=(\d+)'))
          : _maxPage(html, RegExp('/top/${RegExp.escape(kind)}/(\\d+)\\.html'));
      if (page > total) {
        page = total;
        // 用修正页码重新拉一次（下轮循环），避免返回空榜
        continue;
      }
      final books = _rows(html).map(_rowToBook).toList();
      if (books.isNotEmpty) {
        return DiscoverResult(
          title: '$title榜',
          books: books,
          page: page,
          pages: total,
        );
      }
      if (attempt < 2) {
        await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw SourceException('得奇小说网：这个榜单暂时取不到内容');
  }

  Future<DiscoverResult> _category(String cid, int page) async {
    if (!_cats.any((t) => t.key == cid)) cid = '1';
    final name =
        _cats.firstWhere((t) => t.key == cid, orElse: () => _cats.first).name;
    if (page < 1) page = 1;
    var total = 1;
    // 空结果重试（站点间歇反爬 / 404）
    for (var attempt = 0; attempt < 3; attempt++) {
      final url = '$_base/sort/$cid/$page.html';
      final (html, _) = await _get(url, idleTimeout: const Duration(seconds: 30));
      total =
          _maxPage(html, RegExp('/sort/${RegExp.escape(cid)}/(\\d+)\\.html'));
      if (page > total) {
        page = total;
        continue; // 修正页码重新拉
      }
      final books = _rows(html).map(_rowToBook).toList();
      if (books.isNotEmpty) {
        return DiscoverResult(
          title: '$name小说',
          books: books,
          page: page,
          pages: total,
        );
      }
      if (attempt < 2) {
        await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    return DiscoverResult(
      title: '$name小说',
      books: const [],
      page: page,
      pages: total,
    );
  }

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) {
    if (isRank) {
      final k = _ranks.any((t) => t.key == key) ? key : 'allvisit';
      return _rank(k, page);
    }
    return _category(key, page);
  }
}
