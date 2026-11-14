/// 章节内容：小说正文（段落列表）或漫画内容（图片列表）。
///
/// 对应 shiguang 的 `{title, bookTitle, paras[]}`（小说）与
/// `{title, bookTitle, pages[]}`（漫画），用 [kind] 区分。
library;

import 'book_source.dart';

class Content {
  /// 章节标题
  final String title;

  /// 所属书名
  final String bookTitle;

  /// 小说正文段落（kind == novel 时非空）
  final List<String> paras;

  /// 漫画图片 URL 列表（kind == comic 时非空）
  final List<String> pages;

  /// 视频直链（kind == video 时非空，如 m3u8/mp4）
  final String video;

  /// 内容类型
  final ContentType kind;

  const Content({
    required this.title,
    this.bookTitle = '',
    this.paras = const [],
    this.pages = const [],
    this.video = '',
    this.kind = ContentType.novel,
  });

  /// 是否漫画
  bool get isComic => kind == ContentType.comic;

  /// 是否视频
  bool get isVideo => kind == ContentType.video;

  factory Content.fromJson(Map<String, dynamic> json) => Content(
        title: json['title'] as String? ?? '',
        bookTitle: json['bookTitle'] as String? ?? '',
        paras: (json['paras'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        pages: (json['pages'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        video: json['video'] as String? ?? '',
        kind: ContentType.values.firstWhere(
          (t) => t.name == (json['kind'] ?? 'novel'),
          orElse: () => ContentType.novel,
        ),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'bookTitle': bookTitle,
        'paras': paras,
        'pages': pages,
        'video': video,
        'kind': kind.name,
      };
}
