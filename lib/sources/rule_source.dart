/// 规则引擎书源实现：把 JSON 规则书源（[BookSource]）包装成统一接口。
///
/// 硬编码书源（native/ 下的 Dart 模块）与规则源对前端无差别。
library;

import '../models/book.dart';
import '../models/book_source.dart';
import '../models/content.dart';
import '../models/discover.dart';
import 'novel_source.dart';
import 'source.dart';

class RuleSource extends SourceBase {
  final NovelSourceExecutor _executor;
  final BookSource _source;

  RuleSource(this._source) : _executor = NovelSourceExecutor(_source);

  @override
  String get sourceId => _source.id;

  @override
  String get sourceName => _source.name;

  @override
  ContentType get type => _source.type;

  @override
  Map<String, String>? get imageHeaders =>
      {'Referer': '${_source.baseUrl}/'};

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) =>
      _executor.search(keyword, page: page);

  @override
  Future<Book> detail(Book book) => _executor.detail(book);

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) =>
      _executor.loadToc(
        book,
        onProgress: onProgress,
        onPageChunk: onPageChunk,
      );

  @override
  Future<Content> content(Chapter chapter) async {
    final text = await _executor.content(chapter);
    // 规则源正文是 `<p>`/`<br>` 转成 `\n` 分隔的纯文本，按行拆成段落
    // （原来整章塞一段，翻页/首行缩进错乱）。
    final paras = text
        .split('\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return Content(
      title: chapter.title,
      paras: paras.isEmpty ? [text] : paras,
      kind: _source.type,
    );
  }

  @override
  List<DiscoverTab> get discoverTabs => _source.discover
      .map((t) => DiscoverTab(key: t.key, name: t.name, isRank: t.isRank))
      .toList();

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    final tab = _source.discover
        .where((t) => t.key == key && t.isRank == isRank)
        .firstOrNull;
    if (tab == null) throw SourceException('$sourceName无「$key」发现标签');
    return _executor.discover(tab, page);
  }
}
