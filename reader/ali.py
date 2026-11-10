"""
爱丽丝书屋（alicesw.com）抓取层。

成人向小说站，**访客免登录就能读全文**（正文页直接吐 HTML，没有 VIP / 金币 / 分段）：
  - 搜索  GET /search.html?q=关键词&f=_all&p=N（一页 10 条，标题里带 <em> 高亮）
  - 分类  GET /lists/{cid}.html?page=N（29 个标签分类，一页 50 本，页数在分页条里）
  - 榜单  GET /other/rank_hits/order/{hits_day|hits_week|hits_month|hits}.html（单页 50 本）
  - 详情  GET /novel/{id}.html（.novel_title / .novel_info / .jianjie / og:image）
  - 目录  GET /other/chapters/id/{id}.html（ul.mulu_list，全量一页，几百章也不分页）
  - 正文  GET /book/{bid}/{hash}.html（.j_readContent 里的 <p>，章节名在 h3.j_chapterName）

两个必须知道的事：
  1. **这站非走代理不可**。DNS 能解析（www 指向 128.242.240.117），但大陆直连 443 直接超时。
     所以请求层自带代理选择：settings.proxy → SUDUGU_PROXY / ALI_PROXY 环境变量 → 自动试本机常见端口。
  2. 书籍页的 id 是 /novel/{id}.html，但章节在 /book/{bid}/{hash}.html，两个 id **不是同一个**
     （例：/novel/49271.html 的章节全在 /book/50585/ 下）。所以章节地址原样保存，不做推导。
"""
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from html import unescape

SITE = "https://www.alicesw.com"
PREFIX = "ali:"
SCHEME = "ali://"
NAME = "爱丽丝书屋"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

_HDR = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Referer": SITE + "/",
}

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_STATE = os.path.join(_ROOT, "data", "state.json")

# 首页导航里的 29 个标签分类（顺序照站点）
CATS = [
    ("71", "科幻"), ("79", "经典"), ("75", "奇幻"), ("69", "系统"), ("68", "武侠"),
    ("65", "乱伦"), ("64", "都市"), ("63", "乡村"), ("73", "同人"), ("62", "玄幻"),
    ("61", "校园"), ("70", "穿越"), ("22", "反差"), ("46", "凌辱"), ("18", "堕落"),
    ("19", "纯爱"), ("52", "伪娘"), ("48", "萝莉"), ("56", "熟女"), ("50", "正太"),
    ("72", "明星"), ("54", "NTR"), ("53", "媚黑"), ("58", "调教"), ("59", "言情"),
    ("47", "百合"), ("82", "耽美"), ("21", "重口"), ("57", "其他"),
]

RANKS = [
    ("hits_day", "日榜"), ("hits_week", "周榜"),
    ("hits_month", "月榜"), ("hits", "总榜"),
]

# 本机常见代理端口：Clash(7897/7890)、v2rayN(10809)、SS(1080)
_CANDIDATES = ("http://127.0.0.1:7897", "http://127.0.0.1:7890",
               "http://127.0.0.1:10809", "http://127.0.0.1:1080")

_pick = {"done": False, "proxy": "", "fail_at": 0.0}


# ---------------------------------------------------------------- 代理与请求

def _cfg_proxy():
    """代理来源：设置项 > 环境变量。空字符串表示直连。"""
    val = ""
    try:
        with open(_STATE, encoding="utf-8") as f:
            val = ((json.load(f) or {}).get("settings") or {}).get("proxy") or ""
    except Exception:  # noqa: BLE001
        pass
    if not val:
        val = os.environ.get("SUDUGU_PROXY") or os.environ.get("ALI_PROXY") or ""
    return val.strip()


def _try(url, proxy, timeout, referer=None):
    if proxy:
        op = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    else:
        # 空 ProxyHandler 是「强制直连」：否则 urllib 会去读 HTTP_PROXY 环境变量
        op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    hdrs = dict(_HDR)
    if referer:
        hdrs["Referer"] = referer
    req = urllib.request.Request(url, headers=hdrs)
    with op.open(req, timeout=timeout) as r:
        return r.read(), r.headers.get("Content-Type", "")


def _decode(raw, ctype):
    enc = "utf-8"
    m = re.search(r"charset=([\w-]+)", ctype or "", re.I)
    if m:
        enc = m.group(1).lower()
    if enc in ("gbk", "gb2312", "gb18030"):
        enc = "gb18030"
    return raw.decode(enc, "ignore")


