/// Legado 复合规则解析器。
///
/// 真实书源经常把 JSONPath、JS、正则替换、备选规则串在一起，例如
/// `$.data.title@js:kbClean(result)` 或 `<js>kbPrep(result)</js>$.list`。
/// 这里按 Legado 的执行顺序把它们拆开，再交给对应的引擎执行。
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../models/book_source.dart';
import 'legado_runtime.dart';
import 'rule_engine.dart';

class LegadoRuleResolver {
  final BookSource source;
  final LegadoRuntime _runtime;

  LegadoRuleResolver(this.source) : _runtime = LegadoRuntime();

  Future<void> prepare() => _runtime.loadSource(source);

  Map<String, dynamic> _context(
    Object? input,
    Map<String, dynamic> extra,
  ) =>
      {
        'result': input,
        'source': input,
        'src': input,
        'baseUrl': source.baseUrl,
        'sourceInfo': source.headers,
        'sourceUrl': source.baseUrl,
        ...extra,
      };

  /// 提取单个文本值。
  Future<String> text(
    Object? input,
    String rule, {
    Map<String, dynamic> context = const {},
  }) async {
    if (rule.trim().isEmpty) return '';
    await prepare();
    for (final alt in _alternatives(rule)) {
      final value = await _textOne(input, alt, context);
      if (value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  /// 提取列表。JSON 数组、JS 返回数组、CSS 元素列表都归一化成 List。
  Future<List<dynamic>> list(
    Object? input,
    String rule, {
    Map<String, dynamic> context = const {},
  }) async {
    if (rule.trim().isEmpty) return const [];
    await prepare();
    final core = _splitReplace(rule).$1.trim();
    var value = await _resolve(core, input, context);
    if (value is List) return value;
    if (value is String) {
      final decoded = _decodeList(value);
      if (decoded != null) return decoded;
    }
    return const [];
  }

  Future<String> _textOne(
    Object? input,
    String rule,
    Map<String, dynamic> context,
  ) async {
    var r = rule.trim();
    if (r.toLowerCase().startsWith('@css:')) {
      r = r.substring(5).trim();
    }
    final parts = _splitReplace(r);
    final core = parts.$1.trim();
    final pattern = parts.$2;
    final replacement = parts.$3;
    final value = await _resolve(core, input, context);
    var text = LegadoRuntime.stringify(value);
    if (pattern.isNotEmpty) {
      try {
        text = text.replaceAll(
          RegExp(pattern, multiLine: true, dotAll: true),
          replacement,
        );
      } catch (_) {
        // 失效的正则不影响主结果。
      }
    }
    return text;
  }

  Future<dynamic> _resolve(
    String core,
    Object? input,
    Map<String, dynamic> context,
  ) async {
    if (core.isEmpty) return '';

    final jsBlock = RegExp(r'<js>([\s\S]*?)</js>').firstMatch(core);
    if (jsBlock != null) {
      final code = jsBlock.group(1)!.trim();
      final tail = core.substring(jsBlock.end).trim();
      final dynamic raw = await _runtime.evaluateRule(
        code,
        result: _result(input),
        key: '${context['key'] ?? ''}',
        page: context['page'] is int ? context['page'] as int : 1,
        book: _map(context['book']),
        chapter: _map(context['chapter']),
        bookSource: source,
      );
      if (tail.isEmpty) return raw;
      if (tail.startsWith(r'$')) return LegadoRuntime.jsonPath(raw, tail);
      return tail;
    }

    if (core.startsWith('@js:')) {
      return _runtime.evaluateRule(
        core,
        result: _result(input),
        key: '${context['key'] ?? ''}',
        page: context['page'] is int ? context['page'] as int : 1,
        book: _map(context['book']),
        chapter: _map(context['chapter']),
        bookSource: source,
      );
    }

    final jsAt = core.indexOf('@js:');
    if (jsAt > 0) {
      final left = core.substring(0, jsAt).trim();
      final current = await _resolve(left, input, context);
      return _runtime.evaluateRule(
        core.substring(jsAt + 4),
        result: current,
        key: '${context['key'] ?? ''}',
        page: context['page'] is int ? context['page'] as int : 1,
        book: _map(context['book']),
        chapter: _map(context['chapter']),
        bookSource: source,
      );
    }

    if (core.contains('{{')) {
      return _runtime.evaluateTemplate(core, context: _context(input, context));
    }

    if (core.startsWith(r'$') || core.startsWith('@json:')) {
      final path = core.startsWith('@json:') ? core.substring(6) : core;
      return LegadoRuntime.jsonPath(input, path);
    }

    return _simple(core, input);
  }

  Future<dynamic> _simple(String rule, Object? input) async {
    if (rule.isEmpty) return '';
    if (input is Map) {
      final direct = input[rule] ?? input[rule.replaceFirst(r'$.', '')];
      if (direct != null) return direct;
    }
    if (input is String) {
      final trimmed = input.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map && decoded.containsKey(rule)) return decoded[rule];
        } catch (_) {}
      }
    }
    if (input is dom.Element) {
      return RuleEngine.extractFromElement(input, rule);
    }
    final html = input is String ? input : LegadoRuntime.stringify(input);
    return RuleEngine.extract(html, rule);
  }

  /// CSS 列表：兼容 `||` 备选与 `@tag.a` 链式写法。
  Future<List<dynamic>> cssList(String rule, Object? input) async {
    await prepare();
    for (final alt in _alternatives(rule)) {
      final parts = _splitReplace(alt);
      var selector = parts.$1.trim();
      if (selector.toLowerCase().startsWith('@css:')) {
        selector = selector.substring(5).trim();
      }
      if (selector.isEmpty) continue;
      List<dom.Element> elements;
      if (input is dom.Element) {
        elements = input.querySelectorAll(selector);
      } else {
        elements = RuleEngine.elements(
          parser.parse(LegadoRuntime.stringify(input)),
          selector,
        );
      }
      if (elements.isNotEmpty) return elements;
    }
    return const [];
  }

  Object? _result(Object? input) {
    if (input is dom.Element) return input.outerHtml;
    return input;
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  /// 只在纯 CSS/JSONPath 规则上拆分 `||`；JS 代码里的 `||` 不能拆。
  static List<String> _alternatives(String rule) {
    if (rule.contains('<js>') ||
        rule.contains('@js:') ||
        rule.contains('{{')) {
      return [rule];
    }
    return rule.split('||').where((e) => e.trim().isNotEmpty).toList();
  }

  /// 拆出 `##正则##替换` 后处理。返回 (主体, 正则, 替换)。
  static (String, String, String) _splitReplace(String rule) {
    final first = rule.indexOf('##');
    if (first < 0) return (rule, '', '');
    final body = rule.substring(0, first);
    final rest = rule.substring(first + 2);
    final second = rest.indexOf('##');
    if (second < 0) return (body, rest, '');
    final pattern = rest.substring(0, second);
    var replacement = rest.substring(second + 2);
    if (replacement.endsWith('##')) {
      replacement = replacement.substring(0, replacement.length - 2);
    }
    return (body, pattern, replacement);
  }

  static List<dynamic>? _decodeList(String value) {
    final text = value.trim();
    if (text.isEmpty) return const [];
    if (text.startsWith('[')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    if (!text.contains('\n')) return null;
    return text.split('\n').where((e) => e.trim().isNotEmpty).toList();
  }
}
