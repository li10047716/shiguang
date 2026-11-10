"""解析快看漫画页面里的 Nuxt1 序列化数据。

页面里是 `window.__NUXT__=(function(a,b,...){return {...}}("值",123,...));`
这种格式：重复出现的字符串/数字被抽到函数参数表里，对象体里用变量名引用。
这里用一个小型 JS 字面量求值器把数据还原成 Python 对象，不依赖 JS 引擎。
"""
import json
import re


def _skip_ws(s, i):
    while i < len(s) and s[i] in " \t\r\n":
        i += 1
    return i


class _Parser:
    """JS 对象字面量求值：支持字符串/数字/true/false/null/void 0/数组/对象/标识符。"""

    def __init__(self, body, scope):
        self.s = body
        self.scope = scope

    def parse(self, i):
        i = _skip_ws(self.s, i)
        c = self.s[i]
        if c == '"':
            return self._string(i)
        if c == "'" or c == '`':
            return self._string(i, c)
        if c == '{':
            return self._obj(i)
        if c == '[':
            return self._arr(i)
        if c.isdigit() or c == '-':
            return self._num(i)
        m = re.match(r"[A-Za-z_$][A-Za-z0-9_$]*", self.s[i:])
        if m:
            word = m.group(0)
            if word == "true":
                return True, i + len(word)
            if word == "false":
                return False, i + len(word)
            if word == "null":
                return None, i + len(word)
            if word == "void":
                i = _skip_ws(self.s, i + len(word))
                m2 = re.match(r"0\b", self.s[i:])
                return None, i + (m2.end() if m2 else 0)
            if word == "Array":
                # Nuxt1 的预分配数组：Array(n) 建一个 n 个空位的数组，
                # 元素由函数体里的 name[idx]=... 语句回填
                m2 = re.match(r"\((\d*)\)", self.s[i + len(word):])
                if m2:
                    n = int(m2.group(1) or 0)
                    return [None] * n, i + len(word) + m2.end()
            if word in self.scope:
                return self.scope[word], i + len(word)
            raise ValueError("未知标识符 %r @%d" % (word, i))
        raise ValueError("不认识的字符 %r @%d" % (c, i))

    def _string(self, i, quote='"'):
        out = []
        i += 1
        while i < len(self.s):
            c = self.s[i]
            if c == "\\":
                out.append(self.s[i:i + 2])
                i += 2
                continue
            if c == quote:
                break
            out.append(c)
            i += 1
        raw = "".join(out)
        raw = raw.replace("\\/", "/").replace("\\'", "'").replace('\\`', '`')
        try:
            return json.loads('"' + raw.replace('"', '\\"') + '"'), i + 1
        except Exception:
            raw = raw.replace('\\"', '"')
            return raw.replace("\\n", "\n").replace("\\t", "\t"), i + 1

    def _num(self, i):
        m = re.match(r"-?\d+(\.\d+)?([eE][+-]?\d+)?", self.s[i:])
        t = m.group(0)
        return (float(t) if "." in t or "e" in t.lower() else int(t)), i + len(t)

    def _obj(self, i):
        out = {}
        i = _skip_ws(self.s, i + 1)
        while self.s[i] != "}":
            key, i = self._key(i)
            i = _skip_ws(self.s, i)
            if self.s[i] == ":":
                i += 1
            val, i = self.parse(i)
            out[key] = val
            i = _skip_ws(self.s, i)
            if self.s[i] == ",":
                i += 1
                i = _skip_ws(self.s, i)
        return out, i + 1

    def _key(self, i):
        if self.s[i] in "\"'":
            return self._string(i)
        m = re.match(r"[A-Za-z0-9_$]+", self.s[i:])
        return m.group(0), i + len(m.group(0))

    def _arr(self, i):
        out = []
        i = _skip_ws(self.s, i + 1)
        while self.s[i] != "]":
            val, i = self.parse(i)
            out.append(val)
            i = _skip_ws(self.s, i)
            if self.s[i] == ",":
                i += 1
                i = _skip_ws(self.s, i)
        return out, i + 1


def parse_nuxt(html):
    """从页面 HTML 里解析 __NUXT__ 数据，返回 Python 对象（找不到返回 None）。"""
    m = re.search(r"__NUXT__\s*=\s*", html)
    if not m:
        return None
    i = m.end()
    if html[i] != "(":
        # 直接赋 JSON 的情况
        j = html.index("{", i)
        v, k = _Parser(html, {}).parse(j)
        return v
    # (function(params){STMTS; return BODY}(ARGS)) 形式
    m2 = re.match(r"\(function\(([^)]*)\)\{", html[i:])
    if not m2:
        return None
    params = [p.strip() for p in m2.group(1).split(",") if p.strip()]
    body_i = i + m2.end()
    # 函数体结束在 "}(" —— return 之前可能还有 `name[idx]=value;` 这类数组元素赋值
    close = html.rindex("}(", i, len(html))
    body = html[body_i:close]
    rm = re.search(r"\breturn\b", body)
    if rm:
        stmts, ret_expr = body[:rm.start()], body[rm.end():]
    else:
        stmts, ret_expr = "", body
    scope = dict(zip(params, _parse_args(html, close)))
    _exec_stmts(stmts, scope)
    v, _ = _Parser(ret_expr, scope).parse(_skip_ws(ret_expr, 0))
    return v


def _parse_args(html, close):
    args_src = html[close + 2:]
    # 调用收尾是 "...));"，其后紧跟 </script>；按这个边界截断（字符串里出现 )); 的概率极低，
    # 且 NUXT 值全是普通文案，真出现也不会破坏前面已解析出的参数个数对应关系
    end = args_src.find("</script>")
    if end < 0:
        raise ValueError("找不到 NUXT 调用结尾")
    args_src = args_src[:end].rstrip().rstrip(";)").rstrip()
    args, _ = _Parser("[" + args_src + "]", {}).parse(0)
    return args


def _exec_stmts(src, scope):
    """执行 `name[0]=value;name[1]=value;` 形式的数组元素赋值。"""
    i = _skip_ws(src, 0)
    while i < len(src):
        m = re.match(r"([A-Za-z_$][A-Za-z0-9_$]*)\[(-?\d+)\]\s*=\s*", src[i:])
        if not m:
            break
        name, idx = m.group(1), int(m.group(2))
        arr = scope.setdefault(name, [])
        if not isinstance(arr, list):
            break
        val, i = _Parser(src, scope).parse(i + m.end())
        while len(arr) <= idx:
            arr.append(None)
        arr[idx] = val
        i = _skip_ws(src, i)
        if i < len(src) and src[i] == ";":
            i = _skip_ws(src, i + 1)


if __name__ == "__main__":
    import io
    import sys

    html = io.open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    d = parse_nuxt(html)
    if d is None:
        print("no NUXT")
    else:
        print(type(d), list(d.keys())[:8] if isinstance(d, dict) else "")
        print(json.dumps(d, ensure_ascii=False)[:800])
