"""
本地书籍：TXT / EPUB / 漫画包（CBZ、ZIP、图片版 EPUB）导入、解析与读取。

只用标准库，不联网。书籍 id 用 `loc:` 前缀，章节地址形如 `loc:<hash>/<序号>`，
和八个网络书源共用同一套 /api/book、/api/chapter 接口，前端不需要单独分支。

落盘结构：
    data/local/<hash>.json          # 书名 / 作者 / 简介 / 章节目录
    data/local/<hash>/000123.json   # 单章正文（按章存，读一章不用加载整本）
    data/local/<hash>/img/000001.jpg  # 漫画页图片（导入时解压，按顺序编号）

漫画书的 meta 带 kind="comic"，章节 JSON 里没有 paras，只有 pages（图片文件名列表）。
"""
import html
import json
import os
import posixpath
import re
import time
import zipfile
from hashlib import sha1

PREFIX = "loc:"

ROOT = os.environ.get("SUDUGU_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("SUDUGU_DATA") or os.path.join(ROOT, "data")
LOCAL_DIR = os.path.join(DATA, "local")

# 单个文件上限：手机内存有限，40MB 的纯文本已经是一千多万字
MAX_BYTES = 40 * 1024 * 1024

SRC_NAME = "本地导入"

# 漫画包可能比纯文本大得多（一话十几张图），单独放宽上限
MAX_COMIC_BYTES = 220 * 1024 * 1024
IMG_EXT = (".jpg", ".png", ".webp", ".gif", ".bmp", ".avif")
_IMG_MIME = {".jpg": "image/jpeg", ".png": "image/png", ".webp": "image/webp",
             ".gif": "image/gif", ".bmp": "image/bmp", ".avif": "image/avif"}

# 「第一章 xxx」/「楔子」这类独立成行的标题。行内出现的「第 x 章」不作数：
# 先抓行首的「第X章」，再用 _looks_title 判断后面跟的是标题还是正文句子。
_CHAP = re.compile(
    r"^[ \t\u3000]*("
    r"第[0-9０-９零〇一二三四五六七八九十百千万两]{1,10}[章节回卷集篇部]"
    r"|序章|楔子|引子|前言|后记|尾声|终章|番外|外传"
    r")([^\n]*)$",
    re.M,
)
_SEP = " \t\u3000:：·、-—－_（(【[.．"
_SENT = re.compile(r"[。！？，；、]")


def _looks_title(head, rest):
    """「第二章 入城」是标题；「第二章开始了。主角……」是正文。"""
    rest = (rest or "").strip()
    if len(head) + len(rest) > 60:
        return False
    if not rest:
        return True
    if rest[0] in _SEP:
        return len(rest) <= 40
    # 紧贴正文（「第1章风起」）：只有短、且不像句子的才算标题
    return len(rest) <= 20 and not _SENT.search(rest)

_TAG = re.compile(r"(?s)<[^>]+>")


def is_local(bid):
    return str(bid or "").startswith(PREFIX)


def _hash(raw, name):
    h = sha1()
    h.update(str(name or "").encode("utf-8", "ignore"))
    h.update(b"\x00")
    h.update(raw[:65536])
    h.update(str(len(raw)).encode())
    return h.hexdigest()[:10]


def _hash_of(bid):
    """从 loc:<hash> 取出 hash，顺便挡掉路径穿越。"""
    token = str(bid or "")[len(PREFIX):]
    return token if re.fullmatch(r"[0-9a-f]{8,16}", token) else ""


def _meta_path(h):
    return os.path.join(LOCAL_DIR, h + ".json")


def _chap_dir(h):
    return os.path.join(LOCAL_DIR, h)


# ------------------------------------------------------------------ 解析

def _decode(raw):
    for enc in ("utf-8-sig", "utf-8", "gb18030", "utf-16"):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, UnicodeError):
            continue
    return raw.decode("utf-8", "ignore")


def _paras(body):
    """一段一行；超长段落按句号切开，长按选段和分页都不会撑爆。"""
    out = []
    for line in re.split(r"\r?\n", body or ""):
        s = line.strip()
        while len(s) > 800:
            cut = max(s.rfind("。", 0, 800), s.rfind("！", 0, 800), s.rfind("？", 0, 800))
            if cut < 200:
                cut = 800
            out.append(s[:cut + 1])
            s = s[cut + 1:].lstrip()
        if s:
            out.append(s)
    return out


