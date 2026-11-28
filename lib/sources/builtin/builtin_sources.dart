/// 内置书源（JSON 格式）
///
/// 说明：站点结构可能变化，书源可在「书源管理」中开关或自行调整。
/// 规则语法见 lib/sources/rule_engine.dart 顶部注释。
///   `A || B`        规则回退（列表页与详情页结构不同时用）
///   `##正则##`      后处理（如去掉 URL 的 # 锚点、去掉「作者：」前缀）
///   `@html`         取 innerHTML，<br> 转换行（正文用，保留分段）
///   `:contains(x)`  按文本筛选链接（如「下一页」）
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book_source.dart';
import '../source_import.dart';

const String builtinSourcesJson = r'''
[
  {
    "sourceName": "速读谷",
    "sourceUrl": "https://www.sudugu.cc",
    "sourceType": "novel",
    "enabled": true,
    "charset": "utf-8",
    "search": {
      "url": "https://www.sudugu.cc/modules/article/search.php?searchkey={{key}}&searchtype=all",
      "method": "GET",
      "charset": "utf-8",
      "bookList": "#fengtui div.item || div.item",
      "name": "h3 a@text || h1 a@text",
      "author": ".itemtxt p a@text##^作者：\\s*## || ul li:first-child@text##^作者：\\s*##",
      "cover": ".item img@src",
      "bookUrl": "h3 a@href || h1 a@href##(#.*)$##",
      "lastChapter": ".itemtxt ul li:first-child a@text || ul li a@text"
    },
    "detail": {
      "name": ".itemtxt h1 a@text",
      "author": ".itemtxt p a@text##^作者：\\s*##",
      "cover": ".item img@src",
      "intro": "h2.op + .des@text",
      "tocUrl": "",
      "lastChapter": ".itemtxt ul li:first-child a@text"
    },
    "toc": {
      "chapterList": "#list li a",
      "chapterName": "text",
      "chapterUrl": "href",
      "nextTocUrl": "#pages a.gr@href",
      "pageUrlTemplate": "{{bookUrl}}{{page}}",
      "pageCount": "#pages@text"
    },
    "content": {
      "content": ".con@html",
      "nextContentUrl": ".prenext a:contains(下一页)@href",
      "mergePages": true
    },
    "discover": [
      {"key": "top", "name": "阅读排行", "isRank": true,
       "url": "https://www.sudugu.cc/top.html", "cardList": "div.item"},
      {"key": "quanben", "name": "完结小说", "isRank": true,
       "url": "https://www.sudugu.cc/quanben/{{page}}.html", "cardList": "div.item",
       "pageLinks": "a[href*='/quanben/']"},
      {"key": "1", "name": "玄幻小说", "isRank": false,
       "url": "https://www.sudugu.cc/fenlei/1/{{page}}/", "cardList": "div.item",
       "pageLinks": "a[href*='/fenlei/']"},
      {"key": "2", "name": "仙侠小说", "isRank": false,
       "url": "https://www.sudugu.cc/fenlei/2/{{page}}/", "cardList": "div.item",
       "pageLinks": "a[href*='/fenlei/']"},
      {"key": "3", "name": "都市小说", "isRank": false,
       "url": "https://www.sudugu.cc/fenlei/3/{{page}}/", "cardList": "div.item",
       "pageLinks": "a[href*='/fenlei/']"},
      {"key": "4", "name": "历史小说", "isRank": false,
       "url": "https://www.sudugu.cc/fenlei/4/{{page}}/", "cardList": "div.item",
       "pageLinks": "a[href*='/fenlei/']"},
      {"key": "5", "name": "军事小说", "isRank": false,
       "url": "https://www.sudugu.cc/fenlei/5/{{page}}/", "cardList": "div.item",
       "pageLinks": "a[href*='/fenlei/']"},
      {"key": "6", "name": "科幻小说", "isRank": false,
       "url": "https://www.sudugu.cc/fenlei/6/{{page}}/", "cardList": "div.item",
       "pageLinks": "a[href*='/fenlei/']"},
      {"key": "7", "name": "言情小说", "isRank": false,
       "url": "https://www.sudugu.cc/fenlei/7/{{page}}/", "cardList": "div.item",
       "pageLinks": "a[href*='/fenlei/']"}
    ]
  },
  {
    "sourceName": "速读谷(备用)",
    "sourceUrl": "https://www.sudugu520.com",
    "sourceType": "novel",
    "enabled": true,
    "charset": "utf-8",
    "search": {
      "url": "https://www.sudugu520.com/i/sor.aspx?key={{key}}",
      "method": "GET",
      "charset": "utf-8",
      "bookList": "div.item",
      "name": ".itemtxt h3 a@text",
      "author": ".itemtxt p a@text##^作者：\\s*##",
      "cover": ".item img@src",
      "bookUrl": ".itemtxt h3 a@href || .item > a@href",
      "lastChapter": ".itemtxt ul li:first-child a@text"
    },
    "detail": {
      "name": ".itemtxt h1 a@text",
      "author": ".itemtxt p a@text##^作者：\\s*##",
      "cover": ".item img@src",
      "intro": "h2.op + .des@text",
      "tocUrl": "",
      "lastChapter": ".itemtxt ul li:first-child a@text"
    },
    "toc": {
      "chapterList": "#list li a",
      "chapterName": "text",
      "chapterUrl": "href",
      "nextTocUrl": "",
      "pageUrlTemplate": "",
      "pageCount": ""
    },
    "content": {
      "content": ".con@html",
      "nextContentUrl": ".prenext a:contains(下一页)@href",
      "mergePages": true
    },
    "discover": [
      {"key": "top", "name": "阅读排行", "isRank": true,
       "url": "https://www.sudugu520.com/paihang/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/paihang/']"},
      {"key": "quanben", "name": "完结小说", "isRank": true,
       "url": "https://www.sudugu520.com/wanjie/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/wanjie/']"},
      {"key": "xuanhuan", "name": "玄幻小说", "isRank": false,
       "url": "https://www.sudugu520.com/xuanhuan/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/xuanhuan/']"},
      {"key": "xianxia", "name": "仙侠小说", "isRank": false,
       "url": "https://www.sudugu520.com/xianxia/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/xianxia/']"},
      {"key": "dushi", "name": "都市小说", "isRank": false,
       "url": "https://www.sudugu520.com/dushi/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/dushi/']"},
      {"key": "lishi", "name": "历史小说", "isRank": false,
       "url": "https://www.sudugu520.com/lishi/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/lishi/']"},
      {"key": "junshi", "name": "军事小说", "isRank": false,
       "url": "https://www.sudugu520.com/junshi/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/junshi/']"},
      {"key": "kehuan", "name": "科幻小说", "isRank": false,
       "url": "https://www.sudugu520.com/kehuan/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/kehuan/']"},
      {"key": "yanqing", "name": "言情小说", "isRank": false,
       "url": "https://www.sudugu520.com/yanqing/{{page}}.html", "cardList": "div.item",
       "pageCount": "div.page span@text", "pageLinks": "a[href*='/yanqing/']"}
    ]
  },
  {
    "sourceName": "全本小说网",
    "sourceUrl": "https://www.qbxs.net",
    "sourceType": "novel",
    "enabled": true,
    "charset": "utf-8",
    "search": {
      "url": "https://www.qbxs.net/search/?searchkey={{key}}",
      "method": "GET",
      "bookList": "table#rankinglist tr",
      "name": "td:eq(0) a@text",
      "author": "td:eq(2)@text",
      "cover": "",
      "bookUrl": "td:eq(0) a@href##(#.*)$##",
      "lastChapter": "td:eq(1) a@text"
    },
    "detail": {
      "name": "div.introduce h1@text",
      "author": "span:contains(作者) a@text",
      "cover": "div.pic img@src",
      "intro": "p.jj@text",
      "lastChapter": ""
    },
    "toc": {
      "chapterList": "div.ml_list li a",
      "chapterName": "text",
      "chapterUrl": "href"
    },
    "content": {
      "content": "div#articlecontent@html",
      "nextContentUrl": "#next_url@href",
      "mergePages": true
    },
    "discover": [
      {"key": "top", "name": "总排行榜", "isRank": true,
       "url": "https://www.qbxs.net/rank/",
       "cardCoverPattern": "https://www.qbxs.net/images/{id1000}/{id}/{id}s.jpg"},
      {"key": "allvisit", "name": "总点击榜", "isRank": true,
       "url": "https://www.qbxs.net/rank/allvisit/",
       "cardCoverPattern": "https://www.qbxs.net/images/{id1000}/{id}/{id}s.jpg"},
      {"key": "monthvisit", "name": "月点击榜", "isRank": true,
       "url": "https://www.qbxs.net/rank/monthvisit/",
       "cardCoverPattern": "https://www.qbxs.net/images/{id1000}/{id}/{id}s.jpg"},
      {"key": "weekvisit", "name": "周点击榜", "isRank": true,
       "url": "https://www.qbxs.net/rank/weekvisit/",
       "cardCoverPattern": "https://www.qbxs.net/images/{id1000}/{id}/{id}s.jpg"},
      {"key": "goodnum", "name": "收藏榜", "isRank": true,
       "url": "https://www.qbxs.net/rank/goodnum/",
       "cardCoverPattern": "https://www.qbxs.net/images/{id1000}/{id}/{id}s.jpg"},
      {"key": "1", "name": "玄幻小说", "isRank": false,
       "url": "https://www.qbxs.net/sort/1/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"},
      {"key": "2", "name": "修真小说", "isRank": false,
       "url": "https://www.qbxs.net/sort/2/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"},
      {"key": "3", "name": "都市小说", "isRank": false,
       "url": "https://www.qbxs.net/sort/3/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"},
      {"key": "4", "name": "历史小说", "isRank": false,
       "url": "https://www.qbxs.net/sort/4/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"},
      {"key": "5", "name": "网游小说", "isRank": false,
       "url": "https://www.qbxs.net/sort/5/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"},
      {"key": "6", "name": "科幻小说", "isRank": false,
       "url": "https://www.qbxs.net/sort/6/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"},
      {"key": "7", "name": "其他小说", "isRank": false,
       "url": "https://www.qbxs.net/sort/7/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"},
      {"key": "quanben", "name": "完结小说", "isRank": false,
       "url": "https://www.qbxs.net/quanben/sort/{{page}}/", "cardList": "div.tt",
       "cardName": "h3 a@text", "cardAuthor": "p.p1 a@text",
       "cardCover": "span.pic img@src", "cardBookUrl": "h3 a@href",
       "pageLinks": "#pagelink a"}
    ]
  },
  {
    "sourceName": "八一中文网",
    "sourceUrl": "http://www.81shuku.info",
    "sourceType": "novel",
    "enabled": true,
    "charset": "utf-8",
    "search": {
      "url": "http://www.81shuku.info/modules/article/search.php",
      "method": "POST",
      "bookList": "tr#nr",
      "name": "td:eq(0) a@text",
      "author": "td:eq(2)@text",
      "cover": "",
      "bookUrl": "td:eq(0) a@href",
      "lastChapter": "td:eq(1) a@text"
    },
    "detail": {
      "name": "div#info h1@text",
      "author": "div#info p:contains(作者)@text##.*作者[：:]\\s*##",
      "cover": "div#fmimg img@src",
      "intro": "div#intro p@text",
      "lastChapter": ""
    },
    "toc": {
      "chapterList": "div#list dd a",
      "chapterName": "text",
      "chapterUrl": "href"
    },
    "content": {
      "content": "div#content@html",
      "mergePages": false
    },
    "discover": [
      {"key": "vote", "name": "推荐榜", "isRank": true,
       "url": "http://www.81shuku.info/paihangbang/", "cardList": "div.box.b1 li",
       "cardName": "a@text", "cardBookUrl": "a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg"},
      {"key": "goodnum", "name": "收藏榜", "isRank": true,
       "url": "http://www.81shuku.info/paihangbang/goodnum.html", "cardList": "div.box.b1 li",
       "cardName": "a@text", "cardBookUrl": "a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg"},
      {"key": "newbook", "name": "新书入库", "isRank": true,
       "url": "http://www.81shuku.info/paihangbang/newbook.html", "cardList": "div.box.b1 li",
       "cardName": "a@text", "cardBookUrl": "a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg"},
      {"key": "1", "name": "玄幻小说", "isRank": false,
       "url": "http://www.81shuku.info/xuanhuanxiaoshuo/1_{{page}}.html", "cardList": "div.l li",
       "cardName": "span.s2 a@text", "cardAuthor": "span.s5@text",
       "cardBookUrl": "span.s2 a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg",
       "cardLastChapter": "span.s3 a@text",
       "pageCount": "#pagestats@text"},
      {"key": "2", "name": "修真小说", "isRank": false,
       "url": "http://www.81shuku.info/xiuzhenxiaoshuo/1_{{page}}.html", "cardList": "div.l li",
       "cardName": "span.s2 a@text", "cardAuthor": "span.s5@text",
       "cardBookUrl": "span.s2 a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg",
       "cardLastChapter": "span.s3 a@text",
       "pageCount": "#pagestats@text"},
      {"key": "3", "name": "都市小说", "isRank": false,
       "url": "http://www.81shuku.info/dushixiaoshuo/1_{{page}}.html", "cardList": "div.l li",
       "cardName": "span.s2 a@text", "cardAuthor": "span.s5@text",
       "cardBookUrl": "span.s2 a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg",
       "cardLastChapter": "span.s3 a@text",
       "pageCount": "#pagestats@text"},
      {"key": "4", "name": "穿越小说", "isRank": false,
       "url": "http://www.81shuku.info/chuanyuexiaoshuo/1_{{page}}.html", "cardList": "div.l li",
       "cardName": "span.s2 a@text", "cardAuthor": "span.s5@text",
       "cardBookUrl": "span.s2 a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg",
       "cardLastChapter": "span.s3 a@text",
       "pageCount": "#pagestats@text"},
      {"key": "5", "name": "网游小说", "isRank": false,
       "url": "http://www.81shuku.info/wangyouxiaoshuo/1_{{page}}.html", "cardList": "div.l li",
       "cardName": "span.s2 a@text", "cardAuthor": "span.s5@text",
       "cardBookUrl": "span.s2 a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg",
       "cardLastChapter": "span.s3 a@text",
       "pageCount": "#pagestats@text"},
      {"key": "6", "name": "科幻小说", "isRank": false,
       "url": "http://www.81shuku.info/kehuanxiaoshuo/1_{{page}}.html", "cardList": "div.l li",
       "cardName": "span.s2 a@text", "cardAuthor": "span.s5@text",
       "cardBookUrl": "span.s2 a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg",
       "cardLastChapter": "span.s3 a@text",
       "pageCount": "#pagestats@text"},
      {"key": "7", "name": "其他小说", "isRank": false,
       "url": "http://www.81shuku.info/qitaxiaoshuo/1_{{page}}.html", "cardList": "div.l li",
       "cardName": "span.s2 a@text", "cardAuthor": "span.s5@text",
       "cardBookUrl": "span.s2 a@href",
       "cardCoverPattern": "http://www.81shuku.info/files/article/image/{id1000}/{id}/{id}s.jpg",
       "cardLastChapter": "span.s3 a@text",
       "pageCount": "#pagestats@text"}
    ]
  }
]
''';

