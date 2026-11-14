/// 发现（discover）接口的单元测试。
///
/// 不依赖网络：
/// 1. 不支持发现的书源（默认 [SourceBase]）返回空标签、discover 抛异常
/// 2. 书旗（shuqi）提供榜单+分类标签
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reading_app/sources/native/ali.dart';
import 'package:reading_app/sources/native/bc.dart';
import 'package:reading_app/sources/native/daren.dart';
import 'package:reading_app/sources/native/dq.dart';
import 'package:reading_app/sources/native/gsh.dart';
import 'package:reading_app/sources/native/kuaikan.dart';
import 'package:reading_app/sources/native/localbook.dart';
import 'package:reading_app/sources/native/mkz.dart';
import 'package:reading_app/sources/native/qm.dart';
import 'package:reading_app/sources/native/shuqi.dart';
import 'package:reading_app/sources/novel_source.dart';
import 'package:reading_app/sources/source.dart';
import 'package:reading_app/sources/source_registry.dart';

void main() {
  group('Discover 接口默认行为', () {
    test('不支持发现的书源：discoverTabs 为空', () {
      final local = LocalBookSource();
      expect(local.discoverTabs, isEmpty);
    });

    test('不支持发现的书源：discover 抛 SourceException', () async {
      final local = LocalBookSource();
      await expectLater(
        local.discover('x'),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('书旗 discover', () {
    test('提供榜单 + 分类标签（非空）', () {
      final sq = ShuqiSource();
      expect(sq.discoverTabs, isNotEmpty);
      expect(sq.discoverTabs.any((t) => t.isRank), isTrue);
      expect(sq.discoverTabs.any((t) => !t.isRank), isTrue);
    });
  });

  group('小说源 discover 标签（离线断言）', () {
    test('七猫/得奇/八叉/爱丽丝提供榜单', () {
      for (final s in <NovelSource>[QmSource(), DqSource(), BcSource(), AliSource()]) {
        expect(s.discoverTabs.any((t) => t.isRank), isTrue,
            reason: '${s.sourceName} 应有榜单');
      }
    });

    test('得奇/八叉提供分类标签', () {
      for (final s in <NovelSource>[DqSource(), BcSource()]) {
        expect(s.discoverTabs.any((t) => !t.isRank), isTrue,
            reason: '${s.sourceName} 应有分类');
      }
    });
  });

  group('规则源 discover 标签（离线断言）', () {
    test('速读谷/全本/八一 提供榜单与分类', () {
      const urls = [
        'https://www.sudugu.cc',
        'https://www.qbxs.net',
        'http://www.81shuku.info',
      ];
      for (final u in urls) {
        final s = SourceRegistry().byId(u);
        expect(s, isNotNull, reason: '$u 应已注册');
        expect(s!.discoverTabs.any((t) => t.isRank), isTrue,
            reason: '${s.sourceName} 应有榜单');
        expect(s.discoverTabs.any((t) => !t.isRank), isTrue,
            reason: '${s.sourceName} 应有分类');
      }
    });

    test('标签数量符合预期', () {
      NovelSource sd = SourceRegistry().byId('https://www.sudugu.cc')!;
      NovelSource qb = SourceRegistry().byId('https://www.qbxs.net')!;
      NovelSource bl = SourceRegistry().byId('http://www.81shuku.info')!;
      expect(sd.discoverTabs.length, 9); // 2 榜 + 7 类
      expect(qb.discoverTabs.length, 13); // 5 榜 + 8 类（含完结）
      expect(bl.discoverTabs.length, 10); // 3 榜 + 7 类
    });
  });

  group('漫画源 discover 标签（离线断言）', () {
    test('包子/漫客栈/大人提供榜单', () {
      for (final s in <NovelSource>[
        GshSource(),
        MkzSource(),
        DarenSource(),
      ]) {
        expect(s.discoverTabs.any((t) => t.isRank), isTrue,
            reason: '${s.sourceName} 应有榜单');
      }
    });

    test('快看提供分类（无榜单）', () {
      final kk = KuaikanSource();
      expect(kk.discoverTabs, isNotEmpty);
      expect(kk.discoverTabs.any((t) => !t.isRank), isTrue);
    });

    test('大人/包子 提供分类标签', () {
      for (final s in <NovelSource>[DarenSource(), GshSource()]) {
        expect(s.discoverTabs.any((t) => !t.isRank), isTrue,
            reason: '${s.sourceName} 应有分类');
      }
    });
  });
}
