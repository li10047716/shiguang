/// 我的页：自适应图标宫格，每项功能直接对应一个图标入口。
///
/// 手机 2 列、平板 3 列、桌面 4 列。动作型入口直接执行/弹窗，
/// 页面型入口（本地书列表、书源管理、阅读设置）进入独立子页。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../services/chapter_cache.dart';
import '../../services/library.dart';
import '../../services/toc_cache.dart';
import '../../sources/source.dart';
import '../../sources/builtin/builtin_sources.dart';
import '../../sources/source_registry.dart';
import '../app_theme.dart';
import '../book/book_detail_page.dart';
import '../glass.dart';
import 'cache_manager_page.dart';
import '../reader/reader_prefs.dart';
import '../widgets/cover_image.dart';
import '../widgets/type_tag.dart';

/// 跟随全局主题色（ About 页图标/开关等装饰色与之一致）
Color get _accent => AppTheme.accent.value;

// ---------- 公共工具 ----------

Future<bool> _confirm(BuildContext context, String title, String msg) async {
  final r = await showDialog<bool>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => FlatDialog(
      child: FlatCard(
        radius: 20,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
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
    ),
  );
  return r == true;
}

// ---------- 主界面：图标宫格 ----------

class MinePage extends ConsumerStatefulWidget {
  const MinePage({super.key});

  @override
  ConsumerState<MinePage> createState() => _MinePageState();
}

class _MinePageState extends ConsumerState<MinePage> {
  List<Book> _recentBooks = [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  /// 最近阅读：按 progress_time_ 时间戳取书架里最近打开的书。
  Future<void> _loadRecent() async {
    await ref.read(libraryProvider.notifier).load();
    final sp = await SharedPreferences.getInstance();
    final books = ref.read(libraryProvider);
    final recent = books.where((b) => b.type == ContentType.novel).toList()
      ..sort((a, b) => (sp.getInt('progress_time_${b.bookUrl}') ?? 0)
          .compareTo(sp.getInt('progress_time_${a.bookUrl}') ?? 0));
    final withProgress =
        recent.where((b) => sp.getInt('progress_time_${b.bookUrl}') != null);
    final result = (withProgress.isNotEmpty ? withProgress : recent).take(10).toList();
    if (!mounted) return;
    setState(() => _recentBooks = result);
  }

  @override
  Widget build(BuildContext context) {
    final content = <(IconData, String, VoidCallback)>[
      (Icons.download_outlined, '下载管理',
          () => _push('下载管理', const CacheManagerPage())),
      (Icons.library_books_outlined, '书源管理',
          () => _push('书源管理', const _SourcesPage())),
    ];
    final system = <(IconData, String, VoidCallback)>[
      (Icons.chrome_reader_mode_outlined, '阅读设置',
          () => _push('阅读设置', const _ReaderSettingsPage())),
      (Icons.palette_outlined, '主题色',
          () => _push('主题色', const _ThemeColorPage())),
      (Icons.cloud_sync_outlined, '备份管理',
          () => _push('备份管理', const _BackupPage())),
      (Icons.cleaning_services_outlined, '清除缓存',
          () => _push('清除缓存', const _ClearCachePage())),
      (Icons.info_outlined, '关于',
          () => _push('关于', const _AboutPage())),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_recentBooks.isNotEmpty) _recentSection(),
          const SizedBox(height: 12),
          _groupCard('内容管理', content),
          const SizedBox(height: 12),
          _groupCard('系统设置', system),
        ],
      ),
    );
  }

  /// 最近阅读：一行横向封面，与书架卡片同款。
  Widget _recentSection() {
    return FlatCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 0, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('最近阅读',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF222222))),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 16),
              itemCount: _recentBooks.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final b = _recentBooks[i];
                return GestureDetector(
                  onTap: () => _openBook(b),
                  child: SizedBox(
                    width: 92,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: b.cover.isEmpty
                              ? Container(
                                  width: 92,
                                  height: 118,
                                  color: Colors.grey.shade200,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.menu_book,
                                      size: 30, color: Colors.grey))
                              : CoverImage(b.cover,
                                  sourceId: b.sourceId, width: 92, height: 118),
                        ),
                        const SizedBox(height: 6),
                        Text(b.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF333333))),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 分组白色卡片：标题 + 图标宫格（动作型入口直接执行）。
  Widget _groupCard(String title, List<(IconData, String, VoidCallback)> items) {
    return FlatCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF222222))),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final cols = w >= 900 ? 6 : (w >= 600 ? 5 : 4);
              const gap = 8.0;
              final itemW = (w - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: 6,
                children: [
                  for (final e in items)
                    SizedBox(width: itemW, child: _toolTile(e.$1, e.$2, e.$3)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _toolTile(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: const Color(0xFF222222)),
            const SizedBox(height: 8),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF333333))),
          ],
        ),
      ),
    );
  }

  void _openBook(Book b) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BookDetailPage(book: b)),
    );
  }

  void _push(String title, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SubPage(title: title, child: page),
    ));
  }

  // ---------- 动作：通用 ----------
}

