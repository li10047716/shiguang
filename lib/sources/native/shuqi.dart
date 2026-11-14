/// 书旗小说（shuqi.com）App 接口客户端。
///
/// 移植自 shiguang `reader/shuqi.py`：
///   - 请求体 JSON 与 x-sq-public 头都用 2048 字节 keystream 做二进制 XOR 再 base64
///   - 签名是 md5(按键名升序拼 "k=v&" + skey)
///   - enc18 由 user_id 与毫秒时间戳派生
///   - POST 到 ocean.shuqireader.com/sqan/...
///
/// 书籍 id 用 `sq:<bid>` 编码进 [Book.bookUrl]，章节 url 用 `sq://<bid>/<cid>`。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../novel_source.dart';
import '../source.dart';

const String _skey = '467694bd8912441cae8498b3c7e4282c';
const String _sqsv = '1.0';
const String _uid = '8158804976';
const String _ciuid = '8000000';
const String _host = 'https://ocean.shuqireader.com';
const String _web = 'https://www.shuqi.com';
const String _ua = 'okhttp/3.12.13';
const String _prefix = 'sq:';
const String _scheme = 'sq://';

const String _pSearch = '/sqan/render/render/search/native_v3';
const String _pTitle = '/sqan/sqapi/bff/api/v1/reader/titlepage';
const String _pChinfo = '/sqan/sqapi/bff/api/v1/reader/chapterinfo';

const List<String> _cdnHosts = ['c1.shuqireader.com', 'c2.shuqireader.com'];
const List<String> _cdnFlags = ['3111111111', '2111111111'];

// 发现页：官方榜单（kind）与书库分类（fc，逗号表示多分类）
const List<DiscoverTab> _ranks = [
  DiscoverTab(key: 'boyClick', name: '男频点击榜', isRank: true),
  DiscoverTab(key: 'boyStore', name: '男频收藏榜', isRank: true),
  DiscoverTab(key: 'boyOrder', name: '男频订阅榜', isRank: true),
  DiscoverTab(key: 'boyhot', name: '男频人气榜', isRank: true),
  DiscoverTab(key: 'boyEnd', name: '男频完结榜', isRank: true),
  DiscoverTab(key: 'boyUpdate', name: '男频更新榜', isRank: true),
  DiscoverTab(key: 'girlClick', name: '女频点击榜', isRank: true),
  DiscoverTab(key: 'girlStore', name: '女频收藏榜', isRank: true),
  DiscoverTab(key: 'girlEnd', name: '女频完结榜', isRank: true),
  DiscoverTab(key: 'allEnd', name: '全站完结榜', isRank: true),
  DiscoverTab(key: 'allWords', name: '全站字数榜', isRank: true),
  DiscoverTab(key: 'allClick', name: '全站点击榜', isRank: true),
  DiscoverTab(key: 'allStore', name: '全站收藏榜', isRank: true),
  DiscoverTab(key: 'allOrder', name: '全站订阅榜', isRank: true),
];

const List<DiscoverTab> _storeCats = [
  DiscoverTab(key: '7', name: '都市', isRank: false),
  DiscoverTab(key: '29', name: '玄幻', isRank: false),
  DiscoverTab(key: '34,102', name: '科幻', isRank: false),
  DiscoverTab(key: '41,108', name: '悬疑', isRank: false),
  DiscoverTab(key: '45', name: '历史', isRank: false),
  DiscoverTab(key: '54', name: '体育', isRank: false),
  DiscoverTab(key: '58', name: '武侠', isRank: false),
  DiscoverTab(key: '63', name: '游戏', isRank: false),
  DiscoverTab(key: '67,98', name: '仙侠', isRank: false),
  DiscoverTab(key: '71', name: '同人', isRank: false),
  DiscoverTab(key: '76', name: '现代言情', isRank: false),
  DiscoverTab(key: '86', name: '古代言情', isRank: false),
  DiscoverTab(key: '94', name: '玄幻言情', isRank: false),
  DiscoverTab(key: '122', name: '幻想言情', isRank: false),
  DiscoverTab(key: '127', name: '浪漫青春', isRank: false),
  DiscoverTab(key: '', name: '全部书库', isRank: false),
];

// 2048 字节 keystream（base64），来自 shiguang reader/sq_keystream.b64。
const String _keystreamB64 =
    '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';

