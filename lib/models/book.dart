import 'book_source.dart';

/// 一本书（可能来自某个书源的一次搜索结果）
class Book {
  final String name;
  final String author;
  final String cover;
  final String bookUrl; // 相对该书源站点的详情页链接
  final String sourceId; // 所属书源 id
  final String sourceName;
  final ContentType type;
  final String? lastChapter;
  final String? intro;

  const Book({
    required this.name,
    required this.author,
    required this.cover,
    required this.bookUrl,
    required this.sourceId,
    required this.sourceName,
    this.type = ContentType.novel,
    this.lastChapter,
    this.intro,
  });

  /// 聚合去重的归一化 key：书名 + 作者（去除空白）
  String get normalizeKey =>
      '${name.replaceAll(RegExp(r'\s+'), '')}|${author.replaceAll(RegExp(r'\s+'), '')}';

  Map<String, dynamic> toJson() => {
        'name': name,
        'author': author,
        'cover': cover,
        'bookUrl': bookUrl,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'type': type.name,
        'lastChapter': lastChapter,
        'intro': intro,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        name: json['name'] ?? '',
        author: json['author'] ?? '',
        cover: json['cover'] ?? '',
        bookUrl: json['bookUrl'] ?? '',
        sourceId: json['sourceId'] ?? '',
        sourceName: json['sourceName'] ?? '',
        type: ContentType.values.firstWhere(
          (t) => t.name == (json['type'] ?? 'novel'),
          orElse: () => ContentType.novel,
        ),
        lastChapter: json['lastChapter'],
        intro: json['intro'],
      );
}

/// 章节
class Chapter {
  final String title;
  final String url;

  const Chapter({required this.title, required this.url});
}
