/// 漫画阅读器：左右翻页 / 条漫连续滚动、双击+捏合缩放、预加载、进度记忆。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../models/content.dart';
import '../../sources/source_registry.dart';

enum ComicMode { paged, strip }

/// 漫画阅读页。由 [openReader] 按 book.type == comic 分派进来。
class ComicReaderPage extends StatefulWidget {
  final Book book;
  final List<Chapter> chapters;
  final int initialIndex;

  const ComicReaderPage({
    super.key,
    required this.book,
    required this.chapters,
    this.initialIndex = 0,
  });

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  late int _index;
  int _page = 0; // 当前话内的图片页（0 基）
  ComicMode _mode = ComicMode.paged;

  Content? _content;
  bool _loading = true;
  String? _error;

  // 预载：章节索引 -> 内容 / 进行中的请求
  final Map<int, Content> _preloaded = {};
  final Map<int, Future<Content>> _inflight = {};

  final PageController _pageCtrl = PageController();
  final ScrollController _stripCtrl = ScrollController();

  bool _showBar = true;
  bool _showHint = false;
  late DateTime _lastTick;

  static const Color _gold = Color(0xFFF5C451);

  String get _spKey => 'comic_page_${widget.book.bookUrl}';

  /// 每话的页内进度独立记忆，切话后回来仍能续读。
  String _pageKey(int i) => '${_spKey}_$i';

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.chapters.length - 1);
    _lastTick = DateTime.now();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadIndex(_index);
    SharedPreferences.getInstance().then((sp) {
      if (sp.getBool('comic_hint_shown') != true && mounted) {
        setState(() => _showHint = true);
        sp.setBool('comic_hint_shown', true);
      }
    });
  }

  @override
  void dispose() {
    _tickFlush();
    _pageCtrl.dispose();
    _stripCtrl.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<Content> _fetch(int i) async {
    final cached = _preloaded[i];
    if (cached != null) return cached;
    final pending = _inflight[i];
    if (pending != null) return pending;
    final f = () async {
      final source = SourceRegistry().byId(widget.book.sourceId);
      if (source == null) throw StateError('书源不可用');
      final c = await source.content(widget.chapters[i]);
      _preloaded[i] = c;
      return c;
    }();
    _inflight[i] = f;
    try {
      return await f;
    } finally {
      _inflight.remove(i);
    }
  }

  Future<void> _loadIndex(int i) async {
    if (i < 0 || i >= widget.chapters.length) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await _fetch(i);
      if (!mounted) return;
      // 恢复本话上次读到的图片页
      final sp0 = await SharedPreferences.getInstance();
      final savedPage = sp0.getInt(_pageKey(i)) ?? 0;
      final page = savedPage.clamp(0, (c.pages.length - 1).clamp(0, 1 << 30));
      setState(() {
        _index = i;
        _content = c;
        _page = page;
        _loading = false;
      });
      if (_mode == ComicMode.paged && _pageCtrl.hasClients) {
        _pageCtrl.jumpToPage(page);
      }
      if (_mode == ComicMode.strip && _page > 0 && _stripCtrl.hasClients) {
        _stripCtrl.jumpTo(_page * 500.0);
      }
      await _saveProgress();
      _markRead(i);
      _preloadNeighbors();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _preloadNeighbors() {
    for (var d = 1; d <= 2; d++) {
      final next = _index + d;
      final prev = _index - d;
      if (next < widget.chapters.length && !_preloaded.containsKey(next)) {
        _fetch(next).catchError((_) => Content(title: ''));
      }
      if (prev >= 0 && !_preloaded.containsKey(prev)) {
        _fetch(prev).catchError((_) => Content(title: ''));
      }
    }
  }

  Future<void> _saveProgress() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('progress_${widget.book.bookUrl}', _index);
    await sp.setInt(_pageKey(_index), _page);
  }

  Future<void> _markRead(int i) async {
    final sp = await SharedPreferences.getInstance();
    final set = (sp.getStringList('read_chapters') ?? const []).toSet();
    set.add('${widget.book.bookUrl}#$i');
    await sp.setStringList('read_chapters', set.toList());
  }

  void _switchMode(ComicMode m) {
    if (m == _mode) return;
    setState(() => _mode = m);
  }

  void _toggleBar() => setState(() => _showBar = !_showBar);

  Future<void> _tickFlush() async {
    final now = DateTime.now();
    final ms = now.difference(_lastTick).inMilliseconds;
    _lastTick = now;
    if (ms < 0 || ms > 60 * 60 * 1000) return;
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('read_total_ms', (sp.getInt('read_total_ms') ?? 0) + ms);
    final day = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    await sp.setInt('read_daily_$day', (sp.getInt('read_daily_$day') ?? 0) + ms);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody()),
          // 顶部信息栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            top: _showBar ? 0 : -110,
            left: 0,
            right: 0,
            child: _topBar(),
          ),
          // 底部控制栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            bottom: _showBar ? 0 : -120,
            left: 0,
            right: 0,
            child: _bottomBar(),
          ),
          // 首次进入的操作提示（3.5 秒后淡出）
          if (_showHint)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _showHint = false),
                child: _hintOverlay(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: _gold),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white54, size: 40),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _gold),
                onPressed: () => _loadIndex(_index),
                child: const Text('重试', style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
        ),
      );
    }
    final pages = _content?.pages ?? const <ComicPage>[];
    if (pages.isEmpty) {
      return const Center(
          child: Text('本章暂无图片', style: TextStyle(color: Colors.white70)));
    }
    return _mode == ComicMode.paged ? _pagedView(pages) : _stripView(pages);
  }

  /// 左右翻页：一页一张图。点击左/右 1/4 翻页，中间唤出控制栏，可缩放拖动。
  Widget _pagedView(List<ComicPage> pages) {
    return PageView.builder(
      controller: _pageCtrl,
      itemCount: pages.length,
      onPageChanged: (p) => _onPageChanged(p),
      itemBuilder: (context, p) => _zoomableImage(pages[p].url, p),
    );
  }

  /// 条漫：整话图片纵向连续滚动
  Widget _stripView(List<ComicPage> pages) {
    return ListView.builder(
      controller: _stripCtrl,
      itemCount: pages.length,
      itemBuilder: (context, p) => _zoomableImage(pages[p].url, p, strip: true),
    );
  }

  Widget _zoomableImage(String url, int pageIndex, {bool strip = false}) {
    return _ComicImageView(
      url: url,
      strip: strip,
      gold: _gold,
      onTapLeft: () => _tapLeft(pageIndex, strip),
      onTapRight: () => _tapRight(pageIndex, strip),
      onTapCenter: _toggleBar,
    );
  }

  double get _screenH => MediaQuery.of(context).size.height;

  /// 点左侧：上一页 / 条漫上滚一屏（到头则上一话）
  void _tapLeft(int pageIndex, bool strip) {
    if (strip) {
      final target = (_stripCtrl.offset - _screenH).clamp(0.0, _stripCtrl.position.maxScrollExtent);
      _stripCtrl.animateTo(target,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      return;
    }
    if (pageIndex > 0) {
      _pageCtrl.animateToPage(pageIndex - 1,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    } else if (_index > 0) {
      _goPrevChapter();
    }
  }

  /// 点右侧：下一页 / 条漫下滚一屏（到底则下一话）
  void _tapRight(int pageIndex, bool strip) {
    final count = _content?.pages.length ?? 0;
    if (strip) {
      final max = _stripCtrl.position.maxScrollExtent;
      final target = (_stripCtrl.offset + _screenH).clamp(0.0, max);
      if (target >= max - 1 && _index < widget.chapters.length - 1) {
        _goNextChapter();
      } else {
        _stripCtrl.animateTo(target,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      }
      return;
    }
    if (pageIndex < count - 1) {
      _pageCtrl.animateToPage(pageIndex + 1,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    } else if (_index < widget.chapters.length - 1) {
      _goNextChapter();
    }
  }

  void _onPageChanged(int p) {
    _page = p;
    SharedPreferences.getInstance()
        .then((sp) => sp.setInt(_pageKey(_index), p));
    setState(() {});
  }

  void _goPrevChapter() {
    if (_index > 0) {
      _page = 0;
      _pageCtrl.jumpToPage(0);
      _loadIndex(_index - 1);
    }
  }

  void _goNextChapter() {
    if (_index < widget.chapters.length - 1) {
      _page = 0;
      _pageCtrl.jumpToPage(0);
      _stripCtrl.jumpTo(0);
      _loadIndex(_index + 1);
    }
  }

  Widget _topBar() {
    final ch = widget.chapters[_index];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.85), Colors.transparent],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.of(context).padding.top + 8, 16, 30),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                Text(ch.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final pageCount = _content?.pages.length ?? 0;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.9), Colors.transparent],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 24, 16, MediaQuery.of(context).padding.bottom + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _barBtn(Icons.chevron_left, _index > 0 ? _goPrevChapter : null),
              Expanded(
                child: Slider(
                  value: (_index + 1).toDouble().clamp(1, widget.chapters.length.toDouble()),
                  min: 1,
                  max: widget.chapters.length.toDouble(),
                  divisions: widget.chapters.length > 1 ? widget.chapters.length - 1 : 1,
                  activeColor: _gold,
                  inactiveColor: Colors.white30,
                  onChanged: (v) => _loadIndex(v.round() - 1),
                ),
              ),
              _barBtn(Icons.chevron_right,
                  _index < widget.chapters.length - 1 ? _goNextChapter : null),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _modeBtn(Icons.view_carousel_outlined, '翻页', ComicMode.paged),
              _modeBtn(Icons.view_stream_outlined, '条漫', ComicMode.strip),
              Text(
                '第 ${_index + 1}/${widget.chapters.length} 话 · $pageCount 图',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hintOverlay() {
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showHint = false);
    });
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, color: _gold, size: 28),
            SizedBox(height: 10),
            Text('点击左右两侧翻页 · 点中间显示菜单',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            SizedBox(height: 4),
            Text('双击或捏合缩放 · 放大后拖动查看',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            SizedBox(height: 8),
            Text('轻触任意处关闭',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _barBtn(IconData icon, VoidCallback? onTap) => IconButton(
        icon: Icon(icon, color: onTap == null ? Colors.white24 : Colors.white),
        onPressed: onTap,
      );

  Widget _modeBtn(IconData icon, String label, ComicMode mode) => TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: _mode == mode ? _gold : Colors.white60,
        ),
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: () => _switchMode(mode),
      );
}

