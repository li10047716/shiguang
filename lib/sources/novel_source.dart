/// 小说书源执行器：把 BookSource 的 JSON 规则变成实际的
/// search / detail / toc / content 四个接口。
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../models/book.dart';
import '../models/book_source.dart';
import '../models/discover.dart';
import '../services/http_client.dart' as raw_http;
import '../services/webview_fetch.dart';
import '../utils/text_repair.dart';
import 'legado_rule_resolver.dart';
import 'legado_runtime.dart';
import 'rule_engine.dart';

/// 目录加载结果（区分「完整」与「部分」）
class TocResult {
  final List<Chapter> chapters;
  final bool partial; // 有页没抓全
  final String? warning; // 给用户看的提示
  final int pagesLoaded;

  const TocResult({
    required this.chapters,
    this.partial = false,
    this.warning,
    this.pagesLoaded = 1,
  });
}

class NovelSourceExecutor {
  /// 单页目录的接收上限：速读谷一页 1000 章约 110KB，2MB 足够且能截断异常大页面
  static const int _tocPageLimit = 2 * 1024 * 1024;

  /// 目录分页并发数（站点限流较严，3 是实测比较稳的值）
  static const int _tocConcurrency = 3;

  final BookSource source;
  NovelSourceExecutor(this.source);

  String get _referer => source.baseUrl;

  static final RegExp _jsRulePattern = RegExp(
    r'@js:|<js>|</js>|javascript:|java\.|\{\{',
    caseSensitive: false,
  );

  bool _isJs(String value) => _jsRulePattern.hasMatch(value);

  /// 非标准源（JSONPath / JS / WebView）统一走复合规则解析器。
  bool get _complex => source.implementation != SourceImplementation.standard;

  LegadoRuleResolver? _resolver;
  LegadoRuleResolver get resolver => _resolver ??= LegadoRuleResolver(source);

  /// 统一取网页源码：WebView 源渲染后取 DOM；JS URL 先求值。
  Future<String> _getText(
    String url, {
    String charset = 'utf-8',
    String method = 'GET',
    Map<String, dynamic>? query,
    String? body,
    Map<String, String>? headers,
    String? referer,
    int retries = 2,
    int maxBytes = 6 * 1024 * 1024,
    Duration idleTimeout = const Duration(seconds: 12),
    Duration headerTimeout = const Duration(seconds: 20),
    Duration totalTimeout = const Duration(seconds: 45),
    bool useCache = true,
    String key = '',
    int page = 1,
  }) async {
    var target = url;
    final mergedHeaders = <String, String>{
      ...source.headers,
      ...?headers,
    };
    if (_isJs(target) && _complex) {
      final built = await LegadoRuntime().evaluateRule(
        target,
        src: target,
        baseUrl: source.baseUrl,
        sourceInfo: source.headers,
        key: key,
        page: page,
        bookSource: source,
      );
      if (built.trim().isNotEmpty) target = built.trim();
    }
    if (source.implementation == SourceImplementation.webView) {
      return WebViewFetch.html(
        target,
        headers: mergedHeaders,
        javascript: _webViewJs,
      );
    }
    return raw_http.HttpClient.getText(
      target,
      charset: charset,
      method: method,
      query: query,
      body: body,
      headers: mergedHeaders.isEmpty ? null : mergedHeaders,
      referer: referer,
      retries: retries,
      maxBytes: maxBytes,
      idleTimeout: idleTimeout,
      headerTimeout: headerTimeout,
      totalTimeout: totalTimeout,
      useCache: useCache,
    );
  }

