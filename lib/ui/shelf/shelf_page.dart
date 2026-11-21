/// 书架首页。
///
/// 布局对应 shiguang 书架：顶部「书架」标题 + 右侧工具栏
/// （全部▾筛选 / 网格·列表切换 / 搜索 / 更多），下方三列横向书卡
/// （封面在左带「小说」角标，信息在右：书名/作者/已读/来源/最新章节）。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../services/library.dart';
import '../../services/toc_cache.dart';
import '../../sources/native/localbook.dart';
import '../../sources/source_registry.dart';
import '../book/book_detail_page.dart';
import '../glass.dart';
import '../reader/open_reader.dart';
import '../search/search_page.dart';
import '../widgets/cover_image.dart';
import '../widgets/glass_menu.dart';

class ShelfPage extends ConsumerStatefulWidget {
  const ShelfPage({super.key});

  @override
  ConsumerState<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends ConsumerState<ShelfPage> {
  static const _progressPrefix = 'progress_';
  static const _progressTitlePrefix = 'progress_title_';
  static const _progressTimePrefix = 'progress_time_';

  bool _listView = false;
  Map<String, int> _progress = {};
  Map<String, String> _progressTitles = {};

  // 书架分组：分组名列表 + 每本书所属分组 + 当前过滤组
  List<String> _groups = [];
  Map<String, String> _groupOf = {};
  String? _groupFilter;

  // ---------- 书架管理模式（书架页内操作，不跳转独立页面） ----------
  bool _manageMode = false;
  final Set<String> _mSelected = {};
  int _sortMode = -1; // -1 未选（保持加入顺序）0 最近阅读 1 书名
  Map<String, int> _times = {};
  static const _sortNames = ['最近阅读', '书名'];

  // 书架网格滚动控制器（卡片列表用）
  final ScrollController _scrollCtrl = ScrollController();

  // 下拉检查更新：书卡跟手下移 + 松手回弹
  double _pullRaw = 0;
  double _pullOffset = 0;
  bool _pullReleasing = false;
  bool _pullRefreshing = false;
  Timer? _pullReleaseTimer;

  /// 正在检查更新的书（bookUrl），用于封面转圈提示
  final Set<String> _checkingBooks = {};
  static const _pullMax = 96.0;
  static const _pullTrigger = 60.0;

  @override
  void initState() {
    super.initState();
    ref.read(libraryProvider.notifier).load();
    _loadProgress();
    _loadGroups();
  }

  @override
  void dispose() {
    _pullReleaseTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 书架增删（导入/删除）后刷新进度
    ref.listen<List<Book>>(libraryProvider, (prev, next) {
      _loadProgress();
    });

    final books = _visibleBooks(ref.watch(libraryProvider));

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              // 书籍卡片铺满（顶部预留悬浮胶囊高度，避免首卡被压住）
              // 下拉检查更新：书卡跟手下移，松手回弹
              Positioned.fill(
                child: books.isEmpty
                    ? _empty()
                    : NotificationListener<ScrollNotification>(
                        onNotification: _onShelfPullNotification,
                        child: AnimatedContainer(
                          duration: _pullReleasing || _pullRefreshing
                              ? const Duration(milliseconds: 220)
                              : Duration.zero,
                          curve: Curves.easeOut,
                          transform:
                              Matrix4.translationValues(0, _pullOffset, 0),
                          child: ScrollConfiguration(
                            // 桌面端默认鼠标拖拽不滚动，启用鼠标/触屏拖拽，
                            // 才能在顶部产生跟手下拉效果。
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.stylus,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: _grid(books),
                          ),
                        ),
                      ),
              ),
              // 下拉提示：文字浮在顶部空白处，书卡下移时渐显
              if (_pullOffset > 2 || _pullRefreshing)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _pullRefreshing
                          ? 1
                          : (_pullOffset / 40).clamp(0.0, 1.0),
                      duration: const Duration(milliseconds: 100),
                      child: Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_pullRefreshing)
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                ),
                              )
                            else
                              Icon(
                                _pullRaw >= _pullTrigger
                                    ? Icons.update
                                    : Icons.keyboard_arrow_down,
                                size: 16,
                                color:
                                    Theme.of(context).colorScheme.onPrimary,
                              ),
                            const SizedBox(width: 6),
                            Text(
                              _pullRefreshing
                                  ? '正在检查更新…'
                                  : _pullRaw >= _pullTrigger
                                      ? '松开检查更新'
                                      : '下拉检查更新',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.onPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // 顶部：左侧搜索框 + 右侧工具栏（全部▾ / 视图 / ⋮）
              if (!_manageMode)
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: Row(
                    children: [
                      SizedBox(
                        width: MediaQuery.of(context).size.width < 520
                            ? 150
                            : 240,
                        child: _searchBox(),
                      ),
                      const Spacer(),
                      _topCapsule(),
                    ],
                  ),
                ),
              // 管理模式顶部悬浮栏：返回 / 排序 / 清空 / 全选 / 删除
              if (_manageMode)
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _manageBar(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Ctrl+F 打开书源搜索
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyF &&
        HardwareKeyboard.instance.isControlPressed) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SearchPage()),
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------- 书架分组 ----------

  Future<void> _loadGroups() async {
    final sp = await SharedPreferences.getInstance();
    final groups = sp.getStringList('book_groups') ?? const [];
    final groupOf = <String, String>{};
    for (final k in sp.getKeys()) {
      if (k.startsWith('book_group_')) {
        final v = sp.getString(k);
        if (v != null) groupOf[k.substring('book_group_'.length)] = v;
      }
    }
    if (mounted) {
      setState(() {
        _groups = groups;
        _groupOf = groupOf;
      });
    }
  }


  /// 长按卡片：书籍操作面板（封面 + 信息 + 功能图标 + 列表 + 删除）。
  /// 只放本应用已有的功能：书本详情 / 更换书源 / 移动分组 / 删除书籍。
  Future<void> _showBookMenu(Book b) async {
    final group = _groupOf[b.bookUrl];
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (context) => FlatCard(
        radius: 24,
        blur: 3,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部：封面 + 书名/作者/来源/分组
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 56,
                    height: 74,
                    child: b.cover.isEmpty
                        ? ColoredBox(
                            color: Colors.grey.shade200,
                            child: const Icon(Icons.menu_book,
                                color: Colors.grey))
                        : CoverImage(b.cover,
                            sourceId: b.sourceId, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(b.author.isEmpty ? '未知作者' : b.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                      const SizedBox(height: 2),
                      Text('来源: ${b.sourceName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                      const SizedBox(height: 2),
                      Text('分组: ${group ?? '全部'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 圆形图标行
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _menuIcon(Icons.info_outline, '书本详情', () {
                  Navigator.pop(context);
                  _openBookDetail(b);
                }),
                _menuIcon(Icons.swap_horiz, '更换书源', () {
                  Navigator.pop(context);
                  _openBookDetail(b);
                }),
                _menuIcon(Icons.drive_file_move_outline, '移动分组', () {
                  Navigator.pop(context);
                  _moveGroup(b);
                }),
                _menuIcon(Icons.delete_outline, '删除书籍', () {
                  Navigator.pop(context);
                  _removeBook(b);
                }, color: const Color(0xFFE5484D)),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            _menuRow(Icons.drive_file_move_outline, '移动分组', () {
              Navigator.pop(context);
              _moveGroup(b);
            }),
            const Divider(height: 1),
            _menuRow(Icons.delete_outline, '删除书籍', () {
              Navigator.pop(context);
              _removeBook(b);
            }, color: const Color(0xFFE5484D)),
          ],
        ),
      ),
    );
  }

  Widget _menuIcon(IconData icon, String label, VoidCallback onTap,
      {Color? color}) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              shape: BoxShape.circle,
              border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.6), width: 1),
            ),
            child: Icon(icon, size: 22, color: color ?? cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: color ?? cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _menuRow(IconData icon, String label, VoidCallback onTap,
      {Color? color}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color ?? Colors.grey.shade700),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontSize: 15, color: color ?? const Color(0xFF222222))),
          ],
        ),
      ),
    );
  }

  void _openBookDetail(Book b) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BookDetailPage(book: b)),
    );
  }

  Future<void> _removeBook(Book b) async {
    if (!await _confirm('从书架移除「${b.name}」？（阅读进度保留）')) {
      return;
    }
    await ref.read(libraryProvider.notifier).removeFromShelf(b);
  }

  /// 移动分组：选择分组窗口（标题栏 + 列表单选 + 取消/确定）
  Future<void> _moveGroup(Book b) async {
    var pending = _groupOf[b.bookUrl];
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => FlatCard(
          radius: 24,
          blur: 3,
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题栏
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined,
                        size: 20, color: Color(0xFF3E8EF7)),
                    const SizedBox(width: 8),
                    const Text('选择分组',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 分组列表
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _groupOption(b, null, '全部', pending, setSheet),
                    for (final g in _groups)
                      _groupOption(b, g, g, pending, setSheet),
                    _groupOption(b, '__new__', '+ 新建分组', pending, setSheet),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 底部按钮
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(context);
                        if (pending != '__new__') _setGroup(b, pending);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupOption(Book b, String? g, String label, String? pending,
      StateSetter setSheet) {
    final isNew = g == '__new__';
    final active = pending == g;
    return ListTile(
      dense: true,
      leading: Icon(
        isNew ? Icons.add : Icons.folder_outlined,
        size: 20,
        color:
            active ? const Color(0xFF3E8EF7) : Colors.grey.shade500,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          color:
              active ? const Color(0xFF3E8EF7) : const Color(0xFF222222),
        ),
      ),
      trailing: active
          ? const Icon(Icons.check_circle,
              color: Color(0xFF3E8EF7), size: 20)
          : null,
      onTap: () {
        if (isNew) {
          Navigator.pop(context);
          _createGroup(b);
          return;
        }
        setSheet(() => pending = g);
      },
    );
  }

  Future<void> _setGroup(Book b, String? g) async {
    final sp = await SharedPreferences.getInstance();
    if (g == null) {
      await sp.remove('book_group_${b.bookUrl}');
    } else {
      await sp.setString('book_group_${b.bookUrl}', g);
    }
    if (mounted) {
      setState(() {
        if (g == null) {
          _groupOf.remove(b.bookUrl);
        } else {
          _groupOf[b.bookUrl] = g;
        }
      });
    }
  }

  /// 新建分组对话框，返回分组名（null 取消/空名）
  Future<String?> _promptGroupName() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => FlatDialog(
        child: FlatCard(
          radius: 20,
          blur: 3,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('新建分组',
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: '分组名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, ctrl.text),
                      child: const Text('创建')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 保存分组名到持久化，返回去空格后的名字（null 无效）
  Future<String?> _saveGroup(String raw) async {
    if (raw.trim().isEmpty) return null;
    final g = raw.trim();
    final sp = await SharedPreferences.getInstance();
    final groups = (sp.getStringList('book_groups') ?? const []).toList();
    if (!groups.contains(g)) groups.add(g);
    await sp.setStringList('book_groups', groups);
    if (mounted) setState(() => _groups = groups);
    return g;
  }

  Future<void> _createGroup(Book b) async {
    final name = await _promptGroupName();
    if (name == null) return;
    final g = await _saveGroup(name);
    if (g == null) return;
    await _setGroup(b, g);
  }

  /// 从筛选下拉新建分组（不绑定到某本书）
  Future<void> _createGroupFromMenu() async {
    final name = await _promptGroupName();
    if (name == null) return;
    await _saveGroup(name);
  }

  /// 分组管理：新建 / 重命名 / 删除分组
  Future<void> _showGroupManage() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => FlatDialog(
        maxWidth: 460,
        child: FlatCard(
          radius: 20,
          blur: 3,
          padding: const EdgeInsets.all(20),
          child: StatefulBuilder(
            builder: (context, setSheet) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('分组管理',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建'),
                      onPressed: () async {
                        final name = await _promptGroupName();
                        if (name == null) return;
                        final g = await _saveGroup(name);
                        if (g != null) setSheet(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('暂无分组，点右上角「新建」创建',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade600)),
                    ),
                  )
                else
                  for (final g in _groups) _groupManageRow(g, setSheet),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _groupManageRow(String g, StateSetter setSheet) {
    final count = _groupOf.values.where((v) => v == g).length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined,
              size: 18, color: Color(0xFF3E8EF7)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(g,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
          ),
          Text('$count 本',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: '重命名',
            onPressed: () async {
              await _renameGroup(g);
              setSheet(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 18, color: Color(0xFFE5484D)),
            tooltip: '删除',
            onPressed: () async {
              await _deleteGroup(g);
              setSheet(() {});
            },
          ),
        ],
      ),
    );
  }

  /// 重命名分组：改列表名 + 更新该组所有书的归属
  Future<void> _renameGroup(String old) async {
    final ctrl = TextEditingController(text: old);
    final name = await showDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => FlatDialog(
        child: FlatCard(
          radius: 20,
          blur: 3,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('重命名分组',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: '分组名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, ctrl.text),
                      child: const Text('重命名')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (name == null) return;
    final g = name.trim();
    if (g.isEmpty || g == old) return;
    final sp = await SharedPreferences.getInstance();
    final groups = (sp.getStringList('book_groups') ?? const []).toList();
    final idx = groups.indexOf(old);
    if (idx != -1) {
      groups[idx] = g;
    } else if (!groups.contains(g)) {
      groups.add(g);
    }
    await sp.setStringList('book_groups', groups);
    for (final e in _groupOf.entries.toList()) {
      if (e.value == old) {
        await sp.setString('book_group_${e.key}', g);
        _groupOf[e.key] = g;
      }
    }
    if (mounted) {
      setState(() {
        _groups = groups;
        if (_groupFilter == old) _groupFilter = g;
      });
    }
  }

  /// 删除分组：移出列表，组内书籍归入「全部」
  Future<void> _deleteGroup(String g) async {
    if (!await _confirm('删除分组「$g」？组内书籍会移入「全部」')) return;
    final sp = await SharedPreferences.getInstance();
    final groups = (sp.getStringList('book_groups') ?? const []).toList()
      ..remove(g);
    await sp.setStringList('book_groups', groups);
    for (final e in _groupOf.entries.toList()) {
      if (e.value == g) {
        await sp.remove('book_group_${e.key}');
        _groupOf.remove(e.key);
      }
    }
    if (mounted) {
      setState(() {
        _groups = groups;
        if (_groupFilter == g) _groupFilter = null;
      });
    }
  }


  // ---------- 内容 ----------

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.local_library_outlined,
              size: 72, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('书架空空如也，去搜几本书吧',
              style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  /// 独立胶囊/圆钮分割：不透明表面色 + 淡描边。
  Widget _chip({required Widget child, bool bordered = true}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 4),
      decoration: bordered
          ? BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.6), width: 1),
            )
          : null,
      child: child,
    );
  }

  /// 顶部左侧搜索框：点击打开书源搜索页
  Widget _searchBox() {
    return FlatCard(
      radius: 14,
      shadow: false,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SearchPage()),
          ),
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.search, size: 18, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '搜索书源',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 右上角悬浮工具栏：全部▾筛选 / 视图切换 / ⋮更多。
  Widget _topCapsule() {
    // 白色卡片框，与书籍卡片同底色，凸显工具栏层次
    return FlatCard(
      radius: 14,
      shadow: false,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
          // 全部▾ 筛选（类型 + 分组）
          _chip(
            bordered: false,
            child: GlassMenu(
              width: 200,
              items: [
                GlassMenuItem(
                  label: '全部',
                  selected: _groupFilter == null,
                  onTap: () => setState(() => _groupFilter = null),
                ),
                if (_groups.isNotEmpty)
                  const GlassMenuItem(label: '', divider: true),
                for (final g in _groups)
                  GlassMenuItem(
                    label: g,
                    leadingIcon: Icons.folder_outlined,
                    selected: _groupFilter == g,
                    onTap: () => setState(() => _groupFilter = g),
                  ),
                GlassMenuItem(
                  label: '新建分组',
                  leadingIcon: Icons.add,
                  onTap: _createGroupFromMenu,
                ),
              ],
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _groupFilter ?? '全部',
                      // 与书籍卡片书名同款：15 / w700 / 同深色
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF222222),
                      ),
                    ),
                    Icon(Icons.arrow_drop_down,
                        size: 16, color: Colors.grey.shade800),
                  ],
                ),
              ),
            ),
          ),
          // 视图切换
          _chip(
            bordered: false,
            child: IconButton(
              tooltip: _listView ? '网格视图' : '列表视图',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              icon: Icon(_listView ? Icons.grid_view : Icons.view_list,
                  size: 22, color: Colors.grey.shade800),
              onPressed: () => setState(() => _listView = !_listView),
            ),
          ),
          // ⋮ 更多
          _chip(
            bordered: false,
            child: GlassMenu(
              items: [
                GlassMenuItem(
                  label: '导入本地书',
                  leadingIcon: Icons.upload_file,
                  onTap: _importLocalBook,
                ),
                GlassMenuItem(
                  label: '分组管理',
                  leadingIcon: Icons.folder_outlined,
                  onTap: _showGroupManage,
                ),
                GlassMenuItem(
                  label: '书架管理',
                  leadingIcon: Icons.checklist,
                  onTap: _openManage,
                ),
              ],
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Icon(Icons.more_vert,
                    size: 22, color: Colors.grey.shade800),
              ),
            ),
          ),
      ],
      ),
    );
  }

  /// 管理模式顶部悬浮栏：返回 / 排序 / 清空 / 全选 / 删除。
  Widget _manageBar() {
    final all = ref.read(libraryProvider);
    // 白色卡片框，与书籍卡片同底色
    return FlatCard(
      radius: 14,
      shadow: false,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
          _chip(
            child: IconButton(
              tooltip: '退出管理',
              icon: const Icon(Icons.arrow_back),
              onPressed: _exitManage,
            ),
          ),
          const SizedBox(width: 6),
          // 排序
          _chip(
            child: PopupMenuButton<int>(
              onSelected: (v) {
                setState(() => _sortMode = v);
                _applySort();
              },
              itemBuilder: (_) => List.generate(
                _sortNames.length,
                (i) => PopupMenuItem(
                  value: i,
                  child: Row(
                    children: [
                      if (_sortMode == i)
                        const Icon(Icons.check,
                            size: 16, color: Color(0xFF3E8EF7)),
                      const SizedBox(width: 6),
                      Text(_sortNames[i]),
                    ],
                  ),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sort, size: 18),
                    const SizedBox(width: 4),
                    Text(_sortMode == -1 ? '排序' : _sortNames[_sortMode],
                        style: const TextStyle(fontSize: 13)),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          ),
          // 清空
          _chip(
            child: TextButton.icon(
              onPressed: all.isEmpty ? null : _clearShelf,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空'),
            ),
          ),
          // 全选
          _chip(
            child: IconButton(
              tooltip: '全选/取消全选',
              icon: Icon(
                _mSelected.length == all.length && all.isNotEmpty
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              onPressed: () => setState(() {
                if (_mSelected.length == all.length && all.isNotEmpty) {
                  _mSelected.clear();
                } else {
                  _mSelected.addAll(all.map((b) => b.bookUrl));
                }
              }),
            ),
          ),
          // 删除
          _chip(
            child: TextButton.icon(
              onPressed: _mSelected.isEmpty ? null : _deleteSelected,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE5484D),
              ),
              icon: const Icon(Icons.delete_outline, size: 16),
              label:
                  Text(_mSelected.isEmpty ? '删除' : '删除${_mSelected.length}'),
            ),
          ),
      ],
      ),
    );
  }

  /// 当前分组过滤后的小说（未排序）
  List<Book> _visibleBooks(List<Book> source) {
    return source.where((b) {
      return b.type == ContentType.novel &&
          (_groupFilter == null || _groupOf[b.bookUrl] == _groupFilter);
    }).toList();
  }

  /// 当前界面展示顺序：管理模式用用户排序；普通模式最近阅读置顶
  List<Book> _displayOrder(List<Book> books) {
    return _manageMode
        ? _sortedBooks(books)
        : List<Book>.of(books)
          ..sort((a, b) =>
              (_times[b.bookUrl] ?? 0).compareTo(_times[a.bookUrl] ?? 0));
  }

  Widget _grid(List<Book> books) {
    final display = _displayOrder(books);
    if (_listView) {
      return ListView.builder(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
        itemCount: display.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _BookCard(
            book: display[i],
            progress: _progress,
            progressTitles: _progressTitles,
            times: _times,
            checkingUpdate: _checkingBooks.contains(display[i].bookUrl),
            list: true,
            onOpen: _openDirect,
            onMenu: () => _showBookMenu(display[i]),
            manage: _manageMode,
            selected: _mSelected.contains(display[i].bookUrl),
            onSelect: () => _toggleSelect(display[i].bookUrl),
          ),
        ),
      );
    }
    final isMobile = MediaQuery.of(context).size.width < 600;
    return GridView.builder(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // 手机屏窄：横向卡（封面左+信息右）3 列会挤到只剩一条缝，降为 1 列全宽
        crossAxisCount: isMobile ? 1 : 3,
        childAspectRatio: isMobile ? 2.6 : 3.0,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: display.length,
      itemBuilder: (context, i) => _BookCard(
        book: display[i],
        progress: _progress,
        progressTitles: _progressTitles,
        times: _times,
        checkingUpdate: _checkingBooks.contains(display[i].bookUrl),
        list: false,
        onOpen: _openDirect,
        onMenu: () => _showBookMenu(display[i]),
        manage: _manageMode,
        selected: _mSelected.contains(display[i].bookUrl),
        onSelect: () => _toggleSelect(display[i].bookUrl),
      ),
    );
  }

  void _toggleSelect(String bookUrl) {
    setState(() {
      if (_mSelected.contains(bookUrl)) {
        _mSelected.remove(bookUrl);
      } else {
        _mSelected.add(bookUrl);
      }
    });
  }

  // ---------- 下拉检查更新：跟手位移 / 松手回弹 ----------

  bool _onShelfPullNotification(ScrollNotification n) {
    if (n.depth != 0) return false;

    if (n is ScrollStartNotification) {
      if (!_pullRefreshing) {
        _pullReleaseTimer?.cancel();
        _pullRaw = 0;
        _pullReleasing = false;
      }
      return false;
    }

    if (_pullRefreshing) return false;

    if (n is OverscrollNotification) {
      // 顶部继续下拉：Clamping 物理不会改变 pixels，overscroll 为负的原始拖拽量
      if (n.metrics.pixels <= 0.5 && n.overscroll < 0) {
        _pullRaw = (_pullRaw - n.overscroll).clamp(0.0, 160.0);
        _syncPullOffset();
      }
      return false;
    }

    if (n is ScrollUpdateNotification) {
      final delta = n.scrollDelta ?? 0;
      final atTop = n.metrics.pixels <= 0.5;

      if (atTop && delta < 0) {
        // Bouncing 物理下 pixels 可直接变负，这里同样累计下拉量
        _pullRaw = (_pullRaw - delta).clamp(0.0, 160.0);
      } else if (_pullRaw > 0 && delta > 0) {
        // 下拉后反向推回：同步收回位移
        _pullRaw = (_pullRaw - delta).clamp(0.0, 160.0);
      } else {
        return false;
      }

      _syncPullOffset();
      return false;
    }

    if (n is ScrollEndNotification) {
      _finishShelfPull();
      return false;
    }
    return false;
  }

  void _syncPullOffset() {
    final next = (_pullRaw * 0.55).clamp(0.0, _pullMax);
    if ((next - _pullOffset).abs() >= 0.5) {
      setState(() => _pullOffset = next);
    }
  }

  void _finishShelfPull() {
    if (_pullRefreshing || _pullRaw <= 0) return;
    final shouldRefresh = _pullRaw >= _pullTrigger;

    _pullReleaseTimer?.cancel();
    setState(() {
      _pullReleasing = true;
      _pullRaw = 0;
      _pullOffset = 0;
      if (shouldRefresh) _pullRefreshing = true;
    });
    _pullReleaseTimer = Timer(const Duration(milliseconds: 260), () {
      if (mounted) setState(() => _pullReleasing = false);
    });

    if (shouldRefresh) _runShelfRefresh();
  }

  Future<void> _runShelfRefresh() async {
    final started = DateTime.now();
    try {
      await _refreshShelf();
      // 检查更新继续在后台跑，不阻塞提示消失
      unawaited(_checkUpdatesAndNotify());
    } finally {
      // 本地书少时刷新会瞬间完成，保证提示至少可见一段时间；
      // 检查耗时长也不会一直卡在“正在检查更新…”。
      final left = const Duration(milliseconds: 700) -
          DateTime.now().difference(started);
      if (left > Duration.zero) await Future.delayed(left);
      if (mounted) setState(() => _pullRefreshing = false);
    }
  }

  // ---------- 数据 ----------

  // 下拉刷新：只重载本地书 + 进度（检查更新由 _runShelfRefresh 后台触发）
  Future<void> _refreshShelf() async {
    await ref.read(libraryProvider.notifier).load();
    await _loadProgress();
  }

  // 后台检查更新，完成后 SnackBar 提示
  Future<void> _checkUpdatesAndNotify() async {
    final n = await _checkUpdates();
    if (n > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$n 本书有更新'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // 逐书拉目录对比章节数：首次记录基线，之后章节增多算有更新。
  // 返回有更新的小说数；本地书与无目录来源会跳过。
  Future<int> _checkUpdates() async {
    // 按当前书架显示顺序检查：分组过滤 + 管理模式排序/最近阅读置顶
    final books = _displayOrder(_visibleBooks(ref.read(libraryProvider)));
    final sp = await SharedPreferences.getInstance();
    var updated = 0;
    for (final b in books) {
      if (b.type != ContentType.novel) continue;
      final source = SourceRegistry().byId(b.sourceId);
      if (source == null) continue;
      if (mounted) setState(() => _checkingBooks.add(b.bookUrl));
      try {
        final toc =
            await source.loadToc(b).timeout(const Duration(seconds: 15));
        final newCount = toc.chapters.length;
        final oldKey = 'update_count_${b.bookUrl}';
        final oldCount = sp.getInt(oldKey);
        if (oldCount != null && newCount > oldCount) updated++;
        await sp.setInt(oldKey, newCount);
      } catch (_) {
      } finally {
        if (mounted) setState(() => _checkingBooks.remove(b.bookUrl));
      }
    }
    return updated;
  }

  Future<void> _loadProgress() async {
    final sp = await SharedPreferences.getInstance();
    final keys = sp.getKeys().where((k) => k.startsWith(_progressPrefix));
    final map = <String, int>{};
    for (final k in keys) {
      final raw = sp.get(k);
      final v = raw is int ? raw : null;
      if (v != null) {
        map[k.substring(_progressPrefix.length)] = v;
      }
    }
    final tkeys = sp.getKeys().where((k) => k.startsWith(_progressTimePrefix));
    final tmap = <String, int>{};
    for (final k in tkeys) {
      final raw = sp.get(k);
      final v = raw is int ? raw : null;
      if (v != null) tmap[k.substring(_progressTimePrefix.length)] = v;
    }
    final ttkeys =
        sp.getKeys().where((k) => k.startsWith(_progressTitlePrefix));
    final ttmap = <String, String>{};
    for (final k in ttkeys) {
      final v = sp.getString(k);
      if (v != null) ttmap[k.substring(_progressTitlePrefix.length)] = v;
    }
    if (mounted) {
      setState(() {
        _progress = map;
        _progressTitles = ttmap;
        _times = tmap;
      });
    }
  }

  /// 书架点击书籍：直接进入阅读界面（目录缓存秒开 / 无缓存先抓首页再进）。
  ///
  /// 进入阅读器后后台继续补全目录（[ReaderPage.chaptersProvider] 读取
  /// 增长中的章节列表），避免等待整本目录加载。
  void _openDirect(Book book, int lastIndex) async {
    // 以 SharedPreferences 中的最新进度为准：从阅读器返回后本页的 _progress
    // 尚未刷新，直接用旧值会导致再次打开回到第一章。
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getInt('$_progressPrefix${book.bookUrl}');
    final index = saved ?? lastIndex;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _QuickReader(book: book, initialIndex: index),
      ),
    );
    // 阅读器返回后重载进度，卡片进度条 / 已读章节同步更新。
    if (mounted) _loadProgress();
  }

  // ---------- 操作 ----------

  /// 进入书架管理模式（在书架页内操作，不跳转独立页面）
  void _openManage() {
    setState(() {
      _manageMode = true;
      _mSelected.clear();
    });
  }

  void _exitManage() => setState(() {
        _manageMode = false;
        _mSelected.clear();
      });

  /// 排序后的书架列表（管理模式排序；未选排序保持加入顺序）
  List<Book> _sortedBooks(List<Book> books) {
    final l = List.of(books);
    if (_sortMode == -1) return l; // 未选：保持书架原顺序
    if (_sortMode == 0) {
      l.sort((a, b) =>
          (_times[b.bookUrl] ?? 0).compareTo(_times[a.bookUrl] ?? 0));
    } else if (_sortMode == 1) {
      l.sort((a, b) => a.name.compareTo(b.name));
    }
    return l;
  }

  Future<void> _applySort() async {
    await ref
        .read(libraryProvider.notifier)
        .replaceAll(_sortedBooks(ref.read(libraryProvider)));
  }

  /// 确认框：普通 AlertDialog 样式（不加背景模糊，浅色遮罩即可）
  Future<bool> _confirm(String msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
        content: Text(msg, style: const TextStyle(fontSize: 15)),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _deleteSelected() async {
    final all = ref.read(libraryProvider);
    final target = all.where((b) => _mSelected.contains(b.bookUrl)).toList();
    if (target.isEmpty) return;
    if (!await _confirm('删除选中的 ${target.length} 本书？')) return;
    await ref.read(libraryProvider.notifier).removeMany(target);
    if (mounted) setState(() => _mSelected.clear());
  }

  Future<void> _clearShelf() async {
    final all = ref.read(libraryProvider);
    if (all.isEmpty) return;
    if (!await _confirm('清空书架（共 ${all.length} 本）？')) return;
    await ref.read(libraryProvider.notifier).clearShelf();
  }

  Future<void> _importLocalBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub'],
      withData: true,
    );
    final files = result?.files ?? const [];
    if (files.isEmpty || files.first.bytes == null) return;
    final picked = files.first;
    final name = picked.name;
    final bytes = picked.bytes!;
    try {
      final book = await LocalBookSource.importBytes(name, bytes);
      await ref.read(libraryProvider.notifier).addToShelf(book);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入：${book.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    }
  }

}

