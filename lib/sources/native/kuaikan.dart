/// 快看漫画（kuaikanmanhua.com）漫画源。
///
/// 移植自 shiguang `reader/kuaikan.py`（Nuxt1 服务端渲染）：
///   - 详情/目录/每话数据嵌在页面 `window.__NUXT__` 脚本里，用 [parseNuxt] 还原
///   - 搜索是明文 JSON 接口（search/mini/topic/title_and_author），不用登录签名
///   - 图片 CDN（p1.kkmh.com）地址带 sign 签名，去掉会 403，打开每话页时现发
///   - 付费话站点只给 3 张预览图，目录里标 🔒
///
/// 书籍 id 用 `kk:<tid>`，章节 url 用 `kk://<tid>/<cid>`。
library;

import 'dart:convert';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../../utils/nuxtparse.dart';
import '../novel_source.dart';
import '../source.dart';

const String _web = 'https://m.kuaikanmanhua.com';
const String _prefix = 'kk:';
const String _scheme = 'kk://';
const String _ua =
    'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

class KuaikanSource extends SourceBase {
  @override
  String get sourceId => 'kk';
  @override
  String get sourceName => '快看漫画';
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
    return (s ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  String _tid(String v) {
    var s = v.trim();
    if (s.startsWith(_scheme)) s = s.substring(_scheme.length);
    if (s.startsWith(_prefix)) s = s.substring(_prefix.length);
    s = s.split('/').first.trim();
    if (!RegExp(r'^\d{1,10}$').hasMatch(s)) {
      throw SourceException('漫画地址不合法：${s.length > 40 ? s.substring(0, 40) : s}');
    }
    return s;
  }

  Future<String> _http(String url, {int maxBytes = 8 * 1024 * 1024}) =>
      HttpClient.getText(
        url,
        charset: 'utf-8',
        headers: _headers,
        maxBytes: maxBytes,
        idleTimeout: const Duration(seconds: 20),
      );

  /// 抓页面并解析 __NUXT__，返回 data[0]。
  Future<Map<String, dynamic>> _nuxtPage(String url) async {
    final html = await _http(url);
    final d = parseNuxt(html);
    if (d is! Map) throw SourceException('页面数据解析失败，站点可能改版了');
    final data = d['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw SourceException('页面数据是空的，这本漫画可能已下架');
    }
    return (data.first as Map).cast<String, dynamic>();
  }

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final p = page < 1 ? 1 : page;
    final url =
        '$_web/search/mini/topic/title_and_author?page=$p&size=24&q=${Uri.encodeComponent(kw)}';
    final raw = await _http(url);
    final d = jsonDecode(raw);
    if (d is! Map) throw SourceException('搜索接口返回的不是 JSON');
    if ('${d['code'] ?? ''}' != '200') {
      throw SourceException(d['message']?.toString() ?? '搜索接口出错了');
    }
    final hits = d['hits'];
    final books = <Book>[];
    if (hits is List) {
      for (final h in hits) {
        if (h is! Map) continue;
        final tid = (h['topic_id'] ?? h['id'] ?? '').toString();
        if (!RegExp(r'^\d+$').hasMatch(tid)) continue;
        final title = _clean(h['title']?.toString());
        if (title.isEmpty) continue;
        books.add(Book(
          name: title,
          author: _clean(h['author_name']?.toString()),
          cover: (h['vertical_image_url'] ?? h['cover_image_url'] ?? '').toString(),
          bookUrl: '$_prefix$tid',
          sourceId: sourceId,
          sourceName: sourceName,
          type: ContentType.comic,
          lastChapter: _clean(h['latest_comic_title']?.toString()),
          intro: _clean(h['description']?.toString()),
        ));
      }
    }
    return books;
  }

  // ---------- 详情 / 目录 ----------

  List<Chapter> _chapters(Map<String, dynamic> d0) {
    final out = <Chapter>[];
    final topicId = (d0['topicInfo'] is Map)
        ? (d0['topicInfo'] as Map)['id']?.toString() ?? ''
        : '';
    final list = d0['comicList'];
    if (list is List) {
      for (final c in list) {
        if (c is! Map) continue;
        final cid = (c['id'] ?? '').toString();
        var t = _clean(c['title']?.toString());
        if (cid.isEmpty || t.isEmpty) continue;
        if (!(c['is_free'] == true || c['can_view'] == true)) {
          t += ' 🔒'; // 付费话只能看几页预览，提前说清楚
        }
        out.add(Chapter(title: t, url: '$_scheme$topicId/$cid'));
      }
    }
    return out;
  }

