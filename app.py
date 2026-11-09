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
from reader import ali, bc, blxs, core, dq, qbxs, qm, shuqi  # noqa: E402

_LOCK = threading.Lock()
LAST_PING = [0.0]
PING_SEEN = [False]


# ------------------------------------------------------------------ 缓存 / 状态

def _read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:  # noqa: BLE001
        return default


def _write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


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
    st = _read_json(STATE_FILE, {}) or {}
    st.setdefault("shelf", {})
    st.setdefault("progress", {})
    st.setdefault("settings", {})
    st.setdefault("history", [])
    return st


def save_state(st):
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
    key = "book_%s" % bid
    if not refresh:
        data = cache_get(key, ttl=900)
        if data:
            return data
    data = core.book(bid)
    cache_set(key, data)
    return data


def api_chapter(url):
    if qm.is_qm(url):
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
    key = "ch_%s_%s" % (bid, cid)
    data = cache_get(key)
    if data:
        return data
    data = core.chapter(url)
    if not data.get("bookId"):
        # 爱丽丝书屋的章节 id 里是内部书号，和书籍 id 不是一回事，别覆盖源自己给的
        data["bookId"] = bid
    cache_set(key, data)
    return data


# ------------------------------------------------------------------ 整本下载

DOWNLOADS = {}  # bid -> {"total","done","failed","status"}
_DL_LOCK = threading.Lock()


def start_download(bid):
    """后台线程批量抓取全部章节，写进章节缓存 = 离线可读。已缓存的秒回。"""
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


def api_img(url):
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
    try:
        if "alicesw" in parts.netloc or "321cdn" in parts.netloc:
            # 这站和它的图床都只对代理可达
            blob, _ = ali.fetch_bytes(url)
        else:
            blob, _ = core.http_get_bytes(url)
        with open(path, "wb") as f:
            f.write(blob)
        return blob
    except Exception:  # noqa: BLE001
        return None


# ------------------------------------------------------------------ HTTP

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # 静默默认日志
        pass

    # ---------- 工具
    def _send(self, body, ctype="application/json; charset=utf-8", code=200):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
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
            key = "search_%s_%s" % (src, kw)
            # 前端「重新搜索」带 _=时间戳，跳过缓存重新抓所有书源
            fresh = bool(self._arg("_"))
            data = None if fresh else cache_get(key, ttl=600)
            if not data:
                data = core.search(kw, src)
                if data.get("books"):
                    cache_set(key, data)
            return self._json(data)
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
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa: BLE001
            body = {}
        try:
            if path == "/api/shelf":
                return self._shelf(body)
            if path == "/api/download":
                bid = str(body.get("bookId") or "")
                if not bid:
                    return self._err("缺少 bookId")
                return self._json(start_download(bid))
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
                st["shelf"].pop(bid, None)
            elif op == "touch" and bid:
                if bid in st["shelf"]:
                    st["shelf"][bid]["lastRead"] = time.time()
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
            st["progress"][bid] = item
            shelf = st["shelf"].get(bid)
            if shelf:
                shelf["progress"] = item
                shelf["lastRead"] = item["ts"]
            hist = [h for h in st["history"] if h.get("bookId") != bid]
            hist.insert(0, {"bookId": bid, "u": item["u"], "t": item["t"], "ts": item["ts"]})
            st["history"] = hist[:60]
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
    srv = ThreadingHTTPServer((host, port), Handler)
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
