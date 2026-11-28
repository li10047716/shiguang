/// 统一打开阅读器：按 book.type 分派到小说阅读器或漫画阅读器。
library;

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import 'comic_reader_page.dart';
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
  final Widget page;
  if (book.type == ContentType.video) {
    page = VideoReaderPage(
      book: book,
      chapters: chapters,
      initialIndex: initialIndex,
    );
  } else if (book.type == ContentType.comic) {
    page = ComicReaderPage(
      book: book,
      chapters: chapters,
      initialIndex: initialIndex,
    );
  } else {
    page = ReaderPage(
      book: book,
      chapters: chapters,
      initialIndex: initialIndex,
      chaptersProvider: chaptersProvider,
    );
  }
  final route = MaterialPageRoute(builder: (_) => page);
  final nav = Navigator.of(context);
  return replace ? nav.pushReplacement(route) : nav.push(route);
}
