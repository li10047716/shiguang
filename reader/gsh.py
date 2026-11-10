"""包子漫画 / G社漫画（manhuafree.com）漫画源。

站点是 Astro 静态页：搜索和详情能直接抓 HTML，但目录和每话内容要走两个第三方接口：
  - api-get-v3.mgsearcher.com/api/manga/get?mid=<mid>&mode=all  → 目录 + 作品信息
  - v2.apikk.top/api/v2/chapter/getinfo?m=<mid>&c=<章节id>       → 每话（图片是加密串）
两个接口只认数字 mid，而站点链接、搜索结果里都只有 slug（/manga/<slug>），
mid 只出现在详情页的 data-mid 上。所以书号用 slug，mid 现抓详情页并记下来。

每话的图片地址不是明文，是一段带标记的混淆串：截掉前后缀、按位置切三段重排、
每 7 个字符奇数段反转、再做一次 64 字符表映射，最后 base64 解出 JSON 数组。
算法本身是固定的，没有密钥，照着搬过来就行。
"""

from __future__ import annotations

import base64
import json
import os
import re
import threading
import urllib.error
import urllib.parse
import urllib.request

from . import core

SCHEME = "gs://"
PREFIX = "gs:"
SRC_NAME = "包子漫画"

WEB = "https://manhuafree.com"
TOC_API = "https://api-get-v3.mgsearcher.com"
CH_API = "https://v2.apikk.top"

# 图片 CDN：解出来的地址都是 /scomic/... 这种根路径，直接拼这条线
CDN = "https://t-nd2-1.6wm.top"

# 站点有多个镜像，认链接的时候都收
_HOSTS = ("manhuafree.com", "g-mh.org", "baozimh.org", "bzmh.org")

