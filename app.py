"""
拾光阅读器 —— 本地服务 + 启动器
纯 Python 标准库实现：本地 HTTP 服务 + Edge 应用窗口 + 本地缓存
"""
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

ROOT = os.environ.get("SUDUGU_ROOT") or os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(ROOT, "web")
DATA = os.environ.get("SUDUGU_DATA") or os.path.join(ROOT, "data")
CACHE = os.path.join(DATA, "cache")
IMG = os.path.join(DATA, "img")
STATE_FILE = os.path.join(DATA, "state.json")
PORT = 8791

for d in (DATA, CACHE, IMG):
    os.makedirs(d, exist_ok=True)

sys.path.insert(0, ROOT)

# iOS / Android 内嵌 CPython 没有系统 CA 根证书，HTTPS 请求会全部报
# CERTIFICATE_VERIFY_FAILED。打包时把 certs/cacert.pem 放到代码根目录，
# 这里显式告诉 OpenSSL 去哪里找根证书（桌面端仍用系统证书，不受影响）。
if sys.platform in ("ios", "android") or os.environ.get("SUDUGU_EMBEDDED"):
    _ca = os.path.join(ROOT, "cacert.pem")
    if os.path.exists(_ca):
        os.environ.setdefault("SSL_CERT_FILE", _ca)
from reader import ali, bc, blxs, core, dq, gsh, kuaikan, mkz, qbxs, qm, shuqi, net, localbook  # noqa: E402

# 统一网络层：证书链兼容、gzip 解压、默认超时、可读错误（对全部书源生效）
net.install()

_LOCK = threading.Lock()
LAST_PING = [0.0]
PING_SEEN = [False]


# ------------------------------------------------------------------ 缓存 / 状态

def _diag(msg):
    """state.json 读写异常时留一行现场，出问题能查，正常时不产生文件。"""
    try:
        with open(os.path.join(DATA, "diag.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%m-%d %H:%M:%S"), msg))
    except OSError:
        pass


def _read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except Exception as e:  # noqa: BLE001
        _diag("read fail %s: %r" % (os.path.basename(path), e))
        return default


def _write_json(path, obj):
    # tmp 名带上线程 id：两个线程同时写同一个文件时不会互相踩。
    # 之前固定用 path + ".tmp"，并发下会把目标文件替换成半截内容（书架会突然变空）
    tmp = "%s.%d.tmp" % (path, threading.get_ident())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    for i in range(6):
        try:
            os.replace(tmp, path)
            return
        except OSError as e:  # noqa: BLE001
            _diag("replace fail %s: %r" % (os.path.basename(path), e))
            if i >= 5:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
                raise
            time.sleep(0.02)


def _cache_name(key):
    """缓存文件名要干净：七猫的书 id 带冒号，Windows 文件名不允许。"""
    return re.sub(r"[^0-9A-Za-z_\-\u4e00-\u9fff]", "_", str(key))


def cache_get(key, ttl=None):
    path = os.path.join(CACHE, _cache_name(key) + ".json")
    obj = _read_json(path)
    if not obj:
        return None
    if ttl is not None and time.time() - obj.get("ts", 0) > ttl:
        return None
    return obj.get("data")


def cache_set(key, data):
    _write_json(os.path.join(CACHE, _cache_name(key) + ".json"),
                {"ts": time.time(), "data": data})


def load_state():
    # 后台线程在写 state 时，读端偶尔会碰上 replace 的瞬间；读失败重试一次，
    # 免得把空书架当成真的写回去（那会丢进度）
    st = None
    for _ in range(3):
        st = _read_json(STATE_FILE, None)
        if isinstance(st, dict) and st:
            break
        if st is not None:
            break
        time.sleep(0.04)
    if not isinstance(st, dict):
        st = {}
    st.setdefault("shelf", {})
    st.setdefault("progress", {})
    st.setdefault("settings", {})
    st.setdefault("history", [])
    st.setdefault("marks", [])
    st.setdefault("stats", {"days": {}})
    return st


_LAST_SHELF = [None]


def save_state(st):
    # 书架从「有书」变成「空」才留现场（用户主动删光也是这个特征，但很少见）；
    # 正常的增删单本不记，免得日志越滚越大
    keys = sorted((st.get("shelf") or {}).keys())
    if keys != _LAST_SHELF[0]:
        if _LAST_SHELF[0] and not keys:
            stack = " < ".join(f.name for f in traceback.extract_stack(limit=5)[:-1])
            _diag("shelf cleared by %s (progress=%d)" % (stack, len(st.get("progress") or {})))
        _LAST_SHELF[0] = keys
    _write_json(STATE_FILE, st)


# ------------------------------------------------------------------ 业务

def api_home():
    data = cache_get("home", ttl=600)
    if data:
        return data
    data = core.home()
    data["categories"] = core.CATEGORIES
    cache_set("home", data)
    return data


def api_book(bid, refresh=False):
    if localbook.is_local(bid):
        return localbook.book(bid)
    key = "book_%s" % bid
    if not refresh:
        data = cache_get(key, ttl=900)
        if data:
            return data
    data = core.book(bid)
    cache_set(key, data)
    return data


def chapter_key(url, with_bid=False):
    """章节缓存 key。离线判断和预取都复用它，避免两套算法对不上。"""
    if mkz.is_mkz(url):
        parts = [p for p in str(url).replace(mkz.SCHEME, "").replace(mkz.PREFIX, "").split("/") if p]
        bid = mkz.PREFIX + (parts[0] if parts else "")
        cid = parts[1] if len(parts) > 1 else ""
    elif gsh.is_gs(url):
        parts = [p for p in str(url).replace(gsh.SCHEME, "").replace(gsh.PREFIX, "").split("/") if p]
        bid = gsh.PREFIX + (parts[0] if parts else "")
        cid = parts[1] if len(parts) > 1 else ""
    elif kuaikan.is_kk(url):
        parts = [p for p in str(url).replace(kuaikan.SCHEME, "").replace(kuaikan.PREFIX, "").split("/") if p]
        bid = kuaikan.PREFIX + (parts[0] if parts else "")
        cid = parts[1] if len(parts) > 1 else ""
    elif qm.is_qm(url):
        parts = [p for p in url.replace(qm.SCHEME, "").split("/") if p]
        bid = qm.PREFIX + (parts[0] if parts else "")
        cid = parts[1] if len(parts) > 1 else ""
    elif shuqi.is_sq(url):
        parts = [p for p in url.replace(shuqi.SCHEME, "").split("/") if p]
        bid = shuqi.PREFIX + (parts[0] if parts else "")
        cid = parts[1] if len(parts) > 1 else ""
    elif qbxs.is_qb(url):
        parts = [p for p in url.replace(qbxs.SCHEME, "").split("/") if p]
        bid = qbxs.PREFIX + (parts[0] if parts else "")
        cid = (parts[1] if len(parts) > 1 else "").replace(".html", "")
    elif bc.is_bc(url):
        parts = [p for p in url.replace(bc.SCHEME, "").split("/") if p]
        bid = bc.PREFIX + (parts[0] if parts else "")
        cid = (parts[1] if len(parts) > 1 else "").replace(".html", "")
    elif blxs.is_bl(url):
        parts = [p for p in url.replace(blxs.SCHEME, "").split("/") if p]
        bid = blxs.PREFIX + (parts[0] if parts else "")
        cid = (parts[1] if len(parts) > 1 else "").replace(".html", "")
    elif dq.is_dq(url):
        parts = [p for p in url.replace(dq.SCHEME, "").split("/") if p]
        bid = dq.PREFIX + (parts[0] if parts else "")
        cid = (parts[1] if len(parts) > 1 else "").replace(".html", "")
    elif ali.is_ali(url):
        # 章节地址 ali://book/{bid}/{hash}.html：书号在片段里，不是书籍 id
        m = re.search(r"book/(\d+)/([0-9a-z]+)", url)
        bid = ali.PREFIX + (m.group(1) if m else "")
        cid = m.group(2) if m else ""
    else:
        bid = core.book_id(url)
        cid = os.path.basename(urllib.parse.urlsplit(core.normalize(url)).path).replace(".html", "")
    return ("ch_%s_%s" % (bid, cid), bid) if with_bid else "ch_%s_%s" % (bid, cid)


