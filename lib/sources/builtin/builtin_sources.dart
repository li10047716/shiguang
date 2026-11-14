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
    _loadPersisted();
  }

  static final SourceRepository _instance = SourceRepository._();

  factory SourceRepository() => _instance;

  final List<BookSource> _sources = [];

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
  void _loadPersisted() {
    SharedPreferences.getInstance().then((sp) {
      for (final c in sp.getStringList(_customKey) ?? const []) {
        try {
          final src = BookSource.fromJson(jsonDecode(c) as Map<String, dynamic>);
          if (src.id.isEmpty) continue;
          _sources.removeWhere((s) => s.id == src.id);
          _sources.add(src);
          _customIds.add(src.id);
        } catch (_) {}
      }
      for (final d in sp.getStringList(_disabledKey) ?? const []) {
        final idx = _sources.indexWhere((s) => s.id == d);
        if (idx != -1) {
          final s = _sources[idx];
          _sources[idx] = BookSource(
            id: s.id,
            name: s.name,
            baseUrl: s.baseUrl,
            type: s.type,
            enabled: false,
            search: s.search,
            detail: s.detail,
            toc: s.toc,
            content: s.content,
          );
        }
      }
    });
  }

  /// 全部书源
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

  /// 导入书源 JSON（支持数组或单个对象），持久化到 [ _customKey ]。
  Future<int> importJson(String jsonText) async {
    final decoded = jsonDecode(jsonText);
    final list = decoded is List ? decoded : [decoded];
    var count = 0;
    final saved = <Map<String, dynamic>>[];
    for (final raw in list) {
      try {
        final item = raw as Map<String, dynamic>;
        final src = BookSource.fromJson(item);
        if (src.id.isEmpty) continue;
        _sources.removeWhere((s) => s.id == src.id); // 覆盖同 id
        _sources.add(src);
        _customIds.add(src.id);
        saved.add(item);
        count++;
      } catch (_) {}
    }
    if (saved.isNotEmpty) {
      final sp = await SharedPreferences.getInstance();
      final cur = sp.getStringList(_customKey) ?? const [];
      final merged = [...cur];
      for (final s in saved) {
        final id = s['sourceUrl'];
        merged.removeWhere((e) {
          try {
            return (jsonDecode(e) as Map<String, dynamic>)['sourceUrl'] == id;
          } catch (_) {
            return false;
          }
        });
        merged.add(jsonEncode(s));
      }
      await sp.setStringList(_customKey, merged);
    }
    return count;
  }

  /// 切换启用状态（持久化）
  Future<void> toggle(String id, bool enabled) async {
    final idx = _sources.indexWhere((s) => s.id == id);
    if (idx != -1) {
      final s = _sources[idx];
      _sources[idx] = BookSource(
        id: s.id,
        name: s.name,
        baseUrl: s.baseUrl,
        type: s.type,
        enabled: enabled,
        search: s.search,
        detail: s.detail,
        toc: s.toc,
        content: s.content,
      );
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
  }

  /// 是否用户导入的自定义源
  bool isCustom(String id) => _customIds.contains(id);

  /// 删除自定义书源（内置源不可删）
  Future<void> removeCustom(String id) async {
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
        }).toList());
  }
}