_UA = ("Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

# 解密用的两张 64 字符表（顺序不能动）
_MAP_SRC = "_-9876543210abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
_MAP_TGT = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
_STEP = 7


def is_gs(v) -> bool:
    s = str(v or "")
    return s.startswith(PREFIX) or s.startswith(SCHEME)


def native_id(v) -> str:
    s = str(v or "")
    if s.startswith(PREFIX):
        s = s[len(PREFIX):]
    elif s.startswith(SCHEME):
        s = s[len(SCHEME):]
    return s.split("/")[0].strip()


def _slug(v) -> str:
    s = native_id(v)
    if not s:
        raise RuntimeError("漫画地址不合法")
    # slug 只由小写字母数字和短横线组成，防止拼进 URL 时被注入
    if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{1,80}", s):
        raise RuntimeError("漫画地址不合法：%s" % s)
    return s


def looks_like(text) -> bool:
    """判断用户粘的地址是不是这个站的。"""
    s = str(text or "").strip().lower()
    if s.startswith(PREFIX):
        return True
    return any(h in s for h in _HOSTS)


# ---------------------------------------------------------------- 基础请求

def _http(url, timeout=15):
    req = urllib.request.Request(url, headers={
        "User-Agent": _UA,
        "Accept": "application/json, text/html, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Referer": WEB + "/",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise RuntimeError("这本漫画在站上找不到了（404）") from None
        raise RuntimeError("漫画站点出错了（HTTP %d）" % e.code) from None
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("连不上漫画站点：%s" % e) from None


def _json(url, timeout=15):
    raw = _http(url, timeout=timeout)
    try:
        data = json.loads(raw)
    except ValueError:
        raise RuntimeError("漫画接口返回的不是 JSON") from None
    if str(data.get("code")) != "200":
        raise RuntimeError(data.get("msg") or data.get("message") or "漫画接口出错了")
    return data.get("data") or {}


def _clean(s) -> str:
    s = re.sub(r"<[^>]+>", " ", str(s or ""))
    s = s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&quot;", '"')
    s = re.sub(r"[ \t]+", " ", s)
    return re.sub(r"\n{3,}", "\n\n", s).strip()


def _img(u) -> str:
    u = str(u or "").replace("\\/", "/").strip()
    if not u:
        return ""
    if u.startswith("http"):
        return u
    return CDN + (u if u.startswith("/") else "/" + u)


# ---------------------------------------------------------------- slug ⇄ mid

# 书名页上的 data-mid 是唯一出现 mid 的地方，抓到后记在内存 + 一个小文件里，
# 这样打开第二话时不用再拉一次详情页。
_MID = {}
_MID_LOCK = threading.Lock()
_MID_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "data", "cache", "gs_mid.json")


def _mid_load():
    if _MID:
        return
    try:
        with open(_MID_PATH, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            _MID.update({str(k): str(v) for k, v in data.items()})
    except Exception:  # noqa: BLE001
        pass


def _mid_save():
    try:
        os.makedirs(os.path.dirname(_MID_PATH), exist_ok=True)
        tmp = _MID_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(_MID, f)
        os.replace(tmp, _MID_PATH)
    except OSError:
        pass


def _parse_mid(html):
    m = re.search(r'data-mid="(\d+)"', html or "")
    return m.group(1) if m else ""


def _mid(slug):
    """slug → mid。先查记录，没有再抓详情页。"""
    slug = _slug(slug)
    _mid_load()
    with _MID_LOCK:
        hit = _MID.get(slug)
    if hit:
        return hit
    html = _http(WEB + "/manga/" + slug)
    mid = _parse_mid(html)
    if not mid:
        raise RuntimeError("这个漫画页面上找不到作品编号，可能已下架")
    with _MID_LOCK:
        _MID[slug] = mid
        _mid_save()
    return mid


# ---------------------------------------------------------------- 图片解密

def _decrypt(enc):
    """把接口给的混淆串还原成 [{"order":1,"url":"/scomic/..."}, ...]。"""
    s = str(enc or "").strip()
    if not (s.startswith("J7r") and s.endswith("nQ")):
        raise RuntimeError("漫画图片数据格式变了（前缀/后缀不对）")

    body = s[3:-2]
    total = len(body) - 2 - 3          # 中间还夹着 "kD" 和 "W4s" 两个标记
    cols = total // 3
    rem2 = (total - cols) // 2
    rest = total - cols - rem2

    a = body[:rem2]
    b = body[rem2:rem2 + 2]
    c = body[rem2 + 2:rem2 + 2 + rest]
    d = body[rem2 + 2 + rest:rem2 + 2 + rest + 3]
    e = body[rem2 + 2 + rest + 3:]
    if b != "kD" or d != "W4s" or len(e) != cols:
        raise RuntimeError("漫画图片数据格式变了（标记位不对）")

    joined = e + a + c
    parts = []
    for i in range(0, len(joined), _STEP):
        part = joined[i:i + _STEP]
        if (i // _STEP) % 2 == 1:      # 奇数段倒序
            part = part[::-1]
        parts.append(part)
    swapped = "".join(parts)

    try:
        mapped = "".join(_MAP_TGT[_MAP_SRC.index(ch)] for ch in swapped)
    except ValueError:
        raise RuntimeError("漫画图片数据格式变了（字符表对不上）") from None

    b64 = mapped.replace("-", "+").replace("_", "/")
    b64 += "=" * (-len(b64) % 4)
    try:
        raw = base64.b64decode(b64)
        rows = json.loads(raw)
    except Exception:  # noqa: BLE001
        raise RuntimeError("漫画图片数据解不开") from None
    if not isinstance(rows, list):
        raise RuntimeError("漫画图片数据格式不对")
    return rows


# ---------------------------------------------------------------- 搜索

_CARD_SPLIT = '<div class="pb-2"'

# 站上是繁体（連載中 / 已完結），跟界面其它地方统一成简体
_STATUS_FIX = (("連載", "连载"), ("已完結", "已完结"), ("完結", "完结"))


def search(keyword, page=1):
    keyword = (keyword or "").strip()
    if not keyword:
        return {"books": [], "msg": ""}
    page = max(1, int(page or 1))
    url = "%s/s/%s?page=%d" % (WEB, urllib.parse.quote(keyword), page)
    html = _http(url)

    total = 0
    tm = re.search(r"總數[:：]\s*<span[^>]*>(\d+)</span>", html)
    if tm:
        total = int(tm.group(1))

    books = []
    seen = set()
    for chunk in html.split(_CARD_SPLIT)[1:]:
        am = re.search(r'<a href="(/manga/[^"]+)"', chunk)
        if not am:
            continue
        slug = am.group(1).rstrip("/").split("/")[-1]
        if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{1,80}", slug) or slug in seen:
            continue
        tm2 = re.search(r'class="cardtitle"[^>]*>(.*?)</h3>', chunk, re.S)
        title = _clean(tm2.group(1)) if tm2 else ""
        if not title:
            continue
        seen.add(slug)
        im = re.search(r'<img[^>]+src="([^"]+)"', chunk)
        books.append({
            "id": PREFIX + slug,
            "title": title,
            "author": "",
            "cover": (im.group(1) if im else ""),
            "url": SCHEME + slug,
            "category": "漫画",
            "intro": "",
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
        })

    msg = ""
    if not books and total:
        msg = "%s：这一页没有结果（共 %d 本）" % (SRC_NAME, total)
    return {"books": books, "msg": msg, "total": total}


# ---------------------------------------------------------------- 详情 / 目录

def _page_meta(html):
    """从详情页扒书名、作者、状态、分类、标签（接口里没有这些）。"""
    meta = {"title": "", "author": "", "status": "", "kinds": [], "tags": []}
    h1 = re.search(r"<h1[^>]*text-xl[^>]*>(.*?)</h1>", html or "", re.S)
    if h1:
        inner = h1.group(1)
        meta["title"] = _clean(inner.split("<span")[0])
        bm = re.search(r"<span[^>]*>[^<]*?(連載|连载|已完結|已完结|休刊)[^<]*</span>", inner)
        if bm:
            s = _clean(bm.group(0))
            for a, b in _STATUS_FIX:
                s = s.replace(a, b)
            meta["status"] = s
    am = re.search(r"作者：\s*</span>\s*<a[^>]*>\s*<span>\s*([^<]+?)\s*</span>", html or "", re.S)
    if am:
        meta["author"] = _clean(am.group(1))
    km = re.search(r"類型：\s*</span>(.*?)</div>", html or "", re.S)
    if km:
        meta["kinds"] = [_clean(x) for x in re.findall(r"<span>\s*([^<]+?)\s*</span>", km.group(1))]
        meta["kinds"] = [x.strip(" ,，") for x in meta["kinds"] if x.strip(" ,，")]
    meta["tags"] = [_clean(x) for x in re.findall(
        r'<a href="/manga-tag/[^"]*"><span[^>]*>\s*#([^<]+?)\s*</span>', html or "")]
    return meta


def _toc(mid):
    return _json("%s/api/manga/get?mid=%s&mode=all" % (TOC_API, mid), timeout=20)


def chapters(slug):
    data = _toc(_mid(slug))
    rows = data.get("chapters") or []
    out = []
    for c in rows:
        cid = str(c.get("id") or "")
        attr = c.get("attributes") or {}
        if not cid:
            continue
        out.append({
            "t": _clean(attr.get("title")) or ("第%s话" % (len(out) + 1)),
            "u": "%s%s/%s" % (SCHEME, _slug(slug), cid),
            "i": len(out),
            "order": attr.get("order") or 0,
        })
    # 接口正常按 order 给，但个别作品是倒序，统一按 order 排一次（稳定排序，不打乱番外）
    if any(c["order"] for c in out):
        out.sort(key=lambda c: (c["order"], c["i"]))
        for i, c in enumerate(out):
            c["i"] = i
    return out


def book(slug_or_id):
    """书籍详情，结构与 core.book() 对齐，额外带 kind / unit。"""
    slug = _slug(slug_or_id)
    html = _http(WEB + "/manga/" + slug)
    meta = _page_meta(html)
    mid = _parse_mid(html)
    if not mid:
        raise RuntimeError("这个漫画页面上找不到作品编号，可能已下架")
    with _MID_LOCK:
        if _MID.get(slug) != mid:
            _MID[slug] = mid
            _mid_save()

    data = _toc(mid)
    chs = chapters(slug)
    if not chs:
        raise RuntimeError("这本漫画还没有可读的章节")

    title = _clean(data.get("title")) or meta["title"]
    status = meta["status"] or "连载中"
    kinds = "、".join(meta["kinds"]) or "漫画"
    tags = " ".join("#" + t for t in meta["tags"][:6])
    intro = _clean(data.get("desc")) or "这本漫画还没有简介。"
    if tags:
        intro = ("%s\n\n%s" % (tags, intro)) if intro else tags

    last = _clean((data.get("chapters") or [{}])[-1].get("attributes", {}).get("title"))
    updated = str(((data.get("chapters") or [{}])[-1].get("attributes") or {}).get("updatedAt") or "")
    return {
        "id": PREFIX + slug,
        "title": title,
        "author": meta["author"] or SRC_NAME,
        "cover": _img(data.get("cover") or ""),
        "intro": intro,
        "category": kinds,
        "status": "%s · %d 话" % (status, len(chs)),
        "updated": updated[:10],
        "lastChapter": last,
        "url": SCHEME + slug,
        "chapters": [{"t": c["t"], "u": c["u"]} for c in chs],
        "count": len(chs),
        "source": SRC_NAME,
        "kind": "comic",
        "unit": "话",
    }


def probe(text):
    """从链接 / gs:slug / 纯 slug 认出作品。"""
    s = str(text or "").strip()
    m = re.search(r"/manga/([a-z0-9][a-z0-9\-]{1,80})", s, re.I)
    slug = m.group(1).lower() if m else ""
    if not slug and is_gs(s):
        cand = native_id(s)
        slug = cand if re.fullmatch(r"[a-z0-9][a-z0-9\-]{1,80}", cand) else ""
    if not slug and re.fullmatch(r"[a-z0-9][a-z0-9\-]{3,80}", s, re.I):
        slug = s.lower()
    if not slug:
        raise RuntimeError("请粘贴包子漫画的作品链接，例如 %s/manga/<作品slug>" % WEB)
    return book(PREFIX + slug)


# ---------------------------------------------------------------- 每话图片

def chapter(url):
    """一话 = 一组图片。返回 kind=comic，前端据此走漫画渲染。"""
    raw = str(url or "").replace(SCHEME, "")
    parts = [p for p in raw.split("/") if p]
    if len(parts) < 2 or not parts[1].isdigit():
        raise RuntimeError("漫画章节地址不合法")
    slug, cid = _slug(parts[0]), parts[1]

    data = _json("%s/api/v2/chapter/getinfo?m=%s&c=%s" % (CH_API, _mid(slug), cid),
                 timeout=20)
    info = data.get("info") or {}
    rows = _decrypt((info.get("images") or {}).get("images"))
    rows = sorted(rows, key=lambda x: x.get("order") or 0)
    pages = [_img(r.get("url")) for r in rows]
    pages = [p for p in pages if p]
    if not pages:
        raise RuntimeError("这一话没有取到图片，可能已下架或需要付费")

    def link(cid2):
        return ("%s%s/%s" % (SCHEME, slug, cid2)) if str(cid2 or "").isdigit() else ""

    return {
        "title": _clean(info.get("title")) or ("第 %s 话" % (info.get("order") or cid)),
        "bookId": PREFIX + slug,
        "kind": "comic",
        "pages": pages,
        "url": str(url),
        "prev": link(info.get("pre")),
        "next": link(info.get("next")),
        "chars": 0,
    }


def page_bytes(url, timeout=20):
    """单页图片：CDN 直连，返回 (bytes, content-type)。"""
    blob, ctype = core.http_get_bytes(url, timeout=timeout)
    if not blob:
        raise RuntimeError("图片没有下载下来")
    return blob, ctype or "image/webp"


# ---------------------------------------------------------------- 发现（榜单 / 分类）

RANKS = [("hots", "人气推荐"), ("dayup", "热门更新"), ("newss", "最新上架")]
CATS = [("manga", "全部类型")]


def _list_page(path, page, rank_base=0):
    """manhuafree 列表页通用解析（/hots /dayup /newss /manga，/page/N 翻页）。"""
    page = max(1, int(page or 1))
    url = "%s%s/page/%d" % (WEB, path, page) if page > 1 else WEB + path
    html = _http(url)
    books, seen = [], set()
    for chunk in html.split(_CARD_SPLIT)[1:]:
        am = re.search(r'<a href="(/manga/[^"]+)"', chunk)
        if not am:
            continue
        slug = am.group(1).rstrip("/").split("/")[-1]
        if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{1,80}", slug) or slug in seen:
            continue
        tm = re.search(r'class="cardtitle"[^>]*>(.*?)</h3>', chunk, re.S)
        title = _clean(tm.group(1)) if tm else ""
        if not title:
            continue
        seen.add(slug)
        im = re.search(r'<img[^>]+src="([^"]+)"', chunk)
        books.append({
            "id": PREFIX + slug,
            "title": title,
            "author": "",
            "cover": (im.group(1) if im else ""),
            "url": SCHEME + slug,
            "category": "漫画",
            "intro": "",
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
            "rank": rank_base + len(books) + 1,
        })
    pages = 1
    for pm in re.finditer(r'href="%s/page/(\d+)"' % re.escape(path), html):
        pages = max(pages, int(pm.group(1)))
    pages = min(pages, 200)
    if page > pages:
        fixed = _list_page(path, pages)
        fixed["clamped"] = True
        return fixed
    return {"title": "%s · 第 %d 页" % (path.strip("/") or "全部类型", page),
            "books": books, "page": page, "pages": max(1, pages)}


def ranking(kind="hots", page=1):
    kind = kind if kind in ("hots", "dayup", "newss") else "hots"
    return _list_page("/" + kind, page)


def category(cid="manga", page=1):
    # 站点没有子分类，/manga 就是全库列表
    return _list_page("/manga", page)
