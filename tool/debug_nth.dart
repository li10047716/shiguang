/// 最小测试：验证 csslib 对 table tr td:nth-child 的选择行为。
/// 用法：dart run tool/debug_nth.dart
// ignore_for_file: avoid_print
library;

import 'package:html/parser.dart' as parser;

void main() {
  const html = '''
<table id="rankinglist">
  <tr>
    <td><p><a href="/book/44984/">书名A</a></p></td>
    <td><p><a href="/read/x.html">最新章节X</a></p></td>
    <td><p>作者Y</p></td>
    <td><p>类型Z</p></td>
  </tr>
</table>''';
  final doc = parser.parse(html);
  final tr = doc.querySelector('table#rankinglist tr')!;
  print('tr 子元素: ${tr.children.map((e) => e.localName).join(",")}');

  for (var n = 1; n <= 4; n++) {
    final sel = 'td:nth-child($n)';
    final found = tr.querySelectorAll(sel);
    print('$sel → ${found.map((e) => e.text.trim()).join("|")}');
  }
  print('--- nth-of-type ---');
  for (var n = 1; n <= 4; n++) {
    final sel = 'td:nth-of-type($n)';
    final found = tr.querySelectorAll(sel);
    print('$sel → ${found.map((e) => e.text.trim()).join("|")}');
  }

  // 直接子元素按索引
  final tds = tr.querySelectorAll('td');
  for (var i = 0; i < tds.length; i++) {
    print('td[$i] = ${tds[i].text.trim()}');
  }
}
