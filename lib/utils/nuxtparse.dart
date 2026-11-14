/// 解析快看漫画页面里的 Nuxt1 序列化数据。
///
/// 页面里是 `window.__NUXT__=(function(a,b,...){return {...}}("值",123,...));`
/// 这种格式：重复出现的字符串/数字被抽到函数参数表里，对象体里用变量名引用。
/// 这里用一个小型 JS 字面量求值器把数据还原成 Dart 对象，不依赖 JS 引擎。
///
/// 移植自 shiguang `reader/nuxtparse.py`。
library;

import 'dart:convert';

int _skip(String s, int i) {
  var j = i;
  while (j < s.length && ' \t\r\n'.contains(s[j])) {
    j++;
  }
  return j;
}

/// Nuxt 解析器。为简洁，parse 返回 (value, 新位置)。
class _NuxtParser {
  final String s;
  final Map<String, dynamic> scope;
  _NuxtParser(this.s, this.scope);

  int _skip(int i) {
    while (i < s.length && ' \t\r\n'.contains(s[i])) {
      i++;
    }
    return i;
  }

  (dynamic, int) parse(int i) {
    i = _skip(i);
    if (i >= s.length) throw FormatException('Nuxt 数据意外结束');
    final c = s[i];
    if (c == '"') return _string(i, '"');
    if (c == "'" || c == '`') return _string(i, c);
    if (c == '{') return _obj(i);
    if (c == '[') return _arr(i);
    if ((c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) || c == '-') {
      return _num(i);
    }
    final m = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*').firstMatch(s.substring(i));
    if (m != null) {
      final word = m.group(0)!;
      if (word == 'true') return (true, i + word.length);
      if (word == 'false') return (false, i + word.length);
      if (word == 'null') return (null, i + word.length);
      if (word == 'void') {
        var j = _skip(i + word.length);
        final m2 = RegExp(r'0\b').firstMatch(s.substring(j));
        return (null, j + (m2?.end ?? 0));
      }
      if (word == 'Array') {
        final m2 = RegExp(r'\((\d*)\)').firstMatch(s.substring(i + word.length));
        if (m2 != null) {
          final n = int.tryParse(m2.group(1) ?? '') ?? 0;
          return (List<dynamic>.filled(n, null), i + word.length + m2.end);
        }
      }
      if (scope.containsKey(word)) {
        return (scope[word], i + word.length);
      }
      throw FormatException('未知标识符 "$word" @$i');
    }
    throw FormatException('不认识的字符 "$c" @$i');
  }

  (String, int) _string(int i, String quote) {
    final out = StringBuffer();
    var j = i + 1;
    while (j < s.length) {
      final c = s[j];
      if (c == '\\') {
        out.write(s.substring(j, j + 2));
        j += 2;
        continue;
      }
      if (c == quote) break;
      out.write(c);
      j++;
    }
    var raw = out.toString();
    raw = raw.replaceAll('\\/', '/').replaceAll("\\'", "'").replaceAll('\\`', '`');
    try {
      final decoded = jsonDecode('"${raw.replaceAll('"', '\\"')}"');
      return (decoded.toString(), j + 1);
    } catch (_) {
      raw = raw.replaceAll('\\"', '"');
      return (raw.replaceAll('\\n', '\n').replaceAll('\\t', '\t'), j + 1);
    }
  }

  (dynamic, int) _num(int i) {
    final m = RegExp(r'-?\d+(\.\d+)?([eE][+-]?\d+)?').firstMatch(s.substring(i));
    final t = m!.group(0)!;
    final isFloat = t.contains('.') || t.toLowerCase().contains('e');
    return (isFloat ? double.tryParse(t) : int.tryParse(t), i + t.length);
  }

