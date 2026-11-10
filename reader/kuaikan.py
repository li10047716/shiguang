"""快看漫画（kuaikanmanhua.com）漫画源。

站点是 Nuxt1 服务端渲染：详情 / 目录 / 每话的数据都嵌在页面的
`window.__NUXT__=(function(a,b,...){...}(值,...));` 脚本里。重复出现的值被抽到
函数参数表（参数表里还有 `Array(n)` 预分配数组，由函数体里的 `g[0]=...` 语句回填），
所以配了一个小型 JS 字面量求值器（reader/nuxtparse.py）把数据还原出来，不依赖 JS 引擎。

搜索是明文 JSON 接口（search/mini/topic/title_and_author），不用登录签名。
图片 CDN（p1.kkmh.com）的地址带 sign 签名，去掉会 403 —— 签名在打开每话页面时
现发，所以每话的图片列表不落缓存；图片本体按「主机+路径」缓存在 data/img/。
付费话站点只给 3 张预览图，目录里给这类话标了 🔒，点开只有几页是站点行为。
"""

from __future__ import annotations

import re
import time
import urllib.error
import urllib.parse

from . import core
from .nuxtparse import parse_nuxt

SCHEME = "kk://"
PREFIX = "kk:"
SRC_NAME = "快看漫画"

WEB = "https://m.kuaikanmanhua.com"

