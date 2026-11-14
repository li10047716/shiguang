/// 规则源发现页真实抓取测试（需 --run-skipped）。
///
/// 验证速读谷 / 全本 / 八一 三个规则源的 discover 标签与抓取。
library;

// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';

import 'package:reading_app/sources/source_registry.dart';

void main() {
  test('速读谷 discover 首榜/首分类真实抓取', () async {
    final src = SourceRegistry().byId('https://www.sudugu.cc')!;
    final tabs = src.discoverTabs;
    // 速读谷站点较慢，放宽超时
    expect(tabs, isNotEmpty, reason: '速读谷应有 discover 标签');
    final rank = tabs.firstWhere((t) => t.isRank);
    final r = await src.discover(rank.key, isRank: true);
    expect(r.books, isNotEmpty, reason: '速读谷榜单应抓取到书');
    print('速读谷[${rank.name}] 第1页 ${r.books.length} 本 / ${r.pages} 页');
    for (final b in r.books.take(3)) {
      print('  - ${b.name} / ${b.author} / ${b.bookUrl}');
    }
    final cat = tabs.firstWhere((t) => !t.isRank);
    final c = await src.discover(cat.key, isRank: false);
    expect(c.books, isNotEmpty, reason: '速读谷分类应抓取到书');
    print('速读谷[${cat.name}] 第1页 ${c.books.length} 本 / ${c.pages} 页');
  }, timeout: const Timeout(Duration(minutes: 4)),
      skip: '网络测试，需 --run-skipped 运行');

  test('全本 discover 首榜/首分类真实抓取', () async {
    final src = SourceRegistry().byId('https://www.qbxs.net')!;
    final tabs = src.discoverTabs;
    expect(tabs, isNotEmpty, reason: '全本应有 discover 标签');
    final rank = tabs.firstWhere((t) => t.isRank);
    final r = await src.discover(rank.key, isRank: true);
    expect(r.books, isNotEmpty, reason: '全本榜单应抓取到书');
    print('全本[${rank.name}] 第1页 ${r.books.length} 本 / ${r.pages} 页');
    for (final b in r.books.take(3)) {
      print('  - ${b.name} / ${b.author} / ${b.bookUrl} / 封面:${b.cover}');
    }
    final cat = tabs.firstWhere((t) => !t.isRank);
    final c = await src.discover(cat.key, isRank: false);
    expect(c.books, isNotEmpty, reason: '全本分类应抓取到书');
    print('全本[${cat.name}] 第1页 ${c.books.length} 本 / ${c.pages} 页');
    for (final b in c.books.take(3)) {
      print('  - ${b.name} / 封面:${b.cover}');
    }
  }, skip: '网络测试，需 --run-skipped 运行');

  test('八一 discover 首榜/首分类真实抓取', () async {
    final src = SourceRegistry().byId('http://www.81shuku.info')!;
    final tabs = src.discoverTabs;
    expect(tabs, isNotEmpty, reason: '八一应有 discover 标签');
    final rank = tabs.firstWhere((t) => t.isRank);
    final r = await src.discover(rank.key, isRank: true);
    expect(r.books, isNotEmpty, reason: '八一拳单应抓取到书');
    print('八一[${rank.name}] 第1页 ${r.books.length} 本 / ${r.pages} 页');
    for (final b in r.books.take(3)) {
      print('  - ${b.name} / ${b.author} / ${b.bookUrl} / 封面:${b.cover}');
    }
    final cat = tabs.firstWhere((t) => !t.isRank);
    final c = await src.discover(cat.key, isRank: false);
    expect(c.books, isNotEmpty, reason: '八一分类应抓取到书');
    print('八一[${cat.name}] 第1页 ${c.books.length} 本 / ${c.pages} 页');
    for (final b in c.books.take(3)) {
      print('  - ${b.name} / 封面:${b.cover}');
    }
  }, skip: '网络测试，需 --run-skipped 运行');
}
