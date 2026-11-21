/// 章节内容本地缓存（离线缓存）。
///
/// 按「书 URL + 章 URL」哈希成文件名存 JSON 到应用文档目录，
/// 阅读器取正文时优先读盘（离线可读），下载全书后无需网络。
///
/// 另有一份 `_meta.json` 记录每本书的元信息（书名/来源/目录总章数），
/// 供全局缓存管理页展示——缓存文件名是哈希，无法反推书名。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/content.dart';

/// 已缓存章节的摘要（供管理界面列出/勾选清理）
class CachedChapter {
  final String url;
  final String title;
  final String fileName;
  final int bytes;
  final int order;

  const CachedChapter({
    required this.url,
    required this.title,
    required this.fileName,
    required this.bytes,
    required this.order,
  });
}

/// 一本书的缓存统计
class CachedBook {
  final String bookUrl;
  final Book? book; // 有元信息时非空（旧缓存可能为空）
  final int cached; // 已缓存章节数
  final int total; // 目录总章数（0 = 未知）
  final int bytes; // 占用字节
  final int updatedAt; // 最后缓存时间（毫秒）

  const CachedBook({
    required this.bookUrl,
    required this.book,
    required this.cached,
    required this.total,
    required this.bytes,
    required this.updatedAt,
  });

  String get name => book?.name ?? '未识别书籍';
  String get sourceName => book?.sourceName ?? '';
}

