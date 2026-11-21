/// 发现页。
///
/// 布局：顶部居中的「书源选择 ▾」悬浮工具栏，
/// 下方左侧「推荐/分类」常驻栏 + 右侧二级标签与书库：桌面多列网格，手机单列横卡。
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
  bool _sectionRank = true; // true=推荐节，false=分类节
  DiscoverTab? _tab;

  final List<Book> _books = [];
  int _page = 1;
  int _pages = 1;
  bool _loading = false;
  String? _error;
  bool _more = false;

  // 无限滚动
  final ScrollController _scrollCtrl = ScrollController();
  // 列表末尾「加载更多」提示的锚点：若它已出现在视口内说明首屏没铺满
  final GlobalKey _loadMoreKey = GlobalKey();

  // 发现结果缓存：key = '$sourceId|$tabKey|$isRank' → (已加载书目, 总页数, 已加载页)
  final Map<String, (List<Book>, int, int)> _cache = {};
  bool _forceRefresh = false;

  // 书源选择下拉
  final GlobalKey _sourceKey = GlobalKey();
  OverlayEntry? _menuOverlay;

  @override
  bool get wantKeepAlive => true;

  // 当前源可用的分节（推荐/分类）
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
    // 优先推荐节，其次分类节
    if (_ranks.isNotEmpty) {
      _sectionRank = true;
      _tab = _ranks.first;
    } else if (_cats.isNotEmpty) {
      _sectionRank = false;
      _tab = _cats.first;
    }
  }

  Future<void> _load({bool reset = false, bool keepBooks = false}) async {
    final src = _source;
    final tab = _tab;
    if (src == null || tab == null) return;
    final key = _cacheKey;
    if (reset) {
      _page = 1;
      // 下拉刷新时保留旧书列表：否则列表清空后中间会再转一个大圈，
      // 与顶部 RefreshIndicator 的刷新圈重复。成功后用新数据替换即可。
      if (!keepBooks) _books.clear();
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
        _scheduleAutoFill();
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
        // 下拉刷新：用新数据替换旧列表；普通翻页：追加
        if (keepBooks) _books.clear();
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
        // 首屏内容不足一屏时自动续加载，直到填满视口或没有更多
        _scheduleAutoFill();
      }
    }
  }

  /// 首屏可能一页填不满视口，导致用户必须先上拉/点击才加载更多。
  /// 布局完成后检测列表末尾「加载更多」提示是否已进入视口：
  /// 若已进入（说明底下还有空位），自动加载下一页，循环直到铺满或无更多。
  void _scheduleAutoFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || !_more) return;
      final ctx = _loadMoreKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final top = box.localToGlobal(Offset.zero).dy;
      final screenH = MediaQuery.of(context).size.height;
      // 提示行顶部已进入屏幕（顶部 < 屏高）→ 底下还有空位，继续加载
      if (top < screenH) {
        _page++;
        _load();
      }
    });
  }

  // 刷新：清当前源/标签缓存（内存+磁盘），强制重载
  Future<void> _refresh() {
    final key = _cacheKey;
    if (key.isNotEmpty) {
      _cache.remove(key);
      DiscoverCache.clear(key);
    }
    _forceRefresh = true;
    return _load(reset: true, keepBooks: true)
        .whenComplete(() => _forceRefresh = false);
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
                  // 顶部悬浮条：只保留居中的书源选择
                  Positioned(top: 12, left: 16, right: 16, child: _topBar()),
                ],
              ),
            ),
    );
  }

  // ---------- 顶部悬浮条：只保留居中的书源选择 ----------

  Widget _topBar() {
    final s = _source!;
    return Center(
      // 书源选择（白色卡片框，与书卡同底色，点击弹下拉）
      child: FlatCard(
        radius: 14,
        shadow: false,
        child: GestureDetector(
          key: _sourceKey,
          onTap: _toggleSourceMenu,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
      ),
    );
  }

  // ---------- 书源选择：下拉菜单 ----------

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
          child: FlatCard(
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
              const TypeTag(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 左侧常驻栏：当前分区的二级标签（竖排） ----------

  Widget _categoryRail(bool isMobile) {
    final tabs = _sectionRank ? _ranks : _cats;
    if (tabs.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    // 标签多时卡片内部滚动，最高不超过一屏
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height - 100,
      ),
      child: FlatCard(
        radius: 16,
        blur: 3,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: ListView(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          primary: false,
          children: [
            for (final t in tabs)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: GestureDetector(
                  onTap: () => _pickTab(t),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                        vertical: isMobile ? 7 : 8, horizontal: 4),
                    decoration: BoxDecoration(
                      color: t == _tab
                          ? cs.primary
                          : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color:
                            t == _tab ? cs.primary : cs.outlineVariant,
                      ),
                    ),
                    child: Text(
                      t.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isMobile ? 11 : 12,
                        fontWeight:
                            t == _tab ? FontWeight.w700 : FontWeight.w500,
                        color: t == _tab
                            ? cs.onPrimary
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 右侧顶部固定条：「推荐 / 分类」两个顶级入口（不随内容滑动）。
  Widget _sectionChips(bool isMobile) {
    final cs = Theme.of(context).colorScheme;
    Widget chip(String label, bool rank) {
      final active = rank == _sectionRank;
      return GestureDetector(
        onTap: () => _pickSection(rank),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 14 : 16, vertical: 7),
          decoration: BoxDecoration(
            color: active ? cs.primary : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: active ? cs.primary : cs.outlineVariant,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              color: active ? cs.onPrimary : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('推荐', true),
        const SizedBox(width: 8),
        chip('分类', false),
      ],
    );
  }

  // ---------- 内容：左侧常驻栏 + 右侧书库（桌面多列 / 手机单列） ----------

  Widget _body() {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 600;
    final railWidth = isMobile ? 60.0 : 110.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 60, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: railWidth, child: _categoryRail(isMobile)),
          SizedBox(width: isMobile ? 10 : 14),
          Expanded(child: _bookArea(width, isMobile)),
        ],
      ),
    );
  }

  Widget _bookArea(double width, bool isMobile) {
    final columns = width >= 1100 ? 4 : 3;
    // 顶部「推荐/分类」固定不随内容滑动，书库在下方独立滚动
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _sectionChips(isMobile),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ScrollConfiguration(
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
              if (isMobile)
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 10),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: SizedBox(
                          height: 112,
                          child: _DiscoverCard(book: _books[i]),
                        ),
                      ),
                      childCount: _books.length,
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 16),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      childAspectRatio: 2.55,
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
                    key: _loadMoreKey,
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : GestureDetector(
                            onTap: () {
                              _page++;
                              _load();
                            },
                            child: Text(
                              '滚动自动加载更多（$_page/$_pages 页）',
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
        ),
      ],
    );
  }

  // 书籍区错误视图（左侧分类栏仍在，仅书籍区显示重试）
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
    return FlatCard(
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
