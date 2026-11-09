"""
七猫（wtzw.com）书源客户端。

签名规则与正文解密方式来自用户提供的「阅读」书源（七猫.json）：
  - 请求头与查询参数都要 md5(按 key 排序拼 "k=v" + sign_key)
  - 正文是 Base64(IV[16] + AES-128-CBC(PKCS7))，key 固定

只用标准库；AES 由 reader/aes.py 提供。
"""
import base64
import hashlib
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from . import aes

API = "https://api-bc.wtzw.com"
API_KS = "https://api-ks.wtzw.com"
WEB = "https://www.qimao.com"
SIGN_KEY = "d3dGiJc651gSQ8w1"
AES_KEY = b"242ccb8230d709e1"
UA = "okhttp/4.9.0"
WEB_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

BASE_HEADERS = {
    "app-version": "77800",
    "platform": "android",
    "reg": "0",
    "AUTHORIZATION": "",
    "application-id": "com.****.reader",
    "net-env": "1",
    "channel": "unknown",
    "qm-params": "",
}

PREFIX = "qm:"
SCHEME = "qm://"


def is_qm(value):
    v = (value or "").strip()
    return v.startswith(PREFIX) or v.startswith(SCHEME)


def native_id(value):
    v = (value or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):].split("/")[0]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    return v


# ---------------------------------------------------------------- 网络

def _sign(params):
    raw = "".join("%s=%s" % (k, params[k]) for k in sorted(params)) + SIGN_KEY
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def _get(base, path, params, timeout=15, retries=1):
    p = {k: v for k, v in params.items() if v is not None}
    p["sign"] = _sign(p)
    url = "%s%s?%s" % (base, path, urllib.parse.urlencode(p))
    headers = dict(BASE_HEADERS)
    headers["sign"] = _sign(BASE_HEADERS)
    headers["User-Agent"] = UA
    headers["Accept"] = "application/json"
    err = None
    for i in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "ignore"))
        except urllib.error.HTTPError as e:
            if 400 <= e.code < 500:
                raise RuntimeError("七猫接口返回 HTTP %d" % e.code)
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i < retries:
            time.sleep(0.4 * (i + 1))
    raise RuntimeError("七猫接口请求失败：%s" % err)


def _web_get(path, params, timeout=20, retries=1):
    """七猫网页版接口（www.qimao.com/api/...），不需要 App 签名。"""
    url = "%s%s?%s" % (WEB, path, urllib.parse.urlencode(params))
    headers = {
        "User-Agent": WEB_UA,
        "Referer": WEB + "/paihang/",
        "Accept": "application/json, text/plain, */*",
    }
    err = None
    for i in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "ignore"))
        except urllib.error.HTTPError as e:
            if 400 <= e.code < 500:
                raise RuntimeError("七猫榜单接口返回 HTTP %d" % e.code)
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i < retries:
            time.sleep(0.4 * (i + 1))
    raise RuntimeError("七猫榜单请求失败：%s" % err)


def _data(resp, *path):
    cur = resp
    for k in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def _decrypt(blob):
    raw = base64.b64decode(blob)
    if len(raw) < 32:
        return ""
    return aes.pkcs7_unpad(
        aes.cbc_decrypt(AES_KEY, raw[:16], raw[16:])).decode("utf-8", "ignore")


# ---------------------------------------------------------------- 文本

_TAG = re.compile(r"<[^>]+>")


def _plain(s):
    return _TAG.sub("", s or "").replace("\u3000", " ").strip()


def _words(n):
    try:
        w = int(n)
    except (TypeError, ValueError):
        return ""
    if w >= 10000:
        return "%.1f 万字" % (w / 10000.0)
    return "%d 字" % w


def _book_id(bid):
    bid = str(bid or "").strip()
    if not bid:
        raise RuntimeError("缺少七猫书籍 id")
    return bid


# ---------------------------------------------------------------- 对外接口

EXPLORE_CATS = [
    {"id": "203", "name": "都市"},
    {"id": "219", "name": "都市高武"},
    {"id": "202", "name": "玄幻奇幻"},
    {"id": "205", "name": "武侠仙侠"},
    {"id": "204", "name": "奇闻异事"},
    {"id": "56", "name": "历史"},
    {"id": "75", "name": "游戏"},
    {"id": "64", "name": "科幻"},
]

