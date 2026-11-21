/// 爱看吧（ik8.net）抓取层。
///
/// 与八叉书库（bc.dart）同构：帝国 CMS + conapi.php 动态签名正文接口。
/// 差异：
///   - 书籍地址 /book{bid}/，章节 /book{bid}/chapterN.html（bc 是 /novel{bid}/）
///   - 搜索结果卡片 div.col-12.col-md-4 > dl，作者藏在 dd.book_other
///   - 目录在详情页 #chapterlist，分页 /book{bid}/?p=N（1 基，首页无参数）
///   - 榜单 /top/index_N.html，分类 /booklist{cid}/N.html（0 基）
/// 书籍 id 用 ik8:{bid} 编码进 bookUrl，章节 url 用 ik8://{bid}/chapterN.html。
library;

import 'dart:convert';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _base = 'https://ik8.net';
const String _prefix = 'ik8:';
const String _scheme = 'ik8://';
const String _ua =
    'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Mobile Safari/537.36';

const int _maxTocPages = 60;

class Ik8Source extends SourceBase {
  @override
  String get sourceId => 'ik8';
  @override
  String get sourceName => '爱看吧';
  @override
  ContentType get type => ContentType.novel;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_base/'};

  // ---------- 基础工具 ----------

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
        .replaceAll('&mdash;', '—')
        .replaceAll('&amp;', '&')
        .replaceAll(' ', ' ')
        .replaceAll('　', ' ');
    return s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ').trim();
  }

  String _abs(String href) {
    var h = href.trim();
    if (h.isEmpty) return '';
    if (h.startsWith('//')) return 'https:$h';
    if (h.startsWith('http')) return h;
    return Uri.parse('$_base/').resolve(h).toString();
  }

  String _nativeId(String url) {
    var v = url.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length);
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    return v.split(RegExp(r'[/.?]')).first;
  }

  /// 取 <dd class="book_other">标签：内容 里的纯文本（去掉「标签：」前缀）
  String _ddText(String chunk, String label) {
    final m = RegExp(
      '<dd[^>]*>\\s*${RegExp.escape(label)}[：:]\\s*([\\s\\S]{0,200}?)</dd>',
    ).firstMatch(chunk);
    if (m == null) return '';
    return _text(m.group(1)!);
  }

  // ---------- 网络 ----------

  Future<String> _get(String url, {int maxBytes = 5 * 1024 * 1024}) {
    return HttpClient.getText(
      url,
      charset: 'utf-8',
      headers: {
        'User-Agent': _ua,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': '$_base/',
      },
      maxBytes: maxBytes,
      idleTimeout: const Duration(seconds: 10),
      headerTimeout: const Duration(seconds: 15),
      totalTimeout: const Duration(seconds: 30),
    );
  }

  // ---------- 列表卡片 ----------

  List<Map<String, String>> _cards(String html) {
    final parts = html.split('<div class="col-12 col-md-4">');
    final cards = <Map<String, String>>[];
    final seen = <String>{};
    for (var i = 1; i < parts.length; i++) {
      final chunk = parts[i].split('<div class="col-12 col-md-4">').first;
      final hm = RegExp(r'href="(/book(\d+)/)"').firstMatch(chunk);
      if (hm == null) continue;
      final bid = hm.group(2)!;
      if (!seen.add(bid)) continue;

      final tm = RegExp(r'<h3[^>]*>\s*<a[^>]*>([^<]*)</a>').firstMatch(chunk);
      final title = tm == null ? '' : _text(tm.group(1)!);
      if (title.isEmpty) continue;
      final cm = RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(chunk);

      cards.add({
        'id': '$_prefix$bid',
        'title': title,
        'author': _ddText(chunk, '作者'),
        'cover': cm == null ? '' : _abs(cm.group(1)!),
        'latest': _ddText(chunk, '最新章节'),
        'status': _ddText(chunk, '状态'),
      });
    }
    return cards;
  }

  Book _cardToBook(Map<String, String> c) => Book(
        name: c['title'] ?? '',
        author: c['author'] ?? '',
        cover: c['cover'] ?? '',
        bookUrl: c['id'] ?? '',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        lastChapter: c['latest'] ?? '',
        intro: '',
      );

  // ---------- 搜索 ----------

  Future<String> _searchId(String keyword) async {
    final url = '$_base/e/search/index.php?keyboard=${Uri.encodeComponent(keyword)}'
        '&show=title,writer,byr&searchget=1';
    try {
      final (_, finalUrl) = await HttpClient.getTextDetailed(
        url,
        charset: 'utf-8',
        headers: {'User-Agent': _ua, 'Referer': '$_base/'},
        maxBytes: 2 * 1024 * 1024,
      );
      final m = RegExp(r'searchid=(\d+)').firstMatch(finalUrl);
      return m?.group(1) ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final sid = await _searchId(kw);
    if (sid.isEmpty) return [];
    final p = page < 1 ? 1 : page;
    // 第 1 页 /result/?searchid=N；第 N 页 page=N-1（站点 0 基）
    final url = p == 1
        ? '$_base/e/search/result/?searchid=$sid'
        : '$_base/e/search/result/index.php?page=${p - 1}&searchid=$sid';
    final html = await _get(url);
    return _cards(html).map(_cardToBook).toList();
  }

  // ---------- 详情 ----------

  String _meta(String html, String prop) {
    final m = RegExp(
      '<meta[^>]*property="og:novel:${RegExp.escape(prop)}"[^>]*content="([^"]*)"',
    ).firstMatch(html);
    return m == null ? '' : _text(m.group(1)!);
  }

  @override
  Future<Book> detail(Book book) async {
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少爱看吧书籍 id');
    final html = await _get('$_base/book$bid/', maxBytes: 6 * 1024 * 1024);

    var title = _meta(html, 'book_name');
    if (title.isEmpty) {
      final tm = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(html);
      title = tm == null ? '书籍$bid' : _text(tm.group(1)!).split('_').first;
    }
    final cm = RegExp(r'<meta[^>]*property="og:image"[^>]*content="([^"]*)"')
        .firstMatch(html);
    final dm = RegExp(r'<div id="intro_pc"[^>]*>([\s\S]*?)</div>')
        .firstMatch(html);
    var intro = '';
    if (dm != null) {
      intro = _text(dm.group(1)!)
          .replaceFirst(RegExp(r'^小说介绍[：:]\s*'), '')
          .replaceAll(RegExp(r'您要是觉得[\s\S]*$'), '')
          .trim();
    }
    final chapters = await _fetchToc(bid);

    return Book(
      name: title,
      author: _meta(html, 'author'),
      cover: cm == null ? '' : _abs(cm.group(1)!),
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.novel,
      lastChapter: chapters.isEmpty ? '' : chapters.last.title,
      intro: intro,
    );
  }

  // ---------- 目录 ----------

  List<Chapter> _tocChapters(String html, String bid) {
    final i = html.indexOf('id="chapterlist"');
    var seg = i > 0 ? html.substring(i) : html;
    final cut = seg.indexOf('class="pages"');
    if (cut > 0) seg = seg.substring(0, cut);
    final chapters = <Chapter>[];
    final re = RegExp(
      r'<a href="/book' + RegExp.escape(bid) +
          r'/(chapter\d+\.html)"[^>]*title="([^"]*)"',
    );
    for (final m in re.allMatches(seg)) {
      final label = _text(m.group(2)!);
      if (label.isEmpty) continue;
      chapters.add(Chapter(title: label, url: '$_scheme$bid/${m.group(1)!}'));
    }
    return chapters;
  }

  int _tocPages(String html, String bid) {
    final re = RegExp('/book${RegExp.escape(bid)}/\\?p=(\\d+)');
    var max = 1;
    for (final m in re.allMatches(html)) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  Future<List<Chapter>> _fetchToc(String bid) async {
    final first = await _get('$_base/book$bid/', maxBytes: 6 * 1024 * 1024);
    final total = _tocPages(first, bid).clamp(1, _maxTocPages);
    final chapters = _tocChapters(first, bid);
    if (total > 1) {
      final lists = await Future.wait([
        for (var n = 2; n <= total; n++) _safeToc(bid, n),
      ]);
      for (final list in lists) {
        chapters.addAll(list);
      }
    }
    final seen = <String>{};
    return chapters.where((c) => seen.add(c.url)).toList();
  }

  Future<List<Chapter>> _safeToc(String bid, int n) async {
    try {
      final html = await _get('$_base/book$bid/?p=$n');
      return _tocChapters(html, bid);
    } catch (_) {
      return [];
    }
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少爱看吧书籍 id');
    final chapters = await _fetchToc(bid);
    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    if (chapters.isEmpty) throw SourceException('爱看吧目录为空，规则可能已失效');
    return TocResult(chapters: chapters);
  }

  // ---------- 正文 ----------

  String _pick(String html, String key) {
    var m = RegExp('"$key"\\s*:\\s*"([^"]*)"').firstMatch(html);
    if (m != null) return m.group(1)!.trim();
    m = RegExp('"$key"\\s*:\\s*([^,\\s}]+)').firstMatch(html);
    return m?.group(1)?.trim() ?? '';
  }

  List<String> _split(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<List<String>> _fetchContent(String html, String chapUrl) async {
    const keys = ['url', 'mobile', 'isk', 'novel', 'chapter', 't', 'n', 'sign'];
    final params = <String, String>{for (final k in keys) k: _pick(html, k)};
    if (params['url']!.isEmpty || params['sign']!.isEmpty) return [];

    final body = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    Object? lastError;
    for (var i = 0; i < 3; i++) {
      try {
        final raw = await HttpClient.getText(
          '$_base/conapi.php',
          charset: 'utf-8',
          method: 'POST',
          body: body,
          headers: {
            'User-Agent': _ua,
            'Accept': 'application/json, text/javascript, */*; q=0.01',
            'x-requested-with': 'XMLHttpRequest',
            'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
            'origin': _base,
            'referer': chapUrl,
            'accept-language': 'zh-CN,zh;q=0.9',
          },
          maxBytes: 3 * 1024 * 1024,
          useCache: false,
        );
        final data = jsonDecode(raw);
        if (data is Map) {
          final success = '${data['success'] ?? ''}';
          final content = data['content'];
          if (success.isNotEmpty &&
              success != '0' &&
              success != 'false' &&
              content != null &&
              content.toString().isNotEmpty) {
            return _split(content.toString());
          }
        }
        lastError = '接口没有返回正文';
      } catch (e) {
        lastError = e;
      }
      await Future.delayed(Duration(milliseconds: 600 * (i + 1)));
    }
    throw SourceException('爱看吧正文接口失败：$lastError');
  }

  @override
  Future<Content> content(Chapter chapter) async {
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length);
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    final m = RegExp(r'^(\d+)/(chapter\d+\.html)').firstMatch(v);
    if (m == null) throw SourceException('爱看吧章节地址不对：${chapter.url}');
    final chapUrl = '$_base/book${m.group(1)!}/${m.group(2)!}';
    final html = await _get(chapUrl);

    var title = '';
    final tm = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(html);
    if (tm != null) {
      final parts = _text(tm.group(1)!).split('_');
      title = parts.length > 1 ? parts[1] : parts.first;
    }
    final paras = await _fetchContent(html, chapUrl);
    if (paras.isEmpty) throw SourceException('这一章没有取到内容');
    return Content(title: title, paras: paras);
  }

  // ---------- 发现：榜单 / 分类 ----------

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'top', name: '热门排行', isRank: true),
  ];

  static const List<DiscoverTab> _cats = [
    DiscoverTab(key: '1', name: '长篇', isRank: false),
    DiscoverTab(key: '2', name: '综合', isRank: false),
    DiscoverTab(key: '3', name: '武侠', isRank: false),
    DiscoverTab(key: '4', name: '历史', isRank: false),
    DiscoverTab(key: '5', name: '都市', isRank: false),
    DiscoverTab(key: '6', name: '玄幻', isRank: false),
    DiscoverTab(key: '7', name: '女生', isRank: false),
    DiscoverTab(key: '8', name: '其他', isRank: false),
    DiscoverTab(key: '9', name: '现代', isRank: false),
  ];

  @override
  List<DiscoverTab> get discoverTabs => [..._ranks, ..._cats];

  int _lastPage(String html, String linkPat) {
    var max = 1;
    for (final m in RegExp(linkPat).allMatches(html)) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  Future<DiscoverResult> _rank(int page) async {
    if (page < 1) page = 1;
    var url = page == 1 ? '$_base/top/' : '$_base/top/index_$page.html';
    var html = await _get(url);
    final total = _lastPage(html, r'/top/index_(\d+)\.html');
    if (page > total) {
      page = total;
      url = page == 1 ? '$_base/top/' : '$_base/top/index_$page.html';
      html = await _get(url);
    }
    return DiscoverResult(
      title: '热门排行',
      books: _cards(html).map(_cardToBook).toList(),
      page: page,
      pages: total,
    );
  }

  Future<DiscoverResult> _category(String cid, int page) async {
    if (!_cats.any((t) => t.key == cid)) cid = '1';
    if (page < 1) page = 1;
    var url = '$_base/booklist$cid/${page - 1}.html';
    var html = await _get(url);
    final total = _lastPage(html, '/booklist${RegExp.escape(cid)}/(\\d+)\\.html') + 1;
    if (page > total) {
      page = total;
      url = '$_base/booklist$cid/${page - 1}.html';
      html = await _get(url);
    }
    final name = _cats.firstWhere((t) => t.key == cid).name;
    return DiscoverResult(
      title: '$name小说',
      books: _cards(html).map(_cardToBook).toList(),
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
    return isRank ? _rank(page) : _category(key, page);
  }
}
