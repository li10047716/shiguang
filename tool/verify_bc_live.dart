/// 八叉书库真实链路验证。
/// 用法：dart run tool/verify_bc_live.dart
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:reading_app/sources/source_registry.dart';

void main() async {
  final reg = SourceRegistry();
  final src = reg.all.where((s) => s.sourceName == '八叉书库').firstOrNull;
  if (src == null) {
    stderr.writeln('✗ 八叉书库书源未加载');
    exit(1);
  }
  stdout.writeln('书源: ${src.sourceName}');

  var failed = 0;
  void check(String label, bool ok, String detailText) {
    stdout.writeln('${ok ? "✓" : "✗"} $label: $detailText');
    if (!ok) failed++;
  }

  try {
    final books = await src.search('凡人修仙');
    check('搜索返回书籍', books.isNotEmpty, '${books.length} 本');
    if (books.isEmpty) exit(1);
    final b = books.first;
    check('书名', b.name.isNotEmpty, b.name);
    // 搜索卡片作者是尽力而为（部分书卡片无作者字段）；详情作者才是权威
    stdout.writeln('${b.author.isNotEmpty ? "✓" : "·"} 搜索作者(尽力): ${b.author.isEmpty ? "(空)" : b.author}');
    check('书Url(含bc id)', b.bookUrl.startsWith('bc:'), b.bookUrl);
    stdout.writeln('首本: ${b.name} / ${b.author} / ${b.bookUrl}');

    final detail = await src.detail(b);
    check('详情书名', detail.name.isNotEmpty, detail.name);
    check('详情作者', detail.author.isNotEmpty, detail.author);
    check('详情简介', (detail.intro ?? '').isNotEmpty, '${(detail.intro ?? '').length} 字');

    final toc = await src.loadToc(detail);
    check('目录章节', toc.chapters.isNotEmpty, '${toc.chapters.length} 章');
    if (toc.chapters.isNotEmpty) {
      final first = toc.chapters.first;
      stdout.writeln('首章: ${first.title} / ${first.url}');
      final content = await src.content(first);
      final text = content.paras.join('\n');
      check('正文非空', text.length > 100, '${text.length} 字');
      if (text.isNotEmpty) {
        final firstLine = text.split('\n').first;
        stdout.writeln('正文首段: ${firstLine.substring(0, firstLine.length.clamp(0, 60))}');
      }
    }
  } catch (e) {
    check('请求不抛异常', false, '$e');
  }

  stdout.writeln(failed == 0 ? '\n全部通过' : '\n$failed 项失败');
  exit(failed == 0 ? 0 : 1);
}