# 网页榜单：rank_type 是七猫自己的枚举，1 热榜 / 2 新书 / 3 完结 / 4 收藏 / 6 更新
RANK_TYPES = [
    ("hot", "1", "大热榜"),
    ("new", "2", "新书榜"),
    ("over", "3", "完结榜"),
    ("collect", "4", "收藏榜"),
    ("update", "6", "更新榜"),
]


def explore(category_id="205", page=1):
    """分类浏览（男生频道）。"""
    cid = str(category_id or "205")
    try:
        page = max(1, int(page or 1))
    except (TypeError, ValueError):
        page = 1
    resp = _get(API, "/api/v4/category/get-list", {
        "gender": "2", "category_id": cid, "need_filters": 1,
        "page": page, "need_category": 1})
    data = _data(resp, "data") or {}
    books = []
    for b in data.get("books") or []:
        bid = str(b.get("id") or "")
        if not bid:
            continue
        books.append({
            "id": PREFIX + bid,
            "title": _plain(b.get("title")),
            "author": b.get("author") or "",
            "cover": b.get("image_link") or "",
            "intro": _plain(b.get("intro"))[:120],
            "category": (b.get("ptags") or "").split(",")[0],
            "status": "",
            "words": _words(b.get("words_num")),
            "score": b.get("score") or "",
            "source": "七猫",
        })
    meta = data.get("meta") or {}
    try:
        pages = int(meta.get("total_pages") or 1)
    except (TypeError, ValueError):
        pages = 1
    if page > pages:
        fixed = explore(cid, pages)
        fixed["clamped"] = True
        return fixed
    return {"title": data.get("title") or "七猫", "books": books,
            "page": page, "pages": max(1, pages), "cats": EXPLORE_CATS}


