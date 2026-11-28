/// 章节内容：小说文字段落，或漫画图片页。
library;

/// 漫画的一页图片（URL 可能带时效签名，每次打开章节重新解析）。
class ComicPage {
  final String url;
  final int? width;
  final int? height;

  const ComicPage({required this.url, this.width, this.height});

  factory ComicPage.fromJson(Map<String, dynamic> json) => ComicPage(
        url: json['url'] as String? ?? '',
        width: json['width'] as int?,
        height: json['height'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };
}

class Content {
  /// 章节标题
  final String title;

  /// 所属书名
  final String bookTitle;

  /// 小说正文段落
  final List<String> paras;

  /// 漫画图片页（非空时按漫画渲染，与 paras 互斥）
  final List<ComicPage> pages;

  const Content({
    required this.title,
    this.bookTitle = '',
    this.paras = const [],
    this.pages = const [],
  });

  /// 是否漫画内容
  bool get isComic => pages.isNotEmpty;

  factory Content.fromJson(Map<String, dynamic> json) => Content(
        title: json['title'] as String? ?? '',
        bookTitle: json['bookTitle'] as String? ?? '',
        paras: (json['paras'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        pages: (json['pages'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((e) => ComicPage.fromJson(e))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'bookTitle': bookTitle,
        'paras': paras,
        if (pages.isNotEmpty) 'pages': pages.map((p) => p.toJson()).toList(),
      };
}
