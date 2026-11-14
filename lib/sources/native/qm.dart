/// 七猫（wtzw.com）书源——App 接口 + AES-128-CBC 正文解密。
///
/// 移植自 shiguang `reader/qm.py`：
///   - 请求头与查询参数都要 md5(按 key 排序拼 "k=v" + sign_key)
///   - 正文是 Base64(IV[16] + AES-128-CBC(PKCS7))，key 固定
///
/// 书籍 id 用 `qm:<bid>` 编码进 [Book.bookUrl]，章节 url 用 `qm://<bid>/<cid>`。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/content.dart';
import '../../models/discover.dart';
import '../../services/http_client.dart';
import '../../utils/aes.dart';
import '../novel_source.dart';
import '../source.dart';

const String _api = 'https://api-bc.wtzw.com';
const String _apiKs = 'https://api-ks.wtzw.com';
const String _signKey = 'd3dGiJc651gSQ8w1';
const List<int> _aesKey = [
  0x32, 0x34, 0x32, 0x63, 0x63, 0x62, 0x38, 0x32, // "242ccb82"
  0x33, 0x30, 0x64, 0x37, 0x30, 0x39, 0x65, 0x31, // "30d709e1"
];
const String _ua = 'okhttp/4.9.0';
const String _prefix = 'qm:';
const String _scheme = 'qm://';

const Map<String, String> _baseHeaders = {
  'app-version': '77800',
  'platform': 'android',
  'reg': '0',
  'AUTHORIZATION': '',
  'application-id': 'com.****.reader',
  'net-env': '1',
  'channel': 'unknown',
  'qm-params': '',
};

class QmSource extends SourceBase {
  @override
  String get sourceId => 'qm';
  @override
  String get sourceName => '七猫';
  @override
  ContentType get type => ContentType.novel;

  @override
  Map<String, String>? get imageHeaders => {'Referer': '$_web/'};

  /// md5(按 key 排序拼 "k=v" + sign_key)
  String _sign(Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    final raw = keys.map((k) => '$k=${params[k]}').join() + _signKey;
    return md5.convert(utf8.encode(raw)).toString();
  }

  /// 构建签名 URL（query 里带上 sign）。
  String _buildUrl(String base, String path, Map<String, String> params) {
    final p = <String, String>{...params};
    p['sign'] = _sign(p);
    final uri = Uri.parse(base + path).replace(queryParameters: p);
    return uri.toString();
  }

  /// App 接口 GET，返回解析后的 JSON。
  Future<Map<String, dynamic>> _get(
    String base,
    String path,
    Map<String, String> params,
  ) async {
    final url = _buildUrl(base, path, params);
    final headers = <String, String>{
      ..._baseHeaders,
      'sign': _sign(_baseHeaders),
      'User-Agent': _ua,
      'Accept': 'application/json',
    };
    final text = await HttpClient.getText(
      url,
      charset: 'utf-8',
      headers: headers,
      maxBytes: 3 * 1024 * 1024,
      useCache: false, // 签名含时间敏感参数，避免缓存串味
    );
    final obj = jsonDecode(text);
    if (obj is! Map<String, dynamic>) {
      throw SourceException('七猫接口返回格式异常');
    }
    return obj;
  }

  Map<String, dynamic>? _data(Map<String, dynamic> resp, List<String> path) {
    dynamic cur = resp;
    for (final k in path) {
      if (cur is! Map) return null;
      cur = cur[k];
    }
    return cur is Map<String, dynamic> ? cur : null;
  }

  /// 沿 [path] 取 List（如 `data.chapter_lists`）。
  List<dynamic>? _dataList(Map<String, dynamic> resp, List<String> path) {
    dynamic cur = resp;
    for (final k in path) {
      if (cur is! Map) return null;
      cur = cur[k];
    }
    return cur is List ? cur : null;
  }

  String _plain(String? s) =>
      s == null ? '' : s.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll('　', ' ').trim();