/// 书源仓库：内置源 + 用户导入源（全局单例，保证各页面状态一致）
class SourceRepository {
  static const _customKey = 'custom_sources';
  static const _disabledKey = 'disabled_sources';

  SourceRepository._() {
    _loadBuiltin();
    ready = _loadPersisted();
  }

  static final SourceRepository _instance = SourceRepository._();

  factory SourceRepository() => _instance;

  final List<BookSource> _sources = [];
  late final Future<void> ready;
  Future<void> _pendingImport = Future.value();

  /// 用户导入的自定义源 id（用于区分可删除 / 内置）
  final Set<String> _customIds = {};

  void _loadBuiltin() {
    try {
      final list = jsonDecode(builtinSourcesJson) as List<dynamic>;
      for (final item in list) {
        _sources.add(BookSource.fromJson(item as Map<String, dynamic>));
      }
    } catch (_) {
      // 内置源 JSON 出错不应导致崩溃
    }
  }

  /// 加载持久化的自定义源 + 启停状态（异步合并，不阻塞启动）
  Future<void> _loadPersisted() async {
    final sp = await SharedPreferences.getInstance();
    for (final c in sp.getStringList(_customKey) ?? const []) {
      try {
        final src = BookSource.fromJson(jsonDecode(c) as Map<String, dynamic>);
        if (src.id.isEmpty ||
            ![
              ContentType.novel,
              ContentType.comic,
              ContentType.video,
            ].contains(src.type)) {
          continue;
        }
        _sources.removeWhere((s) => s.id == src.id);
        _sources.add(src);
        _customIds.add(src.id);
      } catch (_) {}
    }
    for (final d in sp.getStringList(_disabledKey) ?? const []) {
      final idx = _sources.indexWhere((s) => s.id == d);
      if (idx != -1) {
        final s = _sources[idx];
        _sources[idx] = s.copyWith(enabled: false);
      }
    }
  }

