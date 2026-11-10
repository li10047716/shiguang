"""大人漫画（drmh3.com / drmh2.com）漫画源。

纯 HTML 抓取：搜索、详情、目录、每话图片全部从网页解析，没有第三方接口。
站点 baseurl 是 drmh3.com（书源里写的 drmh2.com 会 301 跳到 drmh3.com，
两个都认）。图片放在 *.18rouman.vip 上，必须带 Referer: https://drmh3.com/
才能取到（防盗链），所以 page_bytes 不走通用下载，单独发请求。

页面结构（实测）：
  - 搜索：/cata.php?key=<kw> 的 <li class="hl-list-item"> 卡片
  - 详情：/comics-reading/<id>.html，标题 .hl-dc-title，封面 .hl-dc-pic .hl-item-thumb[data-original]
  - 目录：同详情页里的 #hl-plays-list li a -> /comics-reading/<id>/<slug>.html
  - 正文：/comics-reading/<id>/<slug>.html 的 img[data-original]
"""

from __future__ import annotations

import re
import threading
import urllib.error
import urllib.parse
import urllib.request

from . import core

SCHEME = "dr://"
PREFIX = "dr:"
SRC_NAME = "大人漫画"

WEB = "https://drmh3.com"

_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# 认链接只认站点域名，不认图片 CDN（避免粘到图片地址被误判成书）
_HOSTS = ("drmh3.com", "drmh2.com")

_MID_LOCK = threading.Lock()


def is_dr(v) -> bool:
    s = str(v or "")
    return s.startswith(PREFIX) or s.startswith(SCHEME)


def native_id(v) -> str:
    s = str(v or "")
    # 先判 SCHEME（dr://…）再判 PREFIX（dr:…），否则 "dr://37156" 会被 PREFIX 截掉 3 个字符
    if s.startswith(SCHEME):
        s = s[len(SCHEME):]
    elif s.startswith(PREFIX):
        s = s[len(PREFIX):]
    return s.split("/")[0].strip()


def _cid(v) -> str:
    s = native_id(v)
    if not re.fullmatch(r"\d{2,8}", s):
        raise RuntimeError("漫画地址不合法：%s" % s)
    return s


def looks_like(text) -> bool:
    """判断用户粘的地址是不是这个站的。"""
    s = str(text or "").strip().lower()
    if s.startswith(PREFIX) or s.startswith(SCHEME):
        return True
    return any(h in s for h in _HOSTS)


# ---------------------------------------------------------------- 基础请求

