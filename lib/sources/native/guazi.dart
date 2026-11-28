/// 瓜子漫画（guazimanhua.com）漫画书源。
///
/// 站点为服务端渲染的 PHP 页面，元数据同时写在 JSON-LD 里，解析稳定：
///   - 搜索 GET /category.php?keyword=词&page=n → article.card 卡片
///   - 详情 GET /comic.php?id=数字id → JSON-LD ComicStory（作者/封面/简介/最新章节）
///   - 目录 同详情页 div[data-chapter-list] 内 a[href=/chapter.php?id=..]
///          （页面按「新→旧」倒序，本源反转为「旧→新」正序）
///   - 图片 GET /chapter.php?id=章节id → img.reading-image 的 src
///     CDN 直链（img.guazicdn.com）无签名、免 Referer，可长缓存。
///   - 榜单 GET /top.php → article.mobile-rank-card 卡片
///   - 分类 GET /category.php?cid=数字&page=n → article.card 卡片
library;

import 'dart:convert';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _site = 'https://www.guazimanhua.com';
const String _sourceId = 'guazi';
const String _sourceName = '瓜子漫画';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

class GuaziSource extends SourceBase {
  @override
  String get sourceId => _sourceId;
  @override
  String get sourceName => _sourceName;
  @override
  ContentType get type => ContentType.comic;

  @override
  Map<String, String>? get imageHeaders => null; // CDN 直链免 Referer

  Future<String> _get(String url) => HttpClient.getText(
        url,
        headers: {'User-Agent': _ua, 'Referer': '$_site/'},
        maxBytes: 4 * 1024 * 1024,
      );

  // ---------- 通用工具 ----------

  static String _text(String frag) {
    var s = frag
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    return _decode(s.trim());
  }

  static String _decode(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }

  /// JSON-LD 里的单个 "@type" 对象（取第一个匹配）。
  static Map<String, dynamic>? _ldObject(String html, String type) {
    for (final m in RegExp(r'<script[^>]*type="application/ld\+json"[^>]*>([\s\S]*?)</script>')
        .allMatches(html)) {
      Object? decoded;
      try {
        decoded = jsonDecode(m.group(1)!);
      } catch (_) {
        continue;
      }
      Map<String, dynamic>? found;
      void walk(Object? node) {
        if (found != null) return;
        if (node is List) {
          for (final e in node) {
            walk(e);
            if (found != null) return;
          }
        } else if (node is Map) {
          if (node['@type'] == type) {
            found = Map<String, dynamic>.from(node);
            return;
          }
          for (final e in node.values) {
            walk(e);
            if (found != null) return;
          }
        }
      }

      walk(decoded);
      if (found != null) return found;
    }
    return null;
  }

  // ---------- 列表卡片（搜索 / 分类共用） ----------

  /// <article class="card">: cover-wrap a href, img.cover src, h3 a, div.meta
  static List<Map<String, String>> _cards(String html) {
    final cards = <Map<String, String>>[];
    final seen = <String>{};
    for (final m in RegExp(r'<article class="card">([\s\S]*?)</article>')
        .allMatches(html)) {
      final chunk = m.group(1)!;
      final hm = RegExp(r'<a class="cover-wrap" href="/comic\.php\?id=(\d+)"')
          .firstMatch(chunk);
      if (hm == null || !seen.add(hm.group(1)!)) continue;
      final tm = RegExp(r'<h3><a href="/comic\.php\?id=\d+">([^<]*)</a>')
          .firstMatch(chunk);
      final title = tm == null ? '' : _decode(tm.group(1)!);
      if (title.isEmpty) continue;
      final cm = RegExp(r'<img class="cover" src="([^"]+)"').firstMatch(chunk);
      final mm = RegExp(r'<div class="meta">([^<]*)</div>').firstMatch(chunk);
      cards.add({
        'id': hm.group(1)!,
        'title': title,
        'cover': cm == null ? '' : _decode(cm.group(1)!),
        'meta': mm == null ? '' : _decode(mm.group(1)!),
      });
    }
    return cards;
  }

  Book _cardToBook(Map<String, String> c) {
    final meta = c['meta'] ?? '';
    final parts = meta.split('·').map((s) => s.trim()).toList();
    return Book(
      name: c['title'] ?? '',
      author: parts.isEmpty ? '' : parts.first,
      cover: c['cover'] ?? '',
      bookUrl: c['id'] ?? '',
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
      intro: '',
    );
  }

  /// 榜单卡片：<article class="mobile-rank-card">
  static List<Map<String, String>> _rankCards(String html) {
    final cards = <Map<String, String>>[];
    final seen = <String>{};
    for (final m in RegExp(r'<article class="mobile-rank-card">([\s\S]*?)</article>')
        .allMatches(html)) {
      final chunk = m.group(1)!;
      final hm = RegExp(r'<a class="mobile-rank-cover" href="/comic\.php\?id=(\d+)"')
          .firstMatch(chunk);
      if (hm == null || !seen.add(hm.group(1)!)) continue;
      final tm = RegExp(r'<h2><a href="/comic\.php\?id=\d+">([^<]*)</a>')
          .firstMatch(chunk);
      final title = tm == null ? '' : _decode(tm.group(1)!);
      if (title.isEmpty) continue;
      final cm = RegExp(r'<img src="([^"]+)"').firstMatch(chunk);
      cards.add({
        'id': hm.group(1)!,
        'title': title,
        'cover': cm == null ? '' : _decode(cm.group(1)!),
      });
    }
    return cards;
  }

