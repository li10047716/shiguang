"""
书旗小说（shuqi.com）App 接口客户端。

协议来自用户提供的「阅读」书源（1794196551.json），纯 Python 复现：
  - 请求体 JSON 与 x-sq-public 头都用 2048 字节 keystream 做二进制 XOR 再 base64
  - 签名是 md5(按键名升序拼 "k=v&" + skey)
  - enc18 由 user_id 与毫秒时间戳派生
  - POST 到 ocean.shuqireader.com/sqan/...

只用标准库。H5 站点必须用 okhttp UA，否则会返回 403 拦截页。
"""
import base64
import hashlib
import html as htmllib
import json
import os
import random
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SKEY = "467694bd8912441cae8498b3c7e4282c"
SQSV = "1.0"
UID = "8158804976"
CIUID = "8000000"
HOST = "https://ocean.shuqireader.com"
WEB = "https://www.shuqi.com"
UA = "okhttp/3.12.13"

PREFIX = "sq:"
SCHEME = "sq://"

P_SEARCH = "/sqan/render/render/search/native_v3"
P_TITLE = "/sqan/sqapi/bff/api/v1/reader/titlepage"
P_CHINFO = "/sqan/sqapi/bff/api/v1/reader/chapterinfo"

CDN_HOSTS = ["c1.shuqireader.com", "c2.shuqireader.com"]
CDN_FLAGS = ["3111111111", "2111111111"]

PUB = [
    ["soft_id", "1"], ["user_id", UID], ["userId", UID], ["ver", "261013"],
    ["subVer", "sqrelease"], ["appVer", "12.7.0.268"], ["theme", "day"],
    ["platform", "an"], ["placeid", "1069"], ["sdk", "32"], ["cpu", "x86_64"],
    ["pkg_cpu", "arm64-v8a"], ["wh", "900x1600"], ["msv", "3"], ["vc", "5d73"],
    ["mod", "BVL-AN16"], ["manufacturer", "HONOR"], ["brand", "HONOR"],
    ["net_type", "wifi"], ["net_type_str", "wifi"], ["first_placeid", "src1069"],
    ["aak", "a3a840"], ["utype", "pre_vip"], ["net", "4"], ["net_env", "4"],
    ["permissionType", "0"], ["personalized", "1"], ["contentRecom", "1"],
    ["scene_code", ""], ["rom", "12"], ["sqUniqDeviceId", ""], ["utdid", ""],
    ["sn", ""], ["umidtoken", ""], ["otdd", ""],
]

ORDER = [
    "soft_id", "user_id", "userId", "ver", "subVer", "appVer", "theme", "platform",
    "placeid", "sdk", "cpu", "pkg_cpu", "wh", "msv", "enc", "vc", "mod",
    "manufacturer", "brand", "net_type", "net_type_str", "first_placeid", "aak",
    "utype", "net", "net_env", "permissionType", "personalized", "contentRecom",
    "scene_code", "rom", "sqUniqDeviceId", "utdid", "sn", "umidtoken", "otdd",
]

NOSIGN = {"sign", "key", "_public", "_reqid", "_beta", "_", "X",
          "XNEBULAXMLHTTPREQUEST", "callbackUrl"}

RANKS = [
    ("boyClick", "男频点击榜"), ("boyStore", "男频收藏榜"), ("boyOrder", "男频订阅榜"),
    ("boyhot", "男频人气榜"), ("boyEnd", "男频完结榜"), ("boyUpdate", "男频更新榜"),
    ("girlClick", "女频点击榜"), ("girlStore", "女频收藏榜"), ("girlEnd", "女频完结榜"),
    ("allEnd", "全站完结榜"), ("allWords", "全站字数榜"), ("allClick", "全站点击榜"),
    ("allStore", "全站收藏榜"), ("allOrder", "全站订阅榜"),
]

