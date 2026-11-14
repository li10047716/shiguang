/// 花都动漫（视频类书源）。
///
/// macCMS v10 模板的番剧站：
///   - 搜索：`/vodsearch/-------------.html?wd={kw}`（GET，卡为 a.stui-vodlist__thumb）
///   - 详情：`/voddetail{id}.html`
///   - 播放页：`/vodplay/{id}-{sid}-{nid}.html`，页内 `player_data.url` 为
///     base64 → URL 解码两层的 m3u8 直链。
/// 站点限流（约 10 秒/请求），HttpClient 已有重试退避。
library;

import 'dart:convert';

import 'package:html/parser.dart' as hp;

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _web = 'https://hd.huadudm.com';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

class HuadudmSource extends SourceBase {
  @override
  String get sourceId => 'hddm';
  @override
  String get sourceName => '花都动漫';
  @override
  ContentType get type => ContentType.video;

  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Referer': '$_web/',
      };

  /// 站点限流：请求间隔至少 6 秒（页内提示「搜索请间隔10秒」是搜索专用；
  /// 分类浏览按普通人点击节奏 6 秒足够），过快会触发 WAF 重置连接 / 临时封 IP。
  static DateTime _lastReq = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minGap = Duration(seconds: 6);

  Future<String> _http(String url) async {
    final gap = DateTime.now().difference(_lastReq);
    if (gap < _minGap) {
      await Future.delayed(_minGap - gap);
    }
    _lastReq = DateTime.now();
    try {
      return await HttpClient.getText(url, headers: _headers, retries: 0);
    } catch (_) {
      // 连接被重置（WAF 限流）：等 15 秒重试一次
      await Future.delayed(const Duration(seconds: 15));
      _lastReq = DateTime.now();
      return HttpClient.getText(url, headers: _headers, retries: 0);
    }
  }

  String _clean(String? s) =>
      (s ?? '').replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  String _abs(String u) => u.startsWith('http') ? u : '$_web$u';

  /// 从卡片节点解析书籍
  Book? _bookFromCard(dynamic a) {
    final href = (a.attributes['href'] as String?) ?? '';
    if (!href.contains('/voddetail')) return null;
    final name = _clean(a.attributes['title'] as String? ?? a.text);
    if (name.isEmpty) return null;
    var cover = '';
    final img = a.querySelector('img');
    if (img != null) {
      cover = img.attributes['data-original'] ?? img.attributes['src'] ?? '';
    }
    if (cover.isNotEmpty && !cover.startsWith('http')) {
      cover = '$_web$cover';
    }
    return Book(
      name: name,
      author: '',
      bookUrl: href,
      cover: cover,
      sourceId: sourceId,
      sourceName: sourceName,
      type: type,
    );
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final url =
        '$_web/vodsearch/-------------.html?wd=${Uri.encodeComponent(keyword)}';
    final html = await _http(url);
    final doc = hp.parse(html);
    final books = <Book>[];
    for (final a in doc.querySelectorAll('a.stui-vodlist__thumb')) {
      final b = _bookFromCard(a);
      if (b != null) books.add(b);
    }
    return books;
  }

  @override
  Future<Book> detail(Book book) async {
    try {
      final html = await _http(_abs(book.bookUrl));
      final doc = hp.parse(html);
      var name = book.name;
      final tm = RegExp(r'《([^》]+)》').firstMatch(doc.querySelector('title')?.text ?? '');
      if (tm != null && _clean(tm.group(1)).isNotEmpty) {
        name = _clean(tm.group(1));
      }
      var cover = book.cover;
      final mainThumb = doc.querySelector('img.lazyload');
      if (mainThumb != null) {
        final c = mainThumb.attributes['data-original'] ?? mainThumb.attributes['src'] ?? '';
        if (c.isNotEmpty) cover = c.startsWith('http') ? c : '$_web$c';
      }
      // 简介：detail-content 里非标题的一段文本
      var intro = '';
      for (final d in doc.querySelectorAll('.detail-content')) {
        final t = _clean(d.text);
        if (t.isNotEmpty && t != name && !t.contains('详情介绍')) {
          intro = t;
          break;
        }
      }
      return Book(
        name: name,
        bookUrl: book.bookUrl,
        cover: cover,
        sourceId: sourceId,
        sourceName: sourceName,
        type: type,
        author: book.author,
        lastChapter: book.lastChapter,
        intro: intro.isEmpty ? book.intro : intro,
      );
    } catch (_) {
      return book;
    }
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final html = await _http(_abs(book.bookUrl));
    final doc = hp.parse(html);
    final seen = <String>{};
    final chapters = <Chapter>[];
    for (final a in doc.querySelectorAll('a[href*="/vodplay/"]')) {
      final h = a.attributes['href'] ?? '';
      if (h.isEmpty || !seen.add(h)) continue;
      final m = RegExp(r'/vodplay/(\d+)-(\d+)-(\d+)\.html').firstMatch(h);
      final n = m != null ? int.tryParse(m.group(3)!) ?? 1 : 1;
      final t = _clean(a.text);
      chapters.add(Chapter(
        title: t.isNotEmpty && t.length < 20 ? t : '第$n集',
        url: h,
      ));
    }
    // 详情页只有「播放」按钮 → 单集
    if (chapters.isEmpty) {
      final id = RegExp(r'/voddetail(\d+)\.html').firstMatch(book.bookUrl);
      if (id != null) {
        chapters.add(Chapter(title: '第1集', url: '/vodplay/${id.group(1)}-1-1.html'));
      }
    }
    return TocResult(chapters: chapters, partial: false);
  }

  @override
  Future<Content> content(Chapter chapter) async {
    final html = await _http(_abs(chapter.url));
    final m = RegExp(r'player_data=(\{.*?\})\s*;', dotAll: true).firstMatch(html);
    if (m == null) throw SourceException('未找到播放数据');
    final um = RegExp(r'"url":"([^"]+)"').firstMatch(m.group(1)!);
    if (um == null) throw SourceException('未找到视频地址');
    final b64 = um.group(1)!;
    final step1 = utf8.decode(base64.decode(base64.normalize(b64)));
    final video = Uri.decodeFull(step1);
    if (!video.startsWith('http')) throw SourceException('视频地址不合法：$video');
    return Content(title: chapter.title, kind: ContentType.video, video: video);
  }

  @override
  List<DiscoverTab> get discoverTabs => const [
        DiscoverTab(key: 'home', name: '首页', isRank: false),
        DiscoverTab(key: 'dongman', name: '动漫', isRank: false),
        DiscoverTab(key: 'guochan', name: '国产', isRank: false),
        DiscoverTab(key: 'oumei', name: '欧美', isRank: false),
        DiscoverTab(key: 'zhongwenzimu', name: '中文字幕', isRank: false),
        DiscoverTab(key: 'wuzimu', name: '无字幕', isRank: false),
      ];

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    // key='home' 时抓首页「最新」合集（/），否则抓分类页
    final url = key == 'home' ? '$_web/' : '$_web/vodtype/$key.html';
    final html = await _http(url);
    final doc = hp.parse(html);
    final books = <Book>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a.stui-vodlist__thumb')) {
      final b = _bookFromCard(a);
      // 首页同一部作品出现在多个「最新」分区 → 按 URL 去重
      if (b != null && seen.add(b.bookUrl)) books.add(b);
    }
    return DiscoverResult(
      title: key == 'home' ? '首页最新' : '花都动漫',
      books: books,
      page: page,
      pages: 1,
    );
  }
}
