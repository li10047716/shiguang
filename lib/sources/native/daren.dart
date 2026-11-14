/// 大人漫画（drmh3.com / drmh2.com）漫画源。
///
/// 移植自 shiguang `reader/daren.py`（纯 HTML 抓取，无第三方接口）：
///   - 搜索 `/cata.php?key=<kw>` 的 `li.hl-list-item` 卡片
///   - 详情 `/comics-reading/<id>.html`，标题 `.hl-dc-title`，封面 `data-original`
///   - 目录 同详情页 `li a` → `/comics-reading/<id>/<slug>.html`
///   - 正文 `/comics-reading/<id>/<slug>.html` 的 `img[data-original]`
///   - 图片 CDN 需带 Referer: https://drmh3.com/（防盗链）
///
/// 书籍 id 用 `dr:<cid>`，章节 url 用 `dr://<cid>/<slug>`。
library;

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _web = 'https://drmh3.com';
const String _prefix = 'dr:';
const String _scheme = 'dr://';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

class DarenSource extends SourceBase {
  @override
  String get sourceId => 'dr';
  @override
  String get sourceName => '大人漫画';
  @override
  ContentType get type => ContentType.comic;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_web/'};

  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Referer': '$_web/',
      };

  String _clean(String? s) {
    return (s ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cid(String v) {
    var s = v.trim();
    if (s.startsWith(_scheme)) {
      s = s.substring(_scheme.length);
    } else if (s.startsWith(_prefix)) {
      s = s.substring(_prefix.length);
    }
    s = s.split('/').first.trim();
    if (!RegExp(r'^\d{2,8}$').hasMatch(s)) {
      throw SourceException('漫画地址不合法：$s');
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

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final url = '$_web/cata.php?key=${Uri.encodeComponent(kw)}';
    String html;
    try {
      html = await _http(url);
    } catch (_) {
      return [];
    }
    final books = <Book>[];
    final seen = <String>{};
    final re = RegExp(r'<li class="hl-list-item[^"]*">([\s\S]*?)</li>');
    for (final m in re.allMatches(html)) {
      final chunk = m.group(1)!;
      var href = '';
      var title = '';
      var cover = '';
      final am = RegExp(
              r'<a class="hl-item-thumb[^"]*" href="([^"]+)"[^>]*title="([^"]*)"[^>]*data-original="([^"]*)"')
          .firstMatch(chunk);
      if (am != null) {
        href = am.group(1)!;
        title = am.group(2)!;
        cover = am.group(3)!;
      } else {
        final am2 = RegExp(r'<a[^>]*href="(/comics-reading/[^"]+)"[^>]*>')
            .firstMatch(chunk);
        if (am2 == null) continue;
        href = am2.group(1)!;
        final tm = RegExp(r'title="([^"]*)"').firstMatch(chunk);
        title = tm?.group(1) ?? '';
        final cm = RegExp(r'data-original="([^"]+)"').firstMatch(chunk);
        cover = cm?.group(1) ?? '';
      }
      final mid = RegExp(r'/comics-reading/(\d+)').firstMatch(href);
      if (mid == null) continue;
      final cid = mid.group(1)!;
      if (!seen.add(cid)) continue;
      if (title.isEmpty) {
        final tm = RegExp(r'class="hl-item-title[^"]*"[^>]*>([\s\S]*?)</')
            .firstMatch(chunk);
        title = tm == null ? '' : _clean(tm.group(1));
      }
      if (title.isEmpty) continue;
      books.add(Book(
        name: title,
        author: '',
        cover: cover,
        bookUrl: '$_prefix$cid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.comic,
        lastChapter: '',
        intro: '',
      ));
    }
    return books;
  }

  // ---------- 目录 ----------

  Future<List<Chapter>> _chapters(String cid) async {
    final html = await _http('$_web/comics-reading/$cid.html');
    final out = <Chapter>[];
    final seen = <String>{};
    final re = RegExp(
        '<li[^>]*>\\s*<a href="(/comics-reading/$cid/[^"]+)"[^>]*title="([^"]*)"[^>]*>([\\s\\S]*?)</a>');
    for (final m in re.allMatches(html)) {
      final href = m.group(1)!;
      final ta = m.group(2)!;
      final inner = m.group(3)!;
      final slug = RegExp('/comics-reading/$cid/([^./]+)\\.html').firstMatch(href);
      if (slug == null) continue;
      final name = (ta.isNotEmpty ? ta : _clean(inner)).trim();
      if (name.isEmpty) continue;
      final u = '$_scheme$cid/${slug.group(1)}';
      if (!seen.add(u)) continue;
      out.add(Chapter(title: name, url: u));
    }
    return out;
  }

  // ---------- 详情 ----------

  @override
  Future<Book> detail(Book book) async {
    final cid = _cid(book.bookUrl);
    final html = await _http('$_web/comics-reading/$cid.html');
    var title = '';
    final tm = RegExp(r'class="hl-dc-title[^"]*"[^>]*>([\s\S]*?)</').firstMatch(html);
    if (tm != null) {
      title = _clean(tm.group(1));
    }
    if (title.isEmpty) {
      final tm2 = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(html);
      title = tm2 == null ? '未知漫画' : _clean(tm2.group(1)!).split('-').first.trim();
    }
    final cm = RegExp(
            r'class="hl-dc-pic[^"]*"[^>]*>[\s\S]*?data-original="([^"]+)"')
        .firstMatch(html);
    final chs = await _chapters(cid);
    if (chs.isEmpty) throw SourceException('这本漫画还没有可读的章节');
    return Book(
      name: title,
      author: sourceName,
      cover: cm?.group(1) ?? '',
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
      lastChapter: chs.last.title,
      intro: '',
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final cid = _cid(book.bookUrl);
    final chs = await _chapters(cid);
    onPageChunk?.call(1, chs);
    onProgress?.call(1, chs.length);
    if (chs.isEmpty) throw SourceException('大人漫画目录为空，规则可能已失效');
    return TocResult(chapters: chs);
  }

  // ---------- 每话图片 ----------

  @override
  Future<Content> content(Chapter chapter) async {
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) v = v.substring(_scheme.length);
    final parts = v.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2 || !RegExp(r'^\d{2,8}$').hasMatch(parts[0])) {
      throw SourceException('漫画章节地址不合法');
    }
    final cid = parts[0];
    final cslug = parts[1];
    final html = await _http('$_web/comics-reading/$cid/$cslug.html');

    final pages = <String>[];
    final seen = <String>{};
    final imgRe = RegExp(r'<img\b[^>]*>');
    for (final m in imgRe.allMatches(html)) {
      final tag = m.group(0)!;
      String? src;
      for (final attr in ['data-original', 'data-src', 'src']) {
        final mm = RegExp('$attr="([^"]+)"').firstMatch(tag);
        if (mm != null) {
          src = mm.group(1);
          break;
        }
      }
      if (src == null || src.isEmpty) continue;
      final low = src.toLowerCase();
      if (['loading', 'blank', 'data:image', 'yandex', 'logo', 'icon', 'avatar', 'banner']
          .any((x) => low.contains(x))) {
        continue;
      }
      if (!src.startsWith('http')) {
        src = src.startsWith('/') ? '$_web$src' : '$_web/$src';
      }
      if (!seen.add(src)) continue;
      pages.add(src);
    }
    if (pages.isEmpty) throw SourceException('这一话没有取到图片，可能已下架或需要付费');

    var title = '';
    final tm = RegExp(r'<title>([\s\S]*?)\s*[-—]\s*').firstMatch(html);
    if (tm != null) {
      title = _clean(tm.group(1));
    }
    if (title.isEmpty) {
      final tm2 = RegExp(r'class="hl-dc-title[^"]*"[^>]*>([\s\S]*?)</').firstMatch(html);
      title = tm2 == null ? '' : _clean(tm2.group(1));
    }

    return Content(
      title: title.isEmpty ? chapter.title : title,
      pages: pages,
      kind: ContentType.comic,
    );
  }

  // ---------- 发现：榜单 / 分类 ----------

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'all', name: '总榜', isRank: true),
    DiscoverTab(key: 'daily', name: '日榜', isRank: true),
    DiscoverTab(key: 'weekly', name: '周榜', isRank: true),
    DiscoverTab(key: 'monthly', name: '月榜', isRank: true),
  ];

  static const List<(String, String)> _catTheme = [
    ('all', '全部'), ('韩漫', '韩漫'), ('日漫', '日漫'),
    ('真人', '真人'), ('3D漫画', '3D'),
  ];
  static const List<(String, String)> _catState = [
    ('all', ''), ('serialized', '·连载'), ('completed', '·完结'),
  ];

  static final List<DiscoverTab> _cats = [
    for (final (t, name) in _catTheme)
      for (final (s, tag) in _catState)
        DiscoverTab(
          key: '/comics-catalog/$t/ob/hits/st/$s',
          name: name + tag,
          isRank: false,
        ),
  ];

  @override
  List<DiscoverTab> get discoverTabs => [..._ranks, ..._cats];

  /// 卡片：hl-list-item 缩略图链接 + 标题 + 封面 + 状态。
  List<Book> _cards(String html) {
    final books = <Book>[];
    final seen = <String>{};
    for (final chunk in html.split('<li class="hl-list-item').skip(1)) {
      final am = RegExp(r'href="(/comics-reading/(\d+)\.html)"').firstMatch(chunk);
      if (am == null) continue;
      final bid = am.group(2)!;
      if (!seen.add(bid)) continue;
      final tm = RegExp(r'title="([^"]+)"').firstMatch(chunk);
      final title = tm == null ? '' : _clean(tm.group(1));
      if (title.isEmpty) continue;
      final im = RegExp(r'data-original="([^"]+)"').firstMatch(chunk);
      final st = RegExp(r'class="remarks[^"]*"[^>]*>([^<]{1,10})<').firstMatch(chunk);
      books.add(Book(
        name: title,
        author: '',
        cover: im?.group(1) ?? '',
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.comic,
        lastChapter: '',
        intro: st == null ? '漫画' : st.group(1)!.trim(),
      ));
    }
    return books;
  }

  Future<DiscoverResult> _rank(String kind, int page) async {
    final url = kind == 'all'
        ? '$_web/desirable-comics'
        : '$_web/desirable-comics/$kind';
    final html = await _http(url);
    final books = _cards(html);
    final name =
        _ranks.firstWhere((t) => t.key == kind, orElse: () => _ranks.first).name;
    return DiscoverResult(title: name, books: books, page: 1, pages: 1);
  }

  Future<DiscoverResult> _category(String cid, int page) async {
    if (!RegExp(r'^/comics-catalog/[\w/\-]+$').hasMatch(cid) ||
        !cid.contains('/ob/')) {
      cid = '/comics-catalog/all/ob/hits/st/all';
    }
    if (page < 1) page = 1;
    var url = '$_web${Uri.encodeComponent(cid)}';
    if (page > 1) url += '/page/$page';
    final html = await _http(url);
    final books = _cards(html);
    var pages = 1;
    for (final m in RegExp(r'href="[^"]*/page/(\d+)"').allMatches(html)) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n > pages) pages = n;
    }
    if (page > pages && page > 1) return _category(cid, pages);
    final parts = cid.replaceAll(RegExp(r'/$'), '').split('/');
    final label = parts.length > 2 ? parts[2] : '全部';
    return DiscoverResult(
      title: '分类 $label · 第 $page 页',
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
      final k = ['all', 'daily', 'weekly', 'monthly'].contains(key) ? key : 'all';
      return _rank(k, page);
    }
    return _category(key, page);
  }
}