def _chunk(text, size=3000):
    """没有章节标题的纯文本：按约 3000 字一节切开。"""
    lines = [p for p in re.split(r"\r?\n", text) if p.strip()]
    out, buf, n = [], [], 0
    for line in lines:
        buf.append(line.strip())
        n += len(line)
        if n >= size:
            out.append(("第%d节" % (len(out) + 1), "\n".join(buf)))
            buf, n = [], 0
    if buf:
        out.append(("第%d节" % (len(out) + 1), "\n".join(buf)))
    return out


def split_txt(text):
    """返回 [(标题, 正文)]。识别不到章节就按长度分节，保证总能读。"""
    text = (text or "").replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")
    marks = [m for m in _CHAP.finditer(text) if _looks_title(m.group(1), m.group(2))]
    # 只出现一次的多半是正文里的一句引用，不算目录
    if len(marks) < 2:
        return _chunk(text)
    out = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        line_end = text.find("\n", m.start())
        body_start = line_end + 1 if 0 <= line_end < end else end
        body = text[body_start:end]
        if not "".join(body.split()) and i + 1 < len(marks):
            continue  # 只有标题没有正文的空章，跳过
        out.append(((m.group(1) + m.group(2)).strip()[:80], body))
    return out or _chunk(text)


def _strip_html(s):
    s = re.sub(r"(?is)<(script|style|head)[^>]*>.*?</\1>", " ", s or "")
    s = re.sub(r"(?i)<br\s*/?>", "\n", s)
    s = re.sub(r"(?i)</(p|div|h[1-6]|li|tr|blockquote|section)>", "\n", s)
    s = _TAG.sub("", s)
    return html.unescape(s)


def _html_paras(page):
    """EPUB 的 XHTML → 段落数组：块级标签断段，<br> 只当空格（避免一句一页）。"""
    page = re.sub(r"(?is)<(script|style|head)[^>]*>.*?</\1>", " ", page or "")
    page = re.sub(r"(?i)<br\s*/?>", " ", page)
    page = re.sub(r"(?i)</(p|div|h[1-6]|li|tr|blockquote|section|article)>", "\n", page)
    text = html.unescape(_TAG.sub("", page))
    return [ln.strip() for ln in text.split("\n") if ln.strip()]


def _opf_meta(opf, name):
    m = re.search(r"(?is)<(?:dc:)?%s[^>]*>(.*?)</(?:dc:)?%s>" % (name, name), opf)
    if not m:
        return ""
    return html.unescape(_TAG.sub("", m.group(1))).strip()


def _epub_title(xhtml, fallback):
    m = re.search(r"(?is)<h[1-3][^>]*>(.*?)</h[1-3]>", xhtml)
    if m:
        t = html.unescape(_TAG.sub("", m.group(1))).strip()
        if t and len(t) <= 60:
            return t
    m = re.search(r"(?is)<title[^>]*>(.*?)</title>", xhtml)
    if m:
        t = html.unescape(_TAG.sub("", m.group(1))).strip()
        if t and len(t) <= 60:
            return t
    return fallback


def parse_epub(raw, fallback_title=""):
    """返回 (书名, 作者, 简介, [(标题, 正文)])。章节顺序按 OPF spine。"""
    import io

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        names = set(zf.namelist())
        opf_path = ""
        try:
            cont = zf.read("META-INF/container.xml").decode("utf-8", "ignore")
            m = re.search(r'full-path="([^"]+)"', cont)
            if m:
                opf_path = m.group(1)
        except KeyError:
            pass
        if not opf_path:
            cand = [n for n in names if n.lower().endswith(".opf")]
            opf_path = cand[0] if cand else ""
        if not opf_path or opf_path not in names:
            raise ValueError("这个 EPUB 缺少 OPF 目录文件，无法解析")

        base = posixpath.dirname(opf_path)
        opf = zf.read(opf_path).decode("utf-8", "ignore")
        title = _opf_meta(opf, "title") or fallback_title or "未命名"
        author = _opf_meta(opf, "creator")
        intro = _opf_meta(opf, "description")
        intro = re.sub(r"\s+", " ", _strip_html(intro)).strip()[:600]

        items = {}
        for tag in re.findall(r"(?is)<item\b[^>]*>", opf):
            mid = re.search(r'\bid="([^"]+)"', tag)
            href = re.search(r'\bhref="([^"]+)"', tag)
            if mid and href:
                items[mid.group(1)] = html.unescape(href.group(1))
        spine = re.findall(r'(?is)<itemref\b[^>]*\bidref="([^"]+)"', opf)
        hrefs = [items[i] for i in spine if i in items] or list(items.values())

        chapters = []
        for href in hrefs:
            path = posixpath.normpath(posixpath.join(base, href.split("#")[0])) \
                if base else posixpath.normpath(href.split("#")[0])
            if path not in names:
                continue
            blob = zf.read(path)
            try:
                page = blob.decode("utf-8")
            except UnicodeDecodeError:
                page = blob.decode("utf-8", "ignore")
            paras = _html_paras(page)
            if not paras:
                continue
            # 纯图片页 / 空白版权页，跳过（阈值放低，短诗也算一章）
            if sum(len(p) for p in paras) < 6:
                continue
            ct = _epub_title(page, "第%d章" % (len(chapters) + 1))
            # 标题通常也被包含在正文第一段，阅读器会单独显示标题，去掉重复
            if paras and paras[0].replace(" ", "") == ct.replace(" ", ""):
                paras = paras[1:]
            if not paras:
                continue
            chapters.append((ct, paras))
    return title, author, intro, chapters


