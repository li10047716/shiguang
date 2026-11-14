/// 规则解析引擎
///
/// 规则语法：
///   `css: <selector>@<attr>`   取属性（src/href 等）
///   `css: <selector>@text`     取元素内纯文本
///   `css: <selector>@textNodes`取所有文本节点拼接
///   `css: <selector>@html`     取 innerHTML，<br> 转换行（正文常用）
///   无 `css:` 前缀时按 CSS 选择器处理
///
/// 高级语法：
///   `A || B`           回退链：A 取不到值时用 B（应对列表页/详情页结构不同）
///   `##正则##替换`     正则后处理；只写 `##正则##` 表示删除匹配部分
///   `:contains(文字)`  伪类：按元素文本过滤
///   `:not([attr^='x'])`按属性前缀排除
///   `@//href/`         兼容写法，等价于 `@href`
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

class RuleEngine {
  /// 从 HTML 字符串按规则提取单个值
  static String extract(String html, String rule) {
    if (rule.trim().isEmpty) return '';
    final doc = html_parser.parse(html);
    return _extractFrom(doc, rule);
  }

  /// 按列表规则取出元素集合（支持 `||` 回退：前一个匹配为空时用后一个）
  static List<Element> elements(Document doc, String listRule) {
    for (final alt in _splitAlternatives(listRule)) {
      final els = _queryAll(doc, _splitRule(alt).$1);
      if (els.isNotEmpty) return els;
    }
    return const [];
  }

  /// 在单条列表项元素上应用子规则（支持 `||` 与 `##正则##`）
  static String extractFromElement(Element el, String rule) {
    if (rule.trim().isEmpty) return '';
    for (final alt in _splitAlternatives(rule)) {
      final v = _extractFrom(el, alt);
      if (v.trim().isNotEmpty) return v;
    }
    return '';
  }

  // ---------- 核心 ----------

  static String _extractFrom(dynamic scope, String rule) {
    final core = rule.trim();
    if (core.isEmpty) return '';
    final (selector, attr) = _splitRule(core);

    Element? target;
    if (selector.isEmpty) {
      target = scope is Element ? scope : null;
    } else {
      target = _queryAll(scope, selector).firstOrNull;
    }
    final raw = target == null ? '' : _attrValue(target, attr);
    return _applyRegex(raw, core);
  }

  /// 拆分 `selector@attr`（先去掉 `##正则##` 部分）
  static (String, String) _splitRule(String rule) {
    var r = rule.trim();
    final hash = r.indexOf('##');
    if (hash != -1) r = r.substring(0, hash).trim();
    if (r.startsWith('css:')) r = r.substring(4).trim();
    if (r.startsWith('@')) return ('', _normalizeAttr(r.substring(1)));
    // 纯属性写法：text / html / href / src
    if (const {'text', 'html', 'textNodes', 'href', 'src', 'all'}.contains(r)) {
      return ('', r);
    }
    final at = r.lastIndexOf('@');
    if (at == -1) return (r, 'text');
    return (r.substring(0, at).trim(), _normalizeAttr(r.substring(at + 1)));
  }

  /// `//href/` → `href`，`//html/` → `html`
  static String _normalizeAttr(String attr) {
    var a = attr.trim();
    if (a.startsWith('//') && a.endsWith('/')) a = a.substring(2, a.length - 1);
    return a.isEmpty ? 'text' : a;
  }

  static String _attrValue(Element el, String attr) {
    switch (attr) {
      case 'text':
        return el.text.trim();
      case 'textNodes':
        return el.nodes
            .whereType<Text>()
            .map((n) => n.text.trim())
            .where((s) => s.isNotEmpty)
            .join('\n');
      case 'html':
        return _htmlToText(el.innerHtml);
      case 'all':
        return el.outerHtml;
      default:
        return el.attributes[attr] ?? el.attributes['data-$attr'] ?? '';
    }
  }

  /// innerHTML → 纯文本，<br> 与 </p> 转成换行
  static String _htmlToText(String html) {
    var s = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    s = _unescapeEntities(s);
    return s
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join('\n');
  }

  static String _unescapeEntities(String s) => s
      .replaceAll('&emsp;', ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  // ---------- 选择器查询（支持 :contains / :not） ----------

  static List<Element> _queryAll(dynamic scope, String selector) {
    var sel = selector.trim();
    final filters = <bool Function(Element)>[];

    // :eq(n) —— 查询结果中第 n 个（0-based，jQuery 风格）。
    // csslib 的 :nth-child 会把文本节点计入位置（表格换行缩进会偏移），
    // :nth-of-type 又未实现，所以表格列定位统一用 :eq。
    int? eqIndex;
    final eqRe = RegExp(r':eq\((\d+)\)');
    final eqM = eqRe.firstMatch(sel);
    if (eqM != null) {
      eqIndex = int.parse(eqM.group(1)!);
      sel = sel.replaceAll(eqRe, '').trim();
    }

    // :contains(文字)
    final containsRe = RegExp(r':contains\(([^)]*)\)');
    for (final m in containsRe.allMatches(sel)) {
      final kw = m.group(1)!;
      filters.add((e) => e.text.contains(kw));
    }
    sel = sel.replaceAll(containsRe, '');

    // :not([attr^='value'])
    final notRe = RegExp(r""":not\(\[([\w-]+)\^=['"]([^'"]*)['"]\]\)""");
    for (final m in notRe.allMatches(sel)) {
      final attr = m.group(1)!;
      final val = m.group(2)!;
      filters.add((e) => !(e.attributes[attr] ?? '').startsWith(val));
    }
    sel = sel.replaceAll(notRe, '').trim();

    List<Element> found;
    if (sel.isEmpty) {
      found = scope is Element ? [scope] : const [];
    } else {
      // Document 与 Element 都有 querySelectorAll
      found = scope.querySelectorAll(sel).cast<Element>();
    }

    if (eqIndex != null) {
      found = found.length > eqIndex ? [found[eqIndex]] : const [];
    }
    if (filters.isEmpty) return found;
    return found.where((e) => filters.every((f) => f(e))).toList();
  }

  // ---------- 正则后处理 ----------

  static String _applyRegex(String value, String rule) {
    final parts = rule.split('##');
    if (parts.length < 2) return value.trim();
    final pattern = parts[1];
    if (pattern.isEmpty) return value.trim();
    final replacement = parts.length > 2 ? parts[2] : '';
    try {
      return value.replaceAll(RegExp(pattern), replacement).trim();
    } catch (_) {
      return value.trim();
    }
  }

  /// 顶层按 `||` 拆分
  static List<String> _splitAlternatives(String rule) => rule
      .split('||')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  /// 相对链接 → 绝对链接
  static String absoluteUrl(String base, String url) {
    final u = url.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('//')) return 'https:$u';
    final root = RegExp(r'^(https?://[^/]+)').firstMatch(base)?[1] ?? base;
    if (u.startsWith('/')) return '$root$u';
    if (base.endsWith('/')) return '$base$u';
    final dir = base.substring(0, base.lastIndexOf('/') + 1);
    return '$dir$u';
  }
}
