/// 八叉书库（bcshuku.com）抓取层。
///
/// 移植自 shiguang `reader/bc.py`：
///   - 搜索 /e/search/index.php?keyboard=..（302 到 result/?searchid=NNNN）
///   - 详情 /novel{bid}/ og 元信息 + 完整目录（每页 50 章，?p=N）
///   - 正文章节页内嵌 url/mobile/isk/novel/chapter/t/n/sign 八参数，
///     POST 到 /conapi.php 拿 JSON 正文
///   - 页面用移动端 UA；正文接口用夸克 UA，同秒重复请求易 502，需重试
///
/// 书籍 id 用 `bc:<bid>` 编码进 [Book.bookUrl]，章节 url 用 `bc://<bid>/chapterN.html`。
library;

import 'dart:convert';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _base = 'https://bcshuku.com';
const String _prefix = 'bc:';
const String _scheme = 'bc://';
const String _uaMobile =
    'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Mobile Safari/537.36';
const String _uaQuark =
    'Mozilla/5.0 (Linux; U; Android 10; zh-CN; MI 9 Build/QKQ1.190828.002) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 '
    'Quark/10.5.1.1026 Mobile Safari/537.36';

const int _maxTocPages = 30;

class BcSource extends SourceBase {
  @override
  String get sourceId => 'bc';
  @override
  String get sourceName => '八叉书库';
  @override
  ContentType get type => ContentType.novel;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_base/'};

  // ---------- 基础 ----------

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

  String _abs(String href) {
    if (href.trim().isEmpty) return '';
    var h = href.trim();
    if (h.startsWith('//')) return 'https:$h';
    if (h.startsWith('http')) return h;
    return Uri.parse('$_base/').resolve(h).toString();
  }

  String _status(String raw) {
    final s = raw.trim();
    if (s == '完本' || s == '全本' || s == '完结') return '已完结';
    if (s == '连载' || s == '连载中') return '连载中';
    return s;
  }

