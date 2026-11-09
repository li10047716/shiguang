"""
八一中文网（81shuku.info）抓取层。

站点是标准杰奇 CMS 模板，纯 HTML：
  - 搜索  POST /modules/article/search.php（表单 searchkey + searchtype）
  - 分类  /{拼音}_1_{page}.html，7 个分类，每页 60 本、50 页
  - 详情  /{id//1000}/{id}/  一次给全量目录（两千多章约 250KB）
  - 正文  /{id//1000}/{id}/{cid}.html，单页完，无 _2 续页
  - 榜单  /paihangbang/、goodnum.html、newbook.html，每页按分类分 8 块

两个坑：
  1. 不带 Accept-Encoding / Referer 的请求会被回一张 442 字节的自动跳转脚本
     （跳去广告站），必须声明 gzip 并手动解压，否则看着像站点被劫持。
  2. 原域名 blxs.la 已 301 到 81shuku.info，别再用旧域名。
"""
import gzip
import html as htmllib
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

BASE = "http://www.81shuku.info"
PREFIX = "bl:"
SCHEME = "bl://"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

_HDR = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Accept-Encoding": "gzip, deflate",  # 不声明会被回跳转脚本
    "Referer": BASE + "/",
}

CATS = [
    ("1", "玄幻"), ("2", "修真"), ("3", "都市"), ("4", "穿越"),
    ("5", "网游"), ("6", "科幻"), ("7", "其他"),
]

CAT_PATH = {
    "1": "xuanhuanxiaoshuo", "2": "xiuzhenxiaoshuo", "3": "dushixiaoshuo",
    "4": "chuanyuexiaoshuo", "5": "wangyouxiaoshuo", "6": "kehuanxiaoshuo",
    "7": "qitaxiaoshuo",
}

RANKS = [("vote", "推荐榜"), ("goodnum", "收藏榜"), ("newbook", "新书入库")]

RANK_PATH = {
    "vote": "/paihangbang/",
    "goodnum": "/paihangbang/goodnum.html",
    "newbook": "/paihangbang/newbook.html",
}


# ---------------------------------------------------------------- 基础

def is_bl(value):
    v = (value or "").strip()
    return v.startswith(PREFIX) or v.startswith(SCHEME)


