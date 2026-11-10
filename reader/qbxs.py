"""
全本小说网（qbxs.net）抓取层。

站点是传统杰奇类模板，纯 HTML，无 JS 接口：
  - 搜索  /search/?searchkey=关键词（表格 id=rankinglist）
  - 详情  /book/{bid}/ 一次给全量目录（两千多章约 230KB）
  - 正文  /read/{bid}/{cid}.html，长章节拆成 _2.html、_3.html 续页
  - 分类  /sort/{cid}/{page}/  完结 /quanben/sort/{page}/
  - 排行  /rank/ /rank/allvisit/ 等 5 个榜

站点对非浏览器 UA 返回 403，请求头必须带桌面 Chrome UA。
"""
import html as htmllib
import re
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://www.qbxs.net"
# 移动网络下 www 入口偶发连不上 / 证书链异常，无 www 的官方域名是同一套站点
ALT_BASE = "https://qbxs.net"
PREFIX = "qb:"
SCHEME = "qb://"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

_HDR = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,"
              "image/webp,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
    # 明确不接收压缩，移动网关偶发返回 gzip 会让正文变成乱码
    "Accept-Encoding": "identity",
    "Referer": BASE + "/",
}

CATS = [
    ("1", "玄幻"), ("2", "修真"), ("3", "都市"), ("4", "历史"),
    ("5", "网游"), ("6", "科幻"), ("7", "其他"),
]

RANKS = [
    ("", "总排行榜"),
    ("allvisit", "总点击榜"),
    ("monthvisit", "月点击榜"),
    ("weekvisit", "周点击榜"),
    ("goodnum", "收藏榜"),
]


# ---------------------------------------------------------------- 基础

def is_qb(value):
    v = (value or "").strip()
    return v.startswith(PREFIX) or v.startswith(SCHEME)


