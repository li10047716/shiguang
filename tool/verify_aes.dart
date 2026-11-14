/// AES-128-CBC 实现验证（NIST SP 800-38A 标准向量）。
/// 用法：dart run tool/verify_aes.dart
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:reading_app/utils/aes.dart';

void main() {
  var failed = 0;
  void check(String label, bool ok, String detail) {
    print('${ok ? "✓" : "✗"} $label: $detail');
    if (!ok) failed++;
  }

  List<int> hex(String s) {
    final out = <int>[];
    for (var i = 0; i < s.length; i += 2) {
      out.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  // NIST SP 800-38A F.2.1 CBC-AES128.Encrypt 的已知明文-密文对
  final key = hex('2b7e151628aed2a6abf7158809cf4f3c');
  final iv = hex('000102030405060708090a0b0c0d0e0f');
  final pt1 = hex('6bc1bee22e409f96e93d7e117393172a');
  final ct1 = hex('7649abac8119b246cee98e9b12e9197d');
  final pt2 = hex('ae2d8a571e03ac9c9eb76fac45af8e51');
  final ct2 = hex('5086cb9b507219ee95db113a917678b2');

  final dec1 = aesCbcDecrypt(key, iv, ct1);
  check('FIPS-197 向量 1', _bytesEq(dec1, pt1), _hex(dec1));

  final dec2 = aesCbcDecrypt(key, ct1, ct2);
  check('FIPS-197 向量 2（链式）', _bytesEq(dec2, pt2), _hex(dec2));

  // 多分组 CBC 拼接
  final ctAll = [...ct1, ...ct2];
  final decAll = aesCbcDecrypt(key, iv, ctAll);
  check(
    'CBC 多分组',
    _bytesEq(decAll, [...pt1, ...pt2]),
    _hex(decAll),
  );

  // PKCS7 填充（16 字节整块 → 追加一整块 0x10）
  final padded = [...pt1, ...List.filled(16, 16)];
  final unpadded = pkcs7Unpad(padded);
  check('PKCS7 去填充（整块）', _bytesEq(unpadded, pt1), _hex(unpadded));

  // PKCS7 填充（非整块，尾部 3 字节 0x03）
  final padded2 = [...pt1.sublist(0, 13), 3, 3, 3];
  final unpadded2 = pkcs7Unpad(padded2);
  check(
    'PKCS7 去填充（3 字节）',
    _bytesEq(unpadded2, pt1.sublist(0, 13)),
    _hex(unpadded2),
  );

  // 模拟七猫格式：Base64(IV[16] + AES-128-CBC 密文)，key=242ccb8230d709e1
  final qmKey = utf8.encode('242ccb8230d709e1');
  final qmIv = hex('00112233445566778899aabbccddeeff');
  final qmPlain = utf8.encode('第一章 测试\n这是正文内容。\n第二段。');
  final qmEnc = _encryptRef(qmKey, qmIv, qmPlain); // 仅本地对照用（见 _encryptRef）
  final blob = base64Encode([...qmIv, ...qmEnc]);
  final raw = base64Decode(blob);
  final qmDec = aesCbcDecryptPadded(qmKey, raw.sublist(0, 16), raw.sublist(16));
  check(
    '七猫格式（IV+密文）往返',
    _bytesEq(qmDec, qmPlain),
    utf8.decode(qmDec),
  );

  print(failed == 0 ? '\n全部通过' : '\n$failed 项失败');
  if (failed > 0) {
    throw StateError('$failed 项失败');
  }
}

bool _bytesEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(List<int> a) => a.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// 参考加密：用同一套 S-Box 前向变换实现 AES-128-CBC 加密。
/// 仅用于验证解密逻辑的往返一致性（解密实现不依赖它）。
List<int> _encryptRef(List<int> key, List<int> iv, List<int> plain) {
  // 真实流程：明文 → PKCS7 填充 → AES-CBC 加密 → 前置 IV。
  // 这里补齐填充，使往返测试与七猫真实链路一致。
  final padLen = 16 - (plain.length % 16);
  final padded = [
    ...plain,
    ...List<int>.filled(padLen, padLen),
  ];
  final out = <int>[];
  var prev = iv;
  for (var i = 0; i < padded.length; i += 16) {
    final blk = <int>[
      for (var j = 0; j < 16; j++) padded[i + j] ^ prev[j],
    ];
    final enc = _encryptBlockRef(key, blk);
    out.addAll(enc);
    prev = enc;
  }
  return out;
}

List<int> _encryptBlockRef(List<int> key, List<int> block) {
  // 前向 AES 实现（用于自检往返）
  final w = _expandKeyRef(key);
  var s = List<int>.from(block);
  _addRoundKeyRef(s, w, 0);
  for (var rnd = 1; rnd < 10; rnd++) {
    s = [for (final b in s) _sboxRef[b]];
    s = _shiftRows(s);
    s = _mixColumns(s);
    _addRoundKeyRef(s, w, rnd);
  }
  s = [for (final b in s) _sboxRef[b]];
  s = _shiftRows(s);
  _addRoundKeyRef(s, w, 10);
  return s;
}

const List<int> _sboxRef = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
  0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
  0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
  0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
  0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
  0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
  0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
  0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
  0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
  0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
  0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
  0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
  0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
  0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
  0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
  0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
  0xb0, 0x54, 0xbb, 0x16,
];

List<List<int>> _expandKeyRef(List<int> key) {
  final w = <List<int>>[
    for (var i = 0; i < 4; i++) key.sublist(i * 4, i * 4 + 4),
  ];
  var rcon = 1;
  for (var i = 4; i < 44; i++) {
    var t = List<int>.from(w[i - 1]);
    if (i % 4 == 0) {
      t = [t[1], t[2], t[3], t[0]];
      t = [for (final b in t) _sboxRef[b]];
      t[0] ^= rcon;
      rcon = _xtimeRef(rcon);
    }
    w.add([for (var j = 0; j < 4; j++) w[i - 4][j] ^ t[j]]);
  }
  return w;
}

int _xtimeRef(int a) {
  var x = a << 1;
  if (x & 0x100 != 0) x = (x ^ 0x11b) & 0xff;
  return x;
}

void _addRoundKeyRef(List<int> s, List<List<int>> w, int rnd) {
  for (var c = 0; c < 4; c++) {
    final k = w[rnd * 4 + c];
    for (var r = 0; r < 4; r++) {
      s[4 * c + r] ^= k[r];
    }
  }
}

List<int> _shiftRows(List<int> s) {
  final out = List<int>.filled(16, 0);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      out[4 * c + r] = s[4 * ((c + r) % 4) + r];
    }
  }
  return out;
}

List<int> _mixColumns(List<int> s) {
  final out = List<int>.filled(16, 0);
  for (var c = 0; c < 4; c++) {
    final a0 = s[4 * c + 0];
    final a1 = s[4 * c + 1];
    final a2 = s[4 * c + 2];
    final a3 = s[4 * c + 3];
    out[4 * c + 0] = _mul2(a0) ^ _mul3(a1) ^ a2 ^ a3;
    out[4 * c + 1] = a0 ^ _mul2(a1) ^ _mul3(a2) ^ a3;
    out[4 * c + 2] = a0 ^ a1 ^ _mul2(a2) ^ _mul3(a3);
    out[4 * c + 3] = _mul3(a0) ^ a1 ^ a2 ^ _mul2(a3);
  }
  return out;
}

int _mul2(int a) => _xtimeRef(a);
int _mul3(int a) => _xtimeRef(a) ^ a;