def native_id(value):
    v = (value or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    return v.split("/")[0]


def _decode(raw, headers):
    enc = (headers.get("Content-Encoding") or "").lower()
    if "gzip" in enc:
        try:
            raw = gzip.decompress(raw)
        except OSError:
            pass
    elif "deflate" in enc:
        try:
            raw = zlib.decompress(raw, -zlib.MAX_WBITS)
        except zlib.error:
            raw = zlib.decompress(raw)
    return raw


def _get(url, data=None, timeout=25, retries=2):
    """取页面。站点偶发超时/断连，重试两次基本都能过。"""
    err = None
    for i in range(retries + 1):
        try:
            req = urllib.request.Request(url, data=data, headers=_HDR)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = _decode(r.read(), r.headers)
                ctype = r.headers.get("Content-Type", "") or ""
                enc = "utf-8"
                m = re.search(r"charset=([\w-]+)", ctype, re.I)
                if m:
                    enc = m.group(1).lower()
                if enc in ("gbk", "gb2312", "gb18030"):
                    enc = "gb18030"
                return raw.decode(enc, "ignore")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise RuntimeError("页面不存在：%s" % url)
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i < retries:
            time.sleep(0.8 * (i + 1))
    raise RuntimeError("八一中文网请求失败：%s（%s）" % (url, err))


def _text(frag):
    frag = re.sub(r"<script[\s\S]*?</script>", "", frag, flags=re.I)
    frag = re.sub(r"<style[\s\S]*?</style>", "", frag, flags=re.I)
    frag = re.sub(r"<br\s*/?>", "\n", frag, flags=re.I)
    frag = re.sub(r"</p\s*>", "\n", frag, flags=re.I)
    frag = re.sub(r"<[^>]+>", "", frag)
    frag = htmllib.unescape(frag).replace("\u00a0", " ").replace("\u3000", " ")
    frag = re.sub(r"[ \t\r\f\v]+", " ", frag)
    return frag.strip()


def _abs(href):
    if not href:
        return ""
    href = htmllib.unescape(href).strip()
    if href.startswith("//"):
        return "https:" + href
    if href.startswith("http"):
        return href
    return urllib.parse.urljoin(BASE + "/", href)


def _book_id(href):
    """从 /2/2022/ 或 http://www.81shuku.info/2/2022/ 取 2022。"""
    m = re.search(r"/(\d+)/(\d+)/?$", (href or "").strip())
    return m.group(2) if m else ""


def _cid_of(href):
    m = re.search(r"/(\d+)\.html", href or "")
    return m.group(1) if m else ""


def _cover(bid, found=""):
    """封面。详情页有 <img>，列表页没有图，按站点规律推导。"""
    if found:
        return _abs(found)
    bid = str(bid or "").strip()
    if not bid.isdigit():
        return ""
    return "%s/files/article/image/%d/%s/%ss.jpg" % (BASE, int(bid) // 1000, bid, bid)


_BAD_AUTHOR = re.compile(r"(全文免费阅读|最新章节|免费阅读|无弹窗|八一中文|一秒记住)")


def _author(raw):
    """分类页 s5 偶尔塞的是广告词（如「全文免费阅读」），这类置空。"""
    name = _text(raw)
    return "" if _BAD_AUTHOR.search(name) else name


def _status(raw):
    raw = (raw or "").strip()
    if raw in ("完成", "全本", "完结"):
        return "已完结"
    if raw in ("连载", "连载中"):
        return "连载中"
    return raw


def _word_count(raw):
    """搜索页给的是 14484K 这种，转成「1448 万字」好读一些。"""
    raw = (raw or "").strip().upper()
    m = re.match(r"^(\d+(?:\.\d+)?)\s*K$", raw)
    if not m:
        return raw
    n = float(m.group(1)) * 1000
    if n >= 10000:
        return "%.0f 万字" % (n / 10000)
    return "%d 字" % n


# ---------------------------------------------------------------- 搜索

def search(keyword, page=1):
    kw = (keyword or "").strip()
    if not kw:
        return {"books": [], "page": 1, "pages": 1}
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    body = urllib.parse.urlencode({
        "searchkey": kw, "searchtype": "articlename", "page": p,
    }).encode("utf-8")
    html = _get(BASE + "/modules/article/search.php", data=body, timeout=30)

    books = []
    seen = set()
    for tr in re.findall(r'<tr id="nr">([\s\S]*?)</tr>', html, re.I):
        tds = re.findall(r"<td[^>]*>([\s\S]*?)</td>", tr, re.I)
        if len(tds) < 3:
            continue
        am = re.search(r'<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>', tds[0], re.I)
        if not am:
            continue
        bid = _book_id(am.group(1))
        if not bid or bid in seen:
            continue
        seen.add(bid)
        lm = re.search(r'<a[^>]*>([\s\S]*?)</a>', tds[1], re.I)
        books.append({
            "id": PREFIX + bid,
            "title": _text(am.group(2)),
            "author": _text(tds[2]) if len(tds) > 2 else "",
            "cover": _cover(bid),
            "words": _word_count(_text(tds[3])) if len(tds) > 3 else "",
            "updated": _text(tds[4]) if len(tds) > 4 else "",
            "status": _status(_text(tds[5])) if len(tds) > 5 else "",
            "latest": _text(lm.group(1)) if lm else "",
            "category": "",
            "intro": "",
            "source": "八一中文网",
        })

    pages = 1
    m = re.search(r'id="pagestats"[^>]*>\s*\d+\s*/\s*(\d+)', html)
    if m:
        pages = int(m.group(1))
    if pages and p > pages:
        p = pages
    return {"books": books, "page": p, "pages": pages}


# ---------------------------------------------------------------- 分类 / 榜单

def _max_page(html, cid):
    m = re.search(r'id="pagestats"[^>]*>\s*\d+\s*/\s*(\d+)', html)
    if m:
        return max(1, int(m.group(1)))
    nums = [int(n) for n in re.findall(r"/%s_(\d+)\.html" % re.escape(cid), html)]
    return max(nums) if nums else 1


def _cat_cards(html):
    """分类页：只有左栏 div.l 是分页列表，右栏 div.r 是固定推荐位（会重复）。"""
    start = html.find('<div id="newscontent"')
    chunk = html[start:] if start > 0 else html
    lo = chunk.find('<div class="l">')
    if lo > 0:
        hi = chunk.find('<div class="r">', lo)
        chunk = chunk[lo:hi] if hi > lo else chunk[lo:]
    cards, seen = [], set()
    for li in re.findall(r"<li>([\s\S]*?)</li>", chunk, re.I):
        bm = re.search(r'class="s2"[\s\S]*?<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>', li, re.I)
        if not bm:
            continue
        bid = _book_id(bm.group(1))
        if not bid or bid in seen:
            continue
        seen.add(bid)
        am = re.search(r'class="s5"[^>]*>([\s\S]*?)</span>', li, re.I)
        lm = re.search(r'class="s3"[\s\S]*?<a[^>]*>([\s\S]*?)</a>', li, re.I)
        title = _text(bm.group(2)).strip("《》 ")
        cards.append({
            "id": PREFIX + bid,
            "title": title,
            "author": _author(am.group(1)) if am else "",
            "cover": _cover(bid),
            "latest": _text(lm.group(1)) if lm else "",
            "category": "",
            "status": "",
            "intro": "",
            "source": "八一中文网",
        })
    return cards


def sort(cid, page=1):
    """分类列表。cid 1..7。"""
    cid = cid if cid in CAT_PATH else "1"
    name = dict(CATS)[cid]
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    url = "%s/%s/%s_%d.html" % (BASE, CAT_PATH[cid], cid, p)
    html = _get(url, timeout=30)
    total = _max_page(html, cid)
    if p > total:
        p = total
        html = _get("%s/%s/%s_%d.html" % (BASE, CAT_PATH[cid], cid, p), timeout=30)
    books = _cat_cards(html)
    for b in books:
        b["category"] = name + "小说"
    return {"title": name + "小说", "books": books, "page": p,
            "pages": total, "cats": CATS}


def ranking(kind):
    """榜单。每榜按分类分 8 块，取「全部小说 xxx」那块做全站列表。"""
    kind = kind if kind in RANK_PATH else "vote"
    title = dict(RANKS)[kind]
    html = _get(BASE + RANK_PATH[kind], timeout=30)
    blocks = []
    for chunk in re.split(r'<div class="box b\d">', html)[1:]:
        h3 = re.search(r"<h3>([^<]*)</h3>", chunk)
        items = re.findall(r'<li>(\d+)<a href="([^"]+)">([^<]+)</a></li>', chunk)
        if not items:
            continue
        blocks.append((_text(h3.group(1)) if h3 else title, items))

    # 优先「全部小说」，没有就把各分类块拼起来
    pick = None
    for name, items in blocks:
        if "全部小说" in name:
            pick = items
            break
    if pick is None:
        pick = [it for _, items in blocks for it in items]

    books, seen = [], set()
    for rank, href, name in pick:
        bid = _book_id(href)
        if not bid or bid in seen:
            continue
        seen.add(bid)
        books.append({
            "id": PREFIX + bid,
            "title": _text(name),
            "author": "",
            "cover": _cover(bid),
            "rank": int(rank) if rank.isdigit() else len(books) + 1,
            "category": "",
            "status": "",
            "latest": "",
            "intro": "",
            "source": "八一中文网",
        })
    if not books:
        raise RuntimeError("八一中文网：这个榜单暂时取不到内容")
    return {"title": title, "books": books, "page": 1, "pages": 1,
            "note": "八一中文网%s · %d 本" % (title, len(books))}


# ---------------------------------------------------------------- 详情 / 目录

def book(book_id):
    bid = native_id(book_id)
    if not bid:
        raise RuntimeError("缺少八一中文网书籍 id")
    url = "%s/%d/%s/" % (BASE, int(bid) // 1000, bid)
    html = _get(url, timeout=40)

    tm = re.search(r'<div id="info">\s*<h1>([\s\S]*?)</h1>', html, re.I)
    title = _text(tm.group(1)) if tm else ""
    if not title:
        tm = re.search(r"<title>([\s\S]*?)</title>", html)
        title = _text(tm.group(1)).split("_")[0] if tm else ("书籍" + bid)

    am = re.search(r"作\s*(?:&nbsp;)*\s*者[：:]\s*([^<]*)<", html)
    author = _text(am.group(1)) if am else ""
    um = re.search(r"最后更新[：:]\s*([^<]*)<", html)
    updated = _text(um.group(1)) if um else ""

    cm = re.search(r'<div id="fmimg">\s*<img[^>]*src=[\'"]([^\'"]+)', html, re.I)
    cover = _cover(bid, cm.group(1) if cm else "")

    im = re.search(r'<div id="intro">\s*<p>([\s\S]*?)</p>', html, re.I)
    intro = _text(im.group(1)) if im else ""
    intro = re.sub(r"\n{2,}", "\n", intro)

    chapters, seen = [], set()
    start = html.find('<div id="list"')
    toc = html[start:] if start > 0 else html
    # 目录分两块 dt：「最新章节」（前 9 条，倒序）和「正文」（全量正序）。
    # 只取最后一块，否则开头会是最新章而不是第一章。
    parts = re.split(r"<dt[^>]*>", toc)
    body = parts[-1] if len(parts) > 1 else toc
    raw = re.findall(r"<dd>\s*<a[^>]*href=[\'\"]([^\'\"]+)[\'\"][^>]*>([\s\S]*?)</a>", body, re.I)
    for href, name in raw:
        cid = _cid_of(href)
        if not cid or cid in seen:
            continue
        seen.add(cid)
        nm = _text(name)
        if not nm:
            continue
        chapters.append({"t": nm, "u": "%s%s/%s.html" % (SCHEME, bid, cid)})

    if not chapters:
        raise RuntimeError("八一中文网：这本暂时取不到目录")

    return {
        "id": PREFIX + bid,
        "title": title,
        "author": author,
        "cover": cover,
        "category": "",
        "status": "",
        "intro": intro,
        "updated": updated,
        "url": url,
        "chapters": chapters,
        "count": len(chapters),
        "words": "",
        "score": "",
        "latest": chapters[-1]["t"] if chapters else "",
        "tags": [],
        "source": "八一中文网",
    }


# ---------------------------------------------------------------- 正文

_JUNK = re.compile(r"(81shuku|八一中文|一秒记住|请记住本站|最新章节请|手机版阅读)")

def chapter(url):
    v = (url or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    m = re.match(r"^(\d+)/(\d+)(?:\.html)?", v)
    if not m:
        raise RuntimeError("八一中文网章节地址不对：%s" % url)
    bid, cid = m.group(1), m.group(2)
    html = _get("%s/%d/%s/%s.html" % (BASE, int(bid) // 1000, bid, cid), timeout=30)

    tm = re.search(r'<div class="bookname">\s*<h1>([\s\S]*?)</h1>', html, re.I)
    title = _text(tm.group(1)) if tm else ""

    i = html.find('id="content"')
    if i < 0:
        raise RuntimeError("这一章没有取到内容")
    j = html.find("</div>", i)
    body = html[i:j] if j > i else html[i:]
    body = re.sub(r"^\s*id=\"content\"\s*>?", "", body)

    paras = []
    for line in _text(body).split("\n"):
        line = line.strip()
        if not line or _JUNK.search(line):
            continue
        paras.append(line)
    if not paras:
        raise RuntimeError("这一章没有取到内容")

    prev_cid = next_cid = ""
    nav = html[html.find('class="bottem1"'):html.find('class="bottem1"') + 900]
    links = re.findall(r'<a[^>]*href=[\'"]([^\'"]+)[\'"][^>]*>([^<]*)</a>', nav)
    for href, label in links:
        label = _text(label)
        c = _cid_of(href)
        if not c:
            continue
        if "上一章" in label:
            prev_cid = c
        elif "下一章" in label:
            next_cid = c

    return {
        "title": title,
        "bookTitle": "",
        "paras": paras,
        "prev": "%s%s/%s.html" % (SCHEME, bid, prev_cid) if prev_cid else "",
        "next": "%s%s/%s.html" % (SCHEME, bid, next_cid) if next_cid else "",
        "prevPage": "",
        "nextPage": "",
        "url": "%s%s/%s.html" % (SCHEME, bid, cid),
        "chars": sum(len(p) for p in paras),
        "bookId": PREFIX + bid,
        "source": "八一中文网",
    }


if __name__ == "__main__":
    import json
    import sys

    what = sys.argv[1] if len(sys.argv) > 1 else "search"
    if what == "search":
        print(json.dumps(search(sys.argv[2] if len(sys.argv) > 2 else "凡人修仙传"),
                         ensure_ascii=False, indent=1)[:1200])
    elif what == "sort":
        print(json.dumps(sort(sys.argv[2] if len(sys.argv) > 2 else "1"),
                         ensure_ascii=False, indent=1)[:800])
    elif what == "rank":
        print(json.dumps(ranking(sys.argv[2] if len(sys.argv) > 2 else "vote"),
                         ensure_ascii=False, indent=1)[:800])
    elif what == "book":
        print(json.dumps(book(sys.argv[2]), ensure_ascii=False, indent=1)[:1200])
    elif what == "chapter":
        print(json.dumps(chapter(sys.argv[2]), ensure_ascii=False, indent=1)[:1200])
