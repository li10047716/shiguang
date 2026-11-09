"""
八叉书库（bcshuku.com）抓取层。

站点是自定义模板 + 明文 HTML，正文另外走一个签名接口：
  - 搜索  /e/search/index.php?keyboard=词&show=title,writer,byr&searchget=1
          这个地址只负责 302 跳到 result/?searchid=NNNN，翻页用
          /e/search/result/index.php?page=N-1&searchid=NNNN
  - 详情  /novel{bid}/   og: 元信息 + 完整目录（每页 50 章，?p=N）
  - 正文  /novel{bid}/chapter{cid}.html 页面里内嵌 url/mobile/isk/novel/chapter/t/n/sign
          八个参数，表单 POST 到 /conapi.php 才拿到 JSON 正文
  - 分类  /booklist{cid}/{page-1}.html（第 1 页是 0.html）
  - 排行  /popular/ /latest/ /release/ /completed/，第 2 页起 index_N.html

页面必须用移动端 UA；正文接口用夸克 UA，且同一秒内重复请求容易 502，需要重试。
"""
import html as htmllib
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://bcshuku.com"
PREFIX = "bc:"
SCHEME = "bc://"

UA_MOBILE = ("Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) "
             "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Mobile Safari/537.36")
UA_QUARK = ("Mozilla/5.0 (Linux; U; Android 10; zh-CN; MI 9 Build/QKQ1.190828.002) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 "
            "Quark/10.5.1.1026 Mobile Safari/537.36")

_HDR = {
    "User-Agent": UA_MOBILE,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,"
              "image/webp,image/apng,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Referer": BASE + "/",
}

CATS = [
    ("1", "长篇"), ("2", "综合"), ("3", "武侠"), ("4", "历史"), ("5", "都市"),
    ("6", "玄幻"), ("7", "女生"), ("8", "其他"), ("9", "现代"),
]

RANKS = [
    ("popular", "热门排行"),
    ("latest", "最新更新"),
    ("release", "最新入库"),
    ("completed", "完本小说"),
]

MAX_TOC_PAGES = 30        # 目录最多翻 30 页（约 1500 章）
_TOC_WORKERS = 6


# ---------------------------------------------------------------- 基础

def is_bc(value):
    v = (value or "").strip()
    return v.startswith(PREFIX) or v.startswith(SCHEME)


def native_id(value):
    v = (value or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    return re.split(r"[/.?]", v)[0]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def _get(url, timeout=25, retries=2):
    err = None
    for i in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers=_HDR)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
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
            time.sleep(1.0 * (i + 1))
    msg = str(err)
    if "502" in msg or "Tunnel connection failed" in msg:
        raise RuntimeError("八叉书库（bcshuku.com）连不上：网络代理返回 502，"
                           "常见于代理/运营商屏蔽该站点")
    raise RuntimeError("八叉书库请求失败：%s（%s）" % (url, err))


def _text(frag):
    frag = re.sub(r"<script[\s\S]*?</script>", "", frag or "", flags=re.I)
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


def _status(raw):
    raw = (raw or "").strip()
    if raw in ("完本", "全本", "完结"):
        return "已完结"
    if raw in ("连载", "连载中"):
        return "连载中"
    return raw


# ---------------------------------------------------------------- 列表解析

def _cards(html):
    """解析首页/分类/榜单一类的书籍卡片。"""
    split_pat = r'<div class="[^"]*\bhome-truyendecu\b[^"]*"'
    blocks = re.split(split_pat, html)[1:]
    cards, seen = [], set()
    for chunk in blocks:
        chunk = re.split(split_pat, chunk)[0]
        hm = re.search(r'<a href="(/novel(\d+)/)"[^>]*title="([^"]*)"', chunk)
        if not hm:
            continue
        bid = hm.group(2)
        if bid in seen:
            continue
        seen.add(bid)

        tm = re.search(r'<h3 itemprop="name">([\s\S]*?)</h3>', chunk)
        title = _text(tm.group(1)) if tm else htmllib.unescape(hm.group(3))
        cm = re.search(r'<img[^>]*src="([^"]+)"', chunk)
        views = re.search(r'class="chi-tiet luot-xem"[\s\S]{0,120}?</span>\s*([\d,]+)', chunk)
        dates = re.findall(r"(\d{4}-\d{2}-\d{2})", chunk)
        status = re.search(r'<span class="hoan-thanh-mau">([^<]*)</span>', chunk)
        latest = re.search(r'<small class="btn-xs label-primary">([\s\S]*?)</small>', chunk)
        latest_t = _text(latest.group(1)) if latest else ""
        if latest_t:
            latest_t = re.sub(r"^(连载|完本|全本)\s*", "", latest_t).strip()

        author = ""
        am = re.search(r'class="chi-tiet chuyen-muc"[\s\S]{0,200}?<a[^>]*>([^<]*)</a>', chunk)
        if am:
            cand = _text(am.group(1))
            if not re.match(r"^\d{4}-\d{2}-\d{2}", cand):
                author = cand

        cards.append({
            "id": PREFIX + bid,
            "title": title,
            "author": author,
            "cover": _abs(cm.group(1)) if cm else "",
            "intro": "",
            "category": "",
            "status": _status(status.group(1) if status else ""),
            "latest": latest_t,
            "views": views.group(1).replace(",", "") if views else "",
            "updated": dates[0] if dates else "",
            "source": "八叉书库",
        })
    return cards