// ---------- 备份：导出/导入/历史（供 _BackupPage 使用） ----------

/// 备份历史条目
class _BackupRecord {
  final int time; // 毫秒时间戳
  final String kind; // full / quick
  final String name; // 文件名
  final String path;

  const _BackupRecord({
    required this.time,
    required this.kind,
    required this.name,
    required this.path,
  });

  Map<String, dynamic> toJson() =>
      {'t': time, 'k': kind, 'n': name, 'p': path};

  static _BackupRecord fromJson(Map<String, dynamic> j) => _BackupRecord(
        time: j['t'] is int ? j['t'] as int : 0,
        kind: j['k']?.toString() ?? 'quick',
        name: j['n']?.toString() ?? '',
        path: j['p']?.toString() ?? '',
      );

  static Future<List<_BackupRecord>> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList('backup_history') ?? const [];
    return raw
        .map((e) {
          try {
            return _BackupRecord.fromJson(
                jsonDecode(e) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<_BackupRecord>()
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  }

  static Future<void> save(List<_BackupRecord> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
        'backup_history', list.map((e) => jsonEncode(e.toJson())).toList());
  }
}

/// 导出备份。[full] = 完整备份（书架+进度+设置+书源），否则快速备份（书架+进度）。
Future<void> _exportBackup(
  BuildContext context, {
  required bool full,
  VoidCallback? onDone,
}) async {
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
    final data = <String, dynamic>{
      'app': 'reading_app',
      'kind': full ? 'full' : 'quick',
      'shelf': sp.getStringList('shelf_books') ?? const [],
      'progress': progress,
    };
    if (full) {
      data['settings'] = {
        'dark_mode': sp.getInt('dark_mode'),
        'accent_color': sp.getInt('accent_color'),
        'update_notify': sp.getBool('update_notify'),
      };
      data['custom_sources'] = sp.getStringList('custom_sources') ?? const [];
      data['disabled_sources'] = sp.getStringList('disabled_sources') ?? const [];
    }
    final kindName = full ? '完整备份' : '快速备份';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: kindName,
      fileName: '悦读${full ? '完整' : '快速'}备份_${DateTime.now().millisecondsSinceEpoch}.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path != null) {
      await File(path).writeAsString(jsonEncode(data), encoding: utf8);
      final list = await _BackupRecord.load();
      list.insert(
        0,
        _BackupRecord(
          time: DateTime.now().millisecondsSinceEpoch,
          kind: full ? 'full' : 'quick',
          name: path.split(Platform.pathSeparator).last,
          path: path,
        ),
      );
      await _BackupRecord.save(list);
      onDone?.call();
    }
    if (context.mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(path != null ? '$kindName已导出' : '已取消'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }
}

/// 导入备份并恢复
Future<void> _importBackup(
  BuildContext context,
  Future<void> Function() reload,
) async {
  final messenger = ScaffoldMessenger.of(context);
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
    await sp.setStringList(
        'shelf_books', (data['shelf'] as List<dynamic>? ?? []).cast<String>());
    final progress = data['progress'] as Map<String, dynamic>? ?? {};
    for (final e in progress.entries) {
      final v = e.value;
      if (v is int) {
        await sp.setInt(e.key, v);
      } else if (v is String) {
        await sp.setString(e.key, v);
      }
    }
    final settings = data['settings'];
    if (settings is Map<String, dynamic>) {
      final dm = settings['dark_mode'];
      if (dm is int) await sp.setInt('dark_mode', dm);
      final ac = settings['accent_color'];
      if (ac is int) await sp.setInt('accent_color', ac);
      final un = settings['update_notify'];
      if (un is bool) await sp.setBool('update_notify', un);
    }
    final cs = data['custom_sources'];
    if (cs is List<dynamic>) {
      await sp.setStringList('custom_sources', cs.cast<String>());
    }
    final ds = data['disabled_sources'];
    if (ds is List<dynamic>) {
      await sp.setStringList('disabled_sources', ds.cast<String>());
    }
    await reload();
    if (context.mounted) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text('备份已恢复'), duration: Duration(seconds: 1)),
      );
    }
  } catch (e) {
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text('恢复失败：$e')));
    }
  }
}