def native_id(value):
    v = (value or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    return v.split("/")[0]


def _get(url, timeout=12, retries=2):
    """取页面。

    手机弱网下单次超时不能太长：原来 25s×3 最长 75 秒，必然被前端掐断。
    现在主入口试几次（短超时），全失败再换无 www 的官方域名兜底一次，
    整条链路控制在 ~35 秒内；证书校验失败由 reader.net 自动降级重试。
    """
    from . import net

    def once(u, t):
        req = urllib.request.Request(u, headers=_HDR)
        with urllib.request.urlopen(req, timeout=t) as r:
            raw = r.read()
            ctype = r.headers.get("Content-Type", "") or ""
            enc = "utf-8"
            m = re.search(r"charset=([\w-]+)", ctype, re.I)
            if m:
                enc = m.group(1).lower()
            if enc in ("gbk", "gb2312", "gb18030"):
                enc = "gb18030"
            return raw.decode(enc, "ignore")

    err = None
    for i in range(retries + 1):
        try:
            return once(url, timeout)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise RuntimeError("页面不存在：%s" % url)
            err = e
            break  # 403 之类的状态码换域名也一样，别浪费时间
        except Exception as e:  # noqa: BLE001
            err = e
        if i < retries:
            time.sleep(0.5 * (i + 1))

    # 兜底入口：仅当主域名整体不可达时尝试
    if url.startswith(BASE):
        alt = ALT_BASE + url[len(BASE):]
        try:
            return once(alt, timeout)
        except Exception as e2:  # noqa: BLE001
            err = e2
    raise RuntimeError("全本小说网请求失败：%s" % net.friendly(err))


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


def _cover(bid, found=""):
    """封面地址。

    搜索页、榜单页是纯表格，页面本身不含图片；但站点封面路径是固定规律：
    /images/{bid//1000}/{bid}/{bid}s.jpg（实测 59 本里 58 本命中）。
    所以列表页用推导地址，前端 onerror 会降级成书名首字色块。
    """
    if found:
        return _abs(found)
    bid = str(bid or "").strip()
    if not bid.isdigit():
        return ""
    return "%s/images/%d/%s/%ss.jpg" % (BASE, int(bid) // 1000, bid, bid)


def _book_id(href):
    m = re.search(r"/book/(\d+)/?", href or "")
    return m.group(1) if m else ""


# ---------------------------------------------------------------- 解析

def _table_rows(html):
    """解析 table#rankinglist 的正文行，搜索与排行榜共用。"""
    m = re.search(r'<table[^>]*id="rankinglist"[\s\S]*?</table>', html, re.I)
    if not m:
        return []
    rows = []
    for tr in re.findall(r"<tr[^>]*>([\s\S]*?)</tr>", m.group(0), re.I):
        tds = re.findall(r"<td[^>]*>([\s\S]*?)</td>", tr, re.I)
        if len(tds) < 3:
            continue
        am = re.search(r'<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>', tds[0], re.I)
        if not am:
            continue
        bid = _book_id(am.group(1))
        if not bid:
            continue
        latest = ""
        if len(tds) > 1:
            lm = re.search(r'<a[^>]*>([\s\S]*?)</a>', tds[1], re.I)
            latest = _text(lm.group(1)) if lm else _text(tds[1])
        rows.append({
            "id": PREFIX + bid,
            "title": _text(am.group(2)),
            "author": _text(tds[2]) if len(tds) > 2 else "",
            "cover": _cover(bid),
            "category": _text(tds[3]) if len(tds) > 3 else "",
            "updated": _text(tds[4]) if len(tds) > 4 else "",
            "status": _status(_text(tds[5]) if len(tds) > 5 else ""),
            "latest": latest,
        })
    return rows


def _status(raw):
    raw = (raw or "").strip()
    if raw == "全本":
        return "已完结"
    if raw == "连载":
        return "连载中"
    return raw


def _cards(html):
    """解析 /sort/、/quanben/ 的卡片块 div.tt。"""
    cards = []
    for chunk in re.split(r'<div class="tt">', html)[1:]:
        chunk = chunk.split('<div class="clear">')[0]
        hm = re.search(r'<h3>\s*<a href="(/book/\d+/)"[^>]*>([\s\S]*?)</a>', chunk, re.I)
        if not hm:
            continue
        bid = _book_id(hm.group(1))
        cm = re.search(r'<span class="pic">[\s\S]*?<img[^>]*src="([^"]+)"', chunk, re.I)
        am = re.search(r'<p class="p1">[\s\S]*?作者[：:]\s*([^<]*)</a>', chunk, re.I)
        im = re.search(r'<p class="p2">([\s\S]*?)</p>', chunk, re.I)
        cards.append({
            "id": PREFIX + bid,
            "title": _text(hm.group(2)),
            "author": _text(am.group(1)) if am else "",
            "cover": _cover(bid, cm.group(1) if cm else ""),
            "intro": _text(im.group(1)) if im else "",
            "category": "",
            "status": "",
            "latest": "",
            "source": "全本小说网",
        })
    return cards


def _max_page(html, prefix):
    nums = [int(n) for n in re.findall(re.escape(prefix) + r"(\d+)/", html)]
    return max(nums) if nums else 1


# ---------------------------------------------------------------- 搜索 / 浏览

def search(keyword, page=1):
    kw = (keyword or "").strip()
    if not kw:
        return {"books": [], "page": 1, "pages": 1}
    url = BASE + "/search/?searchkey=" + urllib.parse.quote(kw)
    rows = _table_rows(_get(url))
    books = []
    for b in rows:
        b = dict(b)
        b["source"] = "全本小说网"
        books.append(b)
    return {"books": books, "page": 1, "pages": 1}


def ranking(kind, page=1):
    if kind == "all":
        kind = ""
    kind = kind if kind in [k for k, _ in RANKS] else ""
    title = dict(RANKS)[kind]
    url = BASE + ("/rank/%s/" % kind if kind else "/rank/")
    rows = _table_rows(_get(url))
    books = []
    for i, b in enumerate(rows):
        b = dict(b)
        b.update({"rank": i + 1, "source": "全本小说网"})
        books.append(b)
    return {"title": title, "books": books, "page": 1, "pages": 1,
            "note": "全本小说网官方榜单 · 每榜 50 本"}


def sort(cid, page=1):
    """分类列表。cid 为空表示全部完结。"""
    cid = cid if cid in [c for c, _ in CATS] else "1"
    name = dict(CATS)[cid]
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    url = "%s/sort/%s/%d/" % (BASE, cid, p)
    html = _get(url)
    total = _max_page(html, "/sort/%s/" % cid)
    if p > total:
        p = total
        html = _get("%s/sort/%s/%d/" % (BASE, cid, p))
    books = _cards(html)
    for b in books:
        b["category"] = name + "小说"
    return {"title": name + "小说", "books": books, "page": p,
            "pages": total, "cats": CATS}


def quanben(page=1):
    """完结小说，全站混排。"""
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    html = _get("%s/quanben/sort/%d/" % (BASE, p))
    total = _max_page(html, "/quanben/sort/")
    if p > total:
        p = total
        html = _get("%s/quanben/sort/%d/" % (BASE, p))
    books = _cards(html)
    for b in books:
        b["status"] = "已完结"
    return {"title": "完结小说", "books": books, "page": p, "pages": total}


# ---------------------------------------------------------------- 详情 / 目录

def book(book_id):
    bid = native_id(book_id)
    if not bid:
        raise RuntimeError("缺少全本小说网书籍 id")
    url = "%s/book/%s/" % (BASE, bid)
    html = _get(url, timeout=18)

    tm = re.search(r'<div class="introduce">\s*<h1>([\s\S]*?)</h1>', html)
    title = _text(tm.group(1)) if tm else ""
    if not title:
        tm = re.search(r"<title>([\s\S]*?)</title>", html)
        title = _text(tm.group(1)).split("_")[0] if tm else ("书籍" + bid)

    am = re.search(r'<span>作者[：:]\s*<a[^>]*>([\s\S]*?)</a>', html)
    author = _text(am.group(1)) if am else ""
    sm = re.search(r"<span>状态[：:]\s*([^<]*)</span>", html)
    status = _text(sm.group(1)) if sm else ""
    if status == "全本":
        status = "已完结"
    elif status == "连载":
        status = "连载中"
    um = re.search(r"<span>更新[：:]\s*([^<]*)</span>", html)
    updated = _text(um.group(1)) if um else ""
    cm = re.search(r'<div class="pic">\s*<img[^>]*src="([^"]+)"', html)
    cover = _cover(bid, cm.group(1) if cm else "")
    im = re.search(r'<p class="jj">([\s\S]*?)</p>', html)
    intro = _text(im.group(1)) if im else ""
    lm = re.search(r'<p class="lastchapter">[\s\S]*?<a[^>]*>([\s\S]*?)</a>', html)
    latest = _text(lm.group(1)) if lm else ""
    latest = re.sub(r"^《[^》]*》", "", latest).strip()

    chapters, seen = [], set()
    toc = html
    start = toc.find('<div class="ml_list">')
    if start > 0:
        toc = toc[start:]
    for m in re.finditer(r'<li>\s*<a[^>]*href="(/read/\d+/\d+\.html)"[^>]*>([\s\S]*?)</a>', toc):
        href = m.group(1)
        cid = re.search(r"/(\d+)\.html", href)
        if not cid or cid.group(1) in seen:
            continue
        seen.add(cid.group(1))
        name = _text(m.group(2))
        if not name:
            continue
        chapters.append({"t": name, "u": "%s%s/%s.html" % (SCHEME, bid, cid.group(1))})

    if not chapters:
        raise RuntimeError("全本小说网：这本暂时取不到目录")

    return {
        "id": PREFIX + bid,
        "title": title,
        "author": author,
        "cover": cover,
        "category": "",
        "status": status,
        "intro": intro,
        "updated": updated,
        "url": url,
        "chapters": chapters,
        "count": len(chapters),
        "words": "",
        "score": "",
        "latest": latest or (chapters[-1]["t"] if chapters else ""),
        "tags": [],
        "publisher": "全本小说网",
        "statement": "",
        "source": "全本小说网",
    }


# ---------------------------------------------------------------- 正文

def _is_ad(line):
    if not line:
        return True
    low = line.lower()
    if "qbxs" in low or "一秒记住" in line or "[全本小说]" in line:
        return True
    if "全本小说网" in line and len(line) < 40:
        return True
    # 纯装饰性水印（如 𝑄 𝓑 Ⓧ 𝚂 . n e t）不含汉字
    return not re.search(r"[\u4e00-\u9fff]", line)


def _chapter_parts(html):
    """取当前页的标题、段落、上一页/下一页链接。"""
    tm = re.search(r'<div class="nr_title">\s*<h3>([\s\S]*?)</h3>', html)
    title = _text(tm.group(1)) if tm else ""
    title = re.sub(r"^章节目录\s*", "", title)
    title = re.sub(r"（\s*\d+\s*/\s*\d+\s*）\s*$", "", title).strip()

    i = html.find('id="articlecontent"')
    paras = []
    if i > 0:
        j = html.find("</div>", i)
        inner = html[i: j if j > i else len(html)]
        for chunk in re.split(r"</p\s*>|<br\s*/?>", inner, flags=re.I):
            line = _text(chunk)
            if _is_ad(line):
                continue
            paras.append(line)

    prev_u = prev_t = next_u = next_t = ""
    for m in re.finditer(r'<a id="(prev|next)_url"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>', html):
        which, href, label = m.group(1), m.group(2), _text(m.group(3))
        if href.startswith("javascript"):
            continue
        if which == "prev":
            prev_u, prev_t = _abs(href), label
        else:
            next_u, next_t = _abs(href), label
    return title, paras, prev_u, prev_t, next_u, next_t


def chapter(url):
    """正文。长章节自动把 _2、_3 续页拼起来，顺手过滤站点水印。"""
    v = (url or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    m = re.match(r"^(\d+)/(\d+)(?:_\d+)?\.html", v)
    if not m:
        raise RuntimeError("全本小说网章节地址不对：%s" % url)
    bid, cid = m.group(1), m.group(2)
    base_url = "%s/read/%s/%s.html" % (BASE, bid, cid)

    curr = base_url
    title = ""
    paras = []
    prev_url = ""
    next_url = ""
    for _ in range(8):  # 单章最多 8 页，足够
        html = _get(curr, timeout=15)
        t, ps, pu, pt, nu, nt = _chapter_parts(html)
        if not title:
            title = t
            if pt == "上一章":
                prev_url = pu
        paras.extend(ps)
        page_m = re.search(r"_(\d+)\.html", curr)
        if nu and re.search(r"/read/%s/%s_\d+\.html$" % (bid, cid), nu):
            curr = nu
            continue
        if nt == "下一章":
            next_url = nu
        break

    if not paras:
        raise RuntimeError("这一章没有取到内容")
    return {
        "title": title,
        "bookTitle": "",
        "paras": paras,
        "prev": "%s%s/%s.html" % (SCHEME, bid, _cid_of(prev_url, bid)) if prev_url else "",
        "next": "%s%s/%s.html" % (SCHEME, bid, _cid_of(next_url, bid)) if next_url else "",
        "prevPage": "",
        "nextPage": "",
        "url": "%s%s/%s.html" % (SCHEME, bid, cid),
        "chars": sum(len(p) for p in paras),
        "bookId": PREFIX + bid,
        "source": "全本小说网",
    }


def _cid_of(url, bid):
    m = re.search(r"/read/%s/(\d+)\.html" % re.escape(bid), url or "")
    return m.group(1) if m else ""