// 固定请求头字段表（顺序敏感，用于 JSON 序列化与 pub 串）
const List<List<String>> _pub = [
  ['soft_id', '1'], ['user_id', _uid], ['userId', _uid], ['ver', '261013'],
  ['subVer', 'sqrelease'], ['appVer', '12.7.0.268'], ['theme', 'day'],
  ['platform', 'an'], ['placeid', '1069'], ['sdk', '32'], ['cpu', 'x86_64'],
  ['pkg_cpu', 'arm64-v8a'], ['wh', '900x1600'], ['msv', '3'], ['vc', '5d73'],
  ['mod', 'BVL-AN16'], ['manufacturer', 'HONOR'], ['brand', 'HONOR'],
  ['net_type', 'wifi'], ['net_type_str', 'wifi'], ['first_placeid', 'src1069'],
  ['aak', 'a3a840'], ['utype', 'pre_vip'], ['net', '4'], ['net_env', '4'],
  ['permissionType', '0'], ['personalized', '1'], ['contentRecom', '1'],
  ['scene_code', ''], ['rom', '12'], ['sqUniqDeviceId', ''], ['utdid', ''],
  ['sn', ''], ['umidtoken', ''], ['otdd', ''],
];

const List<String> _order = [
  'soft_id', 'user_id', 'userId', 'ver', 'subVer', 'appVer', 'theme', 'platform',
  'placeid', 'sdk', 'cpu', 'pkg_cpu', 'wh', 'msv', 'enc', 'vc', 'mod',
  'manufacturer', 'brand', 'net_type', 'net_type_str', 'first_placeid', 'aak',
  'utype', 'net', 'net_env', 'permissionType', 'personalized', 'contentRecom',
  'scene_code', 'rom', 'sqUniqDeviceId', 'utdid', 'sn', 'umidtoken', 'otdd',
];

const Set<String> _noSign = {
  'sign', 'key', '_public', '_reqid', '_beta', '_', 'X',
  'XNEBULAXMLHTTPREQUEST', 'callbackUrl',
};

class ShuqiSource implements NovelSource {
  @override
  String get sourceId => 'sq';
  @override
  String get sourceName => '书旗小说';
  @override
  ContentType get type => ContentType.novel;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_web/'};

  late final List<int> _ks = base64Decode(_keystreamB64);

  // 每次会话生成一次设备指纹（与 Python 模块级 DEVICE 一致）
  late final Map<String, String> _device = {
    'sqUniqDeviceId': _rnd(22),
    'utdid': _rnd(28),
    'sn': _rnd(16, hexOnly: true),
    'umidtoken': _rnd(40, hexOnly: true),
    'otdd': _rnd(22),
  };

  DateTime _lastSearch = DateTime.fromMillisecondsSinceEpoch(0);

  final Random _rng = Random();