def _max_page(html, kind, cid=None):
    """从分页条里取总页数：分类是 0 基（0.html 为第 1 页），榜单是 1 基。"""
    if kind == "sort":
        nums = [int(n) for n in re.findall(r"/booklist%s/(\d+)\.html" % re.escape(cid or ""), html)]
        return max(nums) + 1 if nums else 1
    nums = [int(n) for n in re.findall(r"/%s/index_(\d+)\.html" % re.escape(kind), html)]
    return max(nums) if nums else 1


# ---------------------------------------------------------------- 搜索

def _search_id(keyword):
    url = ("%s/e/search/index.php?keyboard=%s&show=title,writer,byr&searchget=1"
           % (BASE, urllib.parse.quote(keyword)))
    req = urllib.request.Request(url, headers=dict(_HDR, Referer=BASE + "/"))
    try:
        with _opener.open(req, timeout=25) as r:  # 正常情况会 302
            body = r.read().decode("utf-8", "ignore")
            m = re.search(r"searchid=(\d+)", r.geturl() or "")
            if m:
                return m.group(1)
            m = re.search(r"searchid=(\d+)", body)
            return m.group(1) if m else ""
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location") or ""
        m = re.search(r"searchid=(\d+)", loc)
        return m.group(1) if m else ""


def search(keyword, page=1):
    kw = (keyword or "").strip()
    if not kw:
        return {"books": [], "page": 1, "pages": 1}
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    sid = _search_id(kw)
    if not sid:
        return {"books": [], "page": 1, "pages": 1}
    if p == 1:
        url = "%s/e/search/result/?searchid=%s" % (BASE, sid)
    else:
        url = "%s/e/search/result/index.php?page=%d&searchid=%s" % (BASE, p - 1, sid)
    books = _cards(_get(url, timeout=30))
    # 结果页没有页码条，满 20 条就认为还有下一页
    pages = p + 1 if len(books) >= 20 else p
    return {"books": books, "page": p, "pages": pages}


# ---------------------------------------------------------------- 分类 / 榜单

def sort(cid, page=1):
    cid = cid if cid in [c for c, _ in CATS] else "1"
    name = dict(CATS)[cid]
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    url = "%s/booklist%s/%d.html" % (BASE, cid, p - 1)
    html = _get(url, timeout=30)
    total = _max_page(html, "sort", cid)
    if p > total:
        p = total
        html = _get("%s/booklist%s/%d.html" % (BASE, cid, p - 1), timeout=30)
    books = _cards(html)
    for b in books:
        b["category"] = name + "小说"
    return {"title": name + "小说", "books": books, "page": p,
            "pages": total, "cats": CATS}


def ranking(kind, page=1):
    if kind not in [k for k, _ in RANKS]:
        kind = "popular"
    title = dict(RANKS)[kind]
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    url = "%s/%s/index.html" % (BASE, kind) if p == 1 else \
          "%s/%s/index_%d.html" % (BASE, kind, p)
    html = _get(url, timeout=30)
    total = _max_page(html, kind)
    if p > total:
        p = total
        url = "%s/%s/index.html" % (BASE, kind) if p == 1 else \
              "%s/%s/index_%d.html" % (BASE, kind, p)
        html = _get(url, timeout=30)
    books = _cards(html)
    for i, b in enumerate(books):
        b["rank"] = (p - 1) * 20 + i + 1
    return {"title": title, "books": books, "page": p, "pages": total,
            "note": "八叉书库 · %s · 共 %d 页" % (title, total)}


