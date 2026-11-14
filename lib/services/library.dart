/// 书架 / 阅读进度持久化（shared_preferences 简单实现）
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';

class LibraryService extends StateNotifier<List<Book>> {
  static const _shelfKey = 'shelf_books';
  static const _progressPrefix = 'progress_';
  static const _progressTitlePrefix = 'progress_title_';
  static const _progressTimePrefix = 'progress_time_';

  LibraryService() : super(const []);

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_shelfKey) ?? const [];
    state = raw
        .map((s) => Book.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<bool> addToShelf(Book book) async {
    if (state.any((b) => b.bookUrl == book.bookUrl)) return false;
    state = [...state, book];
    await _save();
    return true;
  }

  Future<void> removeFromShelf(Book book) async {
    state = state.where((b) => b.bookUrl != book.bookUrl).toList();
    await _save();
  }

  bool inShelf(Book book) => state.any((b) => b.bookUrl == book.bookUrl);

  /// 批量删除（书架管理）
  Future<void> removeMany(List<Book> books) async {
    final urls = books.map((b) => b.bookUrl).toSet();
    state = state.where((b) => !urls.contains(b.bookUrl)).toList();
    await _save();
  }

  /// 清空书架
  Future<void> clearShelf() async {
    state = const [];
    await _save();
  }

  /// 整表替换（书架管理排序后落盘新顺序）
  Future<void> replaceAll(List<Book> books) async {
    state = List.of(books);
    await _save();
  }

  /// 阅读进度：章节索引 + 已读章标题 + 最近阅读时间戳
  Future<void> saveProgress(Book book, int chapterIndex,
      {String? chapterTitle}) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('$_progressPrefix${book.bookUrl}', chapterIndex);
    if (chapterTitle != null) {
      await sp.setString(
          '$_progressTitlePrefix${book.bookUrl}', chapterTitle);
    }
    await sp.setInt(
        '$_progressTimePrefix${book.bookUrl}',
        DateTime.now().millisecondsSinceEpoch);
  }

  Future<int> readProgress(Book book) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt('$_progressPrefix${book.bookUrl}') ?? 0;
  }

  /// 最近阅读时间戳（毫秒），无记录返回 0
  Future<int> readProgressTime(Book book) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt('$_progressTimePrefix${book.bookUrl}') ?? 0;
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
        _shelfKey, state.map((b) => jsonEncode(b.toJson())).toList());
  }
}

final libraryProvider = StateNotifierProvider<LibraryService, List<Book>>(
    (ref) => LibraryService());
