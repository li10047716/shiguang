"""🐸漫蛙漫画（manwa）漫画源。

站点：manwapm.cc / manwa.me 等（域名经常换，见 manwa_base()）。
纯 HTML 抓取：搜索 /search、详情 /book/<id>、目录、每话 /chapter/<id> 全是网页解析。
图片在 /static/upload/book/id/<bookid>/<chapterid>/ 下，但**经过 AES-128-CBC 加密**
（key == iv == "my2ecret782ecret"，PKCS7 填充），需要用 reader._aes 解密成 WebP 才能显示。

页面结构（实测 manwapm.cc）：
  - 搜索：/search?keyword=<kw>&page=<n> 的 <li>（.book-list-info-title / data-original / .book-list-info-desc）
  - 详情：/book/<id>，标题 .detail-main-info-title，封面 .detail-main-cover img[data-original]
  - 目录：同详情页 .detail-list-select li a -> /chapter/<id>，章节名在 text / title 属性
  - 正文：/chapter/<id> 的 img.content-img[data-r-src]，按文档顺序即图片顺序
  - 上一话/下一话：章节页是 Vue 渲染的，静态 HTML 里没有链接，只能回详情页目录按序取相邻项

注意：部分成人向作品需要登录（验证码没法在阅读里处理），未登录时搜索/目录可能不全；
普通作品不受影响。站点域名会失效，失效了改 manwa_base() 的默认或 data/cache/manwa_base.txt。
"""

from __future__ import annotations

import os
import re
import threading
import urllib.error
import urllib.parse
import urllib.request

from . import core
from ._aes import aes_cbc_decrypt

SCHEME = "mw://"
PREFIX = "mw:"
SRC_NAME = "漫蛙漫画"

_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# AES key == iv，来自书源的 imageDecode 规则
_AES_KEY = b"my2ecret782ecret"

# 章节目录按书号缓存，避免每翻一话都回详情页拉一遍（prev/next 要它）
_TOC_LOCK = threading.Lock()
_TOC_CACHE = {}

# 书号 / 话号都是数字
_ID_RE = re.compile(r"\d{2,12}")


def manwa_base():
    """取站点根地址。域名经常换，优先级：环境变量 > 本地覆盖文件 > 默认。"""
    env = os.environ.get("MANWA_BASE", "").strip()
    if env:
        return env.rstrip("/")
    fp = os.path.join(os.path.dirname(__file__), "..", "data", "cache", "manwa_base.txt")
    try:
        with open(fp, encoding="utf-8") as f:
            line = f.readline().strip()
            if line:
                return line.rstrip("/")
    except OSError:
        pass
    return "https://manwapm.cc"


# ---------------------------------------------------------------- 基础判定

def is_mw(v) -> bool:
    s = str(v or "")
    return s.startswith(PREFIX) or s.startswith(SCHEME)


def native_id(v) -> str:
    s = str(v or "")
    # 先判 SCHEME（mw://…）再判 PREFIX（mw:…），否则 "mw://15803" 会被 PREFIX 截掉 3 字符
    if s.startswith(SCHEME):
        s = s[len(SCHEME):]
    elif s.startswith(PREFIX):
        s = s[len(PREFIX):]
    return s.split("/")[0].strip()


def _cid(v) -> str:
    s = native_id(v)
    if not _ID_RE.fullmatch(s):
        raise RuntimeError("漫画地址不合法：%s" % s)
    return s


def looks_like(text) -> bool:
    """判断用户粘的地址是不是这个站的。"""
    s = str(text or "").strip().lower()
    if s.startswith(PREFIX) or s.startswith(SCHEME):
        return True
    return "manwa" in s


def is_manwa_image_url(url) -> bool:
    """图片地址识别：路径里带 /static/upload/book/ 就是漫蛙的加密图。"""
    return "/static/upload/book/" in str(url or "")


# ---------------------------------------------------------------- 基础请求