  String? get _webViewJs {
    if (source.webViewRule == null) return null;
    try {
      final map = jsonDecode(source.webViewRule!) as Map<String, dynamic>;
      final js = map['webViewJs'] ?? map['ruleWebView'];
      return js is String && js.isNotEmpty ? js : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _extract(
    String html,
    String rule, {
    Map<String, dynamic> context = const {},
  }) async {
    if (rule.isEmpty) return '';
    if (_complex) {
      return resolver.text(
        html,
        rule,
        context: {
          ...context,
          'key': context['key'] ?? '',
          'page': context['page'] ?? 1,
        },
      );
    }
    return RuleEngine.extract(html, rule);
  }

  Future<String> _extractFrom(dynamic element, String rule) async {
    if (rule.isEmpty) return '';
    if (_complex) {
      return resolver.text(element, rule);
    }
    return element is dom.Element
        ? RuleEngine.extractFromElement(element, rule)
        : '';
  }

  /// 列表项字段提取：标准源走 CSS，复合源走规则解析器。
  Future<String> _field(Object? item, String rule) =>
      _complex ? resolver.text(item, rule) : _extractFrom(item, rule);

  /// 搜索。失败抛异常，由聚合层捕获并按源上报。
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    if (source.implementation == SourceImplementation.jsFile) {
      return _jsSearch(keyword, page);
    }
    final rule = source.search;
    if (rule.urlTemplate.isEmpty || rule.bookList.isEmpty) {
      throw SourceException('书源搜索规则不完整');
    }
    var url = rule.urlTemplate
        .replaceAll('{{key}}', Uri.encodeQueryComponent(keyword))
        .replaceAll('{{page}}', page.toString());
    if (_complex && rule.urlTemplate.contains('{{')) {
      url = await resolver.text(
        url,
        rule.urlTemplate,
        context: {'key': keyword, 'page': page},
      );
    }

    final html = await _getText(
      url,
      charset: rule.charset,
      headers: source.headers,
      useCache: source.headers.isEmpty,
      method: rule.method,
      referer: _referer,
      maxBytes: 3 * 1024 * 1024,
      query: rule.method == 'POST'
          ? {'searchkey': keyword, 'page': page, 'searchtype': 'all'}
          : null,
      key: keyword,
      page: page,
    );

    final items = _complex
        ? await resolver.list(
            html,
            rule.bookList,
            context: {'key': keyword, 'page': page},
          )
        : RuleEngine.elements(parser.parse(html), rule.bookList);
    if (items.isEmpty) return [];

    final books = <Book>[];
    for (final item in items) {
      final name = await _field(item, rule.name);
      final bookUrlRaw = await _field(item, rule.bookUrl);
      if (name.isEmpty || bookUrlRaw.isEmpty) continue;
      books.add(
        Book(
          name: TextRepair.repair(name),
          author: TextRepair.repair(await _field(item, rule.author)),
          cover: RuleEngine.absoluteUrl(
            source.baseUrl,
            await _field(item, rule.cover),
          ),
          bookUrl: RuleEngine.absoluteUrl(source.baseUrl, bookUrlRaw),
          sourceId: source.id,
          sourceName: source.name,
          type: source.type,
          lastChapter: rule.lastChapter == null
              ? null
              : await _field(item, rule.lastChapter!),
        ),
      );
    }
    return books;
  }

  /// 发现页抓取（榜单 / 分类）。卡片选择器缺省回退到搜索规则。
  Future<DiscoverResult> discover(DiscoverTabRule tab, int page) async {
    final url = tab.url.replaceAll('{{page}}', page.toString());

    // 站点（得奇/速读谷等）间歇返回 404 / JS 重定向 / 反爬小页 → 解析出 0 张卡。
    // 此时用新鲜响应重试（useCache: false 绕过 60s 内存缓存），避免"加载不出来"。
    String html = '';
    var doc = parser.parse('');
    var books = <Book>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      html = await _getText(
        url,
        charset: source.search.charset,
        headers: source.headers,
        referer: _referer,
        maxBytes: 3 * 1024 * 1024,
        idleTimeout: const Duration(seconds: 10),
        useCache: false,
      );
      doc = parser.parse(html);
      books = await _parseCards(tab, html);
      if (books.isNotEmpty) break;
      if (attempt < 2) {
        await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }

    var pages = 1;
    if (tab.pageCount != null && tab.pageCount!.isNotEmpty) {
      pages = _parsePagesText(await _extract(html, tab.pageCount!)) ?? 1;
    } else if (tab.pageLinks != null && tab.pageLinks!.isNotEmpty) {
      pages = _pagesFromLinks(doc, tab.pageLinks!) ?? 1;
    }
    return DiscoverResult(
      title: tab.name,
      books: books,
      page: page,
      pages: pages,
    );
  }

  /// 解析一页发现卡片（封面为空且配了模板时，从书 URL 构造）。
  Future<List<Book>> _parseCards(DiscoverTabRule tab, String html) async {
    final cardRule = tab.cardList ?? source.search.bookList;
    final items = _complex
        ? await resolver.list(html, cardRule)
        : RuleEngine.elements(parser.parse(html), cardRule);
    final books = <Book>[];
    for (final el in items) {
      final name = TextRepair.repair(
        await _field(el, tab.cardName ?? source.search.name),
      );
      final bookUrlRaw = await _field(
        el,
        tab.cardBookUrl ?? source.search.bookUrl,
      );
      // 跳过空链接与占位链接（部分站点用 # / #### / javascript: 做占位）
      if (name.isEmpty || bookUrlRaw.isEmpty) continue;
      if (bookUrlRaw == '#' ||
          bookUrlRaw.contains('####') ||
          bookUrlRaw.startsWith('javascript:')) {
        continue;
      }
      var cover = RuleEngine.absoluteUrl(
        source.baseUrl,
        await _field(el, tab.cardCover ?? source.search.cover),
      );
      if (cover.isEmpty) cover = _deriveCover(tab, bookUrlRaw);
      books.add(
        Book(
          name: name,
          author: TextRepair.repair(
            await _field(el, tab.cardAuthor ?? source.search.author),
          ),
          cover: cover,
          bookUrl: RuleEngine.absoluteUrl(source.baseUrl, bookUrlRaw),
          sourceId: source.id,
          sourceName: source.name,
          type: source.type,
          lastChapter:
              (tab.cardLastChapter ?? source.search.lastChapter) == null
              ? null
              : await _field(
                  el,
                  (tab.cardLastChapter ?? source.search.lastChapter)!,
                ),
        ),
      );
    }
    return books;
  }

  /// 封面构造模板：榜单页无封面元素时，取书 URL 最后一段数字为 id，
  /// 按 `images/<id~/1000>/<id>/<id>s.jpg` 一类目录规律拼出封面。
  String _deriveCover(DiscoverTabRule tab, String bookUrlRaw) {
    final pattern = tab.cardCoverPattern;
    if (pattern == null || pattern.isEmpty) return '';
    final nums = RegExp(r'\d+').allMatches(bookUrlRaw).toList();
    if (nums.isEmpty) return '';
    final id = int.tryParse(nums.last.group(0)!) ?? 0;
    if (id <= 0) return '';
    return pattern
        .replaceAll('{id1000}', (id ~/ 1000).toString())
        .replaceAll('{id}', id.toString());
  }

  /// 从分页文本（`1/50`、`共 50 页`、`123...340`）解析总页数。
  static int? _parsePagesText(String text) {
    if (text.trim().isEmpty) return null;
    final m = RegExp(r'共\s*(\d+)\s*页').firstMatch(text);
    if (m != null) return _capPages(int.tryParse(m.group(1)!));
    final m2 = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(text);
    if (m2 != null) return _capPages(int.tryParse(m2.group(2)!));
    final nums = RegExp(r'\d+')
        .allMatches(text)
        .map((e) => int.tryParse(e.group(0)!))
        .whereType<int>()
        .toList();
    if (nums.isNotEmpty) return _capPages(nums.reduce((a, b) => a > b ? a : b));
    return null;
  }

  /// 从分页链接 href 取最大页码（`/sort/1/340/`、`/x_1_50.html` → 50）。
  static int? _pagesFromLinks(dom.Document doc, String selector) {
    final els = RuleEngine.elements(doc, selector);
    if (els.isEmpty) return null;
    var maxP = 1;
    for (final el in els) {
      final href = el.attributes['href'] ?? '';
      final nums = RegExp(r'\d+')
          .allMatches(href)
          .map((e) => int.tryParse(e.group(0)!))
          .whereType<int>()
          .toList();
      if (nums.isEmpty) continue;
      final last = nums.last; // href 末尾数字段通常是页码
      if (last > maxP) maxP = last;
    }
    return maxP > 1 ? _capPages(maxP) : null;
  }

  static int? _capPages(int? n) => (n != null && n > 0 && n <= 5000) ? n : null;

  /// 书籍详情（补全简介等）
  Future<Book> detail(Book book) async {
    if (source.implementation == SourceImplementation.jsFile) {
      return _jsDetail(book);
    }
    final html = await _getText(
      book.bookUrl,
      charset: source.search.charset,
      headers: source.headers,
      useCache: source.headers.isEmpty,
      referer: _referer,
      maxBytes: 4 * 1024 * 1024,
    );
    final r = source.detail;
    final rawName = r.name.isEmpty ? '' : await _extract(html, r.name);
    final rawAuthor = r.author.isEmpty ? '' : await _extract(html, r.author);
    final rawIntro = r.intro.isEmpty ? '' : await _extract(html, r.intro);

    return Book(
      name: rawName.isEmpty ? book.name : TextRepair.repair(rawName),
      author: rawAuthor.isEmpty ? book.author : TextRepair.repair(rawAuthor),
      cover: r.cover.isEmpty
          ? book.cover
          : await _pickCover(html, r.cover, book.cover),
      bookUrl: book.bookUrl,
      sourceId: book.sourceId,
      sourceName: book.sourceName,
      type: book.type,
      lastChapter: r.lastChapter.isEmpty
          ? book.lastChapter
          : await _extract(html, r.lastChapter),
      intro: TextRepair.repair(rawIntro),
    );
  }

  Future<String> _pickCover(String html, String rule, String fallback) async {
    final raw = await _extract(html, rule);
    if (raw.isEmpty) return fallback;
    return RuleEngine.absoluteUrl(source.baseUrl, raw);
  }

  /// 目录加载
  ///
  /// 两处体验优化：
  /// - [onPageChunk]：每解析完一页**立即回调**，UI 可以先渲染已有章节，
  ///   不必等 5 页全部抓完（速读谷一页 1000 章，首屏就够看）
  /// - 已知总页数时**并发**抓取后续页（并发 3），不再一页一页排队
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    if (source.implementation == SourceImplementation.jsFile) {
      return _jsToc(book);
    }
    final rule = source.toc;
    if (rule == null) throw SourceException('书源未配置目录规则');

    var pageUrl = book.bookUrl;
    // 详情页刚抓过同一个 URL 时这里会直接命中缓存，不再发第二次请求
    var html = await _getText(
      pageUrl,
      charset: source.search.charset,
      headers: source.headers,
      useCache: source.headers.isEmpty,
      referer: _referer,
      maxBytes: _tocPageLimit,
      idleTimeout: const Duration(seconds: 8),
    );

    // 目录页可能与详情页不同
    if (source.detail.tocUrl.isNotEmpty) {
      final raw = await _extract(html, source.detail.tocUrl);
      if (raw.isNotEmpty) {
        pageUrl = RuleEngine.absoluteUrl(source.baseUrl, raw);
        html = await _getText(
          pageUrl,
          charset: source.search.charset,
          headers: source.headers,
          useCache: source.headers.isEmpty,
          referer: _referer,
          maxBytes: _tocPageLimit,
        );
      }
    }

    final chunks = <int, List<Chapter>>{};
    final seenUrls = <String>{};
    String? warning;
    Object? lastError;

    Future<void> commit(int page, String pageHtml, String baseUrl) async {
      final list = await _parseChapters(pageHtml, baseUrl, rule, seenUrls);
      chunks[page] = list;
      // 每页到货立刻通知 UI
      onPageChunk?.call(page, list);
      onProgress?.call(page, seenUrls.length);
    }

    // ---- 第 1 页（上面已经抓到了）----
    await commit(1, html, pageUrl);
    for (
      var attempt = 0;
      attempt < 2 && (chunks[1] ?? const []).isEmpty;
      attempt++
    ) {
      try {
        html = await _getText(
          pageUrl,
          charset: source.search.charset,
          headers: source.headers,
          useCache: source.headers.isEmpty,
          referer: _referer,
          retries: 1,
          maxBytes: _tocPageLimit,
          idleTimeout: const Duration(seconds: 8),
        );
        await commit(1, html, pageUrl);
      } catch (e) {
        lastError = e;
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }

    final total = await _detectTotalPages(html, rule);
    final canPipelines =
        rule.pageUrlTemplate != null && rule.pageUrlTemplate!.isNotEmpty;

    if (canPipelines && total != null && total > 1) {
      // ---- 已知总页数：2..N 页并发抓 ----
      var nextPage = 2;
      while (nextPage <= total) {
        final batch = <int>[
          for (
            var p = nextPage;
            p < nextPage + _tocConcurrency && p <= total;
            p++
          )
            p,
        ];
        final urls = batch.map((p) => _pageUrl(book, p, rule)).toList();
        final results = await Future.wait(
          urls.map(
            (u) => _fetchTocPage(u).then<String?>(
              (h) => h,
              onError: (Object e) {
                lastError = e;
                return null;
              },
            ),
          ),
        );
        for (var i = 0; i < batch.length; i++) {
          final h = results[i];
          if (h == null || h.isEmpty) continue;
          await commit(batch[i], h, urls[i]);
        }
        nextPage += _tocConcurrency;
        if (nextPage <= total) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }
      final missing = [
        for (var p = 1; p <= total; p++)
          if ((chunks[p] ?? const []).isEmpty) p,
      ];
      if (missing.isNotEmpty) {
        final head = missing.take(3).join('、');
        warning =
            '第 $head 页未取到章节，目录可能不完整'
            '${lastError == null ? '' : '（$lastError）'}';
      }
    } else if ((chunks[1] ?? const []).isNotEmpty) {
      // ---- 总页数未知：按「下一页」串行翻（老逻辑）----
      var curUrl = pageUrl;
      var curHtml = html;
      var page = 1;
      final visited = <String>{curUrl};
      while (page < 40) {
        String next = '';
        if (rule.nextTocUrl != null && rule.nextTocUrl!.isNotEmpty) {
          next = await _extract(curHtml, rule.nextTocUrl!);
        }
        if (next.isEmpty && canPipelines) {
          next = _pageUrl(book, page + 1, rule);
        }
        if (next.isEmpty) break;
        final nextUrl = RuleEngine.absoluteUrl(curUrl, next);
        if (nextUrl == curUrl || !visited.add(nextUrl)) break;

        String? pageHtml;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            pageHtml = await _getText(
              nextUrl,
              charset: source.search.charset,
              headers: source.headers,
              useCache: source.headers.isEmpty,
              referer: _referer,
              retries: 1,
              maxBytes: _tocPageLimit,
              idleTimeout: const Duration(seconds: 8),
            );
          } catch (e) {
            lastError = e;
            await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
            continue;
          }
          final probe = _complex
              ? await resolver.list(pageHtml, rule.chapterList)
              : RuleEngine.elements(parser.parse(pageHtml), rule.chapterList);
          if (probe.isNotEmpty) break;
          await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
        }
        page++;
        if (pageHtml == null) {
          warning = '第 $page 页请求失败，目录可能不完整';
          break;
        }
        curUrl = nextUrl;
        curHtml = pageHtml;
        final before = seenUrls.length;
        await commit(page, pageHtml, curUrl);
        if (seenUrls.length == before) {
          // 这一页没有新章节，多半是到头了
          break;
        }
      }
    } else {
      warning ??=
          '目录页没有解析到章节'
          '${lastError == null ? '' : '：$lastError'}';
    }