  String _nativeId(String bookUrl) {
    var v = bookUrl.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length);
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    return v.split(RegExp(r'[/.?]')).first;
  }

  // ---------- 网络 ----------

  Future<String> _get(String url, {int maxBytes = 4 * 1024 * 1024}) async {
    final headers = <String, String>{
      'User-Agent': _uaMobile,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': '$_base/',
    };
    return HttpClient.getText(
      url,
      charset: 'utf-8',
      headers: headers,
      maxBytes: maxBytes,
      // 站点「卡死不吐响应头 / 滴流」：头 15s 没到就放弃（卡死快速失败），
      // body 30s 兜底（滴流也能拿到前段卡片），避免发现页一直转圈。
      idleTimeout: const Duration(seconds: 10),
      headerTimeout: const Duration(seconds: 15),
      totalTimeout: const Duration(seconds: 30),
    );
  }

  // ---------- 列表卡片解析 ----------

  List<Map<String, String>> _cards(String html) {
    final splitPat = RegExp(r'<div class="[^"]*\bhome-truyendecu\b[^"]*"');
    final parts = html.split(splitPat);
    final cards = <Map<String, String>>[];
    final seen = <String>{};
    for (var i = 1; i < parts.length; i++) {
      final chunk = parts[i].split(splitPat).first;
      final hm = RegExp(
              r'<a href="(/novel(\d+)/)"[^>]*title="([^"]*)"')
          .firstMatch(chunk);
      if (hm == null) continue;
      final bid = hm.group(2)!;
      if (!seen.add(bid)) continue;
      final tm = RegExp(r'<h3 itemprop="name">([\s\S]*?)</h3>').firstMatch(chunk);
      final title = tm == null ? _text(hm.group(3)!) : _text(tm.group(1)!);
      final cm = RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(chunk);
      final status = RegExp(r'<span class="hoan-thanh-mau">([^<]*)</span>')
          .firstMatch(chunk);
      final latest = RegExp(r'<small class="btn-xs label-primary">([\s\S]*?)</small>')
          .firstMatch(chunk);
      var latestT = latest == null ? '' : _text(latest.group(1)!);
      if (latestT.isNotEmpty) {
        latestT = latestT.replaceFirst(RegExp(r'^(连载|完本|全本)\s*'), '').trim();
      }
      var author = '';
      final am = RegExp(
              r'class="chi-tiet chuyen-muc"[\s\S]{0,200}?<a[^>]*>([^<]*)</a>')
          .firstMatch(chunk);
      if (am != null) {
        final cand = _text(am.group(1)!);
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(cand)) author = cand;
      }
      if (author.isEmpty) {
        // 兜底：author itemprop 或「作者：」前缀
        final a2 = RegExp(r'itemprop="author"[^>]*>([\s\S]{0,120}?)</(?:a|span)>')
            .firstMatch(chunk);
        if (a2 != null) {
          author = _text(a2.group(1)!);
        }
        if (author.isEmpty) {
          final a3 = RegExp(r'作者[：:]\s*</?[^>]*>?\s*([^<]{1,20})')
              .firstMatch(chunk);
          if (a3 != null) author = _text(a3.group(1)!);
        }
      }
      cards.add({
        'id': '$_prefix$bid',
        'title': title,
        'author': author,
        'cover': cm == null ? '' : _abs(cm.group(1)!),
        'intro': '',
        'category': '',
        'status': _status(status?.group(1) ?? ''),
        'latest': latestT,
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
        intro: c['intro'] ?? '',
      );

  // ---------- 搜索 ----------

  Future<String> _searchId(String keyword) async {
    final url = '$_base/e/search/index.php?keyboard=${Uri.encodeComponent(keyword)}'
        '&show=title,writer,byr&searchget=1';
    try {
      // 跟随 302：最终地址是 result/?searchid=NNNN
      final (body, finalUrl) = await HttpClient.getTextDetailed(
        url,
        charset: 'utf-8',
        headers: {'User-Agent': _uaMobile, 'Referer': '$_base/'},
        maxBytes: 2 * 1024 * 1024,
      );
      final m = RegExp(r'searchid=(\d+)').firstMatch(finalUrl);
      if (m != null) return m.group(1)!;
      final m2 = RegExp(r'searchid=(\d+)').firstMatch(body);
      return m2?.group(1) ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final p = page < 1 ? 1 : page;
    final sid = await _searchId(kw);
    if (sid.isEmpty) return [];
    final url = p == 1
        ? '$_base/e/search/result/?searchid=$sid'
        : '$_base/e/search/result/index.php?page=${p - 1}&searchid=$sid';
    final html = await _get(url);
    return _cards(html).map(_cardToBook).toList();
  }

  // ---------- 目录 ----------

  List<Chapter> _tocChapters(String html, String bid) {
    final i = html.indexOf('id="list-chapter"');
    var seg = i > 0 ? html.substring(i) : html;
    final cut = seg.indexOf('id="pagination"');
    if (cut > 0) seg = seg.substring(0, cut);
    // 剔掉隐藏的 SEO 干扰项
    seg = seg.replaceAll(
        RegExp(r'<li[^>]*aria-hidden="true"[^>]*>[\s\S]*?</li>'), '');
    seg = seg.replaceAll(
        RegExp(r'<li[^>]*overflow: ?hidden[^>]*>[\s\S]*?</li>'), '');
    final chapters = <Chapter>[];
    final re = RegExp(
        r'<a href="(/novel\d+/(chapter\d+\.html))"([^>]*)>([\s\S]{0,200}?)</a>');
    for (final m in re.allMatches(seg)) {
      final href = m.group(1)!;
      final fname = m.group(2)!;
      final attrs = m.group(3)!;
      final inner = m.group(4)!;
      if (attrs.contains('nofollow') || attrs.contains('tabindex="-1"')) continue;
      final name = RegExp(r'<span class="chapter-text">([\s\S]*?)</span>')
          .firstMatch(inner);
      final label = name == null ? _text(inner) : _text(name.group(1)!);
      if (label.isEmpty) continue;
      final bm = RegExp(r'/novel(\d+)/').firstMatch(href);
      if (bm == null || (bid.isNotEmpty && bm.group(1) != bid)) continue;
      chapters.add(Chapter(title: label, url: '$_scheme${bm.group(1)}/$fname'));
    }
    return chapters;
  }

  int _tocPages(String html) {
    final nums = RegExp(r'/novel\d+/\?p=(\d+)')
        .allMatches(html)
        .map((m) => int.tryParse(m.group(1)!) ?? 0)
        .toList();
    return nums.isEmpty ? 1 : nums.reduce((a, b) => a > b ? a : b);
  }

  Future<List<Chapter>> _fetchToc(String bid) async {
    final firstHtml = await _get('$_base/novel$bid/');
    final total = _tocPages(firstHtml).clamp(1, _maxTocPages);
    final chapters = _tocChapters(firstHtml, bid);
    // 2..total 页并发抓
    if (total > 1) {
      final results = await Future.wait(
        [for (var n = 2; n <= total; n++) _safeToc(bid, n)],
      );
      for (final list in results) {
        chapters.addAll(list);
      }
    }
    // 去重保序
    final seen = <String>{};
    return chapters.where((c) => seen.add(c.url)).toList();
  }

  Future<List<Chapter>> _safeToc(String bid, int n) async {
    try {
      final html = await _get('$_base/novel$bid/?p=$n');
      return _tocChapters(html, bid);
    } catch (_) {
      return [];
    }
  }

  // ---------- 详情 ----------

  String _meta(String html, String prop) {
    final m = RegExp(
            r'<meta[^>]*property="og:novel:' +
                RegExp.escape(prop) +
                r'"[^>]*content="([^"]*)"')
        .firstMatch(html);
    return m == null ? '' : _text(m.group(1)!);
  }

  @override
  Future<Book> detail(Book book) async {
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少八叉书库书籍 id');
    final url = '$_base/novel$bid/';
    final html = await _get(url, maxBytes: 6 * 1024 * 1024);

    var title = _meta(html, 'book_name');
    if (title.isEmpty) {
      final tm = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(html);
      title = tm == null ? '书籍$bid' : _text(tm.group(1)!).split('_').first;
    }
    final cm = RegExp(r'<meta[^>]*property="og:image"[^>]*content="([^"]*)"')
        .firstMatch(html);

    var intro = '';
    var dm = RegExp(
            r'<div class="desc-text" itemprop="description">([\s\S]*?)</div>\s*<div class="showmore"')
        .firstMatch(html);
    dm ??= RegExp(
            r'<div class="desc-text" itemprop="description">([\s\S]{0,3000}?)</div>')
        .firstMatch(html);
    if (dm != null) {
      var frag = dm.group(1)!;
      frag = frag.replaceAll(
          RegExp(r'<div class="short-content">[\s\S]*?</div>'), '');
      frag = frag.replaceAll(RegExp(r'<div class="showmore">[\s\S]*?</div>'), '');
      intro = _text(frag);
    }

    final chapters = await _fetchToc(bid);
    if (chapters.isEmpty) throw SourceException('八叉书库：这本暂时取不到目录');

    return Book(
      name: title,
      author: _meta(html, 'author'),
      cover: cm == null ? '' : _abs(cm.group(1)!),
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.novel,
      lastChapter: chapters.last.title,
      intro: intro,
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final bid = _nativeId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少八叉书库书籍 id');
    final chapters = await _fetchToc(bid);
    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    if (chapters.isEmpty) throw SourceException('八叉书库目录为空，规则可能已失效');
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
    final t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return t
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<List<String>> _fetchContent(String html, String chapUrl) async {
    const keys = ['url', 'mobile', 'isk', 'novel', 'chapter', 't', 'n', 'sign'];
    final params = <String, String>{};
    for (final k in keys) {
      params[k] = _pick(html, k);
    }
    if (params['url']!.isEmpty || params['sign']!.isEmpty) return [];

    final body = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final headers = <String, String>{
      'User-Agent': _uaQuark,
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      'x-requested-with': 'XMLHttpRequest',
      'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'origin': _base,
      'referer': chapUrl,
      'accept-language': 'zh-CN,zh;q=0.9',
    };
    Object? lastError;
    for (var i = 0; i < 3; i++) {
      try {
        final raw = await HttpClient.getText(
          '$_base/conapi.php',
          charset: 'utf-8',
          method: 'POST',
          body: body,
          headers: headers,
          maxBytes: 3 * 1024 * 1024,
          useCache: false,
        );
        final data = jsonDecode(raw);
        if (data is Map) {
          final success = '${data['success'] ?? ''}';
          final content = data['content'];
          if (success.isNotEmpty &&
              success != '0' &&
              success != 'False' &&
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
    throw SourceException('八叉书库正文接口失败：$lastError');
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
    if (m == null) throw SourceException('八叉书库章节地址不对：${chapter.url}');
    final bid = m.group(1)!;
    final fname = m.group(2)!;
    final chapUrl = '$_base/novel$bid/$fname';
    final html = await _get(chapUrl);

    var title = '';
    final tm = RegExp(r'<a class="chapter-title"[^>]*title="[^"]*?"[^>]*>([\s\S]*?)</a>')
        .firstMatch(html);
    if (tm != null) {
      title = _text(tm.group(1)!);
    } else {
      final tm2 = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(html);
      title = tm2 == null ? '' : _text(tm2.group(1)!).split('_').first;
    }

    final paras = await _fetchContent(html, chapUrl);
    if (paras.isEmpty) throw SourceException('这一章没有取到内容');

    return Content(
      title: title,
      paras: paras,
      kind: ContentType.novel,
    );
  }

  // ---------- 发现：榜单 / 书库 ----------

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'popular', name: '热门排行', isRank: true),
    DiscoverTab(key: 'latest', name: '最新更新', isRank: true),
    DiscoverTab(key: 'release', name: '最新入库', isRank: true),
    DiscoverTab(key: 'completed', name: '完本小说', isRank: true),
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

  /// 总页数：榜单 1 基（`index_N.html`），分类 0 基（`booklist<cid>/N.html` → +1）。
  int _maxPage(String html, {required String kind, String cid = ''}) {
    if (kind == 'sort') {
      var max = 1;
      final re =
          RegExp('/booklist${RegExp.escape(cid)}/(\\d+)\\.html');
      for (final m in re.allMatches(html)) {
        final n = int.tryParse(m.group(1) ?? '') ?? 0;
        if (n + 1 > max) max = n + 1;
      }
      return max;
    }
    var max = 1;
    final re = RegExp('/${RegExp.escape(kind)}/index_(\\d+)\\.html');
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
    var url = page == 1
        ? '$_base/$kind/index.html'
        : '$_base/$kind/index_$page.html';
    var html = await _get(url);
    final total = _maxPage(html, kind: kind);
    if (page > total) {
      page = total;
      url = page == 1
          ? '$_base/$kind/index.html'
          : '$_base/$kind/index_$page.html';
      html = await _get(url);
    }
    final books = _cards(html).map(_cardToBook).toList();
    return DiscoverResult(
      title: title,
      books: books,
      page: page,
      pages: total,
    );
  }

  Future<DiscoverResult> _category(String cid, int page) async {
    if (!_cats.any((t) => t.key == cid)) cid = '1';
    final name =
        _cats.firstWhere((t) => t.key == cid, orElse: () => _cats.first).name;
    if (page < 1) page = 1;
    var url = '$_base/booklist$cid/${page - 1}.html';
    var html = await _get(url);
    final total = _maxPage(html, kind: 'sort', cid: cid);
    if (page > total) {
      page = total;
      url = '$_base/booklist$cid/${page - 1}.html';
      html = await _get(url);
    }
    final books = _cards(html).map(_cardToBook).toList();
    return DiscoverResult(
      title: '$name小说',
      books: books,
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
      final k = _ranks.any((t) => t.key == key) ? key : 'popular';
      return _rank(k, page);
    }
    return _category(key, page);
  }
}