def chapter_cached(url):
    if localbook.is_local(url):
        return True   # 本地书的正文本来就在磁盘上
    return os.path.isfile(os.path.join(CACHE, _cache_name(chapter_key(url)) + ".json"))


def api_chapter(url):
    if localbook.is_local(url):
        return localbook.chapter(url)
    if mkz.is_mkz(url):
        # 漫画每话是一组带签名的图片地址，签名会过期，缓存正文等于缓存一堆死链
        return mkz.chapter(url)
    if gsh.is_gs(url):
        # 图片地址本身不过期，但解出来的列表随时可能跟着源调整，同样不落缓存
        return gsh.chapter(url)
    key, bid = chapter_key(url, True)
    data = cache_get(key)
    if data:
        return data
    data = core.chapter(url)
    if not data.get("bookId"):
        # 爱丽丝书屋的章节 id 里是内部书号，和书籍 id 不是一回事，别覆盖源自己给的
        data["bookId"] = bid
    cache_set(key, data)
    return data


# ------------------------------------------------------------------ 书源 / 换源 / 健康探测 / 章节预取

ALL_SOURCES = [("sd", "速读谷"), ("qm", "七猫"), ("sq", "书旗"), ("qb", "全本网"),
               ("bc", "八叉"), ("bl", "八一"), ("dq", "得奇"), ("ali", "爱丽丝"),
               ("gs", "包子漫画"), ("kk", "快看漫画")]


def disabled_sources():
    """健康面板里被关掉的书源短码。"""
    try:
        return set((load_state().get("settings") or {}).get("disabledSources") or [])
    except Exception:  # noqa: BLE001
        return set()


def _norm(s):
    """书名 / 作者归一化：只保留中英文数字，忽略标点、空格、全半角。"""
    return re.sub(r"[^0-9a-z\u4e00-\u9fff]", "", str(s or "").lower())


def search_data(kw, src="all", fresh=False):
    """搜索缓存。禁用源组合写进 key，开关变化后不会命中旧结果。"""
    skip = disabled_sources() if src == "all" else set()
    key = "search_%s_%s_%s" % (src, kw, "-".join(sorted(skip)))
    data = None if fresh else cache_get(key, ttl=600)
    if not data:
        data = core.search(kw, src, skip=skip)
        if data.get("books"):
            cache_set(key, data)
    return data


def api_sources(title, author, exclude=""):
    """换源候选：用书名（+作者）到全部书源里找同一本书。"""
    data = search_data(title.strip(), "all")
    t, a = _norm(title), _norm(author)
    out = {}
    for b in data.get("books", []):
        if b.get("kind") == "comic":
            continue   # 换源只在小说之间做，漫画的详情页本来也没有换源入口
        if _norm(b.get("title")) != t:
            continue
        ba = _norm(b.get("author"))
        if a and ba and a != ba:
            continue
        src = b.get("source") or ""
        if not src or src == exclude:
            continue
        bid = str(b.get("id") or "")
        if not bid:
            continue
        item = {k: b.get(k) or "" for k in
                ("id", "title", "author", "cover", "category", "words", "intro", "source")}
        # 同一源可能返回多条同名书，只留一条（优先带作者的），菜单里不出现重复源
        cur = out.get(src)
        if cur is None or (not cur.get("author") and item.get("author")):
            out[src] = item
    return {"books": list(out.values()), "msg": data.get("msg") or ""}


HEALTH = {"ts": 0.0, "checking": False, "rows": {}}
_HEALTH_LOCK = threading.Lock()


def health_snapshot(refresh=False):
    now = time.time()
    with _HEALTH_LOCK:
        if (refresh or now - HEALTH["ts"] > 300) and not HEALTH["checking"]:
            HEALTH["checking"] = True
            threading.Thread(target=_health_run, daemon=True).start()
        return {"checking": HEALTH["checking"], "rows": dict(HEALTH["rows"]),
                "ts": HEALTH["ts"], "proxy": ali.proxy_info(),
                "disabled": sorted(disabled_sources())}


def _health_run():
    """各源并发探活，用一次真实搜索判断可用性；结果缓存给前端轮询。"""
    def one(item):
        code = item[0]
        t0 = time.time()
        # 漫画站上没有《斗破苍穹》这种网文，探活得用漫画的常见词
        kw = "斗罗" if code in ("gs", "kk") else "斗破苍穹"
        try:
            r = core.search(kw, code)
            n = len(r.get("books") or [])
            row = {"ok": bool(n), "ms": int((time.time() - t0) * 1000),
                   "msg": ("%d 本" % n) if n else ((r.get("msg") or "没有结果")[:90])}
        except Exception as e:  # noqa: BLE001
            row = {"ok": False, "ms": int((time.time() - t0) * 1000),
                   "msg": str(e)[:90]}
        return code, row

    try:
        with ThreadPoolExecutor(max_workers=len(ALL_SOURCES)) as ex:
            rows = dict(ex.map(one, ALL_SOURCES))
    except Exception:  # noqa: BLE001
        rows = {}
    with _HEALTH_LOCK:
        HEALTH["rows"] = rows
        HEALTH["ts"] = time.time()
        HEALTH["checking"] = False


def _file_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _dir_size(d, exts=None):
    total = 0
    try:
        names = os.listdir(d)
    except OSError:
        return 0
    for name in names:
        if exts and os.path.splitext(name)[1].lower() not in exts:
            continue
        total += _file_size(os.path.join(d, name))
    return total


def cache_status():
    """书架里每本书的章节缓存情况（只读磁盘，不联网）。"""
    out = {}
    shelf = load_state().get("shelf") or {}
    for bid in shelf:
        if localbook.is_local(bid):
            try:
                b = localbook.book(bid)
                n = len(b.get("chapters") or [])
                title = b.get("title") or bid
            except Exception:  # noqa: BLE001
                n = 0
                title = (shelf.get(bid) or {}).get("title") or bid
            out[bid] = {"cached": n, "upto": n, "total": n, "bytes": 0, "local": True,
                        "title": title}
            continue
        book = cache_get("book_%s" % bid) or {}
        chapters = book.get("chapters") or []
        keys = [chapter_key(c.get("u") or "") for c in chapters]
        paths = [os.path.join(CACHE, _cache_name(k) + ".json") for k in keys]
        hit = [os.path.isfile(p) for p in paths]
        upto = 0
        while upto < len(hit) and hit[upto]:
            upto += 1
        out[bid] = {"cached": sum(hit), "upto": upto, "total": len(keys),
                    "bytes": sum(_file_size(p) for p, h in zip(paths, hit) if h),
                    "title": (shelf.get(bid) or {}).get("title") or book.get("title") or bid}
    return {"cache": out, "bytes": _dir_size(CACHE, {".json"}),
            "img": _dir_size(IMG), "local": _dir_size(os.path.join(DATA, "local"))}


