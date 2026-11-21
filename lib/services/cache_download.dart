/// 统一章节缓存下载中心。
///
/// 阅读器顶栏、书详情页、全局缓存管理页共用这里的下载任务，
/// 支持进度上报与中途取消——解决原先「阅读器缓存不能取消、两套逻辑不一致」。
library;

import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../sources/source.dart';
import 'chapter_cache.dart';

/// 一个下载任务的状态
class DownloadTask {
  final String bookUrl;
  final String bookName;
  final int total;
  int done;
  int failed;
  bool cancelled;

  DownloadTask({
    required this.bookUrl,
    required this.bookName,
    required this.total,
    this.done = 0,
    this.failed = 0,
    this.cancelled = false,
  });

  bool get running => done < total && !cancelled;
  double get progress => total == 0 ? 0 : done / total;
}

/// 下载中心（单例 + ValueNotifier，UI 可监听进度）
class CacheDownload {
  CacheDownload._();

  static final CacheDownload instance = CacheDownload._();

  /// 进行中的任务（bookUrl -> 任务）。完成后即移除。
  final ValueNotifier<Map<String, DownloadTask>> tasks =
      ValueNotifier<Map<String, DownloadTask>>({});

  final Map<String, bool> _cancels = {};
  final Set<String> _running = {};

  bool isRunning(String bookUrl) => _running.contains(bookUrl);
  DownloadTask? taskOf(String bookUrl) => tasks.value[bookUrl];

  /// 取消某本书的下载（下一章循环前生效）
  void cancel(String bookUrl) {
    if (_running.contains(bookUrl)) _cancels[bookUrl] = true;
  }

  void cancelAll() {
    for (final url in _running) {
      _cancels[url] = true;
    }
  }

  /// 启动下载：从 [fromIndex] 起逐章取正文写盘。
  ///
  /// [onDone] 在完成/取消后回调（result: 成功章数, 失败章数, 是否取消）。
  Future<void> start({
    required Book book,
    required NovelSource source,
    required List<Chapter> chapters,
    int fromIndex = 0,
    void Function(int done, int failed, bool cancelled)? onDone,
  }) async {
    if (_running.contains(book.bookUrl)) return;
    final slice = chapters.skip(fromIndex).toList();
    if (slice.isEmpty) return;

    _running.add(book.bookUrl);
    _cancels[book.bookUrl] = false;
    final task = DownloadTask(
      bookUrl: book.bookUrl,
      bookName: book.name,
      total: slice.length,
    );
    _put(task);
    await ChapterCache.saveBookMeta(book, chapters.length);

    var done = 0;
    var failed = 0;
    for (var i = 0; i < slice.length; i++) {
      if (_cancels[book.bookUrl] == true) break;
      final ch = slice[i];
      try {
        final c = await source.content(ch);
        await ChapterCache.write(
          book.bookUrl,
          ch.url,
          c,
          title: ch.title,
          order: fromIndex + i,
        );
      } catch (_) {
        failed++;
      }
      done++;
      task.done = done;
      task.failed = failed;
      _put(task);
    }

    final cancelled = _cancels[book.bookUrl] == true;
    task.cancelled = cancelled;
    _remove(book.bookUrl);
    _running.remove(book.bookUrl);
    _cancels.remove(book.bookUrl);
    await ChapterCache.touchMeta(book.bookUrl);
    onDone?.call(done, failed, cancelled);
  }

  void _put(DownloadTask t) {
    final m = Map<String, DownloadTask>.from(tasks.value);
    m[t.bookUrl] = t;
    tasks.value = m;
  }

  void _remove(String bookUrl) {
    final m = Map<String, DownloadTask>.from(tasks.value);
    m.remove(bookUrl);
    tasks.value = m;
  }
}