// ---------- 子页：备份管理 ----------

class _BackupPage extends ConsumerStatefulWidget {
  const _BackupPage();

  @override
  ConsumerState<_BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<_BackupPage> {
  List<_BackupRecord> _records = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _BackupRecord.load();
    if (!mounted) return;
    setState(() {
      _records = list;
      _loaded = true;
    });
  }

  Future<void> _deleteRecord(_BackupRecord r) async {
    final list = await _BackupRecord.load()..removeWhere((e) => e.time == r.time);
    await _BackupRecord.save(list);
    _load();
  }

  Future<void> _clearHistory() async {
    final ok = await _confirm(context, '清空历史', '确定清空备份历史记录？备份文件不会被删除。');
    if (!ok) return;
    await _BackupRecord.save([]);
    _load();
  }

  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      children: [
        // 备份操作卡
        FlatCard(
          radius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Text('备份操作',
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade500)),
              ),
              _actionRow(
                icon: Icons.cloud_upload_outlined,
                color: const Color(0xFF3D8AF7),
                label: '完整备份',
                sub: '书架 + 进度 + 设置 + 书源',
                onTap: () => _exportBackup(context,
                    full: true, onDone: _load),
              ),
              _actionRow(
                icon: Icons.bolt_outlined,
                color: const Color(0xFF3D8AF7),
                label: '快速备份',
                sub: '书架 + 阅读进度',
                onTap: () => _exportBackup(context,
                    full: false, onDone: _load),
              ),
              _actionRow(
                icon: Icons.restore_outlined,
                color: const Color(0xFF3D8AF7),
                label: '导入备份',
                sub: '从备份文件恢复',
                onTap: () => _importBackup(context, () async {
                  await ref.read(libraryProvider.notifier).load();
                  _load();
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 备份历史卡
        FlatCard(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('备份历史',
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade500)),
                  ),
                  if (_records.isNotEmpty)
                    GestureDetector(
                      onTap: _clearHistory,
                      child: Text('清空',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (_records.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      Icon(Icons.history_outlined,
                          size: 44, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text('暂无备份历史',
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey.shade500)),
                      const SizedBox(height: 6),
                      Text('点击「快速备份」开始创建备份',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade400)),
                    ],
                  ),
                )
              else
                for (final r in _records)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(
                          r.kind == 'full'
                              ? Icons.cloud_done_outlined
                              : Icons.bolt_outlined,
                          size: 18,
                          color: const Color(0xFF3D8AF7),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF333333))),
                              const SizedBox(height: 2),
                              Text(
                                '${_fmtTime(r.time)} · ${r.kind == 'full' ? '完整备份' : '快速备份'}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade500),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '删除记录',
                          icon: Icon(Icons.close,
                              size: 16, color: Colors.grey.shade400),
                          onPressed: () => _deleteRecord(r),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actionRow({
    required IconData icon,
    required Color color,
    required String label,
    required String sub,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF222222))),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }
}

