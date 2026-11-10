"""
速读谷（sudugu.cc）抓取与解析层。
只用 Python 标准库，无第三方依赖。
"""
import base64
import gzip
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from html import unescape

from . import ali, bc, blxs, dq, mkz, qbxs, qm, shuqi

BASE = "https://www.sudugu.cc"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")

_HDR = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Accept-Encoding": "identity",
    "Referer": BASE + "/",
}


# ---------------------------------------------------------------- 网络

def normalize(url, ref=BASE):
    """统一成 https://www.sudugu.cc/... 形式，避免 www / 非 www 两套会话。"""
    if not url:
        return ""
    url = unescape(url).strip()
    if url.startswith("//"):
        url = "https:" + url
    if url.startswith("http"):
        p = urllib.parse.urlsplit(url)
        return urllib.parse.urlunsplit(("https", "www.sudugu.cc", p.path, p.query, ""))
    return urllib.parse.urljoin(ref, url)


def http_get(url, timeout=12, retries=2):
    url = normalize(url)
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
            # 4xx 是地址问题，重试也没用，直接失败，别让界面干等
            if 400 <= e.code < 500:
                raise RuntimeError("页面不存在（HTTP %d）：%s" % (e.code, url))
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i < retries:
            time.sleep(0.6 * (i + 1))
    raise RuntimeError("网络请求失败：%s（%s）" % (url, err))


# ---------------------------------------------------------------- 文本工具

def _strip_tags(frag):
    frag = re.sub(r"<script.*?</script>", "", frag, flags=re.S | re.I)
    frag = re.sub(r"<style.*?</style>", "", frag, flags=re.S | re.I)
    frag = re.sub(r"<br\s*/?>", "\n", frag, flags=re.I)
    frag = re.sub(r"</p\s*>", "\n", frag, flags=re.I)
    frag = re.sub(r"<[^>]+>", "", frag)
    frag = unescape(frag)
    return (frag.replace("\u00a0", " ")
                .replace("\u3000", " ")
                .replace("\u2002", " ")
                .replace("\u2003", " "))


def text_of(frag):
    return re.sub(r"[ \t\r\f\v]+", " ", _strip_tags(frag)).strip()


def book_id(url):
    m = re.search(r"sudugu\.cc/(\d+)/?", normalize(url))
    return m.group(1) if m else ""


# ---------------------------------------------------------------- 卡片列表

_LI_CARD = re.compile(
    r'<li>\s*<a href="([^"]+)"[^>]*class="imga"[^>]*>\s*<img[^>]*src="([^"]+)"[^>]*>'
    r'\s*</a>\s*<p>\s*<a[^>]*>(.*?)</a>', re.S)

_DIV_CARD = re.compile(
    r'<div class="item[^"]*">\s*<a href="([^"]+)">\s*<img[^>]*src="([^"]+)"[^>]*>'
    r'\s*</a>(.*?)<div class="itemtxt">(.*?)</div>\s*</div>', re.S)


def _cards_from(chunk):
    out, seen = [], set()
    for m in _LI_CARD.finditer(chunk):
        u = normalize(m.group(1))
        bid = book_id(u)
        if not bid or bid in seen:
            continue
        seen.add(bid)
        out.append({"id": bid, "title": text_of(m.group(3)),
                    "cover": normalize(m.group(2)), "url": u})
    for m in _DIV_CARD.finditer(chunk):
        u = normalize(m.group(1))
        bid = book_id(u)
        if not bid or bid in seen:
            continue
        seen.add(bid)
        inner = m.group(4)
        t = re.search(r"<h[13][^>]*>(.*?)</h[13]>", inner, re.S)
        title = ""
        if t:
            links = re.findall(r"<a[^>]*>(.*?)</a>", t.group(1), re.S)
            title = text_of(links[-1]) if links else text_of(t.group(1))
        item = {"id": bid, "title": title or text_of(inner)[:30],
                "cover": normalize(m.group(2)), "url": u}
        item.update(_item_meta(inner))
        out.append(item)
    return out