def _http(url, timeout=20):
    req = urllib.request.Request(url, headers={
        "User-Agent": _UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Referer": manwa_base() + "/",
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


def _abs(src, base):
    if src.startswith("//"):
        return "https:" + src
    if src.startswith("/"):
        return base + src
    return src


# ---------------------------------------------------------------- 搜索

def search(keyword, page=1):
    keyword = (keyword or "").strip()
    if not keyword:
        return {"books": [], "msg": ""}
    page = max(1, int(page or 1))
    base = manwa_base()
    url = "%s/search?keyword=%s&page=%d" % (base, urllib.parse.quote(keyword), page)
    try:
        html = _http(url)
    except Exception as e:  # noqa: BLE001
        return {"books": [], "msg": str(e)}

    books, seen = [], set()
    for block in re.finditer(r'<li[^>]*>(.*?)</li>', html, re.S):
        chunk = block.group(1)
        if "book-list-info-title" not in chunk and "/book/" not in chunk:
            continue
        am = re.search(r'href="(/book/\d+)"', chunk)
        if not am:
            continue
        href = am.group(1)
        cid = re.search(r"/book/(\d+)", href).group(1)
        if cid in seen:
            continue
        title = ""
        tm = re.search(r'book-list-info-title"[^>]*>(.*?)<', chunk, re.S)
        if tm:
            title = _clean(tm.group(1))
        if not title:
            tm2 = re.search(r'title="([^"]+)"', chunk)
            title = tm2.group(1) if tm2 else ""
        if not title:
            continue
        cm = re.search(r'data-original="([^"]+)"', chunk)
        cover = cm.group(1) if cm else ""
        dm = re.search(r'book-list-info-desc"[^>]*>(.*?)</p>', chunk, re.S)
        intro = _clean(dm.group(1)) if dm else ""
        # 状态（连载中 / 完结）放在底部右侧小字
        sm = re.search(r"book-list-info-bottom-right-font'[^>]*>(.*?)</span>", chunk, re.S)
        status = _clean(sm.group(1)) if sm else ""
        seen.add(cid)
        books.append({
            "id": PREFIX + cid,
            "title": title,
            "author": "",
            "cover": cover,
            "url": SCHEME + cid,
            "category": status or "漫画",
            "intro": intro,
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
        })

    msg = "" if books else "没有找到相关漫画"
    return {"books": books, "msg": msg}


# ---------------------------------------------------------------- 详情 / 目录

def _toc(bookid):
    with _TOC_LOCK:
        if bookid in _TOC_CACHE:
            return _TOC_CACHE[bookid]
    html = _http("%s/book/%s" % (manwa_base(), bookid))
    chs = _parse_chapters(html, bookid)
    with _TOC_LOCK:
        _TOC_CACHE[bookid] = chs
    return chs


def _parse_chapters(html, bookid):
    out = []
    for m in re.finditer(
            r'<li>\s*<a href="(/chapter/\d+)"[^>]*title="([^"]*)"[^>]*>(.*?)</a>', html, re.S):
        href, ta, inner = m.group(1), m.group(2), m.group(3)
        cm = re.search(r"/chapter/(\d+)", href)
        if not cm:
            continue
        cid = cm.group(1)
        name = (ta or _clean(inner) or "").strip()
        if not name:
            continue
        out.append({"t": name, "u": "%s%s/%s" % (SCHEME, bookid, cid), "cid": cid})
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
    base = manwa_base()
    html = _http("%s/book/%s" % (base, cid))
    meta = _page_meta(html, cid)
    chs = _parse_chapters(html, cid)
    # 顺手填进 TOC 缓存：用户加书后立刻点开某话时，chapter() 的 _toc 直接命中，省一次详情页请求
    with _TOC_LOCK:
        _TOC_CACHE[cid] = chs
    if not chs:
        raise RuntimeError("这本漫画还没有可读的章节")

    kinds = meta["kind"] or "漫画"
    status = meta["status"]
    status = ("%s · %d 话" % (status, len(chs))) if status else ("%d 话" % len(chs))
    intro = meta["intro"] or "这本漫画还没有简介。"
    last = chs[-1]["t"]
    return {
        "id": PREFIX + cid,
        "title": meta["title"],
        "author": meta["author"] or SRC_NAME,
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


def _page_meta(html, cid):
    meta = {"title": "", "cover": "", "kind": "", "status": "", "intro": "", "author": ""}

    tm = re.search(r'class="detail-main-info-title"[^>]*>(.*?)<', html, re.S)
    if tm:
        meta["title"] = _clean(tm.group(1))
    if not meta["title"]:
        tm = re.search(r"<title>(.*?)</title>", html, re.S)
        meta["title"] = _clean(tm.group(1)).split("-")[0] if tm else "未知漫画"

    cm = re.search(r'class="detail-main-cover"[^>]*>.*?data-original="([^"]+)"', html, re.S)
    meta["cover"] = cm.group(1) if cm else ""

    km = re.search(r'class="detail-main-info-class"[^>]*>(.*?)</div>', html, re.S)
    if km:
        k = _clean(km.group(1))
        if k:
            meta["kind"] = k

    # 详情页作者块里是「更新状态：连载中」「最新章节：…」等，逐字段抠
    for field, label in (("status", "更新状态"), ("author", "作者"), ("last", "最新章节")):
        fm = re.search(r'%s[：:]\s*</span>\s*<span[^>]*>(.*?)</span>' % label, html, re.S)
        if fm:
            val = _clean(fm.group(1))
            if field == "status":
                meta["status"] = val
            elif field == "author":
                meta["author"] = "" if "[db:" in val else val

    bm = re.search(r'class="detail-desc"[^>]*>(.*?)</', html, re.S)
    if bm:
        intro = _clean(bm.group(1))
        meta["intro"] = re.sub(r"^(简介|介绍)[：:]?", "", intro).strip()
    return meta


def probe(text):
    """从链接 / mw:数字 / 纯数字认出作品。"""
    s = str(text or "").strip()
    m = re.search(r"/book/(\d+)", s)
    cid = m.group(1) if m else ""
    if not cid and is_mw(s):
        cid = native_id(s)
    if not cid or not _ID_RE.fullmatch(cid):
        raise RuntimeError("请粘贴漫蛙的作品链接，例如 %s/book/<数字>" % manwa_base())
    return book(PREFIX + cid)


# ---------------------------------------------------------------- 每话图片

def chapter(url):
    """一话 = 一组图片。返回 kind=comic，前端据此走漫画渲染。"""
    raw = str(url or "").replace(SCHEME, "").replace(PREFIX, "")
    parts = [p for p in raw.split("/") if p]
    if len(parts) < 2 or not _ID_RE.fullmatch(parts[0]) or not _ID_RE.fullmatch(parts[1]):
        raise RuntimeError("漫画章节地址不合法")
    bookid, chapterid = parts[0], parts[1]

    base = manwa_base()
    html = _http("%s/chapter/%s" % (base, chapterid))

    pages, seen = [], set()
    for src in re.findall(r'data-r-src="([^"]+)"', html):
        if not src or src in seen:
            continue
        seen.add(src)
        pages.append(_abs(src, base))
    if not pages:
        raise RuntimeError("这一话没有取到图片，可能已下架或需要登录才能看")

    # 章节标题：<title>书名-章节名在线阅读-漫蛙漫画</title>
    title = ""
    tm = re.search(r"<title>.*?-\s*(.*?)\s*在线阅读", html, re.S)
    if tm:
        title = _clean(tm.group(1))
    if not title:
        for c in _toc(bookid):
            if c["cid"] == chapterid:
                title = c["t"]
                break

    # 上一话 / 下一话：回详情页目录按序取相邻项（章节页是 Vue 渲染，没有静态链接）
    prev = next_ = ""
    try:
        toc = _toc(bookid)
        idx = next((i for i, c in enumerate(toc) if c["cid"] == chapterid), -1)
        if idx > 0:
            prev = toc[idx - 1]["u"]
        if 0 <= idx < len(toc) - 1:
            next_ = toc[idx + 1]["u"]
    except Exception:  # noqa: BLE001
        pass

    return {
        "title": title,
        "bookId": PREFIX + bookid,
        "kind": "comic",
        "pages": pages,
        "url": str(url),
        "prev": prev,
        "next": next_,
        "chars": 0,
    }


def page_bytes(url):
    """下载并 AES 解密漫蛙图片。返回 (bytes, content_type)。"""
    url = str(url)
    req = urllib.request.Request(url, headers={
        "User-Agent": _UA,
        "Accept": "image/webp,image/*,*/*;q=0.8",
        "Referer": manwa_base() + "/",
    })
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            blob = r.read()
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("漫蛙图片下载失败：%s" % e) from None

    if len(blob) % 16 != 0:
        raise RuntimeError("漫蛙图片不是 16 字节对齐，站点可能改了加密或防盗链生效")
    dec = aes_cbc_decrypt(_AES_KEY, blob)
    if dec[:4] == b"RIFF":
        return dec, "image/webp"
    if dec[:2] == b"\xff\xd8":
        return dec, "image/jpeg"
    if dec[:4] == b"\x89PNG":
        return dec, "image/png"
    raise RuntimeError("漫蛙图片解密后不是有效图片，可能站点已换加密或域名失效")


# ---------------------------------------------------------------- 发现（榜单 / 分类）

RANKS = [("hot", "人气榜"), ("newest", "新番榜"), ("end", "完结榜")]
# 分类 = booklist 的单个筛选参数；cid 形如 "gender=0" / "area=3"，all 表示全部
CATS = [
    ("all", "全部"), ("gender=2", "一般向"), ("gender=0", "BL向"), ("gender=1", "禁漫"),
    ("gender=3", "TL向"), ("gender=4", "GL向"), ("area=2", "韩国"), ("area=3", "日漫"),
    ("area=4", "国漫"), ("area=5", "台漫"), ("area=6", "其他"),
]


def _rank_cards(html):
    books = []
    for chunk in re.split(r'<a href="/book/', html)[1:]:
        am = re.match(r'(\d+)"[^>]*title="([^"]*)"', chunk)
        if not am:
            continue
        bid, title = am.group(1), _clean(am.group(2))
        if not title:
            continue
        im = re.search(r'data-original="([^"]+)"', chunk)
        books.append({
            "id": PREFIX + bid,
            "title": title,
            "author": "",
            "cover": (im.group(1) if im else ""),
            "url": SCHEME + bid,
            "category": "漫画",
            "intro": "",
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
            "rank": len(books) + 1,
        })
    return books


def ranking(kind="hot", page=1):
    """/rank 单页三个榜（data-type=newest/hot/end），?page=N&type=X 翻页。"""
    kind = kind if kind in ("hot", "newest", "end") else "hot"
    page = max(1, int(page or 1))
    html = _http("%s/rank?page=%d&type=%s" % (manwa_base(), page, kind))
    # 只取对应榜单的 <ul class="rank-list" data-type="..."> 段
    m = re.search(r'<ul class="rank-list"[^>]*data-type="%s"[^>]*>(.*?)</ul>' % kind, html, re.S)
    books = _rank_cards(m.group(1)) if m else _rank_cards(html)
    pages = 6
    pm = re.search(r'data-type="%s"[^>]*data-page="(\d+)"' % kind, html)
    if pm:
        pages = max(1, int(pm.group(1)))
    if page > pages:
        fixed = ranking(kind, pages)
        fixed["clamped"] = True
        return fixed
    return {"title": "%s · 第 %d 页" % (dict(RANKS).get(kind, "排行"), page),
            "books": books, "page": page, "pages": pages}


def category(cid="all", page=1):
    """/booklist 筛选：cid 是 "k=v" 参数或 all。"""
    cid = str(cid or "all").strip()
    if cid != "all" and not re.fullmatch(r"(?:gender|area|end)=[\-\d]+", cid):
        cid = "all"
    page = max(1, int(page or 1))
    url = "%s/booklist?%s&page=%d" % (manwa_base(), cid, page) if cid != "all" \
        else "%s/booklist?page=%d" % (manwa_base(), page)
    html = _http(url)
    books, seen = [], set()
    for chunk in re.split(r'<li\s*>', html)[1:]:
        am = re.search(r'href="(/book/(\d+))"[^>]*title="([^"]*)"', chunk)
        if not am:
            continue
        bid, title = am.group(2), _clean(am.group(3))
        if not title or bid in seen:
            continue
        seen.add(bid)
        im = re.search(r'<img[^>]+src="([^"]+)"', chunk)
        tip = re.search(r'class="manga-list-2-tip[^"]*"[^>]*>([^<]{1,40})<', chunk)
        books.append({
            "id": PREFIX + bid,
            "title": title,
            "author": "",
            "cover": (im.group(1) if im else ""),
            "url": SCHEME + bid,
            "category": "漫画",
            "intro": _clean(tip.group(1)) if tip else "",
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
            "rank": len(books) + 1,
        })
    pages = 1
    for pm in re.finditer(r'data-page="(\d+)"', html):
        pages = max(pages, int(pm.group(1)))
    pages = min(pages, 100)
    if page > pages:
        fixed = category(cid, pages)
        fixed["clamped"] = True
        return fixed
    name = dict(CATS).get(cid, "全部")
    return {"title": "%s · 第 %d 页" % (name, page), "books": books,
            "page": page, "pages": max(1, pages)}
