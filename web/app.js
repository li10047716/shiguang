/* 速读谷桌面阅读器 —— 前端逻辑 */
(() => {
  'use strict';

  const $ = (s, r = document) => r.querySelector(s);
  const view = $('#view');
  const reader = $('#reader');

  const state = { shelf: {}, progress: {}, settings: {}, history: [], home: null, marks: [] };
  const bookCache = new Map();
  const RANK_SEQ = [0];   // 榜单请求序号，防止快速切换标签时旧响应覆盖新内容
  const LIST_SEQ = [0];
  const SEARCH_SEQ = [0];
  const DISC_SEQ = [0];   // 发现页书源切换的请求序号

  const PLACEHOLDER =
    'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 400">' +
      '<rect width="300" height="400" fill="#e9e1d4"/>' +
      '<text x="150" y="205" font-size="20" fill="#b3a893" text-anchor="middle" font-family="sans-serif">暂无封面</text></svg>');

  const img = (u) => (u ? `/api/img?u=${encodeURIComponent(u)}` : PLACEHOLDER);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // 没有封面时用「首字+暖色渐变」生成一张，比灰底占位好看
  function typoHTML(title) {
    const t = (title || '书').trim();
    const ch = t.charAt(0) || '书';
    let h = 0;
    for (const c of t) h = (h * 31 + c.codePointAt(0)) % 360;
    const hue = 18 + (h % 60);
    return `<div class="typo" style="background:linear-gradient(152deg,hsl(${hue} 34% 84%),hsl(${hue} 40% 66%))">${esc(ch)}</div>`;
  }

  window.coverFail = (el) => {
    const box = el.parentNode;
    const ch = (box.dataset.ch || '书');
    let h = 0;
    for (const c of ch) h = (h * 31 + c.codePointAt(0)) % 360;
    const hue = 18 + (h % 60);
    box.innerHTML = `<div class="typo" style="background:linear-gradient(152deg,hsl(${hue} 34% 84%),hsl(${hue} 40% 66%))">${esc(ch)}</div>`;
  };

  const coverBox = (b, extra = '') => {
    const ch = esc(((b.title || '书').trim().charAt(0)) || '书');
    const inner = b.cover
      ? `<img src="${img(b.cover)}" alt="${esc(b.title)}" loading="lazy" decoding="async" onerror="coverFail(this)">`
      : typoHTML(b.title);
    return `<div class="cover" data-ch="${ch}">${inner}${extra}</div>`;
  };

  // 书源显示名与徽章颜色。速读谷作为默认源，列表里不额外标注
  const SRC_META = {
    '速读谷': ['sd', '速读谷'],
    '七猫': ['qm', '七猫'],
    '书旗': ['sq', '书旗'],
    '全本小说网': ['qb', '全本网'],
    '八叉书库': ['bc', '八叉'],
    '八一中文网': ['bl', '八一'],
    '得奇小说网': ['dq', '得奇'],
    '爱丽丝书屋': ['ali', '爱丽丝'],
    '本地导入': ['loc', '本地'],
  };
  const isLocalBook = (id) => String(id || '').startsWith('loc:');
  const srcBadge = (source, always = false) => {
    const meta = SRC_META[source];
    if (!meta) return '';
    if (!always && meta[0] === 'sd') return '';
    return `<span class="src-dot ${meta[0]}">${esc(meta[1])}</span>`;
  };

  // ---------------------------------------------------------------- 液态玻璃组件
  const ICONS = {
    back: '<svg viewBox="0 0 24 24"><path d="M14.5 5.5 8 12l6.5 6.5"/></svg>',
    search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg>',
    dots: '<svg viewBox="0 0 24 24" class="ico-dots"><path d="M12 5.2v.1M12 12v.1M12 18.8v.1" stroke-width="3.6"/></svg>',
    grid: '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="6.5" height="6.5" rx="1.4"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.4"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.4"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.4"/></svg>',
    list: '<svg viewBox="0 0 24 24"><path d="M4 6.5h16M4 12h16M4 17.5h16" stroke-width="2.1"/></svg>',
    refresh: '<svg viewBox="0 0 24 24"><path d="M19 8.4A7.5 7.5 0 1 0 19 15.2"/><path d="M19 4.6v4h-4"/></svg>',
    filter: '<svg viewBox="0 0 24 24"><path d="M5 7h14M8 12h8M11 17h2"/></svg>',
    chev: '<svg viewBox="0 0 24 24"><path d="m7 10 5 5 5-5"/></svg>',
    close: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
    check: '<svg viewBox="0 0 24 24"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>',
  };

  // 轻量弹出菜单：锚定在按钮下方，玻璃质感，点外面自动收起
  let popEl = null;
  let popKey = '';
  function closePop() {
    if (popEl) popEl.remove();
    popEl = null;
    popKey = '';
  }
  function openPop(anchor, items, title, key) {
    closePop();
    const el = document.createElement('div');
    el.className = 'glass-pop';
    el.innerHTML = (title ? `<div class="gp-title">${esc(title)}</div>` : '') +
      items.map((it, i) => it.sep
        ? '<div class="gp-sep"></div>'
        : `<button class="gp-item ${it.on ? 'on' : ''} ${it.danger ? 'danger' : ''}" data-i="${i}">
        <span>${esc(it.label)}</span>${it.on ? ICONS.check : ''}</button>`).join('');
    document.body.appendChild(el);
    const r = anchor.getBoundingClientRect();
    const w = Math.min(236, window.innerWidth - 24);
    el.style.width = w + 'px';
    // 以按钮中心对齐，贴边时自动夹回屏幕内
    const left = r.left + r.width / 2 - w / 2;
    el.style.left = Math.max(12, Math.min(left, window.innerWidth - w - 12)) + 'px';
    el.style.top = Math.min(r.bottom + 8, window.innerHeight - 60) + 'px';
    el.querySelectorAll('.gp-item').forEach((b) => {
      b.addEventListener('click', (ev) => {
        ev.stopPropagation();
        const it = items[Number(b.dataset.i)];
        closePop();
        if (it && it.run) it.run();
      });
    });
    popEl = el;
    popKey = key || '';
  }
  function togglePop(anchor, key, items, title) {
    if (popEl && popKey === key) { closePop(); return; }
    openPop(anchor, items, title, key);
  }
  document.addEventListener('click', (e) => {
    if (!popEl) return;
    const anchor = e.target.closest ? e.target.closest('[data-pop]') : null;
    if (!popEl.contains(e.target) && !anchor) closePop();
  });
  window.addEventListener('hashchange', closePop);

  // 玻璃质感确认框：WKWebView / Edge --app 里原生 confirm 不可靠
  function askConfirm(msg, okLabel, onOk, variant = 'danger') {
    const mask = document.createElement('div');
    mask.className = 'glass-mask';
    mask.innerHTML = `<div class="glass-dialog">
      <div class="gd-msg">${esc(msg)}</div>
      <div class="gd-actions">
        <button class="g-text" data-no>取消</button>
        <button class="g-text ${variant}" data-yes>${esc(okLabel)}</button>
      </div></div>`;
    document.body.appendChild(mask);
    const close = () => mask.remove();
    mask.addEventListener('click', (e) => { if (e.target === mask) close(); });
    mask.querySelector('[data-no]').addEventListener('click', close);
    mask.querySelector('[data-yes]').addEventListener('click', async () => {
      close();
      try { await onOk(); } catch (err) { toast('操作失败：' + (err && err.message || err)); }
    });
  }

  // 玻璃质感输入框：给书打标签用，WKWebView 里原生 prompt 不可靠
  function askInput(title, placeholder, onOk, opts = {}) {
    const mask = document.createElement('div');
    mask.className = 'glass-mask';
    mask.innerHTML = `<div class="glass-dialog input-dialog">
      <div class="gd-msg">${esc(title)}</div>
      <input class="nd-input" maxlength="24" autocomplete="off"
        placeholder="${esc(placeholder || '')}" value="${esc(opts.value || '')}">
      <div class="gd-actions">
        <button class="g-text" data-no>取消</button>
        <button class="g-text ok" data-yes>${esc(opts.okLabel || '确定')}</button>
      </div></div>`;
    document.body.appendChild(mask);
    const input = mask.querySelector('.nd-input');
    const close = () => mask.remove();
    const done = () => {
      const v = input.value.trim();
      close();
      if (v) Promise.resolve(onOk(v)).catch((err) => toast('操作失败：' + (err && err.message || err)));
    };
    mask.addEventListener('click', (e) => { if (e.target === mask) close(); });
    mask.querySelector('[data-no]').addEventListener('click', close);
    mask.querySelector('[data-yes]').addEventListener('click', done);
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); done(); }
      if (e.key === 'Escape') { e.preventDefault(); close(); }
    });
    setTimeout(() => input.focus(), 60);
  }

  // 章节标题常自带「第十九章」，别和「第19章」重复显示
  function chapterLabel(t) {
    return String(t || '').replace(/^第[一二三四五六七八九十百千零〇0-9]+章[\s:：·]*/, '').trim() || String(t || '');
  }

  function relTime(ts) {
    if (!ts) return '';
    const s = Math.max(0, Date.now() / 1000 - ts);
    if (s < 60) return '刚刚';
    if (s < 3600) return Math.floor(s / 60) + '分钟前';
    if (s < 86400) return Math.floor(s / 3600) + '小时前';
    if (s < 2592000) return Math.floor(s / 86400) + '天前';
    return Math.floor(s / 2592000) + '个月前';
  }

  const srcNameById = (id) => {
    const p = String(id).split(':')[0];
    const hit = Object.entries(SRC_META).find(([, v]) => v[0] === p);
    return hit ? hit[0] : '';
  };

  // ---- 自动缓存：加入书架 / 翻页时后台补后续章节，弱网下能连续读 ----
  const PREFETCH_GATE = new Map();
  function startPrefetch(bid, from = 0, count = 8) {
    if (!bid || state.settings.autoPrefetch === false) return;
    const key = String(bid);
    const last = PREFETCH_GATE.has(key) ? PREFETCH_GATE.get(key) : -99;
    if (from > 0 && from - last < 4) return;   // 翻过 4 章再补一次，别每章都发请求
    PREFETCH_GATE.set(key, from);
    post('/api/prefetch', { bookId: key, from, count }).catch(() => {});
  }

  // ---- 书签 / 划线 / 笔记：全部存在本地 state.marks 里 ----
  const marksOf = (bookId) => (state.marks || []).filter((m) => m.bookId === bookId);
  const markOfChapter = (bookId, u, type = 'bookmark') =>
    (state.marks || []).find((m) => m.bookId === bookId && m.u === u && m.type === type);

  async function saveMark(mark) {
    const r = await post('/api/mark', { op: 'add', mark });
    if (r && r.marks) state.marks = r.marks;
    return r;
  }
  async function removeMark(id) {
    const r = await post('/api/mark', { op: 'remove', id });
    if (r && r.marks) state.marks = r.marks;
    return r;
  }

  // ---- 文件选择：导入书籍 / 恢复备份共用（iOS 要求 input 在 DOM 里并同步触发） ----
  function chooseFile(accept) {
    return new Promise((resolve) => {
      const inp = document.createElement('input');
      inp.type = 'file';
      inp.accept = accept;
      inp.style.cssText = 'position:fixed;left:-9999px;width:1px;height:1px;opacity:0';
      document.body.appendChild(inp);
      let done = false;
      const finish = (f) => {
        if (done) return;
        done = true;
        inp.remove();
        resolve(f || null);
      };
      inp.addEventListener('change', () => finish(inp.files && inp.files[0]));
      // 用户点「取消」时不会有 change 事件，靠窗口重新获得焦点兜底
      window.addEventListener('focus', () => setTimeout(() => finish(null), 1200), { once: true });
      setTimeout(() => finish(null), 180000);   // 兜底清理，别把隐藏 input 一直挂在 DOM 上
      inp.click();
    });
  }

  async function importLocalBook() {
    const f = await chooseFile('.txt,.epub,text/plain,application/epub+zip');
    if (!f) return;
    if (f.size > 40 * 1024 * 1024) { toast('文件超过 40MB，请先拆分再导入'); return; }
    busy(true);
    toast('正在解析，稍等…');
    try {
      const buf = await f.arrayBuffer();
      const r = await fetch('/api/local/import?name=' + encodeURIComponent(f.name), {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: buf,
        cache: 'no-store',
      });
      const j = await r.json();
      if (j.error) throw new Error(j.error);
      if (j.shelf) state.shelf = j.shelf;
      toast(`已导入《${j.book.title}》· ${j.book.chapters.length} 章`);
      viewMine();
    } catch (e) {
      toast('导入失败：' + (e && e.message || e));
    } finally {
      busy(false);
    }
  }

  async function exportBackup() {
    busy(true);
    try {
      const d = await api('/api/backup');
      const name = `拾光备份-${new Date().toISOString().slice(0, 10)}.json`;
      const blob = new Blob([JSON.stringify(d)], { type: 'application/json' });
      const file = new File([blob], name, { type: 'application/json' });
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        try {
          await navigator.share({ files: [file], title: '拾光阅读器备份' });
          toast('备份已导出');
          return;
        } catch (err) {
          if (err && err.name === 'AbortError') return;
        }
      }
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 5000);
      toast('备份文件已保存');
    } catch (e) {
      toast('导出失败：' + (e && e.message || e));
    } finally {
      busy(false);
    }
  }

  async function restoreBackup() {
    const f = await chooseFile('.json,application/json');
    if (!f) return;
    let data;
    try {
      data = JSON.parse(await f.text());
    } catch (e) {
      toast('这个文件不是拾光的备份');
      return;
    }
    const src = (data && data.state) || data || {};
    const n = Object.keys(src.shelf || {}).length;
    if (!n && !(src.marks || []).length) { toast('备份里没有可恢复的内容'); return; }
    askConfirm(`导入备份：${n} 本书（书架、进度、书签、设置）。同名的书保留阅读进度较新的那份。`,
      '开始恢复', async () => {
        busy(true);
        try {
          const r = await post('/api/restore', { data, mode: 'merge' });
          Object.assign(state, r.state || {});
          toast('恢复完成');
          render();
        } catch (e) {
          toast('恢复失败：' + (e && e.message || e));
        } finally {
          busy(false);
        }
      }, 'ok');
  }

  // ---- 一键换源：书名 + 作者匹配其它书源，切换后迁移阅读进度 ----
  async function openSourceSwitch(b, inReader) {
    if (!b || !b.id) return;
    if (isLocalBook(b.id)) { toast('本地导入的书不用换源'); return; }
    busy(true);
    let d;
    try {
      d = await api(`/api/sources?title=${encodeURIComponent(b.title || '')}` +
        `&author=${encodeURIComponent(b.author || '')}` +
        `&exclude=${encodeURIComponent(b.source || '')}`);
    } catch (e) {
      toast('查找书源失败：' + e.message);
      busy(false);
      return;
    }
    busy(false);
    const off = new Set(state.settings.disabledSources || []);
    const list = (d.books || []).filter((x) => !off.has(srcCode(x.source)));
    if (!list.length) { toast('没有找到其它可用的书源'); return; }
    const anchor = inReader ? $('#r-more') : $('#b-more');
    if (!anchor) return;
    if (inReader) $('#r-menu').hidden = true;
    openPop(anchor, list.slice(0, 9).map((x) => ({
      label: `换到${SRC_META[x.source]?.[1] || x.source || '其它源'}${x.author ? ' · ' + x.author : ''}`,
      run: () => doSwitchSource(b, x, inReader),
    })), `更换书源（当前：${b.source || srcNameById(b.id) || '未知'}）`, 'switch-src');
  }

  async function doSwitchSource(b, x, inReader) {
    busy(true);
    try {
      const r = await post('/api/switch', { from: b.id, to: x.id });
      state.shelf = r.shelf || state.shelf;
      state.progress[x.id] = r.progress;
      setPrefSrc(x.source || '');
      bookCache.delete(b.id);
      bookCache.delete(x.id);
      startPrefetch(x.id, Math.max(0, (r.index || 0) - 1), 8);
      toast(`已换到${x.source || '新书源'}，进度保留在第 ${(r.index || 0) + 1} 章`);
      if (inReader) {
        closeReader();
        go(`#/read/${encodeURIComponent(x.id)}`);
      } else {
        go(`#/book/${encodeURIComponent(x.id)}`);
      }
    } catch (e) {
      toast('换源失败：' + e.message);
    } finally {
      busy(false);
    }
  }

  // ---------------------------------------------------------------- 网络
  // WKWebView(iOS) 的 fetch 连接被拒 / 复用了后台挂起前的失效连接时，
  // 抛的是 TypeError: Load failed（不是 DOMException AbortError），必须单独识别并重试。
  const NET_ERR = /load failed|failed to fetch|network ?error|network request failed|connection was lost|could not connect|请求失败/i;

  function friendlyNet(e) {
    const m = String((e && (e.message || e)) || '');
    if (NET_ERR.test(m)) return '本地服务连接中断，已重试；若仍失败请重启应用';
    return m || '网络错误';
  }

  async function api(path, opt) {
    const init = Object.assign({}, opt);
    const isSearch = path.indexOf('/api/search') === 0;
    // 8 源并发最长 35 秒，搜索给足余量；其它接口也不再用 25 秒掐断大目录页
    const timeout = isSearch ? 55000 : 35000;
    const tries = (!init.method || init.method === 'GET') ? 2 : 1;

    for (let i = 0; i < tries; i++) {
      const ac = new AbortController();
      let timedOut = false;
      let bizError = false;
      const timer = setTimeout(() => { timedOut = true; ac.abort(); }, timeout);
      try {
        const r = await fetch(path, Object.assign({}, init, {
          signal: ac.signal, cache: 'no-store',
        }));
        const j = await r.json();
        if (j && j.error) { bizError = true; throw new Error(j.error); }
        return j;
      } catch (e) {
        if (bizError) throw e; // 后端业务错误，重试没有意义
        if (timedOut) throw new Error('请求超时，书源响应较慢，点「重新搜索」再试一次');
        const broken = (e instanceof TypeError) || NET_ERR.test(String((e && e.message) || e));
        if (broken && i < tries - 1) {
          await new Promise((res) => setTimeout(res, 350)); // 换一条新连接重试
          continue;
        }
        if (broken) throw new Error(friendlyNet(e));
        throw e;
      } finally {
        clearTimeout(timer);
      }
    }
    throw new Error('本地服务未响应，请重启应用');
  }

  // 从后台回到前台先发一次心跳：丢弃已失效的 keep-alive 连接、唤醒本地服务
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) fetch('/api/ping', { cache: 'no-store' }).catch(() => {});
  });
  const post = (path, body) => api(path, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });

  let loadingCount = 0;
  const busy = (on) => {
    loadingCount += on ? 1 : -1;
    if (loadingCount < 0) loadingCount = 0;
    $('#loading').hidden = loadingCount === 0;
  };

  let toastTimer;
  function toast(msg) {
    const t = $('#toast');
    t.textContent = msg;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, 2200);
  }

  async function loadState() {
    const st = await api('/api/state');
    Object.assign(state, st);
    if (!state.settings || !Object.keys(state.settings).length) state.settings = {};
  }

  const saveSettings = () => post('/api/settings', { settings: state.settings }).catch(() => {});
  const isOnShelf = (id) => !!state.shelf[id];

  // ---------------------------------------------------------------- 外观：浅色 / 深色 / 跟随系统
  // 解析结果写到 <html data-theme>，index.html 头部还有一段极小的内联脚本先读 localStorage，
  // 这样冷启动不会先闪一下白底。
  const THEME_KEY = 'sg.theme';
  const mediaDark = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  const themePref = () => state.settings.appTheme || 'auto';
  function resolveTheme() {
    const t = themePref();
    if (t === 'light' || t === 'dark') return t;
    return mediaDark && mediaDark.matches ? 'dark' : 'light';
  }
  function applyTheme() {
    const t = resolveTheme();
    document.documentElement.dataset.theme = t;
    try { localStorage.setItem(THEME_KEY, t); } catch (_) { /* 隐私模式忽略 */ }
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', t === 'dark' ? '#0d1219' : '#eef2f9');
    document.querySelectorAll('[data-theme-opt]').forEach((b) => {
      b.classList.toggle('on', (b.dataset.themeOpt || 'auto') === themePref());
    });
  }
  function setAppTheme(v) {
    state.settings.appTheme = v;
    saveSettings();
    applyTheme();
  }
  if (mediaDark) {
    const onSysChange = () => { if (themePref() === 'auto') applyTheme(); };
    if (mediaDark.addEventListener) mediaDark.addEventListener('change', onSysChange);
    else if (mediaDark.addListener) mediaDark.addListener(onSysChange);
  }

  async function addShelf(book) {
    const payload = {
      id: book.id, title: book.title, cover: book.cover,
      author: book.author || '', category: book.category || '', status: book.status || '',
    };
    const r = await post('/api/shelf', { op: 'add', book: payload });
    state.shelf = r.shelf;
    startPrefetch(book.id, 0, 5);   // 加入书架就开始缓存前几章
  }

  async function removeShelf(id) {
    const r = await post('/api/shelf', { op: 'remove', book: { id } });
    state.shelf = r.shelf;
  }

  // ---------------------------------------------------------------- 路由
  function parseHash() {
    const h = location.hash.replace(/^#\/?/, '');
    const [path, query] = h.split('?');
    const parts = path.split('/').filter(Boolean);
    return { parts, q: new URLSearchParams(query || '') };
  }

  function go(hash) {
    if (location.hash === hash) render();
    else location.hash = hash;
  }

  function setNav(name) {
    document.querySelectorAll('.nav a').forEach((a) => {
      a.classList.toggle('on', a.dataset.nav === name);
    });
  }

  // ---------------------------------------------------------------- 组件
  const bookCard = (b, extra = '') => `
    <a class="card" href="#/book/${b.id}">
      ${coverBox(b, extra)}
      <div class="t">${esc(b.title)}</div>
      <div class="s">${esc(b.author || b.category || '')}</div>
    </a>`;

  // ---- 书架分组 / 标签：显式 group 优先，没有就按阅读进度推断 ----
  const GROUPS = [['reading', '在读'], ['todo', '想读'], ['done', '已读完']];
  const groupName = (k) => (GROUPS.find(([x]) => x === k) || ['reading', '在读'])[1];
  function bookGroup(b) {
    const g = b && b.group;
    if (g && GROUPS.some(([k]) => k === g)) return g;
    const p = (b && b.progress) || {};
    const i = Number(p.i);
    if (Number.isFinite(i) && i > 0) {
      if (b.count && i >= b.count - 1) return 'done';
      return 'reading';
    }
    return 'todo';
  }
  const bookTags = (b) => (b && Array.isArray(b.tags) ? b.tags.filter(Boolean) : []);

  function matchScope(b, scope) {
    if (!scope || scope === 'all') return true;
    if (scope.indexOf('g:') === 0) return bookGroup(b) === scope.slice(2);
    if (scope.indexOf('t:') === 0) return bookTags(b).indexOf(scope.slice(2)) >= 0;
    return (b.source || srcNameById(b.id)) === scope;
  }
  function scopeLabel(scope) {
    if (!scope || scope === 'all') return '全部';
    if (scope.indexOf('g:') === 0) return groupName(scope.slice(2));
    if (scope.indexOf('t:') === 0) return '#' + scope.slice(2);
    return scope;
  }
  // 书架内搜索：书名 / 作者 / 标签 / 来源，忽略大小写与标点
  function matchShelfQuery(b, kw) {
    const k = normKey(kw);
    if (!k) return true;
    return normKey(b.title).indexOf(k) >= 0 || normKey(b.author).indexOf(k) >= 0
      || normKey(b.source || srcNameById(b.id)).indexOf(k) >= 0
      || bookTags(b).some((t) => normKey(t).indexOf(k) >= 0);
  }

  const shelfCard = (b, mg = false, sel = false) => {
    const p = b.progress || {};
    const pct = Math.max(0, Math.min(100, Math.round((p.ratio || 0) * 100)));
    const g = bookGroup(b);
    const extra = `<span class="cv-tag g-${g}">${groupName(g)}</span>` +
      `${p.i ? `<div class="prog"><i style="width:${pct}%"></i></div>` : ''}`;
    const sub = p.t ? `读到 ${esc(p.t)}` : '尚未开始';
    const meta = `${b.count ? `${b.count} 章 · ` : ''}${esc(b.source || '')}书源`;
    const tag = mg ? 'div' : 'a';
    const attrs = mg ? `data-pick="${esc(b.id)}"` : `href="#/read/${b.id}"`;
    // 追更检查出新增章节时，在封面右上角标一个 +N（和列表卡的未读角标同一套样式）
    const upd = b.newCh ? `<span class="unread hot upd">+${b.newCh > 99 ? '99+' : b.newCh}</span>` : '';
    return `
      <${tag} class="card ${mg ? 'manage' : ''} ${sel ? 'picked' : ''}" ${attrs} data-sid="${esc(b.id)}">
        ${coverBox(b, extra)}
        ${upd}
        <div class="t">${esc(b.title)}</div>
        <div class="s">${sub}</div>
        <div class="m">${meta}</div>
        <div class="cache-line" data-cache="${esc(b.id)}"></div>
        ${mg ? pickBox(sel) : ''}
      </${tag}>`;
  };

  // 管理模式的选择圈：只在点「管理书架」后出现，固定在卡片右下角（99+ 角标下方）
  const pickBox = (sel) => `<span class="pick ${sel ? 'on' : ''}">${sel ? ICONS.check : ''}</span>`;

  // 图 1 的横向列表排列：封面 + 作者/章节 + 已读 + 来源 + 最近阅读 + 未读角标
  function shelfListCard(b, mg = false, sel = false) {
    const p = b.progress || {};
    const readI = Number.isFinite(p.i) ? p.i + 1 : 0;
    const unread = b.count ? Math.max(0, b.count - readI) : 0;
    const badge = unread
      ? `<span class="unread ${unread >= 20 || b.newCh ? 'hot' : ''}">${unread > 99 ? '99+' : unread}</span>` : '';
    const src = b.source || srcNameById(b.id) || '速读谷';
    const ago = relTime(b.lastRead);
    const g = bookGroup(b);
    const tags = bookTags(b);
    const extra = `<span class="cv-tag g-${g}">${groupName(g)}</span>`;
    const tag = mg ? 'div' : 'a';
    const attrs = mg ? `data-pick="${esc(b.id)}"` : `href="#/read/${b.id}"`;
    // 最后一行的位置本来常驻一句「暂无更新」，正好拿来显示检查到的更新，不再多占地方
    const last = b.newCh
      ? `更新 +${b.newCh} 章${b.updAt ? ' · ' + esc(relTime(b.updAt)) : ''}`
      : (p.t ? `第${readI}章 ${esc(chapterLabel(p.t))}` : '暂无更新');
    return `<${tag} class="sl-card ${mg ? 'manage' : ''} ${sel ? 'picked' : ''}" ${attrs} data-sid="${esc(b.id)}">
      ${coverBox(b, extra)}
      <div class="sl-body">
        <div class="sl-title">${esc(b.title)}</div>
        <div class="sl-line">${esc(b.author || '佚名')} · 共${b.count ? b.count + '章' : '—章'}</div>
        <div class="sl-line">${p.t ? `已读：第${readI}章 ${esc(chapterLabel(p.t))}` : '尚未开始阅读'}</div>
        <div class="sl-line">来源：${esc(src)}</div>
        <div class="sl-line sl-last ${b.newCh ? 'has-upd' : ''}">${ago && !b.newCh ? esc(ago) + ' · ' : ''}${last}</div>
        ${tags.length ? `<div class="sl-tags">${tags.slice(0, 4).map((t) => `<span class="sl-tag">#${esc(t)}</span>`).join('')}</div>` : ''}
        <div class="cache-line" data-cache="${esc(b.id)}"></div>
      </div>
      ${badge}
      ${mg ? pickBox(sel) : ''}
    </${tag}>`;
  }

  // 书架工具条偏好持久化到服务端 state.settings
  function shelfPref(k, fallback) { return state.settings[k] || fallback; }
  function setShelfPref(k, v) {
    state.settings[k] = v;
    saveSettings();
    viewShelf();
  }

  // 书架卡上的「已缓存到第 X 章」：只读本地磁盘，5 秒内复用结果
  let cacheInfo = null, cacheInfoAt = 0;
  function fillCacheLines() {
    if (!view.querySelector('[data-cache]')) return;
    const paint = () => {
      const c = (cacheInfo || {}).cache || {};
      view.querySelectorAll('[data-cache]').forEach((el) => {
        const x = c[el.dataset.cache];
        if (!x || !x.total) return;
        el.textContent = x.upto ? `已缓存到第 ${x.upto} 章` : `已缓存 ${x.cached}/${x.total} 章`;
      });
    };
    if (cacheInfo && Date.now() - cacheInfoAt < 5000) { paint(); return; }
    api('/api/cache').then((d) => { cacheInfo = d; cacheInfoAt = Date.now(); paint(); })
      .catch(() => {});
  }

  // 书架检查更新：后台线程拉目录，前端轮询；有新增就在卡片上留 +N 章，打开这本书后清掉
  let updPoll = null;
  function setPullTip(h, text) {
    const el = $('#pull-tip');
    if (!el) return;
    el.style.height = h ? h + 'px' : '0px';
    el.classList.toggle('on', !!h);
    const s = el.querySelector('span');
    if (s && text) s.textContent = text;
  }
  async function loadUpdates(refresh = false, notify = false) {
    clearTimeout(updPoll);
    if (notify) setPullTip(44, '正在检查更新…');
    try {
      const d = await api(`/api/updates${refresh ? '?refresh=1' : ''}`);
      if (d.shelf) state.shelf = d.shelf;
      if (d.checking) {
        updPoll = setTimeout(() => loadUpdates(false, notify), 1000);
        return;
      }
      const books = Object.values(state.shelf).filter((b) => b.newCh);
      const failed = Object.values(d.items || {}).filter((r) => !r.ok).length;
      if (notify) {
        toast(books.length ? `${books.length} 本书有更新`
          : (failed ? `已检查，${failed} 本读取失败` : '已是最新，没有新章节'));
      } else if (books.length && !location.hash.startsWith('#/shelf')) {
        // 启动检查是静默的，人不在书架页时说一声，否则只靠书架副标题提示
        toast(`${books.length} 本书有更新`);
      }
      setPullTip(0);
      if (location.hash.startsWith('#/shelf')) {
        const top = view.scrollTop;
        viewShelf();
        view.scrollTop = top;
      }
    } catch (e) {
      setPullTip(0);
      if (notify) toast('检查更新失败：' + e.message);
    }
  }

  // 下拉刷新：书架页顶部下拉一格就检查更新（手机上最顺手的入口）
  let pullStartY = 0, pullH = 0, pulling = false;
  view.addEventListener('touchstart', (e) => {
    pulling = false;
    if (!location.hash.startsWith('#/shelf') || !reader.hidden || shelfManage) return;
    if (view.scrollTop > 2 || e.touches.length !== 1) return;
    pullStartY = e.touches[0].clientY;
    pullH = 0;
    pulling = true;
  }, { passive: true });
  view.addEventListener('touchmove', (e) => {
    if (!pulling) return;
    const dy = e.touches[0].clientY - pullStartY;
    if (dy <= 3) { pullH = 0; setPullTip(0); return; }
    pullH = Math.min(76, dy * 0.5);
    setPullTip(pullH, dy > 62 ? '松手检查更新' : '下拉检查更新');
  }, { passive: true });
  view.addEventListener('touchend', () => {
    if (!pulling) return;
    pulling = false;
    if (pullH >= 34) { pullH = 0; loadUpdates(true, true); } else { pullH = 0; setPullTip(0); }
  }, { passive: true });


  let shelfManage = false;
  const shelfPicked = new Set();
  function exitShelfManage() {
    shelfManage = false;
    shelfPicked.clear();
  }

  const pager = (page, pages, cb) => {
    if (pages <= 1) return '';
    const nums = [];
    const add = (n) => { if (!nums.includes(n) && n >= 1 && n <= pages) nums.push(n); };
    add(1); add(page - 1); add(page); add(page + 1); add(pages);
    nums.sort((a, b) => a - b);
    let html = '<div class="pager">';
    html += `<button data-p="${page - 1}" ${page <= 1 ? 'disabled' : ''}>上一页</button>`;
    let last = 0;
    for (const n of nums) {
      if (last && n - last > 1) html += '<span class="info">…</span>';
      html += `<button class="${n === page ? 'now' : ''}" data-p="${n}">${n}</button>`;
      last = n;
    }
    html += `<button data-p="${page + 1}" ${page >= pages ? 'disabled' : ''}>下一页</button>`;
    html += `<span class="info">${page} / ${pages}</span></div>`;
    return html;
  };

  function wirePager(root, cb) {
    root.querySelectorAll('.pager button[data-p]').forEach((b) => {
      b.addEventListener('click', () => {
        const p = Number(b.dataset.p);
        if (p >= 1) cb(p);
      });
    });
  }

  // ---------------------------------------------------------------- 视图：书架
  // 书架内搜索：临时筛选，不落盘；只在改搜索词时原地显示/隐藏卡片，避免输入框丢焦点
  let shelfSearch = '';
  let shelfSearchOn = false;
  let focusShelfSearch = false;

  function applyShelfQuery() {
    let n = 0;
    view.querySelectorAll('[data-sid]').forEach((el) => {
      const b = state.shelf[el.dataset.sid];
      const ok = !b || matchShelfQuery(b, shelfSearch);
      el.hidden = !ok;
      if (ok) n += 1;
    });
    const sub = $('#shelf-sub');
    if (sub) sub.textContent = shelfSearch ? `在书架里找到 ${n} 本` : (sub.dataset.base || '');
    const none = $('#shelf-none');
    if (none) none.hidden = n > 0;
  }

  // 批量改分组 / 标签：一次一本书交给后端 meta 接口，返回最新书架
  async function setShelfMeta(ids, patch) {
    let shelf = state.shelf;
    for (const id of ids) {
      const r = await post('/api/shelf', { op: 'meta', book: Object.assign({ id }, patch) });
      if (r && r.shelf) shelf = r.shelf;
    }
    state.shelf = shelf;
  }

  function closeShelfSearch() {
    shelfSearch = '';
    shelfSearchOn = false;
    viewShelf();
  }

  function viewShelf() {
    setNav('shelf');
    const mobile = window.matchMedia('(max-width: 640px)').matches;
    const layout = shelfPref('shelfLayout', mobile ? 'list' : 'grid');
    const sort = shelfPref('shelfSort', 'recent');
    const all = Object.values(state.shelf);
    if (shelfManage && !all.length) exitShelfManage();
    // 旧版本存的是书源名：源被停用/改名后回落到「全部」，别让书架看着是空的
    const saved = shelfPref('shelfFilter', 'all');
    const scope = (saved === 'all' || String(saved).indexOf('g:') === 0 || String(saved).indexOf('t:') === 0
      || all.some((b) => (b.source || srcNameById(b.id)) === saved)) ? saved : 'all';
    let books = all.filter((b) => matchScope(b, scope));
    books.sort((a, b) => {
      if (sort === 'title') return String(a.title || '').localeCompare(String(b.title || ''), 'zh');
      if (sort === 'added') return (b.added || 0) - (a.added || 0);
      return (b.lastRead || 0) - (a.lastRead || 0);
    });
    const sources = [...new Set(all.map((b) => b.source || srcNameById(b.id)).filter(Boolean))];
    const tags = [...new Set(all.flatMap(bookTags))].sort((a, b) => a.localeCompare(b, 'zh'));
    const countGroup = (g) => all.filter((b) => bookGroup(b) === g).length;
    const body = books.length
      ? layout === 'list'
        ? `<div class="shelf-list">${books.map((b) => shelfListCard(b, shelfManage, shelfPicked.has(b.id))).join('')}</div>`
        : `<div class="grid">${books.map((b) => shelfCard(b, shelfManage, shelfPicked.has(b.id))).join('')}</div>`
      : all.length
        ? `<div class="empty"><div class="ic">🗂</div>
             <p>「${esc(scopeLabel(scope))}」下还没有书</p>
             <button class="btn ghost" id="scope-reset">看全部</button></div>`
        : `<div class="empty"><div class="ic">📚</div>
           <p>书架还是空的<br>去「发现」找一本喜欢的书吧</p>
           <a class="btn" href="#/discover">去逛逛</a></div>`;

    // 管理条：只统计当前筛选下可见的书，避免误删被筛掉的条目
    const pickedIds = shelfManage ? books.filter((b) => shelfPicked.has(b.id)).map((b) => b.id) : [];
    const pickedN = pickedIds.length;
    const manageBar = shelfManage ? `<div class="manage-bar">
      <span class="mb-count">已选 <b>${pickedN}</b> 本</span>
      <div class="mb-actions">
        <button class="g-text sm" id="mg-all">${books.length && pickedN === books.length ? '取消全选' : '全选'}</button>
        <button class="g-text sm" id="mg-group" data-pop ${pickedN ? '' : 'disabled'}>归类</button>
        <button class="g-text sm danger" id="mg-del" ${pickedN ? '' : 'disabled'}>删除</button>
        <button class="g-text sm" id="mg-done">完成</button>
      </div></div>` : '';

    const updN = all.filter((b) => b.newCh).length;
    // 有更新时副标题只留「共 N 本 · M 本有更新」，手机上才不会折成两行
    const baseSub = books.length
      ? (updN ? `共 ${books.length} 本 · ${updN} 本有更新` : `共 ${books.length} 本 · 阅读进度自动保存`)
      : all.length ? `共 ${all.length} 本 · 这一组还没有书` : '收藏的书会出现在这里';

    view.innerHTML = `
      <div class="page">
        <div class="pull-tip" id="pull-tip"><span></span></div>
        <div class="page-head glass-head">
          <div>
            <h1 class="h1">书架</h1>
            <div class="sub" id="shelf-sub" data-base="${esc(baseSub)}">${esc(baseSub)}</div>
          </div>
          <div class="glass-pill shelf-tools">
            <button class="g-text" id="shelf-filter" data-pop title="筛选与分组"><span>${esc(scopeLabel(scope))}</span>${ICONS.chev}</button>
            <i class="g-sep"></i>
            <button class="g-ico" id="shelf-layout" title="${layout === 'list' ? '切换为网格' : '切换为列表'}">${layout === 'list' ? ICONS.grid : ICONS.list}</button>
            <a class="g-ico" href="#/search" title="搜索书源" aria-label="搜索书源">${ICONS.search}</a>
            <button class="g-ico" id="shelf-more" data-pop title="书架选项">${ICONS.dots}</button>
          </div>
        </div>
        ${shelfSearchOn ? `<div class="glass-search shelf-search">
          ${ICONS.search}
          <input id="sh-q" placeholder="搜索书架：书名 / 作者 / 标签" value="${esc(shelfSearch)}"
            autocomplete="off" enterkeyhint="search">
          <button class="s-clear" id="sh-close" title="关闭">${ICONS.close}</button>
        </div>` : ''}
        ${manageBar}
        <div id="shelf-none" class="empty" hidden><div class="ic">🔍</div><p>没有匹配的书</p></div>
        ${body}
      </div>`;

    $('#shelf-layout').addEventListener('click', () => {
      setShelfPref('shelfLayout', layout === 'list' ? 'grid' : 'list');
    });
    $('#scope-reset')?.addEventListener('click', () => setShelfPref('shelfFilter', 'all'));

    // 筛选菜单：分组 → 标签 → 书源，一个菜单装下三种范围
    $('#shelf-filter').addEventListener('click', (e) => {
      e.stopPropagation();
      const pick = (v) => { shelfPicked.clear(); setShelfPref('shelfFilter', v); };
      const items = [
        { label: `全部（${all.length}）`, on: scope === 'all', run: () => pick('all') },
        { sep: true },
        ...GROUPS.map(([k, n]) => ({ label: `${n}（${countGroup(k)}）`, on: scope === 'g:' + k,
          run: () => pick('g:' + k) })),
      ];
      if (tags.length) {
        items.push({ sep: true },
          ...tags.map((t) => ({ label: '#' + t, on: scope === 't:' + t, run: () => pick('t:' + t) })));
      }
      if (sources.length > 1) {
        items.push({ sep: true },
          ...sources.map((s) => ({ label: s, on: scope === s, run: () => pick(s) })));
      }
      togglePop(e.currentTarget, 'shelf-filter', items, '筛选 / 分组 / 标签');
    });

    $('#shelf-more').addEventListener('click', (e) => {
      e.stopPropagation();
      togglePop(e.currentTarget, 'shelf-more', [
        { label: '最近阅读', on: sort === 'recent', run: () => setShelfPref('shelfSort', 'recent') },
        { label: '按书名', on: sort === 'title', run: () => setShelfPref('shelfSort', 'title') },
        { label: '加入时间', on: sort === 'added', run: () => setShelfPref('shelfSort', 'added') },
        { sep: true },
        { label: shelfSearchOn ? '退出书架搜索' : '搜索书架', run: () => {
          if (shelfSearchOn) { closeShelfSearch(); return; }
          shelfSearchOn = true;
          focusShelfSearch = true;
          viewShelf();
        } },
        { label: '检查更新', run: () => loadUpdates(true, true) },
        { label: '后台预取章节', on: state.settings.autoPrefetch !== false, run: () => {
          state.settings.autoPrefetch = state.settings.autoPrefetch === false;
          saveSettings();
          toast(state.settings.autoPrefetch ? '已开启后台预取' : '已关闭后台预取');
        } },
        { sep: true },
        { label: shelfManage ? '退出管理' : '管理书架', run: () => {
          if (shelfManage) exitShelfManage();
          else { shelfManage = true; shelfPicked.clear(); }
          viewShelf();
        } },
      ], '书架选项');
    });

    // 搜索框：输入时原地过滤，不重渲染（否则手机上键盘会收起来）
    const q = $('#sh-q');
    if (q) {
      q.addEventListener('input', () => { shelfSearch = q.value; applyShelfQuery(); });
      q.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeShelfSearch(); }
      });
      $('#sh-close').addEventListener('click', closeShelfSearch);
      if (focusShelfSearch) {
        focusShelfSearch = false;
        setTimeout(() => { q.focus(); q.setSelectionRange(q.value.length, q.value.length); }, 60);
      }
    }
    if (shelfSearch) applyShelfQuery();

    if (shelfManage) {
      view.querySelectorAll('[data-pick]').forEach((el) => {
        el.addEventListener('click', () => {
          const id = el.dataset.pick;
          if (shelfPicked.has(id)) shelfPicked.delete(id); else shelfPicked.add(id);
          viewShelf();
        });
      });
      $('#mg-all').addEventListener('click', () => {
        const visible = books.filter((b) => matchShelfQuery(b, shelfSearch));
        if (visible.length && visible.every((b) => shelfPicked.has(b.id))) shelfPicked.clear();
        else visible.forEach((b) => shelfPicked.add(b.id));
        viewShelf();
      });
      $('#mg-group').addEventListener('click', (e) => {
        e.stopPropagation();
        if (!pickedN) return;
        const hasTags = pickedIds.some((id) => bookTags(state.shelf[id]).length);
        const items = [
          ...GROUPS.map(([k, n]) => ({ label: `归到「${n}」`,
            on: pickedIds.every((id) => bookGroup(state.shelf[id]) === k),
            run: () => bulkShelfMeta(pickedIds, { group: k }, `已归到「${n}」`) })),
          { sep: true },
          { label: '添加标签…', run: () => addTagsTo(pickedIds) },
        ];
        if (hasTags) {
          items.push({ label: '清除标签', danger: true,
            run: () => bulkShelfMeta(pickedIds, { tags: [] }, '标签已清除') });
        }
        togglePop(e.currentTarget, 'mg-group', items, `归类 ${pickedN} 本`);
      });
      $('#mg-del').addEventListener('click', () => {
        if (!pickedN) return;
        askConfirm(
          `确定从书架移出这 ${pickedN} 本书吗？阅读进度会保留，以后可以重新加入。`,
          `删除 ${pickedN} 本`,
          async () => {
            for (const id of pickedIds) await removeShelf(id);
            shelfPicked.clear();
            if (!Object.keys(state.shelf).length) exitShelfManage();
            toast(`已移出 ${pickedN} 本书`);
            render();
          });
      });
      $('#mg-done').addEventListener('click', () => { exitShelfManage(); viewShelf(); });
    }

    fillCacheLines();

    // 老条目没有章节数：借服务端的目录缓存补一次，补完刷新
    const missing = all.filter((b) => !b.count);
    if (missing.length) {
      (async () => {
        for (const b of missing) {
          try {
            const d = await api('/api/book?id=' + encodeURIComponent(b.id));
            if (d.count) {
              const r = await post('/api/shelf', { op: 'add',
                book: { id: b.id, count: d.count, source: d.source || b.source || '' } });
              state.shelf = r.shelf || state.shelf;
            }
          } catch (err) { /* 单本失败不拖累其他 */ }
        }
        if (missing.every((b) => state.shelf[b.id]?.count)) render();
      })();
    }
  }

  async function bulkShelfMeta(ids, patch, msg) {
    busy(true);
    try {
      await setShelfMeta(ids, patch);
      if (msg) toast(msg);
      viewShelf();
    } catch (e) {
      toast('操作失败：' + (e && e.message || e));
    } finally {
      busy(false);
    }
  }

  function addTagsTo(ids) {
    askInput(`给 ${ids.length} 本书加标签`, '空格或逗号分隔，如：仙侠 爽文', async (v) => {
      const add = String(v).split(/[\s,，、;；]+/).map((s) => s.trim().slice(0, 12)).filter(Boolean);
      if (!add.length) return;
      for (const id of ids) {
        const tags = [...new Set([...bookTags(state.shelf[id]), ...add])].slice(0, 8);
        await setShelfMeta([id], { tags });
      }
      toast('标签已添加');
      viewShelf();
    });
  }

  // ---------------------------------------------------------------- 视图：发现
  const DISC_SRC = [['sd', '速读谷'], ['qm', '七猫'], ['sq', '书旗'], ['qb', '全本网'], ['bc', '八叉'], ['bl', '八一'], ['dq', '得奇'], ['ali', '爱丽丝']];
  const SD_DISC_CATS = [['1', '玄幻'], ['2', '仙侠'], ['3', '都市'], ['4', '历史'],
    ['5', '军事'], ['6', '科幻'], ['7', '言情']];
  const QM_DISC_CATS = [['203', '都市'], ['219', '都市高武'], ['202', '玄幻奇幻'],
    ['205', '武侠仙侠'], ['204', '奇闻异事'], ['56', '历史'], ['75', '游戏'], ['64', '科幻']];
  const SQ_DISC_CATS = [['7', '都市'], ['29', '玄幻'], ['34,102', '科幻'], ['41,108', '悬疑'],
    ['45', '历史'], ['58', '武侠'], ['67,98', '仙侠'], ['76', '现代言情'],
    ['86', '古代言情'], ['', '全部书库']];
  const QB_DISC_CATS = [['1', '玄幻'], ['2', '修真'], ['3', '都市'], ['4', '历史'],
    ['5', '网游'], ['6', '科幻'], ['7', '其他'], ['all', '完结']];
  const BC_DISC_CATS = [['1', '长篇'], ['2', '综合'], ['3', '武侠'], ['4', '历史'],
    ['5', '都市'], ['6', '玄幻'], ['7', '女生'], ['8', '其他'], ['9', '现代']];
  const BL_DISC_CATS = [['1', '玄幻'], ['2', '修真'], ['3', '都市'], ['4', '穿越'],
    ['5', '网游'], ['6', '科幻'], ['7', '其他']];
  const DQ_DISC_CATS = [['1', '玄幻'], ['2', '都市'], ['3', '仙侠'], ['4', '历史'],
    ['5', '科幻'], ['6', '诸天无限'], ['7', '悬疑'], ['8', '体育'], ['9', '游戏'], ['10', '综合']];
  // 爱丽丝书屋的 29 个标签分类，顺序照站点导航
  const ALI_DISC_CATS = [['71', '科幻'], ['79', '经典'], ['75', '奇幻'], ['69', '系统'],
    ['68', '武侠'], ['65', '乱伦'], ['64', '都市'], ['63', '乡村'], ['73', '同人'],
    ['62', '玄幻'], ['61', '校园'], ['70', '穿越'], ['22', '反差'], ['46', '凌辱'],
    ['18', '堕落'], ['19', '纯爱'], ['52', '伪娘'], ['48', '萝莉'], ['56', '熟女'],
    ['50', '正太'], ['72', '明星'], ['54', 'NTR'], ['53', '媚黑'], ['58', '调教'],
    ['59', '言情'], ['47', '百合'], ['82', '耽美'], ['21', '重口'], ['57', '其他']];
  const ALI_RANK_TABS = [['hits_day', '日榜'], ['hits_week', '周榜'],
    ['hits_month', '月榜'], ['hits', '总榜']];

  const DISC_CATS = {
    sd: SD_DISC_CATS, qm: QM_DISC_CATS, sq: SQ_DISC_CATS, qb: QB_DISC_CATS,
    bc: BC_DISC_CATS, bl: BL_DISC_CATS, dq: DQ_DISC_CATS, ali: ALI_DISC_CATS,
  };
  // 排行榜已合并进发现页：三个快捷 chip 对应各源排行榜 API 的 kind
  const DISC_RANKS = {
    sd: ['top', 'quanben', 'lastupdate'],
    qm: ['hot', 'over', 'new'],
    sq: ['boyClick', 'allEnd', 'boyStore'],
    qb: ['all', 'goodnum', 'allvisit'],
    bc: ['popular', 'completed', 'latest'],
    bl: ['vote', 'goodnum', 'newbook'],
    dq: ['allvisit', 'full', 'newhot'],
    ali: ['hits_day', 'hits_month', 'hits_week'],
  };
  const RANK_API = {
    sd: (k, p) => `/api/ranking?kind=${k}&p=${p}`,
    qm: (k, p) => `/api/qm/ranking?kind=${k}&p=${p}`,
    sq: (k, p) => `/api/sq/ranking?kind=${k}&p=${p}`,
    qb: (k, p) => `/api/qb/ranking?kind=${k}&p=${p}`,
    bc: (k, p) => `/api/bc/ranking?kind=${k}&p=${p}`,
    bl: (k) => `/api/bl/ranking?kind=${k}`,
    dq: (k, p) => `/api/dq/ranking?kind=${k}&p=${p}`,
    ali: (k) => `/api/ali/ranking?kind=${k}`,
  };
  const CAT_API = {
    sd: (c, p) => `/api/category?c=${encodeURIComponent(c)}&p=${p}`,
    qm: (c, p) => `/api/qm/category?c=${encodeURIComponent(c)}&p=${p}`,
    sq: (c, p) => `/api/sq/store?fc=${encodeURIComponent(c)}&p=${p}`,
    qb: (c, p) => `/api/qb/sort?c=${encodeURIComponent(c)}&p=${p}`,
    bc: (c, p) => `/api/bc/sort?c=${encodeURIComponent(c)}&p=${p}`,
    bl: (c, p) => `/api/bl/sort?c=${encodeURIComponent(c)}&p=${p}`,
    dq: (c, p) => `/api/dq/sort?c=${encodeURIComponent(c)}&p=${p}`,
    ali: (c, p) => `/api/ali/sort?c=${encodeURIComponent(c)}&p=${p}`,
  };

  function discHash(src, o) {
    const u = new URLSearchParams();
    u.set('src', src);
    if (o.cat != null) u.set('cat', o.cat);
    else if (o.rank) u.set('rank', o.rank);
    if (o.p && String(o.p) !== '1') u.set('p', o.p);
    if (o.fresh) u.set('_', String(Date.now()));
    return '#/discover?' + u.toString();
  }

  function discItem(b, src) {
    const label = (DISC_SRC.find(([k]) => k === src) || ['', '速读谷'])[1];
    const meta = [b.category, b.words].filter(Boolean).join(' ');
    const tag = b.status && /完结|完本/.test(b.status) ? '<span class="cv-tag done">已有</span>' : '';
    return `<a class="disc-card" href="#/book/${encodeURIComponent(b.id)}">
      ${coverBox(b, tag)}
      <div class="dc-body">
        <div class="dc-title">${esc(b.title)}</div>
        <div class="dc-author">${esc(b.author || '佚名')}</div>
        <div class="dc-line">来源：${esc(b.source || label)}</div>
        <div class="dc-line">${esc(meta || '网络小说')}</div>
        <div class="dc-latest">最新：${esc(b.latest || b.status || '—')}</div>
      </div>
    </a>`;
  }

  async function viewDiscover(q) {
    setNav('discover');
    const src = DISC_SRC.some(([k]) => k === q.get('src')) ? q.get('src') : 'sd';
    const cats = DISC_CATS[src];
    const ranks = DISC_RANKS[src];
    const mode = q.has('cat') ? 'cat' : 'rank';
    const cat = q.has('cat') ? q.get('cat') : cats[0][0];
    const catName = (cats.find(([id]) => String(id) === String(cat)) || cats[0])[1];
    const rank = ranks.includes(q.get('rank')) ? q.get('rank') : ranks[0];
    const p = q.get('p') || '1';
    const srcLabel = (DISC_SRC.find(([k]) => k === src) || ['', '速读谷'])[1];
    const rankLabels = [`${catName}排行榜`, `完本${catName}小说`, `最新${catName}小说`];

    view.innerHTML = `<div class="page disc-page">
      <div class="glass-topbar">
        <a class="g-circle" href="#/search" title="搜索">${ICONS.search}</a>
        <button class="g-src" id="disc-src" data-pop>${esc(srcLabel)}${ICONS.chev}</button>
        <button class="g-circle" id="disc-refresh" title="刷新">${ICONS.refresh}</button>
      </div>
      <div class="cat-row">
        <div class="cat-scroll">${cats.map(([id, n]) =>
          `<button class="chip ${String(id) === String(cat) ? 'on' : ''}" data-cat="${esc(id)}">${esc(n)}</button>`).join('')}</div>
        <button class="g-ico cat-all" id="disc-cats" title="全部分类">${ICONS.filter}</button>
      </div>
      <div class="cats-panel" id="cats-panel" hidden>${cats.map(([id, n]) =>
        `<button class="chip ${String(id) === String(cat) ? 'on' : ''}" data-cat="${esc(id)}">${esc(n)}</button>`).join('')}</div>
      <div class="rank-row">${ranks.map((k, i) =>
        `<button class="chip rchip ${mode === 'rank' && k === rank ? 'on' : ''}" data-rank="${k}">${esc(rankLabels[i])}</button>`).join('')}</div>
      <div id="disc-list" class="disc-list">
        ${Array(4).fill('<div class="disc-skel"><div class="skel sk-cover"></div><div class="sk-lines"><i class="skel"></i><i class="skel"></i><i class="skel"></i><i class="skel"></i></div></div>').join('')}
      </div>
    </div>`;

    view.querySelectorAll('[data-rank]').forEach((b) => b.addEventListener('click', () =>
      go(discHash(src, { rank: b.dataset.rank }))));
    view.querySelectorAll('[data-cat]').forEach((b) => b.addEventListener('click', () =>
      go(discHash(src, { cat: b.dataset.cat }))));
    $('#disc-cats').addEventListener('click', () => {
      const panel = $('#cats-panel');
      panel.hidden = !panel.hidden;
    });
    $('#disc-src').addEventListener('click', (e) => {
      e.stopPropagation();
      togglePop(e.currentTarget, 'disc-src', DISC_SRC.map(([k, n]) => ({
        label: n, on: k === src, run: () => go(`#/discover?src=${k}`),
      })), '选择书源');
    });
    $('#disc-refresh').addEventListener('click', () => {
      toast('正在刷新…');
      go(discHash(src, { rank: mode === 'rank' ? rank : null,
        cat: mode === 'cat' ? cat : null, p, fresh: true }));
    });

    const seq = ++DISC_SEQ[0];
    const box = $('#disc-list');
    const refreshHash = () => discHash(src, {
      rank: mode === 'rank' ? rank : null, cat: mode === 'cat' ? cat : null, p, fresh: true,
    });
    const failBox = (msg) => {
      if (seq !== DISC_SEQ[0]) return;
      box.innerHTML = `<div class="fail"><p>${esc(msg)}</p>
        <button class="btn ghost sm" id="disc-retry">重试</button></div>`;
      $('#disc-retry').addEventListener('click', () => go(refreshHash()));
    };
    try {
      const url = mode === 'cat' ? CAT_API[src](cat, p) : RANK_API[src](rank, p);
      const data = await api(url);
      if (seq !== DISC_SEQ[0]) return;
      const books = (data.books || []).slice(0, 40);
      if (!books.length) { failBox('这个栏目暂时没有内容，换个书源或刷新试试'); return; }
      box.innerHTML =
        (data.note ? `<p class="rank-note">${esc(data.note)}</p>` : '') +
        books.map((b) => discItem(b, src)).join('') +
        pager(Number(data.page || p), data.pages) +
        `<div class="disc-all"><a href="#/rank?src=${src}&kind=${mode === 'rank' ? rank : ranks[0]}">查看完整榜单 →</a></div>`;
      wirePager(box, (np) => go(discHash(src, {
        rank: mode === 'rank' ? rank : null, cat: mode === 'cat' ? cat : null, p: np,
      })));
      view.scrollTop = 0;
    } catch (e) {
      failBox(srcLabel + '内容没拉下来：' + e.message);
    }
  }

  // ---------------------------------------------------------------- 视图：分类列表
  async function viewList(q) {
    setNav('discover');
    const c = q.get('c') || '1';
    const p = q.get('p') || '1';
    const names = { 1: '玄幻小说', 2: '仙侠小说', 3: '都市小说', 4: '历史小说', 5: '军事小说', 6: '科幻小说', 7: '言情小说' };
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">${names[c] || '分类'}</h1>
      <div class="sub">第 ${p} 页</div></div></div>
      <div class="chips">${[1, 2, 3, 4, 5, 6, 7].map((i) =>
        `<a class="chip ${String(i) === c ? 'on' : ''}" href="#/list?c=${i}&p=1">${names[i]}</a>`).join('')}</div>
      <div id="list-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#list-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/category?c=${c}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(p), data.pages);
      wirePager(view, (np) => go(`#/list?c=${c}&p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail">
        <p>分类内容没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="list-retry">重试</button>
      </div>`;
      $('#list-retry').addEventListener('click', () => viewList(q));
    }
  }

  // ---------------------------------------------------------------- 视图：排行
  const RANK_SRC = [['sd', '速读谷'], ['qm', '七猫'], ['sq', '书旗'], ['qb', '全本网'], ['bc', '八叉'], ['bl', '八一'], ['dq', '得奇'], ['ali', '爱丽丝']];
  const SD_RANK_TABS = [['lastupdate', '最新更新'], ['top', '阅读排行'], ['quanben', '完结小说']];
  const QM_RANK_TABS = [['hot', '大热榜'], ['new', '新书榜'], ['over', '完结榜'],
    ['collect', '收藏榜'], ['update', '更新榜']];
  const SQ_RANK_TABS = [['boyClick', '男频点击'], ['boyStore', '男频收藏'], ['boyEnd', '男频完结'],
    ['girlClick', '女频点击'], ['girlStore', '女频收藏'], ['allEnd', '全站完结']];
  const QB_RANK_TABS = [['all', '总排行榜'], ['allvisit', '总点击榜'], ['monthvisit', '月点击榜'],
    ['weekvisit', '周点击榜'], ['goodnum', '收藏榜']];
  const BC_RANK_TABS = [['popular', '热门排行'], ['latest', '最新更新'],
    ['release', '最新入库'], ['completed', '完本小说']];
  const BL_RANK_TABS = [['vote', '推荐榜'], ['goodnum', '收藏榜'], ['newbook', '新书入库']];
  const DQ_RANK_TABS = [['allvisit', '总点击'], ['monthvisit', '月点击'], ['allvote', '总推荐'],
    ['goodnum', '收藏'], ['words', '字数'], ['newhot', '新书'], ['full', '全本']];
  const RANK_TABS = { sd: SD_RANK_TABS, qm: QM_RANK_TABS, sq: SQ_RANK_TABS,
    qb: QB_RANK_TABS, bc: BC_RANK_TABS, bl: BL_RANK_TABS, dq: DQ_RANK_TABS,
    ali: ALI_RANK_TABS };

  async function viewRank(q) {
    // 排行榜已并入「发现」，这里作为完整榜单子页，导航仍高亮发现
    setNav('discover');
    const src = ['qm', 'sq', 'qb', 'bc', 'bl', 'dq', 'ali'].includes(q.get('src')) ? q.get('src') : 'sd';
    const tabs = RANK_TABS[src];
    let kind = q.get('kind') || tabs[0][0];
    if (!tabs.some(([k]) => k === kind)) kind = tabs[0][0];
    const p = q.get('p') || '1';
    const sub = src === 'qm' ? '七猫官方榜单 · 每榜 100 本'
      : src === 'sq' ? '书旗官方榜单 · 每榜 500 本'
        : src === 'qb' ? '全本小说网官方榜单 · 每榜 50 本'
          : src === 'bc' ? '八叉书库官方榜单 · 每榜 20 本'
            : src === 'bl' ? '八一中文网官方榜单'
              : src === 'dq' ? '得奇小说网官方榜单 · 每榜 30 本'
                : src === 'ali' ? '爱丽丝书屋人气榜 · 每榜 50 本（需代理）' : '速读谷榜单 · 与站点同步';
    const firstKind = { sd: 'lastupdate', qm: 'hot', sq: 'boyClick', qb: 'all', bc: 'popular', bl: 'vote', dq: 'allvisit', ali: 'hits_day' };

    view.innerHTML = `<div class="page">
      <div class="page-head glass-head"><div><h1 class="h1">排行榜</h1>
        <div class="sub">${sub}</div></div>
        <a class="chip" href="#/discover?src=${src}&rank=${kind}">← 返回发现</a></div>
      <div class="chips" style="margin-bottom:12px">${RANK_SRC.map(([k, n]) =>
        `<a class="chip ${k === src ? 'on' : ''}" href="#/rank?src=${k}&kind=${firstKind[k]}">${n}</a>`).join('')}</div>
      <div class="chips">${tabs.map(([k, n]) =>
        `<a class="chip ${k === kind ? 'on' : ''}" href="#/rank?src=${src}&kind=${k}">${n}</a>`).join('')}</div>
      <div id="rank-body"><p class="muted-line">加载中…</p></div></div>`;

    const body = $('#rank-body');
    const seq = ++RANK_SEQ[0];
    try {
      const url = src === 'qm'
        ? `/api/qm/ranking?kind=${kind}&p=${p}`
        : src === 'sq' ? `/api/sq/ranking?kind=${kind}&p=${p}`
          : src === 'qb' ? `/api/qb/ranking?kind=${kind}&p=${p}`
            : src === 'bc' ? `/api/bc/ranking?kind=${kind}&p=${p}`
              : src === 'bl' ? `/api/bl/ranking?kind=${kind}`
                : src === 'dq' ? `/api/dq/ranking?kind=${kind}&p=${p}`
                  : src === 'ali' ? `/api/ali/ranking?kind=${kind}`
                    : `/api/ranking?kind=${kind}&p=${p}`;
      const data = await api(url);
      if (seq !== RANK_SEQ[0]) return;  // 快速连点切榜，只认最后一次
      const books = data.books || [];
      if (!books.length) {
        body.innerHTML = `<p class="muted-line">这个榜单暂时没有内容。</p>`;
        return;
      }
      body.innerHTML =
        (data.note ? `<p class="rank-note">${esc(data.note)}</p>` : '') +
        `<div class="list rank">${books.map((b, i) => `
          <a class="item" href="#/book/${b.id}">
            <span class="no${(b.rank || i + 1) <= 3 ? ' hot' : ''}">${b.rank || i + 1}</span>
            ${coverBox(b)}
            <div class="body">
              <h4>${esc(b.title)}${srcBadge(b.source)}</h4>
              <div class="meta">
                ${b.author ? `<span>${esc(b.author)}</span>` : ''}
                ${b.category ? `<span>${esc(b.category)}</span>` : ''}
                ${b.words ? `<span>${esc(b.words)}</span>` : ''}
                ${b.heat ? `<span>${esc(b.heatLabel || '热度')} ${esc(b.heat)}</span>` : ''}
                ${b.status ? `<span class="tag">${esc(b.status)}</span>` : ''}
              </div>
              ${b.latest ? `<div class="latest">最新：${esc(b.latest)}</div>` : ''}
            </div>
          </a>`).join('')}</div>` + pager(Number(p), data.pages);
      wirePager(view, (np) => go(`#/rank?src=${src}&kind=${kind}&p=${np}`));
    } catch (e) {
      if (seq !== RANK_SEQ[0]) return;
      body.innerHTML = `<div class="fail">
        <p>榜单没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="rank-retry">重试</button>
      </div>`;
      $('#rank-retry').addEventListener('click', () => viewRank(q));
    }
  }

  // ---------------------------------------------------------------- 视图：七猫书城
  async function viewQm(q) {
    setNav('discover');
    const c = q.get('c') || '205';
    const p = q.get('p') || '1';
    const cats = [['203', '都市'], ['219', '都市高武'], ['202', '玄幻奇幻'], ['205', '武侠仙侠'],
      ['204', '奇闻异事'], ['56', '历史'], ['75', '游戏'], ['64', '科幻']];
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">七猫书城</h1>
        <div class="sub">第二个书源 · 正版书库，和速读谷可以混着用</div></div></div>
      <div class="chips">${cats.map(([id, n]) =>
        `<a class="chip ${id === c ? 'on' : ''}" href="#/qm?c=${id}&p=1">${n}</a>`).join('')}</div>
      <div id="qm-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#qm-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/qm/category?c=${c}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(p), data.pages);
      wirePager(view, (np) => go(`#/qm?c=${c}&p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail">
        <p>七猫书城没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="qm-retry">重试</button>
      </div>`;
      $('#qm-retry').addEventListener('click', () => viewQm(q));
    }
  }

  // ---------------------------------------------------------------- 视图：书旗书库
  async function viewSq(q) {
    setNav('discover');
    const fc = q.get('fc') || '';
    const p = q.get('p') || '1';
    const name = (SQ_DISC_CATS.find(([id]) => id === fc) || ['', '全部书库'])[1];
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">书旗 · ${name}</h1>
        <div class="sub">正版书库 · 第 ${p} 页</div></div></div>
      <div class="chips">${SQ_DISC_CATS.map(([id, n]) =>
        `<a class="chip ${id === fc ? 'on' : ''}" href="#/sq${id ? '?fc=' + encodeURIComponent(id) : ''}">${n}</a>`).join('')}</div>
      <div id="sq-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#sq-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/sq/store?fc=${encodeURIComponent(fc)}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(p), data.pages);
      wirePager(view, (np) => go(`#/sq?${fc ? 'fc=' + encodeURIComponent(fc) + '&' : ''}p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail"><p>书旗书库没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="sq-retry">重试</button></div>`;
      $('#sq-retry').addEventListener('click', () => viewSq(q));
    }
  }

  // ---------------------------------------------------------------- 视图：全本书库
  async function viewQb(q) {
    setNav('discover');
    const c = q.get('c') || '1';
    const p = q.get('p') || '1';
    const name = (QB_DISC_CATS.find(([id]) => id === c) || ['1', '玄幻'])[1];
    const head = c === 'all' ? '完结小说' : name + '小说';
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">全本网 · ${head}</h1>
        <div class="sub">第 ${p} 页</div></div></div>
      <div class="chips">${QB_DISC_CATS.map(([id, n]) =>
        `<a class="chip ${id === c ? 'on' : ''}" href="#/qb?c=${id}&p=1">${n}</a>`).join('')}</div>
      <div id="qb-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#qb-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/qb/sort?c=${encodeURIComponent(c)}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(data.page || p), data.pages);
      wirePager(view, (np) => go(`#/qb?c=${encodeURIComponent(c)}&p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail"><p>全本小说网没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="qb-retry">重试</button></div>`;
      $('#qb-retry').addEventListener('click', () => viewQb(q));
    }
  }

  // ---------------------------------------------------------------- 视图：爱丽丝书库
  // 29 个标签分类，chips 会占两行；它是唯一必须走代理的源，所以错误提示直接给「填代理」的口子。
  async function viewAli(q) {
    setNav('discover');
    const c = q.get('c') || '71';
    const p = q.get('p') || '1';
    const name = (ALI_DISC_CATS.find(([id]) => id === c) || ['71', '科幻'])[1];
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">爱丽丝 · ${name}小说</h1>
        <div class="sub">第 ${p} 页 · 这个站要挂代理访问</div></div></div>
      <div class="chips">${ALI_DISC_CATS.map(([id, n]) =>
        `<a class="chip ${id === c ? 'on' : ''}" href="#/ali?c=${id}&p=1">${n}</a>`).join('')}</div>
      <div id="ali-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#ali-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/ali/sort?c=${encodeURIComponent(c)}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(data.page || p), data.pages);
      wirePager(view, (np) => go(`#/ali?c=${encodeURIComponent(c)}&p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail">
        <p>爱丽丝书屋没拉下来：${esc(e.message)}</p>
        <p class="sub" style="margin:8px 0 0">这个站只能通过代理访问。代理软件开着的话，点下面把地址填上（常见是 127.0.0.1:7897）。</p>
        <button class="btn ghost" id="ali-proxy">填代理地址</button>
        <button class="btn ghost" id="ali-retry">重试</button></div>`;
      $('#ali-retry').addEventListener('click', () => viewAli(q));
      $('#ali-proxy').addEventListener('click', async () => {
        const cur = state.settings.proxy || '';
        const v = prompt('HTTP 代理地址（留空表示直连），例如 127.0.0.1:7897', cur);
        if (v === null) return;
        let addr = v.trim();
        if (addr && !/^https?:\/\//i.test(addr)) addr = 'http://' + addr;
        state.settings.proxy = addr;
        await saveSettings();
        viewAli(q);
      });
    }
  }

  // ---------------------------------------------------------------- 视图：得奇书库
  async function viewDq(q) {
    setNav('discover');
    const c = q.get('c') || '1';
    const p = q.get('p') || '1';
    const name = (DQ_DISC_CATS.find(([id]) => id === c) || ['1', '玄幻'])[1];
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">得奇 · ${name}小说</h1>
        <div class="sub">第 ${p} 页</div></div></div>
      <div class="chips">${DQ_DISC_CATS.map(([id, n]) =>
        `<a class="chip ${id === c ? 'on' : ''}" href="#/dq?c=${id}&p=1">${n}</a>`).join('')}</div>
      <div id="dq-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#dq-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/dq/sort?c=${encodeURIComponent(c)}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(data.page || p), data.pages);
      wirePager(view, (np) => go(`#/dq?c=${encodeURIComponent(c)}&p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail"><p>得奇小说网没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="dq-retry">重试</button></div>`;
      $('#dq-retry').addEventListener('click', () => viewDq(q));
    }
  }

  // ---------------------------------------------------------------- 视图：八一中文书库
  async function viewBl(q) {
    setNav('discover');
    const c = q.get('c') || '1';
    const p = q.get('p') || '1';
    const name = (BL_DISC_CATS.find(([id]) => id === c) || ['1', '玄幻'])[1];
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">八一 · ${name}小说</h1>
        <div class="sub">第 ${p} 页</div></div></div>
      <div class="chips">${BL_DISC_CATS.map(([id, n]) =>
        `<a class="chip ${id === c ? 'on' : ''}" href="#/bl?c=${id}&p=1">${n}</a>`).join('')}</div>
      <div id="bl-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#bl-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/bl/sort?c=${encodeURIComponent(c)}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(data.page || p), data.pages);
      wirePager(view, (np) => go(`#/bl?c=${encodeURIComponent(c)}&p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail"><p>八一中文网没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="bl-retry">重试</button></div>`;
      $('#bl-retry').addEventListener('click', () => viewBl(q));
    }
  }

  // ---------------------------------------------------------------- 视图：八叉书库
  async function viewBc(q) {
    setNav('discover');
    const c = q.get('c') || '1';
    const p = q.get('p') || '1';
    const name = (BC_DISC_CATS.find(([id]) => id === c) || ['1', '长篇'])[1];
    view.innerHTML = `<div class="page">
      <div class="page-head"><div><h1 class="h1">八叉 · ${name}</h1>
        <div class="sub">第 ${p} 页</div></div></div>
      <div class="chips">${BC_DISC_CATS.map(([id, n]) =>
        `<a class="chip ${id === c ? 'on' : ''}" href="#/bc?c=${id}&p=1">${n}</a>`).join('')}</div>
      <div id="bc-body"><div class="grid">${Array(6).fill('<div class="skel" style="aspect-ratio:3/4"></div>').join('')}</div></div>
    </div>`;
    const body = $('#bc-body');
    const seq = ++LIST_SEQ[0];
    try {
      const data = await api(`/api/bc/sort?c=${encodeURIComponent(c)}&p=${p}`);
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML =
        `<div class="grid">${data.books.map((b) => bookCard(b)).join('')}</div>` +
        pager(Number(data.page || p), data.pages);
      wirePager(view, (np) => go(`#/bc?c=${encodeURIComponent(c)}&p=${np}`));
      view.scrollTop = 0;
    } catch (e) {
      if (seq !== LIST_SEQ[0]) return;
      body.innerHTML = `<div class="fail"><p>八叉书库没拉下来：${esc(e.message)}</p>
        <button class="btn ghost" id="bc-retry">重试</button></div>`;
      $('#bc-retry').addEventListener('click', () => viewBc(q));
    }
  }

  // ---------------------------------------------------------------- 视图：搜索
  const SEARCH_SOURCES = [['all', '全部书源'], ['sd', '速读谷'], ['qm', '七猫'], ['sq', '书旗'],
    ['qb', '全本网'], ['bc', '八叉'], ['bl', '八一'], ['dq', '得奇'], ['ali', '爱丽丝']];
  const HIST_KEY = 'sg.search.history';
  const SEARCH_SRC_KEY = 'sg.search.src';
  const PREF_SRC_KEY = 'sg.pref.src';           // 上次在折叠组里选过的书源

  const srcCode = (name) => (SRC_META[name] || [])[0] || '';
  const normKey = (s) => String(s == null ? '' : s).toLowerCase()
    .replace(/[^0-9a-z\u4e00-\u9fff]/g, '');
  function getPrefSrc() {
    try { return localStorage.getItem(PREF_SRC_KEY) || ''; } catch (_) { return ''; }
  }
  function setPrefSrc(s) {
    try { localStorage.setItem(PREF_SRC_KEY, s || ''); } catch (_) { /* 忽略 */ }
  }

  // 八源搜同一本书会冒出多张重复卡片：按「书名 + 作者」归并为一组，
  // 主卡片优先选书架里已有的 / 上次选过的书源，展开后可直接进其它源。
  function groupSearchBooks(books) {
    const map = new Map();
    books.forEach((b, order) => {
      const key = normKey(b.title) + '|' + normKey(b.author);
      if (!map.has(key)) map.set(key, []);
      map.get(key).push({ b, order });
    });
    const pref = getPrefSrc();
    return [...map.values()].map((raw) => {
      // 一个源里可能有多条同名书，折叠列表按源去重，避免出现两个一样的源名
      const bySrc = new Map();
      raw.forEach((it) => {
        const cur = bySrc.get(it.b.source);
        if (!cur || (state.shelf[it.b.id] && !state.shelf[cur.b.id])) {
          bySrc.set(it.b.source, it);
        }
      });
      const list = [...bySrc.values()];
      const score = ({ b, order }) => {
        let s = 100 - order / 1000;
        if (state.shelf[b.id]) s += 1000;
        if (pref && b.source === pref) s += 500;
        if (b.source === '速读谷') s += 10;
        return s;
      };
      const main = list.reduce((best, cur) => (score(cur) > score(best) ? cur : best), list[0]);
      return { main, list: list.slice().sort((a, c) => score(c) - score(a)) };
    });
  }

  function getHist() {
    try { return JSON.parse(localStorage.getItem(HIST_KEY) || '[]').filter((x) => typeof x === 'string'); }
    catch (_) { return []; }
  }
  function setHist(list) {
    try { localStorage.setItem(HIST_KEY, JSON.stringify(list.slice(0, 12))); } catch (_) { /* 隐私模式忽略 */ }
  }
  function pushHist(kw) {
    setHist([kw, ...getHist().filter((x) => x !== kw)]);
  }
  function histHTML() {
    const list = getHist();
    return list.length
      ? list.map((k) => `<button class="hist-chip" data-k="${esc(k)}"><span>${esc(k)}</span><i data-del="${esc(k)}" title="删除">${ICONS.close}</i></button>`).join('')
      : '<p class="hist-none">还没有搜索记录</p>';
  }

  function viewSearch(q) {
    setNav('search');
    const kw = q.get('q') || '';
    const src = q.get('src') || localStorage.getItem(SEARCH_SRC_KEY) || 'all';
    try { localStorage.setItem(SEARCH_SRC_KEY, src); } catch (_) { /* 忽略 */ }

    view.innerHTML = `<div class="page search-page">
      <div class="glass-topbar">
        <button class="g-circle" id="s-back" title="返回">${ICONS.back}</button>
        <form class="glass-search" id="sform">
          ${ICONS.search}
          <input id="sq" placeholder="搜索书名、作者" value="${esc(kw)}" autocomplete="off" enterkeyhint="search">
          <input type="hidden" id="ssrc" value="${esc(src)}">
          ${kw ? `<button type="button" class="s-clear" id="s-clear" title="清空">${ICONS.close}</button>` : ''}
        </form>
        <button class="g-circle" id="s-dots" data-pop title="选择书源">${ICONS.dots}</button>
      </div>
      <div id="sres" class="s-res">${kw ? '<p class="muted-line">搜索中…</p>' : ''}</div>
      <div class="hist" id="s-history" ${kw ? 'hidden' : ''}>
        <div class="hist-head"><b>搜索历史</b><button id="hist-clear">清除</button></div>
        <div class="hist-chips" id="hist-list">${histHTML()}</div>
      </div>
    </div>`;

    $('#s-back').addEventListener('click', () => go('#/shelf'));
    const submit = (v) => {
      const key = String(v || '').trim();
      if (!key) return;
      pushHist(key);
      go(`#/search?src=${$('#ssrc').value}&q=${encodeURIComponent(key)}`);
    };
    $('#sform').addEventListener('submit', (e) => {
      e.preventDefault();
      submit($('#sq').value);
    });
    $('#s-clear')?.addEventListener('click', () => go(`#/search?src=${$('#ssrc').value}`));
    $('#s-dots').addEventListener('click', (e) => {
      e.stopPropagation();
      const off = new Set(state.settings.disabledSources || []);
      togglePop(e.currentTarget, 'search-src', [
        ...SEARCH_SOURCES.map(([k, n]) => ({
          label: (k !== 'all' && off.has(k)) ? `${n}（已关闭）` : n,
          on: k === $('#ssrc').value,
          run: () => {
            $('#ssrc').value = k;
            try { localStorage.setItem(SEARCH_SRC_KEY, k); } catch (_) { /* 忽略 */ }
            const v = $('#sq').value.trim();
            go(v ? `#/search?src=${k}&q=${encodeURIComponent(v)}` : `#/search?src=${k}`);
          },
        })),
        { sep: true },
        { label: '书源健康与开关', run: () => go('#/mine') },
      ], '选择书源');
    });
    $('#hist-clear').addEventListener('click', () => {
      setHist([]);
      $('#hist-list').innerHTML = histHTML();
    });
    $('#hist-list').addEventListener('click', (e) => {
      const del = e.target.closest('[data-del]');
      if (del) {
        setHist(getHist().filter((x) => x !== del.dataset.del));
        $('#hist-list').innerHTML = histHTML();
        return;
      }
      const chip = e.target.closest('[data-k]');
      if (chip) submit(chip.dataset.k);
    });
    if (kw) { pushHist(kw); runSearch(kw, src); }
  }

  async function runSearch(kw, src = 'all', fresh = false) {
    const seq = ++SEARCH_SEQ[0];
    try {
      const data = await api(`/api/search?q=${encodeURIComponent(kw)}&src=${src}${fresh ? '&_=' + Date.now() : ''}`);
      const box = $('#sres');
      if (!box || seq !== SEARCH_SEQ[0]) return;
      // 部分书源失败时给出原因与重试入口，不再默默只显示「没找到」
      const failNote = data.msg ? `<div class="fail-note">
        <b>${data.books.length ? '部分书源请求失败' : '书源请求失败'}</b>
        <span>${esc(data.msg)}</span>
        <div><button class="btn sm ghost" id="retry-search">重新搜索</button></div>
      </div>` : '';
      if (!data.books.length) {
        box.innerHTML = `${failNote}<div class="empty"><div class="ic">🔍</div><p>${esc(data.msg ? '请检查网络后重试' : '没有找到相关小说')}</p></div>`;
        bindRetry(box);
        return;
      }
      const off = new Set(state.settings.disabledSources || []);
      // 同一源里也会重复吐同名书，先按「书名+作者+源」去重，折叠数字才对得上
      const seenSrc = new Set();
      const books = data.books.filter((b) => !off.has(srcCode(b.source))).filter((b) => {
        const k = normKey(b.title) + '|' + normKey(b.author) + '|' + (b.source || '');
        if (seenSrc.has(k)) return false;
        seenSrc.add(k);
        return true;
      });
      const groups = groupSearchBooks(books);
      const cnt = (name) => books.filter((b) => b.source === name).length;
      const mix = [['速读谷', cnt('速读谷')], ['七猫', cnt('七猫')], ['书旗', cnt('书旗')],
        ['全本网', cnt('全本小说网')], ['八叉', cnt('八叉书库')], ['八一', cnt('八一中文网')],
        ['得奇', cnt('得奇小说网')], ['爱丽丝', cnt('爱丽丝书屋')]]
        .filter(([, n]) => n).map(([name, n]) => `${name} ${n} 本`).join(' · ');
      const merged = books.length - groups.length;
      const multi = groups.filter((g) => g.list.length > 1).length;
      box.innerHTML = failNote +
        `<p class="rank-note">共 ${books.length} 本${merged > 0 ? ` · 合并后 ${groups.length} 本 · ${multi} 本可换源` : ''}${mix ? `（${mix}）` : ''}</p>` +
        `<div class="list">${groups.map((g, gi) => {
          const b = g.main.b;
          const multi = g.list.length > 1;
          return `<div class="s-group" data-g="${gi}">
            <div class="item">
              <a class="item-main" href="#/book/${encodeURIComponent(b.id)}">
                ${coverBox(b)}
                <div class="body">
                  <h4>${esc(b.title)}${srcBadge(b.source, true)}</h4>
                  <div class="meta">
                    ${b.author ? `<span>${esc(b.author)}</span>` : ''}
                    ${b.category ? `<span>${esc(b.category)}</span>` : ''}
                    ${b.words ? `<span>${esc(b.words)}</span>` : ''}
                    ${b.srcCount > 1 ? `<span class="tag">${b.srcCount} 个站</span>` : ''}
                    ${b.status ? `<span class="tag">${esc(b.status)}</span>` : ''}
                    ${b.read ? `<span>阅读量 ${esc(b.read)}</span>` : ''}
                  </div>
                  <div class="intro">${esc(b.intro || '')}</div>
                </div>
              </a>
              ${multi ? `<button class="src-toggle" data-g="${gi}" title="选择其它书源">
                <span>${g.list.length} 个书源</span>${ICONS.chev}</button>` : ''}
            </div>
            ${multi ? `<div class="src-list" id="sg-${gi}" hidden>${g.list.map(({ b: x }) => `
              <a class="src-opt ${x.id === b.id ? 'on' : ''}" href="#/book/${encodeURIComponent(x.id)}"
                 data-src="${esc(x.source || '')}">
                ${srcBadge(x.source, true)}
                <span class="so-title">${esc(x.title)}</span>
                <span class="so-meta">${esc(x.author || x.category || '')}</span>
                ${x.id === b.id ? ICONS.check : ''}
              </a>`).join('')}</div>` : ''}
          </div>`;
        }).join('')}</div>`;
      box.querySelectorAll('.src-toggle').forEach((btn) => {
        btn.addEventListener('click', () => {
          const panel = $('#sg-' + btn.dataset.g, box);
          if (!panel) return;
          panel.hidden = !panel.hidden;
          btn.classList.toggle('on', !panel.hidden);
        });
      });
      box.querySelectorAll('.src-opt').forEach((a) => {
        a.addEventListener('click', () => setPrefSrc(a.dataset.src));
      });
      bindRetry(box);
    } catch (e) {
      const box = $('#sres');
      if (box) {
        box.innerHTML = `<div class="fail"><p>搜索失败：${esc(e.message)}</p>
          <button class="btn sm ghost" id="retry-search">重新搜索</button></div>`;
        bindRetry(box);
      }
    }
  }

  function bindRetry(box) {
    const btn = box.querySelector('#retry-search');
    if (!btn) return;
    btn.addEventListener('click', () => {
      const kw = $('#sq') ? $('#sq').value.trim() : '';
      const src = $('#ssrc') ? $('#ssrc').value : 'all';
      if (kw) runSearch(kw, src, true);
    });
  }

  // ---------------------------------------------------------------- 视图：详情
  async function viewBook(id) {
    setNav('shelf');
    view.innerHTML = `<div class="page"><div class="detail-top"><div class="detail-main">
      <div class="cover skel"></div>
      <div class="detail-info"><h1 class="skel" style="height:30px;width:50%"></h1>
      <div class="skel" style="height:14px;width:35%"></div></div></div></div></div>`;
    view.scrollTop = 0;

    let b = bookCache.get(id);
    if (!b) {
      try {
        b = await api(`/api/book?id=${encodeURIComponent(id)}`);
        bookCache.set(id, b);
      } catch (e) {
        view.innerHTML = `<div class="page"><div class="empty"><p>加载失败：${esc(e.message)}</p></div></div>`;
        return;
      }
    }

    const p = b.progress || state.progress[b.id] || state.shelf[b.id]?.progress;
    const on = isOnShelf(b.id);
    const startText = p && p.i ? '继续阅读' : '开始阅读';
    const chapters = b.chapters || [];
    const preview = chapters.slice(0, 300);

    view.innerHTML = `<div class="page">
      <div class="detail-top">
        <div class="detail-main">
          ${coverBox(b)}
          <div class="detail-info">
            <h1>${esc(b.title)}</h1>
            <div class="tags">
              ${b.category ? `<span class="tag">${esc(b.category)}</span>` : ''}
              ${b.status ? `<span class="tag">${esc(b.status)}</span>` : ''}
              <span class="tag">${chapters.length} 章</span>
              ${b.words ? `<span class="tag">${esc(b.words)}</span>` : ''}
              ${b.updated && b.source !== '七猫' ? `<span class="tag">更新 ${esc(b.updated)}</span>` : ''}
              <span class="tag src">${isLocalBook(b.id) ? '本地导入' : `${esc(b.source || '速读谷')}书源`}</span>
            </div>
            <div class="who">作者：<b>${esc(b.author || '佚名')}</b>
              ${b.publisher ? `<span class="who-src">版权方：${esc(b.publisher)}</span>` : ''}</div>
            <div class="actions">
              <button class="btn" id="b-read">${p && p.i ? `继续阅读 · ${esc(p.t || '')}` : '开始阅读'}</button>
              <button class="btn ghost ${on ? 'on' : ''}" id="b-shelf">${on ? '已在书架' : '加入书架'}</button>
              ${isLocalBook(b.id) ? '' : `<button class="btn ghost ico-only" id="b-more" data-pop title="更多" aria-label="更多">${ICONS.dots}</button>`}
            </div>
          </div>
        </div>
      </div>

      <div class="intro-box">
        <h3>内容简介</h3>
        <p id="intro-text">${esc(b.intro || '暂无简介')}</p>
        ${b.statement ? `<p class="statement">${esc(b.statement)}</p>` : ''}
      </div>

      <div class="toc-box">
        <div class="toc-head"><h3>目录</h3><span>共 ${chapters.length} 章</span></div>
        <div class="toc-list" id="toc-preview">
          ${preview.map((c, i) => `<a href="#/read/${b.id}/${i}" class="${p && p.u === c.u ? 'read' : ''}">
            <i>${i + 1}</i><span>${esc(c.t)}</span></a>`).join('')}
        </div>
      </div>
    </div>`;

    $('#b-more')?.addEventListener('click', (e) => {
      e.stopPropagation();
      openSourceSwitch(b, false);
    });

    const readBtn = $('#b-read');
    readBtn.addEventListener('click', () => go(`#/read/${b.id}`));

    const shelfBtn = $('#b-shelf');
    shelfBtn.addEventListener('click', async () => {
      if (isOnShelf(b.id)) {
        await removeShelf(b.id);
        shelfBtn.classList.remove('on');
        shelfBtn.textContent = '加入书架';
        toast('已移出书架');
      } else {
        await addShelf(b);
        shelfBtn.classList.add('on');
        shelfBtn.textContent = '已在书架';
        toast('已加入书架');
      }
    });

    if (chapters.length > preview.length) {
      const more = document.createElement('button');
      more.className = 'btn ghost sm';
      more.style.marginTop = '14px';
      more.textContent = `查看全部 ${chapters.length} 章`;
      more.addEventListener('click', () => {
        $('#toc-preview').innerHTML = chapters.map((c, i) => `<a href="#/read/${b.id}/${i}" class="${p && p.u === c.u ? 'read' : ''}">
          <i>${i + 1}</i><span>${esc(c.t)}</span></a>`).join('');
        more.remove();
      });
      $('.toc-box').appendChild(more);
    }

    // 记录：只加入书架的书更新进度展示
  }

  // ================================================================ 阅读器
  const R = {
    book: null, chapters: [], index: 0, chapter: null, saveTimer: null, lastSave: 0,
    page: 1, pages: 1, pw: 0, // 分页状态：当前页 / 总页数 / 页宽
    sec: 0, chNew: false, clock: null, // 阅读计时（秒）/ 是否刚换章
  };

  const rEl = {
    scroll: $('#r-scroll'), article: $('#r-article'), end: $('#r-end'),
    pct: $('#r-pct'), page: $('#r-page'), slider: $('#r-slider'),
    drawer: $('#r-drawer'),
    toc: $('#toc-list'), set: $('#r-set'), prev: $('#r-prev'), next: $('#r-next'),
    bottom: $('#r-bottom'),
  };

  // ---- 分页布局：正文横向分栏，每栏一页 ----
  // 两种阅读模式：page = 左右分栏翻页（默认）；scroll = 上下连续滚动
  const isScroll = () => (state.settings.readMode || 'page') === 'scroll';
  const scrollMax = () => Math.max(0, rEl.scroll.scrollHeight - rEl.scroll.clientHeight);
  function scrollRatio() {
    const m = scrollMax();
    return m > 0 ? Math.min(1, Math.max(0, rEl.scroll.scrollTop / m)) : 1;
  }
  function scrollToRatio(r, instant) {
    const m = scrollMax();
    if (instant) rEl.scroll.style.scrollBehavior = 'auto';
    rEl.scroll.scrollTop = Math.min(1, Math.max(0, r || 0)) * m;
    if (instant) rEl.scroll.style.scrollBehavior = '';
  }

  function layout() {
    const pw = rEl.scroll.clientWidth;
    if (pw <= 0) return;
    R.pw = pw;
    const mobile = window.matchMedia('(max-width: 640px)').matches;
    const cs = getComputedStyle(document.documentElement);
    const sat = parseFloat(cs.getPropertyValue('--sat')) || 0;   // 刘海/状态栏
    const sab = parseFloat(cs.getPropertyValue('--sab')) || 0;   // Home 指示条
    const rw = mobile ? 0 : (state.settings.w || 720);          // 手机上不套桌面页宽
    const M = mobile
      ? Math.max(14, Math.round(pw * 0.055))
      : Math.max(40, Math.ceil((pw - rw) / 2));
    const a = rEl.article;
    a.style.width = pw + 'px';
    a.style.padding = (mobile ? 22 + sat : 44) + 'px ' + M + 'px '
                    + (mobile ? 22 + sab : 44) + 'px';
    if (isScroll()) {
      // 滚动模式：单栏、不设高度，整个容器原生滚动（CSS 那边还会清掉定位与 transform）
      a.style.columnWidth = 'auto';
      a.style.columnGap = '0px';
      a.style.transform = 'none';
      R.pages = 1;
      R.page = 1;
      return;
    }
    a.style.columnWidth = (pw - 2 * M) + 'px';
    a.style.columnGap = (2 * M) + 'px';
    R.pages = Math.max(1, Math.round(a.scrollWidth / pw));
  }

  function goToPage(p, opts = {}) {
    if (isScroll()) {
      scrollToRatio(R.pages > 1 ? (p - 1) / (R.pages - 1) : 0, opts.instant);
      updatePos();
      if (!opts.noSave) saveProgress();
      return;
    }
    R.page = Math.min(R.pages, Math.max(1, p));
    const x = (R.page - 1) * R.pw;
    if (opts.instant) rEl.article.style.transition = 'none';
    rEl.article.style.transform = `translateX(${-x}px)`;
    if (opts.instant) { void rEl.article.offsetHeight; rEl.article.style.transition = ''; }
    updatePos();
    if (!opts.noSave) saveProgress();
  }

  // 设置或窗口变化后重排，按原比例恢复位置（滚动模式按滚动比例）
  // keepRatio：切换阅读模式前先记下的位置，切过去要落在同一处
  function relayout(keepRatio) {
    if (reader.hidden || !R.pw) return;
    const ratio = keepRatio != null ? keepRatio
      : (isScroll() ? scrollRatio() : (R.pages > 1 ? (R.page - 1) / (R.pages - 1) : 0));
    layout();
    if (isScroll()) {
      scrollToRatio(ratio, true);
      updatePos();
      return;
    }
    goToPage(Math.round(ratio * (R.pages - 1)) + 1, { instant: true, noSave: true });
  }

  function nextPage() {
    if (R.page < R.pages) goToPage(R.page + 1);
    else loadChapter(R.index + 1);
  }
  function prevPage() {
    if (R.page > 1) goToPage(R.page - 1);
    else if (R.index > 0) loadChapter(R.index - 1, 1); // 回到上一章末页
  }

  // 沉浸模式：点正文隐藏底部控制条，再点恢复
  function toggleUI(force) {
    const hide = force != null ? force : !reader.classList.contains('ui-hidden');
    reader.classList.toggle('ui-hidden', hide);
    if (hide) {
      rEl.set.hidden = true;
      $('#r-menu').hidden = true;
      if (!rEl.drawer.hidden) toggleToc(false);
    }
  }

  function applySettings() {
    const s = state.settings || {};
    if (s.fs) reader.style.setProperty('--r-fs', s.fs + 'px');
    if (s.lh) reader.style.setProperty('--r-lh', s.lh);
    if (s.w) reader.style.setProperty('--r-width', s.w + 'px');
    reader.dataset.rtheme = s.theme || 'paper';
    reader.dataset.mode = isScroll() ? 'scroll' : 'page';
    rEl.article.dataset.font = s.font || 'serif';
    $('#fs-val').textContent = s.fs || 19;
    $('#set-lh').value = Math.round((s.lh || 1.95) * 100);
    $('#set-w').value = s.w || 720;
    document.querySelectorAll('#set-font button').forEach((b) => b.classList.toggle('on', (s.font || 'serif') === b.dataset.font));
    document.querySelectorAll('#set-theme button').forEach((b) => b.classList.toggle('on', (s.theme || 'paper') === b.dataset.theme));
    document.querySelectorAll('#set-mode button').forEach((b) => b.classList.toggle('on', (s.readMode || 'page') === b.dataset.mode));
  }

  function setSetting(k, v) {
    // 翻页模式切换前先记下当前读到哪儿，换一种排版也停在同一个位置
    const before = isScroll() ? scrollRatio() : (R.pages > 1 ? (R.page - 1) / (R.pages - 1) : 0);
    const modeSwitch = k === 'readMode';
    state.settings[k] = v;
    applySettings();
    saveSettings();
    relayout(modeSwitch ? before : undefined);
    if (modeSwitch) saveProgress();
  }

  // 阅读计时：只在阅读器可见且页面在前台时累加，用于「我的」里的阅读统计
  function stopClock() {
    if (R.clock) { clearInterval(R.clock); R.clock = null; }
  }
  function startClock() {
    stopClock();
    R.clock = setInterval(() => {
      if (reader.hidden || document.hidden || !R.chapter) return;
      R.sec += 5;
      if (R.sec >= 120) saveProgress(true);   // 读得久也定期落一次，别等关闭才写
    }, 5000);
  }

  async function openReader(bookId, index) {
    const b = bookCache.get(bookId) || state.shelf[bookId];
    busy(true);
    try {
      R.book = await api(`/api/book?id=${encodeURIComponent(bookId)}`);
      bookCache.set(bookId, R.book);
      updateShelfBtn();
      R.chapters = R.book.chapters || [];
      const p = state.progress[bookId];
      let i = index != null ? Number(index) : (p && p.i != null ? p.i : 0);
      if (!Number.isFinite(i) || i < 0) i = 0;
      if (i >= R.chapters.length) i = R.chapters.length - 1;
      reader.hidden = false;
      document.body.style.overflow = 'hidden';
      applySettings();
      toggleUI(true); // 进入阅读默认沉浸，点屏幕中间呼出菜单
      if (!localStorage.getItem('uiHint')) {
        localStorage.setItem('uiHint', '1');
        setTimeout(() => toast('点屏幕中间呼出菜单，两侧点击翻页'), 900);
      }
        await loadChapter(i, index == null && p && p.u === R.chapters[i]?.u ? p.ratio : 0);
      startClock();
      // 打开这本书就算看过更新了，顺手清掉书架上的 +N 章
      if (state.shelf[bookId] && state.shelf[bookId].newCh) {
        delete state.shelf[bookId].newCh;
        delete state.shelf[bookId].updAt;
        post('/api/shelf', { op: 'seen', book: { id: bookId } }).catch(() => {});
      }
      startPrefetch(bookId, i, 10);   // 打开就补当前章往后 10 章
    } catch (e) {
      toast('打开失败：' + e.message);
      reader.hidden = true;
    } finally {
      busy(false);
    }
  }

  async function loadChapter(i, restoreRatio = 0) {
    if (!R.chapters.length) return;
    if (i < 0) i = 0;
    if (i >= R.chapters.length) { toast('已经是最后一章了'); return; }
    R.index = i;
    const c = R.chapters[i];
    rEl.article.innerHTML = '<p style="opacity:.5">正在加载章节…</p>';
    layout();
    goToPage(1, { instant: true, noSave: true });

    let data;
    try {
      data = await api(`/api/chapter?u=${encodeURIComponent(c.u)}`);
    } catch (e) {
      rEl.article.innerHTML = `<p class="skip" style="text-align:center;opacity:.7">
        章节加载失败：${esc(e.message)}<br><br>
        <button class="btn ghost sm" onclick="location.reload()">重新加载</button></p>`;
      return;
    }
    R.chapter = data;
    R.chNew = true;
    rEl.article.innerHTML =
      `<h1>${esc(data.title || c.t)}</h1>` +
      data.paras.map((p) => `<p>${esc(p)}</p>`).join('');
    rEl.article.appendChild(rEl.end);
    applyHighlights();
    layout();
    if (isScroll()) {
      scrollToRatio(restoreRatio > 0 ? restoreRatio : 0, true);
      updatePos();
    } else {
      const target = restoreRatio > 0 && R.pages > 1
        ? Math.round(restoreRatio * (R.pages - 1)) + 1 : 1;
      goToPage(target, { instant: true, noSave: true });
    }
    saveProgress(true);
    // 顺带预取后续章节（后端会跳过已缓存 / 正在抓取的）
    if (i + 1 < R.chapters.length && R.book) {
      startPrefetch(R.book.id, i + 1, 8);
    }
  }

  // ---- 划线高亮：按段落开头 18 字匹配，切章再回来也能对上 ----
  function applyHighlights() {
    if (!R.book || !R.chapter) return;
    const u = R.chapter.url || R.chapters[R.index]?.u;
    const notes = marksOf(R.book.id).filter((m) => m.type === 'note' && m.u === u);
    if (!notes.length) return;
    const paras = Array.from(rEl.article.querySelectorAll('p'));
    notes.forEach((n) => {
      const key = String(n.text || '').slice(0, 18);
      if (!key) return;
      const hit = paras.find((p) => p.textContent.indexOf(key) >= 0);
      if (!hit || hit.classList.contains('noted')) return;
      hit.classList.add('noted');
      hit.dataset.mark = n.id;
      // 只给被划的那几行加底色，别整段拉一条横贯全宽的色带
      const full = hit.textContent;
      const at = full.indexOf(key);
      const len = Math.min(full.length - at, (String(n.text || '') || key).length);
      if (at >= 0 && len > 0) {
        hit.innerHTML = esc(full.slice(0, at)) +
          `<span class="hl">${esc(full.slice(at, at + len))}</span>` +
          esc(full.slice(at + len));
      }
    });
  }

  // 长按段落（手机）/ 双击（桌面）→ 划线、写笔记
  function openNoteDialog(p) {
    if (!R.book || !p || reader.hidden) return;
    const text = String(p.textContent || '').trim();
    if (!text) return;
    const u = R.chapter && (R.chapter.url || R.chapters[R.index]?.u);
    const existed = (state.marks || []).find((m) => m.type === 'note' && m.u === u &&
      text.indexOf(String(m.text || '').slice(0, 18)) >= 0);

    const mask = document.createElement('div');
    mask.className = 'glass-mask';
    mask.innerHTML = `<div class="note-dialog">
      <div class="nd-head"><b>${existed ? '编辑笔记' : '划线 / 记笔记'}</b>
        <span>${esc(R.chapters[R.index]?.t || '')}</span></div>
      <div class="nd-quote">${esc(text.slice(0, 220))}</div>
      <textarea class="nd-input" placeholder="写点什么（可留空，只划线）">${esc(existed ? existed.note : '')}</textarea>
      <div class="gd-actions">
        ${existed ? '<button class="g-text danger" data-del>删除</button>' : ''}
        <button class="g-text" data-no>取消</button>
        <button class="g-text ok" data-yes>保存</button>
      </div></div>`;
    document.body.appendChild(mask);
    const close = () => mask.remove();
    const area = mask.querySelector('.nd-input');
    mask.addEventListener('click', (e) => { if (e.target === mask) close(); });
    mask.querySelector('[data-no]').addEventListener('click', close);
    mask.querySelector('[data-del]')?.addEventListener('click', async () => {
      close();
      try {
        await removeMark(existed.id);
        rEl.article.querySelectorAll('p.noted').forEach((el) => {
          if (el.dataset.mark === existed.id) { el.classList.remove('noted'); delete el.dataset.mark; }
        });
        toast('已删除这条笔记');
      } catch (err) { toast('删除失败：' + (err && err.message || err)); }
    });
    mask.querySelector('[data-yes]').addEventListener('click', async () => {
      const note = area.value.trim();
      close();
      try {
        await saveMark({
          id: existed ? existed.id : '',
          bookId: R.book.id, bookTitle: R.book.title || '',
          i: R.index, t: R.chapters[R.index]?.t || '', u,
          page: R.page, ratio: currentRatio(), type: 'note',
          text: text.slice(0, 300), note,
        });
        applyHighlights();
        toast(note ? '笔记已保存' : '已划线');
      } catch (err) {
        toast('保存失败：' + (err && err.message || err));
      }
    });
  }

  let pressTimer = null;
  let pressEl = null;
  const cancelPress = () => { clearTimeout(pressTimer); pressTimer = null; pressEl = null; };
  rEl.article.addEventListener('touchstart', (e) => {
    const p = e.target.closest('p');
    if (!p || e.touches.length !== 1) return;
    cancelPress();
    pressEl = p;
    pressTimer = setTimeout(() => {
      const el = pressEl;
      pressTimer = null;
      pressEl = null;
      if (el) {
        swiped = true;          // 长按后浏览器还会补一次 click，别顺手翻页
        openNoteDialog(el);
      }
    }, 550);
  }, { passive: true });
  ['touchend', 'touchmove', 'touchcancel'].forEach((ev) => {
    rEl.article.addEventListener(ev, cancelPress, { passive: true });
  });
  rEl.article.addEventListener('dblclick', (e) => {
    const p = e.target.closest('p');
    if (p) openNoteDialog(p);
  });
  // 点已划线的段落 → 看笔记 / 删除
  rEl.article.addEventListener('click', (e) => {
    if (swiped) return;
    const p = e.target.closest('p.noted');
    if (!p) return;
    e.stopPropagation();
    const m = (state.marks || []).find((x) => x.id === p.dataset.mark);
    if (!m) return;
    e.preventDefault();
    openPop(p, [{
      label: m.note ? '删除这条笔记' : '删除这条划线', danger: true,
      run: async () => {
        try {
          await removeMark(m.id);
          p.classList.remove('noted');
          delete p.dataset.mark;
          toast('已删除');
        } catch (err) { toast('删除失败'); }
      },
    }], m.note ? ('笔记：' + m.note) : '已划线');
  });

  function updatePos() {
    const i = R.index, n = R.chapters.length;
    rEl.prev.disabled = i <= 0;
    rEl.next.disabled = i >= n - 1;
    // 左下角：全书进度百分比
    const pct = Math.round(((i + 1) / Math.max(1, n)) * 100);
    rEl.pct.textContent = `${pct}%`;
    if (isScroll()) {
      // 滚动模式没有页码，右下滑杆显示本章已读比例
      const r = scrollRatio();
      rEl.page.textContent = `${Math.round(r * 100)}%`;
      if (document.activeElement !== rEl.slider) rEl.slider.value = Math.round(r * 1000);
      return;
    }
    // 右下角：本章真实页码
    rEl.page.textContent = `${R.page} / ${R.pages}`;
    // 同步翻页滑杆（拖动中不覆盖）
    if (document.activeElement !== rEl.slider) {
      rEl.slider.value = R.pages > 1 ? Math.round(((R.page - 1) / (R.pages - 1)) * 1000) : 0;
    }
  }

  // 滑杆拖动 → 翻到对应页（滚动模式下按比例滚）
  rEl.slider.addEventListener('input', () => {
    if (isScroll()) { scrollToRatio(Number(rEl.slider.value) / 1000); updatePos(); return; }
    const p = R.pages > 1 ? Math.round((Number(rEl.slider.value) / 1000) * (R.pages - 1)) + 1 : 1;
    goToPage(p);
  });

  function currentRatio() {
    if (isScroll()) return scrollRatio();
    return R.pages > 1 ? (R.page - 1) / (R.pages - 1) : 1;
  }

  function saveProgress(immediate = false) {
    if (!R.book || !R.chapter) return;
    const doSave = async () => {
      const sec = R.sec;
      const chNew = R.chNew;
      R.sec = 0;
      R.chNew = false;
      const payload = {
        bookId: R.book.id, u: R.chapter.url || R.chapters[R.index]?.u,
        t: R.chapter.title || R.chapters[R.index]?.t, i: R.index,
        n: R.chapters.length, ratio: currentRatio(), sec, chNew,
        title: R.book.title || '',
      };
      state.progress[R.book.id] = { ...payload, ts: Date.now() / 1000 };
      if (state.shelf[R.book.id]) {
        state.shelf[R.book.id].progress = state.progress[R.book.id];
        state.shelf[R.book.id].lastRead = state.progress[R.book.id].ts;
      }
      try { await post('/api/progress', payload); } catch (_) { /* 离线时忽略 */ }
    };
    if (immediate) { clearTimeout(R.saveTimer); doSave(); return; }
    clearTimeout(R.saveTimer);
    R.saveTimer = setTimeout(doSave, 1200);
  }

  function closeReader() {
    saveProgress(true);
    stopClock();
    reader.hidden = true;
    rEl.drawer.hidden = true;
    rEl.set.hidden = true;
    $('#r-menu').hidden = true;
    clearInterval(dlTimer);
    dlTimer = null;
    reader.classList.remove('toc-open');
  }

  function toggleToc(force) {
    const show = force != null ? force : rEl.drawer.hidden;
    rEl.drawer.hidden = !show;
    // 目录打开时收起返回按钮与左下角百分比，避免被抽屉盖住
    reader.classList.toggle('toc-open', show);
    if (show) {
      renderToc('');
      const on = rEl.toc.querySelector('a.on');
      if (on) {
        // 抽屉刚从 hidden 变出来时还没有布局，直接 scrollIntoView 会滚不动，等一帧再按偏移算
        requestAnimationFrame(() => {
          rEl.toc.scrollTop = Math.max(0,
            on.offsetTop - rEl.toc.clientHeight / 2 + on.offsetHeight / 2);
        });
      }
      // 手机上别自动聚焦：会弹出键盘把目录遮掉
      if (!window.matchMedia('(max-width: 640px)').matches) $('#toc-filter').focus();
    }
  }

  function renderToc(filter) {
    const kw = (filter || '').trim();
    let list = R.chapters.map((c, i) => ({ c, i }));
    if (kw) {
      list = list.filter(({ c }) => c.t.includes(kw)).slice(0, 2000);
    } else if (list.length > 1600) {
      // 几千章的书全渲染太慢，以当前章为中心取一段，保证「打开就在当前章」总成立
      const from = Math.max(0, Math.min(R.index - 700, list.length - 1600));
      list = list.slice(from, from + 1600);
    }
    rEl.toc.innerHTML = list.map(({ c, i }) => `
      <a href="javascript:void(0)" data-i="${i}" class="${i === R.index ? 'on' : ''}">
        <span>${esc(c.t)}</span></a>`).join('') || '<p style="padding:12px;color:var(--r-sub)">没有匹配的章节</p>';
    rEl.toc.querySelectorAll('a[data-i]').forEach((a) => {
      a.addEventListener('click', () => {
        toggleToc(false);
        loadChapter(Number(a.dataset.i));
      });
    });
  }

  // 阅读器事件
  rEl.prev.addEventListener('click', () => loadChapter(R.index - 1));
  rEl.next.addEventListener('click', () => loadChapter(R.index + 1));
  $('#r-end-prev')?.addEventListener('click', () => loadChapter(R.index - 1));
  $('#r-end-next')?.addEventListener('click', () => loadChapter(R.index + 1));
  $('#r-back').addEventListener('click', () => {
    closeReader();
    go('#/shelf');
  });
  $('#r-toc-btn').addEventListener('click', () => toggleToc());
  $('#toc-close').addEventListener('click', () => toggleToc(false));
  $('#toc-filter').addEventListener('input', (e) => renderToc(e.target.value));
  $('#r-set-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    rEl.set.hidden = !rEl.set.hidden;
  });
  document.addEventListener('click', (e) => {
    if (!rEl.set.hidden && !rEl.set.contains(e.target) && e.target.closest('#r-set-btn') == null) {
      rEl.set.hidden = true;
    }
    const menu = $('#r-menu');
    if (!menu.hidden && !menu.contains(e.target) && e.target.closest('#r-more') == null) {
      menu.hidden = true;
    }
  });

  // ---- 右上角更多菜单：书籍详情 / 下载 ----
  let dlTimer = null;
  let dlPrev = 'none';
  const dlBtn = $('#r-menu-dl');

  function renderDl(s) {
    const was = dlPrev;
    dlPrev = s.status;
    if (s.status === 'running') {
      dlBtn.disabled = true;
      dlBtn.textContent = `下载中 ${s.done || 0}/${s.total || 0}`;
      if (!dlTimer) {
        dlTimer = setInterval(async () => {
          if (!R.book) return;
          try {
            renderDl(await api(`/api/download?bookId=${encodeURIComponent(R.book.id)}`));
          } catch (_) { /* 忽略轮询错误 */ }
        }, 1000);
      }
    } else {
      clearInterval(dlTimer);
      dlTimer = null;
      dlBtn.disabled = false;
      if (s.status === 'done') {
        dlBtn.textContent = s.failed ? `重新下载（${s.failed} 章失败）` : '重新下载';
        if (was === 'running') toast(s.failed ? `下载完成，${s.failed} 章失败，可重试` : '下载完成，已可离线阅读');
      } else {
        dlBtn.textContent = '下载本书';
      }
    }
  }

  async function refreshDl() {
    if (!R.book) return;
    try {
      renderDl(await api(`/api/download?bookId=${encodeURIComponent(R.book.id)}`));
    } catch (_) { /* 忽略 */ }
  }

  function currentChapterU() {
    return R.chapter ? (R.chapter.url || R.chapters[R.index]?.u || '') : '';
  }

  function updateMarkBtn() {
    const t = $('#r-menu-mark-t');
    if (!t || !R.book) return;
    const on = !!markOfChapter(R.book.id, currentChapterU());
    t.textContent = on ? '移出书签' : '加入书签';
    $('#r-menu-mark').classList.toggle('on', on);
  }

  $('#r-more').addEventListener('click', (e) => {
    e.stopPropagation();
    const menu = $('#r-menu');
    menu.hidden = !menu.hidden;
    if (!menu.hidden) {
      const local = isLocalBook(R.book?.id);
      $('#r-menu-dl').hidden = local;    // 本地书不用下载，也不用换源
      $('#r-menu-src').hidden = local;
      updateMarkBtn();
      if (!local) {
        dlPrev = 'none';
        refreshDl();
      }
    }
  });

  $('#r-menu-mark').addEventListener('click', async () => {
    if (!R.book) return;
    const u = currentChapterU();
    const cur = markOfChapter(R.book.id, u);
    $('#r-menu').hidden = true;
    try {
      if (cur) {
        await removeMark(cur.id);
        toast('已移出书签');
      } else {
        await saveMark({
          bookId: R.book.id, bookTitle: R.book.title || '', i: R.index,
          t: R.chapters[R.index]?.t || '', u, page: R.page,
          ratio: currentRatio(), type: 'bookmark', text: '', note: '',
        });
        toast('已加入书签');
      }
      updateMarkBtn();
    } catch (err) {
      toast('操作失败：' + (err && err.message || err));
    }
  });

  $('#r-menu-detail').addEventListener('click', () => {
    const id = R.book?.id;
    $('#r-menu').hidden = true;
    closeReader();
    go(id ? `#/book/${id}` : '#/shelf');
  });

  $('#r-menu-src').addEventListener('click', () => {
    $('#r-menu').hidden = true;
    openSourceSwitch(R.book, true);
  });

  $('#r-menu-dl').addEventListener('click', async () => {
    if (!R.book || dlBtn.disabled) return;
    try {
      dlBtn.disabled = true;
      dlBtn.textContent = '开始下载…';
      renderDl(await post('/api/download', { bookId: R.book.id }));
    } catch (e) {
      dlBtn.disabled = false;
      dlBtn.textContent = '下载本书';
      toast('下载失败：' + e.message);
    }
  });

  // ---- 右上角加入书架按钮 ----
  const ICON_ADD = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 8.2v7.6M8.2 12h7.6"/></svg>';
  const ICON_ON = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M8.3 12.4l2.6 2.6 4.9-5.4"/></svg>';

  function updateShelfBtn() {
    const btn = $('#r-shelf');
    const on = !!(R.book && state.shelf[R.book.id]);
    btn.classList.toggle('on', on);
    btn.innerHTML = on ? ICON_ON : ICON_ADD;
    btn.title = on ? '移出书架' : '加入书架';
  }

  $('#r-shelf').addEventListener('click', async () => {
    const b = R.book;
    if (!b) return;
    try {
      if (state.shelf[b.id]) {
        await post('/api/shelf', { op: 'remove', book: { id: b.id } });
        delete state.shelf[b.id];
        toast('已移出书架');
      } else {
        const info = {
          id: b.id, title: b.title, author: b.author, cover: b.cover,
          category: b.category, status: b.status,
          source: b.source || srcNameById(b.id),
          count: (b.chapters || []).length,
        };
        await post('/api/shelf', { op: 'add', book: info });
        state.shelf[b.id] = { ...info, added: Date.now() / 1000 };
        startPrefetch(b.id, 0, 5);
        toast('已加入书架');
      }
      updateShelfBtn();
    } catch (e) {
      toast('操作失败：' + e.message);
    }
  });

  // 点正文：左 1/3 上一页，右 1/3 下一页，中间呼出/收起控制面板
  // 滚动模式下位置没有意义，点哪儿都是呼出/收起
  let swiped = false;
  rEl.scroll.addEventListener('click', (e) => {
    if (swiped) { swiped = false; return; }  // 滑动翻页后浏览器还会补一次 click，别重复翻
    if (e.target.closest('button, a, input')) return;
    const sel = window.getSelection ? String(window.getSelection()) : '';
    if (sel.trim()) return; // 正在划词选中，不打断
    if (isScroll()) { toggleUI(); return; }
    const rect = rEl.scroll.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    if (x < 0.3) prevPage();
    else if (x > 0.7) nextPage();
    else toggleUI();
  });

  // 滚轮翻页（滚动模式交给原生滚动）
  let wheelLock = 0;
  rEl.scroll.addEventListener('wheel', (e) => {
    if (isScroll()) return;
    e.preventDefault();
    const now = Date.now();
    if (now - wheelLock < 260) return;
    const d = Math.abs(e.deltaY) >= Math.abs(e.deltaX) ? e.deltaY : e.deltaX;
    if (Math.abs(d) < 12) return;
    wheelLock = now;
    if (d > 0) nextPage(); else prevPage();
  }, { passive: false });

  // 滚动模式：滚动时更新进度与滑杆，进度按 1.2 秒防抖落盘
  rEl.scroll.addEventListener('scroll', () => {
    if (!isScroll() || reader.hidden) return;
    updatePos();
    saveProgress();
  }, { passive: true });

  // 触屏左右滑动翻页（滚动模式是原生上下滚，不接管）
  let tX = 0, tY = 0;
  rEl.scroll.addEventListener('touchstart', (e) => {
    tX = e.touches[0].clientX; tY = e.touches[0].clientY;
  }, { passive: true });
  rEl.scroll.addEventListener('touchend', (e) => {
    if (isScroll()) return;
    const dx = e.changedTouches[0].clientX - tX;
    const dy = e.changedTouches[0].clientY - tY;
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) {
      swiped = true;
      if (dx < 0) nextPage(); else prevPage();
    }
  }, { passive: true });

  window.addEventListener('resize', () => {
    if (!reader.hidden) relayout();
  });
  // 手机横竖屏切换 / 键盘收起后视口变化，重新分页
  window.visualViewport && window.visualViewport.addEventListener('resize', () => {
    if (!reader.hidden) relayout();
  });

  // 设置面板
  document.querySelectorAll('[data-fs]').forEach((b) => {
    b.addEventListener('click', () => {
      const cur = state.settings.fs || 19;
      const next = Math.min(32, Math.max(14, cur + Number(b.dataset.fs)));
      setSetting('fs', next);
    });
  });
  $('#set-lh').addEventListener('input', (e) => setSetting('lh', Number(e.target.value) / 100));
  $('#set-w').addEventListener('input', (e) => setSetting('w', Number(e.target.value)));
  document.querySelectorAll('#set-font button').forEach((b) => {
    b.addEventListener('click', () => setSetting('font', b.dataset.font));
  });
  document.querySelectorAll('#set-mode button').forEach((b) => {
    b.addEventListener('click', () => setSetting('readMode', b.dataset.mode));
  });
  document.querySelectorAll('#set-theme button').forEach((b) => {
    b.addEventListener('click', () => setSetting('theme', b.dataset.theme));
  });

  // 键盘
  document.addEventListener('keydown', (e) => {
    if (!reader.hidden) {
      if (e.key === 'Escape') {
        if (!$('#r-menu').hidden) { $('#r-menu').hidden = true; return; }
        if (!rEl.set.hidden) { rEl.set.hidden = true; return; }
        if (!rEl.drawer.hidden) { toggleToc(false); return; }
        if (reader.classList.contains('ui-hidden')) { toggleUI(false); return; }
        const id = R.book?.id;
        closeReader();
        go(id ? `#/book/${id}` : '#/shelf');
        return;
      }
      if (e.key === 'ArrowLeft') { e.preventDefault(); prevPage(); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); nextPage(); }
      else if (e.key === 'PageUp') { if (!isScroll()) { e.preventDefault(); prevPage(); } }
      else if (e.key === 'PageDown') { if (!isScroll()) { e.preventDefault(); nextPage(); } }
      else if (e.key.toLowerCase() === 't') { e.preventDefault(); toggleToc(); }
      return;
    }
    const tag = (document.activeElement || {}).tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA') return;
    if (e.key === '/') { e.preventDefault(); go('#/search'); setTimeout(() => $('#sq')?.focus(), 80); }
  });

  // ---------------------------------------------------------------- 书源健康面板（我的页底部）
  const HEALTH_SOURCES = [['sd', '速读谷'], ['qm', '七猫'], ['sq', '书旗'], ['qb', '全本网'],
    ['bc', '八叉'], ['bl', '八一'], ['dq', '得奇'], ['ali', '爱丽丝']];
  let healthTimer = null;

  function loadHealth(refresh = false) {
    clearTimeout(healthTimer);
    if (!$('#mine-health')) return;
    api(`/api/health${refresh ? '?refresh=1' : ''}`).then((d) => {
      renderHealth(d);
      if (d.checking && $('#mine-health')) {
        healthTimer = setTimeout(() => loadHealth(false), 1500);
      }
    }).catch(() => {});
  }

  function renderHealth(d) {
    const box = $('#mine-health');
    if (!box) return;
    const off = new Set(state.settings.disabledSources || []);
    const rows = HEALTH_SOURCES.map(([code, name]) => {
      const r = (d.rows || {})[code] || null;
      const cls = r ? (r.ok ? 'ok' : 'bad') : 'wait';
      const txt = r ? (r.ok ? '正常' : '异常') : (d.checking ? '检测中' : '未检测');
      const detail = r ? `${r.ms}ms · ${r.msg}` : '等待检测';
      return `<div class="health-row">
        <span class="h-dot ${cls}"></span>
        <div class="h-name"><b>${esc(name)}</b><span>${esc(detail)}</span></div>
        <span class="h-state ${cls}">${txt}</span>
        <button class="h-switch ${off.has(code) ? '' : 'on'}" data-code="${code}"
          title="启用 / 停用该书源" aria-label="启用或停用该书源"><i></i></button>
      </div>`;
    }).join('');
    const p = d.proxy || {};
    box.innerHTML = `<div class="health-card">
      <div class="hc-head">
        <div><b>书源健康</b><span>${d.checking ? '正在检测 8 个书源…' : '关闭的源不参与搜索与换源'}</span></div>
        <button class="g-text sm" id="health-refresh" ${d.checking ? 'disabled' : ''}>${d.checking ? '检测中' : '重新检测'}</button>
      </div>
      <div class="hc-rows">${rows}</div>
      <div class="hc-proxy">爱丽丝代理：${esc(p.port ? '本机 ' + p.port : (p.proxy || '直连'))}${p.configured ? '（手动设置）' : ''}${p.cooling ? ' · 直连超时冷却中' : ''}</div>
    </div>`;
    box.querySelectorAll('[data-code]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const code = btn.dataset.code;
        const s = new Set(state.settings.disabledSources || []);
        if (s.has(code)) s.delete(code); else s.add(code);
        state.settings.disabledSources = [...s];
        saveSettings();
        renderHealth(d);
      });
    });
    $('#health-refresh')?.addEventListener('click', () => loadHealth(true));
  }

  // ---------------------------------------------------------------- 视图：我的（统计 / 书签 / 本地书 / 备份 / 下载）
  const fmtDur = (sec) => {
    const s = Math.max(0, Math.round(sec || 0));
    if (s < 60) return s ? s + ' 秒' : '0 分';
    const m = Math.round(s / 60);
    if (m < 60) return m + ' 分钟';
    const h = Math.floor(m / 60);
    return h + ' 小时' + (m % 60 ? ' ' + (m % 60) + ' 分' : '');
  };
  const shortDate = (d) => {
    const p = String(d || '').split('-');
    return p.length === 3 ? `${Number(p[1])}/${Number(p[2])}` : String(d || '');
  };

  function renderStats(s) {    const box = $('#mine-stats');
    if (!box) return;
    const recent = s.recent || [];
    const max = Math.max(60, ...recent.map((x) => x.sec || 0));
    const bars = recent.map((x) => {
      const h = x.sec ? Math.max(6, Math.round((x.sec / max) * 100)) : 2;
      return `<i class="${x.sec ? '' : 'zero'}" style="height:${h}%" title="${shortDate(x.d)} · ${fmtDur(x.sec)}${x.ch ? ' · ' + x.ch + ' 章' : ''}"></i>`;
    }).join('');
    const empty = !s.total.sec && !s.total.ch;
    box.innerHTML = `<div class="stat-card">
      <div class="sc-top"><b>阅读统计</b><span>${empty ? '随便读一章就有了' : '最近 14 天'}</span></div>
      <div class="sc-nums">
        <div><b>${s.today.sec ? fmtDur(s.today.sec) : '—'}</b><span>今日</span></div>
        <div><b>${s.streak} 天</b><span>连续阅读</span></div>
        <div><b>${fmtDur(s.total.sec)}</b><span>累计时长</span></div>
        <div><b>${s.total.ch}</b><span>累计章数</span></div>
      </div>
      <div class="sc-bars">${bars}</div>
    </div>`;
  }

  const fmtSize = (n) => {
    const b = Math.max(0, Number(n) || 0);
    if (b < 1024) return b + ' B';
    if (b < 1024 * 1024) return Math.round(b / 1024) + ' KB';
    if (b < 1024 * 1024 * 1024) return (b / 1024 / 1024).toFixed(1) + ' MB';
    return (b / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  };

  // 继续阅读：最近打开过的书，没加入书架的也在里面
  function renderHistory(box, list) {
    if (!box) return;
    if (!list.length) {
      box.innerHTML = `<div class="mine-card glass-card">
        <div class="mc-head"><b>继续阅读</b></div>
        <p class="mc-empty">读过的书按时间排在这里，没加入书架也能找回来</p>
      </div>`;
      return;
    }
    box.innerHTML = `<div class="mine-card glass-card">
      <div class="mc-head"><b>继续阅读</b>
        <button class="mc-more" id="hist-wipe">清空</button></div>
      ${list.slice(0, 6).map((h) => `<div class="mk-row" data-hist-go="${esc(h.bookId)}|${Number(h.i) || 0}">
        <div class="mk-main">
          <div class="mk-title">${esc(h.title || '未知书名')}</div>
          <div class="mk-sub">${esc(h.t || '')}${h.ts ? ' · ' + esc(relTime(h.ts)) : ''}</div>
        </div>
        <button class="mk-go" data-hist-read="${esc(h.bookId)}|${Number(h.i) || 0}">继续</button>
        <button class="mk-del" data-hist-del="${esc(h.bookId)}" title="从历史里移除">${ICONS.close}</button>
      </div>`).join('')}
    </div>`;
    const jump = (v) => {
      const [bid, i] = String(v).split('|');
      go(`#/read/${encodeURIComponent(bid)}/${Number(i) || 0}`);
    };
    box.querySelectorAll('[data-hist-go]').forEach((el) => {
      el.addEventListener('click', (e) => {
        if (e.target.closest('[data-hist-del]')) return;
        jump(el.dataset.histGo);
      });
    });
    box.querySelectorAll('[data-hist-read]').forEach((b) => {
      b.addEventListener('click', () => jump(b.dataset.histRead));
    });
    box.querySelectorAll('[data-hist-del]').forEach((b) => {
      b.addEventListener('click', async (e) => {
        e.stopPropagation();
        try {
          const r = await post('/api/history', { op: 'remove', bookId: b.dataset.histDel });
          renderHistory(box, r.history || []);
        } catch (err) { toast('删除失败'); }
      });
    });
    $('#hist-wipe')?.addEventListener('click', () => {
      askConfirm('清空阅读历史？书架、进度和书签都不受影响。', '清空', async () => {
        try {
          await post('/api/history', { op: 'clear' });
          renderHistory(box, []);
          toast('阅读历史已清空');
        } catch (err) { toast('清空失败'); }
      });
    });
  }

  // 缓存管理：看得见占多少地方，能按本清、也能一次清空
  function loadCacheCard() {
    const box = $('#mine-cache');
    if (!box) return;
    api('/api/cache').then((d) => renderCache(box, d)).catch(() => {});
  }

  function renderCache(box, d) {
    const rows = Object.entries(d.cache || {})
      .filter(([, v]) => v.cached && !v.local)
      .sort((a, b) => (b[1].bytes || 0) - (a[1].bytes || 0));
    box.innerHTML = `<div class="mine-card glass-card">
      <div class="mc-head"><b>缓存</b>
        <span class="mc-sub">章节 ${fmtSize(d.bytes)} · 封面 ${fmtSize(d.img)}</span></div>
      ${rows.length ? rows.slice(0, 8).map(([bid, v]) => `<div class="mk-row">
        <div class="mk-main">
          <div class="mk-title">${esc(v.title || (state.shelf[bid] || {}).title || bid)}</div>
          <div class="mk-sub">已缓存 ${v.cached}${v.total ? '/' + v.total : ''} 章 · ${fmtSize(v.bytes)}</div>
        </div>
        <button class="mk-go" data-cache-clear="${esc(bid)}">清理</button>
      </div>`).join('')
        : '<p class="mc-empty">还没有章节缓存，预取或「下载本书」之后会出现在这里</p>'}
      <div class="mc-foot">
        <button class="g-text sm danger" id="cache-wipe" ${rows.length ? '' : 'disabled'}>清空全部章节缓存</button>
      </div>
    </div>`;
    const refresh = (msg) => {
      cacheInfo = null;
      cacheInfoAt = 0;
      if (msg) toast(msg);
      loadCacheCard();
    };
    box.querySelectorAll('[data-cache-clear]').forEach((b) => {
      b.addEventListener('click', async () => {
        try {
          const r = await post('/api/cache', { bookId: b.dataset.cacheClear });
          refresh(`已清理 ${r.removed || 0} 章`);
        } catch (e) { toast('清理失败：' + (e && e.message || e)); }
      });
    });
    $('#cache-wipe')?.addEventListener('click', () => {
      askConfirm('清空全部章节缓存？书架、阅读进度和书签都不受影响，只是下次读要重新下载正文。',
        '清空缓存', async () => {
          try {
            const r = await post('/api/cache', {});
            refresh(`已清理 ${r.removed || 0} 章`);
          } catch (e) { toast('清理失败：' + (e && e.message || e)); }
        });
    });
  }

  const markRow = (m) => `
    <div class="mk-row" data-mark-go="${esc(m.bookId)}|${Number(m.i) || 0}">
      <span class="mk-tag ${m.type === 'note' ? 'note' : ''}">${m.type === 'note' ? '笔记' : '书签'}</span>
      <div class="mk-main">
        <div class="mk-title">${esc(m.bookTitle || '未知书名')}</div>
        <div class="mk-sub">${esc(m.t || '')}${m.page > 1 ? ` · 第 ${m.page} 页` : ''} · ${esc(relTime(m.ts))}</div>
        ${m.note ? `<div class="mk-note">${esc(m.note)}</div>`
          : (m.text ? `<div class="mk-note">${esc(m.text)}</div>` : '')}
      </div>
      <button class="mk-del" data-mark-del="${esc(m.id)}" title="删除">${ICONS.close}</button>
    </div>`;

  function bindMarks(root) {
    root.querySelectorAll('[data-mark-go]').forEach((el) => {
      el.addEventListener('click', (e) => {
        if (e.target.closest('[data-mark-del]')) return;
        const [bid, idx] = el.dataset.markGo.split('|');
        go(`#/read/${encodeURIComponent(bid)}/${Number(idx) || 0}`);
      });
    });
    root.querySelectorAll('[data-mark-del]').forEach((b) => {
      b.addEventListener('click', async (e) => {
        e.stopPropagation();
        try {
          await removeMark(b.dataset.markDel);
          toast('已删除');
          if (location.hash.startsWith('#/marks')) viewMarks(); else viewMine();
        } catch (err) { toast('删除失败'); }
      });
    });
  }

  function renderMarks(box, limit) {
    const list = (state.marks || []).slice().sort((a, b) => (b.ts || 0) - (a.ts || 0));
    if (!list.length) {
      box.innerHTML = `<div class="mine-card glass-card">
        <div class="mc-head"><b>书签与笔记</b></div>
        <p class="mc-empty">阅读器右上「更多」可加书签，长按正文段落可以划线记笔记</p>
      </div>`;
      return;
    }
    box.innerHTML = `<div class="mine-card glass-card">
      <div class="mc-head"><b>书签与笔记</b>
        <a class="mc-more" href="#/marks">全部 ${list.length}</a></div>
      ${list.slice(0, limit || list.length).map(markRow).join('')}
    </div>`;
    bindMarks(box);
  }

  function renderLocal(box, books) {
    if (!books.length) {
      box.innerHTML = `<div class="mine-card glass-card">
        <div class="mc-head"><b>本地书</b><span class="mc-sub">TXT / EPUB</span></div>
        <p class="mc-empty">点上面「导入本地书」，断网也能读</p>
      </div>`;
      return;
    }
    box.innerHTML = `<div class="mine-card glass-card">
      <div class="mc-head"><b>本地书</b><span class="mc-sub">${books.length} 本 · 不联网</span></div>
      ${books.map((b) => `<div class="mk-row">
        <span class="mk-tag loc">本地</span>
        <div class="mk-main">
          <div class="mk-title">${esc(b.title)}</div>
          <div class="mk-sub">${esc(b.author || '佚名')} · ${b.count} 章</div>
        </div>
        <button class="mk-go" data-local-go="${esc(b.id)}">阅读</button>
        <button class="mk-del" data-local-del="${esc(b.id)}" title="删除">${ICONS.close}</button>
      </div>`).join('')}
    </div>`;
    box.querySelectorAll('[data-local-go]').forEach((b) => {
      b.addEventListener('click', () => go(`#/read/${encodeURIComponent(b.dataset.localGo)}`));
    });
    box.querySelectorAll('[data-local-del]').forEach((b) => {
      b.addEventListener('click', () => {
        const id = b.dataset.localDel;
        askConfirm('删除这本本地书？文件会被移除，阅读进度也不再保留。', '删除', async () => {
          const r = await post('/api/local/delete', { bookId: id });
          if (r.shelf) state.shelf = r.shelf;
          if (r.marks) state.marks = r.marks;
          toast('已删除');
          viewMine();
        });
      });
    });
  }

  function renderDownloads(box, downloads) {
    const list = Object.values(downloads || {}).sort((a, b) => (b.ts || 0) - (a.ts || 0));
    if (!list.length) {
      box.innerHTML = `<div class="mine-card glass-card">
        <div class="mc-head"><b>下载的书</b></div>
        <p class="mc-empty">打开一本书，右上「更多」→「下载本书」可整本缓存</p>
      </div>`;
      return;
    }
    box.innerHTML = `<div class="mine-card glass-card">
      <div class="mc-head"><b>下载的书</b><span class="mc-sub">${list.length} 本</span></div>
      ${list.map((d) => `<div class="mk-row">
        <span class="mk-tag dl">下载</span>
        <div class="mk-main" data-dl-go="${esc(d.id)}">
          <div class="mk-title">${esc(d.title)}</div>
          <div class="mk-sub">${esc(d.author || '')}${d.failed ? ` · 已存 ${d.total - d.failed}/${d.total} 章` : ` · 已存 ${d.total} 章`}</div>
        </div>
        <button class="mk-go" data-dl-read="${esc(d.id)}">阅读</button>
        <button class="mk-del" data-dl-del="${esc(d.id)}" title="删除下载记录">${ICONS.close}</button>
      </div>`).join('')}
    </div>`;
    box.querySelectorAll('[data-dl-read]').forEach((b) => {
      b.addEventListener('click', () => go(`#/read/${encodeURIComponent(b.dataset.dlRead)}`));
    });
    box.querySelectorAll('[data-dl-del]').forEach((b) => {
      b.addEventListener('click', async () => {
        await post('/api/downloads', { bookId: b.dataset.dlDel });
        toast('已删除下载记录');
        viewMine();
      });
    });
  }

  function viewMine() {
    setNav('mine');
    view.innerHTML = `
      <div class="page">
        <div class="page-head glass-head">
          <div>
            <h1 class="h1">我的</h1>
            <div class="sub">阅读统计 · 本地书 · 备份</div>
          </div>
        </div>
        <div id="mine-stats"></div>
        <div id="mine-history"></div>
        <div class="mine-actions glass-pill">
          <button class="g-text" id="mine-import">导入本地书</button>
          <i class="g-sep"></i>
          <button class="g-text" id="mine-backup">备份</button>
          <i class="g-sep"></i>
          <button class="g-text" id="mine-restore">恢复</button>
        </div>
        <div class="mine-actions glass-pill theme-pill" id="mine-theme">
          <button class="g-text" data-theme-opt="auto">跟随系统</button>
          <i class="g-sep"></i>
          <button class="g-text" data-theme-opt="light">浅色</button>
          <i class="g-sep"></i>
          <button class="g-text" data-theme-opt="dark">深色</button>
        </div>
        <div id="mine-marks"></div>
        <div id="mine-local"></div>
        <div id="mine-downloads"></div>
        <div id="mine-cache"></div>
        <div id="mine-lan"></div>
        <div id="mine-health"></div>
      </div>`;
    $('#mine-import').addEventListener('click', importLocalBook);
    $('#mine-backup').addEventListener('click', exportBackup);
    $('#mine-restore').addEventListener('click', restoreBackup);
    $('#mine-theme').querySelectorAll('[data-theme-opt]').forEach((b) => {
      b.addEventListener('click', () => setAppTheme(b.dataset.themeOpt || 'auto'));
    });
    applyTheme();   // 页面重建后补一次选中态

    api('/api/stats').then(renderStats).catch(() => {});
    api('/api/history').then((d) => renderHistory($('#mine-history'), d.history || [])).catch(() => {});
    renderMarks($('#mine-marks'), 5);
    loadCacheCard();
    loadHealth(false);
    Promise.all([
      api('/api/local/list').catch(() => ({ books: [] })),
      api('/api/downloads').catch(() => ({ downloads: {} })),
      api('/api/lan').catch(() => null),
    ]).then(([local, dl, lan]) => {
      renderLocal($('#mine-local'), local.books || []);
      renderDownloads($('#mine-downloads'), dl.downloads || {});
      const lanBox = $('#mine-lan');
      if (lan && lan.lan && lan.ips && lan.ips.length) {
        lanBox.innerHTML = `
          <div class="lan-card">
            <b>手机 / 平板阅读</b>
            <p>同一 WiFi 下，用浏览器访问：<code>http://${esc(lan.ips[0])}:${esc(lan.port)}</code></p>
            <p class="s">在 iPhone Safari 打开后「分享 → 添加到主屏幕」，即可像 app 一样全屏使用</p>
          </div>`;
      }
    });
  }

  // ---------------------------------------------------------------- 视图：全部书签与笔记
  function viewMarks() {
    setNav('mine');
    const list = (state.marks || []).slice().sort((a, b) => (b.ts || 0) - (a.ts || 0));
    view.innerHTML = `<div class="page">
      <div class="marks-head">
        <a class="g-circle" href="#/mine" title="返回">${ICONS.back}</a>
        <div class="mh-title">书签与笔记<span>${list.length}</span></div>
        <span style="width:40px"></span>
      </div>
      <div id="marks-list"></div>
    </div>`;
    const box = $('#marks-list');
    if (!list.length) {
      box.innerHTML = `<div class="empty"><div class="ic">🔖</div>
        <p>还没有书签<br>阅读器右上「更多」可加书签，长按正文可以划线记笔记</p></div>`;
      return;
    }
    box.innerHTML = `<div class="mine-card glass-card">${list.map(markRow).join('')}</div>`;
    bindMarks(box);
  }

  // ---------------------------------------------------------------- 路由分发
  async function render() {
    const { parts, q } = parseHash();
    const page = parts[0] || 'shelf';
    if (page === 'read') {
      const id = parts[1];
      const idx = parts[2] != null ? Number(parts[2]) : null;
      if (!reader.hidden && R.book && R.book.id === id && idx == null) return;
      await openReader(id, idx);
      return;
    }
    if (!reader.hidden) closeReader();
    document.body.style.overflow = ''; // 阅读器使用独立滚动容器
    // 搜索页像图 2 一样是沉浸式整页，收起底部标签栏
    document.body.classList.toggle('no-tabbar', page === 'search');
    // 离开书架页时退出管理模式，避免下次回来还停在勾选状态
    if (page !== 'shelf' && shelfManage) exitShelfManage();
    if (page === 'shelf') viewShelf();
    else if (page === 'mine') viewMine();
    else if (page === 'marks') viewMarks();
    else if (page === 'discover') viewDiscover(q);
    else if (page === 'list') viewList(q);
    else if (page === 'rank') viewRank(q);
    else if (page === 'qm') viewQm(q);
    else if (page === 'sq') viewSq(q);
    else if (page === 'qb') viewQb(q);
    else if (page === 'bc') viewBc(q);
    else if (page === 'bl') viewBl(q);
    else if (page === 'dq') viewDq(q);
    else if (page === 'ali') viewAli(q);
    else if (page === 'search') viewSearch(q);
    else if (page === 'book') await viewBook(parts[1]);
    else go('#/shelf');
  }

  // 屏蔽浏览器原生右键菜单（输入框内保留，方便粘贴）
  document.addEventListener('contextmenu', (e) => {
    const t = e.target;
    const editable = t.closest ? t.closest('input, textarea, [contenteditable]') : /^(INPUT|TEXTAREA)$/.test(t.tagName);
    if (!editable) e.preventDefault();
  });

  window.addEventListener('hashchange', render);

  // ---------------------------------------------------------------- 启动
  (async function init() {
    try {
      await loadState();
    } catch (e) {
      toast('读取本地数据失败');
    }
    applyTheme();   // 拿到设置后再定一次浅色/深色（内联脚本只负责首屏不闪白）
    applySettings();
    if (!location.hash) location.hash = '#/shelf';
    render();
    setInterval(() => fetch('/api/ping').catch(() => {}), 20000);
    // 启动后静默检查一次追更（10 分钟内查过就直接复用结果，不会每次拉目录）
    setTimeout(() => { loadUpdates(false, false); }, 1200);
  })();
})();
