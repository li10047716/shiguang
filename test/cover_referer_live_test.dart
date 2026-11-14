import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reading_app/services/http_client.dart';
import 'package:reading_app/sources/native/daren.dart';

void main() {
  test('daren 封面带 Referer 完整下载（RIFF 声明 == 实际字节）', () async {
    final url = 'https://p4p.18rouman.vip/manga_pics/202405/20240527045101384.webp';
    final h = DarenSource().imageHeaders;
    expect(h, isNotNull);
    final bytes = await HttpClient.getBytes(url, headers: h);
    // RIFF header 第 4-7 字节是小端总长度（含 8 字节头），应为完整图
    final b = Uint8List.fromList(bytes);
    expect(b.length, greaterThan(5000), reason: '不应是截断的 ~700 字节');
    final declared = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24);
    expect(b.length, declared + 8,
        reason: '字节数应等于 RIFF 声明长度+8，实际 ${b.length} vs ${declared + 8}');
    // ignore: avoid_print
    print('daren 封面完整：${b.length} bytes（RIFF 声明 ${declared + 8}）');
  }, timeout: const Timeout(Duration(seconds: 60)),
      skip: '网络测试，需 --run-skipped 运行');
}