def clear_cache(bid=None):
    """清理章节缓存。bid 为空时清空全部；目录缓存保留，书架的数字和目录都还在。"""
    removed = 0
    freed = 0
    if bid:
        book = cache_get("book_%s" % bid) or {}
        paths = [os.path.join(CACHE, _cache_name(chapter_key(c.get("u") or "")) + ".json")
                 for c in (book.get("chapters") or [])]
    else:
        try:
            paths = [os.path.join(CACHE, n) for n in os.listdir(CACHE) if n.endswith(".json")]
        except OSError:
            paths = []
    for p in paths:
        size = _file_size(p)
        try:
            os.remove(p)
            removed += 1
            freed += size
        except OSError:
            pass
    return {"ok": True, "removed": removed, "freed": freed}


# ------------------------------------------------------------------ 追更：书架检查更新

UPDATES = {"at": 0.0, "busy": False, "items": {}}
_UP_LOCK = threading.Lock()


def _latest_count(bid):
    """书架追更用的最新章节数：目录缓存 15 分钟内直接用，过期重新抓一次。"""
    book = cache_get("book_%s" % bid, ttl=900)
    if not book or not (book.get("chapters") or []):
        book = api_book(bid, refresh=True)
    return len(book.get("chapters") or [])


def updates_snapshot(refresh=False):
    """书架检查更新。检查在后台线程跑，前端轮询 checking，列表不用干等。"""
    now = time.time()
    with _UP_LOCK:
        due = refresh or (now - UPDATES["at"] > 600)
        if due and not UPDATES["busy"]:
            shelf = load_state().get("shelf") or {}
            if any(not localbook.is_local(b) for b in shelf):
                UPDATES["busy"] = True
                threading.Thread(target=_updates_run, daemon=True).start()
        return {"checking": UPDATES["busy"], "items": dict(UPDATES["items"]),
                "at": UPDATES["at"], "shelf": load_state().get("shelf") or {}}


def _updates_run():
    """并发拉 4 本，只看章节数变化；有新增就记 newCh，等用户打开这本书再清掉。"""
    targets = [(bid, b) for bid, b in (load_state().get("shelf") or {}).items()
               if not localbook.is_local(bid)]

    def one(item):
        bid, b = item
        old = int(b.get("count") or 0)
        try:
            n = _latest_count(bid)
            if not n:
                return bid, {"ok": False, "msg": "目录为空", "count": old}
            return bid, {"ok": True, "count": n, "added": max(0, n - old) if old else 0}
        except Exception as e:  # noqa: BLE001
            return bid, {"ok": False, "msg": str(e)[:80], "count": old}

    items = {}
    if targets:
        try:
            with ThreadPoolExecutor(max_workers=4) as ex:
                for bid, row in ex.map(one, targets):
                    items[bid] = row
        except Exception:  # noqa: BLE001
            items = {}
    with _LOCK:
        st = load_state()
        for bid, row in items.items():
            cur = st["shelf"].get(bid)
            if cur is None or not row.get("ok"):
                continue
            n = row.get("count") or 0
            if n and n != int(cur.get("count") or 0):
                cur["count"] = n
            if row.get("added"):
                cur["newCh"] = int(row["added"])
                cur["updAt"] = time.time()
        save_state(st)
    with _UP_LOCK:
        UPDATES["items"] = items
        UPDATES["at"] = time.time()
        UPDATES["busy"] = False


def history_snapshot():
    """阅读历史：补上书名，history 里只有 bookId，书可能已经不在书架了。"""
    st = load_state()
    shelf = st.get("shelf") or {}
    prog = st.get("progress") or {}
    out = []
    for h in (st.get("history") or []):
        bid = str(h.get("bookId") or "")
        if not bid:
            continue
        title = h.get("title") or (shelf.get(bid) or {}).get("title") or ""
        if not title:
            # 旧版本写的历史没有书名，借目录缓存补一下，别在列表里露一串书号
            title = str((cache_get("book_%s" % bid) or {}).get("title") or "")
        if localbook.is_local(bid):
            # 本地书删掉以后 history 里还会留一条，别再列出来
            try:
                title = title or str(localbook.book(bid).get("title") or "")
            except Exception:  # noqa: BLE001
                continue
        item = {"bookId": bid, "title": title, "u": h.get("u") or "",
                "t": h.get("t") or "", "i": (prog.get(bid) or {}).get("i", 0),
                "ts": h.get("ts") or 0}
        out.append(item)
    return {"history": out[:40]}


def history_update(body):
    op = body.get("op")
    with _LOCK:
        st = load_state()
        hist = st.get("history") or []
        if op == "clear":
            st["history"] = []
        elif op == "remove":
            bid = str(body.get("bookId") or "")
            st["history"] = [h for h in hist if str(h.get("bookId") or "") != bid]
        save_state(st)
    return {"ok": True, "history": history_snapshot()["history"]}


PREFETCH = {}
_PF_LOCK = threading.Lock()


def start_prefetch(bid, start=0, count=8):
    """后台预取后续章节，只补没缓存的；已缓存 / 正在抓取的都会跳过。"""
    if localbook.is_local(bid):
        return {"ok": True, "queued": 0}   # 本地书不用预取
    if str(bid).startswith((mkz.PREFIX, gsh.PREFIX, kuaikan.PREFIX)):
        # 漫画每话是图片地址列表，不落缓存；预取只会反复拉 JSON，白费流量
        return {"ok": True, "queued": 0}
    book = cache_get("book_%s" % bid)
    if not book:
        return {"ok": False, "queued": 0}
    chapters = book.get("chapters") or []
    start = max(0, int(start or 0))
    count = max(1, min(20, int(count or 8)))
    todo = []
    for i in range(start, min(len(chapters), start + count)):
        u = chapters[i].get("u") or ""
        if not u:
            continue
        k = chapter_key(u)
        if os.path.isfile(os.path.join(CACHE, _cache_name(k) + ".json")):
            continue
        todo.append((i, u))
    with _PF_LOCK:
        busy = PREFETCH.setdefault(bid, set())
        todo = [(i, u) for i, u in todo if i not in busy]
        for i, _ in todo:
            busy.add(i)
    if not todo:
        with _PF_LOCK:
            if not PREFETCH.get(bid):
                PREFETCH.pop(bid, None)
        return {"ok": True, "queued": 0}

    def work():
        def one(item):
            try:
                api_chapter(item[1])
            except Exception:  # noqa: BLE001
                pass
            finally:
                with _PF_LOCK:
                    PREFETCH.get(bid, set()).discard(item[0])

        try:
            with ThreadPoolExecutor(max_workers=3) as ex:
                list(ex.map(one, todo))
        finally:
            with _PF_LOCK:
                if not PREFETCH.get(bid):
                    PREFETCH.pop(bid, None)

    threading.Thread(target=work, daemon=True).start()
    return {"ok": True, "queued": len(todo)}


