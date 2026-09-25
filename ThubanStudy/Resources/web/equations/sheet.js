/*
 * Thuban Study — equation sheet page (sheet.html, hosted by EquationSheetWebView).
 *
 *   Swift → JS   load {mode: "sheet"|"panel", groups: [{id, name, entries: [{id, name, note?, equations: [latex]}]}],
 *                      collapsed: [groupId], emptyMessage}
 *                      The groups arrive already filtered by the search field.
 *                focusEntry {id}
 *                theme {css, isDark}                                handled by shared/bridge.js
 *   JS → Swift   ready
 *                edit {entryId}                                     double-click / Enter on a card (sheet mode)
 *                addEntry {groupId}
 *                menu {kind: "entry"|"group"|"equation", groupId, entryId?, index?, x, y}
 *                                                                   right-click, a "…" button or the menu key;
 *                                                                   x/y in page CSS pixels; Swift shows the menu
 *                moveEntry {entryId, groupId, beforeId? | afterId?}   drag and drop; the neighbour the card was dropped
 *                                                                   next to (neither: the end of the group). Ids, not an
 *                                                                   index: the page shows only the entries that match the
 *                                                                   search, the store resolves them in the full order
 *                moveEntryBy {entryId, delta}                       ⌥↑ / ⌥↓
 *                deleteEntry {entryId}                              Delete (Swift asks first)
 *                copyLatex {entryId, index?}                        ⌘C on a card (index: one equation, else all)
 *                toggleGroup {groupId, collapsed}                   panel mode
 *
 * Math is rendered statically by MathLive (convertLatexToMarkup), the same renderer the question and chat pages use.
 */