  @override
  Future<Book> detail(Book book) async {
    final tid = _tid(book.bookUrl);
    final d0 = await _nuxtPage('$_web/mobile/$tid/list/');
    final ti = d0['topicInfo'];
    final chs = _chapters(d0);
    if (chs.isEmpty) throw SourceException('这本漫画还没有可读的章节');
    final title = _clean(ti is Map ? ti['title']?.toString() : '');
    if (title.isEmpty) throw SourceException('页面上没有书名，可能已下架');
    final author = _clean(
        (ti is Map && ti['user'] is Map) ? (ti['user'] as Map)['nickname']?.toString() : '');
    return Book(
      name: title,
      author: author.isEmpty ? sourceName : author,
      cover: (ti is Map)
          ? (ti['vertical_image_url'] ?? ti['cover_image_url'] ?? '').toString()
          : '',
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
      lastChapter: chs.last.title,
      intro: _clean(ti is Map ? ti['description']?.toString() : ''),
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final tid = _tid(book.bookUrl);
    final d0 = await _nuxtPage('$_web/mobile/$tid/list/');
    final chs = _chapters(d0);
    onPageChunk?.call(1, chs);
    onProgress?.call(1, chs.length);
    if (chs.isEmpty) throw SourceException('快看漫画目录为空，规则可能已失效');
    return TocResult(chapters: chs);
  }

  // ---------- 每话图片 ----------

  @override
  Future<Content> content(Chapter chapter) async {
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) v = v.substring(_scheme.length);
    final parts = v.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2 || !RegExp(r'^\d+$').hasMatch(parts[1])) {
      throw SourceException('漫画章节地址不合法');
    }
    _tid(parts[0]); // 校验 tid
    final cid = parts[1];
    final d0 = await _nuxtPage('$_web/mobile/comics/$cid');
    final ci = d0['comicInfo'];
    final pages = <String>[];
    if (ci is Map) {
      // 新版用 comicImages（对象列表，带 url）；老版用 images（字符串列表）
      final imgList = ci['comicImages'] ?? ci['images'];
      if (imgList is List) {
        for (final p in imgList) {
          String u;
          if (p is Map) {
            u = (p['url'] ?? '').toString();
          } else {
            u = p?.toString() ?? '';
          }
          if (u.isNotEmpty) pages.add(u);
        }
      }
    }
    if (pages.isEmpty) {
      throw SourceException('这一话没有取到图片，可能已下架或需要付费');
    }
    return Content(
      title: chapter.title,
      pages: pages,
      kind: ContentType.comic,
    );
  }

  // ---------- 发现：分类（无榜单） ----------

  static const List<DiscoverTab> _cats = [
    DiscoverTab(key: '0', name: '全部', isRank: false),
    DiscoverTab(key: '20', name: '恋爱', isRank: false),
    DiscoverTab(key: '46', name: '古风', isRank: false),
    DiscoverTab(key: '77', name: '大女主', isRank: false),
    DiscoverTab(key: '80', name: '穿越', isRank: false),
    DiscoverTab(key: '74', name: '校园', isRank: false),
    DiscoverTab(key: '63', name: '玄幻', isRank: false),
    DiscoverTab(key: '52', name: '总裁', isRank: false),
    DiscoverTab(key: '48', name: '都市', isRank: false),
    DiscoverTab(key: '22', name: '奇幻', isRank: false),
    DiscoverTab(key: '67', name: '热血', isRank: false),
    DiscoverTab(key: '23', name: '剧情', isRank: false),
    DiscoverTab(key: '65', name: '悬疑', isRank: false),
    DiscoverTab(key: '85', name: '武侠', isRank: false),
    DiscoverTab(key: '71', name: '搞笑', isRank: false),
    DiscoverTab(key: '54', name: '治愈', isRank: false),
    DiscoverTab(key: '62', name: '萌系', isRank: false),
    DiscoverTab(key: '68', name: '异能', isRank: false),
    DiscoverTab(key: '86', name: '系统', isRank: false),
    DiscoverTab(key: '89', name: '重生', isRank: false),
    DiscoverTab(key: '81', name: '恐怖', isRank: false),
    DiscoverTab(key: '91', name: '末世', isRank: false),
    DiscoverTab(key: '92', name: '非人类', isRank: false),
  ];

  @override
  List<DiscoverTab> get discoverTabs => _cats;

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    if (page < 1) page = 1;
    final d = await _nuxtPage('$_web/tag/$key?state=3&page=$page');
    final rows = d['filerList'];
    final books = <Book>[];
    if (rows is List) {
      for (final b in rows) {
        if (b is! Map) continue;
        final tid = '${b['id'] ?? ''}';
        if (!RegExp(r'^\d+$').hasMatch(tid)) continue;
        final tags = [
          for (final t in (b['tags'] ?? const <dynamic>[]))
            if (t is String && t.isNotEmpty) t,
        ];
        final fav = int.tryParse('${b['favouriteCount'] ?? 0}') ?? 0;
        final heat = fav >= 10000
            ? '${(fav / 10000).toStringAsFixed(1)}万收藏'
            : (fav > 0 ? '$fav' : '');
        final tagStr = tags.take(2).join(' · ');
        books.add(Book(
          name: _clean('${b['title'] ?? ''}'),
          author: '',
          cover: '${b['coverImageUrl'] ?? b['imgSrc'] ?? ''}',
          bookUrl: '$_prefix$tid',
          sourceId: sourceId,
          sourceName: sourceName,
          type: ContentType.comic,
          lastChapter: '',
          intro: [tagStr, heat].where((s) => s.isNotEmpty).join(' · '),
        ));
      }
    }
    final total = int.tryParse('${d['total'] ?? 0}') ?? 0;
    var pages = total > 0 ? ((total + 19) ~/ 20) : 1;
    pages = pages.clamp(1, 500);
    if (books.isEmpty && page > 1) return discover(key, isRank: false, page: pages);
    final name =
        _cats.firstWhere((t) => t.key == key, orElse: () => _cats.first).name;
    return DiscoverResult(
      title: '$name · 第 $page 页',
      books: books,
      page: page,
      pages: pages,
    );
  }
}
