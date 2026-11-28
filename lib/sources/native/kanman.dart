/// 看漫网（kanman.com，小明太极旗下）漫画书源。
///
/// 全站书库 / 搜索 / 目录 / 图片页接口（2026-11 实测）：
///   - 书库 GET /api/getComicList/ → 全站漫画元数据 JSON（约 103 本）
///   - 搜索：站方在书库 JSON 上按 comic_name / PinYin_name 本地正则过滤，
///     本源沿用同样做法（无需额外搜索接口）。
///   - 详情/目录 GET /{comic_id}/ → 章节列表 #j_chapter_list li a
///   - 图片 GET /{comic_id}/{chapter_newid}.html → 内嵌 JS 数组
///     chapter_img_list:["https://hw-chapter2.kaimanhua.com/.../1.jpg?auth_key=...", ...]
///     auth_key 有时效，故章节页禁用缓存，每次重新解析拿最新签名。
///
/// 图片直链无需 Referer 即可下载（免防盗链）。
library;

import 'dart:convert';

import 'package:html/parser.dart' as parser;

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _site = 'https://www.kanman.com';
const String _apiList = '$_site/api/getComicList/';
const String _sourceId = 'kanman';
const String _sourceName = '看漫漫画';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

class KanmanSource extends SourceBase {
  @override
  String get sourceId => _sourceId;
  @override
  String get sourceName => _sourceName;
  @override
  ContentType get type => ContentType.comic;

  @override
  Map<String, String>? get imageHeaders => null; // 图片直链免 Referer

