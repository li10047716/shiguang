/// 阅读器：正文加载、上下章切换、字号/背景设置。
///
/// 小说与漫画共用：小说渲染段落文本，漫画渲染图片列表。
/// 漫画源图片地址直接网络加载；本地书（locimg://）从应用目录读取。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../models/content.dart';
import '../../services/chapter_cache.dart';
import '../../services/library.dart';
import '../../services/marks.dart';
import '../../sources/native/localbook.dart';
import '../../sources/source_registry.dart';
import '../glass.dart';
import '../widgets/cover_image.dart';
import 'reader_prefs.dart';

class ReaderPage extends StatefulWidget {
  final Book book;
  final List<Chapter> chapters;
  final int initialIndex;

  /// 目录可能还在后台追加章节（多页目录边收边显示），
  /// 传入 getter 后可通过「下一章」读到后续加载出来的章节。
  final List<Chapter> Function()? chaptersProvider;

  const ReaderPage({
    super.key,
    required this.book,
    required this.chapters,
    required this.initialIndex,
    this.chaptersProvider,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with SingleTickerProviderStateMixin {
  late int _index;
  Content? _content;
  bool _loading = false;
  String? _error;
  double _fontSize = 18;
  Color _bg = const Color(0xFFF7F3E8); // 护眼米黄

  // ---- 阅读体验增强 ----
  double _lineHeight = 1.9; // 行距
  double _paraGap = 0.5; // 段距（段落间距，单位 = 行高倍数，0-3 连续）
  String? _fontFamily; // 字体（null = 系统默认）
  double _brightness = 1.0; // 亮度（1 = 无遮罩，越低越暗）
  int _turnMode = 0; // 翻页效果：0 左右平移 / 1 上下平移 / 2 上下滑动 / 3 仿真翻页
  bool _autoNight = true; // 夜间自动切换（21:00-7:00）
  final bool _indent = true; // 段首缩进（固定开启）
  final bool _justify = false; // 两端对齐（固定关闭）
  int _wallpaper = 0; // 背景壁纸（0 = 无，>0 = 内置渐变索引）
  String _wallpaperImg = ''; // 本地导入的壁纸图片路径（空 = 无）
  double _pagePadLeft = 20; // 左边距（可调，独立）
  double _pagePadRight = 20; // 右边距（可调，独立）
  double _pagePadTop = 6; // 上页边距：章标题与正文间距（可调）
  double _pagePadBottom = 8; // 下页边距：正文末行与进度行间距（可调）
  bool _immersive = false; // 沉浸阅读（隐藏状态栏）

  // 上下滑动（连续滚动）控制器
  final ScrollController _scrollCtrl = ScrollController();
  double _scrollPercent = 0; // 上下滑动进度 0-1

  // 阅读时长统计：上次结算时刻
  DateTime _lastTick = DateTime.now();

  // 自动阅读（定时翻页）
  Timer? _autoTimer;
  int _autoSec = 10;
  bool _autoReading = false;

  // 漫画阅读方向（true = 右往左，日漫习惯）
  bool _comicReadDir = false;

  // 阅读背景音（白噪音循环）
  final AudioPlayer _bgPlayer = AudioPlayer();
  bool _bgSound = false;
  // 目录面板用底部弹窗（与设置一致），不再用左侧 Drawer

  /// 是否显示顶部/底部控制栏（点中间切换）
  bool _showControls = true;

  /// 当前章节是否已加书签
  bool _bookmarked = false;

  /// 划线笔记模式（小说：开启后正文可选中，选中后记笔记）
  bool _noteMode = false;

  /// 当前选区文本（笔记模式）
  String _selectedText = '';

  /// 漫画是否页漫模式（true=逐页翻，false=条漫竖滑）
  bool _comicPage = false;

  // ---------- 小说分页（左右翻页 + 本章进度） ----------
  final PageController _pageController = PageController();
  int _pageIndex = 0;
  List<_NovelPage> _pages = const []; // 当前章分页（每页=段落片段列表，段距像素级）
  String? _reflowKey; // 分页指纹（内容/字号/尺寸变则重排）
  int? _pendingPage; // 跨章进入时定位（prev 进章 → 最后一页）

  /// 翻页方向：true = 从右到左（点右翻页仍是下一页，仅 PageView 视觉反向）
  bool _flipReverse = false;

  /// 进度条拖动中的临时值（松手才跳章）
  double? _sliderDrag;

  /// 目录面板：常驻树内缓存（打开只滑入，不重建列表 → 秒开）
  bool _tocOpen = false;
  final ScrollController _tocController = ScrollController();
  // 目录面板状态：tab（0 目录/1 书签/2 笔记）、排序、过滤、书签/笔记列表
  int _tocTab = 0;
  bool _tocReverse = false;
  String _tocFilter = '';
  final TextEditingController _tocSearchCtrl = TextEditingController();
  List<Bookmark> _tocBookmarks = const [];
  List<HighlightNote> _tocNotes = const [];

  /// 当前可用的章节列表（优先用动态 provider）
  List<Chapter> get _list => widget.chaptersProvider?.call() ?? widget.chapters;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _scrollCtrl.addListener(_onScrollChanged);
    _loadSettings();
    _loadChapter(_index);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _bgPlayer.dispose();
    _pageController.dispose();
    _tocController.dispose();
    _tocSearchCtrl.dispose();
    _scrollCtrl.dispose();
    _tick(); // 结算阅读时长
    // 退出阅读器：恢复系统状态栏显示
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _fontSize = sp.getDouble('reader_font_size') ?? 18;
      _lineHeight = sp.getDouble('reader_line_height') ?? 1.9;
      // 旧版本存的是 int，getDouble 可能类型不符 → 手动兼容转换
      final pg = sp.get('reader_para_gap');
      _paraGap = pg is int ? pg.toDouble() : (pg is double ? pg : 0.5);
      final fi = sp.getInt('reader_font_index') ?? 0;
      _fontFamily =
          ReaderPrefs.fontFamilies[fi.clamp(0, ReaderPrefs.fontFamilies.length - 1)];
      _brightness = sp.getDouble('reader_brightness') ?? 1.0;
      _turnMode = sp.getInt('reader_turn_mode') ?? 0;
      _autoNight = sp.getBool('reader_auto_night') ?? true;
      final bgIndex = sp.getInt('reader_bg') ?? 0;
      var bg = ReaderPrefs.bgOptions[bgIndex.clamp(0, ReaderPrefs.bgOptions.length - 1)];
      // 夜间自动：夜间时段且当前非暗色 → 强制夜间
      if (_autoNight && _isNightNow() && bg.computeLuminance() > 0.3) {
        bg = ReaderPrefs.bgOptions[2]; // 夜间
      }
      _bg = bg;
      _comicPage = sp.getBool('comic_page_mode') ?? false;
      _flipReverse = sp.getBool('reader_flip_dir') ?? false;
      _comicReadDir = sp.getBool('comic_read_dir') ?? false;
      _autoSec = sp.getInt('reader_auto_sec') ?? 10;
      _bgSound = sp.getBool('reader_bg_sound') ?? false;
      // 段首缩进固定开启（默认 true），两端对齐固定关闭（默认 false）
      _wallpaper = sp.getInt('reader_wallpaper') ?? 0;
      _wallpaperImg = sp.getString('reader_wallpaper_img') ?? '';
      // 左右边距：新键独立；旧合并键 reader_page_pad 迁移为左右相等
      final pl = sp.getDouble('reader_page_pad_left');
      final pr = sp.getDouble('reader_page_pad_right');
      if (pl != null || pr != null) {
        _pagePadLeft = pl ?? 20;
        _pagePadRight = pr ?? 20;
      } else {
        final old = sp.getDouble('reader_page_pad') ?? 20;
        _pagePadLeft = old;
        _pagePadRight = old;
      }
      _pagePadTop = sp.getDouble('reader_page_pad_top') ?? 6;
      _pagePadBottom = sp.getDouble('reader_page_pad_bottom') ?? 8;
      _immersive = sp.getBool('reader_immersive') ?? false;
    });
    if (_bgSound) _startBgSound();
    // 沉浸阅读：隐藏系统状态栏
    if (_immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  Future<void> _startBgSound() async {
    try {
      await _bgPlayer.setReleaseMode(ReleaseMode.loop);
      await _bgPlayer.setVolume(0.25);
      await _bgPlayer.play(AssetSource('audio/whitenoise.wav'));
    } catch (_) {}
  }

  bool _isNightNow() {
    final h = DateTime.now().hour;
    return h >= 21 || h < 7;
  }

  /// 累计阅读时长：把上一段时间写入持久化（切章 / 退出时调用）。
  Future<void> _tick() async {
    final now = DateTime.now();
    final ms = now.difference(_lastTick).inMilliseconds;
    _lastTick = now;
    if (ms < 0 || ms > 60 * 60 * 1000) return; // 防时钟回拨 / 长时间无操作
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('read_total_ms', (sp.getInt('read_total_ms') ?? 0) + ms);
    // 按天累计（阅读日历/图表）
    final day = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final dk = 'read_daily_$day';
    await sp.setInt(dk, (sp.getInt(dk) ?? 0) + ms);
  }

  /// 记录已读章节（去重，key = 书 + 章节索引）
  Future<void> _markRead(int i) async {
    final sp = await SharedPreferences.getInstance();
    final set = (sp.getStringList('read_chapters') ?? const []).toSet();
    set.add('${widget.book.bookUrl}#$i');
    await sp.setStringList('read_chapters', set.toList());
  }

  static const List<Color> _bgOptions = ReaderPrefs.bgOptions;

  /// 预载缓存：章节索引 -> 已取到的正文（翻页秒开，不转圈等网络）
  final Map<int, Content> _preloaded = {};

  /// 进行中的正文请求（预载与翻页并发时复用同一请求，不重复拉同一章）
  final Map<int, Future<Content>> _inflight = {};

  /// 取正文：优先预载缓存，其次复用进行中请求，否则网络。
  Future<Content> _contentFor(int i) {
    final list = _list;
    if (i < 0 || i >= list.length) {
      return Future.error(Exception('章节越界'));
    }
    final cached = _preloaded[i];
    if (cached != null) return Future.value(cached);
    final inflight = _inflight[i];
    if (inflight != null) return inflight;
    final source = SourceRegistry().byId(widget.book.sourceId);
    if (source == null) {
      return Future.error(Exception('找不到书源：${widget.book.sourceId}'));
    }
    final ch = list[i];
    // 优先磁盘缓存（离线可读），否则网络取回并写盘
    final f = ChapterCache.read(widget.book.bookUrl, ch.url).then((disk) async {
      if (disk != null) return disk;
      final c = await source.content(ch);
      ChapterCache.write(widget.book.bookUrl, ch.url, c);
      return c;
    });
    _inflight[i] = f;
    f.then((c) {
      _preloaded[i] = c; // 完成后入缓存，翻到时直接用
      if (_preloaded.length > 6) {
        // 只保留最近几章，避免缓存无限增长
        final first = _preloaded.keys.first;
        if (first != i) _preloaded.remove(first);
      }
    }).catchError((_) {}).whenComplete(() => _inflight.remove(i));
    return f;
  }

  Future<void> _loadChapter(int i) async {
    _tick(); // 结算上一段阅读时长
    final list = _list;
    if (i < 0 || i >= list.length) return;
    final hasCached = _preloaded.containsKey(i);
    setState(() {
      _index = i;
      _loading = !hasCached; // 命中预载缓存不转圈
      _error = null;
    });
    try {
      final content = await _contentFor(i);
      _preloaded.remove(i); // 当前章已显示，预存不再需要
      // 同步当前章书签状态
      final marked = await MarksService.isBookmarked(widget.book.bookUrl, i);
      if (mounted) {
        setState(() {
          _content = content;
          _loading = false;
          _bookmarked = marked;
          _scrollPercent = 0;
        });
        // 上下滑动切章：滚动回顶部
        if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
      }
      _markRead(i); // 记录已读章节
      // 记录进度（含已读章标题，供书架卡片显示）
      final library = LibraryService();
      await library.saveProgress(widget.book, i,
          chapterTitle: content.title.isNotEmpty ? content.title : null);
      // 后台预载后面 3 章
      for (var k = 1; k <= 3; k++) {
        _prefetch(i + k);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 后台预载第 j 章（失败静默；翻到它时若还没好会再走网络）。
  void _prefetch(int j) {
    final list = _list;
    if (j < 0 || j >= list.length) return;
    if (_preloaded.containsKey(j) || _inflight.containsKey(j)) return;
    _contentFor(j).then((_) {}, onError: (_) {});
  }

  void _next() => _loadChapter(_index + 1);
  void _prev() => _loadChapter(_index - 1);

  Future<void> _showSettings() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent, // 背景不变暗
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => ConstrainedBox(
          // 限制高度，避免内容过高时覆盖全屏
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          child: SingleChildScrollView(
            child: Glass(
              radius: 24,
              blur: 8,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题栏：设置 + 关闭按钮（避免全屏后无法返回）
                  Row(
                    children: [
                      const Expanded(
                        child: Text('阅读设置',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                // 沉浸阅读（隐藏状态栏）
                Row(
                  children: [
                    const Text('沉浸阅读'),
                    const Spacer(),
                    Switch(
                      value: _immersive,
                      onChanged: (v) async {
                        setState(() => _immersive = v);
                        setSheet(() => _immersive = v);
                        final sp = await SharedPreferences.getInstance();
                        await sp.setBool('reader_immersive', v);
                        if (v) {
                          SystemChrome.setEnabledSystemUIMode(
                              SystemUiMode.immersiveSticky);
                        } else {
                          SystemChrome.setEnabledSystemUIMode(
                              SystemUiMode.edgeToEdge);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 漫画：页漫 / 条漫
                if (_content?.isComic == true)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('页漫模式（左右翻页）'),
                    subtitle: const Text('关 = 条漫竖滑，开 = 逐页左右翻'),
                    value: _comicPage,
                    onChanged: (v) async {
                      setState(() => _comicPage = v);
                      setSheet(() => _comicPage = v);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setBool('comic_page_mode', v);
                    },
                  ),
                // 小说：划线笔记
                if (_content?.isComic == false)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('划线笔记模式'),
                    subtitle: const Text('开启后选中正文文字可记笔记'),
                    value: _noteMode,
                    onChanged: (v) {
                      setState(() => _noteMode = v);
                      setSheet(() => _noteMode = v);
                    },
                  ),
                // 漫画阅读方向（右往左）
                if (_content?.isComic == true)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('漫画阅读方向（右往左）'),
                    subtitle: const Text('开 = 右往左，日漫习惯'),
                    value: _comicReadDir,
                    onChanged: (v) async {
                      setState(() => _comicReadDir = v);
                      setSheet(() => _comicReadDir = v);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setBool('comic_read_dir', v);
                    },
                  ),
                // 自动阅读（定时翻页）
                Row(
                  children: [
                    const Text('自动阅读'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: _autoSec.toDouble(),
                        min: 5,
                        max: 30,
                        divisions: 5,
                        label: '每 $_autoSec 秒',
                        onChanged: (v) {
                          setState(() => _autoSec = v.round());
                          setSheet(() => _autoSec = v.round());
                          if (_autoReading) _restartAuto();
                          SharedPreferences.getInstance()
                              .then((sp) => sp.setInt('reader_auto_sec', _autoSec));
                        },
                      ),
                    ),
                    Switch(
                      value: _autoReading,
                      onChanged: (v) {
                        setState(() => _autoReading = v);
                        setSheet(() => _autoReading = v);
                        if (v) {
                          _restartAuto();
                        } else {
                          _autoTimer?.cancel();
                        }
                      },
                    ),
                  ],
                ),
                // 阅读背景音
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('阅读背景音'),
                  subtitle: const Text('白噪音循环（小声）'),
                  value: _bgSound,
                  onChanged: (v) async {
                    setState(() => _bgSound = v);
                    setSheet(() => _bgSound = v);
                    if (v) {
                      await _startBgSound();
                    } else {
                      await _bgPlayer.stop();
                    }
                    final sp = await SharedPreferences.getInstance();
                    await sp.setBool('reader_bg_sound', v);
                  },
                ),
                // 夜间自动切换
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('夜间自动切换'),
                  subtitle: const Text('21:00 - 7:00 自动用夜间主题'),
                  value: _autoNight,
                  onChanged: (v) async {
                    setState(() {
                      _autoNight = v;
                      if (v && _isNightNow() && _bg.computeLuminance() > 0.3) {
                        _bg = _bgOptions[2]; // 夜间
                      }
                    });
                    setSheet(() {});
                    final sp = await SharedPreferences.getInstance();
                    await sp.setBool('reader_auto_night', v);
                  },
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// 背景设置子面板：纸色背景 + 壁纸渐变（从设置弹窗移出）
  Future<void> _showBackgroundSettings() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          child: SingleChildScrollView(
            child: Glass(
              radius: 24,
              blur: 8,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('背景设置',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  // 背景（8 主题）
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                          padding: EdgeInsets.only(top: 8), child: Text('背景')),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var i = 0; i < _bgOptions.length; i++)
                              GestureDetector(
                                onTap: () async {
                                  setState(() => _bg = _bgOptions[i]);
                                  setSheet(() => _bg = _bgOptions[i]);
                                  final sp =
                                      await SharedPreferences.getInstance();
                                  await sp.setInt('reader_bg', i);
                                },
                                child: Container(
                                  width: 36,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: _bgOptions[i],
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: _bg == _bgOptions[i]
                                          ? Colors.blue
                                          : Colors.grey,
                                      width: _bg == _bgOptions[i] ? 2 : 1,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 亮度（屏幕视觉，与背景同类）
                  _sheetSlider('亮度', _brightness, 0.3, 1.0,
                      label: '${(_brightness * 100).round()}%',
                      onChanged: (v) async {
                    setState(() => _brightness = v);
                    setSheet(() => _brightness = v);
                    final sp = await SharedPreferences.getInstance();
                    await sp.setDouble('reader_brightness', v);
                  }),
                  const SizedBox(height: 12),
                  // 壁纸：图案渐变样例
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                          padding: EdgeInsets.only(top: 8), child: Text('壁纸')),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var i = 0;
                                i < ReaderPrefs.wallpapers.length;
                                i++)
                              GestureDetector(
                                onTap: () async {
                                  final p =
                                      await SharedPreferences.getInstance();
                                  await p.setInt('reader_wallpaper', i);
                                  await p.setString(
                                      'reader_wallpaper_img', '');
                                  setState(() {
                                    _wallpaper = i;
                                    _wallpaperImg = '';
                                  });
                                  setSheet(() {});
                                },
                                child: Container(
                                  width: 40,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    gradient: i == 0
                                        ? null
                                        : LinearGradient(
                                            colors: ReaderPrefs.wallpapers[i],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight),
                                    color: i == 0 ? Colors.white : null,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color:
                                          _wallpaperImg.isEmpty &&
                                                  _wallpaper == i
                                              ? Colors.blue
                                              : Colors.grey,
                                      width:
                                          _wallpaperImg.isEmpty &&
                                                  _wallpaper == i
                                              ? 2
                                              : 1,
                                    ),
                                  ),
                                  child: i == 0
                                      ? const Icon(Icons.block,
                                          size: 12, color: Colors.grey)
                                      : null,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // 自定义本地图片壁纸
                  Row(
                    children: [
                      const Text('自定义图片'),
                      const Spacer(),
                      if (_wallpaperImg.isNotEmpty)
                        IconButton(
                          tooltip: '删除自定义壁纸',
                          icon: const Icon(Icons.delete_outline,
                              size: 20, color: Color(0xFFE5484D)),
                          onPressed: () async {
                            final p = await SharedPreferences.getInstance();
                            await p.setString('reader_wallpaper_img', '');
                            await p.setInt('reader_wallpaper', 0);
                            setState(() {
                              _wallpaperImg = '';
                              _wallpaper = 0;
                            });
                            setSheet(() {});
                          },
                        ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final path = await _pickWallpaperImage();
                          if (path != null) {
                            setState(() => _wallpaperImg = path);
                            setSheet(() {});
                          }
                        },
                        icon: const Icon(Icons.add_photo_alternate_outlined,
                            size: 18),
                        label: Text(
                            _wallpaperImg.isEmpty ? '导入本地图片' : '更换图片'),
                      ),
                    ],
                  ),
                  if (_wallpaperImg.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(File(_wallpaperImg),
                            height: 120,
                            width: double.infinity,
                            fit: BoxFit.cover),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 选一张本地图片复制到应用文档目录，设为阅读壁纸，返回路径。
  Future<String?> _pickWallpaperImage() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    if (res == null || res.files.isEmpty) return null;
    final src = res.files.single;
    if (src.path == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/reader_wallpaper.png');
    await File(src.path!).copy(dest.path);
    final sp = await SharedPreferences.getInstance();
    await sp.setString('reader_wallpaper_img', dest.path);
    await sp.setInt('reader_wallpaper', 0);
    return dest.path;
  }

  /// 字体设置子面板：字号 / 行距 / 段距 / 间距 / 翻页 / 字体族
  Future<void> _showFontSettings() async {
    bool padOpen = false; // 「间距设置」展开
    bool turnOpen = false; // 「翻页设置」展开
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          child: SingleChildScrollView(
            child: Glass(
              radius: 24,
              blur: 8,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('界面设置',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  _sheetSlider('字号', _fontSize, 14, 28,
                      label: _fontSize.toStringAsFixed(0),
                      onChanged: (v) async {
                    setState(() => _fontSize = v);
                    setSheet(() => _fontSize = v);
                    final sp = await SharedPreferences.getInstance();
                    await sp.setDouble('reader_font_size', v);
                  }),
                  _sheetSlider('行距', _lineHeight, 1.0, 2.2,
                      label: _lineHeight.toStringAsFixed(2),
                      onChanged: (v) async {
                    setState(() => _lineHeight = v);
                    setSheet(() => _lineHeight = v);
                    final sp = await SharedPreferences.getInstance();
                    await sp.setDouble('reader_line_height', v);
                  }),
                  _sheetSlider('段距', _paraGap, 0, 3,
                      label: _paraGap.toStringAsFixed(1),
                      onChanged: (v) async {
                    setState(() => _paraGap = v);
                    setSheet(() => _paraGap = v);
                    final sp = await SharedPreferences.getInstance();
                    await sp.setDouble('reader_para_gap', v);
                  }),
                  const SizedBox(height: 8),
                  // 间距设置（可展开：左/右/上/下边距）
                  _sheetSectionButton('间距设置', padOpen,
                      onTap: () => setSheet(() => padOpen = !padOpen)),
                  if (padOpen) ...[
                    _sheetSlider('左边距', _pagePadLeft, 0, 60,
                        label: '${_pagePadLeft.round()}',
                        onChanged: (v) async {
                      setState(() => _pagePadLeft = v);
                      setSheet(() => _pagePadLeft = v);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setDouble('reader_page_pad_left', v);
                    }),
                    _sheetSlider('右边距', _pagePadRight, 0, 60,
                        label: '${_pagePadRight.round()}',
                        onChanged: (v) async {
                      setState(() => _pagePadRight = v);
                      setSheet(() => _pagePadRight = v);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setDouble('reader_page_pad_right', v);
                    }),
                    _sheetSlider('上边距', _pagePadTop, 0, 60,
                        label: '${_pagePadTop.round()}',
                        onChanged: (v) async {
                      setState(() => _pagePadTop = v);
                      setSheet(() => _pagePadTop = v);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setDouble('reader_page_pad_top', v);
                    }),
                    _sheetSlider('下边距', _pagePadBottom, 0, 60,
                        label: '${_pagePadBottom.round()}',
                        onChanged: (v) async {
                      setState(() => _pagePadBottom = v);
                      setSheet(() => _pagePadBottom = v);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setDouble('reader_page_pad_bottom', v);
                    }),
                    const SizedBox(height: 4),
                  ],
                  const SizedBox(height: 4),
                  // 翻页设置（可展开）
                  _sheetSectionButton('翻页设置', turnOpen,
                      onTap: () => setSheet(() => turnOpen = !turnOpen)),
                  if (turnOpen) ...[
                    Row(
                      children: [
                        const SizedBox(width: 16),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            children: [
                              for (var i = 0;
                                  i < ReaderPrefs.turnNames.length;
                                  i++)
                                ChoiceChip(
                                  label: Text(ReaderPrefs.turnNames[i]),
                                  labelStyle: const TextStyle(fontSize: 12),
                                  visualDensity: VisualDensity.compact,
                                  selected: _turnMode == i,
                                  onSelected: (_) async {
                                    setState(() => _turnMode = i);
                                    setSheet(() => _turnMode = i);
                                    final sp =
                                        await SharedPreferences.getInstance();
                                    await sp.setInt('reader_turn_mode', i);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _restartAuto() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(Duration(seconds: _autoSec), (_) {
      if (mounted) _nextPage();
    });
  }

  /// 设置弹窗里的滑杆行（标题 + 滑杆）。
  /// [divisions] 非空时滑杆按档位吸附，并拖动时显示数值气泡 [label]。
  Widget _sheetSlider(String title, double value, double min, double max,
      {required String label, required ValueChanged<double> onChanged}) {
    return Row(
      children: [
        Text(title),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            // 连续滑杆：不设 divisions，可自由拖动任意取值；
            // 当前值实时显示在右侧文字
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(label,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
        ),
      ],
    );
  }

  /// 设置弹窗里可展开分组按钮（标题 + 折叠箭头）。
  Widget _sheetSectionButton(String title, bool open,
      {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            Icon(open ? Icons.expand_less : Icons.expand_more,
                color: Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }

  /// 打/取消当前章书签
  Future<void> _toggleBookmark() async {
    final c = _content;
    if (c == null) return;
    final bm = Bookmark(
      book: widget.book,
      chapterIndex: _index,
      chapterTitle: c.title,
      time: DateTime.now(),
    );
    final messenger = ScaffoldMessenger.of(context);
    await MarksService.toggleBookmark(bm);
    final marked = !_bookmarked;
    if (mounted) setState(() => _bookmarked = marked);
    messenger.showSnackBar(
      SnackBar(
        content: Text(marked ? '已加书签：第${_index + 1}章' : '已取消书签'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 从选区记笔记（选中文字后点「记笔记」）
  Future<void> _addNoteFromSelection(String selected) async {
    final c = _content;
    if (c == null || selected.trim().isEmpty) return;
    final noteCtrl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => GlassDialog(
        child: Glass(
        radius: 20,
        blur: 18,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('记笔记',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(
              '“${selected.trim()}”',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '写点想法…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, noteCtrl.text),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
    if (note == null || note.trim().isEmpty) return;
    final now = DateTime.now();
    await MarksService.addNote(HighlightNote(
      id: now.microsecondsSinceEpoch.toRadixString(36),
      book: widget.book,
      chapterIndex: _index,
      chapterTitle: c.title,
      text: selected.trim(),
      note: note.trim(),
      time: now,
    ));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('笔记已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  /// 有效背景是否暗色（考虑壁纸渐变）
  bool _effDark() {
    final wp = _wallpaperColors;
    return ReaderPrefs.isDark(wp.isNotEmpty ? wp.first : _bg);
  }

  /// 当前壁纸渐变色（空 = 无壁纸，用纯色纸色）
  List<Color> get _wallpaperColors {
    if (_wallpaper <= 0 || _wallpaper >= ReaderPrefs.wallpapers.length) {
      return const [];
    }
    return ReaderPrefs.wallpapers[_wallpaper];
  }

  @override
  Widget build(BuildContext context) {
    final useWall = _wallpaperImg.isNotEmpty || _wallpaperColors.isNotEmpty;
    final dark = _effDark();
    final fg = dark ? const Color(0xFFB0B0B0) : const Color(0xFF333333);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
      backgroundColor: useWall ? Colors.transparent : _bg,
      body: Stack(
        children: [
          // 背景壁纸：本地图片 或 内置渐变
          if (useWall)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  image: _wallpaperImg.isNotEmpty
                      ? DecorationImage(
                          image: FileImage(File(_wallpaperImg)),
                          fit: BoxFit.cover,
                        )
                      : null,
                  gradient: _wallpaperImg.isEmpty &&
                          _wallpaperColors.isNotEmpty
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: _wallpaperColors,
                        )
                      : null,
                ),
              ),
            ),
          // 阅读内容：点左 1/3 上一章，右 1/3 下一章，中间切换控制栏
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _noteMode ? null : _handleTap,
              // 小说正文：向下快滑切换当前章书签（下拉添加 / 再下拉取消）
              onVerticalDragEnd: _content?.isComic == true
                  ? null
                  : (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v > 400) _toggleBookmark();
                    },
              // 菜单显示时禁用正文手势（滑动/缩放/双击），第一下点击先隐藏菜单
              child: IgnorePointer(
                ignoring: _showControls,
                child: _buildBody(fg),
              ),
            ),
          ),
          // 亮度遮罩（调暗阅读，不拦截点击；控制栏/面板在遮罩之上不受影响）
          if (_brightness < 0.999)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black
                      .withValues(alpha: (1 - _brightness) * 0.6),
                ),
              ),
            ),
          // 笔记模式提示条
          if (_noteMode)
            Positioned(
              top: 64,
              left: 0,
              right: 0,
              child: Center(
                child: Glass(
                  radius: 16,
                  blur: 18,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.edit_note,
                          size: 18, color: Color(0xFF3E8EF7)),
                      const SizedBox(width: 8),
                      Text(
                        '笔记模式：选中文字后点「记笔记」',
                        style: TextStyle(fontSize: 13, color: fg),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '退出笔记模式',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () =>
                            setState(() => _noteMode = false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 顶部：返回按钮随控制栏呼出（章节名不再常显，正文从顶部开始）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  // 呼出时：返回按钮（统一玻璃圆钮样式）
                  _fadeBar(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _roundBtn(Icons.arrow_back, '返回',
                            () => Navigator.of(context).pop(),
                            color: fg),
                      ),
                    ),
                  ),
                  // 右上角书签标签：仅已加书签时显示金色标签，未加不显示。
                  // 点击，或在正文向下快滑，添加/取消当前章书签。
                  if (_bookmarked)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6, top: 2),
                        child: InkWell(
                          onTap: _toggleBookmark,
                          customBorder: const CircleBorder(),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: const Icon(Icons.bookmark,
                                color: Color(0xFFE5A13A), size: 24),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 底部控制区：各控件独立玻璃组件（不再用整条玻璃面板）
          Positioned(
            bottom: 10,
            left: 16,
            right: 16,
            child: _fadeBar(
              child: SafeArea(top: false, child: _bottomBar(fg)),
            ),
          ),
          // 目录面板：常驻缓存（打开只滑入，不重建列表 → 秒开）
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_tocOpen,
              child: Stack(
                children: [
                  // 透明遮罩：点击关闭（不压暗阅读背景）
                  AnimatedOpacity(
                    opacity: _tocOpen ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _tocOpen = false),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // 玻璃目录面板：底部滑入
                  AnimatedSlide(
                    offset: _tocOpen ? Offset.zero : const Offset(0, 1),
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _tocPanel(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// 键盘快捷键：空格/→ 下一页，← 上一页，Esc 关目录面板。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.arrowRight) {
      _nextPage();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _prevPage();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _tocOpen) {
      setState(() => _tocOpen = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 左下角：整本百分比进度
  String _chapterPercentText() {
    final list = _list;
    if (list.isEmpty) return '';
    return '${((_index + 1) / list.length * 100).round()}%';
  }

  /// 控制栏显隐包装（淡入淡出 + 隐藏时不拦截点击）
  Widget _fadeBar({required Widget child}) {
    return IgnorePointer(
      ignoring: !_showControls,
      child: AnimatedOpacity(
        opacity: _showControls ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: child,
      ),
    );
  }

  /// 独立玻璃胶囊：白 0.42 填充 + 毛玻璃 blur 8 + 圆角 + 描边 + 投影。
  /// 样式与 _roundBtn / 设置弹窗 Glass 卡片统一。
  Widget _glassChip({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.55), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.42),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  /// 点击：左/中/右 1/3 区域各自执行配置动作（翻页/呼出菜单/目录/无）。
  void _handleTap(TapUpDetails d) {
    // 菜单显示时：第一下任意位置点击都先隐藏菜单，不翻页
    if (_showControls) {
      setState(() => _showControls = false);
      return;
    }
    final w = MediaQuery.of(context).size.width;
    final x = d.localPosition.dx;
    // 默认三区：左 1/3 上一页，右 1/3 下一页，中间呼出菜单
    if (x < w / 3) {
      _prevPage();
    } else if (x > w * 2 / 3) {
      _nextPage();
    } else {
      setState(() => _showControls = true);
    }
  }

  /// 下一页：章内翻屏，最后一屏翻到下一章第一屏。
  void _nextPage() {
    if (_content?.isComic == true) {
      _next(); // 漫画保持整话翻
      return;
    }
    if (_turnMode == 2) {
      _scrollPage(1); // 上下滑动：向下滚一屏
      return;
    }
    if (_pageIndex < _pages.length - 1) {
      _pageController.nextPage(
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      _pendingPage = 0;
      _next();
    }
  }

  /// 上一页：章内回屏，第一屏回到上一章最后一屏。
  void _prevPage() {
    if (_content?.isComic == true) {
      _prev(); // 漫画保持整话翻
      return;
    }
    if (_turnMode == 2) {
      _scrollPage(-1); // 上下滑动：向上滚一屏
      return;
    }
    if (_pageIndex > 0) {
      _pageController.previousPage(
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      _pendingPage = 1 << 30; // 定位到最后一屏
      _prev();
    }
  }

  /// 上下滑动：滚动一屏（dir 1 下 / -1 上）
  void _scrollPage(int dir) {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final target = (_scrollCtrl.offset + dir * pos.viewportDimension)
        .clamp(0.0, pos.maxScrollExtent);
    _scrollCtrl.animateTo(target,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  /// 上下滑动进度监听
  void _onScrollChanged() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final max = pos.maxScrollExtent;
    final p = max <= 0 ? 0.0 : (pos.pixels / max).clamp(0.0, 1.0);
    if ((p - _scrollPercent).abs() > 0.001) {
      setState(() => _scrollPercent = p);
    }
  }

  /// 底部控制区：上一章 | 进度条 | 下一章 + 圆钮（目录/设置）。
  /// 各控件独立玻璃化（[ _glassChip ] / [_roundBtn]），不再用整条玻璃面板。
  Widget _bottomBar(Color fg) {
    final list = _list;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上一章 | 进度条(缩短) | 下一章：各自独立玻璃胶囊
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _glassChip(
              child: TextButton(
                onPressed: _index > 0 ? _prev : null,
                child: Text('上一章', style: TextStyle(color: fg)),
              ),
            ),
            const SizedBox(width: 8),
            // 进度条占剩余宽度自适应，避免窄屏 Row 溢出截断
            Expanded(
              child: _glassChip(
                child: Slider(
                  value: _sliderDrag ?? _index.toDouble(),
                  min: 0,
                  max: (list.length - 1).clamp(1, 999999).toDouble(),
                  activeColor: const Color(0xFF3E8EF7),
                  onChanged: (v) => setState(() => _sliderDrag = v),
                  onChangeEnd: (v) {
                    setState(() => _sliderDrag = null);
                    final t = v.round();
                    if (t != _index) _loadChapter(t);
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            _glassChip(
              child: TextButton(
                onPressed: _index < list.length - 1 ? _next : null,
                child: Text('下一章', style: TextStyle(color: fg)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 圆钮：目录 / 字体 / 设置（独立玻璃圆钮，同级别）
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roundBtn(Icons.menu, '目录', _showToc),
            const SizedBox(width: 40),
            _roundBtn(Icons.tune, '界面', _showFontSettings),
            const SizedBox(width: 40),
            _roundBtn(Icons.palette_outlined, '背景', _showBackgroundSettings),
            const SizedBox(width: 40),
            _roundBtn(Icons.settings, '设置', _showSettings),
          ],
        ),
      ],
    );
  }

  /// 圆形玻璃按钮（仅图标，长按显示提示）。
  /// 样式与设置弹窗 Glass 卡片统一：白 0.42 填充 + 毛玻璃 blur 8 +
  /// 白 0.55 描边 + 投影。
  Widget _roundBtn(IconData icon, String tip, VoidCallback onTap,
      {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.55), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.42),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 打开目录：常驻面板已缓存，仅滑入 + 定位当前章（不重建列表 → 秒开）。
  void _showToc() {
    setState(() => _tocOpen = true);
    _loadTocMarks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_tocOpen || !_tocController.hasClients) return;
      final list = _list;
      if (list.isEmpty) return;
      final target = _tocReverse ? list.length - 1 - _index : _index;
      _tocController.jumpTo((target - 3).clamp(0, list.length - 1) * 48.0);
    });
  }

  /// 加载本书的书签/笔记（目录面板书签/笔记 tab 用）。
  Future<void> _loadTocMarks() async {
    final bms = await MarksService.getBookmarks();
    final notes = await MarksService.getNotes();
    if (!mounted) return;
    setState(() {
      _tocBookmarks = bms
          .where((b) => b.book.bookUrl == widget.book.bookUrl)
          .toList();
      _tocNotes = notes
          .where((n) => n.book.bookUrl == widget.book.bookUrl)
          .toList();
    });
  }

  /// 目录面板内容（常驻树内缓存，打开时不再重建）。
  /// 封面+书名+作者头部，目录/书签/笔记三 tab，正序下拉，章节列表，底部搜索。
  Widget _tocPanel() {
    final list = _list;
    final dark = _effDark();
    final fg = dark ? const Color(0xFFB0B0B0) : const Color(0xFF333333);
    const accent = Color(0xFF3E8EF7);
    return Glass(
      radius: 24,
      blur: 8,
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            // 封面 + 书名 + 作者
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 52,
                      height: 70,
                      child: widget.book.cover.isEmpty
                          ? Container(color: Colors.grey.shade300)
                          : CoverImage(widget.book.cover,
                              sourceId: widget.book.sourceId,
                              fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.book.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: fg)),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.person_outline,
                                size: 14, color: fg.withValues(alpha: 0.6)),
                            const SizedBox(width: 4),
                            Text(widget.book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13,
                                    color: fg.withValues(alpha: 0.6))),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // tab：目录 / 书签 / 笔记
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: dark ? 0.08 : 0.55),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    _tocTabBtn('目录', 0, Icons.menu, fg, accent, dark),
                    _tocTabBtn('书签', 1, Icons.bookmark_border, fg, accent, dark),
                    _tocTabBtn('笔记', 2, Icons.edit_note, fg, accent, dark),
                  ],
                ),
              ),
            ),
            // 目录 tab：共 X 章 + 正序下拉
            if (_tocTab == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Row(
                  children: [
                    Text('共 ${list.length} 章',
                        style: TextStyle(fontSize: 14, color: fg)),
                    const Spacer(),
                    DropdownButton<bool>(
                      value: _tocReverse,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: false, child: Text('正序')),
                        DropdownMenuItem(value: true, child: Text('倒序')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _tocReverse = v);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!_tocController.hasClients) return;
                          final t = v ? list.length - 1 - _index : _index;
                          _tocController.jumpTo(
                              (t - 3).clamp(0, list.length - 1) * 48.0);
                        });
                      },
                    ),
                  ],
                ),
              ),
            // 内容
            Expanded(
              child: _tocTab == 0
                  ? _tocChapterList(list, fg)
                  : _tocTab == 1
                      ? _tocBookmarkList(fg)
                      : _tocNoteList(fg),
            ),
            // 底部搜索（仅目录 tab）
            if (_tocTab == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: dark ? 0.08 : 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: TextField(
                    controller: _tocSearchCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search,
                          size: 18, color: fg.withValues(alpha: 0.6)),
                      hintText: '搜索标题',
                      hintStyle: TextStyle(
                          fontSize: 13, color: fg.withValues(alpha: 0.5)),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onChanged: (v) => setState(() => _tocFilter = v.trim()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tocTabBtn(String label, int tab, IconData icon, Color fg,
      Color accent, bool dark) {
    final sel = _tocTab == tab;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() => _tocTab = tab),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: sel ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: sel ? Colors.white : fg),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      color: sel ? Colors.white : fg)),
            ],
          ),
        ),
      ),
    );
  }

  /// 目录章节列表（支持正序/倒序 + 搜索过滤 + 当前章高亮 ✓）
  Widget _tocChapterList(List<Chapter> list, Color fg) {
    final ordered = _tocReverse ? list.reversed.toList() : list;
    final filtered = _tocFilter.isEmpty
        ? ordered
        : ordered
            .where((c) =>
                c.title.toLowerCase().contains(_tocFilter.toLowerCase()))
            .toList();
    if (filtered.isEmpty) {
      return Center(
        child: Text('没有匹配「$_tocFilter」的章节',
            style: TextStyle(color: fg.withValues(alpha: 0.6))),
      );
    }
    return ListView.builder(
      controller: _tocController,
      itemExtent: 48,
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final c = filtered[i];
        final allIndex = list.indexOf(c);
        final selected = allIndex == _index;
        return ListTile(
          dense: true,
          selected: selected,
          selectedTileColor:
              Theme.of(context).colorScheme.primaryContainer,
          title: Text(
            c.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : fg,
            ),
          ),
          trailing: selected
              ? Icon(Icons.check,
                  size: 16, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: () {
            setState(() => _tocOpen = false); // 关面板
            if (allIndex != _index) _loadChapter(allIndex);
          },
        );
      },
    );
  }

  /// 书签列表（本书）
  Widget _tocBookmarkList(Color fg) {
    if (_tocBookmarks.isEmpty) {
      return Center(
        child: Text('暂无书签',
            style: TextStyle(color: fg.withValues(alpha: 0.6))),
      );
    }
    return ListView.builder(
      itemCount: _tocBookmarks.length,
      itemBuilder: (context, i) {
        final bm = _tocBookmarks[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.bookmark, size: 16, color: Color(0xFFE5A13A)),
          title: Text(bm.chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: fg)),
          onTap: () {
            setState(() => _tocOpen = false);
            if (bm.chapterIndex != _index) _loadChapter(bm.chapterIndex);
          },
        );
      },
    );
  }

  /// 笔记列表（本书）
  Widget _tocNoteList(Color fg) {
    if (_tocNotes.isEmpty) {
      return Center(
        child: Text('暂无笔记',
            style: TextStyle(color: fg.withValues(alpha: 0.6))),
      );
    }
    return ListView.builder(
      itemCount: _tocNotes.length,
      itemBuilder: (context, i) {
        final n = _tocNotes[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.edit_note, size: 18, color: Color(0xFF3E8EF7)),
          title: Text(n.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: fg)),
          subtitle: n.note.isEmpty
              ? null
              : Text(n.note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, color: fg.withValues(alpha: 0.6))),
          onTap: () {
            setState(() => _tocOpen = false);
            if (n.chapterIndex != _index) _loadChapter(n.chapterIndex);
          },
        );
      },
    );
  }

  Widget _buildBody(Color fg) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text('加载失败：$_error',
                  textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _loadChapter(_index),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final c = _content;
    if (c == null) {
      return const Center(child: Text('暂无内容'));
    }
    if (c.isComic) {
      return _ComicView(
          book: widget.book,
          content: c,
          pageMode: _comicPage,
          reverse: _comicReadDir);
    }
    // 小说：分页阅读（左右翻屏，右下角显示本章进度）
    return _novelPaged(fg);
  }

  // ---------- 小说分页（左右翻页 + 本章进度） ----------

  /// 页眉章节名 + 间距 占用的高度（正文从其下方开始）
  static const double _headerH = 24;
  /// 页脚分页进度 + 间距 占用的高度
  static const double _footerH = 22;

  TextStyle _novelStyle(Color fg) => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        color: fg,
      );

  /// 当前章标题（无章节列表时为空）。
  String get _chapterTitle => _list.isEmpty ? '' : _list[_index].title;

  /// 每章第一页的大号加粗标题样式。
  TextStyle _chapterTitleStyle(Color fg) => TextStyle(
        fontSize: _fontSize + 4,
        height: _lineHeight,
        fontWeight: FontWeight.w700,
        color: fg,
      );

  /// 正文分页视图：每屏一段文字（滑动 / 覆盖两种翻页效果）。
  Widget _novelPaged(Color fg) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final safeTop = MediaQuery.of(context).padding.top;
        final size = Size(
          constraints.maxWidth - _pagePadLeft - _pagePadRight,
          constraints.maxHeight -
              safeTop -
              _headerH -
              _footerH -
              16 - // 进度行下方固定留白（不随边距调节）
              _pagePadTop -
              _pagePadBottom,
        );
        _reflow(fg, size);
        if (_pages.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        switch (_turnMode) {
          case 1:
            return _buildVerticalPager(fg); // 上下平移
          case 2:
            return _buildScrollViewer(fg); // 上下滑动（连续滚动）
          case 3:
            return _buildFlipPager(fg); // 仿真翻页
          default:
            return _buildHorizontalPager(fg); // 左右平移
        }
      },
    );
  }

  /// 左右平移：水平 PageView（原滑动）
  Widget _buildHorizontalPager(Color fg) {
    return PageView.builder(
      controller: _pageController,
      reverse: _flipReverse,
      physics: _noteMode
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: _pages.length,
      onPageChanged: (i) => setState(() => _pageIndex = i),
      itemBuilder: (context, i) => _pageText(i, fg),
    );
  }

  /// 上下平移：垂直 PageView
  Widget _buildVerticalPager(Color fg) {
    return PageView.builder(
      controller: _pageController,
      scrollDirection: Axis.vertical,
      physics: _noteMode
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: _pages.length,
      onPageChanged: (i) => setState(() => _pageIndex = i),
      itemBuilder: (context, i) => _pageText(i, fg),
    );
  }

  /// 上下滑动：整章连续滚动，不分页（页脚显示滚动百分比）
  Widget _buildScrollViewer(Color fg) {
    final paras = _decoratedParas(_content?.paras ?? const <String>[]);
    final gapPx = _paraGap * _fontSize * _lineHeight;
    final safeTop = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          _pagePadLeft, safeTop, _pagePadRight, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _list.isEmpty ? '' : _list[_index].title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.55)),
          ),
          SizedBox(height: _pagePadTop),
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollCtrl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 章首大号标题
                  if (_chapterTitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(_chapterTitle,
                          style: _chapterTitleStyle(fg)),
                    ),
                  for (var k = 0; k < paras.length; k++) ...[
                    if (k > 0) SizedBox(height: gapPx),
                    Text(
                      paras[k],
                      style: _novelStyle(fg),
                      textAlign: _justify
                          ? TextAlign.justify
                          : TextAlign.start,
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: _pagePadBottom),
          Row(
            children: [
              Text(
                _chapterPercentText(),
                style: TextStyle(
                    fontSize: 12, color: fg.withValues(alpha: 0.5)),
              ),
              const Spacer(),
              Text(
                '${(_scrollPercent * 100).round()}%',
                style: TextStyle(
                    fontSize: 12, color: fg.withValues(alpha: 0.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 仿真翻页：PageView 每页按偏移绕 Y 轴翻转
  Widget _buildFlipPager(Color fg) {
    return PageView.builder(
      controller: _pageController,
      physics: _noteMode
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: _pages.length,
      onPageChanged: (i) => setState(() => _pageIndex = i),
      itemBuilder: (context, i) => AnimatedBuilder(
        animation: _pageController,
        builder: (context, child) {
          final page = _pageController.position.haveDimensions
              ? (_pageController.page ?? _pageIndex.toDouble())
              : _pageIndex.toDouble();
          final delta = (page - i).clamp(-1.0, 1.0);
          final angle = delta * -0.9; // 弧度
          return Transform(
            alignment: delta > 0
                ? Alignment.centerLeft
                : Alignment.centerRight,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY(angle),
            child: child,
          );
        },
        child: _pageText(i, fg),
      ),
    );
  }

  /// 一屏正文（左右平移 / 上下平移 / 仿真翻页共用）
  Widget _pageText(int i, Color fg) {
    final page = i < _pages.length ? _pages[i] : null;
    // 每章第一页：正文前显示大号加粗章节标题
    final title = i == 0 ? _chapterTitle : '';
    final body = page == null
        ? const SizedBox()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(title, style: _chapterTitleStyle(fg)),
                ),
              for (var k = 0; k < page.segs.length; k++) ...[
                if (k > 0) SizedBox(height: page.gaps[k]),
                Text(page.segs[k],
                    style: _novelStyle(fg),
                    textAlign: _justify
                        ? TextAlign.justify
                        : TextAlign.start),
              ],
            ],
          );
    final safeTop = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          _pagePadLeft, safeTop, _pagePadRight, 16),
      // 整页一体：页眉章节名 + 正文 + 页脚分页进度，随翻页一起动
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _list.isEmpty ? '' : _list[_index].title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, color: fg.withValues(alpha: 0.55)),
          ),
          SizedBox(height: _pagePadTop),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: _noteMode
                  ? SelectionArea(
                      onSelectionChanged: (sel) {
                        if (sel != null) _selectedText = sel.plainText;
                      },
                      contextMenuBuilder: (context, state) =>
                          AdaptiveTextSelectionToolbar.buttonItems(
                        anchors: state.contextMenuAnchors,
                        buttonItems: [
                          ContextMenuButtonItem(
                            label: '记笔记',
                            onPressed: _selectedText.trim().isEmpty
                                ? null
                                : () => _addNoteFromSelection(_selectedText),
                          ),
                          ...state.contextMenuButtonItems,
                        ],
                      ),
                      child: body,
                    )
                  : body,
            ),
          ),
          SizedBox(height: _pagePadBottom),
          // 页脚：左整本进度，右本章分页进度（随页一体）
          Row(
            children: [
              Text(
                _chapterPercentText(),
                style: TextStyle(
                    fontSize: 12, color: fg.withValues(alpha: 0.5)),
              ),
              const Spacer(),
              Text(
                '${i + 1}/${_pages.length}',
                style: TextStyle(
                    fontSize: 12, color: fg.withValues(alpha: 0.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 重排分页：内容 / 字号 / 可用尺寸变化时重新计算 [pages]，
  /// 并按 [_pendingPage] 定位（跨章进入时跳到指定屏）。
  void _reflow(Color fg, Size size) {
    final c = _content;
    if (c == null || c.isComic) {
      _pages = const [];
      _reflowKey = null;
      return;
    }
    // 段距像素 = 段距 × 行高（0 = 无间距，1 = 一行高）
    final gapPx = _paraGap * _fontSize * _lineHeight;
    final paras = _decoratedParas(c.paras);
    // 每章第一页的大号标题：预留其高度，正文从标题下方开始
    final title = _chapterTitle;
    final titleStyle = _chapterTitleStyle(fg);
    final titleH = title.isEmpty
        ? 0.0
        : (TextPainter(
            text: TextSpan(text: title, style: titleStyle),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: size.width))
            .height;
    final key = '${paras.join('\n')}|$title|${_paraGap.toStringAsFixed(2)}|'
        '${_fontSize.toStringAsFixed(1)}|'
        '${_lineHeight.toStringAsFixed(2)}|${_fontFamily ?? ''}|'
        '$_indent|$_justify|'
        '${size.width.toStringAsFixed(1)}|${size.height.toStringAsFixed(1)}';
    if (key == _reflowKey) return; // 未变，不重排
    _reflowKey = key;
    _pages = _paginateParas(paras, _novelStyle(fg), size, gapPx,
        justify: _justify, firstPageReserve: titleH + 10);
    final target = _pendingPage ?? _pageIndex;
    _pendingPage = null;
    _pageIndex = target.clamp(0, _pages.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(_pageIndex);
      }
    });
  }

  /// 段首缩进装饰（缩进开启时每个段落前加两个全角空格）。
  List<String> _decoratedParas(List<String> paras) =>
      paras.map((p) => '${_indent ? '　　' : ''}$p').toList();

  /// 按段落像素分页：每页存段落片段列表 + 各段前间距。
  /// 段距可任意小数（SizedBox 像素），段落不跨页（单段超页高才截断）。
  /// [firstPageReserve]：第一页顶部预留高度（每章大号标题），正文从标题下开始。
  List<_NovelPage> _paginateParas(List<String> paras, TextStyle style,
      Size size, double gapPx,
      {bool justify = false, double firstPageReserve = 0}) {
    final pages = <_NovelPage>[];
    final segs = <String>[];
    final gaps = <double>[];
    var used = firstPageReserve; // 第一页预留标题高度
    var isFirst = true;

    void flush() {
      if (segs.isEmpty) return;
      pages.add(_NovelPage(List.of(segs), List.of(gaps)));
      segs.clear();
      gaps.clear();
      used = 0;
      isFirst = false;
    }

    for (final p in paras) {
      if (p.trim().isEmpty) continue; // 空段落跳过
      final tp = TextPainter(
        text: TextSpan(text: p, style: style),
        textDirection: TextDirection.ltr,
        textAlign: justify ? TextAlign.justify : TextAlign.start,
      )..layout(maxWidth: size.width);
      final h = tp.height;
      final need = h + (segs.isEmpty ? 0 : gapPx);
      if (segs.isNotEmpty && used + need > size.height) flush();
      // 第一页标题预留导致连一段都放不下 → 标题独占首页，正文从下一页开始
      if (segs.isEmpty && isFirst && used + h > size.height) {
        pages.add(_NovelPage(const [], const [0])); // 仅标题页
        isFirst = false;
        used = 0;
      }
      if (h > size.height) {
        // 单段超一页：该段单独截断分页（复用 _paginate）
        flush();
        for (final part in _paginate(p, style, size, justify: justify)) {
          pages.add(_NovelPage([part], [0]));
        }
        continue;
      }
      segs.add(p);
      gaps.add(segs.length == 1 ? 0 : gapPx);
      used += need;
    }
    flush();
    return pages.isEmpty ? [_NovelPage([''], [0])] : pages;
  }

  /// 用 TextPainter 把整章文本按可用宽高分成多页（每页字符范围子串）。
  List<String> _paginate(String fullText, TextStyle style, Size size,
      {bool justify = false}) {
    final tp = TextPainter(
      text: TextSpan(text: fullText, style: style),
      textDirection: TextDirection.ltr,
      textAlign: justify ? TextAlign.justify : TextAlign.start,
    )..layout(maxWidth: size.width);
    final lines = tp.computeLineMetrics();
    if (lines.isEmpty) return [fullText];
    final pages = <String>[];
    var start = 0;
    var used = 0.0;
    for (final line in lines) {
      final h = line.height;
      if (used + h > size.height && used > 0) {
        final cut = tp
            .getPositionForOffset(Offset(0, line.baseline - line.ascent))
            .offset;
        if (cut > start) {
          pages.add(fullText.substring(start, cut));
          start = cut;
          used = 0;
        }
      }
      used += h;
    }
    if (start < fullText.length) pages.add(fullText.substring(start));
    return pages.isEmpty ? [fullText] : pages;
  }
}

/// 一页小说正文：段落片段列表 + 各段前间距（像素，首段为 0）。
/// 段距任意小数通过 [SizedBox] 实现，替代整数空行。
class _NovelPage {
  final List<String> segs;
  final List<double> gaps;
  const _NovelPage(this.segs, this.gaps);
}

/// 漫画内容视图：条漫（竖滑）/ 页漫（左右翻）两种模式，均可双击缩放。
class _ComicView extends StatelessWidget {
  final Book book;
  final Content content;
  final bool pageMode;

  /// 右往左翻（日漫习惯）
  final bool reverse;
  const _ComicView({
    required this.book,
    required this.content,
    required this.pageMode,
    this.reverse = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? const Color(0xFFB0B0B0) : const Color(0xFF333333);

    Widget img(int i) => _ZoomableImage(
          child: _ComicImage(
            url: content.pages[i],
            sourceId: book.sourceId,
            fg: fg,
            index: i,
            total: content.pages.length,
          ),
        );

    // 页漫：逐页左右翻，图居中（顶部避开常显顶栏）
    if (pageMode) {
      return PageView.builder(
        reverse: reverse,
        itemCount: content.pages.length,
        itemBuilder: (context, i) => Padding(
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 8),
          child: Center(child: img(i)),
        ),
      );
    }

    // 条漫：竖滑列表
    return ListView.builder(
      // 上下留白，让首/末图不被浮动控制栏遮住
      padding: const EdgeInsets.fromLTRB(0, 68, 0, 80),
      itemCount: content.pages.length,
      itemBuilder: (context, i) => img(i),
    );
  }
}

/// 单图可缩放包装：双击放大 2 倍（再双击还原），放大后可拖动平移。
class _ZoomableImage extends StatefulWidget {
  final Widget child;
  const _ZoomableImage({required this.child});

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _tc = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTc);
  }

  @override
  void dispose() {
    _tc.removeListener(_onTc);
    _tc.dispose();
    super.dispose();
  }

  void _onTc() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.01;
    if (z != _zoomed) setState(() => _zoomed = z);
  }

  void _toggleZoom() {
    if (_zoomed) {
      _tc.value = Matrix4.identity();
    } else {
      _tc.value = Matrix4.diagonal3Values(2.0, 2.0, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 4,
        // 未放大时不拦截手势，让外层列表/翻页正常滚动
        panEnabled: _zoomed,
        scaleEnabled: _zoomed,
        child: widget.child,
      ),
    );
  }
}

/// 单张漫画图：直接网络加载（本地书走 locimg://）。
class _ComicImage extends StatelessWidget {
  final String url;
  final String? sourceId;
  final Color fg;
  final int index;
  final int total;
  const _ComicImage({
    required this.url,
    this.sourceId,
    required this.fg,
    required this.index,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    if (url.startsWith('locimg://')) {
      return _LocalImage(url: url, fg: fg, index: index, total: total);
    }
    return Column(
      children: [
        CoverImage(
          url,
          sourceId: sourceId,
          fit: BoxFit.fitWidth,
          cache: false, // 大图不缓存，避免内存膨胀
          loadingWidget: const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
        if (index < total - 1) const Divider(height: 1),
      ],
    );
  }
}

/// 本地漫画图片：从应用目录读文件 → 显示。
class _LocalImage extends StatefulWidget {
  final String url;
  final Color fg;
  final int index;
  final int total;
  const _LocalImage({
    required this.url,
    required this.fg,
    required this.index,
    required this.total,
  });

  @override
  State<_LocalImage> createState() => _LocalImageState();
}

class _LocalImageState extends State<_LocalImage> {
  late Future<(List<int>, String)> _future;

  @override
  void initState() {
    super.initState();
    _future = LocalBookSource.readPage(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FutureBuilder<(List<int>, String)>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Container(
                height: 120,
                alignment: Alignment.center,
                color: Colors.grey.shade200,
                child: Text('读取失败：${snap.error}',
                    style: TextStyle(color: widget.fg, fontSize: 12)),
              );
            }
            final (bytes, _) = snap.data!;
            return Image.memory(
              Uint8List.fromList(bytes),
              fit: BoxFit.fitWidth,
              errorBuilder: (_, _, _) => Container(
                height: 120,
                alignment: Alignment.center,
                color: Colors.grey.shade200,
                child: Text('图片解码失败',
                    style: TextStyle(color: widget.fg, fontSize: 12)),
              ),
            );
          },
        ),
        if (widget.index < widget.total - 1) const Divider(height: 1),
      ],
    );
  }
}


