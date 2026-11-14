/// 目录页：加载章节列表，点击章节进入阅读器
///
/// 体验要点：
/// - **边收边显示**：每抓完一页就渲染，不必等全部页；首屏 1000 章几乎立刻可点
/// - 先读本地缓存，瞬间出列表；再后台刷新（刷新失败保留缓存）
/// - 失败时展示具体原因并可重试，而不是空白页
/// - 支持按章节名搜索，可直接跳回上次阅读位置
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../services/toc_cache.dart';
import '../../sources/source_registry.dart';
import '../glass.dart';
import '../reader/open_reader.dart';

class TocPage extends StatefulWidget {
  final Book book;

  /// 打开后自动滚动定位到该章节（书签/笔记跳转用）
  final int? initialIndex;
  const TocPage({super.key, required this.book, this.initialIndex});

  @override
  State<TocPage> createState() => _TocPageState();
}

class _TocPageState extends State<TocPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  /// 按目录页码分块保存，后续页到了直接追加
  final Map<int, List<Chapter>> _chunks = {};

  List<Chapter> _chapters = const [];
  List<Chapter> _visible = const [];
  Map<String, int> _urlIndex = const {};

  bool _loading = true;
  bool _refreshing = false;
  String _progress = '';
  String? _error;
  String? _warning;
  String _filter = '';
  int _lastReadIndex = 0;
  bool _jumpedToInitial = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final cached = await TocCache.read(widget.book.bookUrl);
    final sp = await SharedPreferences.getInstance();
    final lastIdx = sp.getInt('progress_${widget.book.bookUrl}') ?? 0;
    if (!mounted) return;
    if (cached != null) {
      _chunks.clear();
      _chunks[1] = List.of(cached.chapters);
      _rebuild();
      setState(() {
        _loading = false;
        _refreshing = !cached.isFresh;
        _lastReadIndex = lastIdx;
        _warning = cached.partial ? '本地缓存为部分目录，正在刷新…' : null;
      });
      // 缓存还新鲜（30 分钟内抓过）就直接用，不再重复扫一遍站点
      if (cached.isFresh && !cached.partial) return;
    } else {
      setState(() => _lastReadIndex = lastIdx);
    }
    await _fetch(keepExisting: cached != null);
  }

  Future<void> _fetch({bool keepExisting = false}) async {
    setState(() {
      _error = null;
      _loading = _chapters.isEmpty && !keepExisting;
      _refreshing = true;
      _progress = '正在加载目录…';
    });

    final source = SourceRegistry().byId(widget.book.sourceId);
    if (source == null) {
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = '找不到书源：${widget.book.sourceId}';
      });
      return;
    }

    if (!keepExisting) {
      _chunks.clear();
      _rebuild();
    }

    try {
      final result = await source.loadToc(
        widget.book,
        onProgress: (page, count) {
          if (!mounted) return;
          setState(() => _progress = '正在加载 · 第 $page 页 · 已取 $count 章');
        },
        // 每页到货立刻上屏：首屏 1000 章不等后面几页
        onPageChunk: (page, list) {
          if (!mounted || list.isEmpty) return;
          _chunks[page] = list;
          _rebuild();
          setState(() {
            _loading = false;
            _progress = '已加载 ${_chapters.length} 章，正在加载剩余页…';
          });
        },
      );

      if (!mounted) return;
      _chunks.clear();
      _chunks[1] = List.of(result.chapters);
      _rebuild();
      setState(() {
        _warning = result.warning;
        _loading = false;
        _refreshing = false;
        _progress = '';
      });
      await TocCache.write(
        widget.book.bookUrl,
        result.chapters,
        partial: result.partial,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _progress = '';
        _error = _chapters.isEmpty ? e.toString() : null;
        if (_chapters.isNotEmpty) _warning = '刷新失败，当前显示已加载的部分';
      });
    }
  }

  /// 合并所有页块 → 章节列表 + 过滤结果 + 索引
  void _rebuild() {
    final merged = <Chapter>[];
    final seen = <String>{};
    for (final p in _chunks.keys.toList()..sort()) {
      for (final c in _chunks[p]!) {
        if (seen.add(c.url)) merged.add(c);
      }
    }
    _chapters = merged;

    final idx = <String, int>{};
    for (var i = 0; i < merged.length; i++) {
      idx[merged[i].url] = i;
    }
    _urlIndex = idx;

    if (_filter.isEmpty) {
      _visible = merged;
    } else {
      final kw = _filter.toLowerCase();
      _visible =
          merged.where((c) => c.title.toLowerCase().contains(kw)).toList();
    }
    _jumpToInitial();
  }

  /// 打开后自动滚动到初始章节（书签/笔记跳转），只执行一次。
  void _jumpToInitial() {
    final idx = widget.initialIndex;
    if (_jumpedToInitial || idx == null || idx <= 0) return;
    _jumpedToInitial = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(
          (idx * 44.0 - 160).clamp(0.0, double.infinity));
    });
  }

  void _open(int visibleIndex) {
    final target = _visible[visibleIndex];
    final allIndex = _urlIndex[target.url] ?? visibleIndex;
    openReader(
      context,
      widget.book,
      _chapters,
      allIndex,
      chaptersProvider: () => _chapters,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackground()),
          SafeArea(
            child: Column(
              children: [
                // 顶部栏：返回 + 标题 + 刷新
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
                          '目录 · ${widget.book.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新目录',
                        icon: const Icon(Icons.refresh),
                        onPressed: _refreshing ? null : () => _fetch(),
                      ),
                    ],
                  ),
                ),
                // 刷新进度条
                if (_refreshing)
                  const LinearProgressIndicator(
                    minHeight: 3,
                    backgroundColor: Colors.transparent,
                  ),
                if (_chapters.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Glass(
                            radius: 20,
                            blur: 18,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 2),
                            child: TextField(
                              controller: _searchCtrl,
                              decoration: InputDecoration(
                                isDense: true,
                                prefixIcon:
                                    const Icon(Icons.search, size: 20),
                                hintText:
                                    '搜索章节名（已加载 ${_chapters.length} 章）',
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 0, vertical: 10),
                              ),
                              onChanged: (v) => setState(() {
                                _filter = v.trim();
                                _rebuild();
                              }),
                            ),
                          ),
                        ),
                        if (_lastReadIndex > 0 && _filter.isEmpty) ...[
                          const SizedBox(width: 8),
                          Glass(
                            radius: 20,
                            blur: 18,
                            child: TextButton(
                              onPressed: _jumpToLastRead,
                              child: const Text('上次读'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (_progress.isNotEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 10,
                            height: 10,
                            child:
                                CircularProgressIndicator(strokeWidth: 1.6),
                          ),
                          const SizedBox(width: 6),
                          Text(_progress,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  ),
                if (_warning != null)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Glass(
                      radius: 10,
                      padding: const EdgeInsets.all(10),
                      child: Text(_warning!,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.orange)),
                    ),
                  ),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_progress.isEmpty ? '正在加载目录…' : _progress,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 44, color: Colors.grey),
              const SizedBox(height: 12),
              const Text('目录加载失败',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SelectableText(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.red.shade400),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3E8EF7)),
                onPressed: () => _fetch(),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final list = _visible;
    if (list.isEmpty) {
      return Center(
        child: Text('没有匹配「$_filter」的章节',
            style: TextStyle(color: Colors.grey.shade600)),
      );
    }

    // 整张目录放进一块玻璃面板
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Glass(
        radius: 16,
        blur: 0,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Scrollbar(
          controller: _scrollCtrl,
          child: ListView.builder(
            controller: _scrollCtrl,
            itemCount: list.length,
            // 固定行高：长列表滚动更顺，也能按偏移量定位
            itemExtent: 44,
            itemBuilder: (context, i) {
              final c = list[i];
              final allIndex = _urlIndex[c.url] ?? i;
              final isLastRead = allIndex == _lastReadIndex;
              return ListTile(
                dense: true,
                selected: isLastRead,
                leading: SizedBox(
                  width: 44,
                  child: Text(
                    '${allIndex + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isLastRead
                          ? const Color(0xFF3E8EF7)
                          : Colors.grey.shade500,
                    ),
                  ),
                ),
                title: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isLastRead ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                trailing: isLastRead
                    ? const Icon(Icons.play_arrow,
                        size: 16, color: Color(0xFF3E8EF7))
                    : null,
                onTap: () => _open(i),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 跳到上次阅读位置（按固定行高估算滚动，再提示）
  void _jumpToLastRead() {
    final target = _lastReadIndex.clamp(0, _chapters.length - 1);
    if (_searchCtrl.text.isNotEmpty) {
      _searchCtrl.clear();
      setState(() {
        _filter = '';
        _rebuild();
      });
    }
    final pos = _visible.indexWhere((c) => c.url == _chapters[target].url);
    final offset = ((pos == -1 ? target : pos) * 44.0 - 160)
        .clamp(0.0, double.infinity);
    _scrollCtrl.jumpTo(offset);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('上次读到：第 ${target + 1} 章 ${_chapters[target].title}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