  /// 从 bookUrl 里取七猫书籍 id（`qm:<bid>` / `qm://<bid>`）。
  String _bookId(String bookUrl) {
    var v = bookUrl.trim();
    if (v.startsWith(_scheme)) {
      v = v.substring(_scheme.length).split('/')[0];
    } else if (v.startsWith(_prefix)) {
      v = v.substring(_prefix.length);
    }
    return v.trim();
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    final resp = await _get(_api, '/api/v5/search/words', {
      'gender': '3',
      'imei_ip': '2937357107',
      'page': '$page',
      'wd': kw,
    });
    final data = _data(resp, ['data']) ?? {};
    final list = data['books'];
    if (list is! List) return [];
    final books = <Book>[];
    for (final item in list) {
      if (item is! Map) continue;
      final bid = (item['id'] ?? '').toString();
      if (bid.isEmpty) continue;
      books.add(Book(
        name: _plain((item['original_title'] ?? item['title']).toString()),
        author: _plain((item['original_author'] ?? item['author']).toString()),
        cover: item['image_link']?.toString() ?? '',
        bookUrl: '$_prefix$bid',
        sourceId: sourceId,
        sourceName: sourceName,
        type: ContentType.novel,
        lastChapter: '',
        intro: _plain(item['intro']?.toString()),
      ));
    }
    return books;
  }

  @override
  Future<Book> detail(Book book) async {
    final bid = _bookId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少七猫书籍 id');
    final resp = await _get(_api, '/api/v4/book/detail', {
      'id': bid,
      'imei_ip': '2937357107',
      'teeny_mode': '0',
    });
    final b = _data(resp, ['data', 'book']) ?? {};
    final title = b['title']?.toString() ?? '';
    if (title.isEmpty) throw SourceException('七猫没有返回这本书的信息');

    return Book(
      name: title,
      author: b['author']?.toString() ?? '',
      cover: b['image_link']?.toString() ?? '',
      bookUrl: book.bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
      type: ContentType.novel,
      lastChapter: b['latest_chapter_title']?.toString() ?? '',
      intro: _plain(b['intro']?.toString()),
    );
  }