# 发现页的书库分类（fc 与站点一致，逗号表示多分类）
STORE_CATS = [
    ("7", "都市"), ("29", "玄幻"), ("34,102", "科幻"), ("41,108", "悬疑"),
    ("45", "历史"), ("54", "体育"), ("58", "武侠"), ("63", "游戏"),
    ("67,98", "仙侠"), ("71", "同人"), ("76", "现代言情"), ("86", "古代言情"),
    ("94", "玄幻言情"), ("122", "幻想言情"), ("127", "浪漫青春"), ("", "全部书库"),
]


# ---------------------------------------------------------------- 基础工具

def is_sq(value):
    v = (value or "").strip()
    return v.startswith(PREFIX) or v.startswith(SCHEME)


def native_id(value):
    v = (value or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):].split("/")[0]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    return v


_KS = None


def _ks():
    global _KS
    if _KS is None:
        with open(os.path.join(HERE, "sq_keystream.b64"), "r", encoding="utf-8") as f:
            _KS = base64.b64decode(f.read().strip())
    return _KS


def _uri(s):
    """等价 JS encodeURIComponent（保留 ! ' ( ) * - . _ ~）。"""
    return urllib.parse.quote(str(s), safe="!'()*-._~")


def _pub_enc(s):
    return urllib.parse.quote(str(s), safe="!'()~-._")


def _xor_b64(raw):
    ks = _ks()
    n = min(len(raw), len(ks))
    return base64.b64encode(bytes(raw[i] ^ ks[i] for i in range(n))).decode()


def _enc18(uid, ts):
    ts = str(ts)
    while len(ts) < 13:
        ts = "2" + ts
    ts = ts[:13]
    n = int(uid) or 24697
    k = int(ts[1] + ts[3] + ts[5] + ts[8] + ts[6]) or 0
    p = 12347 * n if k == 0 else k * n
    return str(p)[-5:] + ts


def _rnd(n, hex_only=False):
    chars = "0123456789abcdef" if hex_only else \
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(random.choice(chars) for _ in range(n))


DEVICE = {
    "sqUniqDeviceId": _rnd(22),
    "utdid": _rnd(28),
    "sn": _rnd(16, True),
    "umidtoken": _rnd(40, True),
    "otdd": _rnd(22),
}


def _sign(pairs):
    a = [(k, str(v)) for k, v in pairs if k not in NOSIGN]
    if not any(k == "sqSv" for k, _ in a):
        a.append(("sqSv", SQSV))
    a.sort(key=lambda x: x[0])
    raw = "".join("%s=%s&" % (k, _uri(v)) for k, v in a) + "skey=" + SKEY
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def _pub_str(uid, enc):
    m = dict(PUB)
    m.update(DEVICE)
    m["user_id"] = uid
    m["userId"] = uid
    m["platform"] = "2"
    m["enc"] = enc
    return "".join("%s=%s&" % (k, _pub_enc(m[k])) for k in ORDER if k in m)


def _build(path, biz, uid=UID, ts=None):
    ts = ts or str(int(time.time() * 1000))
    enc = _enc18(uid, ts)
    m = dict(PUB)
    m.update(DEVICE)
    m["user_id"] = uid
    m["userId"] = uid
    m["platform"] = "an"
    m["enc"] = enc
    m["timestamp"] = ts
    for k, v in biz:
        m[k] = str(v)
    m["isTeenMode"] = "0"
    m["sqSv"] = SQSV
    m["sign"] = _sign(list(m.items()))
    m["key"] = "sq_app_gateway"

    plain = json.dumps(m, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    body = "data=" + _uri(_xor_b64(plain))
    headers = {
        "content-type": "application/x-www-form-urlencoded",
        "user-agent": UA,
        "x-sq-req-platform": "an",
        "x-sq-s-key": "23011413",
        "x-sq-sv": "3.0",
        "x-sq-public": _xor_b64(_pub_str(uid, enc).encode("utf-8")),
        "x-sq-req-encrypt": "sdk",
        "x-sq-req-encrypt-param": "x-sq-public",
        "x-sq-api-encrypt": "1",
    }
    return HOST + path, body, headers


def _api(path, biz, uid=UID, timeout=20, retries=1):
    url, body, headers = _build(path, biz, uid)
    err = None
    for i in range(retries + 1):
        try:
            req = urllib.request.Request(url, data=body.encode("utf-8"),
                                         headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "ignore"))
        except urllib.error.HTTPError as e:
            if 400 <= e.code < 500:
                raise RuntimeError("书旗接口返回 HTTP %d" % e.code)
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i < retries:
            time.sleep(0.5 * (i + 1))
    raise RuntimeError("书旗接口请求失败：%s" % err)


