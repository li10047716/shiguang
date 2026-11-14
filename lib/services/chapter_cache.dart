/// 章节内容本地缓存（离线缓存）。
///
/// 按「书 URL + 章 URL」哈希成文件名存 JSON 到应用文档目录，
/// 阅读器取正文时优先读盘（离线可读），下载全书后无需网络。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/content.dart';

class ChapterCache {
  ChapterCache._();

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}chapter_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

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

  static Future<void> write(String bookUrl, String chUrl, Content c) async {
    try {
      final d = await _dir();
      final f = File('${d.path}${Platform.pathSeparator}${_name(bookUrl, chUrl)}');
      await f.writeAsString(jsonEncode(c.toJson()), encoding: utf8);
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

  /// 清除某本书的缓存，返回删除数量
  static Future<int> clearBook(String bookUrl) async {
    var n = 0;
    try {
      final d = await _dir();
      final prefix = '${_h(bookUrl)}_';
      await for (final e in d.list()) {
        if (e is File && e.uri.pathSegments.last.startsWith(prefix)) {
          await e.delete();
          n++;
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