  /// 分页最大页：从 page=N 链接里取最大值，至少 1（兼容 HTML 转义的 &amp;page）。
  static int _lastPage(String html) {
    var max = 1;
    for (final m in RegExp(r'page=(\d+)').allMatches(html)) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    final p = page < 1 ? 1 : page;
    final html = await _get(
      '$_site/category.php?keyword=${Uri.encodeComponent(kw)}&page=$p',
    );
    return _cards(html).map(_cardToBook).toList();
  }

  // ---------- 详情 ----------

  static String _authorFromHtml(String html) {
    final m = RegExp(
      r'<div><span>作者</span><b>([^<]*)</b></div>',
    ).firstMatch(html);
    return m == null ? '' : _decode(m.group(1)!);
  }

  static String _latestFromHtml(String html) {
    final m = RegExp(
      r'<div><span>最新</span><b>([^<]*)</b></div>',
    ).firstMatch(html);
    return m == null ? '' : _decode(m.group(1)!);
  }

  @override
  Future<Book> detail(Book book) async {
    final html = await _get('$_site/comic.php?id=${book.bookUrl}');
    final ld = _ldObject(html, 'ComicStory');
    final name = ld?['name']?.toString().trim() ?? book.name;
    final image = ld?['image']?.toString() ?? book.cover;
    var desc = ld?['description']?.toString() ?? '';
    if (desc.isEmpty) {
      final m = RegExp(r'<p>([\s\S]{0,500}?)</p>').firstMatch(html);
      if (m != null) desc = _text(m.group(1)!);
    }
    final authorObj = ld?['author'];
    final author = authorObj is Map ? authorObj['name']?.toString() ?? '' : '';
    return Book(
      name: name.isEmpty ? book.name : name,
      author: author.isEmpty ? _authorFromHtml(html) : author,
      cover: image.isEmpty ? book.cover : image,
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
      lastChapter: _latestFromHtml(html).isEmpty
          ? book.lastChapter
          : _latestFromHtml(html),
      intro: desc,
    );
  }

  // ---------- 目录 ----------

  static List<Chapter> _tocChapters(String html) {
    final start = html.indexOf('data-chapter-list');
    if (start < 0) return const [];
    final tail = html.substring(start);
    final end = tail.indexOf('</div>');
    final seg = end > 0 ? tail.substring(0, end) : tail;
    final list = <Chapter>[];
    for (final m in RegExp(
      r'<a[^>]*href="/chapter\.php\?id=(\d+)"[^>]*>([^<]*)</a>',
    ).allMatches(seg)) {
      final id = m.group(1)!;
      final title = _decode(m.group(2)!);
      if (title.isEmpty) continue;
      list.add(Chapter(title: title, url: '$_site/chapter.php?id=$id'));
    }
    // 页面是最新→最早，反转为最早→最新（与阅读器/目录顺序一致）
    return list.reversed.toList();
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final html = await _get('$_site/comic.php?id=${book.bookUrl}');
    final chapters = _tocChapters(html);
    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    if (chapters.isEmpty) {
      throw SourceException('瓜子漫画目录为空，规则可能已失效');
    }
    return TocResult(chapters: chapters);
  }

  // ---------- 图片页 ----------

  @override
  Future<Content> content(Chapter chapter) async {
    final html = await _get(chapter.url);
    final urls = <String>[];
    for (final m in RegExp(
      r'<img[^>]*class="reading-image[^"]*"[^>]*src="([^"]+)"',
    ).allMatches(html)) {
      final u = _decode(m.group(1)!);
      if (u.isEmpty) continue;
      urls.add(u.startsWith('//') ? 'https:$u' : u);
    }
    if (urls.isEmpty) throw SourceException('未取到瓜子漫画图片（可能已下架）');
    // 章节页 JSON-LD Article.name 是干净的章节名（如「50 治疗开始」）
    final article = _ldObject(html, 'Article');
    final ldTitle = article?['name']?.toString().trim() ?? '';
    final title = ldTitle.isEmpty ? chapter.title : ldTitle;
    return Content(
      title: title,
      pages: urls.map((u) => ComicPage(url: u)).toList(),
    );
  }

  // ---------- 发现 ----------

  static const List<DiscoverTab> _discoverTabs = [
    DiscoverTab(key: 'rank', name: '排行', isRank: true),
    DiscoverTab(key: '25', name: '玄幻', isRank: false),
    DiscoverTab(key: '42', name: '都市', isRank: false),
    DiscoverTab(key: '9', name: '恋爱', isRank: false),
    DiscoverTab(key: '13', name: '热血', isRank: false),
    DiscoverTab(key: '23', name: '古风', isRank: false),
    DiscoverTab(key: '8', name: '穿越', isRank: false),
    DiscoverTab(key: '148', name: '系统', isRank: false),
  ];

  @override
  List<DiscoverTab> get discoverTabs => _discoverTabs;

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    final p = page < 1 ? 1 : page;
    if (isRank) {
      final html = await _get('$_site/top.php');
      final books = _rankCards(html).map(_cardToBook).toList();
      return DiscoverResult(title: '人气排行', books: books, page: 1, pages: 1);
    }
    final cid = _discoverTabs
            .where((t) => t.key == key && !t.isRank)
            .isEmpty
        ? '25'
        : key;
    var html = await _get('$_site/category.php?cid=$cid&page=$p');
    var total = _lastPage(html);
    if (p > total) {
      html = await _get('$_site/category.php?cid=$cid&page=$total');
      total = _lastPage(html);
    }
    final name = _discoverTabs
        .where((t) => t.key == cid && !t.isRank)
        .map((t) => t.name)
        .firstOrNull ?? '分类';
    return DiscoverResult(
      title: name,
      books: _cards(html).map(_cardToBook).toList(),
      page: p > total ? total : p,
      pages: total,
    );
  }
}
