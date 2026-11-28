import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:reading_app/models/book_source.dart';
import 'package:reading_app/sources/legado_rule_resolver.dart';
import 'package:reading_app/sources/rule_engine.dart';
import 'package:reading_app/sources/source_import.dart';

void main() {
  test('yckceo 真实书源按类型与实现方式导入', () {
    const expected = {
      '8055.json': ('novel', 'jsRule'),
      '8099.json': ('video', 'jsRule'),
      '8127.json': ('novel', 'jsRule'),
      '8142.json': ('novel', 'jsRule'),
      '8146.json': ('novel', 'jsRule'),
      '8166.json': ('comic', 'jsRule'),
      '8170.json': ('novel', 'jsRule'),
    };
    final dir = Directory('test/fixtures/yck');
    for (final entry in expected.entries) {
      final file = File('${dir.path}/${entry.key}');
      final imported = SourceImportAdapter.parse(file.readAsStringSync()).single;
      expect(
        imported.reason,
        isNull,
        reason: '${entry.key}: ${imported.reason}',
      );
      expect(imported.json!['sourceType'], entry.value.$1, reason: entry.key);
      expect(
        imported.json!['implementation'],
        entry.value.$2,
        reason: entry.key,
      );
      final source = BookSource.fromJson(imported.json!);
      expect(source.search.bookList.isNotEmpty, isTrue, reason: entry.key);
    }
  });

  test('8170 分类与榜单发现规则完整导入', () {
    final imported = SourceImportAdapter.parse(
      File('test/fixtures/yck/8170.json').readAsStringSync(),
    ).single;
    expect(imported.reason, isNull);
    final source = BookSource.fromJson(imported.json!);
    expect(source.discover.length, 19);
    final categories = source.discover.where((t) => !t.isRank).toList();
    final ranks = source.discover.where((t) => t.isRank).toList();
    expect(categories.length, 9);
    expect(ranks.length, 10);
    expect(categories.first.name, '玄幻奇幻');
    expect(
      categories.first.url,
      'http://www.xkushu.org/zwwsort1/0/{{page}}.htm',
    );
    expect(ranks.first.name, '总阅读榜');
    expect(
      ranks.first.url,
      'http://www.xkushu.org/zwwtopallvisit/0/{{page}}.htm',
    );
    expect(
      source.discover.first.cardBookUrl,
      r'td:nth-child(1) a@href##/35zwhtml/(\d+)/(\d+)/##/zwwinfo/$1/$2.htm##',
    );
    expect(
      source.discover.first.cardCover,
      'td:nth-child(1) a@href@js:xkCover(result)',
    );
    expect(imported.warnings.join('\n'), contains('已导入 19 个发现页标签'));
  });

  test('规则引擎支持 8170 的 :has() 卡片选择器', () {
    final doc = html_parser.parse('''
      <table class="grid">
        <tr><td class="odd"><a href="/1">书一</a></td><td>作者</td></tr>
        <tr><td>无链接</td><td>占位</td></tr>
        <tr><td class="odd"><a href="/2">书二</a></td><td>作者</td></tr>
      </table>
    ''');
    final items = RuleEngine.elements(doc, 'table.grid tr:has(td.odd a)');
    expect(items.length, 2);
    expect(
      items.map((e) => RuleEngine.extractFromElement(e, 'td:nth-child(1) a@text')).toList(),
      ['书一', '书二'],
    );
  });

  test('非 HTTP 书源 URL 用内部 ID，动态 header 被忽略并提示', () {
    final file = File('test/fixtures/yck/8146.json');
    final imported = SourceImportAdapter.parse(file.readAsStringSync()).single;
    expect(imported.reason, isNull);
    expect(imported.json!['sourceUrl'], startsWith('legado://'));
    expect(imported.warnings.join('\n'), contains('动态脚本'));
  });

  test('复合规则解析器支持 JSONPath、正则替换、备选与列表', () async {
    const source = BookSource(
      id: 'test://resolver',
      name: 'test',
      baseUrl: 'https://example.test',
      type: ContentType.novel,
      implementation: SourceImplementation.extendedRule,
      search: SearchRule(
        urlTemplate: '',
        bookList: r'$.list[*]',
        name: r'$.name',
        author: '',
        cover: '',
        bookUrl: '',
      ),
      detail: DetailRule(),
    );
    final resolver = LegadoRuleResolver(source);
    final raw = jsonEncode({
      'data': {'title': '测试标题 ', 'id': 7},
      'list': [
        {'name': '第一本'},
        {'name': '第二本'},
      ],
    });
    expect(await resolver.text(raw, r'$.data.title##\s+$##'), '测试标题');
    expect(await resolver.text(raw, r'$.data.id'), '7');
    expect(await resolver.text(raw, r'{{$.data.title}}'), '测试标题');
    final list = await resolver.list(raw, r'$.list[*]');
    expect(list.length, 2);
    expect(await resolver.text(list.first, r'$.name'), '第一本');
    expect(await resolver.text(list.last, r'$.name'), '第二本');
    expect(await resolver.text(list.first, 'name'), '第一本');
  });
}
