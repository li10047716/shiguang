import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:reading_app/models/book_source.dart';
import 'package:reading_app/sources/builtin/builtin_sources.dart';
import 'package:reading_app/sources/rule_engine.dart';
import 'package:reading_app/sources/rule_source.dart';
import 'package:reading_app/sources/source_import.dart';
import 'package:reading_app/sources/source_import_input.dart';
import 'package:reading_app/sources/source_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> legado({
  String url = 'https://example.test',
  int type = 0,
}) => {
  'bookSourceName': '测试书源',
  'bookSourceUrl': url,
  'bookSourceType': type,
  'searchUrl': '/search?key={{key}}&page={{page}}',
  'header':
      '{"User-Agent":"ReadingApp-Test","Referer":"https://example.test/"}',
  'ruleSearch': {
    'bookList': 'class.book',
    'name': 'tag.a@text',
    'bookUrl': 'tag.a@href',
    'coverUrl': 'tag.img@src',
  },
  'ruleBookInfo': {'intro': 'id.intro@text', 'tocUrl': 'a.toc@href'},
  'ruleToc': {
    'chapterList': '#toc a',
    'chapterName': 'text',
    'chapterUrl': 'href',
  },
  'ruleContent': {'content': type == 2 ? '.pages img@src' : '#content@html'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('转换单源、GET 模板和静态请求头，简写可在真实 HTML 上执行', () {
    final entry = SourceImportAdapter.parse('\uFEFF${jsonEncode(legado())}')
        .single;
    expect(entry.reason, isNull);
    final source = BookSource.fromJson(entry.json!);
    expect(
      source.search.urlTemplate,
      'https://example.test/search?key={{key}}&page={{page}}',
    );
    expect(source.headers['User-Agent'], 'ReadingApp-Test');
    final doc = html.parse(
      '<div class="book"><a href="/book/1">书名</a><img src="/cover.jpg"></div>',
    );
    final card = RuleEngine.elements(doc, source.search.bookList).single;
    expect(RuleEngine.extractFromElement(card, source.search.name), '书名');
    expect(
      RuleEngine.extractFromElement(card, source.search.bookUrl),
      '/book/1',
    );
    expect(
      RuleEngine.extract('<div id="intro">简介</div>', source.detail.intro),
      '简介',
    );
    expect(
      RuleEngine.extract(
        '<div id="content">甲<br>乙</div>',
        source.content!.content,
      ),
      '甲\n乙',
    );
  });

  test('原生 CSS 与自定义回退正则保持不变', () {
    final legacy = legado();
    (legacy['ruleSearch'] as Map)['bookList'] = '@css:div.book';
    final converted = SourceImportAdapter.parse(jsonEncode(legacy))
        .single
        .json!;
    (converted['search'] as Map)['name'] = 'h3@text##^作者：## || a@text';
    final entry = SourceImportAdapter.parse(jsonEncode(converted)).single;
    expect(entry.reason, isNull);
    expect((entry.json!['search'] as Map)['bookList'], 'div.book');
    expect((entry.json!['search'] as Map)['name'], 'h3@text##^作者：## || a@text');
  });

  test('数组逐项报告无效项和同批重复', () {
    final entries = SourceImportAdapter.parse(
      jsonEncode([legado(), null, 1, legado()]),
    );
    expect(entries.where((e) => e.json != null).length, 1);
    expect(entries.last.reason, contains('重复'));
    expect(entries[1].reason, contains('不是书源对象'));
    expect(
      SourceImportAdapter.parse('42').single.reason,
      isNotNull,
    );
    expect(() => SourceImportAdapter.parse('{'), throwsFormatException);
  });

  for (final rule in [
    '@js:result',
    '<js>1</js>',
    r'$.data.books',
    'a@text##x##',
    'a@text||b@text',
  ]) {
    test('JS 与扩展规则保留原始写法 $rule', () {
      final json = legado();
      (json['ruleSearch'] as Map)['name'] = rule;
      final entry = SourceImportAdapter.parse(jsonEncode(json)).single;
      expect(entry.json, isNotNull);
      expect(entry.json!['implementation'], isNotNull);
      expect((entry.json!['search'] as Map)['name'], rule);
    });
  }

  for (final rule in [
    'class.book.0',
    'class.book@tag.a@text',
    'a:nth-child(2)@text',
  ]) {
    test('标准规则仍拒绝歧义写法 $rule', () {
      final json = legado();
      (json['ruleSearch'] as Map)['name'] = rule;
      final entry = SourceImportAdapter.parse(jsonEncode(json)).single;
      expect(entry.json, isNull);
      expect(entry.reason, isNotEmpty);
    });
  }

  for (final rule in ['//div/a', '@XPath://a', '@json:books']) {
    test('XPath/JSONPath 规则保留为扩展规则 $rule', () {
      final json = legado();
      (json['ruleSearch'] as Map)['name'] = rule;
      final entry = SourceImportAdapter.parse(jsonEncode(json)).single;
      expect(entry.json, isNotNull);
      expect(entry.json!['implementation'], 'extendedRule');
    });
  }

  test('缺少必需规则、复杂 URL、脚本请求头、非支持类型均拒绝', () {
    for (final change in <String, dynamic>{
      'searchUrl': '/search, {"method":"POST"}',
      'header': '{"Cookie":"{{java.get()}}"}',
      'bookSourceType': 1,
      'ruleToc': {},
      'ruleContent': {'content': '#content@text', 'replaceRegex': '广告'},
    }.entries) {
      final json = legado()..[change.key] = change.value;
      expect(
        SourceImportAdapter.parse(jsonEncode(json)).single.reason,
        isNotNull,
        reason: change.key,
      );
    }
  });

  test('小说、漫画与视频类型均保留，漫画正文必须为静态图片列表', () {
    final comic = SourceImportAdapter.parse(jsonEncode(legado(type: 2))).single;
    expect(BookSource.fromJson(comic.json!).type, ContentType.comic);
    final bad = legado(type: 2)..['ruleContent'] = {'content': '#content@text'};
    expect(
      SourceImportAdapter.parse(jsonEncode(bad)).single.reason,
      contains('漫画正文'),
    );
    final video = SourceImportAdapter.parse(jsonEncode(legado(type: 4))).single;
    expect(video.reason, isNull);
    expect(BookSource.fromJson(video.json!).type, ContentType.video);
  });

  test('JS 发现规则保留在原始配置中', () {
    final json = legado()..['exploreUrl'] = '@js:explore()';
    final entry = SourceImportAdapter.parse(jsonEncode(json)).single;
    expect(entry.json, isNotNull);
    expect(entry.json!['implementation'], 'jsRule');
    expect(entry.json!['legadoJson'], contains('exploreUrl'));
  });

  test('JS 单文件源码可直接导入', () {
    final script = '''
// @name: 测试 JS 源
// @bookSourceUrl: https://js.test/
function search(key) { return []; }
function getChapters(book) { return []; }
function getContent(chapter) { return '正文'; }
''';
    final entry = SourceImportAdapter.parse(script).single;
    expect(entry.reason, isNull);
    expect(BookSource.fromJson(entry.json!).implementation,
        SourceImplementation.jsFile);
    expect(entry.json!['jsCode'], contains('function search'));
  });

  test('初始化竞态、持久化、启停 discover、覆盖授权和旧入口', () async {
    final saved = SourceImportAdapter.parse(
      jsonEncode(legado(url: 'https://persisted.test')),
    ).single.json!;
    saved['discover'] = [
      {
        'key': 'top',
        'name': '榜单',
        'isRank': true,
        'url': 'https://persisted.test/top',
      },
    ];
    SharedPreferences.setMockInitialValues({
      'custom_sources': [jsonEncode(saved)],
      'disabled_sources': ['https://persisted.test'],
      'source_order': ['https://persisted.test', 'loc'],
    });
    // 不提前 await 仓库，模拟注册表先启动。
    final registry = SourceRegistry();
    final repo = SourceRepository();
    await registry.ready;
    expect(registry.all.first.sourceId, 'https://persisted.test');
    expect(repo.byId('https://persisted.test')!.discover.single.key, 'top');
    expect(repo.byId('https://persisted.test')!.enabled, isFalse);
    await registry.toggleEnabled('https://persisted.test', true);
    expect(repo.byId('https://persisted.test')!.discover.single.key, 'top');
    expect(
      repo.byId('https://persisted.test')!.headers['User-Agent'],
      'ReadingApp-Test',
    );

    final text = jsonEncode(legado());
    final first = await repo.importJsonWithReport(text);
    expect(first.added, 1);
    final denied = await repo.importJsonWithReport(text);
    expect(denied.overwritten, 0);
    expect(denied.skipped.single, contains('未授权覆盖'));
    final allowed = await repo.importJsonWithReport(
      text,
      overwriteIds: {'https://example.test'},
    );
    expect(allowed.overwritten, 1);
    final mixed = await repo.importJsonWithReport(
      jsonEncode([legado(url: 'https://another.test'), null]),
    );
    expect(mixed.added, 1);
    expect(mixed.skipped.length, 1);
    final concurrent = await Future.wait([
      repo.importJsonWithReport(
        jsonEncode(legado(url: 'https://concurrent-a.test')),
      ),
      repo.importJsonWithReport(
        jsonEncode(legado(url: 'https://concurrent-b.test')),
      ),
    ]);
    expect(concurrent.map((r) => r.added), [1, 1]);
    expect(await repo.importJson(text), 1);
    final disabled = legado(url: 'https://disabled.test')..['enabled'] = false;
    await repo.importJson(jsonEncode(disabled));
    await repo.toggle('https://disabled.test', true);
    final sp = await SharedPreferences.getInstance();
    final stored = sp
        .getStringList('custom_sources')!
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .toList();
    expect(
      stored.map((e) => e['sourceUrl']),
      containsAll(['https://concurrent-a.test', 'https://concurrent-b.test']),
    );
    final persisted = BookSource.fromJson(
      stored.firstWhere((e) => e['sourceUrl'] == 'https://persisted.test'),
    );
    expect(persisted.discover.single.key, 'top');
    expect(
      BookSource.fromJson(
        stored.firstWhere((e) => e['sourceUrl'] == 'https://disabled.test'),
      ).enabled,
      isTrue,
    );
    registry.reload();
    expect(registry.byId('https://example.test'), isNotNull);
  });

  test('文件读取、编码与超限校验', () async {
    final directory = await Directory.systemTemp.createTemp('source-import-');
    addTearDown(() => directory.delete(recursive: true));
    final text = jsonEncode(legado());
    final file = File('${directory.path}/source.json');
    await file.writeAsString(text);
    expect(await SourceImportInput.readFile(file.path), text);
    await file.writeAsBytes(List.filled(SourceImportInput.maxBytes + 1, 32));
    await expectLater(
      SourceImportInput.readFile(file.path),
      throwsFormatException,
    );
    // URL 仅接受无内嵌凭据的 HTTP(S)。
    await expectLater(
      SourceImportInput.download('file:///tmp/test.json'),
      throwsFormatException,
    );
    await expectLater(
      SourceImportInput.download('https://user:pass@example.test/x.json'),
      throwsFormatException,
    );
  });

  test('漫画静态图片列表规则可在真实 HTML 上提取多张图并携带请求头', () {
    final json = legado(url: 'https://example.test', type: 2);
    final bookSource = BookSource.fromJson(
      SourceImportAdapter.parse(jsonEncode(json)).single.json!,
    );
    final source = RuleSource(bookSource);
    final doc = html.parse(
      '<div class="pages"><img src="/1.jpg"><img src="/2.jpg"></div>',
    );
    final urls = RuleEngine.elements(
      doc,
      bookSource.content!.content,
    ).map((e) => RuleEngine.extractFromElement(e, 'src')).toList();
    expect(urls, ['/1.jpg', '/2.jpg']);
    expect(source.imageHeaders!['User-Agent'], 'ReadingApp-Test');
  });
}