# 「连载中 / 玄幻小说」这种两段式标签
_SPANS = re.compile(r"<span>\s*([^<]{1,12})\s*</span>")
_AUTHOR = re.compile(r"作者[：:]\s*([^<，,]{1,24})")
_LATEST = re.compile(
    r"<li>\s*(?:<i>([^<]*)</i>)?\s*<a href=\"([^\"]+)\"[^>]*>(.*?)</a>\s*</li>", re.S)


def _item_meta(inner):
    """从 itemtxt 里挖出作者/分类/状态/最新章节，失败就留空，不影响主流程。"""
    meta = {"author": "", "category": "", "status": "", "latest": "", "latestUrl": ""}
    for s in _SPANS.findall(inner):
        s = text_of(s)
        if not s:
            continue
        if not meta["status"] and ("载" in s or "完结" in s):
            meta["status"] = s
        elif not meta["category"]:
            meta["category"] = "" if s == "置顶" else s
    am = _AUTHOR.search(inner)
    if am:
        meta["author"] = text_of(am.group(1))
    lm = _LATEST.search(inner)
    if lm:
        meta["latest"] = text_of(lm.group(3))
        meta["latestUrl"] = normalize(lm.group(2))
    return meta


# ---------------------------------------------------------------- 首页

def parse_home(html):
    """返回 [{title, url, books:[...]}, ...]"""
    sections = []
    heads = list(re.finditer(r'<h2[^>]*>\s*<a href="([^"]+)"[^>]*>(.*?)</a>', html, re.S))
    for idx, m in enumerate(heads):
        title = text_of(m.group(2))
        if not title or title in ("相关小说",):
            continue
        start = m.end()
        end = heads[idx + 1].start() if idx + 1 < len(heads) else len(html)
        chunk = html[start:end]
        # 截到 section 结束（下一个 container 之前）
        cut = chunk.find('<div class="container"')
        if cut > 0:
            chunk = chunk[:cut]
        books = _cards_from(chunk)
        if books:
            sections.append({"title": title, "url": normalize(m.group(1)),
                             "books": books[:12]})
    return sections


def home():
    return {"sections": parse_home(http_get(BASE + "/"))}


# ---------------------------------------------------------------- 分类 / 榜单

CATEGORIES = [
    {"id": 1, "name": "玄幻小说"}, {"id": 2, "name": "仙侠小说"},
    {"id": 3, "name": "都市小说"}, {"id": 4, "name": "历史小说"},
    {"id": 5, "name": "军事小说"}, {"id": 6, "name": "科幻小说"},
    {"id": 7, "name": "言情小说"},
]


def category(cid=1, page=1):
    try:
        page = max(1, int(page or 1))
    except (TypeError, ValueError):
        page = 1
    url = "%s/fenlei/%s/%d/" % (BASE, cid, page)
    html = http_get(url)
    m = re.search(r'<ul class="list top clear">(.*?)</ul>', html, re.S)
    chunk = m.group(1) if m else html
    books = _cards_from(chunk)
    total = 1
    pm = re.search(r"<span>(\d+)\s*/\s*(\d+)</span>", html)
    if pm:
        total = max(1, int(pm.group(2)))
    if page > total:
        fixed = category(cid, total)
        fixed["clamped"] = True
        return fixed
    return {"title": "分类 · 第 %d 页" % page, "books": books,
            "page": page, "pages": total}


def _rank_books(html):
    """榜单页正文只在 <div class="container"> 里，别整页扫，否则会抓到页头推荐位。"""
    i = html.find('<div class="container"')
    chunk = html[i:] if i > 0 else html
    j = chunk.find('<div class="footer"')
    if j > 0:
        chunk = chunk[:j]
    books = _cards_from(chunk)
    for n, b in enumerate(books, 1):
        b["rank"] = n
    return books


RANK_TITLES = {"lastupdate": "最新更新", "top": "阅读排行", "quanben": "完结小说"}


