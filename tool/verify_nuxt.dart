/// Nuxt1 解析器单元验证（字符串/数组/对象/标识符/void 0/Array(n)）。
/// 用法：dart run tool/verify_nuxt.dart
// ignore_for_file: avoid_print
library;

import 'package:reading_app/utils/nuxtparse.dart';

void main() {
  var failed = 0;
  void check(String label, bool ok, String detail) {
    print('${ok ? "✓" : "✗"} $label: $detail');
    if (!ok) failed++;
  }

  // 案例 1：基础字面量（字符串/数字/布尔/null/数组/对象）
  final html1 = '<script>window.__NUXT__=(function(a,b,c){return {"title":a,'
      '"count":b,"flag":c,"arr":[1,2,3],"obj":{"x":"y"},"none":null,"v":void 0}'
      '}("你好",42,true));</script>';
  final d1 = parseNuxt(html1);
  check('解析对象', d1 is Map, '${d1.runtimeType}');
  if (d1 is Map) {
    check('字符串', d1['title'] == '你好', '${d1['title']}');
    check('数字', d1['count'] == 42, '${d1['count']}');
    check('布尔', d1['flag'] == true, '${d1['flag']}');
    check('数组', (d1['arr'] as List).join(',') == '1,2,3', '${d1['arr']}');
    check('对象', (d1['obj'] as Map)['x'] == 'y', '${d1['obj']}');
    check('null', d1['none'] == null, '${d1['none']}');
    check('void 0', d1['v'] == null, '${d1['v']}');
  }

  // 案例 2：Array(n) 预分配（作为中间参数，非末位，避免 rstrip 吃掉其右括号）
  // + 函数体 g[0]=...;g[1]=... 回填
  final html2 = '<script>window.__NUXT__=(function(g,z){g[0]="x";'
      'g[1]="回填";return {"list":g,"tail":z}}(Array(2),"结"));</script>';
  final d2 = parseNuxt(html2);
  if (d2 is Map) {
    final list = d2['list'];
    check('Array回填', list is List && list.length == 2 && list[0] == 'x' && list[1] == '回填',
        '$list');
    check('Array尾参', d2['tail'] == '结', '${d2['tail']}');
  } else {
    check('Array回填', false, '解析失败');
  }

  // 案例 3：转义字符串
  final html3 = r'''<script>window.__NUXT__=(function(){return {"s":"a\/b\nc\t\"d\""}}());</script>''';
  final d3 = parseNuxt(html3);
  if (d3 is Map) {
    check('转义字符串', '${d3['s']}'.contains('a/b'), '${d3['s']}');
  } else {
    check('转义字符串', false, '解析失败');
  }

  // 案例 4：JSON 直赋
  final html4 = '<script>window.__NUXT__={"data":[{"id":1165,"title":"测试"}]};</script>';
  final d4 = parseNuxt(html4);
  if (d4 is Map) {
    final data = d4['data'];
    check('JSON直赋', data is List && (data.first as Map)['id'] == 1165, '$data');
  } else {
    check('JSON直赋', false, '解析失败');
  }

  // 案例 5：参数表里的字符串含中文与特殊字符
  final html5 = '<script>window.__NUXT__=(function(a,b){return {"a":a,"b":b}}'
      '("第1话 开始","🔥付费"));</script>';
  final d5 = parseNuxt(html5);
  if (d5 is Map) {
    check('中文参数', d5['a'] == '第1话 开始', '${d5['a']}');
    check('emoji参数', d5['b'] == '🔥付费', '${d5['b']}');
  } else {
    check('中文参数', false, '解析失败');
  }

  print(failed == 0 ? '\n全部通过' : '\n$failed 项失败');
  if (failed > 0) throw StateError('$failed 项失败');
}