/// 横向书卡：封面在左（带类型角标），信息在右。
class _BookCard extends StatelessWidget {
  final Book book;
  final Map<String, int> progress;

  /// 已读章标题（progress_title_ 持久化，供「已读: 第N章 标题」显示）
  final Map<String, String> progressTitles;

  /// 最近阅读时间戳（progress_time_），供「X分钟前: 最新章节」显示
  final Map<String, int> times;

  /// 正在检查更新：封面右下角显示转圈
  final bool checkingUpdate;

  final bool list;

  /// 点击书籍（默认进入详情页；书架直读模式直接进阅读器）。
  final void Function(Book book, int lastIndex)? onOpen;

  /// 长按非管理卡片：弹分组菜单
  final VoidCallback? onMenu;

  /// 管理模式：显示多选框，点击切换选中（不进入阅读器）
  final bool manage;
  final bool selected;
  final VoidCallback? onSelect;

  const _BookCard({
    required this.book,
    required this.progress,
    this.progressTitles = const {},
    this.times = const {},
    this.checkingUpdate = false,
    required this.list,
    this.onOpen,
    this.onMenu,
    this.manage = false,
    this.selected = false,
    this.onSelect,
  });

  /// 总章节数：从 lastChapter 解析「第N章」
  int? get _total {
    final lc = book.lastChapter;
    if (lc == null || lc.isEmpty) return null;
    final m = RegExp(r'第\s*(\d+)\s*章').firstMatch(lc);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 未读章节数 = 最新章节号 - 已读章号
  int? get _unread {
    final total = _total;
    if (total == null) return null;
    final read = (progress[book.bookUrl] ?? 0) + 1;
    final unread = total - read;
    return unread > 0 ? unread : null;
  }

  /// 最近阅读时间短语（「刚刚 / X分钟前 / X小时前 / X天前」）
  String _fmtAgo(int? ms) {
    if (ms == null || ms <= 0) return '未读';
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  @override
  Widget build(BuildContext context) {
    final p = progress[book.bookUrl] ?? 0;
    final unread = _unread;

    Widget cover() {
      return ClipRRect(
        // 与卡片 Material(10) 及发现页封面一致：四角都圆
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            book.cover.isEmpty
                ? ColoredBox(
                    color: Colors.grey.shade200,
                    child: Icon(
                      Icons.menu_book,
                      size: 32,
                      color: Colors.grey,
                    ),
                  )
                : CoverImage(book.cover,
                    sourceId: book.sourceId, fit: BoxFit.cover),
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5484D),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '小说',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (checkingUpdate)
              Positioned(
                right: 5,
                bottom: 5,
                child: Tooltip(
                  message: '正在检查更新',
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    Widget info() {
      final total = _total;
      final readTitle = progressTitles[book.bookUrl] ?? '';
      final lc = book.lastChapter ?? '';
      final ago = _fmtAgo(times[book.bookUrl]);
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween, // 五行均匀填满
          children: [
            Text(
              book.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 15,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF222222)),
            ),
            // 作者 · 共N章
            if (book.author.isNotEmpty || total != null)
              Text(
                [
                  if (book.author.isNotEmpty) book.author,
                  if (total != null) '共$total章',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    color: Colors.grey.shade600),
              ),
            // 已读: 第N章 + 已读章标题
            Text(
              readTitle.isEmpty
                  ? '已读: 第${p + 1}章'
                  : '已读: 第${p + 1}章 $readTitle',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.25,
                  color: Colors.grey.shade600),
            ),
            Text(
              '来源: ${book.sourceName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.25,
                  color: Colors.grey.shade600),
            ),
            // X分钟前: 最新章节
            if (lc.isNotEmpty)
              Text(
                '$ago: $lc',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    color: Colors.grey.shade500),
              ),
          ],
        ),
      );
    }

    return FlatCard(
      radius: 10,
      border: manage && selected
          ? Border.all(color: const Color(0xFF3E8EF7), width: 2)
          : null,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (manage) {
              onSelect?.call();
              return;
            }
            final lastIdx = progress[book.bookUrl] ?? 0;
            if (onOpen != null) {
              onOpen!(book, lastIdx);
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => BookDetailPage(book: book)),
              );
            }
          },
          // 长按弹分组菜单；管理模式=切换选中
          onLongPress: () {
            if (manage) {
              onSelect?.call();
              return;
            }
            onMenu?.call();
          },
          child: Stack(
            children: [
              // 列表模式：项高度无界，需给封面/信息固定高度（网格有格子约束无需）
              list
                  ? SizedBox(
                      height: 112,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 封面缩小并四周留白，不贴卡片边
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(10, 8, 0, 8),
                            child: SizedBox(width: 76, child: cover()),
                          ),
                          Expanded(child: info()),
                        ],
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 封面缩小并四周留白，不贴卡片边（居中浮在卡片里）
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
                          child: SizedBox(width: 72, child: cover()),
                        ),
                        Expanded(child: info()),
                      ],
                    ),
              // 整个卡片右上角：管理模式选中徽章 / 未读章节数角标
              Positioned(
                right: 6,
                top: 6,
                child: manage
                    ? (selected
                        ? Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: const Color(0xFF3E8EF7),
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: Colors.white, width: 2),
                              boxShadow: const [
                                BoxShadow(
                                    color: Colors.black38, blurRadius: 4),
                              ],
                            ),
                            child: const Icon(Icons.check,
                                color: Colors.white, size: 14),
                          )
                        : Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.grey.shade400,
                                  width: 1.5),
                              boxShadow: const [
                                BoxShadow(
                                    color: Colors.black26, blurRadius: 3),
                              ],
                            ),
                          ))
                    : (unread != null
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5484D),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white, width: 1),
                            ),
                            child: Text(
                              '${unread > 99 ? 99 : unread}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600),
                            ),
                          )
                        : const SizedBox.shrink()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书架直读：加载目录（缓存秒开 / 无缓存先抓首页），随后
