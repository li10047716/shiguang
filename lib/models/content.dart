/// 小说章节内容。
library;

class Content {
  /// 章节标题
  final String title;

  /// 所属书名
  final String bookTitle;

  /// 小说正文段落
  final List<String> paras;

  const Content({
    required this.title,
    this.bookTitle = '',
    this.paras = const [],
  });

  factory Content.fromJson(Map<String, dynamic> json) => Content(
        title: json['title'] as String? ?? '',
        bookTitle: json['bookTitle'] as String? ?? '',
        paras: (json['paras'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'bookTitle': bookTitle,
        'paras': paras,
      };
}
