/// 统一打开小说阅读器 [ReaderPage]。
library;

import 'package:flutter/material.dart';

import '../../models/book.dart';
import 'reader_page.dart';

Future<void> openReader(
  BuildContext context,
  Book book,
  List<Chapter> chapters,
  int initialIndex, {
  List<Chapter> Function()? chaptersProvider,
  bool replace = false,
}) {
  final route = MaterialPageRoute(
    builder: (_) => ReaderPage(
      book: book,
      chapters: chapters,
      initialIndex: initialIndex,
      chaptersProvider: chaptersProvider,
    ),
  );
  final nav = Navigator.of(context);
  return replace ? nav.pushReplacement(route) : nav.push(route);
}
