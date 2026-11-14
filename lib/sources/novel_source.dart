/// 小说书源执行器：把 BookSource 的 JSON 规则变成实际的
/// search / detail / toc / content 四个接口。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../models/book.dart';
import '../models/book_source.dart';
import '../models/discover.dart';
import '../services/http_client.dart';
import '../utils/text_repair.dart';
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

  /// 搜索。失败抛异常，由聚合层捕获并按源上报。
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final rule = source.search;
    if (rule.urlTemplate.isEmpty || rule.bookList.isEmpty) {
      throw SourceException('书源搜索规则不完整');
    }
    final url = rule.urlTemplate
        .replaceAll('{{key}}', Uri.encodeQueryComponent(keyword))
        .replaceAll('{{page}}', page.toString());

    final html = await HttpClient.getText(
      url,
      charset: rule.charset,
      method: rule.method,
      referer: _referer,
      maxBytes: 3 * 1024 * 1024,
      query: rule.method == 'POST'
          ? {'searchkey': keyword, 'page': page, 'searchtype': 'all'}
          : null,
    );

    final doc = parser.parse(html);
    final items = RuleEngine.elements(doc, rule.bookList);
    if (items.isEmpty) return [];

    final books = <Book>[];
    for (final el in items) {
      final name = RuleEngine.extractFromElement(el, rule.name);
      final bookUrlRaw = RuleEngine.extractFromElement(el, rule.bookUrl);
      if (name.isEmpty || bookUrlRaw.isEmpty) continue;
      books.add(Book(
        name: TextRepair.repair(name),
        author:
            TextRepair.repair(RuleEngine.extractFromElement(el, rule.author)),
        cover: RuleEngine.absoluteUrl(
            source.baseUrl, RuleEngine.extractFromElement(el, rule.cover)),
        bookUrl: RuleEngine.absoluteUrl(source.baseUrl, bookUrlRaw),
        sourceId: source.id,
        sourceName: source.name,
        type: ContentType.novel,
        lastChapter: rule.lastChapter == null
            ? null
            : RuleEngine.extractFromElement(el, rule.lastChapter!),
      ));
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
      html = await HttpClient.getText(
        url,
        charset: source.search.charset,
        referer: _referer,
        maxBytes: 3 * 1024 * 1024,
        idleTimeout: const Duration(seconds: 10),
        useCache: false,
      );
      doc = parser.parse(html);
      books = _parseCards(tab, doc);
      if (books.isNotEmpty) break;
      if (attempt < 2) {
        await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }

    var pages = 1;
    if (tab.pageCount != null && tab.pageCount!.isNotEmpty) {
      pages = _parsePagesText(RuleEngine.extract(html, tab.pageCount!)) ?? 1;
    } else if (tab.pageLinks != null && tab.pageLinks!.isNotEmpty) {
      pages = _pagesFromLinks(doc, tab.pageLinks!) ?? 1;
    }
    return DiscoverResult(title: tab.name, books: books, page: page, pages: pages);
  }

  /// 解析一页发现卡片（封面为空且配了模板时，从书 URL 构造）。
  List<Book> _parseCards(DiscoverTabRule tab, dom.Document doc) {
    final items = RuleEngine.elements(doc, tab.cardList ?? source.search.bookList);
    final books = <Book>[];
    for (final el in items) {
      final name = TextRepair.repair(
          RuleEngine.extractFromElement(el, tab.cardName ?? source.search.name));
      final bookUrlRaw = RuleEngine.extractFromElement(
          el, tab.cardBookUrl ?? source.search.bookUrl);
      // 跳过空链接与占位链接（部分站点用 # / #### / javascript: 做占位）
      if (name.isEmpty || bookUrlRaw.isEmpty) continue;
      if (bookUrlRaw == '#' ||
          bookUrlRaw.contains('####') ||
          bookUrlRaw.startsWith('javascript:')) {
        continue;
      }
      var cover = RuleEngine.absoluteUrl(source.baseUrl,
          RuleEngine.extractFromElement(el, tab.cardCover ?? source.search.cover));
      if (cover.isEmpty) cover = _deriveCover(tab, bookUrlRaw);
      books.add(Book(
        name: name,
        author: TextRepair.repair(RuleEngine.extractFromElement(
            el, tab.cardAuthor ?? source.search.author)),
        cover: cover,
        bookUrl: RuleEngine.absoluteUrl(source.baseUrl, bookUrlRaw),
        sourceId: source.id,
        sourceName: source.name,
        type: source.type,
        lastChapter: (tab.cardLastChapter ?? source.search.lastChapter) == null
            ? null
            : RuleEngine.extractFromElement(
                el, (tab.cardLastChapter ?? source.search.lastChapter)!),
      ));
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
    final html = await HttpClient.getText(
      book.bookUrl,
      charset: source.search.charset,
      referer: _referer,
      maxBytes: 4 * 1024 * 1024,
    );
    final r = source.detail;
    final rawName = r.name.isEmpty ? '' : RuleEngine.extract(html, r.name);
    final rawAuthor =
        r.author.isEmpty ? '' : RuleEngine.extract(html, r.author);
    final rawIntro = r.intro.isEmpty ? '' : RuleEngine.extract(html, r.intro);

    return Book(
      name: rawName.isEmpty ? book.name : TextRepair.repair(rawName),
      author: rawAuthor.isEmpty ? book.author : TextRepair.repair(rawAuthor),
      cover: r.cover.isEmpty
          ? book.cover
          : _pickCover(html, r.cover, book.cover),
      bookUrl: book.bookUrl,
      sourceId: book.sourceId,
      sourceName: book.sourceName,
      type: book.type,
      lastChapter: r.lastChapter.isEmpty
          ? book.lastChapter
          : RuleEngine.extract(html, r.lastChapter),
      intro: TextRepair.repair(rawIntro),
    );
  }

  String _pickCover(String html, String rule, String fallback) {
    final raw = RuleEngine.extract(html, rule);
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
    final rule = source.toc;
    if (rule == null) throw SourceException('书源未配置目录规则');

    var pageUrl = book.bookUrl;
    // 详情页刚抓过同一个 URL 时这里会直接命中缓存，不再发第二次请求
    var html = await HttpClient.getText(
      pageUrl,
      charset: source.search.charset,
      referer: _referer,
      maxBytes: _tocPageLimit,
      idleTimeout: const Duration(seconds: 8),
    );

    // 目录页可能与详情页不同
    if (source.detail.tocUrl.isNotEmpty) {
      final raw = RuleEngine.extract(html, source.detail.tocUrl);
      if (raw.isNotEmpty) {
        pageUrl = RuleEngine.absoluteUrl(source.baseUrl, raw);
        html = await HttpClient.getText(
          pageUrl,
          charset: source.search.charset,
          referer: _referer,
          maxBytes: _tocPageLimit,
        );
      }
    }

    final chunks = <int, List<Chapter>>{};
    final seenUrls = <String>{};
    String? warning;
    Object? lastError;

    void commit(int page, String pageHtml, String baseUrl) {
      final list = _parseChapters(pageHtml, baseUrl, rule, seenUrls);
      chunks[page] = list;
      // 每页到货立刻通知 UI
      onPageChunk?.call(page, list);
      onProgress?.call(page, seenUrls.length);
    }

    // ---- 第 1 页（上面已经抓到了）----
    commit(1, html, pageUrl);
    for (var attempt = 0; attempt < 2 && (chunks[1] ?? const []).isEmpty; attempt++) {
      try {
        html = await HttpClient.getText(
          pageUrl,
          charset: source.search.charset,
          referer: _referer,
          retries: 1,
          maxBytes: _tocPageLimit,
          idleTimeout: const Duration(seconds: 8),
        );
        commit(1, html, pageUrl);
      } catch (e) {
        lastError = e;
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }

    final total = _detectTotalPages(html, rule);
    final canPipelines =
        rule.pageUrlTemplate != null && rule.pageUrlTemplate!.isNotEmpty;

    if (canPipelines && total != null && total > 1) {
      // ---- 已知总页数：2..N 页并发抓 ----
      var nextPage = 2;
      while (nextPage <= total) {
        final batch = <int>[
          for (var p = nextPage; p < nextPage + _tocConcurrency && p <= total; p++)
            p,
        ];
        final urls = batch.map((p) => _pageUrl(book, p, rule)).toList();
        final results = await Future.wait(urls.map((u) => _fetchTocPage(u)
            .then<String?>((h) => h, onError: (Object e) {
          lastError = e;
          return null;
        })));
        for (var i = 0; i < batch.length; i++) {
          final h = results[i];
          if (h == null || h.isEmpty) continue;
          commit(batch[i], h, urls[i]);
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
        warning = '第 $head 页未取到章节，目录可能不完整'
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
          next = RuleEngine.extract(curHtml, rule.nextTocUrl!);
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
            pageHtml = await HttpClient.getText(
              nextUrl,
              charset: source.search.charset,
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
          if (RuleEngine.elements(parser.parse(pageHtml), rule.chapterList)
              .isNotEmpty) {
            break;
          }
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
        commit(page, pageHtml, curUrl);
        if (seenUrls.length == before) {
          // 这一页没有新章节，多半是到头了
          break;
        }
      }
    } else {
      warning ??= '目录页没有解析到章节'
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
  Future<String> _fetchTocPage(String url) => HttpClient.getText(
        url,
        charset: source.search.charset,
        referer: _referer,
        retries: 1,
        maxBytes: _tocPageLimit,
        idleTimeout: const Duration(seconds: 8),
      );

  /// 解析一页的章节（用共享的 [seen] 去重）
  List<Chapter> _parseChapters(
    String html,
    String baseUrl,
    TocRule rule,
    Set<String> seen,
  ) {
    final els = RuleEngine.elements(parser.parse(html), rule.chapterList);
    final out = <Chapter>[];
    for (final el in els) {
      final title = RuleEngine.extractFromElement(el, rule.chapterName);
      final href = RuleEngine.extractFromElement(el, rule.chapterUrl);
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
  int? _detectTotalPages(String html, TocRule rule) {
    var text = '';
    if (rule.pageCount != null && rule.pageCount!.isNotEmpty) {
      text = RuleEngine.extract(html, rule.pageCount!);
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

  Future<String> _fetchChapter(Chapter chapter, ContentRule rule) async {
    var url = chapter.url;
    final buf = StringBuffer();
    final visited = <String>{};
    // 章内分页（部分站点每页只 2-3 段、章节分 30+ 页），最多取 40 页
    for (var i = 0; i < 40 && url.isNotEmpty; i++) {
      if (!visited.add(url)) break;
      final html = await HttpClient.getText(
        url,
        charset: source.search.charset,
        referer: _referer,
        maxBytes: 2 * 1024 * 1024,
        idleTimeout: const Duration(seconds: 10),
        useCache: false, // 正文每页独立抓，重试需新鲜响应
      );
      final part = RuleEngine.extract(html, rule.content);
      if (part.isNotEmpty) buf.writeln(part);

      if (!rule.mergePages ||
          rule.nextContentUrl == null ||
          rule.nextContentUrl!.isEmpty) {
        break;
      }
      final next = RuleEngine.extract(html, rule.nextContentUrl!);
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
}

class SourceException implements Exception {
  final String message;
  SourceException(this.message);
  @override
  String toString() => message;
}
