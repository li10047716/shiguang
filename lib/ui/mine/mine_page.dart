/// 我的页：分类 tab（统计 / 内容 / 书源 / 设置）。
///
/// 对应 shiguang 我的页：顶部「我的」标题 + 分类胶囊，下方按分类切换面板。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../services/library.dart';
import '../../services/marks.dart';
import '../../sources/builtin/builtin_sources.dart';
import '../../sources/native/localbook.dart';
import '../../sources/source_registry.dart';
import '../app_theme.dart';
import '../book/book_detail_page.dart';
import '../book/toc_page.dart';
import '../glass.dart';
import '../reader/reader_prefs.dart';
import '../widgets/cover_image.dart';
import '../widgets/type_tag.dart';

class MinePage extends ConsumerStatefulWidget {
  const MinePage({super.key});

  @override
  ConsumerState<MinePage> createState() => _MinePageState();
}

class _MinePageState extends ConsumerState<MinePage> {
  static const _progressPrefix = 'progress_';
  static const _accent = Color(0xFF2E7D5B);

  int _tab = 0;
  Map<String, int> _progress = {};
  List<Book> _localBooks = [];
  int _cacheBytes = 0;
  List<Bookmark> _bookmarks = [];
  List<HighlightNote> _notes = [];
  int _readMs = 0; // 累计阅读时长（毫秒）
  int _readChapters = 0; // 累计已读章节（去重）
  Map<String, int> _daily = {}; // 最近 7 天每天阅读毫秒（key=yyyyMMdd）

  @override
  void initState() {
    super.initState();
    ref.read(libraryProvider.notifier).load();
    _loadAll();
  }

  Future<void> _loadAll() async {
    await _loadProgress();
    await _loadLocal();
    await _loadMarks();
    await _loadStats();
  }

  Future<void> _loadStats() async {
    final sp = await SharedPreferences.getInstance();
    final daily = <String, int>{};
    for (var i = 6; i >= 0; i--) {
      final d = DateTime.now().subtract(Duration(days: i));
      final key = '${d.year}'
          '${d.month.toString().padLeft(2, '0')}'
          '${d.day.toString().padLeft(2, '0')}';
      daily[key] = sp.getInt('read_daily_$key') ?? 0;
    }
    if (mounted) {
      setState(() {
        _readMs = sp.getInt('read_total_ms') ?? 0;
        _readChapters =
            (sp.getStringList('read_chapters') ?? const []).length;
        _daily = daily;
      });
    }
  }

  Future<void> _loadMarks() async {
    final bm = await MarksService.getBookmarks();
    final notes = await MarksService.getNotes();
    if (mounted) {
      setState(() {
        _bookmarks = bm;
        _notes = notes;
      });
    }
  }

  Future<void> _loadProgress() async {
    final sp = await SharedPreferences.getInstance();
    final keys = sp.getKeys().where((k) => k.startsWith(_progressPrefix));
    final map = <String, int>{};
    for (final k in keys) {
      final v = sp.getInt(k);
      if (v != null) map[k.substring(_progressPrefix.length)] = v;
    }
    if (mounted) setState(() => _progress = map);
  }

  Future<void> _loadLocal() async {
    final books = await LocalBookSource.list();
    var bytes = 0;
    try {
      bytes = _dirSize(await LocalBookSource.root());
    } catch (_) {}
    if (mounted) {
      setState(() {
        _localBooks = books;
        _cacheBytes = bytes;
      });
    }
  }

  int _dirSize(Directory dir) {
    var total = 0;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += e.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  }

