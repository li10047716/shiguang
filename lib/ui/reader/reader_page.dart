/// 阅读器：正文加载、上下章切换、字号/背景设置。
///
/// 小说与漫画共用：小说渲染段落文本，漫画渲染图片列表。
/// 漫画源图片地址直接网络加载；本地书（locimg://）从应用目录读取。
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  int _paraGap = 1; // 段距（段落间额外空行数 0-3）
  String? _fontFamily; // 字体（null = 系统默认）
  double _brightness = 1.0; // 亮度（1 = 无遮罩，越低越暗）
  int _turnMode = 0; // 翻页效果：0 滑动 / 1 覆盖
  bool _autoNight = true; // 夜间自动切换（21:00-7:00）
  bool _indent = true; // 段首缩进
  bool _justify = false; // 两端对齐
  int _wallpaper = 0; // 背景壁纸（0 = 无）

  // 覆盖翻页动画
  late final AnimationController _coverAnim;
  int _coverTarget = 0;
  int _coverDir = 1;

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
  List<String> _pages = const []; // 当前章分页文本
  String? _reflowKey; // 分页指纹（内容/字号/尺寸变则重排）
  int? _pendingPage; // 跨章进入时定位（prev 进章 → 最后一页）

  /// 翻页方向：true = 从右到左（点右翻页仍是下一页，仅 PageView 视觉反向）
  bool _flipReverse = false;

  /// 进度条拖动中的临时值（松手才跳章）
  double? _sliderDrag;

  /// 目录面板：常驻树内缓存（打开只滑入，不重建列表 → 秒开）
  bool _tocOpen = false;
  final ScrollController _tocController = ScrollController();

  /// 当前可用的章节列表（优先用动态 provider）
  List<Chapter> get _list => widget.chaptersProvider?.call() ?? widget.chapters;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _coverAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 240));
    _loadSettings();
    _loadChapter(_index);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _bgPlayer.dispose();
    _pageController.dispose();
    _tocController.dispose();
    _coverAnim.dispose();
    _tick(); // 结算阅读时长
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _fontSize = sp.getDouble('reader_font_size') ?? 18;
      _lineHeight = sp.getDouble('reader_line_height') ?? 1.9;
      _paraGap = sp.getInt('reader_para_gap') ?? 1;
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
        bg = ReaderPrefs.bgOptions[3];
      }
      _bg = bg;
      _comicPage = sp.getBool('comic_page_mode') ?? false;
      _flipReverse = sp.getBool('reader_flip_dir') ?? false;
      _comicReadDir = sp.getBool('comic_read_dir') ?? false;
      _autoSec = sp.getInt('reader_auto_sec') ?? 10;
      _bgSound = sp.getBool('reader_bg_sound') ?? false;
      _indent = sp.getBool('reader_indent') ?? true;
      _justify = sp.getBool('reader_justify') ?? false;
      _wallpaper = sp.getInt('reader_wallpaper') ?? 0;
    });
    if (_bgSound) _startBgSound();
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
        });
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
        builder: (context, setSheet) => SingleChildScrollView(
          child: Glass(
            radius: 24,
            blur: 8,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 书签当前章
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _bookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: _bookmarked ? const Color(0xFFE5A13A) : null,
                  ),
                  title: Text(_bookmarked ? '取消当前章书签' : '加当前章书签'),
                  onTap: () {
                    Navigator.pop(context);
                    _toggleBookmark();
                  },
                ),
                _sheetSlider('字号', _fontSize, 14, 28,
                    label: _fontSize.toStringAsFixed(0), onChanged: (v) async {
                  setState(() => _fontSize = v);
                  setSheet(() => _fontSize = v);
                  final sp = await SharedPreferences.getInstance();
                  await sp.setDouble('reader_font_size', v);
                }),
                _sheetSlider('行距', _lineHeight, 1.4, 2.4,
                    label: _lineHeight.toStringAsFixed(2),
                    onChanged: (v) async {
                  setState(() => _lineHeight = v);
                  setSheet(() => _lineHeight = v);
                  final sp = await SharedPreferences.getInstance();
                  await sp.setDouble('reader_line_height', v);
                }),
                _sheetSlider('段距', _paraGap.toDouble(), 0, 3,
                    label: _paraGap.toString(), onChanged: (v) async {
                  setState(() => _paraGap = v.round());
                  setSheet(() => _paraGap = v.round());
                  final sp = await SharedPreferences.getInstance();
                  await sp.setInt('reader_para_gap', v.round());
                }),
                // 字体
                Row(
                  children: [
                    const Text('字体'),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (var i = 0;
                              i < ReaderPrefs.fontNames.length;
                              i++)
                            ChoiceChip(
                              label: Text(ReaderPrefs.fontNames[i]),
                              labelStyle: const TextStyle(fontSize: 12),
                              visualDensity: VisualDensity.compact,
                              selected: ReaderPrefs.fontFamilies[i] ==
                                  _fontFamily,
                              onSelected: (_) async {
                                setState(() =>
                                    _fontFamily = ReaderPrefs.fontFamilies[i]);
                                setSheet(() =>
                                    _fontFamily = ReaderPrefs.fontFamilies[i]);
                                final sp =
                                    await SharedPreferences.getInstance();
                                await sp.setInt('reader_font_index', i);
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
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
                // 壁纸（渐变背景）
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
                                setState(() => _wallpaper = i);
                                setSheet(() => _wallpaper = i);
                                final sp =
                                    await SharedPreferences.getInstance();
                                await sp.setInt('reader_wallpaper', i);
                              },
                              child: Container(
                                width: 36,
                                height: 26,
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
                                    color: _wallpaper == i
                                        ? Colors.blue
                                        : Colors.grey,
                                    width: _wallpaper == i ? 2 : 1,
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
                const SizedBox(height: 8),
                // 排版：段首缩进 / 两端对齐
                Row(
                  children: [
                    const Text('段首缩进'),
                    const Spacer(),
                    Switch(
                      value: _indent,
                      onChanged: (v) async {
                        setState(() => _indent = v);
                        setSheet(() => _indent = v);
                        final sp = await SharedPreferences.getInstance();
                        await sp.setBool('reader_indent', v);
                      },
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Text('两端对齐'),
                    const Spacer(),
                    Switch(
                      value: _justify,
                      onChanged: (v) async {
                        setState(() => _justify = v);
                        setSheet(() => _justify = v);
                        final sp = await SharedPreferences.getInstance();
                        await sp.setBool('reader_justify', v);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _sheetSlider('亮度', _brightness, 0.3, 1.0,
                    label: '${(_brightness * 100).round()}%',
                    onChanged: (v) async {
                  setState(() => _brightness = v);
                  setSheet(() => _brightness = v);
                  final sp = await SharedPreferences.getInstance();
                  await sp.setDouble('reader_brightness', v);
                }),
                // 翻页效果
                Row(
                  children: [
                    const Text('翻页'),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (var i = 0; i < ReaderPrefs.turnNames.length; i++)
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
                const SizedBox(height: 8),
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
                        _bg = _bgOptions[3];
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
    );
  }

  void _restartAuto() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(Duration(seconds: _autoSec), (_) {
      if (mounted) _nextPage();
    });
  }

  /// 设置弹窗里的滑杆行（标题 + 滑杆）
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
            label: label,
            onChanged: onChanged,
          ),
        ),
      ],
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
    final useWall = _wallpaperColors.isNotEmpty;
    final dark = _effDark();
    final fg = dark ? const Color(0xFFB0B0B0) : const Color(0xFF333333);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
      backgroundColor: useWall ? Colors.transparent : _bg,
      body: Stack(
        children: [
          // 背景壁纸（渐变）
          if (useWall)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: _wallpaperColors,
                  ),
                ),
              ),
            ),
          // 阅读内容：点左 1/3 上一章，右 1/3 下一章，中间切换控制栏
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _noteMode ? null : _handleTap,
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
          // 顶部：章节名常显居中（阅读界面内，透明）+ 返回按钮随控制栏呼出
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  // 常显章节名（居中）
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: Text(
                        _list.isEmpty ? '' : _list[_index].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: fg),
                      ),
                    ),
                  ),
                  // 呼出时：返回按钮（独立玻璃圆钮，不再整条毛玻璃）
                  _fadeBar(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: InkWell(
                          onTap: () => Navigator.of(context).pop(),
                          customBorder: const CircleBorder(),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(
                                  alpha: dark ? 0.20 : 0.45),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.55),
                                  width: 1),
                            ),
                            child: Icon(Icons.arrow_back, color: fg, size: 20),
                          ),
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
          // 角落进度（常显，悬浮面板之上）：左下整本百分比 / 右下本章分页进度
          Positioned(
            left: 20,
            bottom: 8,
            child: IgnorePointer(
              child: Text(
                _chapterPercentText(),
                style: TextStyle(
                    fontSize: 12, color: fg.withValues(alpha: 0.5)),
              ),
            ),
          ),
          Positioned(
            right: 20,
            bottom: 8,
            child: IgnorePointer(
              child: Text(
                _pageProgressText(),
                style: TextStyle(
                    fontSize: 12, color: fg.withValues(alpha: 0.5)),
              ),
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

  /// 右下角：本章分页进度（当前屏/总屏）
  String _pageProgressText() {
    if (_content?.isComic == true) return '';
    if (_pages.isEmpty) return '';
    return '${_pageIndex + 1}/${_pages.length}';
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

  /// 独立玻璃胶囊：半透明白 + 圆角 + 高光描边（控件各自玻璃化，不占整条）。
  /// [alpha] 越小越透；夜间背景用更低不透明度。
  Widget _glassChip({required Widget child, required double alpha}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(22),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1),
      ),
      child: child,
    );
  }

  /// 点击：左/右 1/3 翻页（章内翻屏，翻到章首/章尾再切章），中间切换控制栏显隐。
  void _handleTap(TapUpDetails d) {
    // 菜单显示时：第一下任意位置点击都先隐藏菜单，不翻页
    if (_showControls) {
      setState(() => _showControls = false);
      return;
    }
    final w = MediaQuery.of(context).size.width;
    final x = d.localPosition.dx;
    if (x < w / 3) {
      _prevPage();
    } else if (x > w * 2 / 3) {
      _nextPage();
    } else {
      // 菜单隐藏时：点中间呼出菜单
      setState(() => _showControls = true);
    }
  }

  /// 下一页：章内翻屏，最后一屏翻到下一章第一屏。
  void _nextPage() {
    if (_content?.isComic == true) {
      _next(); // 漫画保持整话翻
      return;
    }
    if (_turnMode == 1) {
      _coverFlip(1);
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
    if (_turnMode == 1) {
      _coverFlip(-1);
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

  /// 底部控制区：上一章 | 进度条 | 下一章 + 圆钮（目录/设置）。
  /// 各控件独立玻璃化（[ _glassChip ] / [_roundBtn]），不再用整条玻璃面板。
  Widget _bottomBar(Color fg) {
    final list = _list;
    final dark = _effDark();
    final alpha = dark ? 0.20 : 0.45;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上一章 | 进度条(缩短) | 下一章：各自独立玻璃胶囊
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _glassChip(
              alpha: alpha,
              child: TextButton(
                onPressed: _index > 0 ? _prev : null,
                child: Text('上一章', style: TextStyle(color: fg)),
              ),
            ),
            const SizedBox(width: 10),
            _glassChip(
              alpha: alpha,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
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
            const SizedBox(width: 10),
            _glassChip(
              alpha: alpha,
              child: TextButton(
                onPressed: _index < list.length - 1 ? _next : null,
                child: Text('下一章', style: TextStyle(color: fg)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 圆钮：目录 / 设置（独立玻璃圆钮）
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roundBtn(Icons.menu, '目录', _showToc),
            const SizedBox(width: 56),
            _roundBtn(Icons.settings, '设置', _showSettings),
          ],
        ),
      ],
    );
  }

  /// 圆形玻璃按钮（图标 + 下方小字）
  Widget _roundBtn(IconData icon, String tip, VoidCallback onTap,
      {Color? color}) {
    final dark = _effDark();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: dark ? 0.20 : 0.45),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.55), width: 1),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            tip,
            style: TextStyle(
                fontSize: 10, color: (color ?? Colors.grey.shade600)),
          ),
        ],
      ),
    );
  }

  /// 打开目录：常驻面板已缓存，仅滑入 + 定位当前章（不重建列表 → 秒开）。
  void _showToc() {
    setState(() => _tocOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_tocOpen || !_tocController.hasClients) return;
      final list = _list;
      if (list.isEmpty) return;
      _tocController.jumpTo((_index - 3).clamp(0, list.length - 1) * 48.0);
    });
  }

  /// 目录面板内容（常驻树内缓存，打开时不再重建）。
  Widget _tocPanel() {
    final list = _list;
    final dark = _effDark();
    final fg = dark ? const Color(0xFFB0B0B0) : const Color(0xFF333333);
    final sel = _index;
    return Glass(
      radius: 24,
      blur: 8,
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF3E8EF7).withValues(alpha: 0.14),
              child: Text(
                '目录（${list.length} 章）',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: fg),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _tocController,
                itemExtent: 48,
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final selected = i == sel;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    selectedTileColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    title: Text(
                      list[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : fg,
                      ),
                    ),
                    onTap: () {
                      setState(() => _tocOpen = false); // 关面板
                      if (i != _index) _loadChapter(i);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
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

  static const double _pagePadH = 20;
  static const double _pagePadV = 24;

  /// 常显顶栏（返回+章节名）占用的顶部高度，正文要避开
  static const double _topBarH = 52;

  TextStyle _novelStyle(Color fg) => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        color: fg,
        fontFamily: _fontFamily,
      );

  /// 正文分页视图：每屏一段文字（滑动 / 覆盖两种翻页效果）。
  Widget _novelPaged(Color fg) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth - _pagePadH * 2,
          constraints.maxHeight - _topBarH - _pagePadV,
        );
        _reflow(fg, size);
        if (_pages.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_turnMode == 1) return _buildCoverPager(fg);
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
      },
    );
  }

  /// 覆盖翻页：当前页固定，下一页从右（或反向）盖上来。点击左右 1/3 翻页。
  Widget _buildCoverPager(Color fg) {
    return AnimatedBuilder(
      animation: _coverAnim,
      builder: (context, _) {
        final w = MediaQuery.of(context).size.width;
        final s = _flipReverse ? -1.0 : 1.0;
        final dx = (1 - _coverAnim.value) * w * s * _coverDir;
        return Stack(
          children: [
            Positioned.fill(child: _pageText(_pageIndex, fg)),
            if (_coverAnim.isAnimating)
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(dx, 0),
                  child: _pageText(_coverTarget, fg),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 一屏正文（滑动 / 覆盖共用）
  Widget _pageText(int i, Color fg) {
    final text = Text(_pages[i],
        style: _novelStyle(fg),
        textAlign: _justify ? TextAlign.justify : TextAlign.start);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          _pagePadH, _topBarH, _pagePadH, _pagePadV),
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
                child: text,
              )
            : text,
      ),
    );
  }

  /// 覆盖翻页：驱动动画，章首/章尾则切章。
  void _coverFlip(int dir) {
    final target = _pageIndex + dir;
    if (target < 0 || target >= _pages.length) {
      if (dir > 0) {
        _pendingPage = 0;
        _next();
      } else {
        _pendingPage = 1 << 30;
        _prev();
      }
      return;
    }
    setState(() {
      _coverTarget = target;
      _coverDir = dir;
    });
    _coverAnim.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _pageIndex = target);
    });
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
    final gap = '\n' * (2 + _paraGap); // 段距：段落间空行数（基础 1 空行 + 调节）
    final fullText = c.paras
        .map((p) => '${_indent ? '　　' : ''}$p')
        .join(gap);
    final key = '$fullText|${_fontSize.toStringAsFixed(1)}|'
        '${_lineHeight.toStringAsFixed(2)}|${_fontFamily ?? ''}|'
        '$_indent|$_justify|'
        '${size.width.toStringAsFixed(1)}|${size.height.toStringAsFixed(1)}';
    if (key == _reflowKey) return; // 未变，不重排
    _reflowKey = key;
    _pages = _paginate(fullText, _novelStyle(fg), size, justify: _justify);
    final target = _pendingPage ?? _pageIndex;
    _pendingPage = null;
    _pageIndex = target.clamp(0, _pages.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(_pageIndex);
      }
    });
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
          padding: const EdgeInsets.only(top: _ReaderPageState._topBarH),
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


