import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart' as dio_io;
import 'package:fast_gbk/fast_gbk.dart';

/// 全局 HTTP 客户端（dio 封装）
///
/// 针对「站点限流 / 大页面迟迟不返回」做了三层保护：
/// 1. **响应缓存**：同一 URL 60 秒内只请求一次。详情页刚抓过目录页，
///    点「查看目录」时直接用缓存，不再发第二次请求（这是被判限流的主因）。
/// 2. **流式接收**：边收边解析，空闲超过 [idleTimeout] 就用已收内容，
///    避免站点「连接建立了但不吐数据」导致整体 receiveTimeout。
/// 3. **失败重试**：网络抖动 / 空响应时退避重试。
class HttpClient {
  static final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 60),
    responseType: ResponseType.bytes,
    followRedirects: true,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,'
              'image/webp,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Site': 'same-origin',
      'Upgrade-Insecure-Requests': '1',
      // 部分图片 CDN（如大人漫画 18rouman.vip）对 gzip 请求会慢速/挂起，
      // 强制 identity：curl 1.1s 完整返回 vs gzip 下 30s+ 截断。
      'Accept-Encoding': 'identity',
    },
  ));

  // 底层 HttpClient 关闭自动解压（配合 identity，避免 CDN 对 gzip 异常响应）
  static final dio_io.IOHttpClientAdapter _ioAdapter =
      dio_io.IOHttpClientAdapter(
    createHttpClient: () => io.HttpClient()..autoUncompress = false,
  );

  static bool _adapterSet = false;

  static void _ensureAdapter() {
    if (!_adapterSet) {
      dio.httpClientAdapter = _ioAdapter;
      _adapterSet = true;
    }
  }

  // ---------- 响应缓存 ----------

  static const Duration _cacheTtl = Duration(seconds: 60);
  static const int _cacheMax = 12;
  static final Map<String, _CacheEntry> _cache = {};

  static String? _cacheGet(String key) {
    final e = _cache[key];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) > _cacheTtl) {
      _cache.remove(key);
      return null;
    }
    return e.text;
  }

  static void _cachePut(String key, String text) {
    if (text.isEmpty) return;
    if (_cache.length >= _cacheMax) {
      // 简单淘汰：删掉最早写入的一条
      final oldest = _cache.entries
          .reduce((a, b) => a.value.at.isBefore(b.value.at) ? a : b);
      _cache.remove(oldest.key);
    }
    _cache[key] = _CacheEntry(text, DateTime.now());
  }

  static void clearCache() => _cache.clear();

  /// 调试用：当前缓存的 URL 列表
  static List<String> get cachedUrls => _cache.keys.toList();

  // ---------- 请求 ----------

  /// 请求并按指定编码解码为文本（带缓存 / 流式接收 / 重试）。
  ///
  /// [referer] 建议传站点首页，部分站点（如速读谷）对无 Referer 的请求
  /// 会返回 404 页面或空内容。
  /// [maxBytes] 为接收上限，收到上限即主动断开（目录类大页面很有用）。
  /// [idleTimeout] 为「多久没收到新数据就用手上的内容」。
  static Future<String> getText(
    String url, {
    String charset = 'utf-8',
    String method = 'GET',
    Map<String, dynamic>? query,
    String? body, // 原始请求体（POST，优先于 query）
    Map<String, String>? headers,
    String? referer,
    int retries = 2,
    int maxBytes = 6 * 1024 * 1024,
    Duration idleTimeout = const Duration(seconds: 12),
    Duration headerTimeout = const Duration(seconds: 20),
    Duration totalTimeout = const Duration(seconds: 45),
    bool useCache = true,
  }) async {
    if (method == 'GET' && useCache) {
      final hit = _cacheGet(url);
      if (hit != null) return hit;
    }

    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final (text, _) = await _fetchOnce(
          url,
          charset: charset,
          method: method,
          query: query,
          requestBody: body,
          headers: headers,
          referer: referer,
          maxBytes: maxBytes,
          idleTimeout: idleTimeout,
          headerTimeout: headerTimeout,
          totalTimeout: totalTimeout,
        );
        if (text.isNotEmpty) {
          if (method == 'GET') _cachePut(url, text);
          return text;
        }
        lastError = '响应为空';
      } catch (e) {
        lastError = e;
      }
      if (attempt < retries) {
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    throw HttpFetchException('请求失败：$url\n$lastError');
  }

  /// 同 [getText]，但额外返回重定向后的最终地址（如搜索精确命中 302 到书页）。
  ///
  /// 返回 `(文本, 最终URL)`。用于需要知道重定向目标的场景。
  static Future<(String, String)> getTextDetailed(
    String url, {
    String charset = 'utf-8',
    String method = 'GET',
    Map<String, dynamic>? query,
    String? body,
    Map<String, String>? headers,
    String? referer,
    int retries = 2,
    int maxBytes = 6 * 1024 * 1024,
    Duration idleTimeout = const Duration(seconds: 12),
    Duration headerTimeout = const Duration(seconds: 20),
    Duration totalTimeout = const Duration(seconds: 45),
    bool useCache = false,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final (text, finalUrl) = await _fetchOnce(
          url,
          charset: charset,
          method: method,
          query: query,
          requestBody: body,
          headers: headers,
          referer: referer,
          maxBytes: maxBytes,
          idleTimeout: idleTimeout,
          headerTimeout: headerTimeout,
          totalTimeout: totalTimeout,
        );
        if (text.isNotEmpty) {
          if (method == 'GET' && useCache) _cachePut(url, text);
          return (text, finalUrl);
        }
        lastError = '响应为空';
      } catch (e) {
        lastError = e;
      }
      if (attempt < retries) {
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    throw HttpFetchException('请求失败：$url\n$lastError');
  }

  static Future<(String, String)> _fetchOnce(
    String url, {
    required String charset,
    required String method,
    Map<String, dynamic>? query,
    String? requestBody,
    Map<String, String>? headers,
    String? referer,
    required int maxBytes,
    required Duration idleTimeout,
    required Duration headerTimeout,
    required Duration totalTimeout,
  }) async {
    _ensureAdapter();
    // 头部等待超时：服务器接受 TCP 但迟迟不返回响应头（卡死）时，
    // dio.request 会一直等 receiveTimeout（3 分钟），这里强制封顶。
    final resp = await dio
        .request<ResponseBody>(
          url,
          queryParameters: query,
          data: requestBody ?? (method == 'POST' ? query : null),
          options: Options(
            method: method,
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(minutes: 3),
            headers: {
              if (referer != null && referer.isNotEmpty) 'Referer': referer,
              ...?headers,
            },
            // 4xx/5xx 也把内容读出来（站点会用 200 返回 404 页）
            validateStatus: (_) => true,
          ),
        )
        .timeout(headerTimeout);

    final body = resp.data;
    if (body == null) return ('', url);

    // body 总时长上限：站点「滴流式吐数据」（如八叉 72KB 拖 90s）时兜底，
    // 已收到的部分仍可用（发现页卡片/目录在前段，截断也能解析出来）。
    final deadline = DateTime.now().add(totalTimeout);
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in body.stream.timeout(idleTimeout)) {
        builder.add(chunk);
        // 收到上限就主动断开：目录页只需前面部分即可解析
        if (builder.length >= maxBytes) break;
        // 超时就用已收到的部分
        if (DateTime.now().isAfter(deadline)) break;
      }
    } on TimeoutException {
      // 站点不吐数据了：用已收到的部分（HTML 截断仍能解析出已到达的章节）
    }

    List<int> bytes = builder.takeBytes();
    final finalUrl = resp.realUri.toString();
    if (bytes.isEmpty) return ('', url);
    // 部分服务器无视 `Accept-Encoding: identity` 仍强制 gzip（如八一分类页），
    // 而底层 HttpClient autoUncompress=false 不解压 → 手动解压，避免乱码。
    bytes = _maybeGunzip(bytes);
    return (decode(bytes, charset), finalUrl);
  }

  /// 检测 gzip 魔数并解压（非 gzip 原样返回）。
  static List<int> _maybeGunzip(List<int> bytes) {
    if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return bytes;
    try {
      return io.gzip.decode(bytes);
    } catch (_) {
      return bytes; // 不是合法 gzip 流，原样返回
    }
  }

  /// 请求并返回原始字节（用于图片下载，不做文本解码 / 不缓存）。
  static Future<List<int>> getBytes(
    String url, {
    String method = 'GET',
    Map<String, dynamic>? query,
    String? body,
    Map<String, String>? headers,
    String? referer,
    int retries = 2,
    int maxBytes = 20 * 1024 * 1024,
    Duration idleTimeout = const Duration(seconds: 20),
    Duration headerTimeout = const Duration(seconds: 20),
    Duration totalTimeout = const Duration(seconds: 60),
  }) async {
    _ensureAdapter();
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final deadline = DateTime.now().add(totalTimeout);
        final resp = await dio
            .request<ResponseBody>(
              url,
              queryParameters: query,
              data: body ?? (method == 'POST' ? query : null),
              options: Options(
                method: method,
                responseType: ResponseType.stream,
                receiveTimeout: const Duration(minutes: 3),
                headers: {
                  if (referer != null && referer.isNotEmpty) 'Referer': referer,
                  // 图片 CDN（如 18rouman.vip）对 gzip 请求会慢速/挂起，
                  // 且 keep-alive 陈旧连接会卡死/截断：强制 identity + 每次新连接。
                  'Accept-Encoding': 'identity',
                  'Connection': 'close',
                  ...?headers,
                },
                validateStatus: (_) => true,
              ),
            )
            .timeout(headerTimeout);
        final bodyStream = resp.data;
        if (bodyStream == null) {
          lastError = '响应为空';
          continue;
        }
        final builder = BytesBuilder(copy: false);
        try {
          await for (final chunk in bodyStream.stream.timeout(idleTimeout)) {
            builder.add(chunk);
            if (builder.length >= maxBytes) break;
            if (DateTime.now().isAfter(deadline)) break;
          }
        } on TimeoutException {
          // 用已收部分
        }
        List<int> bytes = builder.takeBytes();
        if (bytes.isNotEmpty) {
          return _maybeGunzip(bytes);
        }
        lastError = '响应为空';
      } catch (e) {
        lastError = e;
      }
      if (attempt < retries) {
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    throw HttpFetchException('图片请求失败：$url\n$lastError');
  }

  /// 字节 → 文本（utf-8 / gbk / latin1）
  static String decode(List<int> bytes, String charset) {
    final cs = charset.toLowerCase();
    if (cs.contains('gb')) {
      try {
        return gbk.decode(bytes); // 纯 Dart GBK 解码
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
    if (cs.contains('latin') || cs.contains('iso-8859')) {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class _CacheEntry {
  final String text;
  final DateTime at;
  _CacheEntry(this.text, this.at);
}

class HttpFetchException implements Exception {
  final String message;
  HttpFetchException(this.message);
  @override
  String toString() => message;
}
