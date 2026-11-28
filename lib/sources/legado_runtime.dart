/// Legado JavaScript 运行时。
///
/// 使用 QuickJS / JavaScriptCore 执行书源脚本，并提供 Legado 常用的
/// `java.*` 兼容对象。jsLib 以全局作用域加载，规则里的函数才能互相调用。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/book_source.dart';
import '../services/http_client.dart';

class LegadoRuntime {
  LegadoRuntime._();

  static final LegadoRuntime _instance = LegadoRuntime._();
  factory LegadoRuntime() => _instance;

  JavascriptRuntime? _engine;
  final Set<String> _loaded = <String>{};

  /// 求值并等待 Promise 完成。flutter_js 的 evaluateAsync 本身不展开 Promise，
  /// 必须显式调用 handlePromise，否则拿到的是 [object Promise]。
  Future<dynamic> _eval(String code) async {
    final result = await _runtime.evaluateAsync(code);
    if (result.isError) {
      throw StateError('JS 执行失败：${result.stringResult}');
    }
    final resolved = await _runtime.handlePromise(result);
    if (resolved.isError) {
      throw StateError('JS 执行失败：${resolved.stringResult}');
    }
    return _unwrap(resolved);
  }

  JavascriptRuntime get _runtime {
    final engine = _engine;
    if (engine != null) return engine;
    final created = getJavascriptRuntime(xhr: true);
    created.onMessage('legado_sync', (dynamic args) => _sync(args));
    created.onMessage('legado_async', (dynamic args) => _async(args));
    created.evaluate(_globalPreamble);
    _engine = created;
    return created;
  }

  /// 执行一段 JS 规则，返回其求值结果。
  Future<dynamic> evaluate(
    String code, {
    Map<String, dynamic> context = const {},
  }) async {
    if (code.trim().isEmpty) return '';
    final wrapped = '(async function(){\n'
        '${_assign(context)}\n'
        '${_awaitify(code)}\n'
        '})()';
    return _eval(wrapped);
  }

  /// 加载书源的 jsLib / 单文件脚本（只加载一次，全局作用域）。
  Future<void> loadSource(BookSource source) async {
    if (_loaded.contains(source.id)) return;
    final lib = source.jsLib?.trim() ?? '';
    final code = source.jsCode?.trim() ?? '';
    if (lib.isEmpty && code.isEmpty) {
      _loaded.add(source.id);
      return;
    }
    // 先确保全局桥接存在，jsLib 里的顶层函数才能引用 java / host 等。
    _runtime;
    if (lib.isNotEmpty) {
      await _eval(lib);
    }
    if (code.isNotEmpty) {
      await _eval(code);
    }
    _loaded.add(source.id);
  }

  /// 调用 JavaScript 单文件书源导出的函数。
  Future<dynamic> call(
    BookSource source,
    String functionName,
    List<dynamic> args,
  ) async {
    await loadSource(source);
    final callArgs = args.map(_jsLiteral).join(',');
    return _eval(
      '(async function(){ return await $functionName($callArgs); })()',
    );
  }

  /// 求值字符串里的所有 `{{...}}` 表达式。
  ///
  /// 支持 Legado 常见的 `{{key}}`、`{{page}}`、`{{签名函数(...)}}`
  /// 以及 `{{$.jsonPath}}`。
  Future<String> evaluateTemplate(
    String text, {
    Map<String, dynamic> context = const {},
  }) async {
    if (!text.contains('{{')) return text;
    final pattern = RegExp(r'\{\{(.+?)\}\}', dotAll: true);
    var out = text;
    // 多次展开：表达式结果里可能又含模板变量。
    for (var round = 0; round < 3 && out.contains('{{'); round++) {
      final matches = pattern.allMatches(out).toList();
      for (final m in matches.reversed) {
        var expr = m.group(1)!.trim();
        if (expr.startsWith('@@')) expr = expr.substring(2).trim();
        Object? value;
        if (expr.startsWith(r'$')) {
          value = jsonPath(context['result'], expr);
        } else {
          value = await evaluate('return ($expr);', context: context);
        }
        final replacement = stringify(value);
        out = out.replaceRange(m.start, m.end, replacement);
      }
    }
    return out;
  }

