"""
得奇小说网（deqixss.com）抓取层。

站点是杰奇 CMS 的改版模板，但正文做了异步拆分：
  - 搜索  GET /modules/article/search.php?searchkey=xxx（一页 40 条，无翻页；
          书名精确命中时站点直接 302 到 /books/{id}/）
  - 书库  /sort/{cid}/{page}.html，10 个分类，每页 30 本
  - 榜单  /top/{order}/{page}.html，每页 30 本，最多 288 页
  - 全本  /modules/article/toplist.php?order=allvisit&fullflag=1&page=N
  - 详情  /books/{id}/  一次给全量目录（#list-chapterAll，两千多章约 90KB）
  - 正文  章节页里的 #chapter-content 是空的，真正正文由
          /modules/article/ajax2.php 返回 JSON；token/timestamp/nonce 由
          /scripts/chapter.js.php?aid=&cid= 现发，且**绑定 cid**，换一章就得重新取。

正文接口的两个坑：
  1. 必须带 X-Requested-With: XMLHttpRequest，缺了只回 {"status":0}（跟 cookie 无关）；
  2. token 与 cid 一一对应，缓存一本书的 token 去请求别的章会失败。
"""
import html as htmllib
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://www.deqixss.com"
PREFIX = "dq:"
SCHEME = "dq://"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

_HDR = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Referer": BASE + "/",
}

CATS = [
    ("1", "玄幻"), ("2", "都市"), ("3", "仙侠"), ("4", "历史"), ("5", "科幻"),
    ("6", "诸天无限"), ("7", "悬疑"), ("8", "体育"), ("9", "游戏"), ("10", "综合"),
]

RANKS = [
    ("allvisit", "总点击"), ("monthvisit", "月点击"), ("allvote", "总推荐"),
    ("goodnum", "收藏"), ("words", "字数"), ("newhot", "新书"), ("full", "全本"),
]

_FULL_URL = "/modules/article/toplist.php?order=allvisit&fullflag=1&page=%d"


# ---------------------------------------------------------------- 基础

def is_dq(value):
    v = (value or "").strip()
    return v.startswith(PREFIX) or v.startswith(SCHEME)