def switch_source(old_id, new_id):
    """换到另一个书源的同一本书：目录对齐章节 → 迁移进度与书架记录。"""
    new_book = api_book(new_id)
    chapters = new_book.get("chapters") or []
    if not chapters:
        raise RuntimeError("目标书源没有可用目录")

    def label(t):
        return re.sub(r"^第[一二三四五六七八九十百千零〇0-9]+章[\s:：·]*", "",
                      str(t or "")).strip()

    with _LOCK:
        st = load_state()
        old = dict(st["progress"].get(old_id) or {})
    title, want = old.get("t") or "", label(old.get("t"))
    idx = min(max(int(old.get("i") or 0), 0), len(chapters) - 1)
    if want:
        for j, c in enumerate(chapters):
            if label(c.get("t")) == want or c.get("t") == title:
                idx = j
                break
    ch = chapters[idx]
    now = time.time()
    newp = {"u": ch.get("u") or "", "t": ch.get("t") or "", "i": idx,
            "n": len(chapters), "ratio": old.get("ratio", 0), "ts": now}
    with _LOCK:
        st = load_state()
        st["progress"][new_id] = newp
        shelf = st["shelf"]
        prev = shelf.pop(old_id, None)
        if prev:
            item = dict(prev)
            item.update({
                "id": new_id,
                "title": new_book.get("title") or prev.get("title") or "",
                "author": new_book.get("author") or prev.get("author") or "",
                "cover": new_book.get("cover") or prev.get("cover") or "",
                "source": new_book.get("source") or "",
                "count": len(chapters),
                "progress": newp,
                "lastRead": now,
            })
            shelf[new_id] = item
        save_state(st)
        return {"ok": True, "index": idx, "progress": newp, "shelf": st["shelf"],
                "count": len(chapters), "source": new_book.get("source") or ""}


# ------------------------------------------------------------------ 整本下载

DOWNLOADS = {}  # bid -> {"total","done","failed","status"}
_DL_LOCK = threading.Lock()


def start_download(bid):
    """后台线程批量抓取全部章节，写进章节缓存 = 离线可读。已缓存的秒回。"""
    if localbook.is_local(bid):
        return {"status": "local", "total": 0, "done": 0, "failed": 0}
    book = api_book(bid)
    chapters = book.get("chapters") or []
    with _DL_LOCK:
        cur = DOWNLOADS.get(bid)
        if cur and cur.get("status") == "running":
            return dict(cur)
        DOWNLOADS[bid] = {"total": len(chapters), "done": 0, "failed": 0, "status": "running"}

    def work():
        failed = 0

        def one(c):
            nonlocal failed
            try:
                api_chapter(c.get("u"))
            except Exception:  # noqa: BLE001
                failed += 1
            with _DL_LOCK:
                DOWNLOADS[bid]["done"] += 1
                DOWNLOADS[bid]["failed"] = failed

        if chapters:
            with ThreadPoolExecutor(max_workers=6) as ex:
                list(ex.map(one, chapters))
        with _DL_LOCK:
            DOWNLOADS[bid]["status"] = "done"
        # 写进本地状态，供主界面「我的」页展示
        with _LOCK:
            st = load_state()
            st.setdefault("downloads", {})[bid] = {
                "id": bid,
                "title": book.get("title") or "",
                "author": book.get("author") or "",
                "cover": book.get("cover") or "",
                "source": book.get("source") or "",
                "total": len(chapters),
                "failed": DOWNLOADS[bid].get("failed", 0),
                "ts": time.time(),
            }
            save_state(st)

    threading.Thread(target=work, daemon=True).start()
    return dict(DOWNLOADS[bid])


def api_ranking(kind, page):
    """榜单缓存 10 分钟：站点榜单本身更新不快，重复翻页别再打网络。
    抓取失败或抓到空列表时，退回上一份缓存，避免页面突然白掉。"""
    kind = kind if kind in ("lastupdate", "top", "quanben") else "top"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    # 页码超范围时先拿第一页缓存里的总页数夹回去，别让站点去生成第 999 页
    if p > 1:
        head = cache_get("rank_%s_1" % kind)
        if head and head.get("pages") and p > head["pages"]:
            p = head["pages"]
    key = "rank_%s_%s" % (kind, p)
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = core.ranking(kind, p)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if not data.get("books") and old:
        old["note"] = "本次没抓到内容，显示上次抓取的结果"
        return old
    if data.get("books"):
        cache_set(key, data)
    return data


def api_category(cid, page):
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    if p > 1:
        head = cache_get("cat_%s_1" % cid)
        if head and head.get("pages") and p > head["pages"]:
            p = head["pages"]
    key = "cat_%s_%s" % (cid, p)
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    try:
        data = core.category(cid, p)
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_qm_category(cid, page):
    """七猫分类浏览，缓存 5 分钟。"""
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    key = "qmcat_%s_%s" % (cid, p)
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    try:
        data = qm.explore(cid, p)
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    return data


def api_qm_ranking(kind, page):
    """七猫排行榜，缓存 10 分钟；失败回退旧缓存。"""
    kinds = [k for k, _, _ in qm.RANK_TYPES]
    kind = kind if kind in kinds else "hot"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    if p > 1:
        head = cache_get("qmrank_%s_1" % kind)
        if head and head.get("pages") and p > head["pages"]:
            p = head["pages"]
    key = "qmrank_%s_%s" % (kind, p)
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = qm.ranking(kind, p)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_sq_ranking(kind, page):
    """书旗排行榜，缓存 10 分钟。"""
    kinds = [k for k, _ in shuqi.RANKS]
    kind = kind if kind in kinds else "boyClick"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    if p > 1:
        head = cache_get("sqrank_%s_1" % kind)
        if head and head.get("pages") and p > head["pages"]:
            p = head["pages"]
    key = "sqrank_%s_%s" % (kind, p)
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = shuqi.ranking(kind, p)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_sq_store(fc, page):
    """书旗书库分类浏览，缓存 5 分钟。"""
    fc = (fc or "").strip()
    if not re.match(r"^\d+(,\d+)*$", fc):
        fc = ""
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    if p > 1:
        head = cache_get("sqstore_%s_1" % (fc or "all"))
        if head and head.get("pages") and p > head["pages"]:
            p = head["pages"]
    key = "sqstore_%s_%s" % (fc or "all", p)
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    try:
        data = shuqi.store(fc, p)
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_qb_ranking(kind, page):
    """全本小说网榜单，缓存 10 分钟；失败回退旧缓存。"""
    kinds = [k for k, _ in qbxs.RANKS]
    kind = kind if kind in kinds else ""
    key = "qbrank_%s" % (kind or "all")
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = qbxs.ranking(kind, 1)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_qb_sort(cid, page):
    """全本小说网分类 / 完结列表，缓存 5 分钟。"""
    cid = (cid or "").strip()
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    if cid == "all":
        key = "qball_%s" % p
        head_key = "qball_1"
        fetch = lambda: qbxs.quanben(p)  # noqa: E731
    else:
        if cid not in [c for c, _ in qbxs.CATS]:
            cid = "1"
        key = "qbsort_%s_%s" % (cid, p)
        head_key = "qbsort_%s_1" % cid
        fetch = lambda: qbxs.sort(cid, p)  # noqa: E731
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    head = cache_get(head_key)
    if p > 1 and head and head.get("pages") and p > head["pages"]:
        p = head["pages"]
        key = key.rsplit("_", 1)[0] + "_%s" % p
        data = cache_get(key, ttl=300)
        if data:
            return data
        old = cache_get(key)
    try:
        data = fetch()
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_bc_ranking(kind, page):
    """八叉书库榜单，缓存 10 分钟。"""
    kinds = [k for k, _ in bc.RANKS]
    kind = kind if kind in kinds else "popular"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    key = "bcrank_%s_%s" % (kind, p)
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = bc.ranking(kind, p)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_bc_sort(cid, page):
    """八叉书库分类列表，缓存 5 分钟；页码越界按总页数夹取。"""
    cid = (cid or "1").strip()
    if cid not in [c for c, _ in bc.CATS]:
        cid = "1"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    key = "bcsort_%s_%s" % (cid, p)
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    head = cache_get("bcsort_%s_1" % cid)
    if p > 1 and head and head.get("pages") and p > head["pages"]:
        p = head["pages"]
        key = "bcsort_%s_%s" % (cid, p)
        data = cache_get(key, ttl=300)
        if data:
            return data
        old = cache_get(key)
    try:
        data = bc.sort(cid, p)
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_bl_sort(cid, page):
    """八一中文网分类列表，缓存 5 分钟；页码越界按总页数夹取。"""
    cid = (cid or "1").strip()
    if cid not in [c for c, _ in blxs.CATS]:
        cid = "1"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    key = "blsort_%s_%s" % (cid, p)
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    head = cache_get("blsort_%s_1" % cid)
    if p > 1 and head and head.get("pages") and p > head["pages"]:
        p = head["pages"]
        key = "blsort_%s_%s" % (cid, p)
        data = cache_get(key, ttl=300)
        if data:
            return data
        old = cache_get(key)
    try:
        data = blxs.sort(cid, p)
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_bl_ranking(kind):
    """八一中文网榜单，缓存 10 分钟；失败回退旧缓存。"""
    kinds = [k for k, _ in blxs.RANKS]
    kind = kind if kind in kinds else "vote"
    key = "blrank_%s" % kind
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = blxs.ranking(kind)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_dq_sort(cid, page):
    """得奇小说网书库分类，缓存 5 分钟；页码越界按总页数夹取。"""
    cid = (cid or "1").strip()
    if cid not in [c for c, _ in dq.CATS]:
        cid = "1"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    key = "dqsort_%s_%s" % (cid, p)
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    head = cache_get("dqsort_%s_1" % cid)
    if p > 1 and head and head.get("pages") and p > head["pages"]:
        p = head["pages"]
        key = "dqsort_%s_%s" % (cid, p)
        data = cache_get(key, ttl=300)
        if data:
            return data
        old = cache_get(key)
    try:
        data = dq.sort(cid, p)
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_dq_ranking(kind, page):
    """得奇小说网榜单，缓存 10 分钟；失败回退旧缓存。"""
    kinds = [k for k, _ in dq.RANKS]
    kind = kind if kind in kinds else "allvisit"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    key = "dqrank_%s_%s" % (kind, p)
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = dq.ranking(kind, p)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_ali_sort(cid, page):
    """爱丽丝书屋标签分类（29 类，一页 50 本），缓存 5 分钟。"""
    cid = (cid or "65").strip()
    if cid not in [c for c, _ in ali.CATS]:
        cid = "65"
    try:
        p = max(1, int(page or 1))
    except (TypeError, ValueError):
        p = 1
    key = "alisort_%s_%s" % (cid, p)
    data = cache_get(key, ttl=300)
    if data:
        return data
    old = cache_get(key)
    head = cache_get("alisort_%s_1" % cid)
    if p > 1 and head and head.get("pages") and p > head["pages"]:
        p = head["pages"]
        key = "alisort_%s_%s" % (cid, p)
        data = cache_get(key, ttl=300)
        if data:
            return data
        old = cache_get(key)
    try:
        data = ali.sort(cid, p)
    except Exception:
        if old:
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


