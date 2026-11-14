/// 内容类型：小说 / 漫画 / 视频
enum ContentType { novel, comic, video }

/// 书源规则模型（类 Legado 的 JSON 规则书源）
class BookSource {
  final String id; // 唯一标识（取 sourceUrl）
  final String name;
  final String baseUrl;
  final ContentType type;
  final bool enabled;
  final SearchRule search;
  final DetailRule detail;
  final TocRule? toc;
  final ContentRule? content;

  /// 发现页标签（榜单/分类）。为空 = 不支持发现。
  final List<DiscoverTabRule> discover;

  const BookSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.type,
    this.enabled = true,
    required this.search,
    required this.detail,
    this.toc,
    this.content,
    this.discover = const [],
  });

  factory BookSource.fromJson(Map<String, dynamic> json) {
    final url = json['sourceUrl'] as String? ?? '';
    return BookSource(
      id: url,
      name: json['sourceName'] as String? ?? url,
      baseUrl: url,
      type: ContentType.values.firstWhere(
        (t) => t.name == (json['sourceType'] ?? 'novel'),
        orElse: () => ContentType.novel,
      ),
      enabled: json['enabled'] as bool? ?? true,
      search: SearchRule.fromJson(
        (json['search'] as Map<String, dynamic>?) ?? {},
      ),
      detail: DetailRule.fromJson(
        (json['detail'] as Map<String, dynamic>?) ?? {},
      ),
      toc: json['toc'] == null
          ? null
          : TocRule.fromJson(json['toc'] as Map<String, dynamic>),
      content: json['content'] == null
          ? null
          : ContentRule.fromJson(json['content'] as Map<String, dynamic>),
      discover: (json['discover'] as List<dynamic>? ?? [])
          .map((e) => DiscoverTabRule.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 发现页单个标签（榜单或分类）规则。
///
/// 卡片选择器留空时回退到搜索规则（[SearchRule]），
/// 因为多数站点榜单/分类页与搜索页卡片结构一致。
class DiscoverTabRule {
  final String key; // 唯一键（榜单 kind 或分类 id）
  final String name; // 标签显示名
  final bool isRank; // true=榜单，false=分类
  final String url; // 抓取地址，`{{page}}` 会被替换成页码
  final String? cardList; // 卡片列表选择器
  final String? cardName;
  final String? cardAuthor;
  final String? cardCover;
  final String? cardBookUrl;
  final String? cardLastChapter;

  /// 封面构造模板（榜单页无封面元素时，从书 URL 提取 id 拼封面）。
  ///
  /// 占位符：`{id}` = 书 URL 最后一段数字（如 `/book/1839/` → 1839），
  /// `{id1000}` = id ~/ 1000（多数站点封面按 `images/<id~/1000>/<id>/<id>s.jpg`
  /// 存目录）。当 [cardCover] 提取为空时用于构造封面。
  final String? cardCoverPattern;

  /// 总页数文本选择器（如 `#pagestats@text` → "1/50"）。
  final String? pageCount;

  /// 分页链接选择器（收集所有链接，从 href 取最大页码）。
  final String? pageLinks;

  const DiscoverTabRule({
    required this.key,
    required this.name,
    required this.isRank,
    required this.url,
    this.cardList,
    this.cardName,
    this.cardAuthor,
    this.cardCover,
    this.cardBookUrl,
    this.cardLastChapter,
    this.cardCoverPattern,
    this.pageCount,
    this.pageLinks,
  });

  factory DiscoverTabRule.fromJson(Map<String, dynamic> j) => DiscoverTabRule(
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        isRank: j['isRank'] as bool? ?? false,
        url: j['url'] as String? ?? '',
        cardList: j['cardList'] as String?,
        cardName: j['cardName'] as String?,
        cardAuthor: j['cardAuthor'] as String?,
        cardCover: j['cardCover'] as String?,
        cardBookUrl: j['cardBookUrl'] as String?,
        cardLastChapter: j['cardLastChapter'] as String?,
        cardCoverPattern: j['cardCoverPattern'] as String?,
        pageCount: j['pageCount'] as String?,
        pageLinks: j['pageLinks'] as String?,
      );
}

/// 搜索规则
class SearchRule {
  final String urlTemplate; // 支持 {{key}} {{page}}
  final String method; // GET / POST
  final String charset; // 网页编码（默认 utf-8，GBK 站点需指定）
  final String bookList; // 书籍列表选择器
  final String name;
  final String author;
  final String cover;
  final String bookUrl;
  final String? lastChapter;

  const SearchRule({
    required this.urlTemplate,
    this.method = 'GET',
    this.charset = 'utf-8',
    required this.bookList,
    required this.name,
    required this.author,
    required this.cover,
    required this.bookUrl,
    this.lastChapter,
  });

  factory SearchRule.fromJson(Map<String, dynamic> json) => SearchRule(
        urlTemplate: json['url'] as String? ?? '',
        method: (json['method'] as String? ?? 'GET').toUpperCase(),
        charset: json['charset'] as String? ?? 'utf-8',
        bookList: json['bookList'] as String? ?? '',
        name: json['name'] as String? ?? '',
        author: json['author'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        bookUrl: json['bookUrl'] as String? ?? '',
        lastChapter: json['lastChapter'] as String?,
      );
}

/// 详情规则
class DetailRule {
  final String name;
  final String author;
  final String cover;
  final String intro;
  final String tocUrl; // 留空则用 bookUrl 本身
  final String lastChapter;

  const DetailRule({
    this.name = '',
    this.author = '',
    this.cover = '',
    this.intro = '',
    this.tocUrl = '',
    this.lastChapter = '',
  });

  factory DetailRule.fromJson(Map<String, dynamic> json) => DetailRule(
        name: json['name'] as String? ?? '',
        author: json['author'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        intro: json['intro'] as String? ?? '',
        tocUrl: json['tocUrl'] as String? ?? '',
        lastChapter: json['lastChapter'] as String? ?? '',
      );
}

/// 目录规则
class TocRule {
  final String chapterList;
  final String chapterName;
  final String chapterUrl;

  /// 翻页链接规则：从当前页提取「下一页」链接。
  /// 有些站点（如杰奇 CMS）第二页之后不再输出分页区，
  /// 此时用 [pageUrlTemplate] 兜底。
  final String? nextTocUrl;

  /// 页码模板，`{{page}}` 会被替换成页码，`{{bookUrl}}` 为书籍目录页地址。
  /// 例：`{{bookUrl}}{{page}}` → https://site/1670/2
  final String? pageUrlTemplate;

  /// 总页数来源（取文本后用 `1/5`、`共 5 页` 解析）。
  /// 有总页数时才能并发抓取后续页，如速读谷填 `#pages@text`
  final String? pageCount;

  const TocRule({
    required this.chapterList,
    required this.chapterName,
    required this.chapterUrl,
    this.nextTocUrl,
    this.pageUrlTemplate,
    this.pageCount,
  });

  factory TocRule.fromJson(Map<String, dynamic> json) => TocRule(
        chapterList: json['chapterList'] as String? ?? '',
        chapterName: json['chapterName'] as String? ?? 'a@text',
        chapterUrl: json['chapterUrl'] as String? ?? 'a@href',
        nextTocUrl: json['nextTocUrl'] as String?,
        pageUrlTemplate: json['pageUrlTemplate'] as String?,
        pageCount: json['pageCount'] as String?,
      );
}

/// 正文规则
class ContentRule {
  final String content; // 正文选择器（html 会保留 <br> 换行）
  final String? nextContentUrl; // 下一页正文（章内分页）
  final bool mergePages; // 是否自动合并后续页

  const ContentRule({
    required this.content,
    this.nextContentUrl,
    this.mergePages = true,
  });

  factory ContentRule.fromJson(Map<String, dynamic> json) => ContentRule(
        content: json['content'] as String? ?? '',
        nextContentUrl: json['nextContentUrl'] as String?,
        mergePages: json['mergePages'] as bool? ?? true,
      );
}