(function () {
  'use strict';

  const thuban = window.thuban;
  const sheetEl = document.getElementById('sheet');
  const emptyEl = document.getElementById('empty');

  let mode = 'sheet';
  let groups = [];
  let collapsed = new Set();
  let dragged = null;          // {entryId, groupId}
  let pendingFocus = null;

  const ICONS = {
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>',
    more: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="6" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="18" cy="12" r="1.6"/></svg>',
    chevron: '<svg class="chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9.5l6 6 6-6"/></svg>'
  };

  const editable = () => mode === 'sheet';

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  /* ================================================================= math */

  function renderMath(target, latex) {
    const source = String(latex || '');
    try {
      target.innerHTML = window.MathLive.convertLatexToMarkup(source, { mathstyle: 'displaystyle' });
    } catch (err) {
      target.textContent = source;
      target.classList.add('is-invalid');
    }
    let spoken = source;
    try {
      if (typeof window.MathLive.convertLatexToSpeakableText === 'function') {
        spoken = window.MathLive.convertLatexToSpeakableText(source) || source;
      }
    } catch (_) { /* keep the LaTeX */ }
    target.setAttribute('role', 'math');
    target.setAttribute('aria-label', spoken);
  }

  /* =============================================================== render */

  function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }

  function buildCard(entry, group) {
    const card = el('article', 'eq-card');
    card.tabIndex = 0;
    card.dataset.entryId = entry.id;
    card.dataset.groupId = group.id;
    const equations = Array.isArray(entry.equations) ? entry.equations : [];
    let label = entry.name + ', ' + plural(equations.length, 'equation');
    if (entry.note) label += '. ' + entry.note;
    card.setAttribute('aria-label', label);
    card.setAttribute('aria-roledescription', 'equation card');

    const head = el('div', 'eq-head');
    head.appendChild(el('h3', 'eq-name', entry.name));
    const menuBtn = el('button', 'icon-btn card-menu');
    menuBtn.type = 'button';
    menuBtn.innerHTML = ICONS.more;
    menuBtn.setAttribute('aria-label', 'Actions for ' + entry.name);
    menuBtn.tabIndex = -1;
    menuBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      postMenu('entry', group.id, entry.id, null, menuBtn);
    });
    head.appendChild(menuBtn);
    card.appendChild(head);

    const list = el('div', 'eq-list');
    equations.forEach((latex, index) => {
      const row = el('div', 'eq');
      row.dataset.index = String(index);
      renderMath(row, latex);
      row.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        e.stopPropagation();
        card.focus({ preventScroll: true });
        thuban.send('menu', { kind: 'equation', groupId: group.id, entryId: entry.id, index, x: e.clientX, y: e.clientY });
      });
      list.appendChild(row);
    });
    card.appendChild(list);

    if (entry.note) card.appendChild(el('p', 'eq-note', entry.note));

    card.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      card.focus({ preventScroll: true });
      thuban.send('menu', { kind: 'entry', groupId: group.id, entryId: entry.id, x: e.clientX, y: e.clientY });
    });
    card.addEventListener('dblclick', () => { if (editable()) thuban.send('edit', { entryId: entry.id }); });
    card.addEventListener('keydown', (e) => onCardKey(e, card, entry, group));

    if (editable()) {
      card.draggable = true;
      card.addEventListener('dragstart', (e) => {
        dragged = { entryId: entry.id, groupId: group.id };
        card.classList.add('is-dragging');
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', entry.name);
      });
      card.addEventListener('dragend', () => {
        dragged = null;
        card.classList.remove('is-dragging');
        clearDropMarks();
      });
    }
    return card;
  }

  function buildGroup(group) {
    const section = el('section', 'group');
    section.dataset.groupId = group.id;
    const entries = Array.isArray(group.entries) ? group.entries : [];
    const isCollapsed = mode === 'panel' && collapsed.has(group.id);
    if (isCollapsed) section.classList.add('is-collapsed');
    const titleId = 'group-title-' + group.id;
    section.setAttribute('aria-labelledby', titleId);

    const head = el('header', 'group-head');
    const title = el('h2', 'group-title', group.name);
    title.id = titleId;
    const count = el('span', 'group-count', String(entries.length));
    count.setAttribute('aria-label', entries.length === 1 ? '1 entry' : entries.length + ' entries');

    if (mode === 'panel') {
      const toggle = el('button', 'group-toggle');
      toggle.type = 'button';
      toggle.setAttribute('aria-expanded', String(!isCollapsed));
      toggle.setAttribute('aria-controls', 'cards-' + group.id);
      toggle.innerHTML = ICONS.chevron;
      toggle.appendChild(title);
      toggle.appendChild(count);
      toggle.addEventListener('click', () => {
        const nowCollapsed = !section.classList.contains('is-collapsed');
        section.classList.toggle('is-collapsed', nowCollapsed);
        toggle.setAttribute('aria-expanded', String(!nowCollapsed));
        if (nowCollapsed) collapsed.add(group.id); else collapsed.delete(group.id);
        thuban.send('toggleGroup', { groupId: group.id, collapsed: nowCollapsed });
      });
      head.appendChild(toggle);
    } else {
      head.appendChild(title);
      head.appendChild(count);
      head.appendChild(el('span', 'group-rule'));
      const add = el('button', 'add-btn');
      add.type = 'button';
      add.innerHTML = ICONS.plus + '<span>Add equation</span>';
      add.setAttribute('aria-label', 'Add an equation to ' + group.name);
      add.addEventListener('click', () => thuban.send('addEntry', { groupId: group.id }));
      head.appendChild(add);
      const more = el('button', 'icon-btn');
      more.type = 'button';
      more.innerHTML = ICONS.more;
      more.setAttribute('aria-label', 'Actions for group ' + group.name);
      more.addEventListener('click', () => postMenu('group', group.id, null, null, more));
      head.appendChild(more);
      head.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        thuban.send('menu', { kind: 'group', groupId: group.id, x: e.clientX, y: e.clientY });
      });
    }
    section.appendChild(head);

    const cards = el('div', 'cards');
    cards.id = 'cards-' + group.id;
    cards.dataset.groupId = group.id;
    for (const entry of entries) cards.appendChild(buildCard(entry, group));
    if (editable() && entries.length === 0) {
      const tile = el('button', 'add-tile');
      tile.type = 'button';
      tile.innerHTML = ICONS.plus + '<span>Add the first equation</span>';
      tile.setAttribute('aria-label', 'Add the first equation to ' + group.name);
      tile.addEventListener('click', () => thuban.send('addEntry', { groupId: group.id }));
      cards.appendChild(tile);
    }
    if (editable()) wireDrop(cards, group);
    section.appendChild(cards);
    return section;
  }

  function postMenu(kind, groupId, entryId, index, anchor) {
    const rect = anchor.getBoundingClientRect();
    const payload = { kind, groupId, x: rect.left, y: rect.bottom + 2 };
    if (entryId) payload.entryId = entryId;
    if (index != null) payload.index = index;
    thuban.send('menu', payload);
  }

  function load(payload) {
    mode = payload && payload.mode === 'panel' ? 'panel' : 'sheet';
    document.body.classList.toggle('is-panel', mode === 'panel');
    groups = Array.isArray(payload && payload.groups) ? payload.groups : [];
    collapsed = new Set(Array.isArray(payload && payload.collapsed) ? payload.collapsed : []);

    // Keep keyboard focus on the same card across a reload (after an edit or a move).
    const active = document.activeElement;
    const focusedId = pendingFocus || (active && active.dataset ? active.dataset.entryId : null);
    pendingFocus = null;
    const scrollTop = document.scrollingElement ? document.scrollingElement.scrollTop : 0;

    sheetEl.textContent = '';
    for (const group of groups) sheetEl.appendChild(buildGroup(group));
    emptyEl.hidden = groups.length > 0;
    emptyEl.textContent = (payload && payload.emptyMessage) || '';

    if (document.scrollingElement) document.scrollingElement.scrollTop = scrollTop;
    if (focusedId) focusCard(focusedId);
    fitAll();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitAll);
  }

  /* ================================================================ fit */

  // A long equation shrinks to fit its card (to 70 %, or 55 % in the narrow Study panel); beyond that it scrolls
  // sideways, and `is-overflowing` keeps a thin scrollbar visible so the cut-off end never reads as clipped text.
  function fit(row) {
    row.style.fontSize = '';
    row.classList.remove('is-overflowing');
    const width = row.clientWidth;
    const needed = row.scrollWidth;
    if (!width || needed <= width + 1) return;
    const minScale = mode === 'panel' ? 0.55 : 0.7;
    const base = parseFloat(getComputedStyle(row).fontSize) || 17;
    row.style.fontSize = (base * Math.max(minScale, (width - 2) / needed)).toFixed(2) + 'px';
    if (row.scrollWidth > row.clientWidth + 1) row.classList.add('is-overflowing');
  }
  function fitAll() { for (const row of sheetEl.querySelectorAll('.eq')) fit(row); }
  let fitTimer = 0;
  window.addEventListener('resize', () => { clearTimeout(fitTimer); fitTimer = setTimeout(fitAll, 60); });

  function focusCard(id) {
    const card = sheetEl.querySelector('.eq-card[data-entry-id="' + CSS.escape(String(id)) + '"]');
    if (!card) return false;
    card.focus({ preventScroll: true });
    card.scrollIntoView({ block: 'nearest' });
    return true;
  }

  function focusEntry(payload) {
    const id = payload && payload.id;
    if (!id) return;
    if (!focusCard(id)) pendingFocus = id;
  }

  /* ============================================================ keyboard */

  function cardsInOrder() { return Array.from(sheetEl.querySelectorAll('.eq-card')); }

  function onCardKey(e, card, entry, group) {
    if (e.target !== card) return;
    const key = e.key;
    if ((key === 'Enter' || key === ' ') && !e.metaKey && !e.altKey) {
      if (editable()) { e.preventDefault(); thuban.send('edit', { entryId: entry.id }); }
      return;
    }
    if (key === 'ContextMenu' || (key === 'F10' && e.shiftKey)) {
      e.preventDefault();
      const rect = card.getBoundingClientRect();
      thuban.send('menu', { kind: 'entry', groupId: group.id, entryId: entry.id, x: rect.left + 12, y: rect.top + 24 });
      return;
    }
    if (e.metaKey && (key === 'c' || key === 'C')) {
      e.preventDefault();
      thuban.send('copyLatex', { entryId: entry.id });
      return;
    }
    if (editable() && (key === 'Delete' || key === 'Backspace') && !e.metaKey) {
      e.preventDefault();
      thuban.send('deleteEntry', { entryId: entry.id });
      return;
    }
    if (key === 'ArrowUp' || key === 'ArrowDown') {
      e.preventDefault();
      const delta = key === 'ArrowUp' ? -1 : 1;
      if (e.altKey) {
        if (editable()) {
          pendingFocus = entry.id;
          thuban.send('moveEntryBy', { entryId: entry.id, delta });
        }
        return;
      }
      const all = cardsInOrder();
      const next = all[all.indexOf(card) + delta];
      if (next) { next.focus({ preventScroll: true }); next.scrollIntoView({ block: 'nearest' }); }
    }
  }

  /* ======================================================== drag and drop */

  function clearDropMarks() {
    for (const node of sheetEl.querySelectorAll('.drop-before, .drop-after, .drop-into, .drop-vertical')) {
      node.classList.remove('drop-before', 'drop-after', 'drop-into', 'drop-vertical');
    }
  }

  /// Where a drop at (clientX, clientY) lands in `cards`: before or after the nearest card. Cards fill rows left to
  /// right, so in a multi-column grid the side is decided by x; in a single column (a narrow window) by y.
  function dropTarget(cards, clientX, clientY) {
    const list = Array.from(cards.querySelectorAll('.eq-card')).filter((c) => !dragged || c.dataset.entryId !== dragged.entryId);
    if (list.length === 0) return { card: null, after: false, vertical: false };
    let best = null, bestDistance = Infinity;
    for (const card of list) {
      const r = card.getBoundingClientRect();
      const dx = clientX < r.left ? r.left - clientX : (clientX > r.right ? clientX - r.right : 0);
      const dy = clientY < r.top ? r.top - clientY : (clientY > r.bottom ? clientY - r.bottom : 0);
      const distance = dx * dx + dy * dy;
      if (distance < bestDistance) { bestDistance = distance; best = card; }
    }
    const r = best.getBoundingClientRect();
    const vertical = r.width > cards.clientWidth * 0.6;
    const after = vertical ? clientY > r.top + r.height / 2 : clientX > r.left + r.width / 2;
    return { card: best, after, vertical };
  }

  function wireDrop(cards, group) {
    cards.addEventListener('dragover', (e) => {
      if (!dragged) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      clearDropMarks();
      const target = dropTarget(cards, e.clientX, e.clientY);
      if (target.card) {
        target.card.classList.add(target.after ? 'drop-after' : 'drop-before');
        target.card.classList.toggle('drop-vertical', target.vertical);
      } else cards.classList.add('drop-into');
    });
    cards.addEventListener('dragleave', (e) => {
      if (!cards.contains(e.relatedTarget)) clearDropMarks();
    });
    cards.addEventListener('drop', (e) => {
      if (!dragged) return;
      e.preventDefault();
      const target = dropTarget(cards, e.clientX, e.clientY);
      const entryId = dragged.entryId;
      clearDropMarks();
      dragged = null;
      pendingFocus = entryId;
      const payload = { entryId, groupId: group.id };
      if (target.card) payload[target.after ? 'afterId' : 'beforeId'] = target.card.dataset.entryId;
      thuban.send('moveEntry', payload);
    });
  }

  /* ================================================================ boot */

  thuban.on('load', load);
  thuban.on('focusEntry', focusEntry);

  // Debug surface: opened in Safari without a host, show a small sample sheet.
  if (!thuban.hasBridge) {
    document.addEventListener('DOMContentLoaded', () => load({
      mode: 'sheet',
      groups: [
        { id: 'g1', name: 'Partial derivatives', entries: [
          { id: 'e1', name: 'Chain rule', equations: ['\\frac{\\partial z}{\\partial t} = \\frac{\\partial z}{\\partial x}\\frac{\\mathrm{d}x}{\\mathrm{d}t} + \\frac{\\partial z}{\\partial y}\\frac{\\mathrm{d}y}{\\mathrm{d}t}'] },
          { id: 'e2', name: 'Clairaut', equations: ['f_{xy} = f_{yx}'], note: 'when both are continuous' }
        ] },
        { id: 'g2', name: 'Vectors', entries: [] }
      ]
    }));
  }

  window.ThubanSheet = { load, focusEntry, get groups() { return groups; } };
})();
