import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;

import '../models/book_source.dart';
import 'rule_engine.dart';

class SourceImportEntry {
  final String name;
  final Map<String, dynamic>? json;
  final String? reason;
  final List<String> warnings;

  const SourceImportEntry(
    this.name, {
    this.json,
    this.reason,
    this.warnings = const [],
  });
  String get id => json?['sourceUrl'] as String? ?? '';
}

class SourceImportReport {
  final int added;
  final int overwritten;
  final List<String> skipped;
  final List<String> warnings;

  const SourceImportReport({
    this.added = 0,
    this.overwritten = 0,
    this.skipped = const [],
    this.warnings = const [],
  });

  String get summary =>
      '新增 $added，覆盖 $overwritten，跳过 ${skipped.length}'
      '${skipped.isEmpty ? '' : '\n${skipped.join('\n')}'}'
      '${warnings.isEmpty ? '' : '\n${warnings.join('\n')}'}';
}

/// 把 Legado 书源（JSON 规则、JS 规则、JS 单文件、WebView 规则）转成
/// 本 App 的持久化格式。
///
/// 导入阶段**不执行**书源里的任何脚本；脚本只在运行时由 LegadoRuntime 执行。
class SourceImportAdapter {
  static List<SourceImportEntry> parse(String text) {
    final trimmed = text.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic> && decoded is! List) {
        throw const FormatException('JSON 顶层必须是书源对象或数组');
      }
      final entries = decoded is List ? decoded : [decoded];
      final seen = <String>{};
      return [
        for (var i = 0; i < entries.length; i++) _entry(entries[i], i, seen),
      ];
    }
    // 非 JSON：按 JavaScript 单文件书源处理。
    return [_jsFile(trimmed)];
  }

  static SourceImportEntry _entry(dynamic raw, int index, Set<String> seen) {
    var name = '第 ${index + 1} 项';
    try {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('不是书源对象');
      }
      name = (raw['bookSourceName'] ?? raw['sourceName'] ?? name).toString();
      final legado = raw.containsKey('bookSourceUrl');
      final warnings = <String>[];
      final json = legado
          ? _legado(raw, warnings)
          : Map<String, dynamic>.from(raw);
      _validate(json, legado: legado);
      final id = json['sourceUrl'] as String;
      if (!seen.add(id)) throw const FormatException('同一批次书源 URL 重复，保留第一项');
      return SourceImportEntry(name, json: json, warnings: warnings);
    } catch (e) {
      return SourceImportEntry(
        name,
        reason: e is FormatException ? e.message.toString() : '字段类型错误：$e',
      );
    }
  }

  static bool _present(dynamic v) =>
      v != null &&
      v != '' &&
      v != false &&
      !(v is Map && v.isEmpty) &&
      !(v is List && v.isEmpty);

  static final _jsMarkers = RegExp(
    r'@js:|<js>|</js>|javascript:|java\.|\bfunction\s+\w+\s*\(|\basync\s+function|=>',
    caseSensitive: false,
  );

  static final _extendedMarkers = RegExp(
    r'^[@/]?[xX][pP]ath:|^@[jJ]son:|^\s*//|^\s*/\w|^\s*\$\.|^\s*\$\[|##|\|\||^\s*:\w+##',
  );

  static bool _hasJs(Object? value) {
    if (value == null) return false;
    if (value is String) return _jsMarkers.hasMatch(value);
    if (value is Map) return value.values.any(_hasJs);
    if (value is List) return value.any(_hasJs);
    return false;
  }

  static bool _hasExtended(Object? value) {
    if (value == null) return false;
    if (value is String) return _extendedMarkers.hasMatch(value.trim());
    if (value is Map) return value.values.any(_hasExtended);
    if (value is List) return value.any(_hasExtended);
    return false;
  }

  static SourceImplementation _implementation(Map<String, dynamic> j) {
    if (_present(j['mainJs']) || _present(j['js'])) {
      return SourceImplementation.jsFile;
    }
    // loginUi / loginUrl 只是登录面板，不代表书源依赖 WebView 渲染。
    final webViewKeys = [
      'webView',
      'webViewJs',
      'ruleWebView',
      'sourceRegex',
    ];
    if (webViewKeys.any((k) => _present(j[k]))) {
      return SourceImplementation.webView;
    }
    final jsKeys = [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
      'ruleExplore',
      'searchUrl',
      'exploreUrl',
      'jsLib',
      'loginCheckJs',
      'coverDecodeJs',
    ];
    if (jsKeys.any((k) => _hasJs(j[k]))) return SourceImplementation.jsRule;
    final ruleKeys = [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
      'ruleExplore',
    ];
    if (ruleKeys.any((k) => _hasExtended(j[k]))) {
      return SourceImplementation.extendedRule;
    }
    return SourceImplementation.standard;
  }

  static String _contentType(int type) => switch (type) {
    2 => 'comic',
    4 => 'video',
    _ => 'novel',
  };

  static Map<String, dynamic> _legado(
    Map<String, dynamic> j,
    List<String> warnings,
  ) {
    final typeValue = j['bookSourceType'] ?? 0;
    final int type = typeValue is int
        ? typeValue
        : int.tryParse(typeValue.toString()) ?? 0;
    if (![0, 2, 4].contains(type)) {
      throw const FormatException('仅支持文本(0)、图片(2)和视频(4)类型');
    }
    final implementation = _implementation(j);
    final loose = implementation != SourceImplementation.standard;
    if (loose) {
      warnings.add(
        '实现方式：${switch (implementation) {
          SourceImplementation.extendedRule => 'XPath/JSONPath/正则扩展规则',
          SourceImplementation.jsRule => 'JS 增强规则',
          SourceImplementation.jsFile => 'JS 单文件',
          SourceImplementation.webView => 'WebView 规则',
          SourceImplementation.standard => '标准规则',
        }}，脚本仅在运行时执行',
      );
    }

    Map<String, dynamic> rules(String key, Set<String> allowed) {
      final value = j[key];
      if (value == null) return {};
      if (value is! Map<String, dynamic>) throw FormatException('$key 必须是规则对象');
      for (final entry in value.entries) {
        if (!allowed.contains(entry.key) && _present(entry.value)) {
          if (loose) {
            warnings.add('$key.${entry.key} 暂未映射到原生规则，已保留原始配置');
          } else {
            throw FormatException('$key.${entry.key} 尚不能转换');
          }
        }
      }
      return value;
    }

    final search = rules('ruleSearch', {
      'bookList',
      'name',
      'author',
      'coverUrl',
      'bookUrl',
      'lastChapter',
      'intro',
      'kind',
      'wordCount',
    });
    final info = rules('ruleBookInfo', {
      'name',
      'author',
      'coverUrl',
      'intro',
      'tocUrl',
      'lastChapter',
      'kind',
      'wordCount',
    });
    final toc = rules('ruleToc', {
      'chapterList',
      'chapterName',
      'chapterUrl',
      'nextTocUrl',
    });
    final content = rules('ruleContent', {'content', 'nextContentUrl'});

    if (!loose) {
      for (final group in [search, info]) {
        for (final key in [
          'kind',
          'wordCount',
          if (identical(group, search)) 'intro',
        ]) {
          if (_present(group[key])) {
            _rule(group[key], key);
            warnings.add('$key 元数据不导入');
          }
        }
      }
    }

    final rawBase = _string(j['bookSourceUrl'], 'bookSourceUrl');
    final baseUri = Uri.tryParse(rawBase);
    final pseudoBase = baseUri == null ||
        !['http', 'https'].contains(baseUri.scheme) ||
        baseUri.host.isEmpty;
    final base = pseudoBase
        ? 'legado://${sha256.convert(utf8.encode(rawBase)).toString().substring(0, 16)}'
        : rawBase;
    if (pseudoBase) {
      warnings.add('书源 URL 非 HTTP(S)，已用内部 ID 代替：$rawBase');
    }
    _httpUrl(base, 'bookSourceUrl');
    var url = loose
        ? (j['searchUrl'] is String ? (j['searchUrl'] as String).trim() : '')
        : _string(j['searchUrl'], 'searchUrl');
    url = url
        .replaceAll('{{key}}', 'IMPORTKEY')
        .replaceAll('{{page}}', 'IMPORTPAGE');
    if (!loose &&
        RegExp(
          r'[{},<>]|@js:|javascript:',
          caseSensitive: false,
        ).hasMatch(url)) {
      throw const FormatException(
        'searchUrl 仅支持 GET URL 与 {{key}}/{{page}}，不支持脚本、POST 选项或其他模板',
      );
    }
    final resolved = Uri.tryParse(url);
    final scriptUrl = RegExp(r'^(@js:|<js>|\{\{)', caseSensitive: false)
        .hasMatch(url);
    final searchUrl = scriptUrl || pseudoBase
        ? url
        : resolved != null && ['http', 'https'].contains(resolved.scheme)
            ? url
            : Uri.parse(base)
                .resolve(url)
                .toString()
                .replaceAll('IMPORTKEY', '{{key}}')
                .replaceAll('IMPORTPAGE', '{{page}}');

    final headers = _headers(j['header'], loose: loose, warnings: warnings);
    String r(Map<String, dynamic> map, String key, {bool list = false}) =>
        loose
            ? _ruleLoose(map[key], key)
            : _rule(map[key], key, list: list);

    final discover = _discover(j, base: base, loose: loose, warnings: warnings);

    final json = <String, dynamic>{
      'sourceName': _string(j['bookSourceName'], 'bookSourceName'),
      'sourceUrl': base,
      'sourceType': _contentType(type),
      'bookSourceType': type,
      'enabled': j['enabled'] ?? true,
      'headers': headers,
      'implementation': implementation.name,
      'legadoJson': jsonEncode(j),
      'discover': discover,
      'search': {
        'url': searchUrl,
        'bookList': r(search, 'bookList', list: true),
        'name': r(search, 'name'),
        'author': r(search, 'author'),
        'cover': r(search, 'coverUrl'),
        'bookUrl': r(search, 'bookUrl'),
        'lastChapter': r(search, 'lastChapter'),
      },
      'detail': {
        'name': r(info, 'name'),
        'author': r(info, 'author'),
        'cover': r(info, 'coverUrl'),
        'intro': r(info, 'intro'),
        'tocUrl': r(info, 'tocUrl'),
        'lastChapter': r(info, 'lastChapter'),
      },
      'toc': {
        'chapterList': r(toc, 'chapterList', list: true),
        'chapterName': r(toc, 'chapterName'),
        'chapterUrl': r(toc, 'chapterUrl'),
        'nextTocUrl': r(toc, 'nextTocUrl'),
      },
      'content': {
        'content': r(content, 'content'),
        'nextContentUrl': r(content, 'nextContentUrl'),
      },
    };
    if (_present(j['jsLib'])) json['jsLib'] = j['jsLib'].toString();
    final jsCode = j['mainJs'] ?? j['js'];
    if (_present(jsCode)) json['jsCode'] = jsCode.toString();
    final webView = <String, dynamic>{
      for (final k in [
        'webView',
        'webViewJs',
        'ruleWebView',
        'sourceRegex',
        'loginUi',
        'loginUrl',
        'loginCheckJs',
        'coverDecodeJs',
      ])
        if (_present(j[k])) k: j[k],
    };
    if (webView.isNotEmpty) json['webViewRule'] = jsonEncode(webView);
    return json;
  }

  /// JavaScript 单文件书源。
  static SourceImportEntry _jsFile(String text) {
    try {
      if (text.isEmpty ||
          !RegExp(r'function\s+\w+|=>|\bvar\s+\w+|\blet\s+\w+',
                  caseSensitive: false)
              .hasMatch(text)) {
        throw const FormatException('不是可识别的 JSON 或 JavaScript 书源');
      }
      final hash = sha256.convert(utf8.encode(text)).toString().substring(0, 16);
      final url = _commentValue(text, 'bookSourceUrl') ??
          _commentValue(text, 'sourceUrl') ??
          RegExp(r'https?://[^\s<>]+').firstMatch(text)?.group(0) ??
          'js://$hash';
      final name = _commentValue(text, 'name') ??
          _commentValue(text, 'bookSourceName') ??
          'JS 书源 ${hash.substring(0, 6)}';
      final typeName = _commentValue(text, 'type') ?? 'novel';
      final type = switch (typeName) {
        'comic' || 'image' => ContentType.comic,
        'video' => ContentType.video,
        _ => ContentType.novel,
      };
      final search = <String, dynamic>{
        'url': '',
        'bookList': '',
        'name': '',
        'author': '',
        'cover': '',
        'bookUrl': '',
      };
      final detail = <String, dynamic>{};
      final toc = <String, dynamic>{
        'chapterList': '',
        'chapterName': '',
        'chapterUrl': '',
      };
      final content = <String, dynamic>{'content': ''};
      final json = <String, dynamic>{
        'sourceName': name,
        'sourceUrl': url,
        'sourceType': type.name,
        'enabled': true,
        'headers': <String, String>{},
        'implementation': SourceImplementation.jsFile.name,
        'jsCode': text,
        'legadoJson': jsonEncode({
          'bookSourceName': name,
          'bookSourceUrl': url,
          'bookSourceType': switch (type) {
            ContentType.comic => 2,
            ContentType.video => 4,
            _ => 0,
          },
        }),
        'search': search,
        'detail': detail,
        'toc': toc,
        'content': content,
      };
      _validate(json, legado: false);
      return SourceImportEntry(
        name,
        json: json,
        warnings: const ['JavaScript 单文件书源：脚本仅在运行时执行'],
      );
    } catch (e) {
      return SourceImportEntry(
        'JavaScript 书源',
        reason: e is FormatException ? e.message.toString() : '字段类型错误：$e',
      );
    }
  }

  static String? _commentValue(String text, String key) {
    final escaped = RegExp.escape(key);
    final patterns = [
      RegExp('^\\s*//\\s*@?$escaped\\s*[:：]\\s*(.+)\$', multiLine: true),
      RegExp('^\\s*//\\s*$escaped\\s*[:：]\\s*(.+)\$', multiLine: true),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final v = m.group(1)!.trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  static String _string(dynamic value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field 缺失或不是非空字符串');
    }
    return value.trim();
  }

  static void _httpUrl(String value, String field) {
    if (value.startsWith('js://') || value.startsWith('legado://')) return;
    final uri = Uri.tryParse(
      value.replaceAll('{{key}}', 'key').replaceAll('{{page}}', '1'),
    );
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw FormatException('$field 必须是无内嵌凭据的 HTTP(S) URL');
    }
  }

  static Map<String, String> _headers(
    dynamic value, {
    bool loose = false,
    List<String>? warnings,
  }) {
    if (value == null || value == '') return {};
    if (value is String && loose && _jsMarkers.hasMatch(value)) {
      warnings?.add('header 为动态脚本，已忽略；此类站点可能需要登录或验证码');
      return {};
    }
    if (value is String) value = jsonDecode(value);
    if (value is! Map) {
      throw const FormatException('header 必须是静态 JSON 对象');
    }
    final result = <String, String>{};
    for (final e in value.entries) {
      final key = e.key.toString();
      if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(key) || e.value is! String) {
        throw FormatException('header.$key 不是受支持的请求头');
      }
      final v = e.value as String;
      if (RegExp(r'[\r\n]').hasMatch(v) ||
          (!loose &&
              RegExp(
                r'\{\{|@js:|<js>|javascript:',
                caseSensitive: false,
              ).hasMatch(v))) {
        throw FormatException('header.$key 不是受支持的静态请求头');
      }
      result[key] = v;
    }
    return result;
  }

  /// 严格模式：仅保留当前 HTML/CSS 引擎能可靠执行的规则。
  static String _rule(dynamic value, String field, {bool list = false}) {
    if (value == null || value == '') return '';
    if (value is! String) throw FormatException('$field 必须是字符串');
    var rule = value.trim();
    final explicitCss = rule.toLowerCase().startsWith('@css:');
    if (explicitCss) rule = rule.substring(5).trim();
    if (rule.startsWith('css:')) rule = rule.substring(4).trim();
    if (RegExp(
      r'@js:|<\/?js>|javascript:|@xpath:|@json:|\$|//|\{\{|##|&&|\|\||%%|!|\^',
      caseSensitive: false,
    ).hasMatch(rule)) {
      throw FormatException(
        '$field 不兼容：仅支持基础 HTML/CSS，不支持 JS/XPath/JSONPath、正则或复合规则',
      );
    }
    final at = rule.lastIndexOf('@');
    var selector = at < 0 ? rule : rule.substring(0, at);
    var attr = at < 0 ? '' : rule.substring(at + 1);
    if (selector.contains('@')) throw FormatException('$field 不支持链式 @ 选择');
    if (!list &&
        at < 0 &&
        {'text', 'html', 'textNodes', 'href', 'src'}.contains(rule)) {
      selector = '';
      attr = rule;
    }
    if (!explicitCss) {
      final shorthand = RegExp(r'^(class|tag|id)\.([A-Za-z_][\w-]*)$')
          .firstMatch(selector);
      if (shorthand != null) {
        selector =
            '${{'class': '.', 'tag': '', 'id': '#'}[shorthand[1]]}${shorthand[2]}';
      } else if (RegExp(r'(^|[\s>+~])(class|tag|id)\.').hasMatch(selector)) {
        throw FormatException(
          '$field 简写仅支持单段 class.xxx/tag.xxx/id.xxx，不支持索引或链式规则',
        );
      }
    }
    if (selector.isNotEmpty &&
        !RegExp(r'''^[A-Za-z0-9_\-.*#\s>+~\[\]="'|]+$''').hasMatch(selector)) {
      throw FormatException('$field 选择器超出基础 CSS 支持范围');
    }
    if (selector.isEmpty && list) throw FormatException('$field 列表选择器不能为空');
    if (list && attr.isNotEmpty) throw FormatException('$field 列表不能带属性提取');
    if (attr.isNotEmpty && !RegExp(r'^[A-Za-z_][\w-]*$').hasMatch(attr)) {
      throw FormatException('$field 属性提取不兼容');
    }
    if (selector.isNotEmpty) {
      html.parse('<html></html>').querySelectorAll(selector);
    }
    return selector.isEmpty ? attr : '$selector${attr.isEmpty ? '' : '@$attr'}';
  }

  /// 宽松模式：保留原始规则字符串，由运行时解析器决定如何执行。
  static String _ruleLoose(dynamic value, String field) {
    if (value == null || value == '') return '';
    if (value is! String) throw FormatException('$field 必须是字符串');
    var rule = value.trim();
    if (rule.toLowerCase().startsWith('@css:')) {
      rule = rule.substring(5).trim();
    } else if (rule.startsWith('css:')) {
      rule = rule.substring(4).trim();
    }
    final shorthand = RegExp(r'^(class|tag|id)\.([A-Za-z_][\w-]*)$')
        .firstMatch(rule);
    if (shorthand != null) {
      return '${{'class': '.', 'tag': '', 'id': '#'}[shorthand[1]]}${shorthand[2]}';
    }
    return rule;
  }

  /// 把 Legado 的 exploreUrl / ruleExplore 转成发现页标签。
  ///
  /// Legado 的 exploreUrl 常见三种形态：
  /// - JSON 数组 `[{title, url, style}, ...]`，url 为空的项是分组标题；
  /// - JSON 对象 `{分组名: url}` 或 `{分组名: {url: ...}}`；
  /// - 单个 URL 字符串。
  /// 分组标题含「榜」时其下标签归到榜单，其余归到分类。
  static List<Map<String, dynamic>> _discover(
    Map<String, dynamic> j, {
    required String base,
    required bool loose,
    required List<String> warnings,
  }) {
    if (j['enabledExplore'] == false) return <Map<String, dynamic>>[];
    final rawExplore = j['exploreUrl'];
    if (!_present(rawExplore)) return <Map<String, dynamic>>[];
    final rawRule = j['ruleExplore'];
    if (rawRule != null && rawRule is! Map<String, dynamic>) {
      warnings.add('ruleExplore 不是规则对象，发现页未导入');
      return <Map<String, dynamic>>[];
    }
    final rule = (rawRule as Map<String, dynamic>?) ?? <String, dynamic>{};

    final tabs = <_ExploreTab>[];
    var group = '';
    var groupRank = false;

    void add(String title, dynamic value) {
      final name = title.trim();
      if (name.isEmpty) return;
      final url = value is String ? value.trim() : '';
      if (url.isEmpty) {
        group = name;
        groupRank = name.contains('榜');
        return;
      }
      tabs.add(
        _ExploreTab(
          title: name,
          url: url,
          isRank: groupRank || name.contains('榜'),
        ),
      );
    }

    void consume(dynamic value) {
      if (value is String) {
        final v = value.trim();
        if (v.isEmpty) return;
        if (v.startsWith('[') || v.startsWith('{')) {
          try {
            consume(jsonDecode(v));
            return;
          } catch (_) {
            // 不是 JSON，按普通 URL 处理
          }
        }
        if (RegExp(r'^(@js:|<js>)', caseSensitive: false).hasMatch(v) ||
            (v.startsWith('{{') &&
                !v.contains('{{page}}') &&
                !v.contains('{{key}}'))) {
          warnings.add('发现页 URL 含动态脚本，已跳过');
          return;
        }
        add(group.isEmpty ? '发现' : group, v);
        return;
      }
      if (value is List) {
        for (final e in value) {
          if (e is Map) {
            add(
              (e['title'] ?? e['name'] ?? '').toString(),
              e['url'] ?? e['exploreUrl'] ?? e['explore'] ?? '',
            );
          } else if (e is String) {
            add(e, '');
          }
        }
        return;
      }
      if (value is Map) {
        if (value.containsKey('url') || value.containsKey('exploreUrl')) {
          add(
            (value['title'] ?? value['name'] ?? group).toString(),
            value['url'] ?? value['exploreUrl'],
          );
          return;
        }
        for (final e in value.entries) {
          final v = e.value;
          if (v is Map) {
            add(
              (v['title'] ?? v['name'] ?? e.key).toString(),
              v['url'] ?? v['exploreUrl'] ?? v['explore'] ?? '',
            );
          } else {
            add(e.key.toString(), v);
          }
        }
      }
    }
    consume(rawExplore);
    if (tabs.isEmpty) return <Map<String, dynamic>>[];

    String cardRule(String key, {bool list = false}) {
      final v = rule[key];
      if (!_present(v)) return '';
      try {
        return loose
            ? _ruleLoose(v, 'ruleExplore.$key')
            : _rule(v, 'ruleExplore.$key', list: list);
      } catch (e) {
        warnings.add('ruleExplore.$key 未导入：$e');
        return '';
      }
    }

    final card = <String, dynamic>{
      'cardList': cardRule('bookList', list: true),
      'cardName': cardRule('name'),
      'cardAuthor': cardRule('author'),
      'cardCover': cardRule('coverUrl'),
      'cardBookUrl': cardRule('bookUrl'),
      'cardLastChapter': cardRule('lastChapter'),
    };
    final out = <Map<String, dynamic>>[];
    for (final tab in tabs) {
      var url = tab.url;
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url) &&
          !base.startsWith('legado://') &&
          !base.startsWith('js://')) {
        if (url.contains('{{')) {
          final placeholders = RegExp(r'\{\{(?:key|page)\}\}');
          if (!placeholders.hasMatch(url) ||
              url.replaceAll(placeholders, '').contains('{{')) {
            warnings.add('发现页「${tab.title}」URL 含脚本，已跳过');
            continue;
          }
        }
        url = Uri.parse(base)
            .resolve(
              url
                  .replaceAll('{{key}}', 'IMPORTKEY')
                  .replaceAll('{{page}}', 'IMPORTPAGE'),
            )
            .toString()
            .replaceAll('IMPORTKEY', '{{key}}')
            .replaceAll('IMPORTPAGE', '{{page}}');
      }
      out.add(<String, dynamic>{
        'key': url,
        'name': tab.title,
        'isRank': tab.isRank,
        'url': url,
        ...card,
      });
    }
    if (out.isEmpty) {
      warnings.add('发现页规则未能转换，发现页不可用');
    } else {
      warnings.add('已导入 ${out.length} 个发现页标签');
    }
    return out;
  }

  static void _validate(Map<String, dynamic> json, {required bool legado}) {
    _httpUrl(_string(json['sourceUrl'], 'sourceUrl'), 'sourceUrl');
    final type = json['sourceType'] ?? 'novel';
    if (!['novel', 'comic', 'video'].contains(type)) {
      throw const FormatException('仅支持小说、漫画和视频');
    }
    final implementation = SourceImplementation.values.firstWhere(
      (v) => v.name == (json['implementation'] ?? 'standard'),
      orElse: () => SourceImplementation.standard,
    );
    final source = BookSource.fromJson(json);
    if (implementation != SourceImplementation.jsFile) {
      final required = {
        'search.url': source.search.urlTemplate,
        'search.bookList': source.search.bookList,
        'search.name': source.search.name,
        'search.bookUrl': source.search.bookUrl,
        'toc.chapterList': source.toc?.chapterList,
        'toc.chapterName': source.toc?.chapterName,
        'toc.chapterUrl': source.toc?.chapterUrl,
      };
      if (type != 'video') required['content.content'] = source.content?.content;
      for (final e in required.entries) {
        if (implementation == SourceImplementation.standard) {
          _string(e.value, e.key);
        }
      }
      if (implementation == SourceImplementation.standard &&
          source.search.urlTemplate.isNotEmpty) {
        _httpUrl(source.search.urlTemplate, 'search.url');
      }
    }
    _headers(json['headers']);
    if (implementation == SourceImplementation.standard &&
        !['GET', 'POST'].contains(source.search.method)) {
      throw const FormatException('不支持的请求方法');
    }
    if (![
      'utf-8',
      'utf8',
      'gbk',
      'gb2312',
      'gb18030',
    ].contains(source.search.charset.toLowerCase())) {
      throw const FormatException('不支持的网页编码');
    }
    if (implementation == SourceImplementation.standard &&
        source.type == ContentType.comic &&
        !RegExp(r'@(?:src|data-src)$').hasMatch(source.content!.content)) {
      throw const FormatException('漫画正文仅支持 CSS 图片列表@src 或 @data-src');
    }
    if (!legado && implementation == SourceImplementation.standard) {
      for (final group in ['search', 'detail', 'toc', 'content']) {
        final map = json[group];
        if (map is! Map<String, dynamic>) continue;
        for (final e in map.entries) {
          if (e.value is! String ||
              ['url', 'method', 'charset', 'pageUrlTemplate'].contains(e.key)) {
            continue;
          }
          final rule = e.value as String;
          if (RegExp(
            r'@js:|<js>|javascript:|@xpath:|@json:|\$\.|\$\[|\{\{',
            caseSensitive: false,
          ).hasMatch(rule)) {
            throw FormatException('$group.${e.key} 含不兼容规则');
          }
          for (final alt in rule.split('||')) {
            RuleEngine.extractFromElement(html.parse('<div></div>').body!, alt);
          }
        }
      }
    }
  }
}

class _ExploreTab {
  final String title;
  final String url;
  final bool isRank;

  const _ExploreTab({
    required this.title,
    required this.url,
    required this.isRank,
  });
}