def api_ali_ranking(kind, page):
    """爱丽丝书屋人气榜：日/周/月/总，各 50 本，缓存 10 分钟。"""
    kinds = [k for k, _ in ali.RANKS]
    kind = kind if kind in kinds else "hits_day"
    key = "alirank_%s" % kind
    data = cache_get(key, ttl=600)
    if data:
        return data
    old = cache_get(key)
    try:
        data = ali.ranking(kind)
    except Exception:
        if old:
            old["note"] = "网络异常，显示上次抓取的内容"
            return old
        raise
    if data.get("books"):
        cache_set(key, data)
    elif old:
        return old
    return data


_IMG_LOCK = threading.Lock()
_IMG_BUSY = set()


def api_img(url):
    """封面代理。

    图片请求会和搜索/详情抢 WKWebView 的同一 host 连接数，慢图床一旦挂住
    就会拖垮所有 API（表现就是 Load failed）。所以这里：短超时、失败缓存、
    同一张图的并发请求去重，失败立刻回占位图，绝不长时间占用连接。
    """
    parts = urllib.parse.urlsplit(url)
    if "sudugu.cc" in parts.netloc:
        name = "%s_%s" % (core.book_id(url),
                          os.path.basename(parts.path) or "cover.jpg")
    else:  # 外部书源（七猫 CDN）的封面，用地址哈希命名
        ext = os.path.splitext(parts.path)[1].lower() or ".jpg"
        if ext not in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
            ext = ".jpg"
        name = "ext_%s%s" % (hashlib.md5(url.encode("utf-8")).hexdigest()[:16], ext)
    path = os.path.join(IMG, name)
    if os.path.exists(path):
        with open(path, "rb") as f:
            return f.read()
    fail = path + ".fail"
    if os.path.exists(fail):
        if time.time() - os.path.getmtime(fail) < 600:
            return None
        try:
            os.remove(fail)
        except OSError:
            pass
    with _IMG_LOCK:
        if name in _IMG_BUSY:
            return None
        _IMG_BUSY.add(name)
    try:
        try:
            if "alicesw" in parts.netloc or "321cdn" in parts.netloc:
                # 这站和它的图床都只对代理可达
                blob, _ = ali.fetch_bytes(url, timeout=8)
            else:
                blob, _ = core.http_get_bytes(url, timeout=6)
            if blob:
                with open(path, "wb") as f:
                    f.write(blob)
                return blob
        except Exception:  # noqa: BLE001
            pass
        try:
            with open(fail, "w") as f:
                f.write("failed")
        except OSError:
            pass
        return None
    finally:
        with _IMG_LOCK:
            _IMG_BUSY.discard(name)


_COMIC_EXT = (".webp", ".jpg", ".png", ".gif")


def api_comic_page(url):
    """漫画单页图片：CDN 直连 + 磁盘缓存。

    这张图可能是漫客栈的（地址里的 auth_key 每次都变），也可能是包子漫画的
    （地址稳定、但要先解密才拿得到）。所以缓存键取「主机 + 路径」：签名轮换后
    路径不变仍然命中，不同图床的同名路径也不会串。返回 (bytes, content-type)。
    """
    parts = urllib.parse.urlsplit(str(url or ""))
    host = (parts.netloc or "").lower()
    if parts.scheme not in ("http", "https") or not host:
        raise RuntimeError("图片地址不合法")
    if not (host.endswith(".6wm.top") or "mkzcdn" in host
            or host.endswith(".kkmh.com") or "/comic/" in parts.path):
        raise RuntimeError("图片地址不合法")
    h = hashlib.md5((host + parts.path).encode("utf-8")).hexdigest()[:20]
    for ext in _COMIC_EXT:
        p = os.path.join(IMG, "comic_%s%s" % (h, ext))
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            with open(p, "rb") as f:
                return f.read(), MIME.get(ext, "image/jpeg")

    if host.endswith(".6wm.top"):
        blob, ctype = gsh.page_bytes(str(url))
    elif host.endswith(".kkmh.com"):
        blob, ctype = kuaikan.page_bytes(str(url))
    else:
        blob, ctype = mkz.page_bytes(str(url))
    if not blob:
        raise RuntimeError("图片没有下载下来")
    ctype = (ctype or "").split(";")[0].strip().lower()
    ext = {".webp": ".webp", ".png": ".png", ".gif": ".gif"}.get(
        "." + ctype.rsplit("/", 1)[-1], ".jpg")
    if blob[:4] == b"\x89PNG":
        ext = ".png"
    elif blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
        ext = ".webp"
    try:
        with open(os.path.join(IMG, "comic_%s%s" % (h, ext)), "wb") as f:
            f.write(blob)
    except OSError:
        pass
    return blob, ctype or "image/jpeg"