class ChapterCache {
  ChapterCache._();

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}chapter_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<File> _metaFile() async =>
      File('${(await _dir()).path}${Platform.pathSeparator}_meta.json');

  /// FNV-1a 稳定哈希（跨版本一致）
  static String _h(String s) {
    var hash = 0x811c9dc5;
    for (final c in utf8.encode(s)) {
      hash ^= c;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  static String _name(String bookUrl, String chUrl) =>
      '${_h(bookUrl)}_${_h(chUrl)}.json';

  /// 写章节正文；[title]/[order] 会在文件内记录，供管理页列出章节。
  static Future<void> write(
    String bookUrl,
    String chUrl,
    Content c, {
    String? title,
    int order = -1,
  }) async {
    try {
      final d = await _dir();
      final f = File('${d.path}${Platform.pathSeparator}${_name(bookUrl, chUrl)}');
      final json = <String, dynamic>{
        ...c.toJson(),
        '_url': chUrl,
        '_title': title ?? '',
        '_order': order,
      };
      await f.writeAsString(jsonEncode(json), encoding: utf8);
    } catch (_) {
      // 缓存失败不影响阅读
    }
  }

  static Future<Content?> read(String bookUrl, String chUrl) async {
    try {
      final d = await _dir();
      final f = File('${d.path}${Platform.pathSeparator}${_name(bookUrl, chUrl)}');
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return Content.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ---------- 元信息 ----------

  static Future<Map<String, dynamic>> _readMeta() async {
    try {
      final f = await _metaFile();
      if (!await f.exists()) return <String, dynamic>{};
      final m = jsonDecode(await f.readAsString());
      return m is Map<String, dynamic> ? m : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _writeMeta(Map<String, dynamic> meta) async {
    try {
      final f = await _metaFile();
      await f.writeAsString(jsonEncode(meta), encoding: utf8);
    } catch (_) {}
  }

  /// 下载开始时保存/更新书的元信息（书名、来源、目录总章数）
  static Future<void> saveBookMeta(Book book, int total) async {
    final meta = await _readMeta();
    meta[book.bookUrl] = <String, dynamic>{
      'book': book.toJson(),
      'total': total,
      'updated': DateTime.now().millisecondsSinceEpoch,
    };
    await _writeMeta(meta);
  }

  static Future<void> touchMeta(String bookUrl) async {
    final meta = await _readMeta();
    final entry = meta[bookUrl];
    if (entry is Map<String, dynamic>) {
      entry['updated'] = DateTime.now().millisecondsSinceEpoch;
      await _writeMeta(meta);
    }
  }

  // ---------- 统计 / 列出 ----------

  /// 全部已缓存书籍的统计（按缓存数降序）
  static Future<List<CachedBook>> allBooks() async {
    final d = await _dir();
    final meta = await _readMeta();
    final hexToUrl = <String, String>{};
    final acc = <String, _Acc>{};

    meta.forEach((url, value) {
      hexToUrl[_h(url)] = url;
      Book? book;
      var total = 0;
      var updated = 0;
      if (value is Map<String, dynamic>) {
        total = value['total'] is int ? value['total'] : 0;
        updated = value['updated'] is int ? value['updated'] : 0;
        final b = value['book'];
        if (b is Map<String, dynamic>) {
          try {
            book = Book.fromJson(b);
          } catch (_) {}
        }
      }
      acc[url] = _Acc(book: book, total: total, updated: updated);
    });

    await for (final e in d.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name == '_meta.json' || !name.endsWith('.json')) continue;
      final idx = name.indexOf('_');
      if (idx <= 0) continue;
      final url = hexToUrl[name.substring(0, idx)] ?? name.substring(0, idx);
      final a = acc.putIfAbsent(url, () => _Acc());
      a.cached++;
      try {
        a.bytes += await e.length();
      } catch (_) {}
    }

    final list = acc.entries
        .map((e) => CachedBook(
              bookUrl: e.key,
              book: e.value.book,
              cached: e.value.cached,
              total: e.value.total,
              bytes: e.value.bytes,
              updatedAt: e.value.updated,
            ))
        .toList();
    list.sort((a, b) => b.cached.compareTo(a.cached));
    return list;
  }

  /// 某本书已缓存的章节列表（按目录顺序）
  ///
  /// 兼容旧缓存：bookUrl 可能实为哈希前缀，两种前缀都匹配。
  static Future<List<CachedChapter>> listChapters(String bookUrl) async {
    final d = await _dir();
    final prefixes = <String>{'${_h(bookUrl)}_'};
    if (_isHashPrefix(bookUrl)) prefixes.add('${bookUrl}_');
    final list = <CachedChapter>[];
    await for (final e in d.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      var matched = false;
      for (final p in prefixes) {
        if (name.startsWith(p)) {
          matched = true;
          break;
        }
      }
      if (!matched) continue;
      var url = '';
      var title = '';
      var order = -1;
      try {
        final j = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
        url = j['_url']?.toString() ?? '';
        title = j['_title']?.toString() ?? '';
        order = j['_order'] is int ? j['_order'] : -1;
      } catch (_) {}
      var bytes = 0;
      try {
        bytes = await e.length();
      } catch (_) {}
      list.add(CachedChapter(
        url: url,
        title: title,
        fileName: name,
        bytes: bytes,
        order: order,
      ));
    }
    list.sort((a, b) {
      if (a.order >= 0 && b.order >= 0) return a.order.compareTo(b.order);
      if (a.order >= 0) return -1;
      if (b.order >= 0) return 1;
      return a.title.compareTo(b.title);
    });
    return list;
  }

  /// 全部缓存占用字节
  static Future<int> totalBytes() async {
    var total = 0;
    for (final b in await allBooks()) {
      total += b.bytes;
    }
    return total;
  }

  // ---------- 清理 ----------

  /// 清除某本书的缓存，返回删除数量。
  ///
  /// 兼容旧缓存：旧缓存没有 _meta.json 记录时，管理页拿到的 bookUrl
  /// 实为文件名中的哈希前缀，此时直接用该前缀匹配文件名。
  static Future<int> clearBook(String bookUrl) async {
    var n = 0;
    try {
      final d = await _dir();
      final prefixes = <String>{_h(bookUrl)};
      if (_isHashPrefix(bookUrl)) prefixes.add(bookUrl);
      await for (final e in d.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.endsWith('.json')) continue;
        for (final p in prefixes) {
          if (name.startsWith('${p}_')) {
            await e.delete();
            n++;
            break;
          }
        }
      }
      final meta = await _readMeta();
      if (meta.remove(bookUrl) != null) await _writeMeta(meta);
    } catch (_) {}
    return n;
  }

  /// bookUrl 是否实为文件名中的十六进制哈希前缀（旧缓存无元信息时）
  static bool _isHashPrefix(String s) =>
      RegExp(r'^[0-9a-fA-F]{1,16}$').hasMatch(s);

  /// 按文件名清除选中的章节，返回删除数量
  static Future<int> clearChapters(List<CachedChapter> chapters) async {
    var n = 0;
    try {
      final d = await _dir();
      for (final c in chapters) {
        final f = File('${d.path}${Platform.pathSeparator}${c.fileName}');
        if (await f.exists()) {
          await f.delete();
          n++;
        }
      }
    } catch (_) {}
    return n;
  }

  /// 清空全部缓存，返回删除的章节数
  static Future<int> clearAll() async {
    var n = 0;
    try {
      final d = await _dir();
      await for (final e in d.list()) {
        if (e is File) {
          await e.delete();
          if (e.uri.pathSegments.last != '_meta.json') n++;
        }
      }
    } catch (_) {}
    return n;
  }

  /// 某本书已缓存章节数
  static Future<int> bookCount(String bookUrl) async {
    var n = 0;
    try {
      final d = await _dir();
      final prefix = '${_h(bookUrl)}_';
      await for (final e in d.list()) {
        if (e is File && e.uri.pathSegments.last.startsWith(prefix)) n++;
      }
    } catch (_) {}
    return n;
  }
}

class _Acc {
  Book? book;
  int cached = 0;
  int total;
  int bytes = 0;
  int updated;
  _Acc({this.book, this.total = 0, this.updated = 0});
}
