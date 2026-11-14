/// 按书籍类型打开对应阅读器。
///
/// 小说/漫画 → [ReaderPage]，视频 → [VideoReaderPage]。
/// 各入口（书架卡片、目录页、详情页「开始阅读」）统一走这里，避免漏接视频。
library;

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import 'reader_page.dart';
import 'video_reader_page.dart';

Future<void> openReader(
  BuildContext context,
  Book book,
  List<Chapter> chapters,
  int initialIndex, {
  List<Chapter> Function()? chaptersProvider,
  bool replace = false,
}) {
  final route = MaterialPageRoute(
    builder: (_) => book.type == ContentType.video
        ? VideoReaderPage(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex,
          )
        : ReaderPage(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex,
            chaptersProvider: chaptersProvider,
          ),
  );
  final nav = Navigator.of(context);
  return replace ? nav.pushReplacement(route) : nav.push(route);
}