def api_comic_open(text):
    """按链接/ID 认出一本在线漫画，顺手返回目录，前端拿到就能直接入架。"""
    # 三家漫画源按地址特征认领；都不认就按「搜索能用的源优先」依次试
    for src in (gsh, kuaikan, mkz):
        if src.looks_like(text):
            data = src.probe(text)
            break
    else:
        data = mkz.probe(text)
    cache_set("book_%s" % data["id"], data)
    return data


# ------------------------------------------------------------------ 本地书 / 书签 / 备份 / 统计

def _today(offset=0):
    return time.strftime("%Y-%m-%d", time.localtime(time.time() + offset * 86400))


def api_local_import(name, raw):
    """导入 TXT / EPUB：解析后落盘，顺手放进书架（用户选的文件就是要读的）。"""
    book = localbook.import_bytes(name, raw)
    with _LOCK:
        st = load_state()
        cur = st["shelf"].get(book["id"], {})
        cur.update({
            "id": book["id"], "title": book["title"], "author": book["author"],
            "cover": "", "source": localbook.SRC_NAME, "count": book["count"],
            "category": book.get("category") or "本地导入",
        })
        cur.setdefault("added", time.time())
        st["shelf"][book["id"]] = cur
        save_state(st)
    out = dict(book)
    out["chapters"] = book.get("chapters") or []
    return {"ok": True, "book": out, "shelf": st["shelf"]}


def api_local_delete(bid):
    removed = localbook.delete(bid)
    with _LOCK:
        st = load_state()
        st["shelf"].pop(bid, None)
        st["progress"].pop(bid, None)
        st["marks"] = [m for m in st.get("marks") or [] if m.get("bookId") != bid]
        save_state(st)
    return {"ok": True, "removed": removed, "shelf": st["shelf"], "marks": st["marks"]}


def _mark_id(m):
    raw = "|".join(str(m.get(k) or "") for k in ("bookId", "u", "type", "text", "page"))
    return hashlib.sha1(raw.encode("utf-8", "ignore")).hexdigest()[:12]


def api_mark(body):
    op = body.get("op") or "add"
    m = body.get("mark") or {}
    with _LOCK:
        st = load_state()
        marks = st.get("marks") or []
        if op == "remove":
            mid = str(body.get("id") or m.get("id") or "")
            marks = [x for x in marks if x.get("id") != mid]
        else:
            item = {
                "id": m.get("id") or "",
                "bookId": str(m.get("bookId") or ""),
                "bookTitle": str(m.get("bookTitle") or ""),
                "i": int(m.get("i") or 0),
                "t": str(m.get("t") or ""),
                "u": str(m.get("u") or ""),
                "page": int(m.get("page") or 1),
                "ratio": float(m.get("ratio") or 0),
                "type": "note" if m.get("type") == "note" else "bookmark",
                "text": str(m.get("text") or "")[:400],
                "note": str(m.get("note") or "")[:1000],
                "ts": time.time(),
            }
            if not item["bookId"]:
                return {"ok": False, "error": "缺少书籍 id"}
            item["id"] = item["id"] or _mark_id(item)
            marks = [x for x in marks if x.get("id") != item["id"]]
            marks.insert(0, item)
        st["marks"] = marks[:500]
        save_state(st)
    return {"ok": True, "marks": st["marks"]}


def stats_snapshot():
    st = load_state()
    days = ((st.get("stats") or {}).get("days") or {})
    today = _today()
    d0 = days.get(today) or {}

    def sec_of(v):
        return float((v or {}).get("sec") or 0)

    total_sec = int(sum(sec_of(v) for v in days.values()))
    total_ch = int(sum(int((v or {}).get("ch") or 0) for v in days.values()))

    # 今天还没读就先从昨天算，避免早上打开只看 0 天
    streak, start = 0, (0 if (sec_of(d0) >= 30 or (d0.get("ch") or 0) > 0) else 1)
    for i in range(start, 400):
        v = days.get(_today(-i)) or {}
        if sec_of(v) >= 30 or (v.get("ch") or 0) > 0:
            streak += 1
        else:
            break

    recent = []
    for i in range(13, -1, -1):
        d = _today(-i)
        v = days.get(d) or {}
        recent.append({"d": d, "sec": int(sec_of(v)), "ch": int(v.get("ch") or 0)})
    return {
        "today": {"sec": int(sec_of(d0)), "ch": int(d0.get("ch") or 0)},
        "total": {"sec": total_sec, "ch": total_ch, "days": sum(1 for v in days.values()
                                                                if sec_of(v) >= 30 or (v.get("ch") or 0) > 0)},
        "streak": streak,
        "recent": recent,
    }


BACKUP_KEYS = ("shelf", "progress", "settings", "marks", "history", "stats", "downloads")


def backup_data():
    st = load_state()
    return {"app": "shiguang", "version": 1, "exported": time.time(),
            "state": {k: st.get(k) for k in BACKUP_KEYS}}


def restore_data(data, mode="merge"):
    """导入备份：merge 只补不改（冲突时保留更新时间较新的），replace 直接覆盖。"""
    if not isinstance(data, dict):
        raise ValueError("备份文件格式不对")
    src = data.get("state") if isinstance(data.get("state"), dict) else data
    if not isinstance(src, dict):
        raise ValueError("备份文件里没有可恢复的数据")
    with _LOCK:
        st = load_state()
        if mode == "replace":
            for k in BACKUP_KEYS:
                if k in src and isinstance(src[k], type(st.get(k))):
                    st[k] = src[k]
        else:
            for k in ("shelf", "progress"):
                dst = st.get(k) or {}
                for bid, item in (src.get(k) or {}).items():
                    if not isinstance(item, dict):
                        continue
                    cur = dst.get(bid)
                    newer = (item.get("lastRead") or item.get("ts") or 0) >= \
                            ((cur or {}).get("lastRead") or (cur or {}).get("ts") or 0)
                    if cur is None or newer:
                        dst[bid] = {**(cur or {}), **item}
                st[k] = dst
            st["settings"] = {**(st.get("settings") or {}), **(src.get("settings") or {})}
            marks = st.get("marks") or []
            have = {m.get("id") for m in marks}
            for m in (src.get("marks") or []):
                if isinstance(m, dict) and m.get("id") not in have:
                    marks.append(m)
            st["marks"] = marks[:500]
            hist = st.get("history") or []
            seen = {h.get("bookId") for h in hist}
            for h in (src.get("history") or []):
                if isinstance(h, dict) and h.get("bookId") not in seen:
                    hist.append(h)
            st["history"] = sorted(hist, key=lambda x: -(x.get("ts") or 0))[:60]
            days = ((st.get("stats") or {}).get("days") or {})
            for d, v in (((src.get("stats") or {}).get("days")) or {}).items():
                if not isinstance(v, dict):
                    continue
                cur = days.get(d) or {}
                days[d] = {"sec": max(float(cur.get("sec") or 0), float(v.get("sec") or 0)),
                           "ch": max(int(cur.get("ch") or 0), int(v.get("ch") or 0))}
            st["stats"] = {"days": days}
        st.setdefault("marks", [])
        st.setdefault("stats", {"days": {}})
        save_state(st)
    return {"ok": True, "state": st, "mode": mode}


# ------------------------------------------------------------------ HTTP

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
}