  String _rnd(int n, {bool hexOnly = false}) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const hex = '0123456789abcdef';
    final pool = hexOnly ? hex : chars;
    return List.generate(n, (_) => pool[_rng.nextInt(pool.length)]).join();
  }

  // ---------- 编码工具 ----------

  /// JS encodeURIComponent（保留 ! ' ( ) * - . _ ~）
  String _uri(String s) => _enc(s, extra: "!'()*-._~");

  /// 与 `_uri` 类似，但安全字符集不含 `*`（用于 _pub_str）
  String _pubEnc(String s) => _enc(s, extra: "!'()~-._");

  String _enc(String s, {required String extra}) {
    final sb = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      final isAlphaNum = (b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A);
      if (isAlphaNum || extra.contains(c)) {
        sb.write(c);
      } else {
        sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return sb.toString();
  }

  /// keystream XOR 前 min(len, 2048) 字节再 base64
  String _xorB64(List<int> raw) {
    final n = raw.length < _ks.length ? raw.length : _ks.length;
    final out = List<int>.generate(n, (i) => raw[i] ^ _ks[i]);
    return base64Encode(out);
  }

  String _enc18(String uid, int tsMs) {
    var ts = '$tsMs';
    while (ts.length < 13) {
      ts = '2$ts';
    }
    ts = ts.substring(0, 13);
    final n = int.tryParse(uid) ?? 24697;
    final k = int.tryParse(
            ts[1] + ts[3] + ts[5] + ts[8] + ts[6]) ??
        0;
    final p = k == 0 ? 12347 * n : k * n;
    return '$p'.substring('$p'.length - 5) + ts;
  }

  // ---------- 签名 ----------

  String _sign(List<MapEntry<String, String>> pairs) {
    final a = pairs
        .where((e) => !_noSign.contains(e.key))
        .map((e) => MapEntry(e.key, e.value))
        .toList();
    if (!a.any((e) => e.key == 'sqSv')) {
      a.add(MapEntry('sqSv', _sqsv));
    }
    a.sort((x, y) => x.key.compareTo(y.key));
    final raw = '${a.map((e) => '${e.key}=${_uri(e.value)}&').join()}skey=$_skey';
    return md5.convert(utf8.encode(raw)).toString();
  }

  String _pubStr(String uid, String enc) {
    final m = _pubMap();
    m['user_id'] = uid;
    m['userId'] = uid;
    m['platform'] = '2';
    m['enc'] = enc;
    final sb = StringBuffer();
    for (final k in _order) {
      if (m.containsKey(k)) sb.write('$k=${_pubEnc(m[k]!)}&');
    }
    return sb.toString();
  }

  Map<String, String> _pubMap() {
    final m = <String, String>{};
    for (final pair in _pub) {
      m[pair[0]] = pair[1];
    }
    m.addAll(_device);
    return m;
  }

  (String, String, Map<String, String>) _build(
    String path,
    List<List<String>> biz,
  ) {
    final tsMs = DateTime.now().millisecondsSinceEpoch;
    final ts = '$tsMs';
    final enc = _enc18(_uid, tsMs);
    final m = _pubMap();
    m['user_id'] = _uid;
    m['userId'] = _uid;
    m['platform'] = 'an';
    m['enc'] = enc;
    m['timestamp'] = ts;
    for (final pair in biz) {
      m[pair[0]] = pair[1];
    }
    m['isTeenMode'] = '0';
    m['sqSv'] = _sqsv;
    m['sign'] = _sign(m.entries.toList());
    m['key'] = 'sq_app_gateway';

    final plain = utf8.encode(jsonEncode(m));
    final body = 'data=${_uri(_xorB64(plain))}';
    final headers = <String, String>{
      'content-type': 'application/x-www-form-urlencoded',
      'user-agent': _ua,
      'x-sq-req-platform': 'an',
      'x-sq-s-key': '23011413',
      'x-sq-sv': '3.0',
      'x-sq-public': _xorB64(utf8.encode(_pubStr(_uid, enc))),
      'x-sq-req-encrypt': 'sdk',
      'x-sq-req-encrypt-param': 'x-sq-public',
      'x-sq-api-encrypt': '1',
    };
    return ('$_host$path', body, headers);
  }

  Future<Map<String, dynamic>> _api(
    String path,
    List<List<String>> biz, {
    String uid = _uid,
  }) async {
    final (url, body, headers) = _build(path, biz);
    final text = await HttpClient.getText(
      url,
      charset: 'utf-8',
      method: 'POST',
      body: body,
      headers: headers,
      maxBytes: 3 * 1024 * 1024,
      useCache: false,
    );
    final obj = jsonDecode(text);
    if (obj is! Map<String, dynamic>) {
      throw SourceException('书旗接口返回格式异常');
    }
    return obj;
  }

  Future<String> _h5Get(String url) => HttpClient.getText(
        url,
        charset: 'utf-8',
        headers: {'user-agent': _ua},
        maxBytes: 4 * 1024 * 1024,
        useCache: false,
      );

  // ---------- 文本工具 ----------

  String _plain(String? s) {
    var str = (s ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('　', ' ');
    return str.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ---------- 对外接口 ----------

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    // 搜索太频繁会触发风控，3 秒最小间隔
    final now = DateTime.now();
    final wait = const Duration(seconds: 3) - now.difference(_lastSearch);
    if (wait > Duration.zero) {
      await Future.delayed(wait);
    }
    _lastSearch = DateTime.now();

    final resp = await _api(_pSearch, [
      ['page', 'searchResultV3'],
      ['query', kw],
      ['timestamp', '${DateTime.now().millisecondsSinceEpoch}'],
    ]);
    final data = resp['data'];
    final modules = data is Map ? data['moduleInfos'] : null;
    if (modules is! List) return [];
    final books = <Book>[];
    final seen = <String>{};
    for (final mod in modules) {
      if (mod is! Map) continue;
      final b = mod['book'];
      if (b is! Map) continue;
      final bid = '${b['bookId'] ?? ''}';
      if (bid.isEmpty || !seen.add(bid)) continue;
      final author = _plain('${b['authorName'] ?? ''}');
      books.add(Book(
        name: _plain('${b['bookName'] ?? b['displayBookName'] ?? ''}'),
        author: author,
        cover: '${b['imgUrl'] ?? ''}',
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        lastChapter: '',
        intro: _plain('${b['desc'] ?? ''}'),
      ));
    }
    return books;
  }

  String _bookId(String bookUrl) {
    var v = bookUrl.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length).split('/')[0];
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    return v.trim();
  }

  /// H5 目录缺失时的兜底：openapi 卷数组。
  Future<List<Chapter>> _openToc(String bid) async {
    const key = '37e81a9d8f02596e1b895d07c171d5c9';
    final ts = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final sign = md5
        .convert(utf8.encode('$bid$ts$_ciuid$key'))
        .toString();
    final q = 'bookId=$bid&user_id=$_ciuid&timestamp=$ts&sign=$sign';
    final urls = [
      'https://content.shuqireader.com/openapi/book/chapterlist?shuqi_h5=205&platform=0&$q',
      'https://ocean.shuqireader.com/api/bcspub/qswebapi/book/chapterlist?_=&$q',
    ];
    String raw = '';
    for (final u in urls) {
      try {
        raw = await _h5Get(u);
        if (raw.isNotEmpty && raw.length > 200) break;
      } catch (_) {
        continue;
      }
    }
    dynamic d;
    try {
      d = jsonDecode(raw);
    } catch (_) {
      return [];
    }
    if (d is! Map) return [];
    if ('${d['state'] ?? ''}' != '200' && '${d['status'] ?? ''}' != '200') {
      return [];
    }
    final data = d['data'];
    final chapterList = data is Map ? data['chapterList'] : null;
    final out = <Chapter>[];
    if (chapterList is List) {
      for (final vol in chapterList) {
        if (vol is! Map) continue;
        final rows = <dynamic>[];
        for (final k in ['volumeList', 'chapterList', 'chapter']) {
          final v = vol[k];
          if (v is List) rows.addAll(v);
        }
        for (final c in rows) {
          if (c is! Map) continue;
          final cid = '${c['chapterId'] ?? c['cid'] ?? ''}';
          if (cid.isEmpty) continue;
          final name = _plain(
              '${c['chapterName'] ?? c['name'] ?? c['title'] ?? ''}');
          out.add(Chapter(
            title: name.isEmpty ? '第${out.length + 1}章' : name,
            url: '$_scheme$bid/$cid',
          ));
        }
      }
    }
    return out;
  }

  Future<List<Chapter>> _chapters(String bid) async {
    String html = '';
    try {
      html = await _h5Get('$_web/chapter?bid=$bid');
    } catch (_) {
      html = '';
    }
    if (html.length > 5000 && html.contains('cid=')) {
      final rows = <Chapter>[];
      final seen = <String>{};
      final re = RegExp(
        r'href="/reader\?bid=\d+&(?:amp;)?cid=(\d+)"[^>]*>([\s\S]*?)</a>',
      );
      for (final m in re.allMatches(html)) {
        final cid = m.group(1)!;
        if (!seen.add(cid)) continue;
        var inner = m.group(2)!.replaceAll(RegExp(r'<i[^>]*>[\s\S]*?</i>'), ' ');
        var name = _plain(inner);
        name = name.replaceFirst(RegExp(r'^\d+[.、]\s*'), '');
        if (name.isEmpty) continue;
        rows.add(Chapter(title: name, url: '$_scheme$bid/$cid'));
      }
      if (rows.isNotEmpty) return rows;
    }
    return _openToc(bid);
  }

  @override
  Future<Book> detail(Book book) async {
    final bid = _bookId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少书旗书籍 id');
    final chs = await _chapters(bid);
    if (chs.isEmpty) throw SourceException('书旗：这本暂时取不到目录');

    var name = book.name;
    var author = book.author;
    var intro = book.intro ?? '';
    var cover = book.cover;
    try {
      final r = await _api(_pTitle, [
        ['bookId', bid],
      ]);
      final data = r['data'];
      final b = data is Map ? data['bookInfo'] : null;
      if (b is Map && '${b['bookName'] ?? ''}'.isNotEmpty) {
        name = _plain('${b['bookName'] ?? ''}');
        author = _plain('${b['authorName'] ?? ''}');
        intro = _plain('${b['briefIntro'] ?? ''}');
        cover = '${b['coverUrl'] ?? ''}';
      }
    } catch (_) {}

    return Book(
      name: name,
      author: author,
      cover: cover,
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.novel,
      lastChapter: chs.isEmpty ? '' : chs.last.title,
      intro: intro,
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final bid = _bookId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少书旗书籍 id');
    final chs = await _chapters(bid);
    onPageChunk?.call(1, chs);
    onProgress?.call(1, chs.length);
    if (chs.isEmpty) throw SourceException('书旗目录为空，规则可能已失效');
    return TocResult(chapters: chs);
  }

  String _rot13(String s) {
    final sb = StringBuffer();
    for (final ch in s.split('')) {
      final o = ch.codeUnitAt(0);
      if (o >= 65 && o <= 90) {
        sb.writeCharCode((o - 65 + 13) % 26 + 65);
      } else if (o >= 97 && o <= 122) {
        sb.writeCharCode((o - 97 + 13) % 26 + 97);
      } else {
        sb.write(ch);
      }
    }
    return sb.toString();
  }

  String _ciDecode(String? s) {
    var raw = _rot13(s ?? '').replaceAll(RegExp(r'\s+'), '');
    try {
      final txt = utf8.decode(base64Decode(raw + '=' * (-raw.length % 4)),
          allowMalformed: true);
      return txt.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    } catch (_) {
      return '';
    }
  }

  /// 解析 CDN JSONP 响应
  String _cdnParse(String body) {
    final i = body.indexOf('(');
    final j = body.lastIndexOf(')');
    final inner = (i > 0 && i < j) ? body.substring(i + 1, j) : body;
    dynamic arr;
    try {
      arr = jsonDecode(inner);
    } catch (_) {
      return '';
    }
    String c = '';
    if (arr is List && arr.isNotEmpty) {
      final first = arr.first;
      if (first is Map) c = '${first['content'] ?? ''}';
    }
    if (c.isEmpty) return '';
    c = c.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    c = c.replaceAll(RegExp(r'<[^>]+>'), '');
    return c.replaceAll('&nbsp;', ' ').replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>').replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'").replaceAll('&amp;', '&');
  }

  // ---------- 发现：榜单 / 书库 ----------

  @override
  List<DiscoverTab> get discoverTabs => [..._ranks, ..._storeCats];

  /// 书旗页面里的最大页码（用于夹取范围外的页码）
  int _maxPage(String html, RegExp re) {
    var max = 1;
    for (final m in re.allMatches(html)) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  /// 榜单行 `<li class="clearfix">` → Book
  List<Book> _rankRows(String html) {
    final out = <Book>[];
    final liRe = RegExp(r'<li class="clearfix">([\s\S]*?)</li>');
    for (final m in liRe.allMatches(html)) {
      final li = m.group(1)!;
      final mb = RegExp(r'/book/(\d+)\.html').firstMatch(li);
      if (mb == null) continue;
      final bid = mb.group(1)!;
      final title = _plain(
          RegExp(r'<h3>([\s\S]*?)</h3>').firstMatch(li)?.group(1) ?? '');
      if (title.isEmpty) continue;
      final cover =
          RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(li)?.group(1) ?? '';
      final author = _plain(RegExp(
              r'class="bkuser-icon"[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)</a>')
          .firstMatch(li)?.group(1) ?? '');
      final cate = _plain(RegExp(r'class="bkcate-icon">([\s\S]*?)</span>')
          .firstMatch(li)?.group(1) ?? '');
      final intro = _plain(RegExp(r'class="ranklist-des">([\s\S]*?)</p>')
          .firstMatch(li)?.group(1) ?? '');
      final tags = _plain(RegExp(r'class="ranklist-tag">([\s\S]*?)</p>')
          .firstMatch(li)?.group(1) ?? '');
      final category =
          [cate, tags].where((s) => s.isNotEmpty).join(' · ');
      out.add(Book(
        name: title,
        author: author,
        cover: cover,
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        intro: [category, intro].where((s) => s.isNotEmpty).join(' · '),
        lastChapter: '',
      ));
    }
    return out;
  }

  /// 书库行 `<li>` 内含 `store-tag` → Book
  List<Book> _storeRows(String html) {
    final out = <Book>[];
    final seen = <String>{};
    final liRe = RegExp(r'<li>([\s\S]*?)</li>');
    for (final m in liRe.allMatches(html)) {
      final li = m.group(1)!;
      if (!li.contains('store-tag')) continue;
      final mb = RegExp(r'/book/(\d+)\.html').firstMatch(li);
      if (mb == null) continue;
      final bid = mb.group(1)!;
      if (!seen.add(bid)) continue;
      final title = _plain(
          RegExp(r'<h3[^>]*>([\s\S]*?)</h3>').firstMatch(li)?.group(1) ?? '');
      if (title.isEmpty) continue;
      final cover = (RegExp(r'<img[^>]*class="cover"[^>]*src="([^"]+)"')
              .firstMatch(li) ??
          RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(li))?.group(1) ??
          '';
      var author = _plain(RegExp(
              r'class="store-tag[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)</a>')
          .firstMatch(li)?.group(1) ?? '');
      author = author.replaceFirst(RegExp(r'^作者[：:]\s*'), '');
      final cate = _plain(RegExp(
              r'class="store-tag[^>]*>[\s\S]*?<span>([\s\S]*?)</span>')
          .firstMatch(li)?.group(1) ?? '');
      final intro = _plain(RegExp(r'class="store-des">([\s\S]*?)</p>')
          .firstMatch(li)?.group(1) ?? '');
      out.add(Book(
        name: title,
        author: author,
        cover: cover,
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        intro: [cate, intro].where((s) => s.isNotEmpty).join(' · '),
        lastChapter: '',
      ));
    }
    return out;
  }

  Future<DiscoverResult> _rank(String kind, int page) async {
    if (page < 1) page = 1;
    final html = await _h5Get('$_web/ranklist?rank=$kind&page=$page');
    if (html.length < 2000) {
      throw SourceException('书旗榜单页没有返回内容');
    }
    final total = _maxPage(
        html, RegExp(r'rank=[A-Za-z]+(?:&amp;|&)page=(\d+)'));
    final books = _rankRows(html);
    if (page > total) {
      // 页码超界：取最后一页
      final last = await _rank(kind, total);
      return DiscoverResult(
        title: last.title,
        books: last.books,
        page: total,
        pages: total,
      );
    }
    return DiscoverResult(
      title: kind,
      books: books,
      page: page,
      pages: total,
    );
  }

  Future<DiscoverResult> _store(String fc, int page) async {
    if (page < 1) page = 1;
    final q = <String>[];
    if (fc.isNotEmpty) q.add('fc=${_uri(fc)}');
    q.add('page=$page');
    final html = await _h5Get('$_web/store?${q.join('&')}');
    if (html.length < 2000) {
      throw SourceException('书旗书库页没有返回内容');
    }
    final total = _maxPage(html, RegExp(r'page=(\d+)'));
    final books = _storeRows(html);
    if (page > total) {
      final last = await _store(fc, total);
      return DiscoverResult(
        title: last.title,
        books: last.books,
        page: total,
        pages: total,
      );
    }
    var title = '书库';
    for (final tab in _storeCats) {
      if (tab.key == fc) title = tab.name;
    }
    return DiscoverResult(
      title: title,
      books: books,
      page: page,
      pages: total,
    );
  }

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) {
    if (isRank) return _rank(key, page);
    return _store(key, page);
  }

  @override
  Future<Content> content(Chapter chapter) async {
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) v = v.substring(_scheme.length);
    final parts = v.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) {
      throw SourceException('书旗章节地址不对：${chapter.url}');
    }
    final bid = parts[0];
    final cid = parts[1];

    var text = '';
    outer:
    for (final scheme in ['https', 'http']) {
      for (final host in _cdnHosts) {
        for (final flag in _cdnFlags) {
          final u = '$scheme://$host/httpserver/filecache/get_book_content_${bid}_${cid}_${flag}_0_0.html';
          try {
            text = _cdnParse(await _h5Get(u));
          } catch (_) {
            text = '';
          }
          if (text.length > 30) break outer;
        }
      }
    }

    if (text.length <= 30) {
      try {
        final r = await _api(_pChinfo, [
          ['bookId', bid],
          ['chapterId', cid],
        ], uid: _ciuid);
        final data = r['data'];
        final c = data is Map ? data['chapter'] : null;
        final enc = c is Map ? '${c['content'] ?? ''}' : '';
        text = _ciDecode(enc);
      } catch (_) {
        text = '';
      }
    }

    if (text.length <= 30) {
      throw SourceException('书旗：本章正文不可用（$cid），可能需要登录或为付费章');
    }

    final paras = text
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((p) => p.trim().replaceAll('　', ' ').trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (paras.isEmpty) throw SourceException('书旗正文为空');

    return Content(
      title: chapter.title,
      paras: paras,
      kind: ContentType.novel,
    );
  }
}
