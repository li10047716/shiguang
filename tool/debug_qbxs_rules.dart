/// 调试全本规则提取。
/// 用法：dart run tool/debug_qbxs_rules.dart
library;

import 'dart:io';

import 'package:html/parser.dart' as parser;
import 'package:reading_app/sources/rule_engine.dart';
import 'package:reading_app/services/http_client.dart';

Future<void> main() async {
  final searchHtml = await HttpClient.getText(
      'https://www.qbxs.net/search/?searchkey=${Uri.encodeComponent('斗破苍穹')}',
      referer: 'https://www.qbxs.net');

  final doc = parser.parse(searchHtml);
  final rows = RuleEngine.elements(doc, 'table#rankinglist tr');
  stdout.writeln('tr 行数: ${rows.length}');
  for (var i = 0; i < rows.length && i < 4; i++) {
    final el = rows[i];
    final name = RuleEngine.extractFromElement(el, 'td:nth-child(1) a@text');
    final a2 = RuleEngine.extractFromElement(el, 'td:nth-child(2) a@text');
    final a3 = RuleEngine.extractFromElement(el, 'td:nth-child(3)@text');
    final a4 = RuleEngine.extractFromElement(el, 'td:nth-child(4)@text');
    stdout.writeln('行$i: 名=[$name] td2=[$a2] td3=[$a3] td4=[$a4]');
  }

  final detailHtml = await HttpClient.getText(
      'https://www.qbxs.net/book/44984/', referer: 'https://www.qbxs.net');
  final ddoc = parser.parse(detailHtml);
  final chaps = RuleEngine.elements(ddoc, 'div.ml_list li a');
  stdout.writeln('div.ml_list li a 章节数: ${chaps.length}');
  if (chaps.isNotEmpty) {
    final t = RuleEngine.extractFromElement(chaps.first, 'text');
    final h = RuleEngine.extractFromElement(chaps.first, 'href');
    stdout.writeln('首章: [$t] [$h]');
  }
  final chaps2 = RuleEngine.elements(ddoc, 'div.ml_list ul li a');
  stdout.writeln('div.ml_list ul li a 章节数: ${chaps2.length}');
}