def parse_txt(raw, fallback_title=""):
    text = _decode(raw)
    author = ""
    m = re.search(r"作\s*者\s*[:：]\s*([^\n]{1,24})", text[:3000])
    if m:
        author = m.group(1).strip()
    title = fallback_title or "未命名"
    # 文件开头写了「书名：xxx」或「《xxx》」时优先用它，文件名常是拼音/序号
    m = re.match(r"^\s*(?:书\s*名|《)\s*[:：]?\s*([^\n》]{1,30})", text[:600])
    if m and m.group(1).strip():
        title = m.group(1).strip()
    return title, author, "", split_txt(text)


# ---------------------------------------------------------------- 漫画包

def _natural(name):
    """1.jpg / 2.jpg / 10.jpg 要按数字排，不能按字符串（否则 10 排在 2 前面）。"""
    return [int(t) if t.isdigit() else t.lower()
            for t in re.split(r"(\d+)", str(name or ""))]


def _img_ext(name):
    ext = posixpath.splitext(str(name or ""))[1].lower()
    if ext in (".jpeg", ".jpe"):
        return ".jpg"
    return ext if ext in IMG_EXT else ""


def _sniff_ext(blob, name=""):
    """优先看文件头：压缩包里的扩展名经常是错的（.jpg 其实是 png）。"""
    if blob[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if blob[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
        return ".webp"
    if blob[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if blob[:2] == b"BM":
        return ".bmp"
    return _img_ext(name)


def _comic_entries(names):
    out = []
    for n in names:
        if n.endswith("/") or "__MACOSX" in n:
            continue
        base = posixpath.basename(n)
        if not base or base.startswith("."):
            continue
        if _img_ext(base):
            out.append(n)
    return out


def _group_by_dir(names, fallback):
    """一个目录一话；只有一层图片就整包一话（常见于单话 CBZ）。"""
    by_dir = {}
    for n in names:
        by_dir.setdefault(posixpath.dirname(n), []).append(n)
    if len(by_dir) >= 2:
        groups = []
        for d in sorted(by_dir, key=_natural):
            label = posixpath.basename(d) or ("第%d话" % (len(groups) + 1))
            groups.append((label, sorted(by_dir[d], key=_natural)))
        return groups
    return [(fallback, sorted(names, key=_natural))]


def parse_zip_comic(raw, fallback):
    """CBZ / ZIP → [(话名, [(原文件名, 图片字节)])]。"""
    import io

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        names = _comic_entries(zf.namelist())
        if not names:
            raise ValueError("压缩包里没有图片（支持 jpg / png / webp / gif）")
        groups = []
        for label, items in _group_by_dir(names, fallback):
            pages = [(posixpath.basename(n), zf.read(n)) for n in items]
            pages = [(nm, b) for nm, b in pages if b]
            if pages:
                groups.append((label, pages))
    return groups


def parse_epub_comic(raw, fallback):
    """图片版 EPUB：按 spine 顺序取每页的 <img>，一个 xhtml 当一个话。"""
    import io

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        names = set(zf.namelist())
        opf_path = ""
        try:
            cont = zf.read("META-INF/container.xml").decode("utf-8", "ignore")
            m = re.search(r'full-path="([^"]+)"', cont)
            if m:
                opf_path = m.group(1)
        except KeyError:
            pass
        if not opf_path:
            cand = [n for n in names if n.lower().endswith(".opf")]
            opf_path = cand[0] if cand else ""
        if not opf_path or opf_path not in names:
            raise ValueError("这个 EPUB 缺少 OPF 目录文件，无法解析")

        base = posixpath.dirname(opf_path)
        opf = zf.read(opf_path).decode("utf-8", "ignore")
        items = {}
        for tag in re.findall(r"(?is)<item\b[^>]*>", opf):
            mid = re.search(r'\bid="([^"]+)"', tag)
            href = re.search(r'\bhref="([^"]+)"', tag)
            if mid and href:
                items[mid.group(1)] = html.unescape(href.group(1))
        spine = re.findall(r'(?is)<itemref\b[^>]*\bidref="([^"]+)"', opf)
        hrefs = [items[i] for i in spine if i in items] or list(items.values())

        groups = []
        for href in hrefs:
            path = posixpath.normpath(posixpath.join(base, href.split("#")[0])) \
                if base else posixpath.normpath(href.split("#")[0])
            if path not in names:
                continue
            page = zf.read(path).decode("utf-8", "ignore")
            pages = []
            for src in re.findall(r'(?is)<img[^>]+src="([^"]+)"', page):
                p = posixpath.normpath(posixpath.join(
                    posixpath.dirname(path), html.unescape(src).split("#")[0]))
                if p in names:
                    pages.append((posixpath.basename(p), zf.read(p)))
            if pages:
                groups.append((_epub_title(page, "第%d话" % (len(groups) + 1)), pages))
    return groups


def _import_comic(name, raw, fallback):
    """把漫画包解压成「每话一个 JSON + 一堆编号图片」。"""
    lower = name.lower()
    if lower.endswith((".cbz", ".zip")) or not lower.endswith(".epub"):
        groups = parse_zip_comic(raw, fallback)
    else:
        groups = parse_epub_comic(raw, fallback)
    if not groups:
        raise ValueError("这本漫画没有解析出任何可看的页")

    h = _hash(raw, fallback)
    bid = PREFIX + h
    img_dir = os.path.join(_chap_dir(h), "img")
    os.makedirs(img_dir, exist_ok=True)

    catalog, seq = [], 0
    for label, pages in groups:
        keep = []
        for src_name, blob in pages:
            ext = _sniff_ext(blob, src_name)
            if not ext or not blob:
                continue
            seq += 1
            fn = "%06d%s" % (seq, ext)
            with open(os.path.join(img_dir, fn), "wb") as f:
                f.write(blob)
            keep.append(fn)
        if not keep:
            continue
        idx = len(catalog)
        url = "%s%s/%d" % (PREFIX, h, idx)
        with open(os.path.join(_chap_dir(h), "%06d.json" % idx), "w", encoding="utf-8") as f:
            json.dump({"title": label, "kind": "comic", "pages": keep, "url": url},
                      f, ensure_ascii=False)
        catalog.append({"t": label, "u": url, "i": idx})

    if not catalog:
        raise ValueError("这本漫画没有可显示的图片")

    meta = {
        "id": bid,
        "title": fallback,
        "author": "佚名",
        "intro": "本地导入的漫画，无需联网，打开即可阅读。",
        "source": SRC_NAME,
        "category": "本地漫画",
        "status": "%d 话" % len(catalog),
        "cover": "/api/local/page?id=%s&ch=0&i=0" % bid,
        "created": time.time(),
        "count": len(catalog),
        "kind": "comic",
        "unit": "话",
        "chapters": [{"t": c["t"], "u": c["u"]} for c in catalog],
    }
    with open(_meta_path(h), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    return meta


# ------------------------------------------------------------------ 导入 / 读取

def _clean_intro(intro):
    t = re.sub(r"\s+", " ", str(intro or "")).strip()
    return t[:800]


def import_bytes(name, raw):
    """导入一份 TXT / EPUB，落盘并返回书籍信息（含章节目录）。"""
    name = str(name or "未命名.txt")
    if not raw:
        raise ValueError("文件是空的")
    lower = name.lower()
    fallback = re.sub(r"\.(txt|epub|cbz|zip|text)$", "", name, flags=re.I).strip() or "未命名"

    # 漫画包动辄一百多兆，纯文本 40MB 已经是天量，两个上限分开
    is_comic_pack = lower.endswith((".cbz", ".zip"))
    limit = MAX_COMIC_BYTES if is_comic_pack or lower.endswith(".epub") else MAX_BYTES
    if len(raw) > limit:
        raise ValueError("文件超过 %dMB，请先拆分再导入" % (limit // (1024 * 1024)))

    if is_comic_pack:
        if raw[:2] != b"PK":
            raise ValueError("这不是有效的 CBZ / ZIP 文件")
        return _import_comic(name, raw, fallback)

    if lower.endswith(".epub") or raw[:2] == b"PK":
        if raw[:2] != b"PK":
            raise ValueError("这不是有效的 EPUB 文件")
        title, author, intro, chapters = parse_epub(raw, fallback)
        if not chapters:
            # 文字层是空的：多半是图片版漫画 EPUB，按漫画再解一次
            return _import_comic(name, raw, fallback)
    else:
        title, author, intro, chapters = parse_txt(raw, fallback)

    if not chapters:
        raise ValueError("没有解析到任何正文，换个文件试试")

    # 同一份文件重复导入复用同一个 id，避免书架里出现两条一模一样的书
    h = _hash(raw, title)
    bid = PREFIX + h
    os.makedirs(_chap_dir(h), exist_ok=True)

    catalog = []
    for i, item in enumerate(chapters):
        if isinstance(item[1], list):
            ct, paras = item[0], item[1]
        else:
            ct, paras = item[0], _paras(item[1])
        if not paras:
            continue
        idx = len(catalog)
        url = "%s%s/%d" % (PREFIX, h, idx)
        with open(os.path.join(_chap_dir(h), "%06d.json" % idx), "w", encoding="utf-8") as f:
            json.dump({"title": ct, "paras": paras, "url": url}, f, ensure_ascii=False)
        catalog.append({"t": ct, "u": url, "i": idx})

    meta = {
        "id": bid,
        "title": title,
        "author": author or "佚名",
        "intro": _clean_intro(intro) or "本地导入的书，无需联网，打开即可阅读。",
        "source": SRC_NAME,
        "category": "本地导入",
        "status": "%d 章" % len(catalog),
        "cover": "",
        "created": time.time(),
        "count": len(catalog),
        "chapters": [{"t": c["t"], "u": c["u"]} for c in catalog],
    }
    with open(_meta_path(h), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    return meta


def book(bid):
    h = _hash_of(bid)
    if not h:
        raise ValueError("不是本地书籍")
    path = _meta_path(h)
    if not os.path.isfile(path):
        raise ValueError("这本书已经不在本地了")
    with open(path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    meta["count"] = len(meta.get("chapters") or [])
    return meta


def chapter(url):
    m = re.match(r"^loc:([0-9a-f]{8,16})/(\d+)$", str(url or ""))
    if not m:
        raise ValueError("章节地址不合法")
    h, idx = m.group(1), m.group(2)
    path = os.path.join(_chap_dir(h), "%06d.json" % int(idx))
    if not os.path.isfile(path):
        raise ValueError("这一章的正文丢了，重新导入一次试试")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    data["bookId"] = PREFIX + h
    if data.get("kind") == "comic":
        # 页面地址统一成接口形式，前端不关心图片是本地解压的还是线上拉的
        data["pages"] = ["/api/local/page?id=%s%s&ch=%d&i=%d"
                         % (PREFIX, h, int(idx), i)
                         for i in range(len(data.get("pages") or []))]
    return data


def page(bid, ch, i):
    """读一页本地漫画图，返回 (bytes, content-type)。"""
    h = _hash_of(bid)
    if not h:
        raise ValueError("不是本地书籍")
    try:
        ch, i = int(ch), int(i)
    except (TypeError, ValueError):
        raise ValueError("页参数不合法") from None
    path = os.path.join(_chap_dir(h), "%06d.json" % ch)
    if not os.path.isfile(path):
        raise ValueError("没有这一话")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    pages = data.get("pages") or []
    if not (0 <= i < len(pages)):
        raise ValueError("没有这一页")
    fn = str(pages[i])
    if "/" in fn or "\\" in fn or ".." in fn:
        raise ValueError("页地址不合法")
    p = os.path.join(_chap_dir(h), "img", fn)
    if not os.path.isfile(p):
        raise ValueError("这一页的图片不见了")
    ext = posixpath.splitext(fn)[1].lower()
    with open(p, "rb") as f:
        return f.read(), _IMG_MIME.get(ext, "image/jpeg")


def list_books():
    out = []
    if not os.path.isdir(LOCAL_DIR):
        return out
    for name in os.listdir(LOCAL_DIR):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(LOCAL_DIR, name), "r", encoding="utf-8") as f:
                meta = json.load(f)
        except Exception:  # noqa: BLE001
            continue
        out.append({
            "id": meta.get("id") or "",
            "title": meta.get("title") or "",
            "author": meta.get("author") or "",
            "count": len(meta.get("chapters") or []),
            "created": meta.get("created") or 0,
        })
    out.sort(key=lambda x: -(x.get("created") or 0))
    return out


def delete(bid):
    h = _hash_of(bid)
    if not h:
        return False
    removed = False
    meta = _meta_path(h)
    if os.path.isfile(meta):
        os.remove(meta)
        removed = True
    folder = _chap_dir(h)
    if os.path.isdir(folder):
        for name in os.listdir(folder):
            try:
                os.remove(os.path.join(folder, name))
            except OSError:
                pass
        try:
            os.rmdir(folder)
        except OSError:
            pass
        removed = True
    return removed
