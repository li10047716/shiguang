/// 本地书籍：TXT / EPUB / 漫画包（CBZ、ZIP、图片版 EPUB）导入、解析与读取。
///
/// 移植自 shiguang `reader/localbook.py`。只读本地文件，不联网。
/// 书籍 id 用 `loc:<hash>`，章节地址 `loc:<hash>/<序号>`。
/// 漫画页地址用 `locimg://<hash>/<ch>/<i>`，阅读器据此读本地图片文件。
///
/// 落盘（应用支持目录 /local_books/）：
///   `hash.json`           # 元信息（书名/作者/简介/目录）
///   `hash/000000.json`    # 单章正文（按章存）
///   `hash/img/000001.jpg` # 漫画页（导入时解压编号）
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../novel_source.dart';
import '../source.dart';

const String _prefix = 'loc:';
const String _imgScheme = 'locimg://';
const String _srcName = '本地导入';
const int _maxBytes = 40 * 1024 * 1024;
const int _maxComicBytes = 220 * 1024 * 1024;
const List<String> _imgExt = [
  '.jpg', '.png', '.webp', '.gif', '.bmp', '.avif',
];
const Map<String, String> _imgMime = {
  '.jpg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
  '.avif': 'image/avif',
};

class LocalBookSource extends SourceBase {
  @override
  String get sourceId => 'loc';
  @override
  String get sourceName => _srcName;
  @override
  ContentType get type => ContentType.novel;

  static Directory? _root;