class _Server(ThreadingHTTPServer):
    """iOS WKWebView 会一次性发来搜索 + 几十张封面请求。

    默认 backlog 只有 5，弱网下封面代理稍慢就会把连接队列挤满，
    后续 API 直接被拒 → 前端报 "Load failed"。这里把队列放宽。
    """
    request_queue_size = 128
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # 静默默认日志
        pass

    # ---------- 工具
    def _send(self, body, ctype="application/json; charset=utf-8", code=200, cache="no-store"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:  # noqa: BLE001
            pass

    def _json(self, obj, code=200):
        self._send(json.dumps(obj, ensure_ascii=False), code=code)

    def _err(self, msg):
        self._json({"error": msg})

    def _q(self):
        return urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)

    def _arg(self, key, default=""):
        return (self._q().get(key) or [default])[0]

    # ---------- GET
    def do_GET(self):  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        try:
            if path.startswith("/api/"):
                return self._api(path)
            return self._static(path)
        except Exception as e:  # noqa: BLE001
            return self._err(str(e))

    def _api(self, path):
        if path == "/api/home":
            return self._json(api_home())
        if path == "/api/book":
            bid = self._arg("id")
            if not bid:
                return self._err("缺少书籍 id")
            return self._json(api_book(bid, self._arg("refresh") == "1"))
        if path == "/api/chapter":
            u = self._arg("u")
            if not u:
                return self._err("缺少章节地址")
            return self._json(api_chapter(u))
        if path == "/api/search":
            kw = self._arg("q").strip()
            src = (self._arg("src") or "all").lower()
            if not kw:
                return self._json({"books": [], "msg": ""})
            # 前端「重新搜索」带 _=时间戳，跳过缓存重新抓所有书源
            return self._json(search_data(kw, src, bool(self._arg("_"))))
        if path == "/api/sources":
            return self._json(api_sources(self._arg("title"), self._arg("author"),
                                          self._arg("exclude")))
        if path == "/api/health":
            return self._json(health_snapshot(self._arg("refresh") == "1"))
        if path == "/api/cache":
            return self._json(cache_status())
        if path == "/api/updates":
            return self._json(updates_snapshot(self._arg("refresh") == "1"))
        if path == "/api/history":
            return self._json(history_snapshot())
        if path == "/api/category":
            return self._json(api_category(self._arg("c", "1"), self._arg("p", "1")))
        if path == "/api/qm/category":
            return self._json(api_qm_category(self._arg("c", "205"), self._arg("p", "1")))
        if path == "/api/qm/ranking":
            return self._json(api_qm_ranking(self._arg("kind", "hot"), self._arg("p", "1")))
        if path == "/api/sq/ranking":
            return self._json(api_sq_ranking(self._arg("kind", "boyClick"), self._arg("p", "1")))
        if path == "/api/sq/store":
            return self._json(api_sq_store(self._arg("fc", ""), self._arg("p", "1")))
        if path == "/api/qb/ranking":
            return self._json(api_qb_ranking(self._arg("kind", ""), self._arg("p", "1")))
        if path == "/api/qb/sort":
            return self._json(api_qb_sort(self._arg("c", "1"), self._arg("p", "1")))
        if path == "/api/bc/ranking":
            return self._json(api_bc_ranking(self._arg("kind", "popular"), self._arg("p", "1")))
        if path == "/api/bc/sort":
            return self._json(api_bc_sort(self._arg("c", "1"), self._arg("p", "1")))
        if path == "/api/bl/ranking":
            return self._json(api_bl_ranking(self._arg("kind", "vote")))
        if path == "/api/bl/sort":
            return self._json(api_bl_sort(self._arg("c", "1"), self._arg("p", "1")))
        if path == "/api/dq/ranking":
            return self._json(api_dq_ranking(self._arg("kind", "allvisit"), self._arg("p", "1")))
        if path == "/api/dq/sort":
            return self._json(api_dq_sort(self._arg("c", "1"), self._arg("p", "1")))
        if path == "/api/ali/ranking":
            return self._json(api_ali_ranking(self._arg("kind", "hits_day"), self._arg("p", "1")))
        if path == "/api/ali/sort":
            return self._json(api_ali_sort(self._arg("c", "65"), self._arg("p", "1")))
        if path == "/api/ranking":
            return self._json(api_ranking(self._arg("kind", "top"), self._arg("p", "1")))
        if path == "/api/img":
            blob = api_img(self._arg("u"))
            if not blob:
                return self._send(PLACEHOLDER, "image/svg+xml")
            ctype = "image/png" if blob[:4] == b"\x89PNG" else (
                "image/webp" if blob[:4] == b"RIFF" and blob[8:12] == b"WEBP" else "image/jpeg")
            return self._send(blob, ctype)
        if path == "/api/comic/page":
            try:
                blob, ctype = api_comic_page(self._arg("u"))
            except Exception as e:  # noqa: BLE001
                return self._json({"error": str(e)}, 502)
            return self._send(blob, ctype, cache="public, max-age=604800")
        if path == "/api/local/page":
            try:
                blob, ctype = localbook.page(
                    self._arg("id"), self._arg("ch", "0"), self._arg("i", "0"))
            except Exception as e:  # noqa: BLE001
                return self._err(str(e))
            return self._send(blob, ctype, cache="public, max-age=604800")
        if path == "/api/download":
            bid = self._arg("bookId")
            with _DL_LOCK:
                st = DOWNLOADS.get(bid)
            return self._json(st or {"status": "none"})
        if path == "/api/downloads":
            return self._json({"downloads": load_state().get("downloads", {})})
        if path == "/api/lan":
            return self._json({"ips": lan_ips(), "port": PORT,
                               "lan": self.server.server_address[0] == "0.0.0.0"})
        if path == "/api/state":
            return self._json(load_state())
        if path == "/api/local/list":
            return self._json({"books": localbook.list_books()})
        if path == "/api/marks":
            return self._json({"marks": load_state().get("marks") or []})
        if path == "/api/stats":
            return self._json(stats_snapshot())
        if path == "/api/backup":
            return self._json(backup_data())
        if path == "/api/ping":
            LAST_PING[0] = time.time()
            PING_SEEN[0] = True
            return self._json({"ok": True})
        return self._err("未知接口")

    def _static(self, path):
        if path in ("/", ""):
            path = "/index.html"
        fp = os.path.normpath(os.path.join(WEB, path.lstrip("/")))
        if not fp.startswith(WEB) or not os.path.isfile(fp):
            return self._send("Not Found", "text/plain; charset=utf-8", 404)
        ext = os.path.splitext(fp)[1].lower()
        with open(fp, "rb") as f:
            blob = f.read()
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(blob)

    # ---------- POST
    def do_POST(self):  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        try:
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
        except Exception:  # noqa: BLE001
            raw = b""
        # 导入书籍是文件二进制，直接在原始 body 上收，不做 JSON 解析
        if path == "/api/local/import":
            try:
                name = self._arg("name") or "未命名.txt"
                return self._json(api_local_import(name, raw))
            except Exception as e:  # noqa: BLE001
                return self._err(str(e))
        try:
            body = json.loads(raw or b"{}")
        except Exception:  # noqa: BLE001
            body = {}
        try:
            if path == "/api/comic/open":
                return self._json(api_comic_open(str(body.get("url") or "")))
            if path == "/api/local/delete":
                bid = str(body.get("bookId") or "")
                if not bid:
                    return self._err("缺少书籍 id")
                return self._json(api_local_delete(bid))
            if path == "/api/mark":
                return self._json(api_mark(body))
            if path == "/api/cache":
                return self._json(clear_cache(str(body.get("bookId") or "") or None))
            if path == "/api/history":
                return self._json(history_update(body))
            if path == "/api/restore":
                return self._json(restore_data(body.get("data"), body.get("mode") or "merge"))
            if path == "/api/shelf":
                return self._shelf(body)
            if path == "/api/download":
                bid = str(body.get("bookId") or "")
                if not bid:
                    return self._err("缺少 bookId")
                return self._json(start_download(bid))
            if path == "/api/prefetch":
                bid = str(body.get("bookId") or "")
                if not bid:
                    return self._err("缺少 bookId")
                return self._json(start_prefetch(bid, body.get("from", 0), body.get("count", 8)))
            if path == "/api/switch":
                old = str(body.get("from") or "")
                new = str(body.get("to") or "")
                if not old or not new:
                    return self._err("缺少书籍 id")
                return self._json(switch_source(old, new))
            if path == "/api/downloads":
                bid = str(body.get("bookId") or "")
                with _LOCK:
                    st = load_state()
                    removed = (st.get("downloads") or {}).pop(bid, None)
                    save_state(st)
                return self._json({"ok": True, "removed": bool(removed)})
            if path == "/api/progress":
                return self._progress(body)
            if path == "/api/settings":
                with _LOCK:
                    st = load_state()
                    st["settings"].update(body.get("settings") or {})
                    save_state(st)
                return self._json({"ok": True})
            return self._err("未知接口")
        except Exception as e:  # noqa: BLE001
            return self._err(str(e))

    def _shelf(self, body):
        op = body.get("op")
        book = body.get("book") or {}
        with _LOCK:
            st = load_state()
            bid = str(book.get("id") or "")
            if op == "add" and bid:
                cur = st["shelf"].get(bid, {})
                cur.update({k: v for k, v in book.items() if v not in (None, "")})
                cur.setdefault("added", time.time())
                st["shelf"][bid] = cur
            elif op == "remove" and bid:
                _diag("shelf remove %r" % bid)
                st["shelf"].pop(bid, None)
            elif op == "touch" and bid:
                if bid in st["shelf"]:
                    st["shelf"][bid]["lastRead"] = time.time()
            elif op == "seen" and bid:
                # 打开这本书就算「看过更新了」，清掉书架的 +N 章标记
                cur = st["shelf"].get(bid)
                if cur is not None:
                    cur.pop("newCh", None)
                    cur.pop("updAt", None)
            elif op == "meta" and bid:
                # 分组 / 标签：允许显式清空（group="" 或 tags=[]），
                # 不能用 add 那两个空值过滤，否则「取消分组」会失效
                cur = st["shelf"].get(bid)
                if cur is not None:
                    if "group" in book:
                        g = str(book.get("group") or "")
                        if g in ("reading", "todo", "done"):
                            cur["group"] = g
                        else:
                            cur.pop("group", None)
                    if "tags" in book:
                        raw = book.get("tags") or []
                        tags = []
                        for t in raw:  # noqa: PLR1702 - 保持顺序去重，最多 8 个
                            t = str(t).strip()[:12]
                            if t and t not in tags:
                                tags.append(t)
                        if tags:
                            cur["tags"] = tags[:8]
                        else:
                            cur.pop("tags", None)
            save_state(st)
        return self._json({"ok": True, "shelf": st["shelf"]})

    def _progress(self, body):
        bid = str(body.get("bookId") or "")
        if not bid:
            return self._err("缺少 bookId")
        with _LOCK:
            st = load_state()
            item = {
                "u": body.get("u", ""),
                "t": body.get("t", ""),
                "i": body.get("i", 0),
                "n": body.get("n", 0),
                "ratio": body.get("ratio", 0),
                "ts": time.time(),
            }
            # 漫画多两个字段：读到第几页、这一话共几页。小说没有，别写空键
            if body.get("kind") == "comic":
                item["kind"] = "comic"
                try:
                    item["pg"] = max(0, int(body.get("pg") or 0))
                    item["pages"] = max(0, int(body.get("pages") or 0))
                except (TypeError, ValueError):
                    item["pg"], item["pages"] = 0, 0
            st["progress"][bid] = item
            shelf = st["shelf"].get(bid)
            if shelf:
                shelf["progress"] = item
                shelf["lastRead"] = item["ts"]
            hist = [h for h in st["history"] if h.get("bookId") != bid]
            hist.insert(0, {"bookId": bid, "u": item["u"], "t": item["t"], "ts": item["ts"],
                            "title": body.get("title") or (shelf or {}).get("title") or ""})
            st["history"] = hist[:60]

            # 阅读统计：前端每隔一段时间带上这段时间读了多少秒
            try:
                sec = max(0.0, min(600.0, float(body.get("sec") or 0)))
            except (TypeError, ValueError):
                sec = 0.0
            if sec >= 1 or body.get("chNew"):
                days = st.setdefault("stats", {}).setdefault("days", {})
                day = days.setdefault(_today(), {"sec": 0, "ch": 0})
                day["sec"] = round(float(day.get("sec") or 0) + sec, 1)
                if body.get("chNew"):
                    day["ch"] = int(day.get("ch") or 0) + 1
                # 只保留最近一年，别让 state.json 无限长
                if len(days) > 400:
                    for key in sorted(days)[:-400]:
                        days.pop(key, None)
            save_state(st)
        return self._json({"ok": True})