def _order():
    """确定这一轮要试哪几个代理。第一个命中的会被记住，后续请求直接用。"""
    cfg = _cfg_proxy()
    if cfg:
        return [cfg]
    if _pick["done"]:
        return [_pick["proxy"]]
    return [""] + [p for p in _CANDIDATES]


def _cooling():
    """探测失败后的冷却期：别每次搜索都花 6 秒去撞直连。"""
    return bool(_pick["fail_at"]) and time.time() - _pick["fail_at"] < 20


def proxy_info():
    """给「书源健康」面板看的爱丽丝代理状态。"""
    cfg = _cfg_proxy()
    cur = cfg or (_pick["proxy"] if _pick["done"] else "")
    return {
        "proxy": cur or "直连",
        "port": (re.search(r":(\d+)\s*$", cur).group(1) if re.search(r":(\d+)\s*$", cur) else ""),
        "configured": bool(cfg),
        "cooling": _cooling(),
        "candidates": list(_CANDIDATES),
    }


def _get(url, timeout=20, referer=None, retries=1):
    if not _cfg_proxy() and _cooling():
        raise RuntimeError(
            "%s 打不开：刚才试过直连和本机代理都不通，先确认代理软件在跑"
            "（设置里也能直接填代理地址）。" % NAME)
    err = None
    for attempt in range(retries + 1):
        for proxy in _order():
            # 直连只给 4 秒，探测阶段别把整个搜索拖死
            t = timeout if proxy else min(timeout, 4)
            try:
                raw, ctype = _try(url, proxy, t, referer)
            except Exception as e:  # noqa: BLE001
                err = e
                continue
            _pick.update(done=True, proxy=proxy, fail_at=0.0)
            return _decode(raw, ctype)
        if attempt < retries:
            time.sleep(0.4)
    _pick.update(done=True, proxy="", fail_at=time.time())
    raise RuntimeError(
        "%s 打不开（%s）。这个站必须挂着代理访问，先确认代理软件在跑；"
        "也可以在设置里把代理地址填成 127.0.0.1:7897。" % (NAME, err))


def fetch_bytes(url, timeout=25):
    """封面用：返回 (blob, content_type)。图片在 CDN 上，同样要过代理。"""
    err = None
    for proxy in _order():
        try:
            raw, ctype = _try(url, proxy, timeout if proxy else min(timeout, 8))
            _pick.update(done=True, proxy=proxy, fail_at=0.0)
            return raw, ctype
        except Exception as e:  # noqa: BLE001
            err = e
    raise RuntimeError("%s 图片下载失败：%s" % (NAME, err))


# ---------------------------------------------------------------- 文本工具

def _text(frag):
    frag = re.sub(r"<script.*?</script>", "", frag, flags=re.S | re.I)
    frag = re.sub(r"<style.*?</style>", "", frag, flags=re.S | re.I)
    frag = re.sub(r"<br\s*/?>", "\n", frag, flags=re.I)
    frag = re.sub(r"</p\s*>", "\n", frag, flags=re.I)
    frag = re.sub(r"<[^>]+>", "", frag)
    frag = unescape(frag)
    frag = (frag.replace("\u00a0", " ").replace("\u3000", " ")
                .replace("\u2002", " ").replace("\u2003", " "))
    return re.sub(r"[ \t\r\f\v]+", " ", frag).strip()


def _one(pattern, html, group=1, default=""):
    m = re.search(pattern, html, re.I | re.S)
    return _text(m.group(group)) if m else default


def _words(raw):
    s = _text(raw)
    if not s:
        return ""
    if re.search(r"[\d.]+\s*[万千]?字?", s):
        return s if s.endswith("字") else s + "字"
    return ""


def _num(raw):
    return re.sub(r"[^\d]", "", raw or "")


def _status(raw):
    s = _text(raw)
    if not s:
        return ""
    if "完结" in s or "全本" in s:
        return "已完结"
    if "连载" in s:
        return "连载中"
    return ""


# ---------------------------------------------------------------- id

def is_ali(v):
    v = (v or "").strip()
    return v.startswith(PREFIX) or v.startswith(SCHEME)


