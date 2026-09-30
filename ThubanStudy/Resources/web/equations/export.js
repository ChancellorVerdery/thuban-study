/*
 * Thuban Study — equation sheet export workbench (export.html, hosted by EquationExportWebView). Ported from Atlas's
 * print-sheet workbench: Include (which groups, entries and list items), Paper & fit (paper, sides, sheets, columns,
 * type size, what to show), and a live preview with the fit readouts. exportlayout.js holds the pure layout logic;
 * this file measures real DOM and draws the pages.
 *
 *   Swift → JS   load {className, groups: [{id, name, entries: [{id, name, note?, equations: [latex]}]}],
 *                      saved: {settings?, sel?} | null}
 *                afterOutput {}                         the PDF or print job is done: leave print layout
 *                theme {css, isDark}                    handled by shared/bridge.js
 *   JS → Swift   ready
 *                save {settings, sel: [id]}             debounced; kept per class
 *                output {mode: "pdf"|"print", widthIn, heightIn, sides, fileName}
 *                                                       the pages are laid out in #print-root at paper size; Swift runs the
 *                                                       PDF export or the print dialog, then sends afterOutput
 *                done {}
 */
(function () {
  'use strict';

  const thuban = window.thuban;
  const L = window.EqLayout;
  const app = document.getElementById('app');
  const printRoot = document.getElementById('print-root');

  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function renderMath(latex) {
    let markup = '';
    try { markup = window.MathLive.convertLatexToMarkup(String(latex || ''), { mathstyle: 'displaystyle' }); }
    catch (_) { return '<div class="eq-render eq-render--invalid">' + esc(latex) + '</div>'; }
    return '<div class="eq-render"><span class="eq-render__inner">' + markup + '</span></div>';
  }

  const SVG_CHEV = '<svg viewBox="0 0 10 10" fill="currentColor" aria-hidden="true"><path d="M3 1l4 4-4 4z"/></svg>';
  const SVG_CK = '<svg class="ck" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M2 5l2.2 2.2L8 3"/></svg><svg class="mx" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M2 5h6"/></svg>';

  function shellHTML() {
    const seg = (key, opts, full) => '<div class="eqp-seg' + (full ? ' eqp-seg--full' : '') + '" data-seg-of="' + key + '">' +
      opts.map(([v, l]) => '<button type="button" data-seg="' + key + '" data-v="' + v + '">' + l + '</button>').join('') + '</div>';
    const chk = (key, label) => '<label class="eqp-chk"><input type="checkbox" data-set="' + key + '"> ' + label + '</label>';
    return '<div class="eqp-head">' +
        '<div><p class="eqp-head__eyebrow" data-el="eyebrow">Export equation sheet</p><p class="eqp-head__sum" data-el="summary"></p></div>' +
        '<div class="eqp-head__actions">' +
          '<button type="button" class="eqp-btn" data-act="done">Done</button>' +
          '<button type="button" class="eqp-btn" data-act="print">Print…</button>' +
          '<button type="button" class="eqp-btn eqp-btn--primary" data-act="pdf">Export PDF…</button>' +
        '</div>' +
      '</div>' +
      '<div class="eqp-tool">' +
        '<div class="eqp-pane">' +
          '<div class="eqp-pane__h"><span>Include</span><span><button type="button" class="eqp-lnk" data-act="sel-all">All</button> · <button type="button" class="eqp-lnk" data-act="sel-none">None</button></span></div>' +
          '<div class="eqp-search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input data-el="q" placeholder="Filter equations" aria-label="Filter equations"></div>' +
          '<div class="eqp-tree" data-el="tree" role="tree"></div>' +
          '<div class="eqp-tree-foot"><span><b data-el="cnt-sel">0</b> of <b data-el="cnt-all">0</b> equations</span><span data-el="cnt-groups"></span></div>' +
        '</div>' +
        '<div class="eqp-pane eqp-pane--settings">' +
          '<div class="eqp-pane__h"><span>Paper &amp; fit</span></div>' +
          '<div class="eqp-set">' +
            '<div class="eqp-set__l">Paper</div>' +
            '<div class="eqp-row"><span class="eqp-lab">Size</span><select class="eqp-sel" data-set="paper">' +
              Object.entries(L.PAPERS).map(([k, p]) => '<option value="' + k + '">' + p.label + (k === 'custom' ? '…' : ' ' + p.w + ' × ' + p.h) + '</option>').join('') +
            '</select></div>' +
            '<div class="eqp-custom" data-el="custom"><span class="eqp-lab">W</span><input class="eqp-num" data-set="customW" type="number" step="0.1" min="2" max="17"><span class="eqp-lab">H</span><input class="eqp-num" data-set="customH" type="number" step="0.1" min="2" max="17"><span class="eqp-sub">in</span></div>' +
            '<div class="eqp-row"><span class="eqp-lab">Orientation</span>' + seg('orient', [['portrait', 'Portrait'], ['landscape', 'Landscape']]) + '</div>' +
            '<div class="eqp-row"><span class="eqp-lab">Margins</span><span><input class="eqp-num" data-set="margin" type="number" step="0.05" min="0" max="1.5"> <span class="eqp-sub">in</span></span></div>' +
          '</div>' +
          '<div class="eqp-set">' +
            '<div class="eqp-set__l">Pages</div>' +
            '<div class="eqp-row"><span class="eqp-lab">Sides</span>' + seg('sides', [['1', 'One side'], ['2', 'Front &amp; back']]) + '</div>' +
            '<div class="eqp-row"><span class="eqp-lab">Sheets</span><span class="eqp-row__r"><span class="eqp-stepper"><button type="button" data-act="pg-dec" aria-label="Fewer sheets">−</button><output data-el="pg-out">1</output><button type="button" data-act="pg-inc" aria-label="More sheets">+</button></span><span class="eqp-sub" data-el="sides-out"></span></span></div>' +
          '</div>' +
          '<div class="eqp-set">' +
            '<div class="eqp-set__l">Columns</div>' +
            seg('cols', [['auto', 'Auto'], ['1', '1'], ['2', '2'], ['3', '3'], ['4', '4'], ['5', '5'], ['6', '6']], true) +
            chk('rules', 'Hairline between columns') +
          '</div>' +
          '<div class="eqp-set">' +
            '<div class="eqp-set__l">Type size</div>' +
            seg('sizeMode', [['auto', 'Auto-fit to pages'], ['fixed', 'Fixed']], true) +
            '<div class="eqp-row"><span class="eqp-lab">Base size</span><span class="eqp-sub" data-el="size-out">—</span></div>' +
            '<input class="eqp-range" data-set="size" type="range" min="' + L.SIZE_MIN + '" max="' + L.SIZE_MAX + '" step="0.25" aria-label="Base type size in points">' +
            '<p class="eqp-sub eqp-help">Auto-fit finds the largest size where everything lands on your sheets, trying each column count. Long equations shrink to their column, never wrap.</p>' +
          '</div>' +
          '<div class="eqp-set">' +
            '<div class="eqp-set__l">Show</div>' +
            chk('showCat', 'Group headings') + chk('showSub', 'List titles') + chk('showNames', 'Equation names') + chk('showNotes', 'Notes') +
            '<div class="eqp-row"><span class="eqp-lab">Name placement</span>' + seg('nameStyle', [['above', 'Above'], ['beside', 'Beside']]) + '</div>' +
            chk('labels', 'Sheet labels in the margin') +
          '</div>' +
          '<div class="eqp-set">' +
            '<div class="eqp-set__l">Preview</div>' +
            seg('pv', [['fit', 'Fit'], ['actual', 'Actual size']], true) +
            '<div class="eqp-row"><span class="eqp-lab">Printer</span><select class="eqp-sel" data-set="dpi"><option value="150">150 dpi · inkjet draft</option><option value="300">300 dpi · typical</option><option value="600">600 dpi · laser</option><option value="1200">1200 dpi · photo</option></select></div>' +
          '</div>' +
        '</div>' +
        '<div class="eqp-pane eqp-preview">' +
          '<div class="eqp-readout">' +
            '<div class="eqp-ro" data-el="ro-size"><div class="eqp-ro__l">Solved size</div><div class="eqp-ro__v">—</div><div class="eqp-ro__s"></div></div>' +
            '<div class="eqp-ro" data-el="ro-sides"><div class="eqp-ro__l">Sides used</div><div class="eqp-ro__v">—</div><div class="eqp-ro__s"></div></div>' +
            '<div class="eqp-ro" data-el="ro-leg"><div class="eqp-ro__l">Smallest text on paper</div><div class="eqp-ro__v">—</div><div class="eqp-ro__s"></div></div>' +
          '</div>' +
          '<div class="eqp-warn" data-el="warn"></div>' +
          '<div class="eqp-note" data-el="note"></div>' +
          '<div class="eqp-well" data-el="well"><div class="eqp-well__inner" data-el="pages"></div></div>' +
        '</div>' +
      '</div>' +
      '<div class="eqp-measure" data-el="measure" aria-hidden="true"></div>';
  }

  // ---- state ----
  let className = '';
  let tree = [], ALL = [];
  let S = L.settingsFrom(null);
  let sel = new Set();
  const open = new Set();
  let query = '';
  let blocks = [], nodes = [], sol = null, pageEls = [];
  let mounted = false;
  let fontsWatched = false;

  // Every KaTeX face the sheet can use, loaded up front (see load()).
  const MATH_FACES = ['16px KaTeX_Main', 'italic 16px KaTeX_Main', 'bold 16px KaTeX_Main', 'italic 16px KaTeX_Math',
    'bold italic 16px KaTeX_Math', '16px KaTeX_AMS', '16px KaTeX_Size1', '16px KaTeX_Size2', '16px KaTeX_Size3', '16px KaTeX_Size4'];
  let mathFontsPromise = null;
  function mathFonts() {
    if (!mathFontsPromise) {
      mathFontsPromise = document.fonts && document.fonts.load
        ? Promise.all(MATH_FACES.map((f) => document.fonts.load(f).catch(() => null))).then(() => document.fonts.ready)
        : Promise.resolve();
    }
    return mathFontsPromise;
  }

  const el = (name) => app.querySelector('[data-el="' + name + '"]');

  let saveTimer = 0;
  function persist() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => thuban.send('save', { settings: S, sel: Array.from(sel) }), 300);
  }

  // ---- include tree ----
  function renderTree() {
    const out = [];
    const q = query.trim().toLowerCase();
    const matches = (n) => (n.label || '').toLowerCase().includes(q) || leavesOf(n).some((l) => (l.label || '').toLowerCase().includes(q) || (l.latex || '').toLowerCase().includes(q));
    const walk = (n, depth) => {
      const st = L.stateOf(n, sel);
      if (q && !matches(n)) return;
      const isOpen = q ? true : open.has(n.id);
      const label = n.label || (n.kind === 'cat' ? 'Untitled group' : n.leaf ? n.latex : 'Untitled list');
      const isMath = n.leaf && !n.label;
      out.push('<div class="eqp-tnode' + (st === 'off' ? ' is-off' : '') + (isOpen ? ' is-open' : '') + '" data-id="' + esc(n.id) + '" data-kind="' + n.kind + '" style="--depth:' + depth + '" role="treeitem">' +
        '<button type="button" class="eqp-tchev' + (n.leaf ? ' is-leaf' : '') + '" data-act="open" aria-label="Expand">' + SVG_CHEV + '</button>' +
        '<button type="button" class="eqp-tcheck is-' + st + '" data-act="toggle" role="checkbox" aria-checked="' + (st === 'on' ? 'true' : st === 'mixed' ? 'mixed' : 'false') + '" aria-label="Include ' + esc(label) + '">' + SVG_CK + '</button>' +
        '<span class="eqp-tlabel' + (isMath ? ' is-math' : '') + '" data-act="toggle">' + (isMath ? renderMath(n.latex) : esc(label)) + '</span>' +
        '<span class="eqp-tcount">' + (n.leaf ? '' : leavesOf(n).length) + '</span></div>');
      if (!n.leaf && isOpen) n.children.forEach((c) => walk(c, depth + 1));
    };
    tree.forEach((c) => walk(c, 0));
    el('tree').innerHTML = out.join('') || '<p class="eqp-empty">No equations on this sheet yet. Add some in the Equations section first.</p>';
    el('cnt-sel').textContent = sel.size;
    el('cnt-all').textContent = ALL.length;
    const lists = tree.reduce((n, c) => n + c.children.filter((x) => x.kind === 'list').length, 0);
    el('cnt-groups').textContent = tree.length + ' group' + (tree.length === 1 ? '' : 's') + (lists ? ' · ' + lists + ' list' + (lists === 1 ? '' : 's') : '');
  }
  const leavesOf = L.leavesOf;

  // ---- controls ↔ state ----
  function syncControls() {
    app.querySelectorAll('[data-seg]').forEach((b) => b.classList.toggle('is-on', String(S[b.dataset.seg]) === b.dataset.v));
    app.querySelectorAll('input[type="checkbox"][data-set]').forEach((c) => { c.checked = !!S[c.dataset.set]; });
    app.querySelectorAll('select[data-set]').forEach((s) => { s.value = String(S[s.dataset.set]); });
    for (const k of ['margin', 'customW', 'customH']) app.querySelector('[data-set="' + k + '"]').value = S[k];
    const size = app.querySelector('[data-set="size"]'); size.value = S.size; size.disabled = S.sizeMode === 'auto';
    el('custom').classList.toggle('is-on', S.paper === 'custom');
    el('pg-out').value = S.pages;
    const n = S.pages * S.sides;
    el('sides-out').textContent = '= ' + n + ' side' + (n === 1 ? '' : 's');
  }

  // ---- blocks + measurement ----
  // Block nodes live in the off-screen measure box; pages get clones. The measure box has the sheet's font and the
  // column's width, so heights read there are the heights the flow will see on paper.
  function buildNodes() {
    blocks = L.buildBlocks(tree, sel, S);
    const m = el('measure');
    m.innerHTML = '';
    nodes = blocks.map((b) => {
      const d = document.createElement('div');
      if (b.t !== 'eq') {
        d.className = 'eqp-' + b.t;
        d.textContent = b.text;
        if (b.t === 'list' && S.showNotes && b.note) { const n = document.createElement('span'); n.className = 'eqp-note-inline'; n.textContent = ' — ' + b.note; d.appendChild(n); }
      } else {
        const named = S.showNames && b.name;
        d.className = 'eqp-eq' + (S.nameStyle === 'beside' && named ? ' is-beside' : '');
        let head = '';
        if (named) head = '<div class="eqp-name">' + esc(b.name) + (S.showNotes && b.note ? '<span class="eqp-note-inline"> — ' + esc(b.note) + '</span>' : '') + '</div>';
        else if (S.showNotes && b.note) head = '<div class="eqp-name"><span class="eqp-note-inline">' + esc(b.note) + '</span></div>';
        d.innerHTML = head + '<div class="eqp-math">' + renderMath(b.latex) + '</div>';
      }
      m.appendChild(d);
      return d;
    });
  }
  // Shrink-to-column, batched (all reads, then all writes) so a pass costs a couple of reflows.
  function fitAt(sizePt, k, g) {
    const m = el('measure');
    m.style.width = g.cw + 'px';
    m.style.fontSize = sizePt + 'pt';
    const eqs = [];
    nodes.forEach((n, i) => {
      if (blocks[i].t !== 'eq') return;
      const box = n.querySelector('.eq-render'), inner = box && box.querySelector('.eq-render__inner');
      if (!inner) return;
      inner.style.transform = '';
      box.style.height = '';
      eqs.push({ box, inner });
    });
    // The drawn extent, not the box: MathLive's parts can overflow the inline box that holds them, so the box's own
    // width understates a long equation and it would be clipped at the column edge instead of shrunk.
    const range = document.createRange();
    for (const e of eqs) {
      range.selectNodeContents(e.inner);
      const drawn = range.getBoundingClientRect();
      const left = e.inner.getBoundingClientRect().left;
      e.natural = Math.max(e.inner.offsetWidth, e.inner.scrollWidth, drawn.right - left);
      e.avail = e.box.clientWidth;
      e.h = Math.max(e.inner.offsetHeight, drawn.height);
    }
    let minScale = 1;
    for (const e of eqs) {
      const sc = e.natural && e.avail ? Math.min(1, e.avail / e.natural) : 1;
      e.inner.style.transform = sc < 0.999 ? 'scale(' + sc + ')' : '';
      e.box.style.height = sc < 0.999 ? (e.h * sc) + 'px' : '';
      if (sc < minScale) minScale = sc;
    }
    const heights = nodes.map((n) => n.offsetHeight);
    const cols = L.flow(blocks, heights, g.ch);
    return { sides: Math.ceil(cols.length / k), minScale, cols };
  }

  // ---- render ----
  function render() {
    buildNodes();
    if (!blocks.length) { pageEls = []; sol = null; el('pages').innerHTML = ''; setReadout(null); return; }
    sol = L.solve(S, fitAt);
    if (!sol) { pageEls = []; el('pages').innerHTML = ''; setReadout(null); return; }
    const { k, size } = sol;
    const g = L.geometry(S, k);
    const lim = S.pages * S.sides;
    const { cols } = fitAt(size, k, g); // leaves the nodes fitted at the winning size
    const sidesNeeded = Math.ceil(cols.length / k);
    const sidesShown = Math.min(sidesNeeded, lim);
    sol.sidesNeeded = sidesNeeded;
    sol.dropped = cols.slice(sidesShown * k).flat().filter((i) => blocks[i].t === 'eq').length;
    sol.leg = L.legibility(size, sol.minScale, +S.dpi, blocks.some((b) => b.t === 'eq' && /[_^]/.test(b.latex)));
    const host = el('pages');
    host.innerHTML = '';
    pageEls = [];
    for (let sIdx = 0; sIdx < sidesShown; sIdx++) {
      const pg = document.createElement('div');
      pg.className = 'eqp-page';
      pg.style.cssText = 'width:' + g.W + 'px;height:' + g.H + 'px;padding:' + g.mg + 'px ' + g.mg + 'px ' + (g.mg + g.label) + 'px';
      const grid = document.createElement('div');
      grid.className = 'eqp-cols';
      grid.style.cssText = 'grid-template-columns:repeat(' + k + ',minmax(0,1fr));column-gap:' + g.gut + 'px;font-size:' + size + 'pt';
      for (let c = 0; c < k; c++) {
        const col = document.createElement('div');
        col.className = 'eqp-col' + (S.rules && c > 0 ? ' is-rule' : '');
        for (const i of (cols[sIdx * k + c] || [])) col.appendChild(nodes[i].cloneNode(true));
        grid.appendChild(col);
      }
      pg.appendChild(grid);
      const sideName = S.sides === 2 ? (sIdx % 2 ? 'back' : 'front') : 'one side';
      const sheetNo = Math.floor(sIdx / S.sides) + 1;
      if (S.labels) {
        const lb = document.createElement('div');
        lb.className = 'eqp-label';
        lb.style.bottom = Math.max(2, g.mg * 0.35) + 'px';
        lb.textContent = (className || 'Equations') + ' · sheet ' + sheetNo + (S.sides === 2 ? ' ' + sideName : '');
        pg.appendChild(lb);
      }
      pageEls.push(pg);
      const slot = document.createElement('div');
      slot.className = 'eqp-slot';
      const cap = document.createElement('div');
      cap.className = 'eqp-slot__cap';
      cap.textContent = 'Sheet ' + sheetNo + ' · ' + sideName + ' · ' + g.Win + ' × ' + g.Hin + ' in';
      slot.appendChild(cap);
      const sc = document.createElement('div');
      sc.className = 'eqp-scale';
      sc.appendChild(pg);
      slot.appendChild(sc);
      host.appendChild(slot);
    }
    layoutSlots();
    setReadout(sol);
    verifyFit();
  }

  // Self-check: an equation drawing wider than its column after scaling means it was measured before its fonts were
  // in place (their metrics change as they arrive). Lay out again shortly, a few times at most.
  let verifyTries = 0, verifyTimer = 0;
  function verifyFit() {
    clearTimeout(verifyTimer);
    const overflowing = nodes.some((n, i) => {
      if (blocks[i].t !== 'eq') return false;
      const box = n.querySelector('.eq-render'), inner = box && box.querySelector('.eq-render__inner');
      if (!inner) return false;
      const t = inner.style.transform;
      const sc = t ? parseFloat(t.slice(6)) : 1;
      return inner.offsetWidth * sc > box.clientWidth + 0.5;
    });
    if (!overflowing) { verifyTries = 0; return; }
    if (verifyTries >= 6) return;
    verifyTries++;
    verifyTimer = setTimeout(() => { cancelAnimationFrame(raf); raf = requestAnimationFrame(render); }, 150);
  }
  function layoutSlots() {
    const [Win, Hin] = L.paperSize(S);
    const W = Win * L.PX_PER_IN, H = Hin * L.PX_PER_IN;
    const well = el('well');
    const scale = S.pv === 'fit' ? Math.max(0.05, Math.min((well.clientWidth - 56) / W, (well.clientHeight - 90) / H, 2)) : 1;
    app.querySelectorAll('.eqp-slot').forEach((slot) => {
      slot.style.width = (W * scale) + 'px';
      slot.style.height = (H * scale) + 'px';
      const sc = slot.querySelector('.eqp-scale');
      if (sc) sc.style.transform = 'scale(' + scale + ')';
    });
    el('note').textContent = S.pv === 'fit' ? 'Fit to window · ' + Math.round(scale * 100) + '% of actual size' : 'Actual size · 1 in on paper = 96 points on screen';
  }

  // ---- readouts ----
  function setReadout(s) {
    const ro = (name, v, sub, bad) => { const r = el(name); r.classList.toggle('is-bad', !!bad); r.querySelector('.eqp-ro__v').innerHTML = v; r.querySelector('.eqp-ro__s').textContent = sub; };
    const lim = S.pages * S.sides;
    const warn = el('warn');
    const paperLabel = (L.PAPERS[S.paper] || {}).label || 'Custom';
    for (const b of app.querySelectorAll('[data-act="pdf"], [data-act="print"]')) b.disabled = !s;
    if (!s) {
      ro('ro-size', '—', ALL.length ? 'Nothing selected' : 'No equations on this sheet'); ro('ro-sides', '0 / ' + lim, ''); ro('ro-leg', '—', '');
      warn.classList.remove('is-on');
      el('summary').innerHTML = ALL.length ? 'Pick equations on the left to start a sheet.' : 'This class has no equations yet.';
      el('size-out').textContent = '—';
      return;
    }
    const shrink = 'longest equation at ' + Math.round(s.minScale * 100) + '% width';
    ro('ro-size', s.size + ' pt<small>' + s.k + ' column' + (s.k > 1 ? 's' : '') + '</small>',
      s.loose ? 'Only fits by shrinking long equations below ' + Math.round(L.MIN_SHRINK * 100) + '% · ' + shrink
        : S.sizeMode === 'auto' ? 'Largest size that fits ' + lim + ' side' + (lim > 1 ? 's' : '') + ' · ' + shrink : 'Fixed size · ' + shrink, !!s.loose);
    ro('ro-sides', Math.min(s.sidesNeeded, lim) + ' / ' + lim,
      s.fits ? S.pages + ' sheet' + (S.pages > 1 ? 's' : '') + ' of ' + paperLabel + ', ' + (S.sides === 2 ? 'front and back' : 'one side') : 'Needs ' + s.sidesNeeded + ' sides at this size', !s.fits);
    const d = s.leg.dots, dots = Math.round(d);
    const cls = s.leg.grade === 'good' ? '' : s.leg.grade === 'marginal' ? 'is-warn' : 'is-bad';
    let worst = '', m = 1;
    nodes.forEach((n, i) => {
      if (blocks[i].t !== 'eq') return;
      const t = (n.querySelector('.eq-render__inner') || {}).style;
      const sc = t && t.transform ? parseFloat(t.transform.slice(6)) : 1;
      if (sc < m) { m = sc; worst = blocks[i].name || ''; }
    });
    ro('ro-leg', '<span class="eqp-dot ' + cls + '"></span>' + s.leg.effPt.toFixed(1) + ' pt<small>' + s.leg.grade + '</small>',
      s.leg.xhPt.toFixed(1) + ' pt subscripts = ' + dots + ' dot' + (dots === 1 ? '' : 's') + ' @ ' + S.dpi + ' dpi' + (m < 0.999 ? (worst ? ' · “' + worst + '”' : '') : ' · nothing shrinks'), d < 5);
    el('size-out').textContent = s.size + ' pt';
    if (S.sizeMode === 'auto') app.querySelector('[data-set="size"]').value = s.size;
    warn.classList.toggle('is-on', !s.fits);
    if (!s.fits) warn.innerHTML = S.sizeMode === 'fixed'
      ? '<b>' + s.dropped + ' equation' + (s.dropped === 1 ? '' : 's') + ' won\'t fit</b> at ' + s.size + ' pt on ' + lim + ' side' + (lim > 1 ? 's' : '') + '. Add a sheet, use both sides, or switch to Auto-fit.'
      : '<b>Even at ' + L.SIZE_MIN + ' pt this doesn\'t fit</b> on ' + lim + ' side' + (lim > 1 ? 's' : '') + ' — ' + s.dropped + ' equation' + (s.dropped === 1 ? '' : 's') + ' cut. Add a sheet or deselect a group.';
    const eqs = blocks.filter((b) => b.t === 'eq').length;
    el('summary').innerHTML = '<b>' + eqs + '</b> equation' + (eqs === 1 ? '' : 's') + ' · <b>' + esc(paperLabel) + '</b> ' + S.orient + ' · <b>' + S.pages + '</b> sheet' + (S.pages > 1 ? 's' : '') + ', ' + (S.sides === 2 ? 'front &amp; back' : 'one side') + ' · ' + s.k + ' col · ' + s.size + ' pt';
  }

  // ---- output ----
  // The pages go into #print-root at paper size (the workbench hides while printing), @page is set to the paper so
  // nothing gets re-fitted, and Swift runs the PDF export or the print dialog; front/back is the printer's duplex.
  function output(mode) {
    // Lay out afresh with every font in place, so the file matches what the fonts actually draw.
    cancelAnimationFrame(raf);
    render();
    if (!pageEls.length) return;
    const [Win, Hin] = L.paperSize(S);
    printRoot.innerHTML = '';
    const st = document.createElement('style');
    st.textContent = '@page { size: ' + Win + 'in ' + Hin + 'in; margin: 0; }';
    printRoot.appendChild(st);
    for (const pg of pageEls) printRoot.appendChild(pg.cloneNode(true));
    document.body.classList.add('eqp-printing');
    const base = (className || 'Equations').replace(/[\/:*?"<>|]+/g, ' ').trim();
    requestAnimationFrame(() => requestAnimationFrame(() => {
      thuban.send('output', { mode, widthIn: Win, heightIn: Hin, sides: pageEls.length, fileName: base + ' equation sheet.pdf' });
    }));
  }
  let noteTimer = 0;
  function afterOutput(payload) {
    document.body.classList.remove('eqp-printing');
    printRoot.innerHTML = '';
    layoutSlots();
    const message = payload && payload.message;
    if (message) {
      el('note').textContent = message;
      clearTimeout(noteTimer);
      noteTimer = setTimeout(layoutSlots, 4000);
    }
  }

  // ---- events ----
  let raf = 0;
  const schedule = () => { persist(); cancelAnimationFrame(raf); raf = requestAnimationFrame(render); };
  function wire() {
    app.addEventListener('click', (e) => {
      const seg = e.target.closest('[data-seg]');
      if (seg) {
        const key = seg.dataset.seg;
        S[key] = key === 'sides' ? +seg.dataset.v : seg.dataset.v;
        syncControls();
        if (key === 'pv') { persist(); layoutSlots(); return; }
        schedule();
        return;
      }
      const act = e.target.closest('[data-act]');
      if (!act) return;
      const a = act.dataset.act;
      if (a === 'open' || a === 'toggle') {
        const id = act.closest('.eqp-tnode') && act.closest('.eqp-tnode').dataset.id;
        const n = id && L.findNode(tree, id);
        if (!n) return;
        if (a === 'open') { if (open.has(id)) open.delete(id); else open.add(id); renderTree(); return; }
        const on = L.stateOf(n, sel) !== 'on';
        for (const l of leavesOf(n)) { if (on) sel.add(l.id); else sel.delete(l.id); }
        renderTree(); schedule();
      } else if (a === 'sel-all') { ALL.forEach((l) => sel.add(l.id)); renderTree(); schedule(); }
      else if (a === 'sel-none') { sel.clear(); renderTree(); schedule(); }
      else if (a === 'pg-dec') { S.pages = Math.max(1, S.pages - 1); syncControls(); schedule(); }
      else if (a === 'pg-inc') { S.pages = Math.min(20, S.pages + 1); syncControls(); schedule(); }
      else if (a === 'pdf') output('pdf');
      else if (a === 'print') output('print');
      else if (a === 'done') thuban.send('done', {});
    });
    app.addEventListener('input', (e) => {
      const t = e.target;
      if (t === el('q')) { query = t.value; renderTree(); return; }
      const key = t.dataset.set;
      if (!key) return;
      if (key === 'size') { S.size = +t.value; el('size-out').textContent = S.size + ' pt'; schedule(); return; }
      if (key === 'margin' || key === 'customW' || key === 'customH') { S[key] = Math.max(0, +t.value || 0); schedule(); }
    });
    app.addEventListener('change', (e) => {
      const t = e.target, key = t.dataset.set;
      if (!key) return;
      if (t.type === 'checkbox') { S[key] = t.checked; schedule(); return; }
      if (key === 'paper') {
        S.paper = t.value;
        // Index cards default to landscape with slim margins; paper to portrait.
        const card = !!(L.PAPERS[S.paper] || {}).card;
        S.orient = card ? 'landscape' : 'portrait';
        S.margin = card ? 0.15 : 0.3;
        syncControls(); schedule();
      } else if (key === 'dpi') { S.dpi = +t.value; schedule(); }
    });
    // Fit-to-window follows the pane.
    new ResizeObserver(() => { if (!document.body.classList.contains('eqp-printing')) layoutSlots(); }).observe(el('well'));
  }

  function load(payload) {
    className = (payload && payload.className) || '';
    tree = L.buildTree((payload && payload.groups) || []);
    ALL = L.allLeaves(tree);
    const leafIds = new Set(ALL.map((l) => l.id));
    const saved = payload && payload.saved;
    S = L.settingsFrom(saved && saved.settings);
    // First visit selects everything; afterwards the saved picks come back (minus anything since deleted).
    sel = new Set(saved && Array.isArray(saved.sel) ? saved.sel.filter((id) => leafIds.has(id)) : ALL.map((l) => l.id));
    open.clear();
    tree.forEach((c) => open.add(c.id));
    if (!mounted) { app.innerHTML = shellHTML(); wire(); mounted = true; }
    el('eyebrow').textContent = 'Export equation sheet' + (className ? ' · ' + className : '');
    syncControls();
    renderTree();
    render();
    // KaTeX fonts otherwise load only as the math is laid out, after this first measurement, and their glyphs are wider
    // than the fallback's: an equation measured early would be clipped instead of shrunk. Load them all, then measure
    // again (and again whenever another batch of fonts finishes).
    mathFonts().then(() => { cancelAnimationFrame(raf); raf = requestAnimationFrame(render); });
    if (document.fonts && !fontsWatched) {
      fontsWatched = true;
      document.fonts.addEventListener('loadingdone', () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(render); });
    }
  }

  // For the layout checks in the smoke harness.
  window.__eqpRender = render;
  thuban.on('load', load);
  thuban.on('afterOutput', afterOutput);
  thuban.on('exportPDF', () => output('pdf'));
})();
