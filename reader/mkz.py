"""漫客栈（mkzhan）漫画源。

站点有两套东西：网页负责搜索（HTML），内容全部走 comic.mkzcdn.com 的 JSON 接口
（详情 / 目录 / 每话图片列表）。图片是 content.mkzcdn.com 上的 CDN，地址里带
auth_key 签名、有时效，所以「图片列表」不能长期缓存，图片本体可以。

和小说源的区别都在数据形状上：章节没有正文段落，只有一串图片地址，
所以章节对象带 kind="comic" 和 pages，前端按这个分支去渲染。
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request

from . import core

SCHEME = "mkz://"
PREFIX = "mkz:"
SRC_NAME = "漫客栈"

WEB = "https://www.mkzhan.com"
API = "https://comic.mkzcdn.com"

# 图片每页宽 800 是站点自己给观看器的规格，流量和清晰度比较平衡
IMG_Q = "!page-800-x"

_UA = ("Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")


def is_mkz(v) -> bool:
    s = str(v or "")
    return s.startswith(PREFIX) or s.startswith(SCHEME)


def native_id(v) -> str:
    s = str(v or "")
    if s.startswith(PREFIX):
        s = s[len(PREFIX):]
    elif s.startswith(SCHEME):
        s = s[len(SCHEME):]
    return s.split("/")[0].strip()


def _book_id(v) -> str:
    bid = native_id(v)
    if not bid.isdigit():
        raise RuntimeError("漫画地址不合法")
    return bid


def _http(url, timeout=12):
    """本站不能走 core.http_get —— 那个会把域名归一成速读谷，这里直接发请求。"""
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
        if 400 <= e.code < 500:
            raise RuntimeError("漫画站点拒绝了请求（HTTP %d）" % e.code) from None
        raise RuntimeError("漫画站点出错了（HTTP %d）" % e.code) from None
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("连不上漫画站点：%s" % e) from None


def _get(path, params=None, timeout=12):
    q = urllib.parse.urlencode(params or {})
    raw = _http(API + path + ("?" + q if q else ""), timeout=timeout)
    try:
        data = json.loads(raw)
    except ValueError:
        raise RuntimeError("漫画接口返回的不是 JSON") from None
    if str(data.get("code")) != "200":
        raise RuntimeError(data.get("message") or "漫画接口出错了")
    return data.get("data")


def _clean(s) -> str:
    s = re.sub(r"<[^>]+>", " ", str(s or ""))
    s = s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&quot;", '"')
    return re.sub(r"\s+", " ", s).strip()


def _img(u) -> str:
    """接口给的图片地址统一补上尺寸后缀（已经带了就不重复加）。"""
    u = str(u or "").replace("\\/", "/").strip()
    if not u:
        return ""
    if "!" in u:
        return u
    return u + IMG_Q


# ---------------------------------------------------------------- 搜索 / 详情

_URL_ID = re.compile(r"(?:mkzhan\.com|mkzcdn\.com)/(?:comic/)?(\d{4,8})", re.I)


def _author_name(author_id) -> str:
    """详情接口只给 author_id，作者名要单查一次；失败就当佚名，不影响看书。"""
    aid = str(author_id or "").strip()
    if not aid:
        return ""
    try:
        d = _get("/author/info/", {"author_id": aid}) or {}
        return _clean(d.get("title"))
    except Exception:  # noqa: BLE001
        return ""


def probe(text):
    """从链接或纯 ID 里认出作品。

    站上的搜索、分类、排行接口都要登录签名（uid + sign），只放开了详情 / 目录 /
    每话图片这几个阅读必需的接口。所以这里不做关键词搜索：用户在浏览器里找到
    作品，把地址粘进来即可。
    """
    s = str(text or "").strip()
    m = _URL_ID.search(s)
    bid = m.group(1) if m else ""
    if not bid and is_mkz(s):
        nid = native_id(s)
        bid = nid if nid.isdigit() else ""
    if not bid and re.fullmatch(r"\d{4,8}", s):
        bid = s
    if not bid:
        raise RuntimeError("请粘贴漫客栈的作品链接，例如 https://www.mkzhan.com/217087/")
    return book(PREFIX + bid)


def chapters(bid):
    data = _get("/chapter/v1/", {"comic_id": _book_id(bid)})
    rows = data if isinstance(data, list) else (data or {}).get("list") or []
    out = []
    for c in rows:
        cid = str(c.get("chapter_id") or "")
        if not cid:
            continue
        t = _clean(c.get("title")) or ("第%s话" % (c.get("number") or ""))
        out.append({
            "t": t,
            "u": "%s%s/%s" % (SCHEME, _book_id(bid), cid),
            "i": len(out),
            "vip": str(c.get("is_vip") or "0") == "1",
        })
    # 接口基本是正序，但仍按话号兜一次底，免得个别作品倒着排
    def num(item):
        m = re.search(r"(\d+(?:\.\d+)?)", item["t"])
        return float(m.group(1)) if m else 0.0
    if len(out) > 2 and num(out[0]) > num(out[-1]):
        out.sort(key=num)
        for i, item in enumerate(out):
            item["i"] = i
    return out


def book(book_or_id):
    """书籍详情，返回结构与 core.book() 对齐，额外带 kind / unit。"""
    bid = _book_id(book_or_id)
    info = _get("/comic/info/", {"comic_id": bid}) or {}
    if not info.get("title"):
        raise RuntimeError("漫客栈没有返回这本漫画的信息")
    chs = chapters(bid)
    if not chs:
        raise RuntimeError("这本漫画还没有可读的章节")
    finished = str(info.get("finish") or "0") == "1"
    return {
        "id": PREFIX + bid,
        "title": _clean(info.get("title")),
        "author": _author_name(info.get("author_id")) or "漫客栈",
        "cover": _img(info.get("cover")),
        "intro": _clean(info.get("content")) or "这本漫画还没有简介。",
        "category": "漫画",
        "status": ("已完结 · %d 话" % len(chs)) if finished else ("连载中 · %d 话" % len(chs)),
        "updated": str(info.get("chapter_start_time") or ""),
        "lastChapter": _clean(info.get("chapter_title")),
        "url": SCHEME + bid,
        "chapters": [{"t": c["t"], "u": c["u"]} for c in chs],
        "count": len(chs),
        "source": SRC_NAME,
        "kind": "comic",
        "unit": "话",
    }


# ---------------------------------------------------------------- 每话图片

def chapter(url):
    """一话 = 一组图片。返回 kind=comic，前端据此走漫画渲染。"""
    parts = [p for p in str(url or "").replace(SCHEME, "").split("/") if p]
    if len(parts) < 2 or not parts[0].isdigit():
        raise RuntimeError("漫画章节地址不合法")
    bid, cid = parts[0], parts[1]

    data = _get("/chapter/content/v1/", {
        "chapter_id": cid, "comic_id": bid,
        "quality": 1, "type": 1, "format": 1})
    pages = [_img(p.get("image")) for p in (data or {}).get("page") or []]
    pages = [p for p in pages if p]
    if not pages:
        body = (data or {}).get("read_card") or {}
        if body:
            raise RuntimeError("这一话需要阅读券或付费才能看")
        raise RuntimeError("这一话没有取到图片，可能已下架")

    # 上下话从目录里找，比从页面猜链接可靠
    title, prev_u, next_u = "", "", ""
    try:
        chs = chapters(bid)
        idx = next((i for i, c in enumerate(chs) if c["u"].endswith("/" + cid)), -1)
        if idx >= 0:
            title = chs[idx]["t"]
            if idx > 0:
                prev_u = chs[idx - 1]["u"]
            if idx + 1 < len(chs):
                next_u = chs[idx + 1]["u"]
    except Exception:  # noqa: BLE001
        pass

    return {"title": title or ("第%s话" % cid), "bookId": PREFIX + bid,
            "kind": "comic", "pages": pages, "url": str(url),
            "prev": prev_u, "next": next_u, "chars": 0}


def page_bytes(url, timeout=20):
    """单页图片：CDN 直连，返回 (bytes, content-type)。"""
    blob, ctype = core.http_get_bytes(url, timeout=timeout)
    if not blob:
        raise RuntimeError("图片没有下载下来")
    return blob, ctype or "image/jpeg"


# ---------------------------------------------------------------- 发现（榜单）
# 分类接口要登录签名（uid+sign），发现页只提供榜单中心 /top/ 的五张榜 + 最近更新。

RANKS = [
    ("popularity", "人气榜"), ("ascension", "上升榜"), ("collection", "收藏榜"),
    ("comment", "热评榜"), ("latest", "新作榜"), ("update", "最近更新"),
]


def _rank_page(path):
    """榜单页通用解析：三种卡片（top-list__box-item / top-list__item / common-comic-item）
    都带 封面链接 + 标题，多数带作者/简介/更新到。"""
    html = _http(WEB + path)
    books, seen = [], set()
    for chunk in re.split(r'<div class="(?:top-list__box-item|top-list__item|common-comic-item)', html)[1:]:
        am = re.search(r'<a class="cover" href="/(\d{3,8})/"[^>]*>', chunk)
        if not am:
            continue
        bid = am.group(1)
        if bid in seen:
            continue
        seen.add(bid)
        nm = re.search(r'<p class="comic_?_?title"><a[^>]*>(.*?)</a>', chunk, re.S)
        title = _clean(nm.group(1)) if nm else ""
        if not title:
            continue
        im = re.search(r'<img[^>]+data-src="([^"]+)"', chunk)
        au = re.search(r'作者：<a[^>]*>([^<]+)</a>', chunk)
        ft = re.search(r'<p class="comic-feature">(.*?)</p>', chunk, re.S)
        up = re.search(r'更至：<a[^>]*>([^<]+)</a>', chunk)
        rn = re.search(r'<span class="tag tag--?\d*">(\d+)</span>', chunk)
        books.append({
            "id": PREFIX + bid,
            "title": title,
            "author": _clean(au.group(1)) if au else "",
            "cover": (im.group(1) if im else ""),
            "url": SCHEME + bid,
            "category": "漫画",
            "intro": _clean(ft.group(1))[:120] if ft else "",
            "latest": _clean(up.group(1)) if up else "",
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
            "rank": int(rn.group(1)) if rn else len(books) + 1,
        })
    return books


def ranking(kind="popularity", page=1):
    kind = kind if kind in ("popularity", "ascension", "collection",
                            "comment", "latest", "update") else "popularity"
    path = "/update/" if kind == "update" else ("/top/%s/" % kind)
    books = _rank_page(path)
    # 榜单页一次给全（几十到一百多本），无翻页
    return {"title": dict(RANKS).get(kind, "排行"), "books": books,
            "page": 1, "pages": 1}