  String _fmtBytes(int b) {
    if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          _tabBar(),
          Expanded(child: _panel()),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('我的',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('统计 · 内容 · 书源 · 设置',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _tabBar() {
    const tabs = ['统计', '内容', '书源', '设置'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Glass(
        radius: 22,
        blur: 18,
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _tab = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _tab == i
                          ? _accent.withValues(alpha: 0.85)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      tabs[i],
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            _tab == i ? FontWeight.w600 : FontWeight.w400,
                        color: _tab == i
                            ? Colors.white
                            : Colors.grey.shade700,
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

  Widget _panel() {
    switch (_tab) {
      case 0:
        return _statsPanel();
      case 1:
        return _contentPanel();
      case 2:
        return _sourcePanel();
      default:
        return _settingPanel();
    }
  }

  // ---------- 统计 ----------

  Widget _statsPanel() {
    final books = ref.watch(libraryProvider);
    final readChapters = books.fold<int>(0, (sum, b) {
      final p = _progress[b.bookUrl] ?? 0;
      return sum + (p > 0 ? p + 1 : 0);
    });
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            _statCard('书架', '${books.length}', Icons.library_books),
            const SizedBox(width: 12),
            _statCard('已读章节', '$readChapters', Icons.chrome_reader_mode),
            const SizedBox(width: 12),
            _statCard('本地书', '${_localBooks.length}', Icons.folder),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _statCard('阅读时长', _fmtDuration(_readMs), Icons.timer_outlined),
            const SizedBox(width: 12),
            _statCard('累计章节', '$_readChapters', Icons.history),
            const SizedBox(width: 12),
            _statCard('书签笔记',
                '${_bookmarks.length + _notes.length}', Icons.bookmarks_outlined),
          ],
        ),
        const SizedBox(height: 20),
        _weekChart(),
        const SizedBox(height: 20),
        Text('阅读历史',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        if (books.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('还没有读过的书',
                  style: TextStyle(color: Colors.grey.shade500)),
            ),
          )
        else
          for (final b in books) _historyTile(b),
      ],
    );
  }

  String _fmtDuration(int ms) {
    final min = ms ~/ 60000;
    if (min < 1) return '<1分';
    if (min < 60) return '$min分';
    final h = min ~/ 60;
    final m = min % 60;
    return m == 0 ? '$h小时' : '$h小时$m分';
  }

  /// 最近 7 天阅读时长柱状图
  Widget _weekChart() {
    final now = DateTime.now();
    const wl = ['一', '二', '三', '四', '五', '六', '日'];
    final entries = <(String, int)>[]; // (周几标签, 毫秒)
    for (var i = 6; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      final key = '${d.year}'
          '${d.month.toString().padLeft(2, '0')}'
          '${d.day.toString().padLeft(2, '0')}';
      entries.add((wl[d.weekday - 1], _daily[key] ?? 0));
    }
    final maxMs = entries.fold<int>(0, (a, e) => e.$2 > a ? e.$2 : a);
    final total = entries.fold<int>(0, (a, e) => a + e.$2);
    return Glass(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('最近 7 天阅读',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF555555))),
          const SizedBox(height: 14),
          SizedBox(
            height: 100,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final e in entries)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: 18,
                                height: maxMs == 0
                                    ? 4
                                    : (e.$2 / maxMs * 78).clamp(4.0, 78.0),
                                decoration: BoxDecoration(
                                  color: _accent
                                      .withValues(alpha: e.$2 > 0 ? 0.85 : 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(e.$1,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('近 7 天共 ${_fmtDuration(total)}',
              style:
                  TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Expanded(
      child: Glass(
        radius: 10,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, size: 20, color: _accent),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _historyTile(Book b) {
    final p = _progress[b.bookUrl] ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 8,
        child: ListTile(
          dense: true,
          leading: b.cover.isEmpty
              ? const Icon(Icons.menu_book)
              : CoverImage(b.cover, sourceId: b.sourceId,
                  width: 32, height: 40),
          title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${b.sourceName} · 已读 第${p + 1}章',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: p > 0
              ? Text('第${p + 1}章',
                  style: TextStyle(fontSize: 12, color: _accent))
              : null,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => BookDetailPage(book: b)),
          ),
        ),
      ),
    );
  }

  // ---------- 内容 ----------

  Widget _contentPanel() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _actionBar([
          _actionBtn('导入本地书', Icons.upload_file, _importLocalBook),
        ]),
        const SizedBox(height: 20),
        Text('本地书',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        if (_localBooks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text('暂无本地书，导入 TXT/EPUB/CBZ/ZIP 后出现在这里',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
            ),
          )
        else
          for (final b in _localBooks) _localTile(b),
        const SizedBox(height: 20),
        Text('书签',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        if (_bookmarks.isEmpty)
          _emptyHint('阅读器顶栏点书签图标即可加书签')
        else
          for (final bm in _bookmarks) _bookmarkTile(bm),
        const SizedBox(height: 20),
        Text('划线笔记',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        if (_notes.isEmpty)
          _emptyHint('阅读器「设置 → 划线笔记模式」后选中文字可记笔记')
        else
          for (final n in _notes) _noteTile(n),
      ],
    );
  }

  Widget _emptyHint(String msg) {
    return Glass(
      radius: 8,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(Icons.bookmark_border, color: Colors.grey.shade400),
          const SizedBox(width: 10),
          Expanded(
            child: Text(msg,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _bookmarkTile(Bookmark bm) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Glass(
        radius: 8,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.bookmark, color: const Color(0xFFE5A13A)),
          title: Text(bm.book.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${bm.chapterTitle} · ${_fmtTime(bm.time)}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () async {
              await MarksService.removeBookmark(
                  bm.book.bookUrl, bm.chapterIndex);
              await _loadMarks();
            },
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TocPage(
                  book: bm.book, initialIndex: bm.chapterIndex),
            ),
          ),
        ),
      ),
    );
  }

  Widget _noteTile(HighlightNote n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Glass(
        radius: 8,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.edit_note, color: Color(0xFF3E8EF7)),
          title: Text('${n.book.name} · ${n.chapterTitle}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(n.note, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () async {
              await MarksService.removeNote(n.id);
              await _loadMarks();
            },
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TocPage(
                  book: n.book, initialIndex: n.chapterIndex),
            ),
          ),
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  Widget _localTile(Book b) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 8,
        child: ListTile(
          dense: true,
          leading: b.cover.isEmpty
              ? Icon(b.type == ContentType.comic ? Icons.image : Icons.menu_book)
              : CoverImage(b.cover, sourceId: b.sourceId,
                  width: 32, height: 40),
          title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(b.author, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteLocal(b),
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => BookDetailPage(book: b)),
          ),
        ),
      ),
    );
  }

  // ---------- 书源 ----------

  Widget _sourcePanel() {
    final repo = SourceRepository();
    final sources = SourceRegistry().all;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('书源管理',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800)),
            const Spacer(),
            TextButton.icon(
              onPressed: _exportSources,
              icon: Icon(Icons.upload_outlined,
                  size: 18, color: Colors.grey.shade700),
              label: Text('导出书源',
                  style:
                      TextStyle(color: Colors.grey.shade700, fontSize: 13)),
            ),
            TextButton.icon(
              onPressed: _addSource,
              icon: const Icon(Icons.add, size: 18, color: _accent),
              label: Text('添加书源',
                  style: TextStyle(color: Colors.grey.shade800, fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final s in sources)
          Builder(builder: (context) {
            final rule = repo.byId(s.sourceId);
            final isBuiltin = rule == null;
            final isCustom = !isBuiltin && repo.isCustom(s.sourceId);
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Glass(
                radius: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: SwitchListTile(
                        dense: true,
                        activeThumbColor: _accent,
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(s.sourceName,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            const SizedBox(width: 8),
                            TypeTag(type: s.type),
                          ],
                        ),
                        subtitle: Text(
                          isBuiltin ? '内置书源（始终启用）' : rule.baseUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: isBuiltin ? true : rule.enabled,
                        onChanged: isBuiltin
                            ? null
                            : (v) async {
                                await repo.toggle(s.sourceId, v);
                                setState(() {});
                              },
                      ),
                    ),
                    if (isCustom)
                      IconButton(
                        tooltip: '删除书源',
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: Color(0xFFE5484D)),
                        onPressed: () => _removeSource(repo, s.sourceId),
                      ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  /// 添加自定义书源：粘贴 JSON → 导入 → 刷新注册表
  Future<void> _addSource() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
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
            const Text('添加书源',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('粘贴 JSON 书源（单个对象或数组）',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLines: 8,
              maxLength: 4000,
              decoration: const InputDecoration(
                hintText: '{"sourceName": "..", "sourceUrl": "..", '
                    '"sourceType": "novel", "search": {...}, ...}',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: () => Navigator.pop(context, ctrl.text),
                    child: const Text('导入')),
              ],
            ),
          ],
        ),
        ),
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      final n = await SourceRepository().importJson(text);
      SourceRegistry().reload();
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 $n 个书源'),
              duration: const Duration(seconds: 1)),
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

  Future<void> _removeSource(SourceRepository repo, String id) async {
    final ok = await _confirm('删除书源', '删除该书源？（不影响已加入书架的书）');
    if (!ok) return;
    await repo.removeCustom(id);
    SourceRegistry().reload();
    setState(() {});
  }

  /// 导出自定义书源为 JSON 文件（custom_sources 存的是单条 JSON 字符串）
  Future<void> _exportSources() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final sp = await SharedPreferences.getInstance();
      final custom = sp.getStringList('custom_sources') ?? const [];
      if (custom.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('没有可导出的自定义书源')),
        );
        return;
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出书源',
        fileName: '悦读书源_${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path != null) {
        await File(path).writeAsString('[${custom.join(',')}]',
            encoding: utf8);
      }
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(path != null ? '书源已导出' : '已取消导出'),
          duration: const Duration(seconds: 1),
        ));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  // ---------- 设置 ----------

  Widget _settingPanel() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('阅读',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        _settingTile(
            Icons.chrome_reader_mode_outlined, '阅读设置', '字号 / 背景主题',
            () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _ReaderSettingsPage()),
                )),
        const SizedBox(height: 20),
        Text('缓存',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        _settingTile(Icons.folder_open, '本地书缓存',
            '${_localBooks.length} 本 · ${_fmtBytes(_cacheBytes)}',
            () => _clearLocalCache()),
        const SizedBox(height: 20),
        Text('外观',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        _settingTile(
            Icons.dark_mode_outlined,
            '深色模式',
            const ['跟随系统', '浅色', '深色'][AppTheme.darkMode.value],
            _showDarkSheet),
        _settingTile(Icons.palette_outlined, '主题色', '应用强调色',
            _showAccentSheet),
        const SizedBox(height: 20),
        Text('通用',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        _settingTile(Icons.backup_outlined, '备份与恢复',
            '导出 / 导入书架与进度', _showBackupSheet),
        _settingTile(Icons.delete_sweep_outlined, '清除阅读记录',
            '清空书架与各书进度', _clearAll),
        _settingTile(Icons.info_outline, '关于', '悦读 · 拾光阅读器 Flutter 版',
            () {}),
      ],
    );
  }

  // ---------- 外观 ----------

  Future<void> _showDarkSheet() async {
    const names = ['跟随系统', '浅色', '深色'];
    await showDialog<void>(
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
            const Text('深色模式',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < names.length; i++)
                  ChoiceChip(
                    label: Text(names[i]),
                    selected: AppTheme.darkMode.value == i,
                    onSelected: (_) {
                      AppTheme.darkMode.value = i;
                      SharedPreferences.getInstance()
                          .then((sp) => sp.setInt('app_dark_mode', i));
                      setState(() {});
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  Future<void> _showAccentSheet() async {
    await showDialog<void>(
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
            const Text('主题色',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Row(
              children: [
                for (var i = 0; i < AppTheme.accents.length; i++)
                  GestureDetector(
                    onTap: () {
                      AppTheme.accent.value = AppTheme.accents[i];
                      SharedPreferences.getInstance().then((sp) => sp.setInt(
                          'accent_color',
                          AppTheme.accents[i].toARGB32()));
                      setState(() {});
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.accents[i],
                        shape: BoxShape.circle,
                        border: AppTheme.accent.value == AppTheme.accents[i]
                            ? Border.all(color: Colors.white, width: 3)
                            : null,
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 4)
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _settingTile(IconData icon, String title, String sub,
      VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Glass(
        radius: 8,
        child: ListTile(
          dense: true,
          leading: Icon(icon, color: _accent),
          title: Text(title),
          subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: onTap,
        ),
      ),
    );
  }

  Widget _actionBar(List<Widget> children) {
    return Glass(
      radius: 22,
      blur: 18,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: children),
    );
  }

  Widget _actionBtn(String label, IconData icon, VoidCallback onTap) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: _accent),
      label: Text(label,
          style: TextStyle(color: Colors.grey.shade800, fontSize: 13)),
    );
  }

  // ---------- 操作 ----------

  Future<void> _importLocalBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub', 'cbz', 'zip'],
      withData: true,
    );
    final files = result?.files ?? const [];
    if (files.isEmpty || files.first.bytes == null) return;
    final picked = files.first;
    try {
      final book =
          await LocalBookSource.importBytes(picked.name, picked.bytes!);
      await ref.read(libraryProvider.notifier).addToShelf(book);
      await _loadAll();
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

  Future<void> _deleteLocal(Book b) async {
    final ok = await _confirm('删除本地书', '确定删除「${b.name}」及其所有章节/图片？');
    if (!ok) return;
    await LocalBookSource.delete(b.bookUrl);
    await _loadLocal();
  }

  Future<void> _clearLocalCache() async {
    if (_localBooks.isEmpty) return;
    final ok = await _confirm('清空本地书缓存',
        '将删除全部 ${_localBooks.length} 本本地书及其文件（书架也会移除）。确定？');
    if (!ok) return;
    for (final b in _localBooks) {
      await LocalBookSource.delete(b.bookUrl);
      await ref.read(libraryProvider.notifier).removeFromShelf(b);
    }
    await _loadLocal();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地书缓存已清空')),
      );
    }
  }

  // ---------- 备份与恢复 ----------

  Future<void> _showBackupSheet() async {
    final action = await showDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => GlassDialog(
        child: Glass(
        radius: 20,
        blur: 18,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('备份与恢复',
                style:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.upload),
                  label: const Text('导出备份'),
                  onPressed: () => Navigator.pop(context, 'export'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('恢复备份'),
                  onPressed: () => Navigator.pop(context, 'import'),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
    if (action == 'export') await _backup();
    if (action == 'import') await _restore();
  }

  /// 导出：书架 + 全部进度（索引/标题/时间）打包 JSON
  Future<void> _backup() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final sp = await SharedPreferences.getInstance();
      final progress = <String, dynamic>{};
      for (final k in sp.getKeys()) {
        if (k.startsWith('progress_')) {
          final iv = sp.getInt(k);
          if (iv != null) {
            progress[k] = iv;
            continue;
          }
          final sv = sp.getString(k);
          if (sv != null) progress[k] = sv;
        }
      }
      final data = {
        'shelf': sp.getStringList('shelf_books') ?? const [],
        'progress': progress,
      };
      // file_picker 8.x 在 Windows 上 saveFile 不支持 bytes 写盘，
      // 先取保存路径再手动写入，避免「导出没反应/报错」。
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出备份',
        fileName: '悦读备份_${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path != null) {
        await File(path).writeAsString(jsonEncode(data), encoding: utf8);
      }
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(path != null ? '备份已导出' : '已取消导出'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  /// 恢复：读备份 JSON，写回书架 + 进度
  Future<void> _restore() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final f = result?.files.firstOrNull;
    if (f == null || f.bytes == null) return;
    try {
      final data = jsonDecode(utf8.decode(f.bytes!)) as Map<String, dynamic>;
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList('shelf_books',
          (data['shelf'] as List<dynamic>? ?? []).cast<String>());
      final progress = data['progress'] as Map<String, dynamic>? ?? {};
      for (final e in progress.entries) {
        final v = e.value;
        if (v is int) {
          await sp.setInt(e.key, v);
        } else if (v is String) {
          await sp.setString(e.key, v);
        }
      }
      await ref.read(libraryProvider.notifier).load();
      await _loadAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('备份已恢复'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败：$e')),
        );
      }
    }
  }

  Future<void> _clearAll() async {
    final ok = await _confirm('清除阅读记录',
        '将清空书架与所有阅读进度，此操作不可撤销。');
    if (!ok) return;
    final sp = await SharedPreferences.getInstance();
    final keys = sp.getKeys().where((k) => k.startsWith('progress_')).toList();
    for (final k in keys) {
      await sp.remove(k);
    }
    await sp.remove('shelf_books');
    await _loadProgress();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('阅读记录已清除')),
      );
    }
  }

  Future<bool> _confirm(String title, String msg) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (context) => Glass(
        radius: 20,
        blur: 18,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(msg),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确定')),
              ],
            ),
          ],
        ),
      ),
    );
    return r == true;
  }
}

