/// 全局下载管理页（章节缓存）。
///
/// 顶部「总进度」摘要卡 + 「正在下载 / 已缓存」双 Tab：
/// - 正在下载：实时显示下载任务的进度条，可取消；
/// - 已缓存：按书籍列出封面/书名/大小/来源，支持单本清除；
/// 点书籍卡片可打开该书的缓存面板（缓存全书/后续章节）。
/// 下载/取消统一走 [CacheDownload]，与阅读器、书详情页实时同步。
library;

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../services/cache_download.dart';
import '../../services/chapter_cache.dart';
import '../../services/toc_cache.dart';
import '../../sources/source_registry.dart';
import '../glass.dart';
import '../widgets/cache_sheet.dart';
import '../widgets/cover_image.dart';

const _blue = Color(0xFF3D8AF7);
const _red = Color(0xFFE5484D);

class CacheManagerPage extends StatefulWidget {
  const CacheManagerPage({super.key});

  @override
  State<CacheManagerPage> createState() => _CacheManagerPageState();
}

class _CacheManagerPageState extends State<CacheManagerPage> {
  List<CachedBook> _books = [];
  bool _loading = true;
  // 0 = 正在下载，1 = 已缓存；有活动任务时默认看下载，否则看已缓存
  int _tab = CacheDownload.instance.tasks.value.isNotEmpty ? 0 : 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final books = await ChapterCache.allBooks();
    if (!mounted) return;
    setState(() {
      _books = books;
      _loading = false;
    });
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<bool> _confirm(String title, String msg) async {
    return await showDialog<bool>(
          context: context,
          barrierColor: Colors.transparent,
          builder: (_) => FlatDialog(
            child: FlatCard(
              radius: 20,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Text(msg,
                      style:
                          TextStyle(fontSize: 14, color: Colors.grey.shade700)),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      const SizedBox(width: 8),
                      FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: _red),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确定')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;
  }

  void _tip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 打开某本书的缓存管理面板：优先读目录缓存，否则联网取目录，
  /// 拿到真实章节后传入面板，使「缓存全书/后续」在这些入口也可用。
  Future<void> _openSheet(CachedBook cb) async {
    final book = cb.book;
    if (book == null) {
      _tip('该书无元信息，请到书详情页管理缓存');
      return;
    }
    List<Chapter> chapters = const [];
    final cachedToc = await TocCache.read(book.bookUrl);
    if (cachedToc != null && cachedToc.chapters.isNotEmpty) {
      chapters = cachedToc.chapters;
    } else {
      final source = SourceRegistry().byId(book.sourceId);
      if (source != null) {
        try {
          final r = await source.loadToc(book);
          chapters = r.chapters;
          if (r.chapters.isNotEmpty) {
            await TocCache.write(book.bookUrl, r.chapters, partial: r.partial);
          }
        } catch (_) {}
      }
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CacheSheet(
        book: book,
        chapters: () => chapters,
        total: chapters.length,
        currentIndex:
            cb.cached.clamp(0, chapters.isEmpty ? 0 : chapters.length - 1),
      ),
    ).whenComplete(_load);
  }

  Future<void> _clearOne(CachedBook cb) async {
    final ok = await _confirm('清除缓存', '确定清除「${cb.name}」的 ${cb.cached} 章缓存？');
    if (!ok) return;
    final n = await ChapterCache.clearBook(cb.bookUrl);
    _tip('已清除 $n 章');
    _load();
  }

  // ---------- Tab ----------

  Widget _tabItem(String label, int count, int index) {
    final selected = _tab == index;
    final color = selected ? _blue : Colors.grey.shade600;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = index),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Text('$label ($count)',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color)),
            const SizedBox(height: 6),
            Container(
              height: 3,
              width: 36,
              decoration: BoxDecoration(
                color: selected ? _blue : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 卡片：已缓存 ----------

  Widget _cachedCard(CachedBook cb) {
    final b = cb.book;
    final progress =
        cb.total > 0 ? (cb.cached / cb.total).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FlatCard(
        radius: 14,
        padding: const EdgeInsets.all(12),
        child: InkWell(
          onTap: () => _openSheet(cb),
          borderRadius: BorderRadius.circular(14),
          child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: b != null && b.cover.isNotEmpty
                  ? CoverImage(b.cover,
                      sourceId: b.sourceId, width: 56, height: 76)
                  : Container(
                      width: 56,
                      height: 76,
                      color: Colors.grey.shade200,
                      alignment: Alignment.center,
                      child: Icon(Icons.menu_book,
                          size: 24, color: Colors.grey.shade400),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(cb.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF222222))),
                      ),
                      const SizedBox(width: 8),
                      Text(_fmt(cb.bytes),
                          style:
                              TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    b == null || b.sourceName.isEmpty
                        ? '${cb.cached} 章'
                        : '${b.sourceName} · ${cb.cached}${cb.total > 0 ? '/${cb.total}' : ''} 章',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  if (progress != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: Colors.grey.shade300,
                        valueColor: const AlwaysStoppedAnimation<Color>(_blue),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book,
                            size: 12, color: Colors.grey.shade600),
                        const SizedBox(width: 4),
                        Text('小说',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '清除缓存',
              icon: const Icon(Icons.delete_outline, color: _red),
              onPressed: () => _clearOne(cb),
            ),
          ],
        ),
        ),
      ),
    );
  }

  // ---------- 卡片：正在下载 ----------

  Widget _downloadingCard(DownloadTask t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FlatCard(
        radius: 14,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(t.bookName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF222222))),
                      ),
                      const SizedBox(width: 8),
                      Text('${(t.progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _blue)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: t.progress,
                      minHeight: 4,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: const AlwaysStoppedAnimation<Color>(_blue),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t.cancelled
                        ? '已取消'
                        : '${t.done}${t.failed > 0 ? '（失败 ${t.failed}）' : ''}/${t.total} 章',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '取消下载',
              icon: Icon(Icons.close, color: Colors.grey.shade600),
              onPressed: () => CacheDownload.instance.cancel(t.bookUrl),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(String msg, IconData icon) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ValueListenableBuilder<Map<String, DownloadTask>>(
      valueListenable: CacheDownload.instance.tasks,
      builder: (_, tasks, _) {
        final running = tasks.values.where((t) => t.running).toList();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _tabItem('正在下载', running.length, 0),
                  _tabItem('已缓存', _books.length, 1),
                ],
              ),
              Expanded(
                child: _tab == 0
                    ? (running.isEmpty
                        ? _empty('暂无下载任务', Icons.download_outlined)
                        : ListView(
                            padding: const EdgeInsets.only(top: 8),
                            children: [
                              for (final t in running) _downloadingCard(t),
                            ],
                          ))
                    : (_books.isEmpty
                        ? _empty('暂无离线缓存', Icons.download_for_offline_outlined)
                        : ListView(
                            padding: const EdgeInsets.only(top: 8),
                            children: [
                              for (final cb in _books) _cachedCard(cb),
                            ],
                          )),
              ),
            ],
          ),
        );
      },
    );
  }
}
