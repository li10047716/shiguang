/// 书旗 discover 真实链路验证（手动：flutter test --run-skipped）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reading_app/sources/native/shuqi.dart';

void main() {
  test('书旗榜单真实抓取', () async {
    final sq = ShuqiSource();
    final r = await sq.discover('boyClick', isRank: true, page: 1);
    expect(r.books, isNotEmpty);
    // ignore: avoid_print
    print('榜单「${r.title}」第${r.page}/${r.pages}页，${r.books.length}本');
    for (final b in r.books.take(3)) {
      // ignore: avoid_print
      print('  ${b.name} · ${b.author} · ${b.bookUrl}');
    }
  }, skip: '网络测试，需 --run-skipped 运行');

  test('书旗书库真实抓取', () async {
    final sq = ShuqiSource();
    final r = await sq.discover('7', isRank: false, page: 1);
    expect(r.books, isNotEmpty);
    // ignore: avoid_print
    print('书库「${r.title}」第${r.page}/${r.pages}页，${r.books.length}本');
  }, skip: '网络测试，需 --run-skipped 运行');
}
