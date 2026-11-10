/* 速读谷桌面阅读器 —— 前端逻辑 */
(() => {
  'use strict';

  const $ = (s, r = document) => r.querySelector(s);
  const view = $('#view');
  const reader = $('#reader');

  const state = { shelf: {}, progress: {}, settings: {}, history: [], home: null };
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
  };
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
  function askConfirm(msg, okLabel, onOk) {
    const mask = document.createElement('div');
    mask.className = 'glass-mask';
    mask.innerHTML = `<div class="glass-dialog">
      <div class="gd-msg">${esc(msg)}</div>
      <div class="gd-actions">
        <button class="g-text" data-no>取消</button>
        <button class="g-text danger" data-yes>${esc(okLabel)}</button>
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

  async function addShelf(book) {
    const payload = {
      id: book.id, title: book.title, cover: book.cover,
      author: book.author || '', category: book.category || '', status: book.status || '',
    };
    const r = await post('/api/shelf', { op: 'add', book: payload });
    state.shelf = r.shelf;
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

  const shelfCard = (b, mg = false, sel = false) => {
    const p = b.progress || {};
    const pct = Math.max(0, Math.min(100, Math.round((p.ratio || 0) * 100)));
    const extra = `${p.i ? `<div class="prog"><i style="width:${pct}%"></i></div>` : ''}`;
    const sub = p.t ? `读到 ${esc(p.t)}` : '尚未开始';
    const meta = `${b.count ? `${b.count} 章 · ` : ''}${esc(b.source || '')}书源`;
    const tag = mg ? 'div' : 'a';
    const attrs = mg ? `data-pick="${esc(b.id)}"` : `href="#/read/${b.id}"`;
    return `
      <${tag} class="card ${mg ? 'manage' : ''} ${sel ? 'picked' : ''}" ${attrs}>
        ${coverBox(b, extra)}
        <div class="t">${esc(b.title)}</div>
        <div class="s">${sub}</div>
        <div class="m">${meta}</div>
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
      ? `<span class="unread ${unread >= 20 ? 'hot' : ''}">${unread > 99 ? '99+' : unread}</span>` : '';
    const src = b.source || srcNameById(b.id) || '速读谷';
    const ago = relTime(b.lastRead);
    const extra = '<span class="cv-tag">小说</span>';
    const tag = mg ? 'div' : 'a';
    const attrs = mg ? `data-pick="${esc(b.id)}"` : `href="#/read/${b.id}"`;
    return `<${tag} class="sl-card ${mg ? 'manage' : ''} ${sel ? 'picked' : ''}" ${attrs}>
      ${coverBox(b, extra)}
      <div class="sl-body">
        <div class="sl-title">${esc(b.title)}</div>
        <div class="sl-line">${esc(b.author || '佚名')} · 共${b.count ? b.count + '章' : '—章'}</div>
        <div class="sl-line">${p.t ? `已读：第${readI}章 ${esc(chapterLabel(p.t))}` : '尚未开始阅读'}</div>
        <div class="sl-line">来源：${esc(src)}</div>
        <div class="sl-line sl-last">${ago ? esc(ago) + ' · ' : ''}${p.t ? `第${readI}章 ${esc(chapterLabel(p.t))}` : '暂无更新'}</div>
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

  // 书架管理：三点菜单进入 → 多选 → 批量移出（卡片上不再放单本删除按钮）
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
  function viewShelf() {
    setNav('shelf');
    const mobile = window.matchMedia('(max-width: 640px)').matches;
    const layout = shelfPref('shelfLayout', mobile ? 'list' : 'grid');
    const sort = shelfPref('shelfSort', 'recent');
    const filter = shelfPref('shelfFilter', 'all');
    const all = Object.values(state.shelf);
    if (shelfManage && !all.length) exitShelfManage();
    let books = filter === 'all' ? all.slice()
      : all.filter((b) => (b.source || srcNameById(b.id)) === filter);
    books.sort((a, b) => {
      if (sort === 'title') return String(a.title || '').localeCompare(String(b.title || ''), 'zh');
      if (sort === 'added') return (b.added || 0) - (a.added || 0);
      return (b.lastRead || 0) - (a.lastRead || 0);
    });
    const sources = [...new Set(all.map((b) => b.source || srcNameById(b.id)).filter(Boolean))];
    const body = books.length
      ? layout === 'list'
        ? `<div class="shelf-list">${books.map((b) => shelfListCard(b, shelfManage, shelfPicked.has(b.id))).join('')}</div>`
        : `<div class="grid">${books.map((b) => shelfCard(b, shelfManage, shelfPicked.has(b.id))).join('')}</div>`
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
        <button class="g-text sm danger" id="mg-del" ${pickedN ? '' : 'disabled'}>删除</button>
        <button class="g-text sm" id="mg-done">完成</button>
      </div></div>` : '';

    view.innerHTML = `
      <div class="page">
        <div class="page-head glass-head">
          <div>
            <h1 class="h1">书架</h1>
            <div class="sub">${books.length ? `共 ${books.length} 本 · 阅读进度自动保存` : '收藏的书会出现在这里'}</div>
          </div>
          <div class="glass-pill shelf-tools">
            <button class="g-text" id="shelf-filter" data-pop title="按书源筛选"><span>${filter === 'all' ? '全部' : esc(filter)}</span>${ICONS.chev}</button>
            <i class="g-sep"></i>
            <button class="g-ico" id="shelf-layout" title="${layout === 'list' ? '切换为网格' : '切换为列表'}">${layout === 'list' ? ICONS.grid : ICONS.list}</button>
            <a class="g-ico" href="#/search" title="搜索" aria-label="搜索">${ICONS.search}</a>
            <button class="g-ico" id="shelf-more" data-pop title="书架选项">${ICONS.dots}</button>
          </div>
        </div>
        ${manageBar}
        ${body}
      </div>`;

    $('#shelf-layout').addEventListener('click', () => {
      setShelfPref('shelfLayout', layout === 'list' ? 'grid' : 'list');
    });
    $('#shelf-filter').addEventListener('click', (e) => {
      e.stopPropagation();
      const clearPick = () => { shelfPicked.clear(); };
      togglePop(e.currentTarget, 'shelf-filter', [
        { label: '全部', on: filter === 'all', run: () => { clearPick(); setShelfPref('shelfFilter', 'all'); } },
        ...sources.map((s) => ({ label: s, on: filter === s,
          run: () => { clearPick(); setShelfPref('shelfFilter', s); } })),
      ], '按书源筛选');
    });
    $('#shelf-more').addEventListener('click', (e) => {
      e.stopPropagation();
      togglePop(e.currentTarget, 'shelf-more', [
        { label: '最近阅读', on: sort === 'recent', run: () => setShelfPref('shelfSort', 'recent') },
        { label: '按书名', on: sort === 'title', run: () => setShelfPref('shelfSort', 'title') },
        { label: '加入时间', on: sort === 'added', run: () => setShelfPref('shelfSort', 'added') },
        { sep: true },
        { label: shelfManage ? '退出管理' : '管理书架', run: () => {
          if (shelfManage) exitShelfManage();
          else { shelfManage = true; shelfPicked.clear(); }
          viewShelf();
        } },
      ], '书架选项');
    });

    if (shelfManage) {
      view.querySelectorAll('[data-pick]').forEach((el) => {
        el.addEventListener('click', () => {
          const id = el.dataset.pick;
          if (shelfPicked.has(id)) shelfPicked.delete(id); else shelfPicked.add(id);
          viewShelf();
        });
      });
      $('#mg-all').addEventListener('click', () => {
        if (books.length && pickedN === books.length) shelfPicked.clear();
        else books.forEach((b) => shelfPicked.add(b.id));
        viewShelf();
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
      togglePop(e.currentTarget, 'search-src', SEARCH_SOURCES.map(([k, n]) => ({
        label: n, on: k === $('#ssrc').value,
        run: () => {
          $('#ssrc').value = k;
          try { localStorage.setItem(SEARCH_SRC_KEY, k); } catch (_) { /* 忽略 */ }
          const v = $('#sq').value.trim();
          go(v ? `#/search?src=${k}&q=${encodeURIComponent(v)}` : `#/search?src=${k}`);
        },
      })), '选择书源');
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
      const cnt = (name) => data.books.filter((b) => b.source === name).length;
      const mix = [['速读谷', cnt('速读谷')], ['七猫', cnt('七猫')], ['书旗', cnt('书旗')],
        ['全本网', cnt('全本小说网')], ['八叉', cnt('八叉书库')], ['八一', cnt('八一中文网')],
        ['得奇', cnt('得奇小说网')], ['爱丽丝', cnt('爱丽丝书屋')]]
        .filter(([, n]) => n).map(([name, n]) => `${name} ${n} 本`).join(' · ');
      box.innerHTML = failNote +
        `<p class="rank-note">共 ${data.books.length} 本${mix ? `（${mix}）` : ''}</p>` +
        `<div class="list">${data.books.map((b) => `
        <a class="item" href="#/book/${encodeURIComponent(b.id)}">
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
        </a>`).join('')}</div>`;
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
              <span class="tag src">${esc(b.source || '速读谷')}书源</span>
            </div>
            <div class="who">作者：<b>${esc(b.author || '佚名')}</b>
              ${b.publisher ? `<span class="who-src">版权方：${esc(b.publisher)}</span>` : ''}</div>
            <div class="actions">
              <button class="btn" id="b-read">${p && p.i ? `继续阅读 · ${esc(p.t || '')}` : '开始阅读'}</button>
              <button class="btn ghost ${on ? 'on' : ''}" id="b-shelf">${on ? '已在书架' : '加入书架'}</button>
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
  };

  const rEl = {
    scroll: $('#r-scroll'), article: $('#r-article'), end: $('#r-end'),
    pct: $('#r-pct'), page: $('#r-page'), slider: $('#r-slider'),
    drawer: $('#r-drawer'),
    toc: $('#toc-list'), set: $('#r-set'), prev: $('#r-prev'), next: $('#r-next'),
    bottom: $('#r-bottom'),
  };

  // ---- 分页布局：正文横向分栏，每栏一页 ----
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
    a.style.columnWidth = (pw - 2 * M) + 'px';
    a.style.columnGap = (2 * M) + 'px';
    a.style.padding = (mobile ? 22 + sat : 44) + 'px ' + M + 'px '
                    + (mobile ? 22 + sab : 44) + 'px';
    R.pages = Math.max(1, Math.round(a.scrollWidth / pw));
  }

  function goToPage(p, opts = {}) {
    R.page = Math.min(R.pages, Math.max(1, p));
    const x = (R.page - 1) * R.pw;
    if (opts.instant) rEl.article.style.transition = 'none';
    rEl.article.style.transform = `translateX(${-x}px)`;
    if (opts.instant) { void rEl.article.offsetHeight; rEl.article.style.transition = ''; }
    updatePos();
    if (!opts.noSave) saveProgress();
  }

  // 设置或窗口变化后重排，按原比例恢复页码
  function relayout() {
    if (reader.hidden || !R.pw) return;
    const ratio = R.pages > 1 ? (R.page - 1) / (R.pages - 1) : 0;
    layout();
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
    rEl.article.dataset.font = s.font || 'serif';
    $('#fs-val').textContent = s.fs || 19;
    $('#set-lh').value = Math.round((s.lh || 1.95) * 100);
    $('#set-w').value = s.w || 720;
    document.querySelectorAll('#set-font button').forEach((b) => b.classList.toggle('on', (s.font || 'serif') === b.dataset.font));
    document.querySelectorAll('#set-theme button').forEach((b) => b.classList.toggle('on', (s.theme || 'paper') === b.dataset.theme));
  }

  function setSetting(k, v) {
    state.settings[k] = v;
    applySettings();
    saveSettings();
    relayout(); // 字号/行距/页宽变化后重新分页
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
    rEl.article.innerHTML =
      `<h1>${esc(data.title || c.t)}</h1>` +
      data.paras.map((p) => `<p>${esc(p)}</p>`).join('');
    rEl.article.appendChild(rEl.end);
    layout();
    const target = restoreRatio > 0 && R.pages > 1
      ? Math.round(restoreRatio * (R.pages - 1)) + 1 : 1;
    goToPage(target, { instant: true, noSave: true });
    saveProgress(true);
    // 预取下一章
    if (i + 1 < R.chapters.length) {
      fetch(`/api/chapter?u=${encodeURIComponent(R.chapters[i + 1].u)}`).catch(() => {});
    }
  }

  function updatePos() {
    const i = R.index, n = R.chapters.length;
    rEl.prev.disabled = i <= 0;
    rEl.next.disabled = i >= n - 1;
    // 左下角：全书进度百分比
    const pct = Math.round(((i + 1) / Math.max(1, n)) * 100);
    rEl.pct.textContent = `${pct}%`;
    // 右下角：本章真实页码
    rEl.page.textContent = `${R.page} / ${R.pages}`;
    // 同步翻页滑杆（拖动中不覆盖）
    if (document.activeElement !== rEl.slider) {
      rEl.slider.value = R.pages > 1 ? Math.round(((R.page - 1) / (R.pages - 1)) * 1000) : 0;
    }
  }

  // 滑杆拖动 → 翻到对应页
  rEl.slider.addEventListener('input', () => {
    const p = R.pages > 1 ? Math.round((Number(rEl.slider.value) / 1000) * (R.pages - 1)) + 1 : 1;
    goToPage(p);
  });

  function currentRatio() {
    return R.pages > 1 ? (R.page - 1) / (R.pages - 1) : 1;
  }

  function saveProgress(immediate = false) {
    if (!R.book || !R.chapter) return;
    const doSave = async () => {
      const payload = {
        bookId: R.book.id, u: R.chapter.url || R.chapters[R.index]?.u,
        t: R.chapter.title || R.chapters[R.index]?.t, i: R.index,
        n: R.chapters.length, ratio: currentRatio(),
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
      if (on) on.scrollIntoView({ block: 'center' });
      $('#toc-filter').focus();
    }
  }

  function renderToc(filter) {
    const kw = (filter || '').trim();
    const list = R.chapters.map((c, i) => ({ c, i }))
      .filter(({ c }) => !kw || c.t.includes(kw))
      .slice(0, 2000);
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

  $('#r-more').addEventListener('click', (e) => {
    e.stopPropagation();
    const menu = $('#r-menu');
    menu.hidden = !menu.hidden;
    if (!menu.hidden) {
      dlPrev = 'none';
      refreshDl();
    }
  });

  $('#r-menu-detail').addEventListener('click', () => {
    const id = R.book?.id;
    $('#r-menu').hidden = true;
    closeReader();
    go(id ? `#/book/${id}` : '#/shelf');
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
        toast('已加入书架');
      }
      updateShelfBtn();
    } catch (e) {
      toast('操作失败：' + e.message);
    }
  });

  // 点正文：左 1/3 上一页，右 1/3 下一页，中间呼出/收起控制面板
  let swiped = false;
  rEl.scroll.addEventListener('click', (e) => {
    if (swiped) { swiped = false; return; }  // 滑动翻页后浏览器还会补一次 click，别重复翻
    if (e.target.closest('button, a, input')) return;
    const sel = window.getSelection ? String(window.getSelection()) : '';
    if (sel.trim()) return; // 正在划词选中，不打断
    const rect = rEl.scroll.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    if (x < 0.3) prevPage();
    else if (x > 0.7) nextPage();
    else toggleUI();
  });

  // 滚轮翻页
  let wheelLock = 0;
  rEl.scroll.addEventListener('wheel', (e) => {
    e.preventDefault();
    const now = Date.now();
    if (now - wheelLock < 260) return;
    const d = Math.abs(e.deltaY) >= Math.abs(e.deltaX) ? e.deltaY : e.deltaX;
    if (Math.abs(d) < 12) return;
    wheelLock = now;
    if (d > 0) nextPage(); else prevPage();
  }, { passive: false });

  // 触屏左右滑动翻页
  let tX = 0, tY = 0;
  rEl.scroll.addEventListener('touchstart', (e) => {
    tX = e.touches[0].clientX; tY = e.touches[0].clientY;
  }, { passive: true });
  rEl.scroll.addEventListener('touchend', (e) => {
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
      else if (e.key === 'PageUp') { e.preventDefault(); prevPage(); }
      else if (e.key === 'PageDown') { e.preventDefault(); nextPage(); }
      else if (e.key.toLowerCase() === 't') { e.preventDefault(); toggleToc(); }
      return;
    }
    const tag = (document.activeElement || {}).tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA') return;
    if (e.key === '/') { e.preventDefault(); go('#/search'); setTimeout(() => $('#sq')?.focus(), 80); }
  });

  // ---------------------------------------------------------------- 视图：我的（下载内容）
  function viewMine() {
    setNav('mine');
    view.innerHTML = `
      <div class="page">
        <div class="page-head">
          <div>
            <h1 class="h1">我的</h1>
            <div class="sub">下载到本地的书，离线也能读</div>
          </div>
        </div>
        <div id="mine-lan"></div>
        <div id="mine-body"><p style="color:var(--muted)">加载中…</p></div>
      </div>`;
    Promise.all([api('/api/downloads'), api('/api/lan').catch(() => null)]).then(([{ downloads }, lan]) => {
      // 手机/平板访问提示（局域网模式启动时有效）
      const lanBox = $('#mine-lan');
      if (lan && lan.lan && lan.ips && lan.ips.length) {
        lanBox.innerHTML = `
          <div class="lan-card">
            <b>手机 / 平板阅读</b>
            <p>同一 WiFi 下，用浏览器访问：<code>http://${esc(lan.ips[0])}:${lan.port}</code></p>
            <p class="s">在 iPhone Safari 打开后「分享 → 添加到主屏幕」，即可像 app 一样全屏使用</p>
          </div>`;
      }
      const body = $('#mine-body');
      const list = Object.values(downloads || {}).sort((a, b) => (b.ts || 0) - (a.ts || 0));
      if (!list.length) {
        body.innerHTML = `
          <div class="empty"><div class="ic">⬇️</div>
            <p>还没有下载的书<br>打开一本书，点右上角「更多」→「下载本书」</p>
          </div>`;
        return;
      }
      body.innerHTML = `<div class="grid">${list.map((d) => {
        const ok = d.total - (d.failed || 0);
        return `
        <div class="card mine-card">
          <a href="#/read/${esc(d.id)}">${coverBox(d)}</a>
          <div class="t">${esc(d.title)}</div>
          <div class="s">${esc(d.author || '')}</div>
          <div class="m">${d.failed ? `已下载 ${ok}/${d.total} 章（${d.failed} 章失败）` : `已下载 ${d.total} 章`}${d.source ? ` · ${esc(d.source)}` : ''}</div>
          <button class="del" data-dldel="${esc(d.id)}" title="删除下载记录">
            <svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>
          </button>
        </div>`;
      }).join('')}</div>`;
      body.querySelectorAll('[data-dldel]').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.preventDefault();
          e.stopPropagation();
          await post('/api/downloads', { bookId: btn.dataset.dldel });
          toast('已删除下载记录');
          viewMine();
        });
      });
    }).catch((e) => {
      $('#mine-body').innerHTML = `<p style="color:var(--muted)">加载失败：${esc(e.message)}</p>`;
    });
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
    applySettings();
    if (!location.hash) location.hash = '#/shelf';
    render();
    setInterval(() => fetch('/api/ping').catch(() => {}), 20000);
  })();
})();
