/// 书架首页。
///
/// 布局对应 shiguang 书架：顶部「书架」标题 + 右侧工具栏
/// （全部▾筛选 / 网格·列表切换 / 搜索 / 更多），下方三列横向书卡
/// （封面在左带「小说/漫画」角标，信息在右：书名/作者/已读/来源/最新章节）。
library;

import 'package:file_picker/file_picker.dart';
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

  ContentType? _filter; // null = 全部
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

  @override
  void initState() {
    super.initState();
    ref.read(libraryProvider.notifier).load();
    _loadProgress();
    _loadGroups();
  }

  @override
  Widget build(BuildContext context) {
    // 书架增删（导入/删除）后刷新进度
    ref.listen<List<Book>>(libraryProvider, (prev, next) {
      _loadProgress();
    });

    final books = ref.watch(libraryProvider).where((b) {
      return (_filter == null || b.type == _filter) &&
          (_groupFilter == null || _groupOf[b.bookUrl] == _groupFilter);
    }).toList();

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          _header(),
          Expanded(
            child: books.isEmpty ? _empty() : _grid(books),
          ),
        ],
      ),
      ),
    );
  }

  /// Ctrl+F 打开搜索
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
      builder: (context) => Glass(
        radius: 24,
        blur: 18,
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
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.6),
              shape: BoxShape.circle,
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.55), width: 1),
            ),
            child: Icon(icon, size: 22, color: color ?? Colors.grey.shade700),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: color ?? Colors.grey.shade700)),
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
        builder: (context, setSheet) => Glass(
          radius: 24,
          blur: 18,
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
      builder: (context) => GlassDialog(
        child: Glass(
          radius: 20,
          blur: 18,
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
      builder: (context) => GlassDialog(
        maxWidth: 460,
        child: Glass(
          radius: 20,
          blur: 18,
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
      builder: (context) => GlassDialog(
        child: Glass(
          radius: 20,
          blur: 18,
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

  // ---------- 顶部工具栏 ----------

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      child: _manageMode ? _manageToolbar() : _normalToolbar(),
    );
  }

  /// 独立玻璃胶囊/圆钮：悬浮半透明白 + 高光描边（不再用整条玻璃容器）。
  Widget _chip({required Widget child, double alpha = 0.35}) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(22),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1),
      ),
      child: child,
    );
  }

  /// 正常工具栏：书架标题（独立文字）+ 独立玻璃按钮（筛选/视图/搜索/更多）
  Widget _normalToolbar() {
    return Row(
      children: [
        const Text('书架',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const Spacer(),
        // 全部▾ 筛选（玻璃下拉：类型 + 分组，样式同发现页书源选择）
        _chip(
          child: GlassMenu(
            width: 200,
            items: [
              GlassMenuItem(
                label: '全部',
                selected: _groupFilter == null && _filter == null,
                onTap: () => setState(() {
                  _filter = null;
                  _groupFilter = null;
                }),
              ),
              GlassMenuItem(
                label: '小说',
                selected: _filter == ContentType.novel && _groupFilter == null,
                onTap: () => setState(() {
                  _filter = ContentType.novel;
                  _groupFilter = null;
                }),
              ),
              GlassMenuItem(
                label: '漫画',
                selected: _filter == ContentType.comic && _groupFilter == null,
                onTap: () => setState(() {
                  _filter = ContentType.comic;
                  _groupFilter = null;
                }),
              ),
              GlassMenuItem(
                label: '视频',
                selected: _filter == ContentType.video && _groupFilter == null,
                onTap: () => setState(() {
                  _filter = ContentType.video;
                  _groupFilter = null;
                }),
              ),
              if (_groups.isNotEmpty)
                const GlassMenuItem(label: '', divider: true),
              for (final g in _groups)
                GlassMenuItem(
                  label: g,
                  leadingIcon: Icons.folder_outlined,
                  selected: _groupFilter == g,
                  onTap: () => setState(() {
                    _groupFilter = g;
                    _filter = null;
                  }),
                ),
              GlassMenuItem(
                label: '新建分组',
                leadingIcon: Icons.add,
                onTap: _createGroupFromMenu,
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _groupFilter != null
                        ? _groupFilter!
                        : (_filter == null
                            ? '全部'
                            : (_filter == ContentType.novel
                                ? '小说'
                                : _filter == ContentType.comic
                                    ? '漫画'
                                    : '视频')),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
        ),
        // 视图切换（玻璃圆钮）
        _chip(
          child: IconButton(
            tooltip: _listView ? '网格视图' : '列表视图',
            icon: Icon(_listView ? Icons.grid_view : Icons.view_list),
            onPressed: () => setState(() => _listView = !_listView),
          ),
        ),
        // 搜索（玻璃圆钮）
        _chip(
          child: IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
        ),
        // 更多（玻璃下拉，样式同发现页书源选择）
        _chip(
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: const Icon(Icons.more_vert),
            ),
          ),
        ),
      ],
    );
  }

  /// 管理模式工具栏：返回玻璃圆钮 + 标题 + 独立玻璃按钮（排序/清空/全选/删除）
  Widget _manageToolbar() {
    final all = ref.read(libraryProvider);
    return Row(
      children: [
        // 返回（独立玻璃圆钮）
        _chip(
          child: IconButton(
            tooltip: '退出管理',
            icon: const Icon(Icons.arrow_back),
            onPressed: _exitManage,
          ),
        ),
        const SizedBox(width: 10),
        const Text('书架管理',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        // 排序（玻璃胶囊）
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
        // 清空（玻璃胶囊）
        _chip(
          child: TextButton.icon(
            onPressed: all.isEmpty ? null : _clearShelf,
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('清空'),
          ),
        ),
        // 全选（玻璃圆钮）
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
        // 删除（玻璃胶囊，红色主操作）
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
    );
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

  Widget _grid(List<Book> books) {
    // 管理模式：应用排序
    final display = _manageMode ? _sortedBooks(books) : books;
    if (_listView) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        itemCount: display.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _BookCard(
            book: display[i],
            progress: _progress,
            progressTitles: _progressTitles,
            times: _times,
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
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
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

  // ---------- 数据 ----------

  Future<void> _loadProgress() async {
    final sp = await SharedPreferences.getInstance();
    final keys = sp.getKeys().where((k) => k.startsWith(_progressPrefix));
    final map = <String, int>{};
    for (final k in keys) {
      final v = sp.getInt(k);
      if (v != null) {
        map[k.substring(_progressPrefix.length)] = v;
      }
    }
    final tkeys = sp.getKeys().where((k) => k.startsWith(_progressTimePrefix));
    final tmap = <String, int>{};
    for (final k in tkeys) {
      final v = sp.getInt(k);
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
  void _openDirect(Book book, int lastIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _QuickReader(book: book, initialIndex: lastIndex)),
    );
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

  /// 确认框：普通 AlertDialog 样式（不毛玻璃遮盖，浅色遮罩即可）
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
      allowedExtensions: ['txt', 'epub', 'cbz', 'zip'],
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
          SnackBar(content: Text('已导入：${book.name}（${book.type == ContentType.comic ? "漫画" : "小说"}）')),
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
    final isComic = book.type == ContentType.comic;
    final unread = _unread;

    Widget cover() {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            book.cover.isEmpty
                ? ColoredBox(
                    color: Colors.grey.shade200,
                    child: Icon(
                      isComic ? Icons.image : Icons.menu_book,
                      size: 32,
                      color: Colors.grey,
                    ),
                  )
                : CoverImage(book.cover,
                    sourceId: book.sourceId, fit: BoxFit.contain),
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isComic
                      ? const Color(0xFF7C6FF0)
                      : const Color(0xFFE5484D),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isComic ? '漫画' : '小说',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600),
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

    return Glass(
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
                          SizedBox(width: 90, child: cover()),
                          Expanded(child: info()),
                        ],
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 86, child: cover()),
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
                              color: Colors.white.withValues(alpha: 0.85),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color:
                                      Colors.grey.withValues(alpha: 0.6),
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
      body: GlassBackground(
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