  @override
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  }) async {
    final bid = _bookId(book.bookUrl);
    if (bid.isEmpty) throw SourceException('缺少七猫书籍 id');
    final resp = await _get(_apiKs, '/api/v1/chapter/chapter-list', {
      'id': bid,
    });
    final list = _dataList(resp, ['data', 'chapter_lists']);
    final chapters = <Chapter>[];
    if (list != null) {
      for (final item in list) {
        if (item is! Map) continue;
        final cid = (item['id'] ?? '').toString();
        if (cid.isEmpty) continue;
        chapters.add(Chapter(
          title: (item['title'] ?? '').toString().trim(),
          url: '$_scheme$bid/$cid',
        ));
      }
    }
    onPageChunk?.call(1, chapters);
    onProgress?.call(1, chapters.length);
    if (chapters.isEmpty) {
      throw SourceException('七猫目录为空，规则可能已失效');
    }
    return TocResult(chapters: chapters);
  }

  @override
  Future<Content> content(Chapter chapter) async {
    var v = chapter.url.trim();
    if (v.startsWith(_scheme)) v = v.substring(_scheme.length);
    final parts = v.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) throw SourceException('七猫章节地址不对：${chapter.url}');
    final bid = parts[0];
    final cid = parts[1];

    final resp = await _get(_apiKs, '/api/v1/chapter/content', {
      'id': bid,
      'chapterId': cid,
    });
    final data = _data(resp, ['data']) ?? {};
    final blob = data['content']?.toString() ?? '';
    if (blob.isEmpty) {
      final msg = resp['msg']?.toString() ?? '这一章没有取到内容（可能需要会员）';
      throw SourceException(msg);
    }

    final raw = base64Decode(blob);
    if (raw.length < 32) throw SourceException('七猫正文解密失败（数据过短）');
    final iv = raw.sublist(0, 16);
    final cipher = raw.sublist(16);
    final plain = aesCbcDecryptPadded(_aesKey, iv, cipher);
    final text = utf8.decode(plain, allowMalformed: true);
    final paras = text
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (paras.isEmpty) throw SourceException('七猫正文为空');

    return Content(
      title: chapter.title,
      paras: paras,
      kind: ContentType.novel,
    );
  }

  // ---------- 发现：网页排行榜（免签名） ----------

  static const String _web = 'https://www.qimao.com';
  static const String _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const List<DiscoverTab> _ranks = [
    DiscoverTab(key: 'hot', name: '大热榜', isRank: true),
    DiscoverTab(key: 'new', name: '新书榜', isRank: true),
    DiscoverTab(key: 'over', name: '完结榜', isRank: true),
    DiscoverTab(key: 'collect', name: '收藏榜', isRank: true),
    DiscoverTab(key: 'update', name: '更新榜', isRank: true),
  ];

  @override
  List<DiscoverTab> get discoverTabs => _ranks;

  /// 七猫网页版接口（www.qimao.com/api/...），不需要 App 签名。
  Future<Map<String, dynamic>> _webGet(
    String path,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse('$_web$path').replace(queryParameters: params);
    final text = await HttpClient.getText(
      uri.toString(),
      charset: 'utf-8',
      headers: {
        'User-Agent': _webUa,
        'Referer': '$_web/paihang/',
        'Accept': 'application/json, text/plain, */*',
      },
      maxBytes: 3 * 1024 * 1024,
      useCache: false,
    );
    final obj = jsonDecode(text);
    if (obj is! Map<String, dynamic>) {
      throw SourceException('七猫榜单接口返回格式异常');
    }
    return obj;
  }

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    const table = {
      'hot': ('1', '大热榜'),
      'new': ('2', '新书榜'),
      'over': ('3', '完结榜'),
      'collect': ('4', '收藏榜'),
      'update': ('6', '更新榜'),
    };
    if (!table.containsKey(key)) key = 'hot';
    final (rt, name) = table[key]!;
    if (page < 1) page = 1;
    final resp = await _webGet('/api/rank/book-list', {
      'is_girl': '0',
      'rank_type': rt,
      'date_type': '1',
      'page': '$page',
    });
    final data = resp['data'];
    final rows = data is Map ? data['table_data'] : null;
    final meta = data is Map ? data['page_data'] : null;
    final total = int.tryParse('${meta is Map ? meta['count'] ?? 0 : 0}') ?? 0;
    final size = int.tryParse(
            '${meta is Map ? meta['page_size'] ?? 20 : 20}') ??
        20;
    var pages = total > 0 ? ((total + size - 1) ~/ size) : 1;
    pages = pages.clamp(1, 500);
    if (page > pages) {
      return discover(key, isRank: true, page: pages);
    }
    final books = <Book>[];
    if (rows is List) {
      for (final b in rows) {
        if (b is! Map) continue;
        final bid = '${b['book_id'] ?? ''}';
        if (bid.isEmpty) continue;
        final cat = [
          '${b['category1_name'] ?? ''}',
          '${b['category2_name'] ?? ''}',
        ].where((s) => s.isNotEmpty).join(' · ');
        final intro = _plain('${b['intro'] ?? ''}');
        books.add(Book(
          name: _plain('${b['title'] ?? ''}'),
          author: _plain('${b['author'] ?? ''}'),
          cover: '${b['image_link'] ?? ''}',
          bookUrl: '$_prefix$bid',
          sourceId: sourceId,
          sourceName: sourceName,
          type: ContentType.novel,
          lastChapter: '${b['latest_chapter_title'] ?? ''}',
          intro: [cat, intro].where((s) => s.isNotEmpty).join(' · '),
        ));
      }
    }
    return DiscoverResult(
      title: name,
      books: books,
      page: page,
      pages: pages,
    );
  }
}