# ---------------------------------------------------------------- 详情 / 目录

def _toc_page(bid, p):
    url = "%s/novel%s/" % (BASE, bid) if p == 1 else "%s/novel%s/?p=%d" % (BASE, bid, p)
    return _get(url, timeout=30)


def _toc_chapters(html, bid=""):
    """只解析完整目录区 #list-chapter，避开顶部「最新章节」和侧栏推荐。"""
    i = html.find('id="list-chapter"')
    seg = html[i:] if i > 0 else html
    cut = seg.find('id="pagination"')
    if cut > 0:
        seg = seg[:cut]
    # 站点在目录里塞了隐藏的 SEO 干扰项（aria-hidden / overflow:hidden），先剔掉
    seg = re.sub(r'<li[^>]*aria-hidden="true"[^>]*>[\s\S]*?</li>', "", seg)
    seg = re.sub(r'<li[^>]*overflow: ?hidden[^>]*>[\s\S]*?</li>', "", seg)
    chapters = []
    for m in re.finditer(
            r'<a href="(/novel\d+/(chapter\d+\.html))"([^>]*)>([\s\S]{0,200}?)</a>', seg):
        href, fname, attrs, inner = m.group(1), m.group(2), m.group(3), m.group(4)
        if "nofollow" in attrs or "tabindex=\"-1\"" in attrs:
            continue
        name = re.search(r'<span class="chapter-text">([\s\S]*?)</span>', inner)
        label = _text(name.group(1)) if name else _text(inner)
        if not label:
            continue
        bm = re.search(r"/novel(\d+)/", href)
        if not bm or (bid and bm.group(1) != bid):
            continue
        chapters.append({"t": label, "u": SCHEME + bm.group(1) + "/" + fname})
    return chapters


def _toc_pages(html):
    nums = [int(n) for n in re.findall(r"/novel\d+/\?p=(\d+)", html)]
    return max(nums) if nums else 1


def book(book_id):
    bid = native_id(book_id)
    if not bid:
        raise RuntimeError("缺少八叉书库书籍 id")
    url = "%s/novel%s/" % (BASE, bid)
    html = _get(url, timeout=40)

    def meta(prop):
        m = re.search(r'<meta[^>]*property="og:novel:%s"[^>]*content="([^"]*)"' % prop, html)
        return htmllib.unescape(m.group(1)).strip() if m else ""

    title = meta("book_name")
    author = meta("author")
    category = meta("category")
    status = _status(meta("status"))
    updated = meta("update_time")
    cm = re.search(r'<meta[^>]*property="og:image"[^>]*content="([^"]*)"', html)
    cover = _abs(cm.group(1)) if cm else ""
    if not title:
        tm = re.search(r"<title>([\s\S]*?)</title>", html)
        title = _text(tm.group(1)).split("_")[0] if tm else ("书籍" + bid)

    intro = ""
    dm = re.search(r'<div class="desc-text" itemprop="description">([\s\S]*?)</div>\s*<div class="showmore"', html)
    if not dm:
        dm = re.search(r'<div class="desc-text" itemprop="description">([\s\S]{0,3000}?)</div>', html)
    if dm:
        frag = dm.group(1)
        frag = re.sub(r'<div class="short-content">[\s\S]*?</div>', "", frag)
        frag = re.sub(r'<div class="showmore">[\s\S]*?</div>', "", frag)
        intro = _text(frag)

    latest = ""
    lm = re.search(r'<div id="new-chapter">[\s\S]{0,4000}?<span class="chapter-text">([^<]+)</span>', html)
    if lm:
        latest = _text(lm.group(1))

    # 目录
    total = min(_toc_pages(html), MAX_TOC_PAGES)
    chapters = _toc_chapters(html, bid)
    if total > 1:
        with ThreadPoolExecutor(max_workers=_TOC_WORKERS) as pool:
            pages = list(pool.map(lambda n: _safe_toc(bid, n), range(2, total + 1)))
        for ps in pages:
            chapters.extend(ps)

    seen, ordered = set(), []
    for c in chapters:
        if c["u"] in seen:
            continue
        seen.add(c["u"])
        ordered.append(c)
    chapters = ordered

    if not chapters:
        raise RuntimeError("八叉书库：这本暂时取不到目录")

    return {
        "id": PREFIX + bid,
        "title": title,
        "author": author,
        "cover": cover,
        "category": category,
        "status": status,
        "intro": intro,
        "updated": updated,
        "url": url,
        "chapters": chapters,
        "count": len(chapters),
        "words": "",
        "score": "",
        "latest": latest or chapters[-1]["t"],
        "tags": [category] if category else [],
        "publisher": "八叉书库",
        "statement": "",
        "source": "八叉书库",
        "tocTruncated": bool(total >= MAX_TOC_PAGES),
    }


