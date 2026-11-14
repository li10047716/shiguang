/// 书籍详情页：封面、简介、加入书架、开始阅读（→ 目录）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../services/chapter_cache.dart';
import '../../services/library.dart';
import '../../services/toc_cache.dart';
import '../../sources/source_registry.dart';
import '../glass.dart';
import '../reader/open_reader.dart';
import '../widgets/cover_image.dart';
import 'toc_page.dart';

class BookDetailPage extends StatefulWidget {
  final Book book;
  const BookDetailPage({super.key, required this.book});

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  late Future<Book> _detailFuture;
  Book? _full;
  int _cachedCount = 0; // 已离线缓存的章节数

  @override
  void initState() {
    super.initState();
    _detailFuture = _load();
    ChapterCache.bookCount(widget.book.bookUrl).then((n) {
      if (mounted) setState(() => _cachedCount = n);
    });
  }

  Future<Book> _load() async {
    final source = SourceRegistry().byId(widget.book.sourceId);
    if (source == null) return widget.book;
    try {
      final full = await source.detail(widget.book);
      _full = full;
      return full;
    } catch (_) {
      return widget.book; // 详情抓取失败时退回搜索结果
    }
  }

  /// 换源：搜索同名书，切换其它书源版本。
  Future<void> _switchSource(Book b) async {
    final sources = SourceRegistry()
        .enabled
        .where((s) => s.sourceId != b.sourceId)
        .toList();
    final results = <Book>[];
    var searching = true;
    var kicked = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          if (!kicked) {
            kicked = true;
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              await Future.wait(sources.map((s) async {
                try {
                  final books = await s
                      .search(b.name)
                      .timeout(const Duration(seconds: 10));
                  for (final x in books) {
                    if (x.name.contains(b.name) ||
                        b.name.contains(x.name)) {
                      results.add(x);
                    }
                  }
                } catch (_) {}
              }));
              if (sheetCtx.mounted) {
                setSheet(() => searching = false);
              }
            });
          }

          return Glass(
            radius: 24,
            blur: 18,
            child: SizedBox(
            height: MediaQuery.of(sheetCtx).size.height * 0.6,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.swap_horiz,
                          color: Color(0xFF3E8EF7)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '换源 · ${b.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text('${results.length} 个',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                Expanded(
                  child: searching
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(
                                '正在搜索其他 ${sources.length} 个书源…',
                                style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 13),
                              ),
                            ],
                          ),
                        )
                      : results.isEmpty
                          ? const Center(child: Text('其他书源没找到同名书'))
                          : ListView.builder(
                              itemCount: results.length,
                              itemBuilder: (context, i) {
                                final x = results[i];
                                return ListTile(
                                  dense: true,
                                  leading: x.cover.isEmpty
                                      ? const Icon(Icons.menu_book)
                                      : CoverImage(
                                          x.cover,
                                          sourceId: x.sourceId,
                                          width: 32,
                                          height: 42,
                                        ),
                                  title: Text(x.sourceName,
                                      style:
                                          const TextStyle(fontSize: 14)),
                                  subtitle: Text(
                                    x.author.isEmpty ? '佚名' : x.author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: const Icon(Icons.chevron_right,
                                      size: 18),
                                  onTap: () {
                                    Navigator.of(sheetCtx).pop();
                                    Navigator.of(context)
                                        .pushReplacement(MaterialPageRoute(
                                      builder: (_) => BookDetailPage(book: x),
                                    ));
                                  },
                                );
                              },
                            ),
                ),
              ],
            ),
            ),
          );
        },
      ),
    );
  }

  /// 取目录（缓存优先，否则网络），失败返回 null
  Future<List<Chapter>?> _loadChapters(Book b) async {
    final source = SourceRegistry().byId(b.sourceId);
    if (source == null) return null;
    try {
      final cached = await TocCache.read(b.bookUrl);
      if (cached != null && cached.chapters.isNotEmpty) {
        return cached.chapters;
      }
      final r = await source.loadToc(b);
      if (r.chapters.isEmpty) return null;
      await TocCache.write(b.bookUrl, r.chapters, partial: r.partial);
      return r.chapters;
    } catch (_) {
      return null;
    }
  }

  /// 开始阅读：取目录后进入阅读器（定位到上次进度）
  Future<void> _startReading(Book b) async {
    final chapters = await _loadChapters(b);
    if (chapters == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载目录失败')),
        );
      }
      return;
    }
    final sp = await SharedPreferences.getInstance();
    final last = sp.getInt('progress_${b.bookUrl}') ?? 0;
    final idx = last.clamp(0, chapters.length - 1);
    if (!mounted) return;
    openReader(context, b, chapters, idx);
  }

  /// 下载全书：取目录后逐章取正文并写盘（弹进度框，可取消）
  Future<void> _downloadAll(Book b) async {
    final chapters = await _loadChapters(b);
    if (chapters == null || chapters.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载目录失败')),
        );
      }
      return;
    }
    final source = SourceRegistry().byId(b.sourceId);
    if (source == null) return;
    if (!mounted) return;
    var cancelled = false;
    var done = 0;
    await showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDlg) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            for (var i = 0; i < chapters.length; i++) {
              if (cancelled || !dialogCtx.mounted) break;
              try {
                final c = await source.content(chapters[i]);
                await ChapterCache.write(b.bookUrl, chapters[i].url, c);
              } catch (_) {}
              done++;
              if (dialogCtx.mounted) setDlg(() {});
            }
            if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
          });
          return GlassDialog(
            child: Glass(
              radius: 20,
              blur: 18,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('下载全书',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Text('$done / ${chapters.length} 章'),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value:
                        chapters.isEmpty ? 0 : done / chapters.length,
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () {
                      cancelled = true;
                      Navigator.of(dialogCtx).pop();
                    },
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    final count = await ChapterCache.bookCount(b.bookUrl);
    if (mounted) {
      setState(() => _cachedCount = count);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(cancelled
            ? '已停止，缓存 $done/${chapters.length} 章'
            : '已缓存 $done 章'),
        duration: const Duration(seconds: 1),
      ));
    }
  }

  /// 清除本书缓存
  Future<void> _clearCache(Book b) async {
    final n = await ChapterCache.clearBook(b.bookUrl);
    if (mounted) {
      setState(() => _cachedCount = 0);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已清除 $n 章缓存'),
        duration: const Duration(seconds: 1),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = _full ?? widget.book;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackground()),
          SafeArea(
            child: FutureBuilder<Book>(
              future: _detailFuture,
              builder: (context, snap) {
                final b = snap.data ?? book;
                return Column(
                  children: [
                    // 顶部栏
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '返回',
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              b.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        children: [
                          Glass(
                            radius: 16,
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 封面 + 信息
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: SizedBox(
                                        width: 100,
                                        height: 140,
                                        child: b.cover.isEmpty
                                            ? Container(
                                                color: Colors.grey.shade200,
                                                child: const Icon(Icons.menu_book,
                                                    size: 40,
                                                    color: Colors.grey))
                                            : CoverImage(
                                                b.cover,
                                                sourceId: b.sourceId,
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(b.name,
                                              style: const TextStyle(
                                                  fontSize: 18,
                                                  fontWeight:
                                                      FontWeight.w700)),
                                          const SizedBox(height: 8),
                                          Text(
                                              '作者：${b.author.isEmpty ? "佚名" : b.author}'),
                                          Text('来源：${b.sourceName}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color:
                                                      Colors.grey.shade600)),
                                          if (b.lastChapter != null &&
                                              b.lastChapter!.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Text('最新：${b.lastChapter}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color:
                                                        Colors.grey.shade600)),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                // 简介
                                Text(
                                  '简介',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade600),
                                ),
                                const SizedBox(height: 6),
                                Text(b.intro ?? '暂无简介',
                                    style: const TextStyle(height: 1.6)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          // 操作区
                          Glass(
                            radius: 16,
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                // 开始阅读
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        const Color(0xFF3E8EF7),
                                    minimumSize: const Size.fromHeight(46),
                                  ),
                                  icon: const Icon(Icons.menu_book),
                                  label: const Text('开始阅读'),
                                  onPressed: () => _startReading(b),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize:
                                              const Size.fromHeight(44),
                                        ),
                                        icon: const Icon(Icons.list),
                                        label: const Text('查看目录'),
                                        onPressed: () => Navigator.of(context)
                                            .push(MaterialPageRoute(
                                          builder: (_) => TocPage(book: b),
                                        )),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize:
                                              const Size.fromHeight(44),
                                        ),
                                        icon: const Icon(Icons.download),
                                        label: Text(
                                            _cachedCount > 0
                                                ? '下载全书($_cachedCount章)'
                                                : '下载全书'),
                                        onPressed: () => _downloadAll(b),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize:
                                              const Size.fromHeight(44),
                                        ),
                                        icon: const Icon(Icons.swap_horiz),
                                        label: const Text('换源'),
                                        onPressed: () => _switchSource(b),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(child: _ShelfButton(book: b)),
                                  ],
                                ),
                                if (_cachedCount > 0) ...[
                                  const SizedBox(height: 10),
                                  TextButton.icon(
                                    onPressed: () => _clearCache(b),
                                    icon: const Icon(Icons.delete_outline,
                                        size: 18,
                                        color: Color(0xFFE5484D)),
                                    label: const Text('清除本书缓存',
                                        style: TextStyle(
                                            color: Color(0xFFE5484D),
                                            fontSize: 13)),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfButton extends ConsumerWidget {
  final Book book;
  const _ShelfButton({required this.book});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider.notifier);
    final inShelf = ref.watch(libraryProvider).any(
          (b) => b.bookUrl == book.bookUrl,
        );
    return OutlinedButton.icon(
      icon: Icon(inShelf ? Icons.check : Icons.add),
      label: Text(inShelf ? '已在书架' : '加入书架'),
      onPressed: inShelf
          ? () => library.removeFromShelf(book)
          : () async {
              await library.addToShelf(book);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已加入书架')),
                );
              }
            },
    );
  }
}
