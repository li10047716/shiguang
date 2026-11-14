/// AES-128-CBC 解密 + PKCS7 去填充（纯 Dart 实现）。
///
/// 参照 shiguang `reader/aes.py`（纯 Python 标准库版）逐字节移植。
/// 只实现解密：正文单章几十 KB，Dart 原生 List 操作足够快。
///
/// 用法：
/// ```dart
/// final plain = aesCbcDecrypt(key, iv, ciphertext); // List<int>
/// final text = utf8.decode(pkcs7Unpad(plain));
/// ```
library;

// AES S-Box（FIPS-197 标准值）
const List<int> _sbox = <int>[
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

final List<int> _invSbox = () {
  final inv = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    inv[_sbox[i]] = i;
  }
  return inv;
}();

// 逆列混合乘常数
final List<int> _mul9 = _genMul(9);
final List<int> _mul11 = _genMul(11);
final List<int> _mul13 = _genMul(13);
final List<int> _mul14 = _genMul(14);

List<int> _genMul(int factor) {
  final out = List<int>.filled(256, 0);
  for (var x = 0; x < 256; x++) {
    out[x] = _gfMul(x, factor);
  }
  return out;
}

/// GF(2^8) 乘法（AES 域多项式 `x^8 + x^4 + x^3 + x + 1` → 0x11B）。
int _gfMul(int a, int b) {
  var p = 0;
  var aa = a;
  var bb = b;
  for (var i = 0; i < 8; i++) {
    if (bb & 1 != 0) p ^= aa;
    bb >>= 1;
    aa = _xtime(aa);
  }
  return p;
}

int _xtime(int a) {
  var x = a << 1;
  if (x & 0x100 != 0) x = (x ^ 0x11b) & 0xff;
  return x;
}

/// AES-128 密钥扩展：返回 44 个 4 字节字（每个字是 `List<int>` 长度 4）。
List<List<int>> _expandKey(List<int> key) {
  final w = <List<int>>[
    for (var i = 0; i < 4; i++) key.sublist(i * 4, i * 4 + 4),
  ];
  var rcon = 1;
  for (var i = 4; i < 44; i++) {
    var t = List<int>.from(w[i - 1]);
    if (i % 4 == 0) {
      // RotWord
      t = [t[1], t[2], t[3], t[0]];
      // SubWord
      t = [for (final b in t) _sbox[b]];
      t[0] ^= rcon;
      rcon = _xtime(rcon);
    }
    w.add([for (var j = 0; j < 4; j++) w[i - 4][j] ^ t[j]]);
  }
  return w;
}

/// 状态按列主序线性存放：s[4*c + r] 是 state[r][c]（与 aes.py 一致）。
void _addRoundKey(List<int> s, List<List<int>> w, int rnd) {
  for (var c = 0; c < 4; c++) {
    final k = w[rnd * 4 + c];
    for (var r = 0; r < 4; r++) {
      s[4 * c + r] ^= k[r];
    }
  }
}

List<int> _invShiftRows(List<int> s) {
  final out = List<int>.filled(16, 0);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      out[4 * c + r] = s[4 * ((c - r) % 4) + r];
    }
  }
  return out;
}

List<int> _invSubBytes(List<int> s) => [for (final b in s) _invSbox[b]];

List<int> _invMixColumns(List<int> s) {
  final out = List<int>.filled(16, 0);
  for (var c = 0; c < 4; c++) {
    final a0 = s[4 * c + 0];
    final a1 = s[4 * c + 1];
    final a2 = s[4 * c + 2];
    final a3 = s[4 * c + 3];
    out[4 * c + 0] = _mul14[a0] ^ _mul11[a1] ^ _mul13[a2] ^ _mul9[a3];
    out[4 * c + 1] = _mul9[a0] ^ _mul14[a1] ^ _mul11[a2] ^ _mul13[a3];
    out[4 * c + 2] = _mul13[a0] ^ _mul9[a1] ^ _mul14[a2] ^ _mul11[a3];
    out[4 * c + 3] = _mul11[a0] ^ _mul13[a1] ^ _mul9[a2] ^ _mul14[a3];
  }
  return out;
}

List<int> _decryptBlock(List<int> block, List<List<int>> w) {
  var s = List<int>.from(block);
  _addRoundKey(s, w, 10);
  for (var rnd = 9; rnd > 0; rnd--) {
    s = _invShiftRows(s);
    s = _invSubBytes(s);
    _addRoundKey(s, w, rnd);
    s = _invMixColumns(s);
  }
  s = _invShiftRows(s);
  s = _invSubBytes(s);
  _addRoundKey(s, w, 0);
  return s;
}

/// AES-128-CBC 解密（不处理填充）。
///
/// [key] 必须 16 字节；[iv] 16 字节；[data] 长度必须为 16 的整数倍。
List<int> aesCbcDecrypt(List<int> key, List<int> iv, List<int> data) {
  if (key.length != 16) {
    throw ArgumentError('AES 密钥长度应为 16 字节，实际 ${key.length}');
  }
  if (iv.length != 16) {
    throw ArgumentError('AES IV 长度应为 16 字节，实际 ${iv.length}');
  }
  if (data.length % 16 != 0) {
    throw ArgumentError('AES 密文长度应为 16 的整数倍，实际 ${data.length}');
  }
  final w = _expandKey(key);
  final out = <int>[];
  var prev = iv;
  for (var i = 0; i < data.length; i += 16) {
    final blk = data.sublist(i, i + 16);
    final dec = _decryptBlock(blk, w);
    for (var j = 0; j < 16; j++) {
      out.add(dec[j] ^ prev[j]);
    }
    prev = blk;
  }
  return out;
}

/// PKCS7 去填充。填充非法时原样返回（与 aes.py 容错行为一致）。
List<int> pkcs7Unpad(List<int> data) {
  if (data.isEmpty) return data;
  final n = data[data.length - 1];
  if (n >= 1 && n <= 16 && _endsWithRepeat(data, n)) {
    return data.sublist(0, data.length - n);
  }
  return data;
}

bool _endsWithRepeat(List<int> data, int n) {
  if (data.length < n) return false;
  for (var i = data.length - n; i < data.length; i++) {
    if (data[i] != n) return false;
  }
  return true;
}

/// 便捷：AES-128-CBC 解密 + PKCS7 去填充，返回明文字节。
List<int> aesCbcDecryptPadded(List<int> key, List<int> iv, List<int> data) =>
    pkcs7Unpad(aesCbcDecrypt(key, iv, data));
