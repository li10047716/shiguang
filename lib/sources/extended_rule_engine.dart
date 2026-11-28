/// XPath / JSONPath / 正则书源规则的最小兼容实现。
/// 仅覆盖 Legado 书源中最常见的写法，复杂表达式建议改用 JS 规则。
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import 'rule_engine.dart';

class ExtendedRuleEngine {
  static String extract(String source, String rule) {
    var r = rule.trim();
    if (r.isEmpty) return '';

    final regexMatch = RegExp(r'^:(.+?)##(.*)$').firstMatch(r);
    if (regexMatch != null) {
      try {
        return source
            .replaceAll(RegExp(regexMatch.group(1)!), regexMatch.group(2)!)
            .trim();
      } catch (_) {
        return '';
      }
    }

    if (r.startsWith('@Json:')) {
      r = r.substring(6).trim();
    } else if (r.toLowerCase().startsWith('@json:')) {
      r = r.substring(6).trim();
    }
    if (r.startsWith(r'$')) return _jsonPath(source, r);

    final xpath = _xpathToRule(r);
    if (xpath != null) return RuleEngine.extract(source, xpath);

    // `##正则##替换` 后处理
    return RuleEngine.extract(source, r);
  }

  static List<dom.Element> elements(String html, String rule) {
    var r = rule.trim();
    if (r.toLowerCase().startsWith('@xpath:')) r = r.substring(7).trim();
    final xpath = _xpathToRule(r);
    if (xpath != null) return RuleEngine.elements(parser.parse(html), xpath);
    return RuleEngine.elements(parser.parse(html), r);
  }

  static String? _xpathToRule(String input) {
    var r = input.trim();
    if (!r.startsWith('//') && !r.startsWith('/') &&
        !r.toLowerCase().startsWith('@xpath:')) {
      return null;
    }
    if (r.toLowerCase().startsWith('@xpath:')) r = r.substring(7).trim();

    var attr = 'text';
    if (r.endsWith('/text()')) {
      r = r.substring(0, r.length - 7);
    } else {
      final m = RegExp(r'/@([\w-]+)$').firstMatch(r);
      if (m != null) {
        attr = m.group(1)!;
        r = r.substring(0, m.start);
      }
    }
    r = r.replaceAll(RegExp(r'^//?'), '');
    final parts = r.split('/').where((p) => p.isNotEmpty).toList();
    final css = parts.map((part) {
      final classMatch = RegExp(r'''^(\w+)\[@class=['"]([^'"]+)['"]\]$''')
          .firstMatch(part);
      if (classMatch != null) {
        return '${classMatch.group(1)}.${classMatch.group(2)!.split(' ').join('.')}';
      }
      final idMatch = RegExp(r'''^(\w+)\[@id=['"]([^'"]+)['"]\]$''')
          .firstMatch(part);
      if (idMatch != null) return '${idMatch.group(1)}#${idMatch.group(2)}';
      final tagMatch = RegExp(r'^([A-Za-z][\w-]*)$').firstMatch(part);
      if (tagMatch != null) return tagMatch.group(1)!;
      return part;
    }).join(' ');
    if (css.isEmpty) return null;
    return '$css@$attr';
  }

  static String _jsonPath(String source, String path) {
    Object? value;
    try {
      value = jsonDecode(source);
    } catch (_) {
      return '';
    }
    final clean = path.replaceFirst(r'$', '');
    final tokens = <String>[];
    final re = RegExp(r'\.([A-Za-z_][\w-]*)|\[([^\]]+)\]');
    for (final m in re.allMatches(clean)) {
      final token = m.group(1) ?? m.group(2) ?? '';
      tokens.add(token.replaceAll('"', '').replaceAll("'", ''));
    }
    for (final token in tokens) {
      if (value is List) {
        final index = int.tryParse(token);
        if (index == null || index < 0 || index >= value.length) return '';
        value = value[index];
      } else if (value is Map) {
        value = value[token];
      } else {
        return '';
      }
    }
    if (value == null) return '';
    if (value is List) return value.map((e) => e.toString()).join('\n');
    if (value is Map) return jsonEncode(value);
    return value.toString();
  }
}