// ---------- 子页：清除缓存 ----------

class _ClearCachePage extends StatefulWidget {
  const _ClearCachePage();

  @override
  State<_ClearCachePage> createState() => _ClearCachePageState();
}

class _ClearCachePageState extends State<_ClearCachePage> {
  int _coverBytes = 0;
  int _bookBytes = 0;
  int _bookDirs = 0;
  int _tocBytes = 0;
  int _tocCount = 0;
  int _backupCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<int> _dirSize(Directory dir) async {
    var total = 0;
    if (!await dir.exists()) return 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<void> _load() async {
    final support = await getApplicationSupportDirectory();
    final coverDir = Directory('${support.path}/cover_cache');
    final coverBytes = await _dirSize(coverDir);
    final books = await ChapterCache.allBooks();
    final bookBytes = await ChapterCache.totalBytes();
    final tocBytes = await TocCache.bytesUsed();
    final tocCount = await TocCache.count();
    final records = await _BackupRecord.load();
    if (!mounted) return;
    setState(() {
      _coverBytes = coverBytes;
      _bookBytes = bookBytes;
      _bookDirs = books.length;
      _tocBytes = tocBytes;
      _tocCount = tocCount;
      _backupCount = records.length;
      _loading = false;
    });
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _clearKind(String kind) async {
    final String title;
    switch (kind) {
      case 'cover':
        title = '确定清除全部封面图片缓存？清除后首次加载会重新下载。';
        break;
      case 'book':
        title = '确定清除全部章节缓存？离线阅读需重新缓存。';
        break;
      case 'toc':
        title = '确定清除全部目录缓存？';
        break;
      default:
        title = '确定清空备份历史记录？备份文件不会被删除。';
    }
    final ok = await _confirm(context, '清除缓存', title);
    if (!ok || !mounted) return;
    switch (kind) {
      case 'cover':
        final support = await getApplicationSupportDirectory();
        final dir = Directory('${support.path}/cover_cache');
        if (await dir.exists()) {
          await for (final e in dir.list()) {
            if (e is File) {
              try {
                await e.delete();
              } catch (_) {}
            }
          }
        }
        break;
      case 'book':
        await ChapterCache.clearAll();
        break;
      case 'toc':
        await TocCache.clearAll();
        break;
      default:
        await _BackupRecord.save([]);
    }
    _tip('已清除');
    _load();
  }

  void _tip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final total = _coverBytes + _bookBytes + _tocBytes;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      children: [
        // 总缓存大小卡
        FlatCard(
          radius: 16,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.storage_outlined,
                    size: 26, color: Colors.grey.shade700),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('总缓存大小',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Text(_fmt(total),
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF222222))),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 分节标题
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Icon(Icons.cleaning_services_outlined,
                  size: 16, color: const Color(0xFF3D8AF7)),
              const SizedBox(width: 6),
              Text('缓存清理',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF222222))),
            ],
          ),
        ),
        _clearCard(
          icon: Icons.image_outlined,
          color: const Color(0xFF4CAF7D),
          bg: const Color(0xFFE8F5EF),
          label: '图片缓存',
          sub: '封面缓存: ${_fmt(_coverBytes)}',
          chip: _fmt(_coverBytes),
          chipColor: const Color(0xFF4CAF7D),
          onTap: () => _clearKind('cover'),
        ),
        _clearCard(
          icon: Icons.auto_stories_outlined,
          color: const Color(0xFFE8A13A),
          bg: const Color(0xFFFDF3E3),
          label: '书本缓存',
          sub: '$_bookDirs 本书章节缓存',
          chip: _fmt(_bookBytes),
          chipColor: const Color(0xFFE8A13A),
          onTap: () => _clearKind('book'),
        ),
        _clearCard(
          icon: Icons.list_alt_outlined,
          color: const Color(0xFF3D8AF7),
          bg: const Color(0xFFE8F1FD),
          label: '目录缓存',
          sub: '$_tocCount 个目录记录',
          chip: _fmt(_tocBytes),
          chipColor: const Color(0xFF3D8AF7),
          onTap: () => _clearKind('toc'),
        ),
        _clearCard(
          icon: Icons.cloud_upload_outlined,
          color: const Color(0xFF3D8AF7),
          bg: const Color(0xFFE8F1FD),
          label: '数据备份',
          sub: '$_backupCount 条备份历史',
          chip: '$_backupCount 条',
          chipColor: const Color(0xFF3D8AF7),
          onTap: () => _clearKind('backup'),
        ),
      ],
    );
  }

  Widget _clearCard({
    required IconData icon,
    required Color color,
    required Color bg,
    required String label,
    required String sub,
    required String chip,
    required Color chipColor,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FlatCard(
        radius: 16,
        padding: const EdgeInsets.all(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 22, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF222222))),
                    const SizedBox(height: 2),
                    Text(sub,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(chip,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: chipColor)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 子页：关于 ----------

class _AboutPage extends StatefulWidget {
  const _AboutPage();

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  bool _updateNotify = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((sp) {
      if (!mounted) return;
      setState(() => _updateNotify = sp.getBool('update_notify') ?? true);
    });
  }

  Future<void> _toggleNotify(bool v) async {
    setState(() => _updateNotify = v);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('update_notify', v);
  }

  void _showDoc(String title, String body) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => FlatDialog(
        child: FlatCard(
          radius: 20,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Text(body,
                  style:
                      TextStyle(fontSize: 13, color: Colors.grey.shade700)),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _tip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      children: [
        const SizedBox(height: 24),
        // 应用图标 + 名称 + 版本
        Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.menu_book, size: 40, color: _accent),
            ),
            const SizedBox(height: 14),
            const Text('悦读',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('版本 1.0.0',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
        const SizedBox(height: 28),
        // 信息卡
        FlatCard(
          radius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              _aboutRow('用户协议',
                  onTap: () => _showDoc('用户协议', '本应用仅供学习与个人阅读使用，'
                      '书籍内容均来自网络公开书源，请支持正版。继续使用即视为同意本协议。')),
              _divider(),
              _aboutRow('隐私声明',
                  onTap: () => _showDoc('隐私声明', '本应用不收集、上传任何个人数据；'
                      '书架、进度、缓存均保存在本地设备。')),
              _divider(),
              _aboutRow('免责声明',
                  onTap: () => _showDoc('免责声明', '本应用不存储任何书籍内容，'
                      '所有内容均来自用户添加的书源站点，内容的准确性、合法性由来源站点负责。')),
              _divider(),
              _aboutRow('错误日志', onTap: () => _tip('暂无错误日志')),
              _divider(),
              SwitchListTile(
                value: _updateNotify,
                onChanged: _toggleNotify,
                activeTrackColor: _accent,
                thumbColor: const WidgetStatePropertyAll(Colors.white),
                contentPadding: EdgeInsets.zero,
                title: const Text('更新提醒',
                    style: TextStyle(
                        fontSize: 15, color: Color(0xFF333333))),
              ),
              _divider(),
              _aboutRow('检查更新', onTap: () => _tip('当前已是最新版本')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _divider() => Divider(height: 1, color: Colors.grey.shade200);

  Widget _aboutRow(String label, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 15, color: Color(0xFF333333))),
            ),
            Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }
}

/// 统一子页外壳：返回按钮 + 标题 + 内容，跟随全局背景。
class _SubPage extends StatelessWidget {
  final String title;
  final Widget child;

  const _SubPage({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: AppBackground()),
          SafeArea(
            child: Column(
              children: [
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
                      Text(title,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 子页：主题色（作用于整个应用，与阅读背景无关） ----------

class _ThemeColorPage extends StatelessWidget {
  const _ThemeColorPage();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: AppTheme.accent,
      builder: (context, accent, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            FlatCard(
              radius: 16,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('应用主题色',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF555555))),
                  const SizedBox(height: 8),
                  const Text('作用于整个应用（导航、按钮、刷新圈等），与阅读界面的背景设置相互独立。',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < AppTheme.accents.length; i++)
                        _swatch(i, accent),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _swatch(int i, Color current) {
    final color = AppTheme.accents[i];
    final selected = color.toARGB32() == current.toARGB32();
    return GestureDetector(
      onTap: () async {
        AppTheme.accent.value = color;
        final sp = await SharedPreferences.getInstance();
        await sp.setInt('accent_color', color.toARGB32());
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? const Color(0xFF222222) : Colors.transparent,
                width: 2,
              ),
              boxShadow: selected
                  ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8)]
                  : null,
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white, size: 22)
                : null,
          ),
          const SizedBox(height: 6),
          Text(AppTheme.accentNames[i],
              style: TextStyle(
                  fontSize: 12,
                  color: selected ? const Color(0xFF222222) : Colors.grey)),
        ],
      ),
    );
  }
}

// ---------- 子页：书源管理 ----------

class _SourcesPage extends StatefulWidget {
  const _SourcesPage();

  @override
  State<_SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<_SourcesPage> {
  @override
  Widget build(BuildContext context) {
    final repo = SourceRepository();
    final sources = SourceRegistry()
        .all
        .where((s) => s.sourceId != 'loc' && s.type == ContentType.novel)
        .toList();
    return ReorderableListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      // 关掉系统默认手柄，改用左侧自定义拖动按钮
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) =>
          _onReorder(sources, oldIndex - 1, newIndex - 1),
      children: [
        const Padding(
          key: ValueKey('__sources_header__'),
          padding: EdgeInsets.only(bottom: 8),
          child: Text('书源管理',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
        ),
        for (var i = 0; i < sources.length; i++)
          Builder(key: ValueKey(sources[i].sourceId), builder: (context) {
            final s = sources[i];
            final rule = repo.byId(s.sourceId);
            final isBuiltin = rule == null;
            final isCustom = !isBuiltin && repo.isCustom(s.sourceId);
            return Padding(
              key: ValueKey(s.sourceId),
              padding: const EdgeInsets.only(bottom: 6),
              child: FlatCard(
                radius: 8,
                child: Row(
                  children: [
                    // 拖动排序手柄：按住上下拖动调整书源顺序（手机/桌面通用）
                    ReorderableDragStartListener(
                      index: i + 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        child: Icon(Icons.drag_indicator,
                            size: 20, color: Colors.grey.shade500),
                      ),
                    ),
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
                            const TypeTag(),
                          ],
                        ),
                        subtitle: Text(
                          isBuiltin ? '内置书源（可启停）' : rule.baseUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: SourceRegistry().isEnabled(s.sourceId),
                        onChanged: (v) async {
                          await SourceRegistry().toggleEnabled(s.sourceId, v);
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

  /// 拖拽排序：把显示列表 [shown] 中第 [oldIndex] 项拖到 [newIndex]。
  /// 显示列表过滤掉了本地源/其它类型，因此要把新顺序映射回完整书源顺序再持久化。
  Future<void> _onReorder(
      List<NovelSource> shown, int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= shown.length) return;
    // onReorderItem 已自动为「向下拖」调整过 newIndex，无需再减 1。
    if (newIndex < 0 || newIndex >= shown.length || oldIndex == newIndex) {
      return;
    }

    final shownIds = shown.map((s) => s.sourceId).toList();
    final moved = shownIds.removeAt(oldIndex);
    shownIds.insert(newIndex, moved);

    // 完整顺序里，只替换「显示中的源」所占的槽位，其它源（本地源等）位置不变
    final allIds = SourceRegistry().all.map((s) => s.sourceId).toList();
    final shownSet = shownIds.toSet();
    var k = 0;
    for (var i = 0; i < allIds.length; i++) {
      if (shownSet.contains(allIds[i])) {
        allIds[i] = shownIds[k++];
      }
    }
    await SourceRegistry().setOrder(allIds);
    if (mounted) setState(() {});
  }

  Future<void> _removeSource(SourceRepository repo, String id) async {
    final ok = await _confirm(context, '删除书源', '删除该书源？（不影响已加入书架的书）');
    if (!ok) return;
    await repo.removeCustom(id);
    SourceRegistry().reload();
    setState(() {});
  }
}

// ---------- 子页：阅读设置 ----------

class _ReaderSettingsPage extends StatefulWidget {
  const _ReaderSettingsPage();

  @override
  State<_ReaderSettingsPage> createState() => _ReaderSettingsPageState();
}

class _ReaderSettingsPageState extends State<_ReaderSettingsPage> {
  double _font = 18;
  int _bg = 0;
  double _line = 1.9;
  double _para = 0.5;
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
      final pg = sp.get('reader_para_gap');
      _para = pg is int ? pg.toDouble() : (pg is double ? pg : 0.5);
      _bright = sp.getDouble('reader_brightness') ?? 1.0;
      _turn = sp.getInt('reader_turn_mode') ?? 0;
      _autoNight = sp.getBool('reader_auto_night') ?? true;
      _bg = sp.getInt('reader_bg') ?? 0;
      _loaded = true;
    });
  }

  Widget _card(String title, Widget child) {
    return FlatCard(
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
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
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
        ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        _sliderCard('正文字号', _font, 14, 28, _font.toStringAsFixed(0), (v) async {
          setState(() => _font = v);
          final sp = await SharedPreferences.getInstance();
          await sp.setDouble('reader_font_size', v);
        }),
        const SizedBox(height: 12),
        _sliderCard('行距', _line, 1.4, 2.4, _line.toStringAsFixed(2), (v) async {
          setState(() => _line = v);
          final sp = await SharedPreferences.getInstance();
          await sp.setDouble('reader_line_height', v);
        }),
        const SizedBox(height: 12),
        _sliderCard('段距', _para, 0, 3, _para.toStringAsFixed(1), (v) async {
          setState(() => _para = v);
          final sp = await SharedPreferences.getInstance();
          await sp.setDouble('reader_para_gap', v);
        }),
        const SizedBox(height: 12),
        _card(
            '阅读背景',
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < ReaderPrefs.bgNames.length; i++)
                  ChoiceChip(
                    label: Text(ReaderPrefs.bgNames[i]),
                    selected: _bg == i,
                    onSelected: (_) async {
                      setState(() => _bg = i);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setInt('reader_bg', i);
                    },
                  ),
              ],
            )),
        const SizedBox(height: 12),
        _sliderCard('亮度', _bright, 0.3, 1.0, '${(_bright * 100).round()}%',
            (v) async {
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
                for (var i = 0; i < ReaderPrefs.turnNames.length; i++)
                  ChoiceChip(
                    label: Text(ReaderPrefs.turnNames[i]),
                    selected: _turn == i,
                    onSelected: (_) async {
                      setState(() => _turn = i);
                      final sp = await SharedPreferences.getInstance();
                      await sp.setInt('reader_turn_mode', i);
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
                final sp = await SharedPreferences.getInstance();
                await sp.setBool('reader_auto_night', v);
              },
            )),
      ],
    );
  }
}