def ranking(kind="top", page=1):
    kind = kind if kind in RANK_TITLES else "top"
    try:
        page = max(1, int(page or 1))
    except (TypeError, ValueError):
        page = 1

    # 本站的 /top/lastupdate/N.html 是个兜底页，内容与 /top.html 完全一致，
    # 所以「最新更新」改用首页的真实更新板块，避免两个 tab 显示同一份列表。
    if kind == "lastupdate":
        books, note = [], ""
        try:
            for sec in home()["sections"]:
                if "最新更新" in sec["title"] or "最近更新" in sec["title"]:
                    books = sec["books"]
                    break
        except Exception:  # noqa: BLE001
            books = []
        if books:
            note = "首页实时更新顺序"
        else:  # 首页结构变了就退回榜单页，至少不空
            books = _rank_books(http_get(BASE + "/top.html", retries=1))
            note = "已回退到站点汇总榜"
        out = []
        for b in books[:40]:
            b = dict(b)
            b["rank"] = len(out) + 1
            out.append(b)
        return {"title": RANK_TITLES[kind], "books": out, "page": 1,
                "pages": 1, "note": note, "source": "home"}

    path = "/quanben/%d.html" % page if kind == "quanben" else "/top.html"
    html = http_get(BASE + path, retries=1)  # 榜单偶发慢，少重试一次，别让界面干等
    books = _rank_books(html)
    total = 1
    pm = re.search(r"<span>(\d+)\s*/\s*(\d+)</span>", html)
    if pm:
        total = max(1, int(pm.group(2)))
    if kind == "top":
        total = 1  # 汇总榜只有一页，翻页没有意义
    if page > total >= 1:  # 页码超范围（地址手改/站点总页变动）就夹回最后一页
        fixed = ranking(kind, total)
        fixed["clamped"] = True
        return fixed
    return {"title": RANK_TITLES[kind], "books": books, "page": page,
            "pages": total, "note": "", "source": path}


# ---------------------------------------------------------------- 搜索

def search(keyword, src="all", page=1, skip=None):
    """多书源搜索。src: all / sd / qm / sq / qb / bc / bl / dq / ali。
    skip: 健康面板里关掉的书源短码集合，只在 src=all 时生效。"""
    keyword = (keyword or "").strip()
    if not keyword:
        return {"books": [], "msg": ""}
    if len(keyword.encode("utf-8")) < 4:
        return {"books": [], "msg": "搜索词至少 2 个汉字"}

    src = (src or "all").lower()
    skip = set(skip or ())

    def want(code):
        return (src == code) if src != "all" else (code not in skip)

    # 各书源并发请求：手机网络下单源最慢 20 秒，串行 8 个源会让前端直接超时。
    # 结果仍按固定顺序合并，保证混排列表稳定；单个源失败不影响其它源。
    jobs = []
    if want("sd"):
        jobs.append(("速读谷", lambda: _search_sd(keyword), 0))
    if want("qm"):
        jobs.append(("七猫", lambda: qm.search(keyword, page), 0))
    if want("sq"):
        jobs.append(("书旗", lambda: shuqi.search(keyword, page), 0))
    if want("qb"):
        jobs.append(("全本", lambda: qbxs.search(keyword, page), 0))
    if want("bc"):
        jobs.append(("八叉", lambda: bc.search(keyword, page), 0))
    if want("bl"):
        jobs.append(("八一", lambda: blxs.search(keyword, page), 20 if src == "all" else 0))
    if want("dq"):
        jobs.append(("得奇", lambda: dq.search(keyword, page), 20 if src == "all" else 0))
    if want("ali"):
        jobs.append(("爱丽丝", lambda: ali.search(keyword, page), 0))

    books, notes = [], []
    if len(jobs) == 1:
        name, fn, limit = jobs[0]
        try:
            r = fn()
            out = r.get("books", [])
            books.extend(out[:limit] if limit else out)
            if r.get("msg"):
                notes.append(r["msg"])
        except Exception as e:  # noqa: BLE001
            notes.append("%s：%s" % (name, e))
    else:
        ex = ThreadPoolExecutor(max_workers=min(8, len(jobs)))
        futs = [(name, limit, ex.submit(fn)) for name, fn, limit in jobs]
        try:
            for name, limit, fut in futs:
                try:
                    r = fut.result(timeout=35)
                    out = r.get("books", [])
                    books.extend(out[:limit] if limit else out)
                    if r.get("msg"):
                        notes.append(r["msg"])
                except FutureTimeout:
                    notes.append("%s：请求超时" % name)
                except Exception as e:  # noqa: BLE001
                    notes.append("%s：%s" % (name, e))
        finally:
            ex.shutdown(wait=False, cancel_futures=True)
    return {"books": books, "msg": "；".join(notes)}