  (dynamic, int) _obj(int i) {
    final out = <String, dynamic>{};
    var j = _skip(i + 1);
    while (j < s.length && s[j] != '}') {
      final (key, k2) = _key(j);
      j = _skip(k2);
      if (j < s.length && s[j] == ':') j++;
      final (val, v2) = parse(j);
      out[key] = val;
      j = _skip(v2);
      if (j < s.length && s[j] == ',') {
        j = _skip(j + 1);
      }
    }
    return (out, j + 1);
  }

  (String, int) _key(int i) {
    if (i < s.length && (s[i] == '"' || s[i] == "'")) {
      return _string(i, s[i]);
    }
    final m = RegExp(r'[A-Za-z0-9_$]+').firstMatch(s.substring(i));
    return (m!.group(0)!, i + m.group(0)!.length);
  }

  (List<dynamic>, int) _arr(int i) {
    final out = <dynamic>[];
    var j = _skip(i + 1);
    while (j < s.length && s[j] != ']') {
      final (val, v2) = parse(j);
      out.add(val);
      j = _skip(v2);
      if (j < s.length && s[j] == ',') {
        j = _skip(j + 1);
      }
    }
    return (out, j + 1);
  }
}

/// 从页面 HTML 里解析 __NUXT__ 数据（找不到返回 null）。
dynamic parseNuxt(String html) {
  final m = RegExp(r'__NUXT__\s*=\s*').firstMatch(html);
  if (m == null) return null;
  var i = m.end;
  if (i < html.length && html[i] != '(') {
    // 直接赋 JSON 的情况
    final j = html.indexOf('{', i);
    final (v, _) = _NuxtParser(html, {}).parse(j);
    return v;
  }
  // (function(params){STMTS; return BODY}(ARGS)) 形式
  final m2 = RegExp(r'\(function\(([^)]*)\)\{').firstMatch(html.substring(i));
  if (m2 == null) return null;
  final params = m2
      .group(1)!
      .split(',')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  final bodyStart = i + m2.end;
  // 函数体结束在 "}(" —— return 之前可能还有 `name[idx]=value;` 这类数组元素赋值
  final close = html.lastIndexOf('}(');
  if (close < 0 || close < bodyStart) return null;
  final body = html.substring(bodyStart, close);
  final rm = RegExp(r'\breturn\b').firstMatch(body);
  final stmts = rm == null ? '' : body.substring(0, rm.start);
  final retExpr = rm == null ? body : body.substring(rm.end);

  final scope = <String, dynamic>{};
  final argValues = _parseArgs(html, close);
  for (var k = 0; k < params.length && k < argValues.length; k++) {
    scope[params[k]] = argValues[k];
  }
  _execStmts(stmts, scope);
  final (v, _) = _NuxtParser(retExpr, scope).parse(_skip(retExpr, 0));
  return v;
}

List<dynamic> _parseArgs(String html, int close) {
  var argsSrc = html.substring(close + 2);
  final end = argsSrc.indexOf('</script>');
  if (end < 0) throw FormatException('找不到 NUXT 调用结尾');
  argsSrc = argsSrc.substring(0, end).trimRight();
  argsSrc = argsSrc.replaceFirst(RegExp(r'[;)]+$'), '').trimRight();
  final (args, _) = _NuxtParser('[$argsSrc]', {}).parse(0);
  return (args as List<dynamic>);
}

void _execStmts(String src, Map<String, dynamic> scope) {
  var i = _skip(src, 0);
  while (i < src.length) {
    final m = RegExp(r'([A-Za-z_$][A-Za-z0-9_$]*)\[(-?\d+)\]\s*=\s*')
        .firstMatch(src.substring(i));
    if (m == null) break;
    final name = m.group(1)!;
    final idx = int.parse(m.group(2)!);
    var arr = scope[name];
    if (arr is! List) break;
    final (val, v2) = _NuxtParser(src, scope).parse(i + m.end);
    while (arr.length <= idx) {
      arr.add(null);
    }
    arr[idx] = val;
    i = _skip(src, v2);
    if (i < src.length && src[i] == ';') {
      i = _skip(src, i + 1);
    }
  }
}