/// [Navigator.pushReplacement] 到 [ReaderPage]，返回书架。
///
/// 目录用 [onPageChunk] 边收边并入共享 [List]，进入阅读器后后台
/// 仍继续追加（[ReaderPage.chaptersProvider] 读到最新列表），
/// 首屏 1000 章不等后面几页。
class _QuickReader extends StatefulWidget {
  final Book book;
  final int initialIndex;

  const _QuickReader({required this.book, required this.initialIndex});

  @override
  State<_QuickReader> createState() => _QuickReaderState();
}

class _QuickReaderState extends State<_QuickReader> {
  final List<Chapter> _chapters = [];
  final Set<String> _seen = {};
  bool _entered = false;
  String? _error;
  String _progress = '正在打开…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final source = SourceRegistry().byId(widget.book.sourceId);

    // 1) 目录缓存：有就先用它进阅读器（秒开），后台刷新补全
    try {
      final cached = await TocCache.read(widget.book.bookUrl);
      if (cached != null && cached.chapters.isNotEmpty) {
        _merge(cached.chapters);
        _enter();
        if (cached.isFresh && !cached.partial) return; // 新鲜完整，不扫站点
        // 过期/部分目录：后台刷新（阅读器继续用已有章节）
        if (source != null) {
          try {
            final r = await source
                .loadToc(widget.book, onPageChunk: (_, l) => _merge(l))
                .timeout(const Duration(seconds: 45));
            await TocCache.write(widget.book.bookUrl, r.chapters,
                partial: r.partial);
          } catch (_) {}
        }
        return;
      }
    } catch (_) {}

