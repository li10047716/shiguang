"""
AES-128-CBC 解密（纯标准库实现）。

环境里没有 cryptography / pycryptodome，pip 也用不了，所以手写一份。
只做解密，够用即可：正文单章几十 KB，纯 Python 也能在几毫秒内跑完。
"""

__all__ = ["cbc_decrypt", "pkcs7_unpad"]

_SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76"
    "ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d83115"
    "04c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f84"
    "53d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa8"
    "51a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d1973"
    "60814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479"
    "e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a"
    "703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df"
    "8ca1890dbfe6426841992d0fb054bb16"
)

_INV_SBOX = bytearray(256)
for _i, _v in enumerate(_SBOX):
    _INV_SBOX[_v] = _i

# 逆列混合用到的乘常数
_MUL9 = [0] * 256
_MUL11 = [0] * 256
_MUL13 = [0] * 256
_MUL14 = [0] * 256


def _xtime(a):
    a <<= 1
    if a & 0x100:
        a = (a ^ 0x11B) & 0xFF
    return a


def _mul(a, b):
    """GF(2^8) 乘法。"""
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        b >>= 1
        a = _xtime(a)
    return p


for _x in range(256):
    _MUL9[_x] = _mul(_x, 9)
    _MUL11[_x] = _mul(_x, 11)
    _MUL13[_x] = _mul(_x, 13)
    _MUL14[_x] = _mul(_x, 14)

_SBX = _SBOX
_ISBX = bytes(_INV_SBOX)


def _expand_key(key):
    """AES-128 密钥扩展，返回 44 个 4 字节字。"""
    w = [list(key[i * 4:i * 4 + 4]) for i in range(4)]
    rcon = 1
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]                      # RotWord
            t = [_SBX[b] for b in t]               # SubWord
            t[0] ^= rcon
            rcon = _xtime(rcon)
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return w


def _add_round_key(s, w, rnd):
    # 状态按列主序线性存放：s[4*c + r] 是 state[r][c]
    for c in range(4):
        k = w[rnd * 4 + c]
        for r in range(4):
            s[4 * c + r] ^= k[r]


def _inv_shift_rows(s):
    # 第 r 行循环右移 r 个字节
    out = [0] * 16
    for r in range(4):
        for c in range(4):
            out[4 * c + r] = s[4 * ((c - r) % 4) + r]
    return out


def _inv_sub_bytes(s):
    return [_ISBX[b] for b in s]


def _inv_mix_columns(s):
    out = [0] * 16
    for c in range(4):
        a0, a1, a2, a3 = s[4 * c:4 * c + 4]
        out[4 * c + 0] = _MUL14[a0] ^ _MUL11[a1] ^ _MUL13[a2] ^ _MUL9[a3]
        out[4 * c + 1] = _MUL9[a0] ^ _MUL14[a1] ^ _MUL11[a2] ^ _MUL13[a3]
        out[4 * c + 2] = _MUL13[a0] ^ _MUL9[a1] ^ _MUL14[a2] ^ _MUL11[a3]
        out[4 * c + 3] = _MUL11[a0] ^ _MUL13[a1] ^ _MUL9[a2] ^ _MUL14[a3]
    return out


def decrypt_block(block, w):
    """解密单个 16 字节分组。"""
    s = list(block)
    _add_round_key(s, w, 10)
    for rnd in range(9, 0, -1):
        s = _inv_shift_rows(s)
        s = _inv_sub_bytes(s)
        _add_round_key(s, w, rnd)
        s = _inv_mix_columns(s)
    s = _inv_shift_rows(s)
    s = _inv_sub_bytes(s)
    _add_round_key(s, w, 0)
    return bytes(s)


def cbc_decrypt(key, iv, data):
    """AES-CBC 解密，不处理填充。"""
    if len(key) not in (16, 24, 32):
        raise ValueError("AES 密钥长度不对：%d" % len(key))
    if len(key) != 16:
        raise ValueError("这里只实现了 AES-128")
    if len(data) % 16:
        raise ValueError("密文长度不是 16 的整数倍")
    w = _expand_key(key)
    out = bytearray()
    prev = iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        dec = decrypt_block(blk, w)
        out.extend(a ^ b for a, b in zip(dec, prev))
        prev = blk
    return bytes(out)


def pkcs7_unpad(data):
    if not data:
        return data
    n = data[-1]
    if 1 <= n <= 16 and data.endswith(bytes([n]) * n):
        return data[:-n]
    return data
