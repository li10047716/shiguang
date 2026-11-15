/// 发现页。
///
/// 布局对应 shiguang 发现页：顶部「搜索 | 书源选择 ▾ | 刷新」工具栏，
/// 下方「榜单/分类」分节 tab + 横向芯片行，再下方三列横向书卡
/// （封面在左，信息在右：书名 / 来源 / 分类 / 简介）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/discover.dart';
import '../../services/discover_cache.dart';
import '../../sources/source.dart';
import '../../sources/source_registry.dart';
import '../book/book_detail_page.dart';
import '../glass.dart';
import '../search/search_page.dart';
import '../widgets/cover_image.dart';
import '../widgets/type_tag.dart';

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage>
    with AutomaticKeepAliveClientMixin {
  static const Color _blue = Color(0xFF3E8EF7);

  List<NovelSource> _sources = [];
  NovelSource? _source;
  bool _sectionRank = true; // true=榜单节，false=分类节
  DiscoverTab? _tab;

  final List<Book> _books = [];
  int _page = 1;
  int _pages = 1;
  bool _loading = false;
  String? _error;
  bool _more = false;

  // 无限滚动
  final ScrollController _scrollCtrl = ScrollController();

  // 发现结果缓存：key = '$sourceId|$tabKey|$isRank' → (已加载书目, 总页数, 已加载页)
  final Map<String, (List<Book>, int, int)> _cache = {};
  bool _forceRefresh = false;

  // 书源选择玻璃下拉
  final GlobalKey _sourceKey = GlobalKey();
  OverlayEntry? _menuOverlay;

  @override
  bool get wantKeepAlive => true;

  // 当前源可用的分节（榜单/分类）
  List<DiscoverTab> get _ranks =>
      _source?.discoverTabs.where((t) => t.isRank).toList() ?? const [];
  List<DiscoverTab> get _cats =>
      _source?.discoverTabs.where((t) => !t.isRank).toList() ?? const [];

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    // 监听书源启停变化：关闭书源后发现页跟着不显示
    SourceRegistry().addListener(_onSourcesChanged);
    _refreshSources();
    if (_sources.isNotEmpty) {
      _source = _sources.first;
      _initSection();
      _load(reset: true);
    }
  }

  @override
  void dispose() {
    SourceRegistry().removeListener(_onSourcesChanged);
    _scrollCtrl.dispose();
    _closeSourceMenu();
    super.dispose();
  }

  /// 重新读取启用中的书源（过滤有发现 tab 的）
  void _refreshSources() {
    _sources = SourceRegistry()
        .enabled
        .where((s) => s.discoverTabs.isNotEmpty)
        .toList();
  }

  /// 书源启停变化：刷新源列表；若当前源被禁用则切到第一个可用源。
  void _onSourcesChanged() {
    if (!mounted) return;
    _refreshSources();
    if (_source != null && !_sources.contains(_source)) {
      if (_sources.isEmpty) {
        setState(() => _source = null);
      } else {
        setState(() => _source = _sources.first);
        _initSection();
        _load(reset: true);
      }
    } else {
      setState(() {});
    }
  }

  // 滚动到底部附近 → 自动加载下一页
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 300 && _more && !_loading) {
      _page++;
      _load();
    }
  }

  String get _cacheKey {
    final src = _source, tab = _tab;
    if (src == null || tab == null) return '';
    return '${src.sourceId}|${tab.key}|${tab.isRank}';
  }

  void _initSection() {
    // 优先榜单节，其次分类节
    if (_ranks.isNotEmpty) {
      _sectionRank = true;
      _tab = _ranks.first;
    } else if (_cats.isNotEmpty) {
      _sectionRank = false;
      _tab = _cats.first;
    }
  }

  Future<void> _load({bool reset = false}) async {
    final src = _source;
    final tab = _tab;
    if (src == null || tab == null) return;
    final key = _cacheKey;
    if (reset) {
      _page = 1;
      _books.clear();
      _error = null;
      // 内存缓存命中：秒开（切回书源/标签时不再转圈）
      if (!_forceRefresh && key.isNotEmpty && _cache.containsKey(key)) {
        final (cachedBooks, cachedPages, cachedLoaded) = _cache[key]!;
        setState(() {
          _loading = false;
          _books.addAll(cachedBooks);
          _pages = cachedPages;
          _page = cachedLoaded;
          _more = _page < _pages;
        });
        return;
      }
      // 磁盘缓存命中：秒开（重进 app 后 30 分钟内）
      if (!_forceRefresh && key.isNotEmpty) {
        final disk = await DiscoverCache.load(key);
        if (disk != null && mounted && _source == src && _tab == tab) {
          final (cachedBooks, cachedPages, cachedLoaded) = disk;
          setState(() {
            _loading = false;
            _books.addAll(cachedBooks);
            _pages = cachedPages;
            _page = cachedLoaded;
            _more = _page < _pages;
          });
          return;
        }
      }
    }
    setState(() {
      _loading = true;
      _more = false;
    });
    try {
      final r = await src.discover(
        tab.key,
        isRank: tab.isRank,
        page: _page,
      );
      if (!mounted || _source != src || _tab != tab) return;
      setState(() {
        _books.addAll(r.books);
        _pages = r.pages;
        _error = null;
      });
      // 写缓存（首页重置缓存，后续分页追加）
      if (key.isNotEmpty) {
        if (_page == 1) {
          _cache[key] = (List.of(_books), r.pages, 1);
        } else {
          final cur = _cache[key];
          if (cur != null) {
            _cache[key] = ([...cur.$1, ...r.books], r.pages, _page);
          } else {
            _cache[key] = (List.of(_books), r.pages, _page);
          }
        }
        // 写磁盘缓存（持久，供重进 app 秒开）
        DiscoverCache.save(key, _books, _pages, _page);
      }
    } catch (e) {
      if (!mounted || _source != src || _tab != tab) return;
      setState(() {
        if (_books.isEmpty) _error = e.toString();
      });
    } finally {
      if (mounted && _source == src && _tab == tab) {
        setState(() {
          _loading = false;
          _more = _page < _pages;
        });
      }
    }
  }

  // 刷新：清当前源/标签缓存（内存+磁盘），强制重载
  Future<void> _refresh() {
    final key = _cacheKey;
    if (key.isNotEmpty) {
      _cache.remove(key);
      DiscoverCache.clear(key);
    }
    _forceRefresh = true;
    return _load(reset: true).whenComplete(() => _forceRefresh = false);
  }

  void _pickSource(NovelSource s) {
    if (s == _source) return;
    _scrollToTop();
    setState(() {
      _source = s;
      _initSection();
    });
    _load(reset: true);
  }

  void _pickSection(bool rank) {
    if (rank == _sectionRank) return;
    _scrollToTop();
    setState(() {
      _sectionRank = rank;
      _tab = rank ? _ranks.first : _cats.first;
    });
    _load(reset: true);
  }

  void _pickTab(DiscoverTab t) {
    if (t == _tab) return;
    _scrollToTop();
    setState(() => _tab = t);
    _load(reset: true);
  }

  void _scrollToTop() {
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _sources.isEmpty
          ? const Center(child: Text('暂无支持发现的书源'))
          : SafeArea(
              child: Stack(
                children: [
                  // 内容（分类行 + 芯片 + 书籍）铺满，顶部预留悬浮胶囊高度
                  Positioned.fill(child: _body()),
                  // 顶部悬浮条：搜索(左) / 书源选择(中) / 刷新(右)，各自独立
                  Positioned(top: 12, left: 16, right: 16, child: _topBar()),
                ],
              ),
            ),
    );
  }

  // ---------- 顶部悬浮条：搜索(左) / 书源选择(中) / 刷新(右) ----------

  Widget _topBar() {
    final s = _source!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 左上：搜索（关闭投影，玻璃底直接贴背景，不出现额外暗层）
        GlassRoundButton(
          icon: Icons.search,
          tooltip: '搜索',
          shadow: false,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SearchPage()),
          ),
        ),
        // 中间：书源选择（独立玻璃胶囊，点击弹玻璃下拉；关闭投影）
        Glass(
          radius: 50,
          blur: 3,
          shadow: false,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: GestureDetector(
            key: _sourceKey,
            onTap: _toggleSourceMenu,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.menu_book,
                    size: 16, color: Color(0xFFE5A13A)),
                const SizedBox(width: 6),
                Text(s.sourceName,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800)),
                Icon(Icons.arrow_drop_down,
                    size: 20, color: Colors.grey.shade800),
              ],
            ),
          ),
        ),
        // 右上：刷新（关闭投影）
        GlassRoundButton(
          icon: Icons.refresh,
          tooltip: '刷新',
          shadow: false,
          onTap: _refresh,
        ),
      ],
    );
  }

  // ---------- 书源选择：玻璃下拉 ----------

  void _toggleSourceMenu() {
    if (_menuOverlay != null) {
      _closeSourceMenu();
      return;
    }
    final ctx = _sourceKey.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final size = box.size;

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => _sourceMenuLayer(
        topLeft: topLeft,
        buttonWidth: size.width,
        buttonHeight: size.height,
        overlay: overlay,
      ),
    );
    _menuOverlay = entry;
    overlay.insert(entry);
  }

  void _closeSourceMenu() {
    _menuOverlay?.remove();
    _menuOverlay = null;
  }

  Widget _sourceMenuLayer({
    required Offset topLeft,
    required double buttonWidth,
    required double buttonHeight,
    required OverlayState overlay,
  }) {
    const menuW = 180.0;
    final screen = MediaQuery.of(context).size;
    final menuH = _sources.length * 40.0 + 12;
    // 菜单水平中心对齐按钮中心（clamp 仅防出屏）
    final left = (topLeft.dx + buttonWidth / 2 - menuW / 2).clamp(
      8.0,
      screen.width - menuW - 8,
    );
    final top = topLeft.dy + buttonHeight + 4;
    return Stack(
      children: [
        // 点击空白处关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeSourceMenu,
          ),
        ),
        Positioned(
          left: left,
          top: top.clamp(0.0, screen.height - menuH - 8),
          width: menuW,
          child: Glass(
            radius: 14,
            blur: 3,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final x in _sources)
                  _sourceMenuItem(x),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sourceMenuItem(NovelSource x) {
    final active = x.sourceId == _source?.sourceId;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () {
          _closeSourceMenu();
          _pickSource(x);
        },
        child: Container(
          // 统一高度 + 垂直居中，避免行高不一显得字体不齐
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: active ? _blue.withValues(alpha: 0.14) : Colors.transparent,
          child: Row(
            children: [
              Icon(
                active ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 15,
                color: active ? _blue : Colors.grey.shade500,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  x.sourceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 统一字重（w600），仅用颜色区分选中态，保证字体一致
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: active ? _blue : const Color(0xFF222222),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TypeTag(type: x.type),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 分节 tab：榜单 / 分类 ----------

  // ---------- 分类区：圆角矩形框（榜单/分类 + 分类芯片，芯片放不下自动换行） ----------

  Widget _categoryBox() {
    // 无榜单且无分类时不渲染空玻璃框
    if (_ranks.isEmpty && _cats.isEmpty) return const SizedBox.shrink();
    return Padding(
      // 顶部让出顶栏高度（顶栏 top:12 + 约 48 高），分类框整体下移避开悬浮按钮
      padding: const EdgeInsets.fromLTRB(16, 60, 16, 0),
      child: Glass(
        radius: 20,
        blur: 3,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTabs(),
            _chips(),
          ],
        ),
      ),
    );
  }

  Widget _sectionTabs() {
    final hasRank = _ranks.isNotEmpty;
    final hasCat = _cats.isNotEmpty;
    if (!hasRank && !hasCat) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          if (hasRank) _sectionTab('榜单', true),
          const SizedBox(width: 10),
          if (hasCat) _sectionTab('分类', false),
        ],
      ),
    );
  }

  Widget _sectionTab(String label, bool rank) {
    final active = rank == _sectionRank;
    return GestureDetector(
      onTap: () => _pickSection(rank),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
        decoration: BoxDecoration(
          color: active ? _blue : Colors.white.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? _blue : Colors.white.withValues(alpha: 0.5),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? Colors.white : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  // ---------- 芯片行 ----------

  Widget _chips() {
    final tabs = _sectionRank ? _ranks : _cats;
    if (tabs.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in tabs)
          GestureDetector(
            onTap: () => _pickTab(t),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: t == _tab
                    ? _blue
                    : Colors.white.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: t == _tab
                      ? _blue
                      : Colors.white.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                t.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      t == _tab ? FontWeight.w600 : FontWeight.w400,
                  color:
                      t == _tab ? Colors.white : Colors.grey.shade700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---------- 内容 ----------

  Widget _body() {
    final isMobile = MediaQuery.of(context).size.width < 600;
    // 分类框常驻；切换标签/源时只有下方书籍区随加载状态刷新，
    // 上面的「榜单/分类」和芯片保持不动。
    // 内容铺到顶（不再留 60 空带，避免顶部露裸渐变「遮罩带」）。
    return Padding(
      padding: EdgeInsets.zero,
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ScrollConfiguration(
          // 桌面端默认鼠标拖拽不滚动列表，这里允许鼠标/触屏拖拽，
          // 才能产生过滚触发 RefreshIndicator 下拉刷新。
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.stylus,
              PointerDeviceKind.trackpad,
            },
          ),
          child: CustomScrollView(
            controller: _scrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _categoryBox()),
              // 书籍区：错误 / 加载 / 空 / 网格（仅此区随标签切换刷新）
              if (_error != null && _books.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _errorView(),
                )
              else if (_books.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : const Center(child: Text('暂无内容')),
                )
              else ...[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      // 手机屏窄：横向卡（封面左+信息右）3 列会挤到只剩一条缝，降为 1 列全宽
                      crossAxisCount: isMobile ? 1 : 3,
                      childAspectRatio: isMobile ? 2.6 : 2.55,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _DiscoverCard(book: _books[i]),
                      childCount: _books.length,
                    ),
                  ),
                ),
                if (_more)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _loading
                          ? const SizedBox(
                              width: 22, height: 22,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : GestureDetector(
                              onTap: () {
                                _page++;
                                _load();
                              },
                              child: Text(
                                '上拉或点击加载更多（$_page/$_pages 页）',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey),
                              ),
                            ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 书籍区错误视图（分类框仍在，仅书籍区显示重试）
  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _load(reset: true),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 发现页横向书卡：封面在左，信息在右（书名/来源/分类/简介）。
class _DiscoverCard extends StatelessWidget {
  final Book book;
  const _DiscoverCard({required this.book});

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 10,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => BookDetailPage(book: book)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 86,
                child: ClipRRect(
                  // 封面四角都圆：卡片外层 Material 只裁左边缘（封面左角），
                  // 封面右缘在卡片内部是直角，这里补上同款圆角。
                  borderRadius: BorderRadius.circular(10),
                  child: CoverImage(book.cover, sourceId: book.sourceId),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF222222)),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.menu_book,
                              size: 12, color: Color(0xFFE5A13A)),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              '来源: ${book.sourceName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      if ((book.intro ?? '').isNotEmpty)
                        Text(
                          book.intro!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                      if (book.author.isNotEmpty)
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
