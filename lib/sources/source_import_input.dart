import 'dart:convert';
import 'dart:io';

/// 导入数据必须完整下载；不能复用会容忍截断 HTML 的抓取器。
class SourceImportInput {
  static const maxBytes = 5 * 1024 * 1024;

  static Future<String> readFile(String path) async {
    final file = File(path);
    if (await file.length() > maxBytes) {
      throw const FormatException('JSON 文件不能超过 5 MiB');
    }
    return _read(file.openRead());
  }

  static Future<String> download(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入无内嵌凭据的 HTTP(S) URL');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('下载失败：HTTP ${response.statusCode}');
        }
        if (response.contentLength > maxBytes) {
          throw const FormatException('JSON 下载不能超过 5 MiB');
        }
        return _read(response);
      })().timeout(const Duration(seconds: 30));
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _read(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('JSON 数据不能超过 5 MiB');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }
}
