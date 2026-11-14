/// 调试全本小说网 HTML 结构。
/// 用法：dart run tool/debug_qbxs.dart
/// 抓详情页，打印 div.ml_list 与正文相关片段。
library;

import 'dart:io';

import 'package:reading_app/services/http_client.dart';

Future<void> main() async {
  const url = 'https://www.qbxs.net/book/44984/';
  final html = await HttpClient.getText(url, referer: 'https://www.qbxs.net');
  stdout.writeln('页面长度: ${html.length}');

  // 找目录块
  final i = html.indexOf('ml_list');
  if (i < 0) {
    stdout.writeln('!! 未找到 ml_list');
  } else {
    stdout.writeln('--- ml_list 附近 (500 字符) ---');
    stdout.writeln(html.substring(i, (i + 500).clamp(0, html.length)));
  }

  // 找 li a 的目录项
  final m = RegExp(r'<div class="ml_list">[\s\S]*?</div>\s*</div>').firstMatch(html);
  if (m != null) {
    stdout.writeln('\n--- ml_list 块前 800 字符 ---');
    stdout.writeln(m.group(0)!.substring(0, 800.clamp(0, m.group(0)!.length)));
  } else {
    stdout.writeln('\n!! ml_list 完整块未匹配');
  }

  // 搜索页作者列
  final searchHtml = await HttpClient.getText(
      'https://www.qbxs.net/search/?searchkey=${Uri.encodeComponent('斗破苍穹')}',
      referer: 'https://www.qbxs.net');
  final t = RegExp(r'<table[^>]*id="rankinglist"[\s\S]*?</table>').firstMatch(searchHtml);
  if (t != null) {
    stdout.writeln('\n--- 搜索表格前 900 字符 ---');
    stdout.writeln(t.group(0)!.substring(0, 900.clamp(0, t.group(0)!.length)));
  } else {
    stdout.writeln('\n!! 未找到 rankinglist 表格');
  }
}
