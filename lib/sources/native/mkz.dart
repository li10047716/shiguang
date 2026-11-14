/// 漫客栈（mkzhan.com）漫画源。
///
/// 移植自 shiguang `reader/mkz.py`：
///   - 网页负责榜单（HTML），内容走 comic.mkzcdn.com JSON 接口
///     （详情 / 目录 / 每话图片列表）
///   - 图片是 content.mkzcdn.com CDN，地址带 auth_key 签名、有时效
///   - 搜索/分类接口要登录签名，所以「搜索」退化为链接探测（粘贴作品地址）
///   - 章节没有正文段落，只有一串图片地址 → Content(kind=comic, pages)
///
/// 书籍 id 用 `mkz:<bid>`，章节 url 用 `mkz://<bid>/<cid>`。
library;

import 'dart:convert';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _web = 'https://www.mkzhan.com';
const String _api = 'https://comic.mkzcdn.com';
const String _prefix = 'mkz:';
const String _scheme = 'mkz://';
const String _imgQ = '!page-800-x';
const String _ua =
    'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

class MkzSource extends SourceBase {
  @override
  String get sourceId => 'mkz';
  @override
  String get sourceName => '漫客栈';
  @override
  ContentType get type => ContentType.comic;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_web/'};

  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Accept': 'application/json, text/html, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': '$_web/',
      };

  String _clean(String? s) {
    var str = (s ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"');
    return str.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _img(String? u) {
    var url = (u ?? '').replaceAll(r'\/', '/').trim();
    if (url.isEmpty) return '';
    if (url.contains('!')) return url;
    return url + _imgQ;
  }

  Future<dynamic> _get(String path, Map<String, String> params) async {
    final q = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final raw = await HttpClient.getText(
      '$_api$path?$q',
      charset: 'utf-8',
      headers: _headers,
      maxBytes: 4 * 1024 * 1024,
      useCache: false,
    );
    final data = jsonDecode(raw);
    if (data is! Map) throw SourceException('漫画接口返回的不是 JSON');
    if ('${data['code'] ?? ''}' != '200') {
      throw SourceException(data['message']?.toString() ?? '漫画接口出错了');
    }
    return data['data'];
  }

  String _bookId(String bookUrl) {
    var v = bookUrl.trim();
    if (v.startsWith(_scheme)) v = v.substring(_scheme.length);
    if (v.startsWith(_prefix)) v = v.substring(_prefix.length);
    return v.split('/').first.trim();
  }

  Future<String> _authorName(String authorId) async {
    if (authorId.trim().isEmpty) return '';
    try {
      final d = await _get('/author/info/', {'author_id': authorId});
      if (d is Map) return _clean(d['title']?.toString());
    } catch (_) {}
    return '';
  }

  // ---------- 目录 ----------

  Future<List<Chapter>> _chapters(String bid) async {
    final data = await _get('/chapter/v1/', {'comic_id': bid});
    final rows = data is List ? data : ((data is Map ? data['list'] : null) ?? []);
    final out = <Chapter>[];
    if (rows is List) {
      for (final c in rows) {
        if (c is! Map) continue;
        final cid = (c['chapter_id'] ?? '').toString();
        if (cid.isEmpty) continue;
        var t = _clean(c['title']?.toString());
        if (t.isEmpty) t = '第${c['number'] ?? ''}话';
        out.add(Chapter(title: t, url: '$_scheme$bid/$cid'));
      }
    }
    // 接口基本正序，仍按话号兜底
    double num(Chapter c) {
      final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(c.title);
      return m == null ? 0.0 : double.tryParse(m.group(1)!) ?? 0.0;
    }

    if (out.length > 2 && num(out.first) > num(out.last)) {
      out.sort((a, b) => num(a).compareTo(num(b)));
    }
    return out;
  }

  // ---------- 搜索（链接探测） ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final s = keyword.trim();
    final m = RegExp(r'(?:mkzhan\.com|mkzcdn\.com)/(?:comic/)?(\d{4,8})',
            caseSensitive: false)
        .firstMatch(s);
    var bid = m?.group(1) ?? '';
    if (bid.isEmpty) {
      var v = s;
      if (v.startsWith(_scheme)) v = v.substring(_scheme.length);
      if (v.startsWith(_prefix)) v = v.substring(_prefix.length);
      final nid = v.split('/').first.trim();
      if (RegExp(r'^\d{4,8}$').hasMatch(nid)) bid = nid;
    }
    if (bid.isEmpty && RegExp(r'^\d{4,8}$').hasMatch(s)) bid = s;
    if (bid.isEmpty) return []; // 关键词搜索需登录签名，不可用
    return [await detail(Book(
      name: '',
      author: '',
      cover: '',
      bookUrl: '$_prefix$bid',
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
    ))];
  }

  // ---------- 详情 ----------

  @override
  Future<Book> detail(Book book) async {
    final bid = _bookId(book.bookUrl);
    if (bid.isEmpty || !RegExp(r'^\d+$').hasMatch(bid)) {
      throw SourceException('漫画地址不合法');
    }
    final info = await _get('/comic/info/', {'comic_id': bid});
    if (info is! Map || (info['title']?.toString() ?? '').isEmpty) {
      throw SourceException('漫客栈没有返回这本漫画的信息');
    }
    final chs = await _chapters(bid);
    if (chs.isEmpty) throw SourceException('这本漫画还没有可读的章节');
    final authorName = await _authorName(info['author_id']?.toString() ?? '');
    return Book(
      name: _clean(info['title']?.toString()),
      author: authorName.isEmpty ? '漫客栈' : authorName,
      cover: _img(info['cover']?.toString()),
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
      lastChapter: _clean(info['chapter_title']?.toString()),
      intro: _clean(info['content']?.toString()),
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final bid = _bookId(book.bookUrl);
    final chs = await _chapters(bid);
    onPageChunk?.call(1, chs);
    onProgress?.call(1, chs.length);
    if (chs.isEmpty) throw SourceException('漫客栈目录为空，规则可能已失效');
    return TocResult(chapters: chs);
  }

  // ---------- 每话图片 ----------

  @override
  Future<Content> content(Chapter chapter) async {
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) v = v.substring(_scheme.length);
    final parts = v.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2 || !RegExp(r'^\d+$').hasMatch(parts[0])) {
      throw SourceException('漫画章节地址不合法');
    }
    final bid = parts[0];
    final cid = parts[1];
    final data = await _get('/chapter/content/v1/', {
      'chapter_id': cid,
      'comic_id': bid,
      'quality': '1',
      'type': '1',
      'format': '1',
    });
    final pageList = data is Map ? data['page'] : null;
    final pages = <String>[];
    if (pageList is List) {
      for (final p in pageList) {
        if (p is Map) {
          final u = _img(p['image']?.toString());
          if (u.isNotEmpty) pages.add(u);
        }
      }
    }
    if (pages.isEmpty) {
      final card = data is Map ? data['read_card'] : null;
      if (card != null && card is Map && card.isNotEmpty) {
        throw SourceException('这一话需要阅读券或付费才能看');
      }
      throw SourceException('这一话没有取到图片，可能已下架');
    }
    return Content(
      title: chapter.title,
      pages: pages,
      kind: ContentType.comic,
    );
  }

  // ---------- 发现：榜单（无翻页，一次给全） ----------

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'popularity', name: '人气榜', isRank: true),
    DiscoverTab(key: 'ascension', name: '上升榜', isRank: true),
    DiscoverTab(key: 'collection', name: '收藏榜', isRank: true),
    DiscoverTab(key: 'comment', name: '热评榜', isRank: true),
    DiscoverTab(key: 'latest', name: '新作榜', isRank: true),
    DiscoverTab(key: 'update', name: '最近更新', isRank: true),
  ];

  @override
  List<DiscoverTab> get discoverTabs => _ranks;

  Future<String> _http(String url) => HttpClient.getText(
        url,
        charset: 'utf-8',
        headers: _headers,
        maxBytes: 8 * 1024 * 1024,
        useCache: false,
      );

  /// 榜单页通用解析：三种卡片（top-list__box-item / top-list__item /
  /// common-comic-item）都带封面链接 + 标题，多数带作者/简介/更新到。
  List<Book> _rankCards(String html) {
    final books = <Book>[];
    final seen = <String>{};
    final re = RegExp(
        r'<div class="(?:top-list__box-item|top-list__item|common-comic-item)');
    for (final chunk in html.split(re).skip(1)) {
      final am = RegExp(r'<a class="cover" href="/(\d{3,8})/"[^>]*>')
          .firstMatch(chunk);
      if (am == null) continue;
      final bid = am.group(1)!;
      if (!seen.add(bid)) continue;
      final nm = RegExp(r'<p class="comic_?_?title"><a[^>]*>(.*?)</a>',
              dotAll: true)
          .firstMatch(chunk);
      final title = nm == null ? '' : _clean(nm.group(1));
      if (title.isEmpty) continue;
      final im = RegExp(r'<img[^>]+data-src="([^"]+)"').firstMatch(chunk);
      final au = RegExp(r'作者：<a[^>]*>([^<]+)</a>').firstMatch(chunk);
      final ft = RegExp(r'<p class="comic-feature">(.*?)</p>', dotAll: true)
          .firstMatch(chunk);
      final up = RegExp(r'更至：<a[^>]*>([^<]+)</a>').firstMatch(chunk);
      var intro = ft == null ? '' : _clean(ft.group(1));
      if (intro.length > 120) intro = intro.substring(0, 120);
      books.add(Book(
        name: title,
        author: au == null ? '' : _clean(au.group(1)),
        cover: im?.group(1) ?? '',
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.comic,
        lastChapter: up == null ? '' : _clean(up.group(1)),
        intro: intro,
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
    const kinds = [
      'popularity', 'ascension', 'collection', 'comment', 'latest', 'update',
    ];
    final kind = kinds.contains(key) ? key : 'popularity';
    final path = kind == 'update' ? '/update/' : '/top/$kind/';
    final html = await _http('$_web$path');
    final books = _rankCards(html);
    final name =
        _ranks.firstWhere((t) => t.key == kind, orElse: () => _ranks.first).name;
    return DiscoverResult(
      title: name,
      books: books,
      page: 1,
      pages: 1,
    );
  }
}