_THROTTLE_LOCK = threading.Lock()
_LAST_SEARCH = [0.0]


def _throttle(seconds=3.0):
    """搜索太频繁会触发风控，按书源建议做 3 秒最小间隔。"""
    with _THROTTLE_LOCK:
        wait = seconds - (time.time() - _LAST_SEARCH[0])
        if 0 < wait < seconds:
            time.sleep(wait)
        _LAST_SEARCH[0] = time.time()


def _h5_get(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


# ---------------------------------------------------------------- 文本

_TAG = re.compile(r"<[^>]+>")


def _plain(s):
    s = htmllib.unescape(str(s or ""))
    s = _TAG.sub("", s).replace("\u3000", " ")
    return re.sub(r"\s+", " ", s).strip()


def _words(n):
    try:
        w = int(n)
    except (TypeError, ValueError):
        return ""
    if w >= 100000000:
        return "%.1f 亿字" % (w / 100000000.0)
    if w >= 10000:
        return "%.1f 万字" % (w / 10000.0)
    return ("%d 字" % w) if w > 0 else ""


# ---------------------------------------------------------------- 搜索

def search(keyword, page=1):
    keyword = (keyword or "").strip()
    if not keyword:
        return {"books": [], "pages": 1, "total": 0}
    _throttle(3.0)
    resp = _api(P_SEARCH, [["page", "searchResultV3"], ["query", keyword],
                           ["timestamp", str(int(time.time() * 1000))]])
    data = resp.get("data") or {}
    books, seen = [], set()
    for mod in data.get("moduleInfos") or []:
        b = (mod or {}).get("book") or {}
        bid = str(b.get("bookId") or "")
        if not bid or bid in seen:
            continue
        seen.add(bid)
        author = _plain(b.get("authorName"))
        parts = [x for x in _plain(b.get("bottomText")).split("·") if x]
        kind = [x for x in parts if x not in ("完结", "连载") and x != author]
        tags = [t for t in (b.get("tags") or []) if isinstance(t, str)]
        books.append({
            "id": PREFIX + bid,
            "title": _plain(b.get("bookName") or b.get("displayBookName")),
            "author": author,
            "cover": b.get("imgUrl") or "",
            "intro": _plain(b.get("desc")),
            "category": " · ".join(kind or tags),
            "status": "已完结" if str(b.get("state")) == "2" else "连载中",
            "words": _words(b.get("wordCount")),
            "score": str(b.get("novelScore") or ""),
            "latest": "",
            "source": "书旗",
        })
    return {"books": books, "pages": 1, "page": 1, "total": len(books)}


# ---------------------------------------------------------------- 详情 / 目录

def _open_toc(bid):
    """H5 目录缺失时的兜底：openapi 卷数组。"""
    key = "37e81a9d8f02596e1b895d07c171d5c9"
    ts = str(int(time.time()))
    q = "bookId=%s&user_id=%s&timestamp=%s&sign=%s" % (
        bid, CIUID, ts,
        hashlib.md5(("%s%s%s%s" % (bid, ts, CIUID, key)).encode()).hexdigest())
    urls = [
        "https://content.shuqireader.com/openapi/book/chapterlist?shuqi_h5=205&platform=0&" + q,
        "https://ocean.shuqireader.com/api/bcspub/qswebapi/book/chapterlist?_=&" + q,
    ]
    raw = ""
    for u in urls:
        try:
            raw = _h5_get(u)
            if raw and len(raw) > 200:
                break
        except Exception:  # noqa: BLE001
            continue
    try:
        d = json.loads(raw)
    except Exception:  # noqa: BLE001
        return []
    if str(d.get("state")) != "200" and str(d.get("status")) != "200":
        return []
    out = []
    for vol in (d.get("data") or {}).get("chapterList") or []:
        rows = []
        for c in (vol.get("volumeList") or vol.get("chapterList")
                  or vol.get("chapter") or []):
            cid = str((c or {}).get("chapterId") or (c or {}).get("cid") or "")
            if not cid:
                continue
            name = _plain((c or {}).get("chapterName") or (c or {}).get("name")
                          or (c or {}).get("title"))
            rows.append({"t": name or "第%d章" % (len(rows) + 1),
                         "u": "%s%s/%s" % (SCHEME, bid, cid)})
        out.extend(rows)
    return out


def chapters(bid):
    bid = native_id(bid)
    try:
        html = _h5_get(WEB + "/chapter?bid=" + bid)
    except Exception:  # noqa: BLE001
        html = ""
    if len(html) > 5000 and "cid=" in html:
        rows, seen = [], set()
        for m in re.finditer(
                r'href="/reader\?bid=\d+&(?:amp;)?cid=(\d+)"[^>]*>([\s\S]*?)</a>', html):
            cid = m.group(1)
            if cid in seen:
                continue
            seen.add(cid)
            inner = re.sub(r"<i[^>]*>[\s\S]*?</i>", " ", m.group(2))
            name = _plain(inner)
            name = re.sub(r"^\d+[.、]\s*", "", name)
            if not name:
                continue
            rows.append({"t": name, "u": "%s%s/%s" % (SCHEME, bid, cid)})
        if rows:
            return rows
    return _open_toc(bid)


def book(book_id):
    bid = native_id(book_id)
    if not bid:
        raise RuntimeError("缺少书旗书籍 id")
    info = {}
    try:
        r = _api(P_TITLE, [["bookId", bid]])
        b = (r.get("data") or {}).get("bookInfo") or {}
        if b.get("bookName"):
            score = (r.get("data") or {}).get("scoreInfo") or {}
            info = {
                "title": _plain(b.get("bookName")),
                "author": _plain(b.get("authorName")),
                "intro": _plain(b.get("briefIntro")),
                "cover": b.get("coverUrl") or "",
                "category": " · ".join([x for x in (
                    _plain(b.get("secCateName")),
                    "·".join([t for t in (b.get("tags") or []) if isinstance(t, str)]),
                ) if x]),
                "status": "已完结" if str(b.get("serialState")) == "2" else "连载中",
                "words": _words(b.get("wordCount")),
                "score": str(score.get("bookScore") or ""),
            }
    except Exception:  # noqa: BLE001
        pass

    chs = chapters(bid)
    if not info:
        info = {"title": "书籍" + bid, "author": "", "intro": "", "cover": "",
                "category": "", "status": "", "words": "", "score": ""}
    if not chs:
        raise RuntimeError("书旗：这本暂时取不到目录")
    return {
        "id": PREFIX + bid,
        "title": info["title"],
        "author": info["author"],
        "cover": info["cover"],
        "category": info["category"],
        "status": info["status"],
        "intro": info["intro"],
        "updated": "",
        "url": SCHEME + bid,
        "chapters": chs,
        "count": len(chs),
        "words": info["words"],
        "score": info["score"],
        "latest": chs[-1]["t"] if chs else "",
        "tags": [],
        "publisher": "书旗小说",
        "statement": "",
        "source": "书旗",
    }


# ---------------------------------------------------------------- 正文

def _cdn_parse(body):
    i = body.find("(")
    j = body.rfind(")")
    inner = body[i + 1:j] if 0 < i < j else body
    try:
        arr = json.loads(inner)
        c = str((arr or [{}])[0].get("content") or "")
    except Exception:  # noqa: BLE001
        return ""
    if not c:
        return ""
    c = re.sub(r"<br\s*/?>", "\n", c)
    return htmllib.unescape(_TAG.sub("", c))


def _rot13(s):
    out = []
    for ch in s:
        o = ord(ch)
        if 65 <= o <= 90:
            out.append(chr((o - 65 + 13) % 26 + 65))
        elif 97 <= o <= 122:
            out.append(chr((o - 97 + 13) % 26 + 97))
        else:
            out.append(ch)
    return "".join(out)


def _ci_decode(s):
    raw = re.sub(r"\s+", "", _rot13(str(s or "")))
    try:
        txt = base64.b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8", "ignore")
    except Exception:  # noqa: BLE001
        return ""
    return re.sub(r"<br\s*/?>", "\n", txt)


def chapter(url):
    v = (url or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    parts = [p for p in v.split("/") if p]
    if len(parts) < 2:
        raise RuntimeError("书旗章节地址不对：%s" % url)
    bid, cid = parts[0], parts[1]

    text = ""
    for scheme in ("https", "http"):
        for host in CDN_HOSTS:
            for flag in CDN_FLAGS:
                u = "%s://%s/httpserver/filecache/get_book_content_%s_%s_%s_0_0.html" % (
                    scheme, host, bid, cid, flag)
                try:
                    text = _cdn_parse(_h5_get(u, timeout=20))
                except Exception:  # noqa: BLE001
                    text = ""
                if len(text) > 30:
                    break
            if len(text) > 30:
                break
        if len(text) > 30:
            break

    if len(text) <= 30:
        try:
            r = _api(P_CHINFO, [["bookId", bid], ["chapterId", cid]], uid=CIUID)
            enc = ((r.get("data") or {}).get("chapter") or {}).get("content") or ""
            text = _ci_decode(enc)
        except Exception:  # noqa: BLE001
            text = ""

    if len(text) <= 30:
        raise RuntimeError("书旗：本章正文不可用（%s），可能需要登录或为付费章" % cid)

    paras = [p.strip().replace("\u3000", " ").strip()
             for p in text.replace("\r\n", "\n").split("\n")]
    paras = [p for p in paras if p]
    return {"title": "", "bookTitle": "", "paras": paras,
            "prev": "", "next": "", "url": url,
            "chars": sum(len(p) for p in paras),
            "bookId": PREFIX + bid, "source": "书旗"}


# ---------------------------------------------------------------- 发现 / 榜单

def _rank_rows(html):
    out = []
    for m in re.finditer(r'<li class="clearfix">([\s\S]*?)</li>', html):
        li = m.group(1)
        mb = re.search(r"/book/(\d+)\.html", li)
        if not mb:
            continue
        bid = mb.group(1)
        title = _plain((re.search(r"<h3>([\s\S]*?)</h3>", li) or ["", ""])[1])
        if not title:
            continue
        cover = (re.search(r'<img[^>]*src="([^"]+)"', li) or ["", ""])[1]
        author = _plain((re.search(
            r'class="bkuser-icon"[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)</a>', li) or ["", ""])[1])
        cate = _plain((re.search(r'class="bkcate-icon">([\s\S]*?)</span>', li) or ["", ""])[1])
        intro = _plain((re.search(r'class="ranklist-des">([\s\S]*?)</p>', li) or ["", ""])[1])
        tags = _plain((re.search(r'class="ranklist-tag">([\s\S]*?)</p>', li) or ["", ""])[1])
        out.append({
            "id": PREFIX + bid,
            "title": title,
            "author": author,
            "cover": cover,
            "intro": intro,
            "category": " · ".join([x for x in (cate, tags) if x]),
            "status": "", "words": "", "latest": "",
            "source": "书旗",
        })
    return out


def _store_rows(html):
    out, seen = [], set()
    for m in re.finditer(r"<li>([\s\S]*?)</li>", html):
        li = m.group(1)
        if "store-tag" not in li:
            continue
        mb = re.search(r"/book/(\d+)\.html", li)
        if not mb or mb.group(1) in seen:
            continue
        bid = mb.group(1)
        seen.add(bid)
        title = _plain((re.search(r"<h3[^>]*>([\s\S]*?)</h3>", li) or ["", ""])[1])
        if not title:
            continue
        cover = (re.search(r'<img[^>]*class="cover"[^>]*src="([^"]+)"', li)
                 or re.search(r'<img[^>]*src="([^"]+)"', li) or ["", ""])[1]
        author = _plain((re.search(
            r'class="store-tag[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)</a>', li) or ["", ""])[1])
        author = re.sub(r"^作者[：:]\s*", "", author)
        cate = _plain((re.search(
            r'class="store-tag[^>]*>[\s\S]*?<span>([\s\S]*?)</span>', li) or ["", ""])[1])
        intro = _plain((re.search(r'class="store-des">([\s\S]*?)</p>', li) or ["", ""])[1])
        out.append({
            "id": PREFIX + bid,
            "title": title,
            "author": author,
            "cover": cover,
            "intro": intro,
            "category": cate,
            "status": "", "words": "", "latest": "",
            "source": "书旗",
        })
    return out


def _max_page(html, pattern):
    nums = [int(n) for n in re.findall(pattern, html)]
    return max(nums) if nums else 1


def ranking(kind="boyClick", page=1):
    table = {k: name for k, name in RANKS}
    if kind not in table:
        kind = "boyClick"
    try:
        page = max(1, int(page or 1))
    except (TypeError, ValueError):
        page = 1
    html = _h5_get("%s/ranklist?rank=%s&page=%d" % (WEB, kind, page))
    if len(html) < 2000:
        raise RuntimeError("书旗榜单页没有返回内容")
    total = _max_page(html, r"rank=[A-Za-z]+(?:&amp;|&)page=(\d+)")
    books = _rank_rows(html)
    if page > total:
        fixed = ranking(kind, total)
        fixed["clamped"] = True
        return fixed
    for i, b in enumerate(books):
        b["rank"] = (page - 1) * 10 + i + 1
    return {"title": table[kind], "books": books, "page": page,
            "pages": total, "kind": kind, "note": "书旗官方榜单"}


def store(fc="", page=1, sz="", st="", word="", tm=""):
    try:
        page = max(1, int(page or 1))
    except (TypeError, ValueError):
        page = 1
    q = []
    if fc:
        q.append("fc=" + urllib.parse.quote(str(fc), safe=","))
    if sz:
        q.append("sz=" + str(sz))
    if st:
        q.append("st=" + str(st))
    if word:
        q.append("wd=" + str(word))
    if tm:
        q.append("tm=" + str(tm))
    path = "/store?" + "&".join(q + ["page=%d" % page])
    html = _h5_get(WEB + path)
    if len(html) < 2000:
        raise RuntimeError("书旗书库页没有返回内容")
    total = _max_page(html, r"page=(\d+)")
    books = _store_rows(html)
    if page > total:
        fixed = store(fc, total, sz, st, word, tm)
        fixed["clamped"] = True
        return fixed
    title = "书库"
    for cid, name in STORE_CATS:
        if cid == str(fc):
            title = name
            break
    return {"title": title, "books": books, "page": page, "pages": total}


def measure():
    """书源连通性自检：返回搜索、正文链路可用状态。"""
    out = {}
    try:
        t0 = time.time()
        d = search("凡人修仙传")
        out["search"] = {"ok": bool(d["books"]), "ms": int((time.time() - t0) * 1000),
                         "count": len(d["books"])}
    except Exception as e:  # noqa: BLE001
        out["search"] = {"ok": False, "error": str(e)[:120]}
    if out["search"].get("ok"):
        try:
            b = d["books"][0]
            chs = chapters(b["id"])
            c = chapter(chs[0]["u"])
            out["reader"] = {"ok": bool(c["paras"]), "chapters": len(chs),
                             "chars": c["chars"]}
        except Exception as e:  # noqa: BLE001
            out["reader"] = {"ok": False, "error": str(e)[:120]}
    return out
