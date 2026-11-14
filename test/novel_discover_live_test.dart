/// 小说书源 discover 真实链路验证（手动：flutter test --run-skipped）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reading_app/sources/native/ali.dart';
import 'package:reading_app/sources/native/bc.dart';
import 'package:reading_app/sources/native/dq.dart';
import 'package:reading_app/sources/native/qm.dart';

void main() {
  final cases = <(String, Object)>[
    ('七猫', QmSource()),
    ('得奇', DqSource()),
    ('八叉', BcSource()),
    ('爱丽丝', AliSource()),
  ];

  for (final (name, src) in cases) {
    test('$name discover 首榜真实抓取', () async {
      final s = src as dynamic;
      final r = await s.discover(
        s.discoverTabs.first.key,
        isRank: s.discoverTabs.first.isRank,
        page: 1,
      );
      expect(r.books, isNotEmpty);
      // ignore: avoid_print
      print('$name「${r.title}」第${r.page}/${r.pages}页，${r.books.length}本');
      final b = r.books.first;
      // ignore: avoid_print
      print('  首本：${b.name} · ${b.author} · ${b.bookUrl}');
    }, skip: '网络测试，需 --run-skipped 运行', timeout: Timeout(Duration(seconds: 90)));
  }
}