  // 书库缓存（进程内），命中后搜索/发现都复用
  static List<Map<String, dynamic>>? _library;
  static DateTime _libraryAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<List<Map<String, dynamic>>> _books() async {
    final now = DateTime.now();
    if (_library != null && now.difference(_libraryAt).inMinutes < 30) {
      return _library!;
    }
    final text = await HttpClient.getText(
      _apiList,
      headers: {'User-Agent': _ua, 'X-Requested-With': 'XMLHttpRequest'},
      maxBytes: 2 * 1024 * 1024,
    );
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json['status'] != 0) throw SourceException('看漫书库返回异常');
    final data = json['data'];
    if (data is! List) throw SourceException('看漫书库为空');
    final list = <Map<String, dynamic>>[];
    for (final item in data) {
      if (item is Map<String, dynamic>) list.add(item);
    }
    _library = list;
    _libraryAt = now;
    return list;
  }

  /// 书库元数据 → Book。bookUrl 存纯数字 comic_id，便于目录/图片页复用。
  Book _toBook(Map<String, dynamic> b) {
    final id = (b['comic_id'] ?? '').toString();
    final name = (b['comic_name'] ?? '').toString();
    return Book(
      name: name,
      author: (b['cartoon_author_list_name'] ?? '').toString(),
      cover: 'https://image.yqmh.com/mh/$id.jpg-300x400.jpg',
      bookUrl: id,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.comic,
      lastChapter: (b['latest_cartoon_topic_name'] ?? '').toString(),
      intro: (b['comic_feature'] ?? '').toString(),
    );
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return const [];
    final all = await _books();
    final matched = all.where((b) {
      final name = (b['comic_name'] ?? '').toString().toLowerCase();
      final py = (b['PinYin_name'] ?? '').toString().toLowerCase();
      return name.contains(kw) || py.contains(kw);
    }).toList();
    // 简单分页（站方每页 48）
    const size = 48;
    final start = (page - 1) * size;
    if (start >= matched.length) return const [];
    final end = (start + size).clamp(0, matched.length).toInt();
    return matched.sublist(start, end).map(_toBook).toList();
  }

  @override
  Future<Book> detail(Book book) async {
    // 从书库补全元数据（书库已含简介/封面/作者/最新章节）
    final all = await _books();
    for (final b in all) {
      if ((b['comic_id'] ?? '').toString() == book.bookUrl) {
        return _toBook(b);
      }
    }
    return book;
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final html = await HttpClient.getText(
      '$_site/${book.bookUrl}/',
      headers: {'User-Agent': _ua},
      maxBytes: 3 * 1024 * 1024,
    );
    final doc = parser.parse(html);
    final nodes = doc.querySelectorAll('#j_chapter_list li a');
    final chapters = <Chapter>[];
    for (final a in nodes) {
      var href = a.attributes['href'] ?? '';
      if (href.isEmpty) continue;
      if (href.startsWith('http')) {
        // 保留完整 URL（内部按 host 分段取 path）
      } else if (href.startsWith('/')) {
        href = '$_site$href';
      } else {
        href = '$_site/${book.bookUrl}/$href';
      }
      final title = (a.attributes['title'] ?? a.text).trim();
      if (title.isEmpty) continue;
      chapters.add(Chapter(title: title, url: href));
    }
    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    if (chapters.isEmpty) {
      throw SourceException('看漫目录为空，规则可能已失效');
    }
    return TocResult(chapters: chapters);
  }

  @override
  Future<Content> content(Chapter chapter) async {
    // 图片签名有时效：章节页禁用缓存，每次重新解析
    final html = await HttpClient.getText(
      chapter.url,
      headers: {'User-Agent': _ua},
      maxBytes: 3 * 1024 * 1024,
      useCache: false,
    );
    final urls = _parseImageList(html);
    if (urls.isEmpty) throw SourceException('未取到漫画图片（可能需登录或已下架）');
    final title = _parseChapterTitle(html) ?? chapter.title;
    final pages = urls
        .map((u) => ComicPage(url: u.startsWith('//') ? 'https:$u' : u))
        .toList();
    return Content(title: title, pages: pages);
  }

  /// 从章节页内嵌 JS 里解析 chapter_img_list:[...]
  static List<String> _parseImageList(String html) {
    final key = 'chapter_img_list:';
    final i = html.indexOf(key);
    if (i < 0) return const [];
    final start = html.indexOf('[', i + key.length);
    if (start < 0) return const [];
    // 找配对的 ]
    var depth = 0;
    var end = -1;
    var inStr = false;
    var esc = false;
    for (var j = start; j < html.length; j++) {
      final c = html[j];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == '\\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
        continue;
      }
      if (c == '"') {
        inStr = true;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) {
          end = j;
          break;
        }
      }
    }
    if (end < 0) return const [];
    final arrText = html.substring(start, end + 1);
    try {
      final decoded = jsonDecode(arrText) as List<dynamic>;
      return decoded.map((e) => e.toString()).where((u) => u.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  static String? _parseChapterTitle(String html) {
    final m = RegExp(r'chapter_name:"([^"]*)"').firstMatch(html);
    return m?.group(1);
  }

  // ---------- 发现页 ----------
  // 把书库按分类标签展开成发现 tab，复用搜索的分页逻辑。

  @override
  List<DiscoverTab> get discoverTabs => const [
        DiscoverTab(key: '', name: '热门', isRank: true),
        DiscoverTab(key: 'lianzai', name: '连载', isRank: false),
        DiscoverTab(key: 'wanjie', name: '完结', isRank: false),
        DiscoverTab(key: 'maoxian', name: '冒险', isRank: false),
        DiscoverTab(key: 'shenmo', name: '神魔', isRank: false),
        DiscoverTab(key: 'aiqing', name: '恋爱', isRank: false),
      ];

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    final all = await _books();
    final filtered = all.where((b) {
      if (isRank) return true; // 热门 = 全库按人气
      final tags = (b['cartoon_type_list_name'] ?? '').toString();
      return tags.contains(key);
    }).toList();

    if (isRank) {
      // 按人气排序
      filtered.sort((a, b) {
        final ra = int.tryParse(a['renqi']?.toString() ?? '') ?? 0;
        final rb = int.tryParse(b['renqi']?.toString() ?? '') ?? 0;
        return rb.compareTo(ra);
      });
    }

    const size = 24;
    final start = (page - 1) * size;
    final pages = (filtered.length / size).ceil();
    if (start >= filtered.length) {
      return DiscoverResult(title: isRank ? '热门' : key, books: const [], page: page, pages: pages);
    }
    final end = (start + size).clamp(0, filtered.length).toInt();
    final books = filtered.sublist(start, end).map(_toBook).toList();
    return DiscoverResult(
      title: isRank ? '热门' : key,
      books: books,
      page: page,
      pages: pages == 0 ? 1 : pages,
    );
  }
}