def native_id(value):
    v = (value or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    return v.split("/")[0]


def _get(url, timeout=30, retries=2, xhr=False, referer=None):
    """取页面，顺带把最终地址返回（搜索精确命中会 302 到书页）。"""
    err = None
    for i in range(retries + 1):
        try:
            hdr = dict(_HDR)
            if referer:
                hdr["Referer"] = referer
            if xhr:
                hdr["X-Requested-With"] = "XMLHttpRequest"
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                ctype = r.headers.get("Content-Type", "") or ""
                enc = "utf-8"
                m = re.search(r"charset=([\w-]+)", ctype, re.I)
                if m:
                    enc = m.group(1).lower()
                if enc in ("gbk", "gb2312", "gb18030"):
                    enc = "gb18030"
                return raw.decode(enc, "ignore"), r.geturl()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise RuntimeError("页面不存在：%s" % url)
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i < retries:
            time.sleep(0.7 * (i + 1))
    raise RuntimeError("得奇小说网请求失败：%s（%s）" % (url, err))


def _text(frag):
    frag = re.sub(r"<script[\s\S]*?</script>", "", frag, flags=re.I)
    frag = re.sub(r"<style[\s\S]*?</style>", "", frag, flags=re.I)
    frag = re.sub(r"<br\s*/?>", "\n", frag, flags=re.I)
    frag = re.sub(r"</p\s*>", "\n", frag, flags=re.I)
    frag = re.sub(r"<[^>]+>", "", frag)
    frag = htmllib.unescape(frag).replace("\u00a0", " ").replace("\u3000", " ")
    frag = re.sub(r"[ \t\r\f\v]+", " ", frag)
    return frag.strip()


def _book_id(href):
    m = re.search(r"/books/(\d+)/?(?:[?#]|$)", (href or "").strip())
    return m.group(1) if m else ""


def _cid_of(href):
    m = re.search(r"/books/(\d+)/(\d+)\.html", (href or "").strip())
    return m.group(2) if m else ""


def _cover(bid, found=""):
    """封面。详情页有 <img>，列表页没有图，按站点规律推导。"""
    if found:
        found = found.strip()
        if found.startswith("//"):
            return "https:" + found
        if found.startswith("http"):
            return found
        return urllib.parse.urljoin(BASE + "/", found)
    bid = str(bid or "").strip()
    if not bid.isdigit():
        return ""
    return "%s/files/article/image/%d/%s/%ss.jpg" % (BASE, int(bid) // 1000, bid, bid)


def _words(raw):
    """详情/榜单里是 <script>towan('5582402')</script>万字，换算成「558 万字」。"""
    n = str(raw or "").strip()
    if not n.isdigit():
        return n
    n = int(n)
    if n >= 10000:
        return "%.0f 万字" % (n / 10000.0)
    return "%d 字" % n


def _status(raw):
    raw = (raw or "").strip()
    if raw in ("全本", "完结", "完成"):
        return "已完结"
    if raw in ("连载", "连载中"):
        return "连载中"
    return raw


def _num(raw):
    """"阅读量：373846" / "871人读过" 取数字。"""
    m = re.search(r"([\d.]+)", (raw or "").replace(",", ""))
    return m.group(1) if m else ""


# ---------------------------------------------------------------- 列表行解析

_ROW = re.compile(r'<div class="bookbox">([\s\S]*?)<div class="delbutton">', re.I)


def _rows(html):
    """搜索 / 书库 / 榜单共用同一套 div.bookbox 结构。"""
    books, seen = [], set()
    for chunk in _ROW.findall(html):
        nm = re.search(r'<h4 class="bookname">\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>', chunk, re.I)
        if not nm:
            continue
        bid = _book_id(nm.group(1))
        if not bid or bid in seen:
            continue
        seen.add(bid)

        authors = re.findall(r'<div class="author">([\s\S]*?)</div>', chunk, re.I)
        author, reads = "", ""
        for a in authors:
            t = _text(a)
            if t.startswith("作者"):
                author = re.sub(r"^作\s*者[：:]\s*", "", t)
            elif t.startswith("阅读量"):
                reads = _num(t)
        # 字数塞在 <script>towan('5582402')</script> 里，_text 会把脚本剥掉，
        # 所以要从原始片段里取
        wm = re.search(r"towan\('(\d+)'\)", chunk)
        words = _words(wm.group(1)) if wm else ""

        lm = re.search(r'<div class="cat">[\s\S]*?<a[^>]*>([\s\S]*?)</a>', chunk, re.I)
        im = re.search(r'<div class="update">([\s\S]*?)</div>', chunk, re.I)
        rm = re.search(r'<span class="num">(\d+)</span>', chunk)
        intro = _text(im.group(1)) if im else ""
        intro = re.sub(r"^简\s*介[：:]\s*", "", intro)

        books.append({
            "id": PREFIX + bid,
            "title": _text(nm.group(2)),
            "author": author,
            "cover": _cover(bid),
            "words": words,
            "read": reads,
            "latest": _text(lm.group(1)) if lm else "",
            "intro": intro,
            "category": "",
            "status": "",
            "rank": int(rm.group(1)) if rm else 0,
            "source": "得奇小说网",
        })
    return books


# ---------------------------------------------------------------- 搜索

def search(keyword, page=1):
    kw = (keyword or "").strip()
    if not kw:
        return {"books": [], "page": 1, "pages": 1}
    url = "%s/modules/article/search.php?searchkey=%s" % (
        BASE, urllib.parse.quote(kw))
    html, final = _get(url, timeout=30)

    # 书名精确命中时站点直接 302 到书页，这里补一条结果
    bid = _book_id(urllib.parse.urlsplit(final).path)
    if bid and 'class="booktitle"' in html:
        b = _detail_core(html, bid)
        b.update({"words": b.get("words", ""), "read": b.get("read", "")})
        return {"books": [b], "page": 1, "pages": 1}

    books = _rows(html)
    return {"books": books, "page": 1, "pages": 1}


# ---------------------------------------------------------------- 分类 / 榜单

def _max_page(html, pattern):
    """总页数优先取 <em id="pagestats">当前/总数</em>；
    分页链接里只渲染当前页附近的几个数字，最大值不可靠（999/289 时会给 998）。"""
    m = re.search(r'id="pagestats"[^>]*>\s*\d+\s*/\s*(\d+)', html)
    if m:
        return max(1, int(m.group(1)))
    nums = [int(n) for n in re.findall(pattern, html) if n.isdigit()]
    return max(nums) if nums else 1


def sort(cid, page=1):
    """书库分类。cid 1..10，每页 30 本。"""
    cid = cid if cid in dict(CATS) else "1"
    name = dict(CATS)[cid]
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    url = "%s/sort/%s/%d.html" % (BASE, cid, p)
    html, _ = _get(url, timeout=30)
    total = _max_page(html, r"/sort/%s/(\d+)\.html" % cid)
    if p > total:
        p = total
        html, _ = _get("%s/sort/%s/%d.html" % (BASE, cid, p), timeout=30)
    books = _rows(html)
    for b in books:
        b["category"] = name + "小说"
    return {"title": name + "小说", "books": books, "page": p,
            "pages": total, "cats": CATS}


def ranking(kind, page=1):
    """榜单。kind 见 RANKS；full 走「全本」筛选，其余走 /top/{order}/。"""
    kind = kind if kind in dict(RANKS) else "allvisit"
    title = dict(RANKS)[kind]
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    if kind == "full":
        url = BASE + _FULL_URL % p
        html, _ = _get(url, timeout=30)
        total = _max_page(html, r"fullflag=1&(?:amp;)?page=(\d+)")
        label = "全本"
    else:
        url = "%s/top/%s/%d.html" % (BASE, kind, p)
        html, _ = _get(url, timeout=30)
        total = _max_page(html, r"/top/%s/(\d+)\.html" % kind)
        label = re.findall(r'<h2[^>]*>([^<]*)</h2>', html)
        label = _text(label[0]) if label else title + "榜"

    if p > total:
        p = total
        html, _ = _get(BASE + _FULL_URL % p if kind == "full"
                       else "%s/top/%s/%d.html" % (BASE, kind, p), timeout=30)
    books = _rows(html)
    if not books:
        raise RuntimeError("得奇小说网：这个榜单暂时取不到内容")
    return {"title": title + "榜", "books": books, "page": p, "pages": total,
            "note": "得奇小说网 · %s · %d 本" % (label, len(books))}


# ---------------------------------------------------------------- 详情 / 目录

def _detail_core(html, bid):
    tm = re.search(r'<h1 class="booktitle">([\s\S]*?)</h1>', html, re.I)
    title = _text(tm.group(1)) if tm else ""
    if not title:
        tm = re.search(r"<title>([\s\S]*?)</title>", html)
        title = _text(tm.group(1)).split("_")[0] if tm else ("书籍" + bid)

    am = re.search(r'<p class="booktag">[\s\S]{0,200}?<a class="red"[^>]*>([\s\S]*?)</a>', html, re.I)
    author = _text(am.group(1)) if am else ""

    wm = re.search(r"towan\('(\d+)'\)", html)
    words = _words(wm.group(1)) if wm else ""

    rd = re.search(r">\s*([\d,]+)\s*人读过", html)
    read = _num(rd.group(1)) if rd else ""

    sm = re.findall(r'<span class="red">([^<]{1,6})</span>', html)
    status = _status(sm[-1]) if sm else ""

    cm = re.search(r'<div class="bookcover[^"]*">\s*<img[^>]*src="([^"]+)"', html, re.I)
    cover = _cover(bid, cm.group(1) if cm else "")

    im = re.search(r'<p class="bookintro">([\s\S]*?)</p>', html, re.I)
    intro = _text(im.group(1)) if im else ""
    intro = re.sub(r"\n{2,}", "\n", intro).strip()

    km = re.search(r'<ol class="breadcrumb">([\s\S]*?)</ol>', html, re.I)
    category = ""
    if km:
        links = re.findall(r'<a[^>]*href="[^"]*sort/[^"]*"[^>]*>([\s\S]*?)</a>', km.group(1), re.I)
        category = _text(links[0]) if links else ""

    lm = re.search(r'<a class="bookchapter"[^>]*>([\s\S]*?)</a>', html, re.I)
    latest = _text(lm.group(1)) if lm else ""

    um = re.search(r'<p class="booktime">([\s\S]*?)</p>', html, re.I)
    updated = re.sub(r"^更新时间[：:]\s*", "", _text(um.group(1))) if um else ""

    return {
        "id": PREFIX + bid,
        "title": title,
        "author": author,
        "cover": cover,
        "category": category,
        "status": status,
        "intro": intro,
        "updated": updated,
        "words": words,
        "read": read,
        "score": "",
        "latest": latest,
        "tags": [category] if category else [],
        "source": "得奇小说网",
    }


def book(book_id):
    bid = native_id(book_id)
    if not bid:
        raise RuntimeError("缺少得奇小说网书籍 id")
    url = "%s/books/%s/" % (BASE, bid)
    html, _ = _get(url, timeout=40)

    data = _detail_core(html, bid)

    # 目录：整本书一次给完，div#list-chapterAll 里是正序全量；
    # 这个 div 之前还有一段「最新章节」的 dd，不能整页抓。
    start = html.find('<div id="list-chapterAll"')
    end = html.find("</div>", start) if start > 0 else -1
    toc = html[start:end] if start > 0 and end > start else html
    chapters, seen = [], set()
    for href, name in re.findall(
            r'<dd>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>', toc, re.I):
        cid = _cid_of(href)
        if not cid or cid in seen:
            continue
        seen.add(cid)
        nm = _text(name)
        if not nm or "查看全部章节" in nm:
            continue
        chapters.append({"t": nm, "u": "%s%s/%s.html" % (SCHEME, bid, cid)})

    if not chapters:
        raise RuntimeError("得奇小说网：这本暂时取不到目录")

    data.update({
        "url": url,
        "chapters": chapters,
        "count": len(chapters),
        "latest": data.get("latest") or chapters[-1]["t"],
    })
    return data


# ---------------------------------------------------------------- 正文

_JUNK = re.compile(
    r"(速读谷|速\.读\.谷|速 读 谷|shudugu\.org|更新不易|邀请码|本章节未完"
    r"|得奇小说网|请记住本站|一秒记住|最新网址|\(本章完\)|（本章完）)")


def _token(bid, cid):
    url = "%s/scripts/chapter.js.php?aid=%s&cid=%s&referrer=%s/books/%s/%s.html" % (
        BASE, bid, cid, BASE, bid, cid)
    js, _ = _get(url, timeout=20, referer="%s/books/%s/%s.html" % (BASE, bid, cid))
    m = re.search(
        r"chapterToken = '([^']*)'[\s\S]*?timestamp = (\d+)[\s\S]*?nonce = '([^']*)'", js)
    if not m:
        raise RuntimeError("得奇小说网：这一章没拿到正文 token")
    return m.groups()


def chapter(url):
    v = (url or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    m = re.match(r"^(\d+)/(\d+)(?:\.html)?", v)
    if not m:
        raise RuntimeError("得奇小说网章节地址不对：%s" % url)
    bid, cid = m.group(1), m.group(2)
    page_url = "%s/books/%s/%s.html" % (BASE, bid, cid)

    html, _ = _get(page_url, timeout=30)

    tm = re.search(r'<h1[^>]*>([\s\S]*?)</h1>', html, re.I)
    title = _text(tm.group(1)) if tm else ""
    title = re.sub(r"\s*\(第[^)]*页\)\s*$", "", title)

    token, ts, nonce = _token(bid, cid)
    api = "%s/modules/article/ajax2.php?aid=%s&cid=%s&token=%s&timestamp=%s&nonce=%s" % (
        BASE, bid, cid, urllib.parse.quote(token), ts, urllib.parse.quote(nonce))
    # Referer 必须是本章页地址，站点会校验；写成站点根域会回「Token验证失败」
    raw, _ = _get(api, timeout=30, xhr=True, referer=page_url)
    try:
        payload = json.loads(raw)
    except ValueError:
        raise RuntimeError("得奇小说网：正文接口返回的不是 JSON")
    if payload.get("status") != 1:
        raise RuntimeError("得奇小说网：正文接口拒绝了请求（%s）"
                           % (payload.get("message") or "status!=1"))
    body = ((payload.get("data") or {}).get("content") or "").strip()
    if not body:
        raise RuntimeError("这一章没有取到内容")

    paras = []
    for line in _text(body).split("\n"):
        line = line.strip()
        if not line or _JUNK.search(line):
            continue
        paras.append(line)
    # 站点把章节名写在正文第一行，阅读器自己会显示标题，去掉以免重复
    if paras and (paras[0] == title or paras[0].startswith(title)):
        paras.pop(0)
    if not paras:
        raise RuntimeError("这一章没有取到内容")

    # 上一章/下一章写在页面 loadChapter() 里；第一章给书页、最后一章给 lastchapter.php
    prev_cid = next_cid = ""
    fm = re.search(r"direction === 'prev'\)\s*\{\s*chapterUrl = '([^']*)';"
                   r"[\s\S]{0,200}?chapterUrl = '([^']*)';", html)
    if fm:
        prev_cid = _cid_of(fm.group(1))
        next_cid = _cid_of(fm.group(2))

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
        "source": "得奇小说网",
    }


if __name__ == "__main__":
    import sys

    what = sys.argv[1] if len(sys.argv) > 1 else "search"
    if what == "search":
        print(json.dumps(search(sys.argv[2] if len(sys.argv) > 2 else "凡人修仙传"),
                         ensure_ascii=False, indent=1)[:1200])
    elif what == "sort":
        print(json.dumps(sort(sys.argv[2] if len(sys.argv) > 2 else "1"),
                         ensure_ascii=False, indent=1)[:800])
    elif what == "rank":
        print(json.dumps(ranking(sys.argv[2] if len(sys.argv) > 2 else "allvisit"),
                         ensure_ascii=False, indent=1)[:800])
    elif what == "book":
        print(json.dumps(book(sys.argv[2]), ensure_ascii=False, indent=1)[:1200])
    elif what == "chapter":
        print(json.dumps(chapter(sys.argv[2]), ensure_ascii=False, indent=1)[:1200])