  /// 当前暴露小说、漫画与视频书源。
  List<BookSource> get all => List.unmodifiable(_sources);

  /// 启用中的某类型书源
  List<BookSource> enabledOfType(ContentType type) =>
      _sources.where((s) => s.enabled && s.type == type).toList();

  /// 按 id 查找
  BookSource? byId(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 保留旧调用签名及覆盖行为；交互入口使用带报告、显式授权的接口。
  Future<int> importJson(String jsonText) async {
    final report = await importJsonWithReport(jsonText, overwrite: true);
    return report.added + report.overwritten;
  }

  Future<SourceImportReport> importJsonWithReport(
    String jsonText, {
    bool overwrite = false,
    Set<String> overwriteIds = const {},
  }) async {
    final previous = _pendingImport;
    final operation = () async {
      await previous;
      await ready;
      final entries = SourceImportAdapter.parse(jsonText);
      final sp = await SharedPreferences.getInstance();
      final merged = [...?sp.getStringList(_customKey)];
      final disabled = (sp.getStringList(_disabledKey) ?? const <String>[])
          .toSet();
      final accepted = <BookSource>[];
      final skipped = <String>[];
      final warnings = <String>[];
      var added = 0;
      var overwritten = 0;
      for (final entry in entries) {
        if (entry.json == null) {
          skipped.add('${entry.name}：${entry.reason}');
          continue;
        }
        final exists = byId(entry.id) != null;
        if (exists && !overwrite && !overwriteIds.contains(entry.id)) {
          skipped.add('${entry.name}：同 URL 书源已存在，未授权覆盖');
          continue;
        }
        final src = BookSource.fromJson(entry.json!);
        merged.removeWhere((text) {
          try {
            return (jsonDecode(text) as Map<String, dynamic>)['sourceUrl'] ==
                src.id;
          } catch (_) {
            return false;
          }
        });
        merged.add(jsonEncode(entry.json));
        if (src.enabled) {
          disabled.remove(src.id);
        } else {
          disabled.add(src.id);
        }
        accepted.add(src);
        if (exists) {
          overwritten++;
        } else {
          added++;
        }
        warnings.addAll(entry.warnings.map((w) => '${entry.name}：$w'));
      }
      if (accepted.isNotEmpty) {
        final oldDisabled = sp.getStringList(_disabledKey) ?? const <String>[];
        if (!await sp.setStringList(_disabledKey, disabled.toList())) {
          throw StateError('启停状态保存失败，未导入');
        }
        try {
          if (!await sp.setStringList(_customKey, merged)) {
            throw StateError('书源保存失败');
          }
        } catch (_) {
          await sp.setStringList(_disabledKey, oldDisabled);
          rethrow;
        }
        for (final src in accepted) {
          final index = _sources.indexWhere((s) => s.id == src.id);
          if (index < 0) {
            _sources.add(src);
          } else {
            _sources[index] = src;
          }
          _customIds.add(src.id);
        }
      }
      return SourceImportReport(
        added: added,
        overwritten: overwritten,
        skipped: skipped,
        warnings: warnings,
      );
    }();
    _pendingImport = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// 切换启用状态（持久化）
  Future<void> toggle(String id, bool enabled) async {
    await ready;
    await _pendingImport;
    final idx = _sources.indexWhere((s) => s.id == id);
    if (idx != -1) {
      final s = _sources[idx];
      _sources[idx] = s.copyWith(enabled: enabled);
    }
    final sp = await SharedPreferences.getInstance();
    final disabled = sp.getStringList(_disabledKey) ?? const [];
    final set = disabled.toSet();
    if (enabled) {
      set.remove(id);
    } else {
      set.add(id);
    }
    await sp.setStringList(_disabledKey, set.toList());
    if (_customIds.contains(id)) {
      final saved = sp.getStringList(_customKey) ?? const <String>[];
      await sp.setStringList(
        _customKey,
        saved.map((text) {
          final json = jsonDecode(text) as Map<String, dynamic>;
          if (json['sourceUrl'] == id) json['enabled'] = enabled;
          return jsonEncode(json);
        }).toList(),
      );
    }
  }

  /// 是否用户导入的自定义源
  bool isCustom(String id) => _customIds.contains(id);

  /// 删除自定义书源（内置源不可删）
  Future<void> removeCustom(String id) async {
    await ready;
    await _pendingImport;
    if (!_customIds.contains(id)) return;
    _sources.removeWhere((s) => s.id == id);
    _customIds.remove(id);
    final sp = await SharedPreferences.getInstance();
    final cur = sp.getStringList(_customKey) ?? const [];
    await sp.setStringList(
      _customKey,
      cur.where((e) {
        try {
          return (jsonDecode(e) as Map<String, dynamic>)['sourceUrl'] != id;
        } catch (_) {
          return true;
        }
      }).toList(),
    );
  }
}