def _http(url, timeout=15):
    req = urllib.request.Request(url, headers={
        "User-Agent": _UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Referer": WEB + "/",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            enc = "utf-8"
            m = re.search(r"charset=([\w-]+)", r.headers.get("Content-Type", ""), re.I)
            if m:
                enc = m.group(1).lower()
            if enc in ("gbk", "gb2312", "gb18030"):
                enc = "gb18030"
            return raw.decode(enc, "ignore")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise RuntimeError("这本漫画在站上找不到了（404）") from None
        raise RuntimeError("漫画站点出错了（HTTP %d）" % e.code) from None
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("连不上漫画站点：%s" % e) from None


def _clean(s) -> str:
    s = re.sub(r"<[^>]+>", " ", str(s or ""))
    s = s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&quot;", '"')
    return re.sub(r"\s+", " ", s).strip()


# ---------------------------------------------------------------- 搜索

def search(keyword, page=1):
    keyword = (keyword or "").strip()
    if not keyword:
        return {"books": [], "msg": ""}
    page = max(1, int(page or 1))
    url = "%s/cata.php?key=%s" % (WEB, urllib.parse.quote(keyword))
    try:
        html = _http(url)
    except Exception as e:  # noqa: BLE001
        return {"books": [], "msg": str(e)}

    books, seen = [], set()
    for block in re.finditer(r'<li class="hl-list-item[^"]*">(.*?)</li>', html, re.S):
        chunk = block.group(1)
        href = title = cover = ""
        am = re.search(
            r'<a class="hl-item-thumb[^"]*" href="([^"]+)"[^>]*title="([^"]*)"'
            r'[^>]*data-original="([^"]*)"', chunk)
        if am:
            href, title, cover = am.group(1), am.group(2), am.group(3)
        else:
            am2 = re.search(r'<a[^>]*href="(/comics-reading/[^"]+)"[^>]*>', chunk)
            if not am2:
                continue
            href = am2.group(1)
            tm = re.search(r'title="([^"]*)"', chunk)
            title = tm.group(1) if tm else ""
            cm = re.search(r'data-original="([^"]+)"', chunk)
            cover = cm.group(1) if cm else ""
        mid = re.search(r"/comics-reading/(\d+)", href or "")
        if not mid:
            continue
        cid = mid.group(1)
        if cid in seen:
            continue
        if not title:
            tm = re.search(r'class="hl-item-title[^"]*"[^>]*>(.*?)</', chunk, re.S)
            title = _clean(tm.group(1)) if tm else ""
        if not title:
            continue
        seen.add(cid)
        books.append({
            "id": PREFIX + cid,
            "title": title,
            "author": "",
            "cover": cover,
            "url": SCHEME + cid,
            "category": "漫画",
            "intro": "",
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
        })

    msg = "" if books else "没有找到相关漫画"
    return {"books": books, "msg": msg}


# ---------------------------------------------------------------- 详情 / 目录

def _page_meta(html):
    meta = {"title": "", "cover": "", "kinds": [], "status": "", "intro": ""}

    tm = re.search(r'class="hl-dc-title[^"]*"[^>]*>(.*?)</', html, re.S)
    if tm:
        meta["title"] = _clean(tm.group(1))
    if not meta["title"]:
        tm = re.search(r"<title>(.*?)</title>", html, re.S)
        meta["title"] = _clean(tm.group(1)).split("-")[0] if tm else "未知漫画"

    cm = re.search(
        r'class="hl-dc-pic[^"]*"[^>]*>.*?data-original="([^"]+)"', html, re.S)
    meta["cover"] = cm.group(1) if cm else ""

    for m in re.finditer(
            r'class="(?:detail-tags-item|tags-item)[^"]*"[^>]*>(.*?)</', html, re.S):
        k = _clean(m.group(1))
        if k and k not in meta["kinds"]:
            meta["kinds"].append(k)

    sm = re.search(r'class="hl-pic-tag[^"]*"[^>]*>.*?class="state[^"]*"[^>]*>(.*?)</',
                   html, re.S)
    if not sm:
        sm = re.search(r'class="state[^"]*"[^>]*>(.*?)</', html, re.S)
    if sm:
        meta["status"] = _clean(sm.group(1))

    bm = re.search(r'<li class="blurb[^"]*"[^>]*>(.*?)</li>', html, re.S)
    if bm:
        intro = _clean(bm.group(1))
        meta["intro"] = re.sub(r"^(简介|介绍)[：:]?", "", intro).strip()
    if not meta["intro"]:
        mm = re.search(
            r'<meta[^>]*name="description"[^>]*content="([^"]*)"', html, re.I)
        if mm:
            intro = mm.group(1)
            # 去掉《书名》在线阅读，剧情介绍：这层站方 boilerplate
            intro = re.sub(r"^《[^》]*》[^，,]*[，,]?", "", intro).strip(" ，,")
            if intro.startswith(meta["title"]):
                intro = intro[len(meta["title"]):].strip(" ：:，,")
            meta["intro"] = intro
    return meta


def chapters(cid):
    html = _http("%s/comics-reading/%s.html" % (WEB, cid))
    out = []
    for m in re.finditer(
            r'<li[^>]*>\s*<a href="(/comics-reading/%s/[^"]+)"[^>]*title="([^"]*)"[^>]*>(.*?)</a>'
            % cid, html, re.S):
        href, ta, inner = m.group(1), m.group(2), m.group(3)
        slug = re.search(r"/comics-reading/%s/([^./]+)\.html" % cid, href)
        if not slug:
            continue
        name = (ta or _clean(inner) or "").strip()
        if not name:
            continue
        out.append({
            "t": name,
            "u": "%s%s/%s" % (SCHEME, cid, slug.group(1)),
            "i": len(out),
        })
    seen, uniq = set(), []
    for c in out:
        if c["u"] in seen:
            continue
        seen.add(c["u"])
        uniq.append(c)
    return uniq


def book(cid_or_id):
    """书籍详情，结构与 core.book() 对齐，额外带 kind / unit。"""
    cid = _cid(cid_or_id)
    html = _http("%s/comics-reading/%s.html" % (WEB, cid))
    meta = _page_meta(html)
    chs = chapters(cid)
    if not chs:
        raise RuntimeError("这本漫画还没有可读的章节")

    kinds = "、".join(meta["kinds"]) or "漫画"
    status = meta["status"]
    status = ("%s · %d 话" % (status, len(chs))) if status else ("%d 话" % len(chs))
    intro = meta["intro"] or "这本漫画还没有简介。"
    last = chs[-1]["t"]
    return {
        "id": PREFIX + cid,
        "title": meta["title"],
        "author": SRC_NAME,
        "cover": meta["cover"],
        "intro": intro,
        "category": kinds,
        "status": status,
        "updated": "",
        "lastChapter": last,
        "url": SCHEME + cid,
        "chapters": [{"t": c["t"], "u": c["u"]} for c in chs],
        "count": len(chs),
        "source": SRC_NAME,
        "kind": "comic",
        "unit": "话",
    }


def probe(text):
    """从链接 / dr:数字 / 纯数字认出作品。"""
    s = str(text or "").strip()
    m = re.search(r"/comics-reading/(\d+)", s)
    cid = m.group(1) if m else ""
    if not cid and is_dr(s):
        cid = native_id(s)
    if not cid or not re.fullmatch(r"\d{2,8}", cid):
        raise RuntimeError("请粘贴大人漫画的作品链接，例如 %s/comics-reading/<数字>" % WEB)
    return book(PREFIX + cid)


# ---------------------------------------------------------------- 每话图片

def _chap_link(href, cid):
    m = re.search(r"/comics-reading/%s/([^./]+)\.html" % cid, href or "")
    return ("%s%s/%s" % (SCHEME, cid, m.group(1))) if m else ""


def chapter(url):
    """一话 = 一组图片。返回 kind=comic，前端据此走漫画渲染。"""
    raw = str(url or "").replace(SCHEME, "")
    parts = [p for p in raw.split("/") if p]
    if len(parts) < 2 or not re.fullmatch(r"\d{2,8}", parts[0]) or not parts[1]:
        raise RuntimeError("漫画章节地址不合法")
    cid, cslug = parts[0], parts[1]

    html = _http("%s/comics-reading/%s/%s.html" % (WEB, cid, cslug))
    pages, seen = [], set()
    for tag in re.finditer(r"<img\b[^>]*>", html):
        t = tag.group(0)
        src = None
        for attr in ("data-original", "data-src", "src"):
            mm = re.search(attr + r'="([^"]+)"', t)
            if mm:
                src = mm.group(1)
                break
        if not src:
            continue
        # 跳过导航/图标/占位类图片
        low = src.lower()
        if any(x in low for x in ("loading", "blank", "data:image",
                                  "yandex", "logo", "icon", "avatar", "banner")):
            continue
        if not src.startswith("http"):
            src = (WEB + src) if src.startswith("/") else (WEB + "/" + src)
        if src in seen:
            continue
        seen.add(src)
        pages.append(src)
    if not pages:
        raise RuntimeError("这一话没有取到图片，可能已下架或需要付费")

    title = ""
    tm = re.search(r"<title>(.*?)\s*[-—]\s*", html, re.S)
    if tm:
        title = _clean(tm.group(1))
    if not title:
        tm = re.search(r'class="hl-dc-title[^"]*"[^>]*>(.*?)</', html, re.S)
        title = _clean(tm.group(1)) if tm else ""

    prev = next = ""
    pm = re.search(r'<a[^>]*href="([^"]+)"[^>]*>\s*上一章', html)
    nm = re.search(r'<a[^>]*href="([^"]+)"[^>]*>\s*下一章', html)
    if pm:
        prev = _chap_link(pm.group(1), cid)
    if nm:
        next = _chap_link(nm.group(1), cid)

    return {
        "title": title,
        "bookId": PREFIX + cid,
        "kind": "comic",
        "pages": pages,
        "url": str(url),
        "prev": prev,
        "next": next,
        "chars": 0,
    }


def page_bytes(url, timeout=20):
    """单页图片：图片 CDN 要带站点 Referer 防盗链，单独发请求。"""
    req = urllib.request.Request(str(url), headers={
        "User-Agent": _UA,
        "Accept": "image/webp,image/*,*/*;q=0.8",
        "Referer": WEB + "/",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            ctype = r.headers.get("Content-Type", "image/jpeg")
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("图片下载失败：%s" % e) from None
    if not raw:
        raise RuntimeError("图片没有下载下来")
    return raw, (ctype or "image/jpeg").split(";")[0].strip().lower()


# ---------------------------------------------------------------- 发现（榜单 / 分类）

RANKS = [("all", "总榜"), ("daily", "日榜"), ("weekly", "周榜"), ("monthly", "月榜")]
# 分类 = 题材 × 状态 的组合，cid 直接用站点的 URL 片段
_CATS_THEME = [("all", "全部"), ("韩漫", "韩漫"), ("日漫", "日漫"), ("真人", "真人"), ("3D漫画", "3D")]
_CATS_STATE = [("all", ""), ("serialized", "·连载"), ("completed", "·完结")]
CATS = [(u"/comics-catalog/%s/ob/hits/st/%s" % (t, s), name + tag)
        for (t, name) in _CATS_THEME for (s, tag) in _CATS_STATE]


def _cards(html):
    """hl-list-item 卡片：缩略图链接 + 标题 + 封面 + 状态。"""
    books, seen = [], set()
    for chunk in re.split(r'<li class="hl-list-item', html)[1:]:
        am = re.search(r'href="(/comics-reading/(\d+)\.html)"', chunk)
        if not am:
            continue
        bid = am.group(2)
        if bid in seen:
            continue
        seen.add(bid)
        tm = re.search(r'title="([^"]+)"', chunk)
        title = _clean(tm.group(1)) if tm else ""
        if not title:
            continue
        im = re.search(r'data-original="([^"]+)"', chunk)
        st = re.search(r'class="remarks[^"]*"[^>]*>([^<]{1,10})<', chunk)
        books.append({
            "id": PREFIX + bid,
            "title": title,
            "author": "",
            "cover": (im.group(1) if im else ""),
            "url": SCHEME + bid,
            "category": "漫画",
            "status": (st.group(1).strip() if st else ""),
            "intro": "",
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
            "rank": len(books) + 1,
        })
    return books


def ranking(kind="all", page=1):
    kind = kind if kind in ("all", "daily", "weekly", "monthly") else "all"
    url = WEB + ("/desirable-comics/%s" % kind if kind != "all" else "/desirable-comics")
    html = _http(url)
    books = _cards(html)
    # 榜单页不支持翻页，一次给全（约 96 本）
    return {"title": dict(RANKS).get(kind, "排行"), "books": books,
            "page": 1, "pages": 1}


def category(cid="/comics-catalog/all/ob/hits/st/all", page=1):
    cid = str(cid or "").strip()
    if not re.fullmatch(r"/comics-catalog/[\w/\-]+", cid) or "/ob/" not in cid:
        cid = "/comics-catalog/all/ob/hits/st/all"
    page = max(1, int(page or 1))
    url = WEB + urllib.parse.quote(cid)
    if page > 1:
        url += "/page/%d" % page
    html = _http(url)
    books = _cards(html)
    pages = 1
    for pm in re.finditer(r'href="[^"]*/page/(\d+)"', html):
        pages = max(pages, int(pm.group(1)))
    if page > pages and page > 1:
        fixed = category(cid, pages)
        fixed["clamped"] = True
        return fixed
    name = cid.rstrip("/").split("/")
    label = "%s%s" % (name[2] if len(name) > 2 else "全部", name[-1] if name[-1] != "all" else "")
    return {"title": "分类 %s · 第 %d 页" % (label, page), "books": books,
            "page": page, "pages": max(1, pages)}