def ranking(kind="hot", page=1):
    """七猫网页排行榜，返回结构与 core.ranking() 对齐。

    网页接口每页 20 本、共 100 本，够用；书籍 id 与 App 接口一致，
    所以点进去照样能看目录和正文。
    """
    table = {k: (rt, name) for k, rt, name in RANK_TYPES}
    if kind not in table:
        kind = "hot"
    rt, name = table[kind]
    try:
        page = max(1, int(page or 1))
    except (TypeError, ValueError):
        page = 1

    resp = _web_get("/api/rank/book-list", {
        "is_girl": "0", "rank_type": rt, "date_type": "1", "page": page})
    data = resp.get("data") or {}
    rows = data.get("table_data") or []
    meta = data.get("page_data") or {}

    def _int(v, d=0):
        try:
            return int(v)
        except (TypeError, ValueError):
            return d

    total = _int(meta.get("count"), 0)
    size = max(1, _int(meta.get("page_size"), 20))
    pages = max(1, (total + size - 1) // size)
    if page > pages:
        fixed = ranking(kind, pages)
        fixed["clamped"] = True
        return fixed

    books = []
    for i, b in enumerate(rows):
        bid = str(b.get("book_id") or "")
        if not bid:
            continue
        cat = " · ".join([c for c in (b.get("category1_name"),
                                      b.get("category2_name")) if c])
        # 各榜的 number/unit 含义不同：热榜是热度、收藏榜是收藏数、更新榜是字数
        num = str(b.get("number") or "")
        if kind == "collect":
            try:
                n = int(num)
                heat = ("%.1f 万" % (n / 10000.0)) if n >= 10000 else str(n)
            except (TypeError, ValueError):
                heat = num
            heat_label = "收藏"
        elif kind == "update":
            heat = re.sub(r"字更新$", " 字", num).strip()
            heat_label = "更新"
        else:
            heat = "%s%s" % (num, b.get("unit") or "")
            heat_label = "热度"
        books.append({
            "id": PREFIX + bid,
            "rank": (page - 1) * size + i + 1,
            "title": b.get("title") or "",
            "author": b.get("author") or "",
            "cover": b.get("image_link") or "",
            "intro": _plain(b.get("intro")),
            "category": cat,
            "status": "已完结" if str(b.get("is_over") or "") == "1" else "连载中",
            "latest": b.get("latest_chapter_title") or "",
            "words": b.get("words_num") or "",
            "heat": heat,
            "heatLabel": heat_label,
            "source": "七猫",
        })

    month = meta.get("data_month") or ""
    note = "七猫官方榜单" + (" · 统计月份 %s" % month if month else "")
    return {"title": name, "books": books, "page": page,
            "pages": pages, "kind": kind, "note": note}


def search(keyword, page=1):
    keyword = (keyword or "").strip()
    if not keyword:
        return {"books": [], "pages": 1, "total": 0}
    try:
        page = max(1, int(page or 1))
    except (TypeError, ValueError):
        page = 1
    resp = _get(API, "/api/v5/search/words", {
        "gender": "3", "imei_ip": "2937357107", "page": page, "wd": keyword})
    data = _data(resp, "data") or {}
    books = []
    for b in data.get("books") or []:
        bid = str(b.get("id") or "")
        if not bid:
            continue
        books.append({
            "id": PREFIX + bid,
            "title": _plain(b.get("original_title") or b.get("title")),
            "author": _plain(b.get("original_author") or b.get("author")),
            "cover": b.get("image_link") or "",
            "intro": _plain(b.get("intro")),
            "category": (b.get("ptags") or "").split(",")[0],
            "status": "已完结" if str(b.get("is_over", "")) in ("1", "True") else "",
            "words": _words(b.get("words_num")),
            "score": b.get("score") or "",
            "source": "七猫",
        })
    meta = data.get("meta") or {}
    try:
        pages = int(meta.get("total_page") or 1)
    except (TypeError, ValueError):
        pages = 1
    return {"books": books, "pages": max(1, pages), "page": page, "total": pages}


def chapters(bid):
    bid = _book_id(bid)
    resp = _get(API_KS, "/api/v1/chapter/chapter-list", {"id": bid}, timeout=20)
    lst = _data(resp, "data", "chapter_lists") or []
    out = []
    for c in lst:
        cid = str(c.get("id") or "")
        if not cid:
            continue
        out.append({"t": (c.get("title") or "").strip(),
                    "u": "%s%s/%s" % (SCHEME, bid, cid)})
    return out


def book(book_id):
    """书籍详情，返回结构与 core.book() 对齐。"""
    bid = native_id(book_id)
    bid = _book_id(bid)
    resp = _get(API, "/api/v4/book/detail", {
        "id": bid, "imei_ip": "2937357107", "teeny_mode": 0})
    b = _data(resp, "data", "book") or {}
    if not b.get("title"):
        raise RuntimeError("七猫没有返回这本书的信息")

    tags = []
    for t in b.get("book_tag_list") or []:
        title = (t or {}).get("title")
        if title:
            tags.append(title)

    categories = [c for c in (b.get("category1_name"), b.get("category2_name")) if c]
    chapters_ = chapters(bid)
    status = "已完结" if str(b.get("is_over", "")) in ("1", "True") else "连载中"
    return {
        "id": PREFIX + bid,
        "title": b.get("title") or "",
        "author": b.get("author") or "",
        "cover": b.get("image_link") or "",
        "category": " · ".join(categories) or (tags[0] if tags else ""),
        "status": status,
        "intro": _plain(b.get("intro")),
        "updated": str(b.get("update_time") or ""),
        "url": SCHEME + bid,
        "chapters": chapters_,
        "count": len(chapters_),
        "words": _words(b.get("words_num")),
        "latest": b.get("latest_chapter_title") or "",
        "tags": tags[:6],
        "publisher": b.get("source") or "",
        "statement": _plain(b.get("statement")),
        "source": "七猫",
    }


def chapter(url):
    """正文，返回结构与 core.chapter() 对齐。"""
    v = (url or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    parts = [p for p in v.split("/") if p]
    if len(parts) < 2:
        raise RuntimeError("七猫章节地址不对：%s" % url)
    bid, cid = parts[0], parts[1]

    resp = _get(API_KS, "/api/v1/chapter/content",
                {"id": bid, "chapterId": cid}, timeout=20)
    data = _data(resp, "data") or {}
    blob = data.get("content") or ""
    if not blob:
        msg = resp.get("msg") or "这一章没有取到内容（可能需要会员）"
        raise RuntimeError(msg)
    text = _decrypt(blob)
    paras = [p.strip() for p in text.replace("\r\n", "\n").split("\n") if p.strip()]
    return {"title": "", "bookTitle": "",
            "paras": paras, "prev": "", "next": "", "url": url,
            "chars": sum(len(p) for p in paras), "bookId": PREFIX + bid,
            "source": "七猫"}
