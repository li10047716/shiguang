/// 书源注册表与统一接口的单元测试。
///
/// 验证混合架构的基础：
/// 1. SourceRegistry 能加载规则引擎书源（速读谷）
/// 2. 书源实现统一 NovelSource 接口
/// 3. 类型过滤正确
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reading_app/models/book_source.dart';
import 'package:reading_app/sources/rule_source.dart';
import 'package:reading_app/sources/source.dart';
import 'package:reading_app/sources/source_registry.dart';

void main() {
  group('SourceRegistry', () {
    test('加载内置规则书源（至少速读谷）', () {
      final reg = SourceRegistry();
      expect(reg.all, isNotEmpty);
      expect(reg.all.length, greaterThanOrEqualTo(1));

      // 速读谷应在列表中
      final hasSudugu = reg.all.any((s) => s.sourceName == '速读谷');
      expect(hasSudugu, isTrue);
    });

    test('书源实现统一 NovelSource 接口', () {
      final reg = SourceRegistry();
      for (final s in reg.all) {
        expect(s, isA<NovelSource>());
        expect(s.sourceId, isNotEmpty);
        expect(s.sourceName, isNotEmpty);
      }
    });

    test('速读谷是 RuleSource（规则引擎源）', () {
      final reg = SourceRegistry();
      final sudugu =
          reg.all.where((s) => s.sourceName == '速读谷').firstOrNull;
      expect(sudugu, isNotNull);
      expect(sudugu, isA<RuleSource>());
    });

    test('类型过滤：速读谷为 novel', () {
      final reg = SourceRegistry();
      final novels = reg.enabledOfType(ContentType.novel);
      expect(novels, isNotEmpty);
      expect(novels.any((s) => s.sourceName == '速读谷'), isTrue);
    });

    test('byId 查找', () {
      final reg = SourceRegistry();
      final s = reg.all.first;
      expect(reg.byId(s.sourceId), isNotNull);
    });
  });
}