def _safe_toc(bid, p):
    try:
        return _toc_chapters(_toc_page(bid, p), bid)
    except Exception:  # noqa: BLE001
        return []


# ---------------------------------------------------------------- 正文

def _pick(html, key):
    m = re.search(r'"%s"\s*:\s*"([^"]*)"' % key, html)
    if m:
        return m.group(1).strip()
    m = re.search(r'"%s"\s*:\s*([^,\s}]+)' % key, html)
    return m.group(1).strip() if m else ""


def _fetch_content(html, chap_url, retries=3):
    params = {k: _pick(html, k) for k in
              ("url", "mobile", "isk", "novel", "chapter", "t", "n", "sign")}
    if not params["url"] or not params["sign"]:
        return []
    body = urllib.parse.urlencode(params).encode()
    hdr = {
        "User-Agent": UA_QUARK,
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "x-requested-with": "XMLHttpRequest",
        "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
        "origin": BASE,
        "referer": chap_url,
        "accept-language": "zh-CN,zh;q=0.9",
    }
    err = None
    for i in range(retries):
        try:
            req = urllib.request.Request(BASE + "/conapi.php", data=body,
                                         headers=hdr, method="POST")
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read().decode("utf-8", "ignore")
            data = json.loads(raw)
            if not data or str(data.get("success")) in ("0", "False", "false") or not data.get("content"):
                raise RuntimeError("接口没有返回正文")
            return _split(str(data["content"]))
        except Exception as e:  # noqa: BLE001
            err = e
            time.sleep(0.6 * (i + 1))
    raise RuntimeError("八叉书库正文接口失败：%s" % err)


def _split(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("&nbsp;", " ").replace("\u3000", "  ")
    paras = []
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        paras.append(line)
    return paras


def chapter(url):
    v = (url or "").strip()
    if v.startswith(SCHEME):
        v = v[len(SCHEME):]
    elif v.startswith(PREFIX):
        v = v[len(PREFIX):]
    m = re.match(r"^(\d+)/(chapter\d+\.html)", v)
    if not m:
        raise RuntimeError("八叉书库章节地址不对：%s" % url)
    bid, fname = m.group(1), m.group(2)
    chap_url = "%s/novel%s/%s" % (BASE, bid, fname)
    html = _get(chap_url, timeout=30)

    tm = re.search(r'<a class="chapter-title"[^>]*title="[^"]*?"[^>]*>([\s\S]*?)</a>', html)
    title = _text(tm.group(1)) if tm else ""
    if not title:
        tm = re.search(r"<title>([\s\S]*?)</title>", html)
        title = _text(tm.group(1)).split("_")[0] if tm else ""

    paras = _fetch_content(html, chap_url)
    if not paras:
        raise RuntimeError("这一章没有取到内容")

    def nav(which):
        nm = re.search(r'<a[^>]*id="%s_chap"[^>]*href="([^"]*)"' % which, html)
        return _abs(nm.group(1)) if nm else ""

    prev_url, next_url = nav("prev"), nav("next")
    if next_url and re.search(r"/novel%s/?$" % re.escape(bid), next_url):
        next_url = ""          # 最后一章的「下一章」指向详情页

    return {
        "title": title,
        "bookTitle": "",
        "paras": paras,
        "prev": _chap_scheme(prev_url),
        "next": _chap_scheme(next_url),
        "prevPage": "",
        "nextPage": "",
        "url": SCHEME + "%s/%s" % (bid, fname),
        "chars": sum(len(p) for p in paras),
        "bookId": PREFIX + bid,
        "source": "八叉书库",
    }


def _chap_scheme(url):
    m = re.search(r"/novel(\d+)/(chapter\d+\.html)", url or "")
    return SCHEME + "%s/%s" % (m.group(1), m.group(2)) if m else ""