def native_id(v):
    s = (v or "").strip()
    if s.startswith(SCHEME):
        s = s[len(SCHEME):]
    elif s.startswith(PREFIX):
        s = s[len(PREFIX):]
    m = re.match(r"^(\d+)", s)
    return m.group(1) if m else ""


def _book_id(href):
    m = re.search(r"/novel/(\d+)\.html", href or "")
    if m:
        return m.group(1)
    m = re.search(r"data-bid=\"/novel/(\d+)\.html\"", href or "")
    return m.group(1) if m else ""


def _cover(url):
    url = (url or "").strip()
    if not url:
        return ""
    if url.startswith("//"):
        url = "https:" + url
    if url.startswith("/"):
        url = SITE + url
    return url if url.startswith("http") else ""


# ---------------------------------------------------------------- 列表解析

# 分类页 / 榜单页共用一套 div.rec_rullist > ul > li
_ROW = re.compile(r"<div class=\"clearfix rec_rullist\">([\s\S]*?)(?=<div class=\"layui|</div>\s*</div>\s*<div class=\"wudu|$)")


def _rows(html):
    books, seen = [], set()
    start = html.find('class="clearfix rec_rullist"')
    if start < 0:
        return books
    # 从列表容器开始，按 <ul> 切块，避免把页尾别的列表也吃进来
    tail = html[start:start + 200000]
    for blk in re.findall(r"<ul>([\s\S]*?)</ul>", tail):
        if "/novel/" not in blk:
            continue
        href = re.search(r'<li class="two"><a href="([^"]+)"', blk)
        bid = _book_id(href.group(1) if href else "")
        if not bid or bid in seen:
            continue
        seen.add(bid)
        books.append({
            "id": PREFIX + bid,
            "title": _one(r'<li class="two"><a[^>]*>([\s\S]*?)</a>', blk),
            "author": _one(r'<li class="four">([\s\S]*?)</li>', blk),
            "latest": _one(r'<li class="three"><a[^>]*>([\s\S]*?)</a>', blk),
            "words": _words(_one(r'<li class="five">([\s\S]*?)</li>', blk)),
            "updated": _one(r'<li class="six">([\s\S]*?)</li>', blk),
            "category": _one(r'<li class="sev">[\s\S]*?<a[^>]*>([\s\S]*?)</a>', blk),
            "read": _num(_one(r'<li class="diyhot">([\s\S]*?)</li>', blk)),
            "cover": "",
            "status": "",
            "intro": "",
            "source": NAME,
        })
    return books


def _pages_by_link(html, pattern):
    nums = [int(n) for n in re.findall(pattern, html) if n.isdigit()]
    return max(nums) if nums else 1


# ---------------------------------------------------------------- 搜索

def search(keyword, page=1):
    kw = (keyword or "").strip()
    if not kw:
        return {"books": [], "page": 1, "pages": 1, "total": 0}
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    url = "%s/search.html?q=%s&f=_all&p=%d" % (SITE, urllib.parse.quote(kw), p)
    html = _get(url, timeout=25)

    books, seen = [], set()
    for blk in re.split(r'<div class="list-group-item">', html)[1:]:
        hm = re.search(r'<h5>\s*<a href="/novel/(\d+)\.html"[^>]*>([\s\S]*?)</a>', blk)
        if not hm:
            continue
        bid = hm.group(1)
        if bid in seen:
            continue
        seen.add(bid)
        title = _text(hm.group(2))
        title = re.sub(r"^\d+\.\s*", "", title)  # 站点会带「1. 」编号
        meta = ""
        mm = re.search(r"<p class=\"mb-1 text-muted\">([\s\S]*?)</p>", blk)
        if mm:
            meta = _text(mm.group(1))
        words = ""
        wm = re.search(r"字数[：:]\s*([\d.]+\s*[万千]?字?)", meta)
        if wm:
            words = wm.group(1)
            if not words.endswith("字"):
                words += "字"
        reads = ""
        rm = re.search(r"浏览[：:]\s*([\d,]+)", meta)
        if rm:
            reads = _num(rm.group(1))
        author = ""
        am = re.search(r"作\s*者[：:]\s*<a[^>]*>([\s\S]*?)</a>", blk)
        if am:
            author = _text(am.group(1))
        status = _status(_one(r'<small class="text-muted[^"]*">([\s\S]*?)</small>', blk))
        intro = _one(r'<p class="content-txt">([\s\S]*?)</p>', blk)
        tags = [t.strip() for t in re.findall(r'f=tag"[^>]*>[\s\S]*?</span>\s*([^<]+)</a>', blk)]
        tags = [t for t in tags if t]
        updated = _one(r"更新时间[：:]\s*([\d\-: ]+)", blk)

        books.append({
            "id": PREFIX + bid,
            "title": title,
            "author": author,
            "category": tags[0] if tags else "",
            "tags": tags,
            "cover": "",
            "words": words,
            "read": reads,
            "status": status,
            "intro": intro,
            "latest": "",
            "updated": updated,
            "source": NAME,
        })

    total = 0
    tm = re.search(r"共\s*<b>([\d,]+)</b>\s*条结果", html)
    if tm:
        total = int(_num(tm.group(1)))
    pages = (total + 9) // 10 if total else _pages_by_link(html, r"\?[^\"']*p=(\d+)")
    if pages and p > pages:
        return search(kw, pages)
    return {"books": books, "page": p, "pages": max(1, pages), "total": total, "keyword": kw}