    if (source == null) {
      if (mounted) setState(() => _error = '找不到书源：${widget.book.sourceId}');
      return;
    }

    // 2) 无缓存：抓目录，第一页到货即进。
    //    45s 兜底：站点全挂（0 字节/反爬）时第一页迟迟不来，避免无限转圈。
    try {
      final result = await source
          .loadToc(
            widget.book,
            onProgress: (page, count) {
              if (mounted) {
                setState(() => _progress =
                    '正在加载目录 · 第 $page 页 · 已取 $count 章');
              }
            },
            onPageChunk: (_, list) {
              if (list.isEmpty) return;
              _merge(list);
              if (_chapters.isNotEmpty) _enter(); // 第一页到了就进阅读器
            },
          )
          .timeout(const Duration(seconds: 45));
      _merge(result.chapters);
      await TocCache.write(widget.book.bookUrl, result.chapters,
          partial: result.partial);
    } catch (e) {
      if (_chapters.isEmpty && mounted) {
        setState(() => _error = e.toString());
      }
    }
    if (_chapters.isEmpty && mounted && _error == null) {
      setState(() => _error = '未取到章节目录');
    }
    _enter(); // 已进过则空跑
  }

  /// 并入新章节（按 url 去重），列表对象不变（阅读器 provider 持续读到）。
  void _merge(List<Chapter> list) {
    for (final c in list) {
      if (_seen.add(c.url)) _chapters.add(c);
    }
    if (mounted) setState(() {});
  }

  void _enter() {
    if (_entered) return;
    if (_chapters.isEmpty) return; // 无章节不进入（停留显示错误/加载）
    if (!mounted) return; // 异步回调时组件可能已销毁
    _entered = true;
    final idx = widget.initialIndex.clamp(0, _chapters.length - 1);
    openReader(
      context,
      widget.book,
      _chapters,
      idx,
      chaptersProvider: () => _chapters,
      replace: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 浅色渐变背景（避免透明 Scaffold 露出黑底），显示目录加载进度。
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: Center(
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 40, color: Colors.grey),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('返回'),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      _progress,
                      style: const TextStyle(color: Colors.black54, fontSize: 14),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