/// 阅读设置：字号 / 背景主题（与阅读器共用 key）。
class _ReaderSettingsPage extends StatefulWidget {
  const _ReaderSettingsPage();

  @override
  State<_ReaderSettingsPage> createState() => _ReaderSettingsPageState();
}

class _ReaderSettingsPageState extends State<_ReaderSettingsPage> {
  double _font = 18;
  int _bg = 0;
  double _line = 1.9;
  int _para = 1;
  int _fontIdx = 0;
  double _bright = 1.0;
  int _turn = 0;
  bool _autoNight = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _font = sp.getDouble('reader_font_size') ?? 18;
      _line = sp.getDouble('reader_line_height') ?? 1.9;
      _para = sp.getInt('reader_para_gap') ?? 1;
      _fontIdx = sp.getInt('reader_font_index') ?? 0;
      _bright = sp.getDouble('reader_brightness') ?? 1.0;
      _turn = sp.getInt('reader_turn_mode') ?? 0;
      _autoNight = sp.getBool('reader_auto_night') ?? true;
      _bg = sp.getInt('reader_bg') ?? 0;
      _loaded = true;
    });
  }

  Widget _card(String title, Widget child) {
    return Glass(
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF555555))),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _sliderCard(String title, double value, double min, double max,
      String label, ValueChanged<double> onChanged) {
    return _card(
        title,
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          label: label,
          onChanged: onChanged,
        ));
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
                // 顶栏：返回 + 标题
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
                      const Text('阅读设置',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                Expanded(
                  child: _loaded
                      ? ListView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          children: [
                            _sliderCard('正文字号', _font, 14, 28,
                                _font.toStringAsFixed(0), (v) async {
                              setState(() => _font = v);
                              final sp = await SharedPreferences.getInstance();
                              await sp.setDouble('reader_font_size', v);
                            }),
                            const SizedBox(height: 12),
                            _sliderCard('行距', _line, 1.4, 2.4,
                                _line.toStringAsFixed(2), (v) async {
                              setState(() => _line = v);
                              final sp = await SharedPreferences.getInstance();
                              await sp.setDouble('reader_line_height', v);
                            }),
                            const SizedBox(height: 12),
                            _sliderCard('段距', _para.toDouble(), 0, 3,
                                _para.toString(), (v) async {
                              setState(() => _para = v.round());
                              final sp = await SharedPreferences.getInstance();
                              await sp.setInt('reader_para_gap', v.round());
                            }),
                            const SizedBox(height: 12),
                            _card(
                                '字体',
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    for (var i = 0;
                                        i < ReaderPrefs.fontNames.length;
                                        i++)
                                      ChoiceChip(
                                        label: Text(ReaderPrefs.fontNames[i]),
                                        selected: _fontIdx == i,
                                        onSelected: (_) async {
                                          setState(() => _fontIdx = i);
                                          final sp = await SharedPreferences
                                              .getInstance();
                                          await sp.setInt(
                                              'reader_font_index', i);
                                        },
                                      ),
                                  ],
                                )),
                            const SizedBox(height: 12),
                            _card(
                                '阅读背景',
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (var i = 0;
                                        i < ReaderPrefs.bgNames.length;
                                        i++)
                                      ChoiceChip(
                                        label: Text(ReaderPrefs.bgNames[i]),
                                        selected: _bg == i,
                                        onSelected: (_) async {
                                          setState(() => _bg = i);
                                          final sp = await SharedPreferences
                                              .getInstance();
                                          await sp.setInt('reader_bg', i);
                                        },
                                      ),
                                  ],
                                )),
                            const SizedBox(height: 12),
                            _sliderCard('亮度', _bright, 0.3, 1.0,
                                '${(_bright * 100).round()}%', (v) async {
                              setState(() => _bright = v);
                              final sp = await SharedPreferences.getInstance();
                              await sp.setDouble('reader_brightness', v);
                            }),
                            const SizedBox(height: 12),
                            _card(
                                '翻页效果',
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    for (var i = 0;
                                        i < ReaderPrefs.turnNames.length;
                                        i++)
                                      ChoiceChip(
                                        label: Text(ReaderPrefs.turnNames[i]),
                                        selected: _turn == i,
                                        onSelected: (_) async {
                                          setState(() => _turn = i);
                                          final sp = await SharedPreferences
                                              .getInstance();
                                          await sp.setInt(
                                              'reader_turn_mode', i);
                                        },
                                      ),
                                  ],
                                )),
                            const SizedBox(height: 12),
                            _card(
                                '夜间自动切换',
                                SwitchListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('21:00 - 7:00 自动夜间主题',
                                      style: TextStyle(fontSize: 13)),
                                  value: _autoNight,
                                  onChanged: (v) async {
                                    setState(() => _autoNight = v);
                                    final sp = await SharedPreferences
                                        .getInstance();
                                    await sp.setBool(
                                        'reader_auto_night', v);
                                  },
                                )),
                          ],
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
