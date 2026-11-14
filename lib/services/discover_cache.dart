/// 发现页结果磁盘缓存（SharedPreferences，JSON）。
///
/// 书源榜单/分类数据变化不快，缓存 30 分钟内直接秒开，
/// 避免每次进入发现页/切回书源都重新拉取。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';

class DiscoverCache {
  static const Duration ttl = Duration(minutes: 30);
  static const String _prefix = 'disc_cache_';

  /// 保存某 (书源|标签) 已加载的发现结果。
  static Future<void> save(
    String key,
    List<Book> books,
    int pages,
    int loadedPage,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_prefix$key',
        jsonEncode({
          'books': books.map((b) => b.toJson()).toList(),
          'pages': pages,
          'loaded': loadedPage,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {
      // 磁盘写入失败不影响正常流程
    }
  }

  /// 读取缓存的发现结果；过期或不存在返回 null。
  static Future<(List<Book>, int, int)?> load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$key');
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final ts = m['ts'] as int;
      if (DateTime.now().millisecondsSinceEpoch - ts > ttl.inMilliseconds) {
        return null; // 过期
      }
      final books = (m['books'] as List)
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .toList();
      return (books, m['pages'] as int, m['loaded'] as int);
    } catch (_) {
      return null;
    }
  }

  /// 清除某 key 的缓存（刷新时调用）。
  static Future<void> clear(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$key');
    } catch (_) {}
  }
}