PLACEHOLDER = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 400">'
    '<rect width="300" height="400" fill="#e8e0d2"/>'
    '<text x="150" y="205" font-size="22" fill="#b3a893" text-anchor="middle" '
    'font-family="sans-serif">暂无封面</text></svg>'
).encode("utf-8")


# ------------------------------------------------------------------ 启动

def pick_port():
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", PORT))
        return PORT
    except OSError:
        return 0
    finally:
        s.close()


def edge_paths():
    return [
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe"),
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    ]


def open_window(url):
    if os.environ.get("SUDUGU_NO_WINDOW"):
        return False
    for p in edge_paths():
        if os.path.isfile(p):
            args = [
                p, "--app=" + url,
                "--user-data-dir=" + os.path.join(DATA, "browser"),
                "--window-size=1280,880",
                "--no-first-run", "--no-default-browser-check",
                "--disable-features=Translate",
            ]
            try:
                subprocess.Popen(args, close_fds=True)
                return True
            except Exception:  # noqa: BLE001
                continue
    webbrowser.open(url)
    return False


def watchdog(idle_limit):
    """窗口关掉后自动收工：一段时间没有任何心跳/请求就退出，不留后台进程。"""
    while True:
        time.sleep(15)
        if time.time() - LAST_PING[0] > idle_limit:
            os._exit(0)


def lan_ips():
    """本机在局域网里的 IP，供手机/平板访问用。"""
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            ip = info[4][0]
            if (ip.startswith("192.168.") or ip.startswith("10.") or ip.startswith("172.")) and ip not in ips:
                ips.append(ip)
    except Exception:  # noqa: BLE001
        pass
    return ips


def start_server(host="127.0.0.1", port=None):
    """启动 HTTP 服务（供桌面窗口 / exe / apk 共用）。返回 (server, 实际端口)；端口被占返回 (None, PORT)。"""
    port = pick_port() if port is None else port
    if port == 0:
        return None, PORT
    srv = _Server((host, port), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    LAST_PING[0] = time.time()
    return srv, port


def serve_forever():
    """无窗口常驻模式：apk 等宿主直接调用，服务跑起来后阻塞当前线程。"""
    srv, port = start_server("127.0.0.1")
    if srv is None:
        port = PORT
    while True:
        time.sleep(1)


def main():
    host = "0.0.0.0" if os.environ.get("SUDUGU_LAN") else "127.0.0.1"
    srv, port = start_server(host)
    if srv is None:  # 已有实例在跑
        open_window("http://127.0.0.1:%d/" % PORT)
        return
    opened = open_window("http://127.0.0.1:%d/" % port)
    threading.Thread(target=watchdog, args=(180 if opened else 1200,), daemon=True).start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
