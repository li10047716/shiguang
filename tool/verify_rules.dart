/// 书源规则离线验证脚本
/// 用法：dart run tool/verify_rules.dart
/// 用 test/fixtures 下的真实页面检查内置书源规则提取结果
library;

import 'dart:io';

import 'package:html/parser.dart' as parser;
import 'package:reading_app/sources/builtin/builtin_sources.dart';
import 'package:reading_app/sources/rule_engine.dart';
import 'package:reading_app/utils/text_repair.dart';

void main() {
  final detail = File('test/fixtures/detail.html').readAsStringSync();
  final chapter = File('test/fixtures/chapter.html').readAsStringSync();

  final repo = SourceRepository();
  final src = repo.byId('https://www.sudugu.cc');
  if (src == null) {
    stderr.writeln('✗ 内置书源未加载');
    exit(1);
  }

  var failed = 0;
  void check(String label, bool ok, String detailText) {
    stdout.writeln('${ok ? "✓" : "✗"} $label: $detailText');
    if (!ok) failed++;
  }

  check('书源加载', src.enabled, '${src.name} / ${src.type.name} / enabled=${src.enabled}');

  // 详情页字段
  final name = RuleEngine.extract(detail, src.detail.name);
  final author = RuleEngine.extract(detail, src.detail.author);
  final cover = RuleEngine.extract(detail, src.detail.cover);
  final intro = RuleEngine.extract(detail, src.detail.intro);
  check('书名', name == '斗破苍穹', name);
  check('作者', author == '天蚕土豆', author);
  check('封面', cover.contains('1933s.jpg'), cover);
  check('简介', intro.contains('斗气'), _cut(intro, 60));

  // 搜索列表规则（在详情页结构上验证 h1 回退分支）
  final items = RuleEngine.elements(parser.parse(detail), src.search.bookList);
  check('搜索列表项', items.isNotEmpty, '${items.length} 项');
  if (items.isNotEmpty) {
    final el = items.first;
    final n = RuleEngine.extractFromElement(el, src.search.name);
    final u = RuleEngine.extractFromElement(el, src.search.bookUrl);
    final a = RuleEngine.extractFromElement(el, src.search.author);
    check('列表书名(回退分支)', n == '斗破苍穹', n);
    check('列表链接去锚点', u.isNotEmpty && !u.contains('#'), u);
    check('列表作者', a == '天蚕土豆', a);
  }

  // 目录
  final chapters = RuleEngine.elements(parser.parse(detail), src.toc!.chapterList);
  check('目录章节数', chapters.length >= 1000, '${chapters.length} 章');
  if (chapters.isNotEmpty) {
    final t = RuleEngine.extractFromElement(chapters.first, src.toc!.chapterName);
    final h = RuleEngine.extractFromElement(chapters.first, src.toc!.chapterUrl);
    check('首章标题', t.contains('第1章'), t);
    check('首章链接', h.contains('/1933/'), h);
  }
  final nextToc = RuleEngine.extract(detail, src.toc!.nextTocUrl!);
  check('目录下一页', nextToc.contains('/1933/2'), nextToc);

  // 正文
  final text = RuleEngine.extract(chapter, src.content!.content);
  check('正文长度', text.length > 200, '${text.length} 字');
  check('保留换行', text.contains('\n'), '${text.split('\n').length} 行');
  final nextPage = RuleEngine.extract(chapter, src.content!.nextContentUrl!);
  check('正文下一页', nextPage.contains('_2.html'), nextPage);

  final moji = TextRepair.looksMojibake(text);
  stdout.writeln('· 乱码检测: ${moji ? "命中（该环境抓到的是混淆文本）" : "正常"}');
  if (moji) {
    final fixed = TextRepair.repair(text);
    stdout.writeln('· 修复后首段: ${_cut(fixed.split("\n").first, 60)}');
  } else {
    stdout.writeln('· 正文首段: ${_cut(text.split("\n").first, 60)}');
  }

  stdout.writeln(failed == 0 ? '\n全部通过' : '\n$failed 项失败');
  exit(failed == 0 ? 0 : 1);
}

String _cut(String s, int n) => s.length > n ? '${s.substring(0, n)}…' : s;