_UA = ("Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

# 认链接时收下的几种形式：
#   m.kuaikanmanhua.com/mobile/1165/list  www.kuaikanmanhua.com/topic/1165
#   www.kuaikanmanhua.com/webs/comic-topic/1165/
_LINK_RE = re.compile(
    r"kuaikanmanhua\.com/(?:mobile/|topic/|webs/comic-topic/)(\d+)", re.I)


def is_kk(v) -> bool:
    s = str(v or "")
    return s.startswith(PREFIX) or s.startswith(SCHEME)


def native_id(v) -> str:
    s = str(v or "")
    if s.startswith(PREFIX):
        s = s[len(PREFIX):]
    elif s.startswith(SCHEME):
        s = s[len(SCHEME):]
    return s.split("/")[0].strip()


def looks_like(text) -> bool:
    s = str(text or "").strip().lower()
    return s.startswith(PREFIX) or "kuaikanmanhua.com" in s


# ---------------------------------------------------------------- 基础请求

def _http(url, timeout=15):
    req = urllib.request.Request(url, headers={
        "User-Agent": _UA,
        "Accept": "application/json, text/html, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Referer": WEB + "/",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise RuntimeError("这本漫画在站上找不到了（404）") from None
        raise RuntimeError("漫画站点出错了（HTTP %d）" % e.code) from None
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("连不上漫画站点：%s" % e) from None


def _clean(s) -> str:
    s = re.sub(r"<[^>]+>", " ", str(s or ""))
    s = s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&quot;", '"')
    return re.sub(r"\s{2,}", " ", s).strip()


def _tid(v) -> str:
    """作品号只能是纯数字，防止拼进 URL 时被注入。"""
    s = str(v or "").strip()
    if not re.fullmatch(r"\d{1,10}", s):
        raise RuntimeError("漫画地址不合法：%s" % s[:40])
    return s


def _nuxt_page(url):
    """抓页面并解析 __NUXT__，返回 data[0]。"""
    html = _http(url, timeout=20)
    d = parse_nuxt(html)
    if not isinstance(d, dict):
        raise RuntimeError("页面数据解析失败，站点可能改版了")
    data = d.get("data") or []
    if not data or not isinstance(data[0], dict):
        raise RuntimeError("页面数据是空的，这本漫画可能已下架")
    return data[0]


def _fmt_updated(v) -> str:
    """updated_at 可能是毫秒时间戳，可能是 '18-12-25' 这种字符串。"""
    s = str(v or "")
    if re.fullmatch(r"\d{12,14}", s):
        try:
            return time.strftime("%Y-%m-%d", time.localtime(int(s) / 1000))
        except (ValueError, OSError):
            return ""
    return s[:10]


# ---------------------------------------------------------------- 搜索

def search(keyword, page=1):
    keyword = (keyword or "").strip()
    if not keyword:
        return {"books": [], "msg": ""}
    page = max(1, int(page or 1))
    url = ("%s/search/mini/topic/title_and_author?page=%d&size=24&q=%s"
           % (WEB, page, urllib.parse.quote(keyword)))
    raw = _http(url)
    import json
    try:
        d = json.loads(raw)
    except ValueError:
        raise RuntimeError("搜索接口返回的不是 JSON") from None
    if str(d.get("code")) != "200":
        raise RuntimeError(d.get("message") or "搜索接口出错了")
    hits = d.get("hits") or []
    total = int(d.get("total") or len(hits))

    books = []
    for h in hits:
        tid = str(h.get("topic_id") or h.get("id") or "")
        if not tid.isdigit():
            continue
        cats = h.get("category") or []
        books.append({
            "id": PREFIX + tid,
            "title": _clean(h.get("title")),
            "author": _clean(h.get("author_name")),
            "cover": str(h.get("vertical_image_url") or h.get("cover_image_url") or ""),
            "url": SCHEME + tid,
            "category": "、".join(cats[:3]) or "漫画",
            "intro": _clean(h.get("description")),
            "lastChapter": _clean(h.get("latest_comic_title")),
            "count": int(h.get("comics_count") or 0),
            "source": SRC_NAME,
            "kind": "comic",
            "unit": "话",
        })
    books = [b for b in books if b["title"]]
    msg = ""
    if not books and total:
        msg = "%s：这一页没有结果（共 %d 本）" % (SRC_NAME, total)
    return {"books": books, "msg": msg, "total": total}


# ---------------------------------------------------------------- 详情 / 目录

def _chapters(d0):
    """comicList → 目录。付费话（站点不给正文）在标题后加 🔒 提示。"""
    out = []
    for c in d0.get("comicList") or []:
        cid = c.get("id")
        t = _clean(c.get("title"))
        if not cid or not t:
            continue
        if not c.get("is_free") and not c.get("can_view"):
            t += " 🔒"          # 付费话只能看几页预览，提前说清楚
        out.append({
            "t": t,
            "u": "%s%s/%s" % (SCHEME, d0["topicInfo"]["id"], cid),
            "i": len(out),
        })
    return out


def book(tid_or_id):
    tid = _tid(native_id(tid_or_id))
    d0 = _nuxt_page("%s/mobile/%s/list/" % (WEB, tid))
    ti = d0.get("topicInfo") or {}
    chs = _chapters(d0)
    if not chs:
        raise RuntimeError("这本漫画还没有可读的章节")

    title = _clean(ti.get("title"))
    if not title:
        raise RuntimeError("页面上没有书名，可能已下架")
    status = _clean(ti.get("update_status")) or "连载中"
    cats = ti.get("category") or []
    intro = _clean(ti.get("description")) or "这本漫画还没有简介。"
    last = _clean((d0.get("comicList") or [{}])[-1].get("title"))
    updated = _fmt_updated(ti.get("updated_at"))
    author = _clean((ti.get("user") or {}).get("nickname")) or SRC_NAME
    return {
        "id": PREFIX + tid,
        "title": title,
        "author": author,
        "cover": str(ti.get("vertical_image_url") or ti.get("cover_image_url") or ""),
        "intro": intro,
        "category": "、".join(cats[:3]) or "漫画",
        "status": "%s · %d 话" % (status, len(chs)),
        "updated": updated,
        "lastChapter": last,
        "url": SCHEME + tid,
        "chapters": [{"t": c["t"], "u": c["u"]} for c in chs],
        "count": len(chs),
        "source": SRC_NAME,
        "kind": "comic",
        "unit": "话",
    }


def probe(text):
    """从链接 / kk:数字 / 纯数字认出作品。"""
    s = str(text or "").strip()
    m = _LINK_RE.search(s)
    tid = m.group(1) if m else ""
    if not tid and is_kk(s):
        cand = native_id(s)
        tid = cand if cand.isdigit() else ""
    if not tid and re.fullmatch(r"\d{1,10}", s):
        tid = s
    if not tid:
        raise RuntimeError(
            "请粘贴快看漫画的作品链接，例如 %s/mobile/<作品id>/list/" % WEB)
    return book(PREFIX + tid)


# ---------------------------------------------------------------- 每话图片

def chapter(url):
    """一话 = 一组图片。返回 kind=comic，前端据此走漫画渲染。"""
    raw = str(url or "").replace(SCHEME, "")
    parts = [p for p in raw.split("/") if p]
    if len(parts) < 2 or not parts[1].isdigit():
        raise RuntimeError("漫画章节地址不合法")
    tid, cid = _tid(parts[0]), parts[1]

    d0 = _nuxt_page("%s/mobile/comics/%s" % (WEB, cid))
    ci = d0.get("comicInfo") or {}
    pages = [str(p) for p in (ci.get("images") or []) if p]
    if not pages:
        raise RuntimeError("这一话没有取到图片，可能已下架或需要付费")
    # 付费话站点只给几张预览图，目录标题里的 🔒 已经提示过了，这里如实给预览

    around = d0.get("aroundPage") or {}
    # 每话页自己会带 topicInfo.id，优先用它（目录页改版换 id 时也不会跟丢）
    real_tid = str((d0.get("topicInfo") or {}).get("id") or tid)

    def link(v):
        return ("%s%s/%s" % (SCHEME, real_tid, v)) if str(v or "").isdigit() else ""

    return {
        "title": _clean(ci.get("title")) or ("第 %s 话" % cid),
        "bookId": PREFIX + real_tid,
        "kind": "comic",
        "pages": pages,
        "url": "%s%s/%s" % (SCHEME, real_tid, cid),
        "prev": link(around.get("prevId")),
        "next": link(around.get("nextId")),
        "chars": 0,
    }


def page_bytes(url, timeout=20):
    """单页图片：CDN 直连（地址里的 sign 现抓现有效），返回 (bytes, content-type)。"""
    blob, ctype = core.http_get_bytes(url, timeout=timeout)
    if not blob:
        raise RuntimeError("图片没有下载下来")
    return blob, ctype or "image/webp"
