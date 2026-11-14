/// 包子漫画 / G社漫画（manhuafree.com）漫画源。
///
/// 移植自 shiguang `reader/gsh.py`（Astro 静态页 + 第三方接口）：
///   - 搜索/详情抓 HTML；目录走 api-get-v3.mgsearcher.com；每话走 v2.apikk.top
///   - 书号用 slug，mid 只出现在详情页 data-mid，现抓并记住
///   - 每话图片地址是混淆串：截前后缀 → 按位置切三段重排 → 每 7 字符奇数段反转
///     → 64 字符表映射 → base64 → JSON 数组
///
/// 书籍 id 用 `gs:<slug>`，章节 url 用 `gs://<slug>/<cid>`。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _web = 'https://manhuafree.com';
const String _tocApi = 'https://api-get-v3.mgsearcher.com';
const String _chApi = 'https://v2.apikk.top';
const String _cdn = 'https://t-nd2-1.6wm.top';
const String _prefix = 'gs:';
const String _scheme = 'gs://';
const String _ua =
    'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

// 解密用的两张 64 字符表（顺序不能动）
const String _mapSrc =
    '_-9876543210abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
const String _mapTgt =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const int _step = 7;

class GshSource extends SourceBase {
  @override
  String get sourceId => 'gs';
  @override
  String get sourceName => '包子漫画';
  @override
  ContentType get type => ContentType.comic;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_web/'};

  // slug → mid 缓存（内存，跨请求复用）
  static final Map<String, String> _midCache = {};

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
    str = str.replaceAll(RegExp(r'[ \t]+'), ' ');
    return str.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  String _img(String? u) {
    var url = (u ?? '').replaceAll(r'\/', '/').trim();
    if (url.isEmpty) return '';
    if (url.startsWith('http')) return url;
    return _cdn + (url.startsWith('/') ? url : '/$url');
  }