    final chapters = <Chapter>[];
    for (final p in chunks.keys.toList()..sort()) {
      chapters.addAll(chunks[p]!);
    }
    if (chapters.isEmpty) {
      throw SourceException(warning ?? '目录为空，规则可能已失效');
    }
    return TocResult(
      chapters: chapters,
      partial: warning != null,
      warning: warning,
      pagesLoaded: chunks.length,
    );
  }

  /// 抓取单页目录（内部已带一次重试）
  Future<String> _fetchTocPage(String url) => _getText(
    url,
    charset: source.search.charset,
    headers: source.headers,
    useCache: source.headers.isEmpty,
    referer: _referer,
    retries: 1,
    maxBytes: _tocPageLimit,
    idleTimeout: const Duration(seconds: 8),
  );

  /// 解析一页的章节（用共享的 [seen] 去重）
  Future<List<Chapter>> _parseChapters(
    String html,
    String baseUrl,
    TocRule rule,
    Set<String> seen,
  ) async {
    final els = _complex
        ? await resolver.list(html, rule.chapterList)
        : RuleEngine.elements(parser.parse(html), rule.chapterList);
    final out = <Chapter>[];
    for (final el in els) {
      final title = await _field(el, rule.chapterName);
      final href = await _field(el, rule.chapterUrl);
      if (title.isEmpty || href.isEmpty) continue;
      final url = RuleEngine.absoluteUrl(baseUrl, href);
      if (!seen.add(url)) continue;
      out.add(Chapter(title: title, url: url));
    }
    return out;
  }

  /// 页码模板 → 第 [page] 页 URL
  String _pageUrl(Book book, int page, TocRule rule) {
    final t = rule.pageUrlTemplate;
    if (t == null || t.isEmpty) return book.bookUrl;
    final base = book.bookUrl.endsWith('/') ? book.bookUrl : '${book.bookUrl}/';
    return t
        .replaceAll('{{bookUrl}}', base)
        .replaceAll('{{page}}', page.toString());
  }

  /// 从分页区文本（如「上一页 1/5 下一页」）解析总页数
  Future<int?> _detectTotalPages(String html, TocRule rule) async {
    var text = '';
    if (rule.pageCount != null && rule.pageCount!.isNotEmpty) {
      text = await _extract(html, rule.pageCount!);
    }
    if (text.isEmpty) return null;
    final m = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(text);
    if (m != null) {
      final t = int.tryParse(m.group(2)!);
      if (t != null && t > 0 && t <= 60) return t;
    }
    final m2 = RegExp(r'共\s*(\d+)\s*页').firstMatch(text);
    if (m2 != null) {
      final t = int.tryParse(m2.group(1)!);
      if (t != null && t > 0 && t <= 60) return t;
    }
    return null;
  }

  /// 兼容旧调用：只要章节列表
  Future<List<Chapter>> toc(Book book) async => (await loadToc(book)).chapters;

  /// 正文（支持章内分页合并）。
  ///
  /// 速读谷/全本等站点间歇**截断正文页**（只吐前 1-2 段或 0 字节，反爬/限流），
  /// 导致"内容加载不出来"。正文过短（<100 字符）时用新鲜响应整体重试，
  /// 拿完整章；连续失败则抛错（阅读器会提示）。
  Future<String> content(Chapter chapter) async {
    if (source.implementation == SourceImplementation.jsFile) {
      return _jsContent(chapter);
    }
    final rule = source.content;
    if (rule == null) throw SourceException('书源未配置正文规则');

    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final text = await _fetchChapter(chapter, rule);
        if (text.length >= 100 || attempt == 2) return text;
        lastError = '正文过短（${text.length} 字符）';
      } catch (e) {
        lastError = e;
        if (attempt == 2) rethrow;
      }
      if (attempt < 2) {
        await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw SourceException('正文抓取失败：$lastError');
  }

  /// 漫画仅支持静态 HTML 图片列表，不执行图片解密或脚本。
  Future<List<String>> comicContent(Chapter chapter) async {
    if (source.implementation == SourceImplementation.jsFile) {
      final text = await _jsContent(chapter);
      return text
          .split(RegExp(r'\s+'))
          .where((u) => u.startsWith('http'))
          .toList();
    }
    final rule = source.content;
    if (rule == null) throw SourceException('书源未配置漫画正文规则');
    if (_complex) {
      final html = await _getText(
        chapter.url,
        charset: source.search.charset,
        headers: source.headers,
        referer: _referer,
        useCache: false,
      );
      final raw = await resolver.text(
        html,
        rule.content,
        context: {
          'chapter': {
            'url': chapter.url,
            'title': chapter.title,
          },
          'book': {'url': chapter.url, 'name': source.name},
        },
      );
      final images = _imagesFromContent(raw, chapter.url);
      if (images.isEmpty) {
        throw SourceException('未解析到漫画图片，规则可能已失效');
      }
      return images;
    }
    final at = rule.content.lastIndexOf('@');
    if (at <= 0) throw SourceException('漫画正文需要图片列表@src 规则');
    final selector = rule.content.substring(0, at);
    final attr = rule.content.substring(at + 1);
    final images = <String>{};
    final visited = <String>{};
    var url = chapter.url;
    for (var page = 0; page < 40 && visited.add(url); page++) {
      final html = await _getText(
        url,
        charset: source.search.charset,
        headers: source.headers,
        referer: _referer,
        useCache: false,
      );
      for (final el in RuleEngine.elements(parser.parse(html), selector)) {
        final raw = RuleEngine.extractFromElement(el, '@$attr');
        if (raw.isEmpty) continue;
        final image = Uri.parse(url).resolve(raw);
        if (['http', 'https'].contains(image.scheme) && image.host.isNotEmpty) {
          images.add(image.toString());
        }
      }
      if (!rule.mergePages || (rule.nextContentUrl ?? '').isEmpty) break;
      final next = await _extract(html, rule.nextContentUrl!);
      if (next.isEmpty) break;
      url = Uri.parse(url).resolve(next).toString();
    }
    if (images.isEmpty) throw SourceException('未解析到漫画图片，规则可能已失效');
    return images.toList();
  }

  /// 从 JS / 扩展规则产出的内容里提取图片地址。
  List<String> _imagesFromContent(String raw, String baseUrl) {
    final images = <String>{};
    final doc = parser.parse(raw.contains('<') ? raw : '<html></html>');
    for (final img in doc.querySelectorAll('img')) {
      final src = img.attributes['src'] ??
          img.attributes['data-src'] ??
          img.attributes['data-original'] ??
          '';
      if (src.isEmpty) continue;
      final uri = Uri.parse(baseUrl).resolve(src);
      if (['http', 'https'].contains(uri.scheme) && uri.host.isNotEmpty) {
        images.add(uri.toString());
      }
    }
    if (images.isEmpty) {
      for (final part in raw.split(RegExp(r'\s+'))) {
        final uri = Uri.tryParse(part);
        if (uri != null &&
            ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty) {
          images.add(uri.toString());
        }
      }
    }
    return images.toList();
  }

  Future<String> _fetchChapter(Chapter chapter, ContentRule rule) async {
    var url = chapter.url;
    final buf = StringBuffer();
    final visited = <String>{};
    // 章内分页（部分站点每页只 2-3 段、章节分 30+ 页），最多取 40 页
    for (var i = 0; i < 40 && url.isNotEmpty; i++) {
      if (!visited.add(url)) break;
      final html = await _getText(
        url,
        charset: source.search.charset,
        headers: source.headers,
        referer: _referer,
        maxBytes: 2 * 1024 * 1024,
        idleTimeout: const Duration(seconds: 10),
        useCache: false, // 正文每页独立抓，重试需新鲜响应
      );
      final part = await _extract(
        html,
        rule.content,
        context: {
          'chapter': {'url': url, 'title': chapter.title},
          'book': {'url': chapter.url, 'name': source.name},
        },
      );
      if (part.isNotEmpty) buf.writeln(part);

      if (!rule.mergePages ||
          rule.nextContentUrl == null ||
          rule.nextContentUrl!.isEmpty) {
        break;
      }
      final next = await _extract(html, rule.nextContentUrl!);
      if (next.isEmpty) break;
      final nextUrl = RuleEngine.absoluteUrl(url, next);
      if (visited.contains(nextUrl) || nextUrl == url) break;
      url = nextUrl;
      await Future.delayed(const Duration(milliseconds: 150));
    }

    var text = buf.toString().trim();
    if (text.isEmpty) throw SourceException('正文抓取为空，规则可能已失效');
    text = TextRepair.repair(text);
    return text;
  }

  /// 视频章节：返回可直接播放的 mp4/m3u8 地址。
  Future<String> videoUrl(Chapter chapter) async {
    if (source.implementation == SourceImplementation.jsFile) {
      final text = await _jsContent(chapter);
      final url = _pickMediaUrl(text);
      if (url.isEmpty) throw SourceException('JS 书源未返回视频地址');
      return url;
    }
    final rule = source.content;
    if (rule == null) throw SourceException('书源未配置视频地址规则');
    final html = await _getText(
      chapter.url,
      charset: source.search.charset,
      headers: source.headers,
      referer: _referer,
      maxBytes: 2 * 1024 * 1024,
      useCache: false,
    );
    final raw = await _extract(
      html,
      rule.content,
      context: {
        'chapter': {'url': chapter.url, 'title': chapter.title},
        'book': {'url': chapter.url, 'name': source.name},
      },
    );
    final url = _pickMediaUrl(raw);
    if (url.isEmpty) throw SourceException('未解析到视频地址');
    return url;
  }

  static String _pickMediaUrl(String raw) {
    final direct = RegExp(
      r'https?://[^\s<>]+?\.(?:m3u8|mp4|mkv|webm|mov)(?:\?[^\s<>]*)?',
      caseSensitive: false,
    ).firstMatch(raw)?.group(0);
    if (direct != null) return direct;
    for (final line in raw.split(RegExp(r'\s+'))) {
      final u = Uri.tryParse(line);
      if (u != null &&
          ['http', 'https'].contains(u.scheme) &&
          u.host.isNotEmpty) {
        return line;
      }
    }
    return '';
  }

  // ---------- JavaScript 单文件书源 ----------

  Future<dynamic> _callJs(List<String> names, List<dynamic> args) async {
    for (final name in names) {
      try {
        final value = await LegadoRuntime().call(source, name, args);
        final text = value?.toString() ?? '';
        if (text.isNotEmpty && text != 'null' && text != 'undefined') {
          return value;
        }
      } catch (_) {}
    }
    return null;
  }

  Map<String, dynamic>? _jsMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  List<dynamic> _jsList(dynamic value) {
    final decoded = _jsMap(value);
    if (decoded != null) {
      for (final key in ['books', 'list', 'chapters', 'data', 'result']) {
        final v = decoded[key];
        if (v is List) return v;
        final nested = _jsList(v);
        if (nested.isNotEmpty) return nested;
      }
    }
    if (value is List) return value;
    if (value is String) {
      try {
        final parsed = jsonDecode(value);
        if (parsed is List) return parsed;
      } catch (_) {}
    }
    return const [];
  }

  Book _jsBook(dynamic raw, Book fallback) {
    final map = _jsMap(raw) ?? <String, dynamic>{};
    final url = (map['bookUrl'] ?? map['url'] ?? fallback.bookUrl).toString();
    return Book(
      name: (map['name'] ?? fallback.name).toString(),
      author: (map['author'] ?? fallback.author).toString(),
      cover: (map['coverUrl'] ?? map['cover'] ?? fallback.cover).toString(),
      bookUrl: RuleEngine.absoluteUrl(source.baseUrl, url),
      sourceId: fallback.sourceId,
      sourceName: fallback.sourceName,
      type: fallback.type,
      lastChapter: map['lastChapter']?.toString() ?? fallback.lastChapter,
      intro: map['intro']?.toString() ?? fallback.intro,
    );
  }

  Chapter _jsChapter(dynamic raw) {
    final map = _jsMap(raw) ?? <String, dynamic>{};
    return Chapter(
      title: (map['chapterName'] ?? map['title'] ?? '').toString(),
      url: RuleEngine.absoluteUrl(
        source.baseUrl,
        (map['chapterUrl'] ?? map['url'] ?? '').toString(),
      ),
    );
  }

  Future<List<Book>> _jsSearch(String keyword, int page) async {
    var value = await _callJs(
      ['search', 'searchContent', 'searchBook'],
      [keyword, page],
    );
    value ??= await _callJs(
      ['search', 'searchContent'],
      [
        {'key': keyword, 'keyword': keyword, 'page': page},
      ],
    );
    final fallback = Book(
      name: '',
      author: '',
      cover: '',
      bookUrl: '',
      sourceId: source.id,
      sourceName: source.name,
      type: source.type,
    );
    return _jsList(value)
        .whereType<Map>()
        .map((e) => _jsBook(e, fallback))
        .where((b) => b.name.isNotEmpty && b.bookUrl.isNotEmpty)
        .toList();
  }

  Future<Book> _jsDetail(Book book) async {
    final value = await _callJs(['detail', 'getBookInfo', 'bookInfo'], [book]);
    if (value == null) return book;
    return _jsBook(value, book);
  }

  Future<TocResult> _jsToc(Book book) async {
    final value = await _callJs(
      ['getChapters', 'toc', 'bookChapterList', 'getChapterList'],
      [book],
    );
    final chapters = _jsList(value)
        .map(_jsChapter)
        .where((c) => c.url.isNotEmpty)
        .toList();
    if (chapters.isEmpty) throw SourceException('JS 书源未返回目录');
    return TocResult(chapters: chapters);
  }

  Future<String> _jsContent(Chapter chapter) async {
    final value = await _callJs(
      ['getContent', 'content', 'getChapterContent'],
      [chapter],
    );
    if (value is Map) {
      final raw = value['content'] ?? value['data'] ?? value['text'] ?? '';
      if (raw is List) return raw.join('\n');
      return raw.toString();
    }
    if (value is List) return value.join('\n');
    return value?.toString() ?? '';
  }
}

class SourceException implements Exception {
  final String message;
  SourceException(this.message);
  @override
  String toString() => message;
}
