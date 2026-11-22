/// 书架更新检查服务：与页面状态解耦，供书架下拉刷新和 App 生命周期定时检查共用。
///
/// 规则：逐本小说拉目录对比章节数；首次记录基线，之后章节数增多算有更新。
/// 本地书 / 无目录来源跳过。检查过程中可通过回调驱动 UI 的逐书转圈。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/book_source.dart';
import '../sources/source_registry.dart';
import 'cache_download.dart';

class UpdateChecker {
  UpdateChecker._();

  static const _shelfKey = 'shelf_books';
  static const _countPrefix = 'update_count_';
  /// 单本书的更新开关：值为 false 表示关闭该书自动检查；缺省视为开启。
  static const _autoPrefix = 'auto_update_';
  /// 单本书的自动下载开关：值为 true 表示发现新章节后自动缓存。
  static const _autoDownloadPrefix = 'auto_download_';

  /// 检查书架小说，返回有更新的本数。
  /// [books] 为 null 时读取书架全部小说；传入时按给定顺序检查。
  /// [onBookStart]/[onBookEnd] 分别在每本书检查前后回调（传 bookUrl）。
  static Future<int> check({
    List<Book>? books,
    void Function(String bookUrl)? onBookStart,
    void Function(String bookUrl)? onBookEnd,
  }) async {
    final sp = await SharedPreferences.getInstance();
    final target = books ?? _loadBooks(sp);
    var updated = 0;
    for (final b in target) {
      if (b.type != ContentType.novel) continue;
      // 单本书关闭了更新开关则跳过（默认开启，只有显式 false 才跳过）
      if (sp.getBool('$_autoPrefix${b.bookUrl}') == false) continue;
      final source = SourceRegistry().byId(b.sourceId);
      if (source == null) continue;

      onBookStart?.call(b.bookUrl);
      try {
        final toc = await source.loadToc(b).timeout(const Duration(seconds: 15));
        final newCount = toc.chapters.length;
        final oldCount = sp.getInt('$_countPrefix${b.bookUrl}');
        if (oldCount != null && newCount > oldCount) {
          updated++;
          // 自动下载：发现新章节且开关开启时，后台缓存新增章节（不阻塞检查流程）
          if (sp.getBool('$_autoDownloadPrefix${b.bookUrl}') == true) {
            unawaited(CacheDownload.instance.start(
              book: b,
              source: source,
              chapters: toc.chapters,
              fromIndex: oldCount,
            ));
          }
        }
        await sp.setInt('$_countPrefix${b.bookUrl}', newCount);
      } catch (_) {
      } finally {
        onBookEnd?.call(b.bookUrl);
      }
    }
    return updated;
  }

  static List<Book> _loadBooks(SharedPreferences sp) {
    final raw = sp.getStringList(_shelfKey) ?? const [];
    return raw
        .map((s) {
          try {
            return Book.fromJson(jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<Book>()
        .toList();
  }
}