  /// 执行 Legado JS 规则表达式（`@js:` / `<js>` / `{{...}}` / 裸 JS）。
  Future<String> evaluateRule(
    String rule, {
    String source = '',
    String baseUrl = '',
    String src = '',
    dynamic result,
    Map<String, dynamic> book = const {},
    Map<String, dynamic> chapter = const {},
    Map<String, dynamic> sourceInfo = const {},
    String title = '',
    String nextChapterUrl = '',
    String key = '',
    int page = 1,
    BookSource? bookSource,
  }) async {
    if (bookSource != null) await loadSource(bookSource);
    var code = rule.trim();
    if (code.contains('{{')) {
      code = await evaluateTemplate(
        code,
        context: _context(
          source: source,
          baseUrl: baseUrl,
          src: src,
          result: result,
          book: book,
          chapter: chapter,
          sourceInfo: sourceInfo,
          title: title,
          nextChapterUrl: nextChapterUrl,
          key: key,
          page: page,
        ),
      );
    }
    if (code.startsWith('@js:')) code = code.substring(4).trim();
    if (code.startsWith('<js>') && code.endsWith('</js>')) {
      code = code.substring(4, code.length - 5).trim();
    }
    final value = await evaluate(
      'return ($code);',
      context: _context(
        source: source,
        baseUrl: baseUrl,
        src: src,
        result: result,
        book: book,
        chapter: chapter,
        sourceInfo: sourceInfo,
        title: title,
        nextChapterUrl: nextChapterUrl,
        key: key,
        page: page,
      ),
    );
    return stringify(value);
  }

