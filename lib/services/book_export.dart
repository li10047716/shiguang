/// 书籍导出：先下载全书正文到缓存，再按目录顺序合成 TXT 保存到本地。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/book.dart';
import '../sources/source_registry.dart';
import 'chapter_cache.dart';

class BookExport {
  BookExport._();

  /// 导出进度回调：[done]/[total] 为下载章节数，[phase] 为阶段说明。
  static Future<bool> exportToTxt(
    Book book, {
    required void Function(int done, int total, String phase)? onProgress,
  }) async {
    final source = SourceRegistry().byId(book.sourceId);
    if (source == null) {
      onProgress?.call(0, 0, '书源不可用');
      return false;
    }

    // 1. 拉目录
    onProgress?.call(0, 0, '正在获取目录…');
    final toc = await source.loadToc(book).timeout(const Duration(seconds: 30));
    final chapters = toc.chapters;
    if (chapters.isEmpty) {
      onProgress?.call(0, 0, '目录为空');
      return false;
    }

    // 2. 逐章下载正文（复用缓存，已有缓存则跳过网络但内容一致）。
    await ChapterCache.saveBookMeta(book, chapters.length);
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final cached = await ChapterCache.read(book.bookUrl, ch.url);
      if (cached == null) {
        try {
          final c = await source.content(ch).timeout(const Duration(seconds: 20));
          await ChapterCache.write(
            book.bookUrl,
            ch.url,
            c,
            title: ch.title,
            order: i,
          );
        } catch (_) {
          // 单章失败继续，导出时该章会标记为空
        }
      }
      onProgress?.call(i + 1, chapters.length, '正在下载正文…');
    }

    // 3. 合成 TXT
    onProgress?.call(chapters.length, chapters.length, '正在生成文件…');
    final buf = StringBuffer()
      ..writeln(book.name)
      ..writeln('作者：${book.author.isEmpty ? '未知' : book.author}')
      ..writeln('来源：${book.sourceName}')
      ..writeln();
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final c = await ChapterCache.read(book.bookUrl, ch.url);
      buf
        ..writeln(ch.title)
        ..writeln();
      if (c == null || c.paras.isEmpty) {
        buf..writeln('（本章未能获取正文）')..writeln();
        continue;
      }
      for (final p in c.paras) {
        buf..writeln(p)..writeln();
      }
    }

    // 4. 选择保存位置并写入
    final safeName = book.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出 TXT',
      fileName: '$safeName.txt',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (path == null) return false;
    await File(path).writeAsString(buf.toString(), encoding: utf8);
    return true;
  }
}
