"""
统一网络层：给所有书源的 urllib.request.urlopen 打一层薄补丁。

解决的都是「桌面能跑、手机内嵌 Python 跑不了」的环境差异：

1. iOS 内嵌 OpenSSL + Mozilla CA 不会像 Windows 那样沿 AIA 自动补全缺失的中间证书，
   不少小说站的证书链不完整 → CERTIFICATE_VERIFY_FAILED。
   校验失败时自动用不校验证书的上下文重试一次（只适用于公开书源 HTTP 抓取）。
2. 移动网关 / CDN 偶发返回 gzip 但书源没解压 → 正文乱码。统一按 Content-Encoding 解压。
3. 部分书源忘记传 timeout → 弱网下永久挂起，拖死整个线程池。补一个默认超时。
4. 把 SSL / DNS / 超时等原始异常翻译成可读中文，便于搜索页直接显示原因。

注意：ali.py 用的是自建 opener（自带代理探测），不走 urlopen，因此不受影响。
"""
import gzip
import io
import socket
import time
import urllib.error
import urllib.request
import zlib

_ORIG = urllib.request.urlopen
_INSTALLED = False
DEFAULT_TIMEOUT = 20


class _Response(io.BytesIO):
    """把已读完的响应重新包装成类文件对象，保持 with / headers / geturl 语义。"""

    def __init__(self, data, headers, url, code=200):
        super().__init__(data)
        self.headers = headers
        self.url = url
        self.status = code
        self.code = code
        self.reason = "OK"

    def geturl(self):
        return self.url

    def getcode(self):
        return self.code

    def info(self):
        return self.headers

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def _read_all(r):
    """读完并按 Content-Encoding 解压，返回包装后的响应。"""
    raw = r.read()
    enc = (r.headers.get("Content-Encoding") or "").lower()
    decoded = False
    if "gzip" in enc:
        try:
            raw = gzip.decompress(raw)
            decoded = True
        except Exception:  # noqa: BLE001
            pass
    elif "deflate" in enc:
        try:
            try:
                raw = zlib.decompress(raw)
            except zlib.error:
                raw = zlib.decompress(raw, -zlib.MAX_WBITS)
            decoded = True
        except Exception:  # noqa: BLE001
            pass
    hdr = r.headers
    if decoded:
        # 已解压就摘掉这个头，否则 core._ungzip 等上层会再解压一次导致乱码
        try:
            hdr = dict(hdr)
            hdr.pop("Content-Encoding", None)
        except Exception:  # noqa: BLE001
            pass
    url = r.geturl() if hasattr(r, "geturl") else ""
    code = getattr(r, "status", None) or getattr(r, "code", 200) or 200
    try:
        r.close()
    except Exception:  # noqa: BLE001
        pass
    return _Response(raw, hdr, url, code)


def _is_cert_error(e):
    s = ("%s %s" % (type(e).__name__, e)).upper()
    return ("CERTIFICATE_VERIFY_FAILED" in s or "CERT_HAS_EXPIRED" in s
            or "UNABLE_TO_GET_ISSUER_CERT" in s or "SELF_SIGNED" in s
            or "SSLV3_ALERT" in s or "UNKNOWN_CA" in s)


def friendly(e):
    """把底层网络异常翻译成用户能看懂的短句（保留原始类名便于排查）。"""
    if e is None:
        return "未知错误"
    s = str(e)
    up = ("%s %s" % (type(e).__name__, s)).upper()
    if _is_cert_error(e):
        return "证书校验失败（%s）" % s[:90]
    if "TIMED OUT" in up or "TIMEOUT" in up:
        return "连接超时（%s）" % s[:90]
    if "NAMEORSERVICE" in up or "GAIERROR" in up or "NAMERESOLUTION" in up or "11001" in up:
        return "域名解析失败，检查网络（%s）" % s[:90]
    if "CONNECTION REFUSED" in up or "CONNECTIONRESET" in up or "BROKEN PIPE" in up:
        return "连接被中断（%s）" % s[:90]
    if "UNEXPECTED_EOF" in up or "SSLV3" in up or "WRONG_VERSION" in up:
        return "TLS 连接异常（%s）" % s[:90]
    if "404" in up or "NOT FOUND" in up:
        return "页面不存在（%s）" % s[:90]
    return "%s：%s" % (type(e).__name__, s[:120])


def _patched(req, data=None, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, *, context=None, **kw):
    if timeout is socket._GLOBAL_DEFAULT_TIMEOUT or timeout is None:
        timeout = DEFAULT_TIMEOUT
    try:
        r = _ORIG(req, data=data, timeout=timeout, context=context, **kw)
        return _read_all(r)
    except urllib.error.HTTPError:
        raise  # 4xx/5xx 交给各书源自己处理（很多站点靠 302/403 做反爬判定）
    except Exception as e:  # noqa: BLE001
        # 证书链问题：降级为不校验再试一次。iOS 上这是最常见的书源失败原因。
        if _is_cert_error(e) and context is None:
            try:
                import ssl  # 少数裁剪版 CPython 可能没有 ssl 模块，不能让顶层 import 拖垮服务
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                r = _ORIG(req, data=data, timeout=timeout, context=ctx, **kw)
                return _read_all(r)
            except urllib.error.HTTPError:
                raise
            except ImportError:
                pass
            except Exception as e2:  # noqa: BLE001
                raise urllib.error.URLError(friendly(e2)) from e2
        raise urllib.error.URLError(friendly(e)) from e


def install():
    """在 app.py 启动时调用一次。重复调用无副作用。"""
    global _INSTALLED
    if _INSTALLED:
        return
    _INSTALLED = True
    urllib.request.urlopen = _patched
