/// 目录本地缓存
///
/// 目录一次要抓多页（部分站点 4800+ 章、5 页），缓存后再次进入秒开，
/// 也作为网络失败时的兜底数据。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';

class TocCacheEntry {
  final List<Chapter> chapters;
  final DateTime savedAt;
  final bool partial; // 是否为部分目录（有的页没抓到）

  const TocCacheEntry({
    required this.chapters,
    required this.savedAt,
    this.partial = false,
  });

  bool get isStale =>
      DateTime.now().difference(savedAt) > const Duration(days: 3);

  /// 缓存是否足够新（新到无需后台刷新，直接可用）
  bool get isFresh =>
      DateTime.now().difference(savedAt) < const Duration(minutes: 30);
}

class TocCache {
  static const _prefix = 'toc_cache_';
  static const _maxChapters = 20000; // 防御性上限

  /// FNV-1a 稳定哈希（Dart 的 String.hashCode 不保证跨版本一致）
  static String _key(String bookUrl) {
    var hash = 0x811c9dc5;
    for (final c in utf8.encode(bookUrl)) {
      hash ^= c;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '$_prefix${hash.toRadixString(16)}';
  }

  static Future<TocCacheEntry?> read(String bookUrl) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key(bookUrl));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map['chapters'] as List<dynamic>)
          .map((e) => Chapter(
                title: (e as Map<String, dynamic>)['t'] as String? ?? '',
                url: e['u'] as String? ?? '',
              ))
          .where((c) => c.url.isNotEmpty)
          .toList();
      if (list.isEmpty) return null;
      return TocCacheEntry(
        chapters: list,
        savedAt: DateTime.fromMillisecondsSinceEpoch(map['ts'] as int? ?? 0),
        partial: map['partial'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(
    String bookUrl,
    List<Chapter> chapters, {
    bool partial = false,
  }) async {
    if (chapters.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    final data = chapters
        .take(_maxChapters)
        .map((c) => {'t': c.title, 'u': c.url})
        .toList();
    await sp.setString(
      _key(bookUrl),
      jsonEncode({
        'ts': DateTime.now().millisecondsSinceEpoch,
        'partial': partial,
        'chapters': data,
      }),
    );
  }

  static Future<void> clear(String bookUrl) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key(bookUrl));
  }
}