  /// 轻量 JSONPath，供模板和规则解析器复用。
  static Object? jsonPath(Object? input, String path) {
    Object? value = input;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return '';
      }
    }
    var clean = path.trim();
    if (clean.startsWith(r'$')) clean = clean.substring(1);
    final tokens = <String>[];
    final re = RegExp(r'\.([A-Za-z_][\w-]*)|\[([^\]]+)\]');
    for (final m in re.allMatches(clean)) {
      final token = (m.group(1) ?? m.group(2) ?? '')
          .replaceAll('"', '')
          .replaceAll("'", '');
      tokens.add(token);
    }
    if (clean.isEmpty && tokens.isEmpty && path.trim() == r'$') return value;
    for (final token in tokens) {
      if (token == '*') {
        if (value is List) {
          // 通配符只在最后一段有意义：拍平成换行文本。
          return value.map(stringify).join('\n');
        }
        if (value is Map) {
          return value.values.map(stringify).join('\n');
        }
        return '';
      }
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
    return value;
  }

  static String stringify(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is List) return value.map(stringify).join('\n');
    if (value is Map) return jsonEncode(value);
    return value.toString();
  }

  static Map<String, dynamic> _context({
    required String source,
    required String baseUrl,
    required String src,
    required dynamic result,
    required Map<String, dynamic> book,
    required Map<String, dynamic> chapter,
    required Map<String, dynamic> sourceInfo,
    required String title,
    required String nextChapterUrl,
    required String key,
    required int page,
  }) =>
      {
        'source': source,
        'baseUrl': baseUrl,
        'src': src,
        'result': result,
        'book': book,
        'chapter': chapter,
        'sourceInfo': sourceInfo,
        'title': title,
        'nextChapterUrl': nextChapterUrl,
        'key': key,
        'page': page,
      };

  // ---------- 桥接 ----------

  Object? _sync(dynamic raw) {
    final args = raw as List;
    final kind = args[0] as String;
    final values = (args[1] as List?) ?? const [];
    switch (kind) {
      case 'md5':
        return md5.convert(utf8.encode(_s(values, 0))).toString();
      case 'md516':
        final hex = md5.convert(utf8.encode(_s(values, 0))).toString();
        return hex.substring(8, 24);
      case 'sha1':
        return sha1.convert(utf8.encode(_s(values, 0))).toString();
      case 'sha256':
        return sha256.convert(utf8.encode(_s(values, 0))).toString();
      case 'base64encode':
        return base64.encode(utf8.encode(_s(values, 0)));
      case 'base64decode':
        try {
          return utf8.decode(base64.decode(_s(values, 0)));
        } catch (_) {
          return '';
        }
      case 'urlencode':
        return Uri.encodeQueryComponent(_s(values, 0));
      case 'urldecode':
        try {
          return Uri.decodeQueryComponent(_s(values, 0));
        } catch (_) {
          return '';
        }
      case 'timeFormat':
        final rawTime = _s(values, 0);
        final ms = int.tryParse(rawTime) ?? 0;
        final dt = ms > 0
            ? DateTime.fromMillisecondsSinceEpoch(ms)
            : DateTime.now();
        return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} '
            '${_two(dt.hour)}:${_two(dt.minute)}';
      case 'jsoupSelect':
        return _jsoupSelect(_s(values, 0), _s(values, 1));
      default:
        return '';
    }
  }

  /// 极简 Jsoup 兼容：返回匹配元素的数组 JSON，每项含 text/html 及属性。
  /// 只支持 tag/class/id/属性选择器，覆盖常见 `doc.select('div.foo a')`。
  static String _jsoupSelect(String html, String selector) {
    try {
      final doc = _parseHtml(html);
      final elements = _query(doc, selector);
      final list = elements
          .map(
            (e) => {
              'text': e.text.trim(),
              'html': e.outerHtml,
              'attrs': e.attributes.map((k, v) => MapEntry(k, v)),
            },
          )
          .toList();
      return jsonEncode(list);
    } catch (_) {
      return '[]';
    }
  }

  static dom.Document _parseHtml(String html) =>
      html_parser.parse(html.contains('<') ? html : '<html></html>');

  static List<dom.Element> _query(dom.Node root, String selector) {
    var nodes = <dom.Element>[
      if (root is dom.Element) root else ...root.children.whereType<dom.Element>(),
    ];
    for (final part in selector.split(RegExp(r'\s+'))) {
      if (part.isEmpty) continue;
      final next = <dom.Element>[];
      for (final node in nodes) {
        if (_matchSelector(node, part)) {
          next.add(node);
        } else {
          next.addAll(node.querySelectorAll(part));
        }
      }
      nodes = next;
    }
    return nodes;
  }

  static bool _matchSelector(dom.Element el, String selector) {
    final sel = selector.trim();
    final m = RegExp(r'^([A-Za-z][\w-]*)?(?:#([\w-]+))?(?:\.([\w-]+))?$')
        .firstMatch(sel);
    if (m == null) return false;
    final tag = m.group(1);
    final id = m.group(2);
    final cls = m.group(3);
    if (tag != null && el.localName != tag.toLowerCase()) return false;
    if (id != null && el.attributes['id'] != id) return false;
    if (cls != null && !el.classes.contains(cls)) return false;
    return true;
  }

  Future<Object?> _async(dynamic raw) async {
    final args = raw as List;
    final kind = args[0] as String;
    final values = (args[1] as List?) ?? const [];
    if (kind == 'ajax' || kind == 'connect') {
      final url = _s(values, 0);
      final rawHeaders = values.length > 1 && values[1] is Map
          ? values[1] as Map
          : const {};
      final headers = <String, String>{
        for (final e in rawHeaders.entries) e.key.toString(): e.value.toString(),
      };
      if (url.isEmpty) return '';
      try {
        return await HttpClient.getText(
          url,
          headers: headers.isEmpty ? null : headers,
          useCache: false,
          maxBytes: 4 * 1024 * 1024,
        );
      } catch (_) {
        return '';
      }
    }
    return _sync(raw);
  }

  static String _s(List values, int index) =>
      values.length > index ? (values[index] ?? '').toString() : '';

  static String _two(int n) => n.toString().padLeft(2, '0');

  static Object? _unwrap(dynamic value) {
    if (value is JsEvalResult) return _unwrap(value.rawResult);
    return value;
  }

  static String _jsLiteral(Object? value) => jsonEncode(value ?? '');

  /// 把同步写法的网络调用改成 await，兼容常见 Legado 书源。
  static String _awaitify(String code) => code.replaceAllMapped(
        RegExp(r'\bjava\.(ajax|connect)\s*\('),
        (m) {
          final before = code.substring(0, m.start);
          if (RegExp(r'await\s*$').hasMatch(before)) return m.group(0)!;
          return 'await ${m.group(0)}';
        },
      );

  /// 每次求值前把上下文变量写入全局，避免重复 var 声明。
  static String _assign(Map<String, dynamic> context) => '''
key = ${_jsLiteral(context['key'] ?? '')};
page = ${_jsLiteral(context['page'] ?? 1)};
result = __wrap(${_jsLiteral(context['result'] ?? '')});
source = ${_jsLiteral(context['source'] ?? '')};
baseUrl = ${_jsLiteral(context['baseUrl'] ?? '')};
src = ${_jsLiteral(context['src'] ?? '')};
book = __wrap(${_jsLiteral(context['book'] ?? {})});
chapter = __wrap(${_jsLiteral(context['chapter'] ?? {})});
sourceInfo = __wrap(${_jsLiteral(context['sourceInfo'] ?? {})});
title = ${_jsLiteral(context['title'] ?? '')};
nextChapterUrl = ${_jsLiteral(context['nextChapterUrl'] ?? '')};
''';

  /// 全局桥接只初始化一次；jsLib 在全局作用域执行，函数间可互相调用。
  static const String _globalPreamble = r'''
var key = '';
var page = 1;
var result = '';
var source = '';
var baseUrl = '';
var src = '';
var book = {};
var chapter = {};
var sourceInfo = {};
var title = '';
var nextChapterUrl = '';
var host = '';
var sourceUrl = '';
var __store = {};
function __wrap(v){
  if (v && typeof v === 'object') {
    if (!Array.isArray(v) && typeof v.get !== 'function') {
      Object.defineProperty(v, 'get', {value: function(k, d){
        return v[k] === undefined ? (d === undefined ? '' : d) : v[k];
      }, enumerable: false});
      Object.defineProperty(v, 'set', {value: function(k, val){ v[k] = val; }, enumerable: false});
    }
    for (var k in v) {
      if (v[k] && typeof v[k] === 'object') __wrap(v[k]);
    }
  }
  return v;
}
function J(v){
  if (typeof v === 'string') { try { return JSON.parse(v); } catch (e) { return {}; } }
  return v || {};
}
function SV(k, d){ return java.get(k, d); }
function __dart(kind, args) {
  return sendMessage('legado_async', JSON.stringify([kind, args]));
}
function __dartSync(kind, args) {
  return sendMessage('legado_sync', JSON.stringify([kind, args]));
}
var java = {
  ajax: function(url, headers){ return __dart('ajax', [url, headers || {}]); },
  connect: function(url, headers){ return __dart('connect', [url, headers || {}]); },
  ajaxAll: function(urls){ return Promise.all(urls.map(function(u){ return __dart('ajax', [u, {}]); })); },
  get: function(k, d){ var v = __store[String(k)]; return v === undefined ? (d === undefined ? '' : d) : v; },
  put: function(k, v){ __store[String(k)] = String(v); },
  getCookie: function(){ return ''; },
  setCookie: function(){},
  getVerificationCode: function(){ return ''; },
  webView: function(){ return ''; },
  startBrowser: function(){},
  toast: function(){},
  log: function(){},
  md5Encode: function(s){ return __dartSync('md5', [String(s)]); },
  md5Encode16: function(s){ return __dartSync('md516', [String(s)]); },
  sha1Encode: function(s){ return __dartSync('sha1', [String(s)]); },
  sha256Encode: function(s){ return __dartSync('sha256', [String(s)]); },
  base64Encode: function(s){ return __dartSync('base64encode', [String(s)]); },
  base64Decode: function(s){ return __dartSync('base64decode', [String(s)]); },
  urlEncode: function(s){ return __dartSync('urlencode', [String(s)]); },
  urlDecode: function(s){ return __dartSync('urldecode', [String(s)]); },
  timeFormat: function(t){ return __dartSync('timeFormat', [t == null ? '' : String(t)]); },
  getString: function(rule, isUrl){ return String(rule == null ? '' : rule); }
};
var org = { jsoup: { Jsoup: { parse: function(html){
  var arr = JSON.parse(__dartSync('jsoupSelect', [String(html || ''), '']));
  var doc = String(html || '');
  return {
    select: function(selector){
      var items = JSON.parse(__dartSync('jsoupSelect', [doc, String(selector || '')]));
      function Element(o){ this._o = o; }
      Element.prototype.text = function(){ return this._o.text || ''; };
      Element.prototype.html = function(){ return this._o.html || ''; };
      Element.prototype.attr = function(k, d){ var v = this._o.attrs[String(k)]; return v === undefined ? (d || '') : v; };
      var list = items.map(function(o){ return new Element(o); });
      return {
        size: function(){ return list.length; },
        get: function(i){ return list[i] || new Element({text:'',html:'',attrs:{}}); },
        text: function(){ return list.map(function(e){ return e.text(); }).join('\n'); },
        html: function(){ return list.map(function(e){ return e.html(); }).join(''); },
        first: function(){ return list[0] || new Element({text:'',html:'',attrs:{}}); }
      };
    },
    text: function(){ return String(doc).replace(/<[^>]+>/g, ' ').trim(); }
  };
} } } };
''';
}