# ---------------------------------------------------------------- 分类 / 榜单

def sort(cid, page=1):
    """标签分类。cid 见 CATS，一页 50 本。"""
    cid = cid if cid in dict(CATS) else "65"
    name = dict(CATS)[cid]
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    url = "%s/lists/%s.html" % (SITE, cid)
    if p > 1:
        url += "?page=%d" % p
    html = _get(url, timeout=25)
    pages = _pages_by_link(html, r"/lists/%s\.html\?page=(\d+)" % cid)
    if p > pages:
        return sort(cid, pages)
    books = _rows(html)
    for b in books:
        b["category"] = name
    return {"title": "%s · %s小说" % (NAME, name), "books": books, "page": p,
            "pages": max(1, pages), "cats": CATS}


def ranking(kind="hits_day", page=1):
    """官方人气榜：日/周/月/总，各 50 本，单页不再翻。"""
    keys = dict(RANKS)
    kind = kind if kind in keys else "hits_day"
    url = "%s/other/rank_hits/order/%s.html" % (SITE, kind)
    html = _get(url, timeout=25)
    books = _rows(html)
    for i, b in enumerate(books, 1):
        b["rank"] = i
    return {"title": "%s · %s" % (NAME, keys[kind]), "books": books, "page": 1,
            "pages": 1, "cats": RANKS}


# ---------------------------------------------------------------- 详情

def _detail_core(html, bid):
    title = _one(r'<div class="novel_title">([\s\S]*?)</div>', html)
    if not title:
        title = _one(r"<title>([\s\S]*?)</title>", html).split("_")[0].strip() or ("书籍" + bid)

    author = _one(r'作\s*者[：:]\s*<a[^>]*>([\s\S]*?)</a>', html)
    category = _one(r'分\s*类[：:]\s*<a[^>]*>([\s\S]*?)</a>', html)
    status = _status(_one(r"状\s*态[：:]\s*([^<\n]+)", html))
    words = _words(_one(r"字\s*数[：:]\s*([^<·\n]+)", html))
    read = _num(_one(r"热\s*度[：:]\s*([\d,]+)", html))
    latest = _one(r"最\s*新[：:]\s*<a[^>]*>([\s\S]*?)</a>", html)

    cover = _cover(_one(r'<div class="pic">\s*<img[^>]*src="([^"]+)"', html))
    if not cover:
        cover = _cover(_one(r'og:image"\s+content="([^"]+)"', html))

    intro = _one(r'<div class="jianjie">[\s\S]*?<p>([\s\S]*?)</p>', html)
    intro = re.sub(r"\n{2,}", "\n", intro).strip()

    tags = []
    tm = re.search(r'<div class="tags_list">([\s\S]*?)</div>', html)
    if tm:
        tags = [t for t in re.findall(r'class="red"[^>]*>[\s\S]*?</em>\s*([^<]+)</a>', tm.group(1))]

    return {
        "id": PREFIX + bid,
        "title": title,
        "author": author,
        "category": category,
        "tags": tags,
        "status": status,
        "words": words,
        "read": read,
        "intro": intro,
        "cover": cover,
        "latest": latest,
        "updated": "",
        "source": NAME,
    }