/// 单张漫画图片：缩放 + 点击三区。
///
/// 缩放状态由 [TransformationController] 监听：
///  - 未放大（scale≈1）：关闭 InteractiveViewer 的平移，PageView 可横向滑动翻页；
///    同时点击左/中/右三区分别 = 上一页 / 控制栏 / 下一页。
///  - 已放大（scale>1.05）：开启平移，可拖动查看图片细节，双击复位/继续放大。
/// 条漫模式（[strip]）下点击三区用于上下滚动一屏。
class _ComicImageView extends StatefulWidget {
  final String url;
  final bool strip;
  final Color gold;
  final VoidCallback onTapLeft;
  final VoidCallback onTapRight;
  final VoidCallback onTapCenter;

  const _ComicImageView({
    required this.url,
    required this.strip,
    required this.gold,
    required this.onTapLeft,
    required this.onTapRight,
    required this.onTapCenter,
  });

  @override
  State<_ComicImageView> createState() => _ComicImageViewState();
}

class _ComicImageViewState extends State<_ComicImageView> {
  final _ctrl = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final z = _ctrl.value.getMaxScaleOnAxis() > 1.05;
      if (z != _zoomed && mounted) setState(() => _zoomed = z);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapUp(TapUpDetails d) {
    final w = MediaQuery.of(context).size.width;
    final x = d.globalPosition.dx;
    // 放大时左右点击不翻页（避免查看细节时误触），但点中间仍可唤出菜单
    if (x < w * 0.28) {
      if (!_zoomed) widget.onTapLeft();
    } else if (x > w * 0.72) {
      if (!_zoomed) widget.onTapRight();
    } else {
      widget.onTapCenter();
    }
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _ctrl,
      minScale: 1.0,
      maxScale: 5.0,
      panEnabled: _zoomed, // 未放大时让 PageView 接管横向滑动翻页
      scaleEnabled: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
        child: Container(
          width: double.infinity,
          color: Colors.black,
          child: Image.network(
            widget.url,
            headers: {'User-Agent': 'Mozilla/5.0'},
            fit: widget.strip ? BoxFit.fitWidth : BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return SizedBox(
                height: 400,
                child: Center(
                  child: CircularProgressIndicator(
                    color: widget.gold,
                    value: progress.expectedTotalBytes != null
                        ? progress.cumulativeBytesLoaded /
                            progress.expectedTotalBytes!
                        : null,
                  ),
                ),
              );
            },
            errorBuilder: (_, _, _) => SizedBox(
              height: 400,
              child: Center(
                child: Icon(Icons.broken_image_outlined,
                    color: Colors.white30, size: 40),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
