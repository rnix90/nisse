/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Brand art review page. No framework, no build step, no network requests except to this local server.
   All DOM is built with createElement/textContent, so file names and comments can never inject markup. */
(function () {
  'use strict';

  const LOCAL_KEY = 'brandart-state-v1';
  const VERDICTS = [['keep', 'Keep'], ['redraw', 'Redraw'], ['drop', 'Drop'], ['variant', 'New variant']];
  const PRIORITIES = [['', 'Priority...'], ['must', 'Must have'], ['should', 'Should have'], ['nice', 'Nice to have']];
  const KEY_VERDICT = { '1': 'keep', '2': 'redraw', '3': 'drop', '4': 'variant', '0': '' };

  let inv = null;            // inventory.json
  let state = null;          // comments: {direction, items, groups, custom}
  let groupId = null;        // selected group
  let focusId = null;        // card with keyboard focus
  let saveTimer = null;
  let retryTimer = null;
  let saving = false;
  let dirtyAgain = false;

  const $ = (sel) => document.querySelector(sel);
  const el = (tag, props, ...kids) => {
    const node = document.createElement(tag);
    Object.entries(props || {}).forEach(([k, v]) => {
      if (k === 'class') node.className = v;
      else if (k === 'text') node.textContent = v;
      else if (k.startsWith('data-') || k.startsWith('aria-')) node.setAttribute(k, v);
      else node[k] = v;
    });
    kids.flat().forEach((kid) => kid != null && node.append(kid));
    return node;
  };

  // ------------------------------------------------------------ state and saving

  function clock() {
    const d = new Date();
    return [d.getHours(), d.getMinutes(), d.getSeconds()].map((n) => String(n).padStart(2, '0')).join(':');
  }

  function setSaveState(name, text) {
    const s = $('#save-state');
    s.dataset.state = name;
    s.textContent = text;
  }

  function storeLocal(dirty) {
    try { localStorage.setItem(LOCAL_KEY, JSON.stringify({ state, dirty })); } catch (e) { /* private window: fine */ }
  }

  function loadLocal() {
    try { return JSON.parse(localStorage.getItem(LOCAL_KEY)); } catch (e) { return null; }
  }

  function changed() {
    storeLocal(true);
    setSaveState('saving', 'Saving...');
    clearTimeout(saveTimer);
    saveTimer = setTimeout(flush, 400);
  }

  async function flush() {
    clearTimeout(saveTimer);
    clearTimeout(retryTimer);
    if (saving) { dirtyAgain = true; return; }
    saving = true;
    try {
      do {
        dirtyAgain = false;
        const r = await fetch('/api/state', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(state) });
        if (!r.ok) throw new Error(((await r.json().catch(() => ({}))).error) || ('HTTP ' + r.status));
      } while (dirtyAgain);
      storeLocal(false);
      setSaveState('saved', 'Saved ' + clock());
    } catch (e) {
      setSaveState('error', 'NOT SAVED (' + e.message + ') - retrying');
      retryTimer = setTimeout(flush, 3000);
    } finally {
      saving = false;
    }
  }

  function entry(id) {
    return state.items[id] || { verdict: '', priority: '', comment: '' };
  }

  function marked(id) {
    const e = state.items[id];
    return !!(e && (e.verdict || e.priority || e.comment));
  }

  function setItem(id, patch) {
    const next = Object.assign({}, entry(id), patch);
    if (next.verdict || next.priority || next.comment) state.items[id] = next;
    else delete state.items[id];
    changed();
  }

  // ------------------------------------------------------------ what is shown

  function allItems() {
    return inv.groups.flatMap((g) => g.items.map((i) => Object.assign({ groupId: g.id }, i)));
  }

  function visibleItems() {
    const q = $('#search').value.trim().toLowerCase();
    let items;
    if (q) {
      items = allItems().filter((i) => [i.title, i.id, i.source || '', i.seen, i.owner].join(' ').toLowerCase().includes(q));
    } else {
      const g = inv.groups.find((x) => x.id === groupId);
      items = g ? g.items.map((i) => Object.assign({ groupId: g.id }, i)) : [];
    }
    if ($('#only-uncommented').checked) items = items.filter((i) => !marked(i.id));
    if ($('#only-redraw').checked) items = items.filter((i) => entry(i.id).verdict === 'redraw');
    const kind = $('#kind').value;
    if (kind) items = items.filter((i) => i.kind === kind);
    return items;
  }

  function renderGroups() {
    const ul = $('#groups ul');
    ul.replaceChildren();
    inv.groups.forEach((g) => {
      const done = g.items.filter((i) => marked(i.id)).length;
      const pct = g.items.length ? Math.round((100 * done) / g.items.length) : 0;
      const bar = el('span', { class: 'progress' }, el('i', { style: 'width:' + pct + '%' }));
      const btn = el('button', { type: 'button', title: done + ' of ' + g.items.length + ' marked' },
        g.title, el('span', { class: 'count', text: done + '/' + g.items.length }), bar);
      btn.addEventListener('click', () => { $('#search').value = ''; groupId = g.id; focusId = null; render(); });
      ul.append(el('li', { 'data-group': g.id, class: g.id === groupId && !$('#search').value ? 'active' : '' }, btn));
    });
  }

  function renderHead() {
    const searching = !!$('#search').value.trim();
    const g = inv.groups.find((x) => x.id === groupId);
    $('#group-title').textContent = searching ? 'Search results' : (g ? g.title : '');
    $('#group-seen').textContent = searching ? 'Items from every group matching your search.' : (g ? 'Where you see it: ' + g.seen : '');
    const box = $('#group-comment');
    box.hidden = searching || !g;
    box.value = g && state.groups[g.id] ? state.groups[g.id].comment : '';
  }

  function previewNode(item) {
    const box = el('div', { class: 'preview' });
    if (item.kind === 'missing') {
      box.append(el('div', { class: 'nopreview', text: 'No graphic today: a request for new art' }));
    } else if (item.kind === 'sound' && item.audio) {
      box.append(el('audio', { controls: true, preload: 'none', src: '/' + item.audio }));
    } else if (item.preview) {
      const img = el('img', { alt: item.title, loading: 'lazy', decoding: 'async' });
      img.src = '/' + item.preview;
      img.addEventListener('error', () => box.replaceChildren(el('div', { class: 'nopreview', text: 'Preview could not be loaded' })));
      box.append(img);
    } else {
      box.append(el('div', { class: 'nopreview', text: 'No preview for this kind (' + item.kind + ')' }));
    }
    return box;
  }

  function cardNode(item) {
    const e = entry(item.id);
    const card = el('article', { class: 'card' + (item.kind === 'missing' ? ' missing' : '') + (item.id === focusId ? ' focus' : ''), 'data-id': item.id });
    const size = item.width && item.height ? item.width + 'x' + item.height : null;
    const meta = el('div', { class: 'meta' }, el('span', { class: 'badge', text: item.kind }), size && el('span', { text: size }),
      item.duration && el('span', { text: item.duration.toFixed(1) + ' s' }),
      item.owner && el('span', { class: 'badge', title: item.license || '', text: item.owner + (item.license ? ' (' + item.license + ')' : '') }),
      item.variants && item.variants.length ? el('span', { text: item.variants.length + ' variant file' + (item.variants.length > 1 ? 's' : '') }) : null);
    const verdict = el('div', { class: 'verdict' });
    VERDICTS.forEach(([value, label]) => {
      const b = el('button', { type: 'button', text: label, 'data-verdict': value, 'aria-pressed': String(e.verdict === value) });
      b.addEventListener('click', () => { setItem(item.id, { verdict: entry(item.id).verdict === value ? '' : value }); render(true); });
      verdict.append(b);
    });
    const priority = el('select', { class: 'priority', 'aria-label': 'Priority' });
    PRIORITIES.forEach(([value, label]) => priority.append(el('option', { value, text: label })));
    priority.value = e.priority;
    priority.addEventListener('change', () => { setItem(item.id, { priority: priority.value }); renderGroups(); });
    const comment = el('textarea', { class: 'comment', rows: 3, placeholder: 'What is wrong with it? What should it be instead?' });
    comment.value = e.comment;
    comment.addEventListener('input', () => { setItem(item.id, { comment: comment.value }); renderGroups(); });
    // append() turns null into the text "null", so absent parts are filtered out first
    card.append(...[el('div', { class: 'title', text: item.title }), previewNode(item), meta,
      el('div', { class: 'seen', text: item.seen }),
      item.source ? el('div', { class: 'src', text: item.source }) : null,
      item.note ? el('div', { class: 'note', text: item.note }) : null,
      verdict, priority, comment].filter(Boolean));
    card.addEventListener('focusin', () => { focusId = item.id; document.querySelectorAll('#cards .card.focus').forEach((c) => c.classList.remove('focus')); card.classList.add('focus'); });
    return card;
  }

  function renderCards() {
    const items = visibleItems();
    const box = $('#cards');
    box.replaceChildren(...items.map(cardNode));
    if (!items.length) box.append(el('p', { class: 'empty', text: 'Nothing to show with these filters.' }));
  }

  function customNode(c) {
    const title = el('input', { class: 'title', placeholder: 'What should be drawn?', value: c.title });
    title.addEventListener('input', () => { c.title = title.value; changed(); });
    const comment = el('textarea', { class: 'comment', rows: 2, placeholder: 'Describe it: where it is seen, size, style...' });
    comment.value = c.comment;
    comment.addEventListener('input', () => { c.comment = comment.value; changed(); });
    const remove = el('button', { type: 'button', text: 'Remove' });
    remove.addEventListener('click', () => { state.custom = state.custom.filter((x) => x !== c); changed(); renderCustom(); });
    return el('div', { class: 'custom', 'data-id': c.id }, title, comment, remove);
  }

  function renderCustom() {
    $('#custom-list').replaceChildren(...state.custom.map(customNode));
  }

  function render(keepScroll) {
    const y = window.scrollY;
    renderGroups();
    renderHead();
    renderCards();
    if (keepScroll) window.scrollTo(0, y);
  }

  // ------------------------------------------------------------ keyboard

  function moveFocus(step) {
    const cards = [...document.querySelectorAll('#cards .card')];
    if (!cards.length) return;
    let i = cards.findIndex((c) => c.dataset.id === focusId);
    i = i < 0 ? (step > 0 ? 0 : cards.length - 1) : Math.max(0, Math.min(cards.length - 1, i + step));
    focusId = cards[i].dataset.id;
    cards.forEach((c) => c.classList.toggle('focus', c === cards[i]));
    cards[i].scrollIntoView({ block: 'nearest' });
  }

  document.addEventListener('keydown', (ev) => {
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
    const t = ev.target;
    if (t && /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)) return;
    if (ev.key === 'j') { moveFocus(1); ev.preventDefault(); }
    else if (ev.key === 'k') { moveFocus(-1); ev.preventDefault(); }
    else if (ev.key in KEY_VERDICT && focusId) { setItem(focusId, { verdict: KEY_VERDICT[ev.key] }); render(true); ev.preventDefault(); }
    else if (ev.key === 'c' && focusId) {
      const box = document.querySelector('#cards .card.focus textarea.comment');
      if (box) { box.focus(); ev.preventDefault(); }
    }
  });

  // ------------------------------------------------------------ export

  async function doExport() {
    clearTimeout(saveTimer);
    await flush();
    const panel = $('#export-panel');
    try {
      const r = await fetch('/api/export', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
      const data = await r.json();
      if (!r.ok) throw new Error(data.error || ('HTTP ' + r.status));
      $('#export-path').textContent = 'Written to ' + data.path + ' (' + data.copied + ' original file' + (data.copied === 1 ? '' : 's') + ' copied next to it).';
      $('#export-md').textContent = data.markdown;
    } catch (e) {
      $('#export-path').textContent = 'Export failed: ' + e.message;
      $('#export-md').textContent = '';
    }
    panel.hidden = false;
    panel.scrollIntoView({ block: 'start' });
  }

  // ------------------------------------------------------------ start

  async function boot() {
    const [invRes, stateRes] = await Promise.all([fetch('/api/inventory'), fetch('/api/state')]);
    if (!invRes.ok) {
      document.body.prepend(el('p', { class: 'empty', text: 'No inventory yet: run  bash tools/brandart/extract_in_vm.sh  and  python tools/brandart/previews.py out/brandart' }));
      return;
    }
    inv = await invRes.json();
    state = await stateRes.json();
    const local = loadLocal();
    if (local && local.dirty && local.state) { state = local.state; flush(); }
    groupId = inv.groups.length ? inv.groups[0].id : null;

    const image = inv.image || {};
    $('#image-info').textContent = (image.iso || 'image') + (image.built ? ', built ' + image.built : '') + (image.sha256 ? ', ' + String(image.sha256).slice(0, 8) : '');
    const kinds = [...new Set(allItems().map((i) => i.kind))].sort();
    kinds.forEach((k) => $('#kind').append(el('option', { value: k, text: k })));
    if (inv.notes && inv.notes.length) {
      const d = $('#notes');
      d.hidden = false;
      d.querySelector('summary').textContent = 'Inventory notes (' + inv.notes.length + ')';
      inv.notes.forEach((n) => d.querySelector('ul').append(el('li', { text: n })));
    }

    $('#direction').value = state.direction || '';
    $('#direction').addEventListener('input', () => { state.direction = $('#direction').value; changed(); });
    $('#group-comment').addEventListener('input', () => {
      const text = $('#group-comment').value;
      if (text) state.groups[groupId] = { comment: text }; else delete state.groups[groupId];
      changed();
    });
    $('#bg').addEventListener('change', () => { document.body.dataset.bg = $('#bg').value; });
    ['#search', '#only-uncommented', '#only-redraw', '#kind'].forEach((s) => $(s).addEventListener('input', () => render()));
    $('#add-request').addEventListener('click', () => {
      state.custom.push({ id: 'custom-' + Date.now(), title: '', comment: '' });
      changed();
      renderCustom();
      const inputs = document.querySelectorAll('#custom-list input.title');
      if (inputs.length) inputs[inputs.length - 1].focus();
    });
    $('#export').addEventListener('click', doExport);
    renderCustom();
    render();
    // No beforeunload handler on purpose: every change is copied to localStorage by changed() the moment it happens, and a
    // handler that marked the page's state "unsaved" on unload would let a stale tab overwrite newer comments from another tab.
  }

  boot();
})();