def _search_sd(keyword):
    url = "%s/modules/article/search.php?searchkey=%s" % (
        BASE, urllib.parse.quote(keyword))
    html = http_get(url)
    if 'id="dir"' in html:  # 精确命中直接跳到书页
        b = parse_book(html, url)
        return {"books": [{"id": b["id"], "title": b["title"], "cover": b["cover"],
                           "url": b["url"], "author": b["author"],
                           "intro": b["intro"], "category": b["category"],
                           "status": b["status"], "source": "速读谷"}], "msg": ""}
    books = []
    for m in re.finditer(r'<div class="item clear">(.*?)</div>\s*</div>', html, re.S):
        block = m.group(1)
        h3 = re.search(r'<h3[^>]*>\s*<a href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not h3:
            continue
        u = normalize(h3.group(1))
        bid = book_id(u)
        if not bid:
            continue
        author = ""
        am = re.search(r"作者：(.*?)</li>", block, re.S)
        if am:
            author = text_of(am.group(1))
        read = ""
        rm = re.search(r"阅读量：(.*?)</li>", block, re.S)
        if rm:
            read = text_of(rm.group(1))
        last = ""
        lm = re.search(r"更新：\s*<a[^>]*>(.*?)</a>", block, re.S)
        if lm:
            last = text_of(lm.group(1))
        intro = ""
        im = re.search(r"<p>(.*?)</p>", block, re.S)
        if im:
            intro = text_of(im.group(1))
        cover = ""
        cm = re.search(r'<img[^>]*src="([^"]+)"', block)
        if cm:
            cover = normalize(cm.group(1))
        books.append({"id": bid, "title": text_of(h3.group(2)), "url": u,
                      "author": author, "read": read, "last": last,
                      "intro": intro[:120], "cover": cover, "source": "速读谷"})
    msg = ""
    if not books:
        mb = re.search(r'<div class="blockcontent">(.*?)</div>', html, re.S)
        if mb:
            msg = text_of(mb.group(1))
        msg = msg or "没有找到相关小说"
    return {"books": books, "msg": msg}


# ---------------------------------------------------------------- 书籍详情

def parse_book(html, url):
    bid = book_id(url)
    url = normalize(url)

    cover = ""
    m = re.search(r'<div class="item">\s*<a[^>]*>\s*<img[^>]*src="([^"]+)"', html, re.S)
    if m:
        cover = normalize(m.group(1))
    if not cover:
        m = re.search(r'<img[^>]*src="([^"]*article/image[^"]*)"', html)
        if m:
            cover = normalize(m.group(1))

    title = ""
    m = re.search(r'<div class="itemtxt">\s*<h1[^>]*>(.*?)</h1>', html, re.S)
    if m:
        links = re.findall(r"<a[^>]*>(.*?)</a>", m.group(1), re.S)
        title = text_of(links[-1]) if links else text_of(m.group(1))
    if not title:
        t = re.search(r"<title>(.*?)</title>", html, re.S)
        title = text_of(t.group(1)).split("-")[0] if t else "未知书名"

    author, category, status = "", "", ""
    m = re.search(r'authorarticle\.php\?author=[^"]*"[^>]*>(.*?)</a>', html, re.S)
    if m:
        author = text_of(m.group(1)).replace("作者：", "").strip()
    m = re.search(r"<p>\s*<span>(.*?)</span>\s*<span>(.*?)</span>\s*</p>", html, re.S)
    if m:
        status = text_of(m.group(1))
        category = text_of(m.group(2))

    intro = ""
    for mm in re.finditer(r'<div class="des bb"[^>]*>(.*?)</div>', html, re.S):
        txt = text_of(mm.group(1))
        if txt and not txt.startswith("《"):
            intro = txt
            break

    updated = ""
    m = re.search(r'更新时间：([\d\-: ]+)', html)
    if m:
        updated = m.group(1).strip()

    chapters = _chapter_list(html)
    # 目录 > 1000 章会分页：/2139/2
    pm = re.search(r'<div id="pages".*?</div>', html, re.S)
    if pm:
        total = 1
        tm = re.search(r"(\d+)\s*/\s*(\d+)", text_of(pm.group(0)))
        if tm:
            total = int(tm.group(2))
        for p in range(2, min(total, 30) + 1):
            try:
                sub = http_get("%s/%s/%d" % (BASE, bid, p))
            except Exception:  # noqa: BLE001
                break
            part = _chapter_list(sub)
            if not part:
                break
            chapters.extend(part)

    # 去重（按 url）
    seen, uniq = set(), []
    for c in chapters:
        if c["u"] in seen:
            continue
        seen.add(c["u"])
        uniq.append(c)

    return {"id": bid, "title": title, "author": author, "cover": cover,
            "category": category, "status": status, "intro": intro,
            "updated": updated, "url": url, "chapters": uniq,
            "count": len(uniq)}


def _chapter_list(html):
    i = html.find('id="list"')
    if i < 0:
        return []
    j = html.find('<div id="pages"', i)
    chunk = html[i: j if j > 0 else len(html)]
    out = []
    for m in re.finditer(r"<a\s+([^>]*)>(.*?)</a>", chunk, re.S):
        attrs, label = m.group(1), text_of(m.group(2))
        h = re.search(r'href="([^"]*)"', attrs)
        if not h or not label:
            continue
        u = h.group(1)
        if u.startswith("javascript") or u == "#":
            enc = re.search(r'data-enc="([^"]+)"', attrs)
            if not enc:
                continue
            try:
                u = base64.b64decode(enc.group(1)).decode("utf-8", "ignore")
            except Exception:  # noqa: BLE001
                continue
        if not re.search(r"/\d+/\d+\.html$", u):
            continue
        out.append({"t": label, "u": normalize(u)})
    return out


def book(url_or_id):
    v = str(url_or_id or "").strip()
    if mkz.is_mkz(v):
        return mkz.book(v)
    if qm.is_qm(v):
        return qm.book(v)
    if shuqi.is_sq(v):
        return shuqi.book(v)
    if qbxs.is_qb(v):
        return qbxs.book(v)
    if bc.is_bc(v):
        return bc.book(v)
    if blxs.is_bl(v):
        return blxs.book(v)
    if dq.is_dq(v):
        return dq.book(v)
    if ali.is_ali(v):
        return ali.book(v)
    if v.isdigit():
        url = "%s/%s/" % (BASE, v)
    else:
        url = normalize(v)
    data = parse_book(http_get(url), url)
    data["source"] = "速读谷"
    return data


# ---------------------------------------------------------------- 章节正文

def parse_chapter(html, url=None):
    t = ""
    m = re.search(r'<div class="submenu">\s*<h1>(.*?)</h1>', html, re.S)
    if m:
        raw = text_of(m.group(1))
        book_title, _, chap = raw.partition(">")
        t = chap.strip() or raw
    else:
        m = re.search(r"<title>(.*?)</title>", html, re.S)
        t = text_of(m.group(1)).split("-")[0] if m else ""
    t = re.sub(r"（\s*\d+\s*/\s*\d+\s*）", "", t).strip()

    book_title = ""
    bm = re.search(r'<div class="submenu">\s*<h1>\s*<a[^>]*>(.*?)</a>', html, re.S)
    if bm:
        book_title = text_of(bm.group(1))

    paras = []
    i = html.find('<div class="con">')
    if i >= 0:
        nxt = html.find('class="prenext"', i)
        end = html.rfind("</div>", i, nxt if nxt > 0 else len(html))
        inner = html[i + len('<div class="con">'): end if end > i else len(html)]
        for line in re.split(r"<br\s*/?>|</p>", inner):
            s = text_of(line)
            s = s.strip()
            if not s:
                continue
            if len(s) <= 24 and re.match(r"^第[\d一二三四五六七八九十百千零]+章", s):
                continue
            if s.startswith("（本章完）") or s in ("上一章", "下一章", "目录"):
                continue
            paras.append(s)

    prev_u = next_u = ""
    prev_page = next_page = ""
    pn = html.find('class="prenext"')
    if pn > 0:
        chunk = html[pn: pn + 2000]
        for m in re.finditer(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', chunk, re.S):
            label = text_of(m.group(2))
            target = normalize(m.group(1))
            if label == "上一章":
                prev_u = target
            elif label == "下一章":
                next_u = target
            elif label == "上一页":
                prev_page = target
            elif label == "下一页":
                next_page = target

    return {"title": t, "bookTitle": book_title, "paras": paras,
            "prev": prev_u, "next": next_u,
            "prevPage": prev_page, "nextPage": next_page}


def chapter(url):
    """抓取整章：自动跟进 _2/_3 分页。漫画源返回 kind=comic 的图片列表。"""
    if mkz.is_mkz(url):
        return mkz.chapter(url)
    if qm.is_qm(url):
        return qm.chapter(url)
    if shuqi.is_sq(url):
        return shuqi.chapter(url)
    if qbxs.is_qb(url):
        return qbxs.chapter(url)
    if bc.is_bc(url):
        return bc.chapter(url)
    if blxs.is_bl(url):
        return blxs.chapter(url)
    if dq.is_dq(url):
        return dq.chapter(url)
    if ali.is_ali(url):
        return ali.chapter(url)
    url = normalize(url)
    first = parse_chapter(http_get(url), url)
    paras = list(first["paras"])
    seen = {url}
    cur = first
    guard = 0
    while cur.get("nextPage") and cur["nextPage"] not in seen and guard < 12:
        seen.add(cur["nextPage"])
        guard += 1
        try:
            cur = parse_chapter(http_get(cur["nextPage"]), cur["nextPage"])
        except Exception:  # noqa: BLE001
            break
        paras.extend(cur["paras"])

    return {"title": first["title"], "bookTitle": first["bookTitle"],
            "paras": paras, "prev": cur.get("prev") or first["prev"],
            "next": cur.get("next") or first["next"],
            "url": url, "chars": sum(len(p) for p in paras)}


def _ungzip(raw, headers):
    """有的站连图片都 gzip（如八一中文网），不手动解压就是一张打不开的假图。"""
    enc = (headers.get("Content-Encoding") or "").lower()
    if "gzip" in enc or raw[:2] == b"\x1f\x8b":
        try:
            raw = gzip.decompress(raw)
        except OSError:
            pass
    return raw


def http_get_bytes(url, timeout=20):
    # 只有本站图片才做域名归一，外部 CDN（七猫、全本等）要原样请求
    parts = urllib.parse.urlsplit(url)
    if "sudugu.cc" not in parts.netloc:
        host = parts.netloc.lower()
        if "wtzw" in host or "qimao" in host:  # 七猫 CDN 认 wtzw 站点来源
            ref = "https://www.wtzw.com/"
        else:  # 其余站点用自己的根域做 Referer，避免 403 防盗链
            ref = "%s://%s/" % (parts.scheme or "https", parts.netloc)
        req = urllib.request.Request(url, headers={
            "User-Agent": UA, "Accept": "image/*,*/*", "Referer": ref})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return _ungzip(r.read(), r.headers), r.headers.get("Content-Type", "image/jpeg")
    url = normalize(url)
    req = urllib.request.Request(url, headers=dict(_HDR, Accept="image/*,*/*"))
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return _ungzip(r.read(), r.headers), r.headers.get("Content-Type", "image/jpeg")


if __name__ == "__main__":
    import sys
    what = sys.argv[1] if len(sys.argv) > 1 else "home"
    if what == "home":
        print(json.dumps(home(), ensure_ascii=False, indent=1)[:800])
    elif what == "book":
        print(json.dumps(book(sys.argv[2]), ensure_ascii=False, indent=1)[:1200])
    elif what == "chapter":
        print(json.dumps(chapter(sys.argv[2]), ensure_ascii=False, indent=1)[:1200])
    elif what == "search":
        print(json.dumps(search(sys.argv[2]), ensure_ascii=False, indent=1)[:1200])
