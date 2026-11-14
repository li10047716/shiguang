/// 书签与划线笔记的本地存储。
///
/// - 书签：某本书的某一章（可在阅读器里快速打/取消，我的页列出并跳转）。
/// - 笔记：选中正文某段文字 + 备注（我的页列出并管理）。
/// 均存于 SharedPreferences（JSON 数组）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';

/// 书签：定位到某本书的某一章。
class Bookmark {
  final Book book;
  final int chapterIndex;
  final String chapterTitle;
  final DateTime time;

  const Bookmark({
    required this.book,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'time': time.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
        book: Book.fromJson(j['book'] as Map<String, dynamic>? ?? {}),
        chapterIndex: (j['chapterIndex'] as num?)?.toInt() ?? 0,
        chapterTitle: j['chapterTitle'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 划线笔记：选中一段正文 + 备注。
class HighlightNote {
  final String id;
  final Book book;
  final int chapterIndex;
  final String chapterTitle;
  final String text;
  final String note;
  final DateTime time;

  const HighlightNote({
    required this.id,
    required this.book,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.text,
    required this.note,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'book': book.toJson(),
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'text': text,
        'note': note,
        'time': time.toIso8601String(),
      };

  factory HighlightNote.fromJson(Map<String, dynamic> j) => HighlightNote(
        id: j['id'] as String? ?? '',
        book: Book.fromJson(j['book'] as Map<String, dynamic>? ?? {}),
        chapterIndex: (j['chapterIndex'] as num?)?.toInt() ?? 0,
        chapterTitle: j['chapterTitle'] as String? ?? '',
        text: j['text'] as String? ?? '',
        note: j['note'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 书签与笔记的读写（SharedPreferences）。
class MarksService {
  static const _bookmarksKey = 'marks_bookmarks';
  static const _notesKey = 'marks_notes';

  // ---------- 书签 ----------

  static Future<List<Bookmark>> getBookmarks() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_bookmarksKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.time.compareTo(a.time));
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<bool> isBookmarked(String bookUrl, int chapterIndex) async {
    final list = await getBookmarks();
    return list.any(
        (b) => b.book.bookUrl == bookUrl && b.chapterIndex == chapterIndex);
  }

  static Future<void> toggleBookmark(Bookmark bm) async {
    final list = await getBookmarks();
    final idx = list.indexWhere((b) =>
        b.book.bookUrl == bm.book.bookUrl && b.chapterIndex == bm.chapterIndex);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, bm);
    }
    await _saveBookmarks(list);
  }

  static Future<void> removeBookmark(String bookUrl, int chapterIndex) async {
    final list = await getBookmarks();
    list.removeWhere((b) =>
        b.book.bookUrl == bookUrl && b.chapterIndex == chapterIndex);
    await _saveBookmarks(list);
  }

  static Future<void> _saveBookmarks(List<Bookmark> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _bookmarksKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  // ---------- 笔记 ----------

  static Future<List<HighlightNote>> getNotes() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_notesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => HighlightNote.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.time.compareTo(a.time));
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> addNote(HighlightNote note) async {
    final list = await getNotes();
    list.insert(0, note);
    await _saveNotes(list);
  }

  static Future<void> removeNote(String id) async {
    final list = await getNotes();
    list.removeWhere((n) => n.id == id);
    await _saveNotes(list);
  }

  static Future<void> _saveNotes(List<HighlightNote> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _notesKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }
}