  String _slug(String v) {
    var s = v.trim();
    if (s.startsWith(_scheme)) s = s.substring(_scheme.length);
    if (s.startsWith(_prefix)) s = s.substring(_prefix.length);
    s = s.split('/').first.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9\-]{1,80}$').hasMatch(s)) {
      throw SourceException('漫画地址不合法：$s');
    }
    return s;
  }

  Future<String> _http(String url, {int maxBytes = 20 * 1024 * 1024}) =>
      HttpClient.getText(
        url,
        charset: 'utf-8',
        headers: _headers,
        maxBytes: maxBytes,
        idleTimeout: const Duration(seconds: 30),
      );

  /// 第三方 JSON 接口：用独立 dio 非流式读取（读全量），带重试。
  /// 流式读取会在接口慢速吐数据时被空闲超时截断，这里读完整 body。
  Future<Map<String, dynamic>> _json(String url) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 25),
          receiveTimeout: const Duration(seconds: 90),
          responseType: ResponseType.bytes,
          headers: _headers,
        ));
        final resp = await dio.get<dynamic>(url,
            options: Options(responseType: ResponseType.bytes));
        final bytes = resp.data as List<int>;
        final raw = utf8.decode(bytes, allowMalformed: true);
        final data = jsonDecode(raw);
        if (data is! Map) throw SourceException('漫画接口返回的不是 JSON');
        if ('${data['code'] ?? ''}' != '200') {
          throw SourceException(data['msg']?.toString() ??
              data['message']?.toString() ??
              '漫画接口出错了');
        }
        return data['data'] is Map
            ? (data['data'] as Map).cast<String, dynamic>()
            : {};
      } catch (e) {
        lastError = e;
        await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
    throw SourceException('漫画接口请求失败：$lastError');
  }

  String _parseMid(String html) {
    final m = RegExp(r'data-mid="(\d+)"').firstMatch(html);
    return m?.group(1) ?? '';
  }

  /// slug → mid。先查缓存，没有再抓详情页。
  Future<String> _mid(String slug) async {
    final hit = _midCache[slug];
    if (hit != null) return hit;
    final html = await _http('$_web/manga/$slug');
    final mid = _parseMid(html);
    if (mid.isEmpty) throw SourceException('这个漫画页面上找不到作品编号，可能已下架');
    _midCache[slug] = mid;
    return mid;
  }

  // ---------- 图片解密 ----------

  List<Map<String, dynamic>> _decrypt(String enc) {
    var s = enc.trim();
    if (!(s.startsWith('J7r') && s.endsWith('nQ'))) {
      throw SourceException('漫画图片数据格式变了（前缀/后缀不对）');
    }
    final body = s.substring(3, s.length - 2);
    final total = body.length - 2 - 3;
    final cols = total ~/ 3;
    final rem2 = (total - cols) ~/ 2;
    final rest = total - cols - rem2;

    final a = body.substring(0, rem2);
    final b = body.substring(rem2, rem2 + 2);
    final c = body.substring(rem2 + 2, rem2 + 2 + rest);
    final d = body.substring(rem2 + 2 + rest, rem2 + 2 + rest + 3);
    final e = body.substring(rem2 + 2 + rest + 3);
    if (b != 'kD' || d != 'W4s' || e.length != cols) {
      throw SourceException('漫画图片数据格式变了（标记位不对）');
    }

    final joined = e + a + c;
    final parts = <String>[];
    for (var i = 0; i < joined.length; i += _step) {
      var part = joined.substring(i, (i + _step).clamp(0, joined.length));
      if ((i ~/ _step) % 2 == 1) part = part.split('').reversed.join();
      parts.add(part);
    }
    final swapped = parts.join();

    final mapped = StringBuffer();
    for (final ch in swapped.split('')) {
      final idx = _mapSrc.indexOf(ch);
      if (idx < 0) throw SourceException('漫画图片数据格式变了（字符表对不上）');
      mapped.write(_mapTgt[idx]);
    }
    var b64 = mapped.toString().replaceAll('-', '+').replaceAll('_', '/');
    b64 += '=' * (-b64.length % 4);
    try {
      final raw = base64Decode(b64);
      final rows = jsonDecode(utf8.decode(raw));
      if (rows is! List) throw SourceException('漫画图片数据格式不对');
      return rows.cast<Map<String, dynamic>>();
    } catch (e) {
      if (e is SourceException) rethrow;
      throw SourceException('漫画图片数据解不开');
    }
  }

  // ---------- 目录 ----------

  Future<List<Chapter>> _chapters(String slug) async {
    final mid = await _mid(slug);
    final data = await _json('$_tocApi/api/manga/get?mid=$mid&mode=all');
    final rows = data['chapters'];
    final chapters = <Chapter>[];
    if (rows is List) {
      for (final c in rows) {
        if (c is! Map) continue;
        final cid = (c['id'] ?? '').toString();
        if (cid.isEmpty) continue;
        final attr = c['attributes'];
        final title = _clean(attr is Map ? attr['title']?.toString() : '');
        chapters.add(Chapter(
          title: title.isEmpty ? '第${chapters.length + 1}话' : title,
          url: '$_scheme$slug/$cid',
        ));
      }
    }
    return chapters;
  }

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final p = page < 1 ? 1 : page;
    final url = '$_web/s/${Uri.encodeComponent(kw)}?page=$p';
    final html = await _http(url);
    return _parseCards(html);
  }

  List<Book> _parseCards(String html) {
    final books = <Book>[];
    final seen = <String>{};
    final chunks = html.split('<div class="pb-2"').skip(1);
    for (final chunk in chunks) {
      final am = RegExp(r'<a href="(/manga/[^"]+)"').firstMatch(chunk);
      if (am == null) continue;
      final slug = am.group(1)!.replaceAll(RegExp(r'/$'), '').split('/').last;
      if (!RegExp(r'^[a-z0-9][a-z0-9\-]{1,80}$').hasMatch(slug) ||
          !seen.add(slug)) {
        continue;
      }
      final tm = RegExp(r'class="cardtitle"[^>]*>(.*?)</h3>', dotAll: true)
          .firstMatch(chunk);
      final title = tm == null ? '' : _clean(tm.group(1));
      if (title.isEmpty) continue;
      final im = RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(chunk);
      books.add(Book(
        name: title,
        author: '',
        cover: im?.group(1) ?? '',
        bookUrl: '$_prefix$slug',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.comic,
        lastChapter: '',
        intro: '',
      ));
    }
    return books;
  }

  // ---------- 详情 ----------

  @override
  Future<Book> detail(Book book) async {
    final slug = _slug(book.bookUrl);
    final html = await _http('$_web/manga/$slug');
    final mid = _parseMid(html);
    if (mid.isEmpty) throw SourceException('这个漫画页面上找不到作品编号，可能已下架');
    _midCache[slug] = mid;

    var title = '';
    final h1 = RegExp(r'<h1[^>]*text-xl[^>]*>(.*?)</h1>', dotAll: true)
        .firstMatch(html);
    if (h1 != null) {
      title = _clean(h1.group(1)!.split('<span').first);
    }
    var author = '';
    final am = RegExp(r'作者：\s*</span>\s*<a[^>]*>\s*<span>\s*([^<]+?)\s*</span>',
            dotAll: true)
        .firstMatch(html);
    if (am != null) author = _clean(am.group(1));

    final data = await _json('$_tocApi/api/manga/get?mid=$mid&mode=all');
    final chs = await _chapters(slug);
    if (chs.isEmpty) throw SourceException('这本漫画还没有可读的章节');

    return Book(
      name: _clean(data['title']?.toString()).isEmpty
          ? title
          : _clean(data['title']?.toString()),
      author: author.isEmpty ? sourceName : author,
      cover: _img(data['cover']?.toString()),
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
      lastChapter: chs.last.title,
      intro: _clean(data['desc']?.toString()),
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final slug = _slug(book.bookUrl);
    final chs = await _chapters(slug);
    onPageChunk?.call(1, chs);
    onProgress?.call(1, chs.length);
    if (chs.isEmpty) throw SourceException('包子漫画目录为空，规则可能已失效');
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
    final slug = _slug(parts[0]);
    final cid = parts[1];
    final mid = await _mid(slug);
    final data = await _json('$_chApi/api/v2/chapter/getinfo?m=$mid&c=$cid');
    final info = data['info'];
    final images = info is Map ? info['images'] : null;
    final enc = images is Map ? (images['images']?.toString() ?? '') : '';
    final rows = _decrypt(enc);
    rows.sort((a, b) => ((a['order'] ?? 0) as num).compareTo((b['order'] ?? 0) as num));
    final pages = <String>[];
    for (final r in rows) {
      final u = _img(r['url']?.toString());
      if (u.isNotEmpty) pages.add(u);
    }
    if (pages.isEmpty) throw SourceException('这一话没有取到图片，可能已下架或需要付费');

    return Content(
      title: chapter.title,
      pages: pages,
      kind: ContentType.comic,
    );
  }

  // ---------- 发现：榜单 / 全库 ----------

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'hots', name: '人气推荐', isRank: true),
    DiscoverTab(key: 'dayup', name: '热门更新', isRank: true),
    DiscoverTab(key: 'newss', name: '最新上架', isRank: true),
  ];
  static const List<DiscoverTab> _cats = [
    DiscoverTab(key: 'manga', name: '全部类型', isRank: false),
  ];

  @override
  List<DiscoverTab> get discoverTabs => [..._ranks, ..._cats];

  /// 列表页通用解析（/hots /dayup /newss /manga，/page/N 翻页）。
  Future<DiscoverResult> _listPage(String path, int page) async {
    if (page < 1) page = 1;
    final url = page > 1 ? '$_web$path/page/$page' : '$_web$path';
    final html = await _http(url);
    final books = <Book>[];
    final seen = <String>{};
    for (final chunk in html.split('<div class="pb-2"').skip(1)) {
      final am = RegExp(r'<a href="(/manga/[^"]+)"').firstMatch(chunk);
      if (am == null) continue;
      final slug =
          am.group(1)!.replaceAll(RegExp(r'/$'), '').split('/').last;
      if (!RegExp(r'^[a-z0-9][a-z0-9\-]{1,80}$').hasMatch(slug) ||
          !seen.add(slug)) {
        continue;
      }
      final tm =
          RegExp(r'class="cardtitle"[^>]*>(.*?)</h3>', dotAll: true)
              .firstMatch(chunk);
      final title = tm == null ? '' : _clean(tm.group(1));
      if (title.isEmpty) continue;
      final im = RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(chunk);
      books.add(Book(
        name: title,
        author: '',
        cover: im?.group(1) ?? '',
        bookUrl: '$_prefix$slug',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.comic,
        lastChapter: '',
        intro: '漫画',
      ));
    }
    var pages = 1;
    final re = RegExp('href="${RegExp.escape(path)}/page/(\\d+)"');
    for (final m in re.allMatches(html)) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n > pages) pages = n;
    }
    pages = pages.clamp(1, 200);
    if (page > pages) return _listPage(path, pages);
    final label = path.replaceAll('/', '') == 'manga'
        ? '全部类型'
        : path.replaceAll('/', '');
    return DiscoverResult(
      title: '$label · 第 $page 页',
      books: books,
      page: page,
      pages: pages,
    );
  }

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) {
    if (isRank) {
      final k = ['hots', 'dayup', 'newss'].contains(key) ? key : 'hots';
      return _listPage('/$k', page);
    }
    return _listPage('/manga', page);
  }
}