def book(book_id):
    bid = native_id(book_id)
    if not bid:
        raise RuntimeError("缺少爱丽丝书屋书籍 id")
    url = "%s/novel/%s.html" % (SITE, bid)
    html = _get(url, timeout=30)
    data = _detail_core(html, bid)

    # 目录是独立页，全量一页；比详情页里的「最新章节」全得多
    toc_html = _get("%s/other/chapters/id/%s.html" % (SITE, bid), timeout=30)
    chapters, seen = [], set()
    tm = re.search(r'<ul class="mulu_list">([\s\S]*?)</ul>', toc_html)
    scope = tm.group(1) if tm else toc_html
    for href, name in re.findall(
            r'<li>\s*<a href="(/book/\d+/[0-9a-z]+\.html)"[^>]*>([\s\S]*?)</a>\s*</li>', scope, re.I):
        cid = re.search(r"/book/\d+/([0-9a-z]+)\.html", href)
        if not cid or cid.group(1) in seen:
            continue
        seen.add(cid.group(1))
        nm = _text(name)
        if not nm:
            continue
        chapters.append({"t": nm, "u": SCHEME + href.lstrip("/")})

    if not chapters:
        raise RuntimeError("%s：这本暂时取不到目录" % NAME)

    data.update({
        "url": url,
        "chapters": chapters,
        "count": len(chapters),
        "latest": data.get("latest") or chapters[-1]["t"],
    })
    return data


# ---------------------------------------------------------------- 正文

_JUNK = re.compile(
    r"(爱丽丝书屋|alicesw|请记住本站|最新网址|本章未完|点击下一页|加入书签"
    r"|一秒记住|手机用户请|最新章节|（本章完）|\(本章完\)|本站域名)")


def chapter(url):
    v = (url or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    m = re.match(r"^(?:book/)?(\d+)/([0-9a-z]+)(?:\.html)?", v)
    if not m:
        raise RuntimeError("爱丽丝书屋章节地址不对：%s" % url)
    bid, cid = m.group(1), m.group(2)
    page_url = "%s/book/%s/%s.html" % (SITE, bid, cid)

    html = _get(page_url, timeout=30)

    title = _one(r'<h3 class="j_chapterName">([\s\S]*?)</h3>', html)
    if not title:
        title = _one(r"<title>([\s\S]*?)</title>", html).split("_")[0].strip()

    body = re.search(r'<div class="read-content j_readContent[^"]*">([\s\S]*?)</div>', html)
    if not body:
        raise RuntimeError("这一章没有取到内容（站点可能改了正文容器）")
    raw = body.group(1)

    paras = []
    for line in _text(raw).split("\n"):
        line = line.strip()
        if not line or _JUNK.search(line):
            continue
        paras.append(line)
    if paras and (paras[0] == title or paras[0].startswith(title)):
        paras.pop(0)
    if not paras:
        raise RuntimeError("这一章没有取到内容")

    # data-purl / data-nurl 是站内上一章/下一章（最后一章 nurl 为空）
    prev_url = _one(r'data-purl="([^"]*)"', html)
    next_url = _one(r'data-nurl="([^"]*)"', html)
    owner = _book_id(html)

    return {
        "title": title,
        "paras": paras,
        "chars": sum(len(p) for p in paras),
        "bookId": PREFIX + owner if owner else "",
        "prev": SCHEME + prev_url.lstrip("/") if prev_url.startswith("/") else "",
        "next": SCHEME + next_url.lstrip("/") if next_url.startswith("/") else "",
        "source": NAME,
    }


if __name__ == "__main__":
    import sys

    what = sys.argv[1] if len(sys.argv) > 1 else "search"
    if what == "search":
        print(json.dumps(search(sys.argv[2] if len(sys.argv) > 2 else "淫乱家族"),
                         ensure_ascii=False, indent=1)[:1500])
    elif what == "sort":
        print(json.dumps(sort(sys.argv[2] if len(sys.argv) > 2 else "65"),
                         ensure_ascii=False, indent=1)[:1500])
    elif what == "rank":
        print(json.dumps(ranking(sys.argv[2] if len(sys.argv) > 2 else "hits_day"),
                         ensure_ascii=False, indent=1)[:1200])
    elif what == "book":
        print(json.dumps(book(sys.argv[2]), ensure_ascii=False, indent=1)[:1500])
    elif what == "chapter":
        d = chapter(sys.argv[2])
        print(d["title"], d["chars"])
        print("\n".join(d["paras"][:3]))
