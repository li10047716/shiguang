"""Minimal pure-Python AES-128 (CBC + PKCS7) used by the 漫蛙 (manwa) comic source.

The manwa CDN serves chapter images AES-128-CBC encrypted with key == IV ==
"my2ecret782ecret" and PKCS7 padding. We avoid an external crypto dependency so the
reader runs on a stock Python. Only the decrypt path is implemented.

Reference: standard FIPS-197 AES-128.
"""

# Round constants
_RCON = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]

_S = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]

_INV_S = [0] * 256
for _i, _v in enumerate(_S):
    _INV_S[_v] = _i

# Multiply in GF(2^8)
def _xtime(a):
    a <<= 1
    if a & 0x100:
        a ^= 0x11B
    return a & 0xFF

def _gmul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        a = _xtime(a)
        b >>= 1
    return p & 0xFF


def _key_expansion(key):
    # key: 16 bytes -> 11 round keys of 16 bytes each (44 words)
    w = [list(key[i:i + 4]) for i in range(0, 16, 4)]  # 4 words
    while len(w) < 44:
        temp = list(w[-1])
        if len(w) % 4 == 0:
            temp = temp[1:] + temp[:1]  # RotWord
            temp = [_S[b] for b in temp]  # SubWord
            rc = _RCON[len(w) // 4]
            temp[0] ^= rc
        prev = w[-4]
        w.append([temp[i] ^ prev[i] for i in range(4)])
    # group into 11 round keys
    rk = []
    for r in range(11):
        rk.append(w[r * 4:r * 4 + 4])
    return rk


def _add_round_key(state, rk):
    for c in range(4):
        for r in range(4):
            state[r][c] ^= rk[c][r]


def _sub_bytes(state, box):
    for r in range(4):
        for c in range(4):
            state[r][c] = box[state[r][c]]


def _shift_rows(state, inverse=False):
    for r in range(1, 4):
        if inverse:
            state[r] = state[r][-r:] + state[r][:-r]
        else:
            state[r] = state[r][r:] + state[r][:r]


def _mix_columns(state, inverse=False):
    for c in range(4):
        col = [state[r][c] for r in range(4)]
        if inverse:
            t0 = _gmul(col[0], 14) ^ _gmul(col[1], 11) ^ _gmul(col[2], 13) ^ _gmul(col[3], 9)
            t1 = _gmul(col[0], 9) ^ _gmul(col[1], 14) ^ _gmul(col[2], 11) ^ _gmul(col[3], 13)
            t2 = _gmul(col[0], 13) ^ _gmul(col[1], 9) ^ _gmul(col[2], 14) ^ _gmul(col[3], 11)
            t3 = _gmul(col[0], 11) ^ _gmul(col[1], 13) ^ _gmul(col[2], 9) ^ _gmul(col[3], 14)
        else:
            t0 = _gmul(col[0], 2) ^ _gmul(col[1], 3) ^ col[2] ^ col[3]
            t1 = col[0] ^ _gmul(col[1], 2) ^ _gmul(col[2], 3) ^ col[3]
            t2 = col[0] ^ col[1] ^ _gmul(col[2], 2) ^ _gmul(col[3], 3)
            t3 = _gmul(col[0], 3) ^ col[1] ^ col[2] ^ _gmul(col[3], 2)
        state[0][c], state[1][c], state[2][c], state[3][c] = t0, t1, t2, t3


def _decrypt_block(block, rk):
    # block: 16 bytes -> 16 bytes
    state = [[block[r + 4 * c] for c in range(4)] for r in range(4)]
    _add_round_key(state, rk[10])
    _shift_rows(state, inverse=True)
    _sub_bytes(state, _INV_S)
    for rnd in range(9, 0, -1):
        _add_round_key(state, rk[rnd])
        _mix_columns(state, inverse=True)
        _shift_rows(state, inverse=True)
        _sub_bytes(state, _INV_S)
    _add_round_key(state, rk[0])
    # state is column-major: out[i] = state[i % 4][i // 4]
    return bytes(state[i % 4][i // 4] for i in range(16))


def aes_cbc_decrypt(key, data):
    """Decrypt AES-128-CBC with IV == key. ``key`` is 16 bytes, ``data`` length
    is a multiple of 16. Removes PKCS7 padding."""
    if len(key) != 16:
        raise ValueError("AES-128 requires a 16-byte key")
    rk = _key_expansion(key)
    n = len(data)
    if n == 0 or n % 16 != 0:
        # pad data to block boundary for safety
        pad = (16 - (n % 16)) % 16
        data = data + b"\x00" * pad
        n = len(data)
    prev = key  # IV == key
    out = bytearray()
    for i in range(0, n, 16):
        blk = data[i:i + 16]
        dec = _decrypt_block(blk, rk)
        out += bytes(a ^ b for a, b in zip(dec, prev))
        prev = blk
    # strip PKCS7 padding
    if out and 1 <= out[-1] <= 16:
        padlen = out[-1]
        if out[-padlen:] == bytes([padlen]) * padlen:
            out = out[:-padlen]
    return bytes(out)