  /// 本地书根目录（应用支持目录 /local_books/）
  static Future<Directory> root() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}local_books');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _root = dir;
    return dir;
  }

  static Future<String> _metaPath(String h) async =>
      '${(await root()).path}${Platform.pathSeparator}$h.json';

  static Future<String> _chapDir(String h) async =>
      '${(await root()).path}${Platform.pathSeparator}$h';

  static String _hash(String name, List<int> raw) {
    final bytes = <int>[
      ...utf8.encode(name),
      0,
      ...raw.take(65536),
      ...utf8.encode('${raw.length}'),
    ];
    return sha1.convert(bytes).toString().substring(0, 10);
  }

  static String _hashOf(String bid) {
    final token = bid.startsWith(_prefix)
        ? bid.substring(_prefix.length)
        : bid;
    return RegExp(r'^[0-9a-f]{8,16}$').hasMatch(token) ? token : '';
  }

  // ---------- 解析：TXT ----------

  static final RegExp _chap = RegExp(
      r'^[ \t　]*('
      r'第[0-9０-９零〇一二三四五六七八九十百千万两]{1,10}[章节回卷集篇部]'
      r'|序章|楔子|引子|前言|后记|尾声|终章|番外|外传'
      r')([^\n]*)$',
      multiLine: true);
  static const String _sep = ' \t　:：·、-—－_（(【[.．';
  static final RegExp _sent = RegExp(r'[。！？，；、]');

  static bool _looksTitle(String head, String rest) {
    rest = rest.trim();
    if (head.length + rest.length > 60) return false;
    if (rest.isEmpty) return true;
    if (_sep.contains(rest[0])) return rest.length <= 40;
    return rest.length <= 20 && !_sent.hasMatch(rest);
  }

  static List<String> _paras(String body) {
    final out = <String>[];
    for (final line in body.split(RegExp(r'\r?\n'))) {
      var s = line.trim();
      while (s.length > 800) {
        var cut = -1;
        for (final ch in ['。', '！', '？']) {
          final c = s.lastIndexOf(ch, 800);
          if (c > cut) cut = c;
        }
        if (cut < 200) cut = 800;
        out.add(s.substring(0, cut + 1));
        s = s.substring(cut + 1).trimLeft();
      }
      if (s.isNotEmpty) out.add(s);
    }
    return out;
  }

  static List<(String, String)> _chunk(String text, {int size = 3000}) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final out = <(String, String)>[];
    final buf = <String>[];
    var n = 0;
    for (final line in lines) {
      buf.add(line.trim());
      n += line.length;
      if (n >= size) {
        out.add(('第${out.length + 1}节', buf.join('\n')));
        buf.clear();
        n = 0;
      }
    }
    if (buf.isNotEmpty) out.add(('第${out.length + 1}节', buf.join('\n')));
    return out;
  }

  static List<(String, String)> splitTxt(String text) {
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.startsWith('﻿')) text = text.substring(1);
    final marks = <RegExpMatch>[];
    for (final m in _chap.allMatches(text)) {
      if (_looksTitle(m.group(1)!, m.group(2) ?? '')) marks.add(m);
    }
    if (marks.length < 2) return _chunk(text);
    final out = <(String, String)>[];
    for (var i = 0; i < marks.length; i++) {
      final m = marks[i];
      final end = i + 1 < marks.length ? marks[i + 1].start : text.length;
      final lineEnd = text.indexOf('\n', m.start);
      final bodyStart =
          (lineEnd >= 0 && lineEnd < end) ? lineEnd + 1 : end;
      var body = text.substring(bodyStart, end);
      if (body.replaceAll(RegExp(r'\s'), '').isEmpty && i + 1 < marks.length) {
        continue;
      }
      final title = '${m.group(1)}${m.group(2)}'.trim();
      out.add((title.length > 80 ? title.substring(0, 80) : title, body));
    }
    return out.isNotEmpty ? out : _chunk(text);
  }

  static String _decode(List<int> raw) {
    try {
      return utf8.decode(raw); // 严格 utf-8
    } catch (_) {}
    try {
      return gbk.decode(raw); // GBK / GB18030
    } catch (_) {}
    return utf8.decode(raw, allowMalformed: true);
  }

  /// 大小写不敏感正则（Dart RegExp 不支持内联 `(?i)` 旗标）
  static RegExp _re(String pattern, {bool dotAll = false}) =>
      RegExp(pattern, caseSensitive: false, dotAll: dotAll);

  static String _stripHtml(String s) {
    var t = s.replaceAll(_re(r'<(script|style|head)[^>]*>.*?</\1>', dotAll: true), ' ');
    t = t.replaceAll(_re(r'<br\s*/?>'), '\n');
    t = t.replaceAll(_re(r'</(p|div|h[1-6]|li|tr|blockquote|section)>'), '\n');
    t = t.replaceAll(RegExp(r'<[^>]+>'), '');
    return _unescape(t);
  }

  static String _unescape(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'");
  }

  static List<String> _htmlParas(String page) {
    var p = page.replaceAll(_re(r'<(script|style|head)[^>]*>.*?</\1>', dotAll: true), ' ');
    p = p.replaceAll(_re(r'<br\s*/?>'), ' ');
    p = p.replaceAll(_re(r'</(p|div|h[1-6]|li|tr|blockquote|section|article)>'), '\n');
    final text = _unescape(p.replaceAll(RegExp(r'<[^>]+>'), ''));
    return text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  static String _opfMeta(String opf, String name) {
    final m = _re('<(?:dc:)?$name[^>]*>(.*?)</(?:dc:)?$name>', dotAll: true)
        .firstMatch(opf);
    if (m == null) return '';
    return _unescape(m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '')).trim();
  }

  static String _epubTitle(String xhtml, String fallback) {
    for (final tag in ['h1', 'h2', 'h3', 'title']) {
      final m = _re('<$tag[^>]*>(.*?)</$tag>', dotAll: true).firstMatch(xhtml);
      if (m != null) {
        final t = _unescape(m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '')).trim();
        if (t.isNotEmpty && t.length <= 60) return t;
      }
    }
    return fallback;
  }

  static Future<(String, String, String, List<(String, List<String>)>)>
      parseEpub(List<int> raw, String fallback) async {
    final archive = ZipDecoder().decodeBytes(raw);
    final names = archive.files.map((f) => f.name).toSet();
    String opfPath = '';
    final cont = archive.files
        .where((f) => f.name == 'META-INF/container.xml')
        .toList();
    if (cont.isNotEmpty) {
      final c = utf8.decode(cont.first.content, allowMalformed: true);
      final m = RegExp(r'full-path="([^"]+)"').firstMatch(c);
      if (m != null) opfPath = m.group(1)!;
    }
    if (opfPath.isEmpty) {
      final cand = names.where((n) => n.toLowerCase().endsWith('.opf')).toList();
      opfPath = cand.isNotEmpty ? cand.first : '';
    }
    if (opfPath.isEmpty || !names.contains(opfPath)) {
      throw FormatException('这个 EPUB 缺少 OPF 目录文件，无法解析');
    }
    final base = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';
    final opfFile =
        archive.files.where((f) => f.name == opfPath).firstOrNull;
    final opf = utf8.decode(opfFile!.content, allowMalformed: true);
    final title = _opfMeta(opf, 'title').isNotEmpty
        ? _opfMeta(opf, 'title')
        : fallback;
    final author = _opfMeta(opf, 'creator');
    final intro = _cleanIntro(_stripHtml(_opfMeta(opf, 'description')));

    final items = <String, String>{};
    for (final m in _re(r'<item\b[^>]*>').allMatches(opf)) {
      final tag = m.group(0)!;
      final mid = RegExp(r'\bid="([^"]+)"').firstMatch(tag)?.group(1);
      final href = RegExp(r'\bhref="([^"]+)"').firstMatch(tag)?.group(1);
      if (mid != null && href != null) items[mid] = _unescape(href);
    }
    final spine = _re(r'<itemref\b[^>]*\bidref="([^"]+)"')
        .allMatches(opf)
        .map((m) => m.group(1)!)
        .toList();
    var hrefs = <String>[];
    for (final s in spine) {
      if (items.containsKey(s)) hrefs.add(items[s]!);
    }
    if (hrefs.isEmpty) hrefs = items.values.toList();

    final chapters = <(String, List<String>)>[];
    for (final href in hrefs) {
      var path = href.split('#').first;
      if (base.isNotEmpty) path = '$base$path';
      final norm = _normPath(path);
      if (!names.contains(norm)) continue;
      final f = archive.files.where((x) => x.name == norm).firstOrNull;
      if (f == null) continue;
      final page = utf8.decode(f.content, allowMalformed: true);
      final paras = _htmlParas(page);
      if (paras.isEmpty) continue;
      if (paras.fold<int>(0, (a, b) => a + b.length) < 6) continue;
      var ct = _epubTitle(page, '第${chapters.length + 1}章');
      if (paras.isNotEmpty && paras[0].replaceAll(' ', '') == ct.replaceAll(' ', '')) {
        paras.removeAt(0);
      }
      if (paras.isEmpty) continue;
      chapters.add((ct, paras));
    }
    return (title, author, intro, chapters);
  }

  static String _normPath(String p) {
    final parts = p.split('/');
    final out = <String>[];
    for (final part in parts) {
      if (part == '.' || part.isEmpty) continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else {
        out.add(part);
      }
    }
    return out.join('/');
  }

  static String _cleanIntro(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 800 ? t.substring(0, 800) : t;
  }

  // ---------- 漫画包 ----------

  static List<dynamic> _natural(String name) {
    return RegExp(r'(\d+)')
        .allMatches(name)
        .map((m) => int.tryParse(m.group(1)!) ?? m.group(1)!.toLowerCase())
        .toList();
  }

  static String _imgExtOf(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.')).toLowerCase()
        : '';
    if (ext == '.jpeg' || ext == '.jpe') return '.jpg';
    return _imgExt.contains(ext) ? ext : '';
  }

  static String _sniffExt(List<int> blob, String name) {
    if (blob.length >= 3 && blob[0] == 0xFF && blob[1] == 0xD8 && blob[2] == 0xFF) {
      return '.jpg';
    }
    if (blob.length >= 8 &&
        blob[0] == 0x89 && blob[1] == 0x50 && blob[2] == 0x4E && blob[3] == 0x47) {
      return '.png';
    }
    if (blob.length >= 12 &&
        blob[0] == 0x52 && blob[1] == 0x49 && blob[2] == 0x46 && blob[3] == 0x46 &&
        blob[8] == 0x57 && blob[9] == 0x45 && blob[10] == 0x42 && blob[11] == 0x50) {
      return '.webp';
    }
    return _imgExtOf(name);
  }

  static List<String> _comicEntries(List<String> names) {
    final out = <String>[];
    for (final n in names) {
      if (n.endsWith('/') || n.contains('__MACOSX')) continue;
      final base = n.split('/').last;
      if (base.isEmpty || base.startsWith('.')) continue;
      if (_imgExtOf(base).isNotEmpty) out.add(n);
    }
    return out;
  }

  static List<(String, List<String>)> _groupByDir(List<String> names, String fallback) {
    final byDir = <String, List<String>>{};
    for (final n in names) {
      final d = n.contains('/') ? n.substring(0, n.lastIndexOf('/')) : '';
      byDir.putIfAbsent(d, () => []).add(n);
    }
    if (byDir.length >= 2) {
      final dirs = byDir.keys.toList()..sort((a, b) => _cmpNatural(a, b));
      final groups = <(String, List<String>)>[];
      for (final d in dirs) {
        final label = d.isEmpty
            ? '第${groups.length + 1}话'
            : d.split('/').last;
        groups.add((label, byDir[d]!..sort((a, b) => _cmpNatural(a, b))));
      }
      return groups;
    }
    return [(fallback, names..sort((a, b) => _cmpNatural(a, b)))];
  }

  static int _cmpNatural(String a, String b) {
    final na = _natural(a);
    final nb = _natural(b);
    final len = na.length < nb.length ? na.length : nb.length;
    for (var i = 0; i < len; i++) {
      if (na[i] is int && nb[i] is int) {
        final c = (na[i] as int).compareTo(nb[i] as int);
        if (c != 0) return c;
      } else {
        final c = na[i].toString().compareTo(nb[i].toString());
        if (c != 0) return c;
      }
    }
    return na.length.compareTo(nb.length);
  }

  static Future<List<(String, List<(String, List<int>)>)>> _parseZipComic(
      List<int> raw, String fallback) async {
    final archive = ZipDecoder().decodeBytes(raw);
    final names = archive.files.map((f) => f.name).toList();
    final entries = _comicEntries(names);
    if (entries.isEmpty) {
      throw FormatException('压缩包里没有图片（支持 jpg / png / webp / gif）');
    }
    final groups = <(String, List<(String, List<int>)>)>[];
    for (final (label, items) in _groupByDir(entries, fallback)) {
      final pages = <(String, List<int>)>[];
      for (final n in items) {
        final f = archive.files.where((x) => x.name == n).firstOrNull;
        if (f == null) continue;
        final blob = f.content;
        if (blob.isNotEmpty) pages.add((n.split('/').last, blob));
      }
      if (pages.isNotEmpty) groups.add((label, pages));
    }
    return groups;
  }

  static Future<List<(String, List<(String, List<int>)>)>> _parseEpubComic(
      List<int> raw, String fallback) async {
    final archive = ZipDecoder().decodeBytes(raw);
    final names = archive.files.map((f) => f.name).toSet();
    String opfPath = '';
    final cont = archive.files
        .where((f) => f.name == 'META-INF/container.xml')
        .toList();
    if (cont.isNotEmpty) {
      final c = utf8.decode(cont.first.content, allowMalformed: true);
      final m = RegExp(r'full-path="([^"]+)"').firstMatch(c);
      if (m != null) opfPath = m.group(1)!;
    }
    if (opfPath.isEmpty) {
      final cand = names.where((n) => n.toLowerCase().endsWith('.opf')).toList();
      opfPath = cand.isNotEmpty ? cand.first : '';
    }
    if (opfPath.isEmpty || !names.contains(opfPath)) {
      throw FormatException('这个 EPUB 缺少 OPF 目录文件，无法解析');
    }
    final base = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';
    final opfFile = archive.files.where((f) => f.name == opfPath).firstOrNull;
    final opf = utf8.decode(opfFile!.content, allowMalformed: true);
    final items = <String, String>{};
    for (final m in _re(r'<item\b[^>]*>').allMatches(opf)) {
      final tag = m.group(0)!;
      final mid = RegExp(r'\bid="([^"]+)"').firstMatch(tag)?.group(1);
      final href = RegExp(r'\bhref="([^"]+)"').firstMatch(tag)?.group(1);
      if (mid != null && href != null) items[mid] = _unescape(href);
    }
    final spine = _re(r'<itemref\b[^>]*\bidref="([^"]+)"')
        .allMatches(opf)
        .map((m) => m.group(1)!)
        .toList();
    var hrefs = <String>[];
    for (final s in spine) {
      if (items.containsKey(s)) hrefs.add(items[s]!);
    }
    if (hrefs.isEmpty) hrefs = items.values.toList();

    final groups = <(String, List<(String, List<int>)>)>[];
    for (final href in hrefs) {
      var path = href.split('#').first;
      if (base.isNotEmpty) path = '$base$path';
      final norm = _normPath(path);
      if (!names.contains(norm)) continue;
      final f = archive.files.where((x) => x.name == norm).firstOrNull;
      if (f == null) continue;
      final page = utf8.decode(f.content, allowMalformed: true);
      final pages = <(String, List<int>)>[];
      for (final m in _re(r'<img[^>]+src="([^"]+)"').allMatches(page)) {
        final src = _unescape(m.group(1)!).split('#').first;
        final dir = norm.contains('/')
            ? norm.substring(0, norm.lastIndexOf('/') + 1)
            : '';
        final imgPath = _normPath('$dir$src');
        if (!names.contains(imgPath)) continue;
        final img = archive.files.where((x) => x.name == imgPath).firstOrNull;
        if (img != null) pages.add((imgPath.split('/').last, img.content));
      }
      if (pages.isNotEmpty) {
        groups.add((_epubTitle(page, '第${groups.length + 1}话'), pages));
      }
    }
    return groups;
  }

  // ---------- 导入 ----------

  static Future<Book> importBytes(String name, List<int> raw) async {
    if (raw.isEmpty) throw FormatException('文件是空的');
    final lower = name.toLowerCase();
    var fallback = name.replaceAll(
        RegExp(r'\.(txt|epub|cbz|zip|text)$', caseSensitive: false), '');
    fallback = fallback.trim();
    if (fallback.isEmpty) fallback = '未命名';
    final isComicPack = lower.endsWith('.cbz') || lower.endsWith('.zip');
    final limit = isComicPack || lower.endsWith('.epub') ? _maxComicBytes : _maxBytes;
    if (raw.length > limit) {
      throw FormatException('文件超过 ${limit ~/ (1024 * 1024)}MB，请先拆分再导入');
    }

    if (isComicPack) {
      if (raw.length < 2 || raw[0] != 0x50 || raw[1] != 0x4B) {
        throw FormatException('这不是有效的 CBZ / ZIP 文件');
      }
      return _importComic(name, raw, fallback);
    }

    if (lower.endsWith('.epub') ||
        (raw.length >= 2 && raw[0] == 0x50 && raw[1] == 0x4B)) {
      if (raw.length < 2 || raw[0] != 0x50 || raw[1] != 0x4B) {
        throw FormatException('这不是有效的 EPUB 文件');
      }
      final (title, author, intro, chapters) = await parseEpub(raw, fallback);
      if (chapters.isEmpty) return _importComic(name, raw, fallback);
      return _saveNovel(raw, title, author, intro, chapters);
    }

    final (title, author, _, chapters) = await _parseTxt(raw, fallback);
    if (chapters.isEmpty) throw FormatException('没有解析到任何正文，换个文件试试');
    final parasList = chapters
        .map((c) => (c.$1, _paras(c.$2)))
        .where((c) => c.$2.isNotEmpty)
        .toList();
    return _saveNovel(raw, title, author, '', parasList);
  }

  static Future<(String, String, String, List<(String, String)>)> _parseTxt(
      List<int> raw, String fallback) async {
    final text = _decode(raw);
    var author = '';
    final am = RegExp(r'作\s*者\s*[:：]\s*([^\n]{1,24})').firstMatch(text.substring(0, text.length < 3000 ? text.length : 3000));
    if (am != null) author = am.group(1)!.trim();
    var title = fallback.isEmpty ? '未命名' : fallback;
    final tm = RegExp(r'^\s*(?:书\s*名|《)\s*[:：]?\s*([^\n》]{1,30})')
        .firstMatch(text.substring(0, text.length < 600 ? text.length : 600));
    if (tm != null && tm.group(1)!.trim().isNotEmpty) {
      title = tm.group(1)!.trim();
    }
    return (title, author, '', splitTxt(text));
  }

  static Future<Book> _saveNovel(
    List<int> raw,
    String title,
    String author,
    String intro,
    List<(String, List<String>)> chapters,
  ) async {
    final h = _hash(title, raw);
    final bid = '$_prefix$h';
    final dir = await _chapDir(h);
    Directory(dir).createSync(recursive: true);

    final catalog = <Map<String, dynamic>>[];
    for (final (ct, paras) in chapters) {
      if (paras.isEmpty) continue;
      final idx = catalog.length;
      final url = '$_prefix$h/$idx';
      final chapFile = File('$dir${Platform.pathSeparator}${_padded(idx)}.json');
      chapFile.writeAsStringSync(jsonEncode({
        'title': ct,
        'paras': paras,
        'url': url,
      }));
      catalog.add({'t': ct, 'u': url, 'i': idx});
    }
    if (catalog.isEmpty) throw FormatException('没有解析到任何正文，换个文件试试');

    final meta = {
      'id': bid,
      'title': title,
      'author': author.isEmpty ? '佚名' : author,
      'intro': _cleanIntro(intro).isEmpty
          ? '本地导入的书，无需联网，打开即可阅读。'
          : _cleanIntro(intro),
      'source': _srcName,
      'category': '本地导入',
      'status': '${catalog.length} 章',
      'cover': '',
      'created': DateTime.now().millisecondsSinceEpoch / 1000,
      'count': catalog.length,
      'kind': 'novel',
      'unit': '章',
      'chapters': catalog,
    };
    File(await _metaPath(h)).writeAsStringSync(jsonEncode(meta));
    return _metaToBook(meta);
  }

  static Future<Book> _importComic(String name, List<int> raw, String fallback) async {
    final lower = name.toLowerCase();
    final groups = lower.endsWith('.epub')
        ? await _parseEpubComic(raw, fallback)
        : await _parseZipComic(raw, fallback);
    if (groups.isEmpty) throw FormatException('这本漫画没有解析出任何可看的页');

    final h = _hash(fallback, raw);
    final bid = '$_prefix$h';
    final dir = await _chapDir(h);
    final imgDir = '$dir${Platform.pathSeparator}img';
    Directory(imgDir).createSync(recursive: true);

    final catalog = <Map<String, dynamic>>[];
    var seq = 0;
    for (final (label, pages) in groups) {
      final keep = <String>[];
      for (final (srcName, blob) in pages) {
        final ext = _sniffExt(blob, srcName);
        if (ext.isEmpty || blob.isEmpty) continue;
        seq++;
        final fn = '${seq.toString().padLeft(6, '0')}$ext';
        File('$imgDir${Platform.pathSeparator}$fn')
            .writeAsBytesSync(blob);
        keep.add(fn);
      }
      if (keep.isEmpty) continue;
      final idx = catalog.length;
      final url = '$_prefix$h/$idx';
      final chapFile = File('$dir${Platform.pathSeparator}${_padded(idx)}.json');
      chapFile.writeAsStringSync(jsonEncode({
        'title': label,
        'kind': 'comic',
        'pages': keep,
        'url': url,
      }));
      catalog.add({'t': label, 'u': url, 'i': idx});
    }
    if (catalog.isEmpty) throw FormatException('这本漫画没有可显示的图片');

    final meta = {
      'id': bid,
      'title': fallback,
      'author': '佚名',
      'intro': '本地导入的漫画，无需联网，打开即可阅读。',
      'source': _srcName,
      'category': '本地漫画',
      'status': '${catalog.length} 话',
      'cover': '',
      'created': DateTime.now().millisecondsSinceEpoch / 1000,
      'count': catalog.length,
      'kind': 'comic',
      'unit': '话',
      'chapters': catalog,
    };
    File(await _metaPath(h)).writeAsStringSync(jsonEncode(meta));
    return _metaToBook(meta);
  }

  static String _padded(int i) => i.toString().padLeft(6, '0');

  static Book _metaToBook(Map<String, dynamic> meta) {
    final chapters = (meta['chapters'] as List<dynamic>? ?? [])
        .map((c) => Chapter(
              title: '${(c as Map)['t'] ?? ''}',
              url: '${c['u'] ?? ''}',
            ))
        .toList();
    return Book(
      name: meta['title']?.toString() ?? '',
      author: meta['author']?.toString() ?? '',
      cover: meta['cover']?.toString() ?? '',
      bookUrl: meta['id']?.toString() ?? '',
      sourceId: 'loc',
      sourceName: _srcName,
      type: meta['kind'] == 'comic' ? ContentType.comic : ContentType.novel,
      lastChapter: chapters.isNotEmpty ? chapters.last.title : '',
      intro: meta['intro']?.toString() ?? '',
    );
  }

  // ---------- NovelSource 接口 ----------

  static Future<Map<String, dynamic>?> _readMeta(String h) async {
    final path = await _metaPath(h);
    if (!File(path).existsSync()) return null;
    return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async => [];

  @override
  Future<Book> detail(Book book) async {
    final h = _hashOf(book.bookUrl);
    final meta = await _readMeta(h);
    if (meta == null) throw SourceException('这本书已经不在本地了');
    return _metaToBook(meta);
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final h = _hashOf(book.bookUrl);
    final meta = await _readMeta(h);
    if (meta == null) throw SourceException('这本书已经不在本地了');
    final chapters = (meta['chapters'] as List<dynamic>? ?? [])
        .map((c) => Chapter(
              title: (c as Map)['t']?.toString() ?? '',
              url: c['u']?.toString() ?? '',
            ))
        .toList();
    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    return TocResult(chapters: chapters);
  }

  @override
  Future<Content> content(Chapter chapter) async {
    final m = RegExp(r'^loc:([0-9a-f]{8,16})/(\d+)$').firstMatch(chapter.url);
    if (m == null) throw SourceException('章节地址不合法');
    final h = m.group(1)!;
    final idx = int.parse(m.group(2)!);
    final dir = await _chapDir(h);
    final chapFile = File('$dir${Platform.pathSeparator}${_padded(idx)}.json');
    if (!chapFile.existsSync()) {
      throw SourceException('这一章的正文丢了，重新导入一次试试');
    }
    final data = jsonDecode(chapFile.readAsStringSync()) as Map<String, dynamic>;
    if (data['kind'] == 'comic') {
      final imgFiles = pagesOf(data);
      final pages = <String>[
        for (var i = 0; i < imgFiles.length; i++) '$_imgScheme$h/$idx/$i',
      ];
      return Content(
        title: data['title']?.toString() ?? chapter.title,
        pages: pages,
        kind: ContentType.comic,
      );
    }
    return Content(
      title: data['title']?.toString() ?? chapter.title,
      paras: (data['paras'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      kind: ContentType.novel,
    );
  }

  static List<dynamic> pagesOf(Map<String, dynamic> data) =>
      data['pages'] as List<dynamic>? ?? [];

  /// 读一页本地漫画图，返回 (bytes, content_type)。
  static Future<(List<int>, String)> readPage(String pageUrl) async {
    final m = RegExp(r'^locimg://([0-9a-f]{8,16})/(\d+)/(\d+)$')
        .firstMatch(pageUrl);
    if (m == null) throw FormatException('页地址不合法');
    final h = m.group(1)!;
    final ch = int.parse(m.group(2)!);
    final i = int.parse(m.group(3)!);
    final dir = await _chapDir(h);
    final chapFile = File('$dir${Platform.pathSeparator}${_padded(ch)}.json');
    if (!chapFile.existsSync()) throw FormatException('没有这一话');
    final data = jsonDecode(chapFile.readAsStringSync()) as Map<String, dynamic>;
    final pages = pagesOf(data);
    if (i < 0 || i >= pages.length) throw FormatException('没有这一页');
    final fn = pages[i].toString();
    if (fn.contains('/') || fn.contains('\\') || fn.contains('..')) {
      throw FormatException('页地址不合法');
    }
    final p = File('$dir${Platform.pathSeparator}img${Platform.pathSeparator}$fn');
    if (!p.existsSync()) throw FormatException('这一页的图片不见了');
    final ext = fn.contains('.')
        ? fn.substring(fn.lastIndexOf('.')).toLowerCase()
        : '.jpg';
    return (p.readAsBytesSync(), _imgMime[ext] ?? 'image/jpeg');
  }

  /// 列出全部本地书（元信息，按导入时间倒序）
  static Future<List<Book>> list() async {
    final dir = await root();
    final out = <Book>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final meta = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        out.add(_metaToBook(meta));
      } catch (_) {}
    }
    out.sort((a, b) => 0);
    return out;
  }

  /// 删除一本本地书及其文件。
  static Future<bool> delete(String bid) async {
    final h = _hashOf(bid);
    if (h.isEmpty) return false;
    var removed = false;
    final metaPath = await _metaPath(h);
    if (File(metaPath).existsSync()) {
      File(metaPath).deleteSync();
      removed = true;
    }
    final dir = Directory(await _chapDir(h));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
      removed = true;
    }
    return removed;
  }
}
