/*
 * Thuban Study — equation sheet export: the pure layout logic (ported from Atlas's eqprint.js).
 *
 * Data in, data out; export.js owns the DOM. Vocabulary: a class's sheet is groups → entries. On paper a group is
 * a CATEGORY heading; an entry with one equation is one EQUATION (its name above or beside it); an entry with
 * several equations is a LIST (its name as a heading, its equations below). Content flows top-to-bottom down a
 * column, then into the next column, then onto the next side (front, back, next sheet's front …).
 */
(function () {
  'use strict';

  const PAPERS = {
    letter: { w: 8.5, h: 11, label: 'Letter' },
    a4: { w: 8.27, h: 11.69, label: 'A4' },
    legal: { w: 8.5, h: 14, label: 'Legal' },
    half: { w: 5.5, h: 8.5, label: 'Half letter' },
    i35: { w: 3, h: 5, label: '3 × 5 card', card: true },
    i46: { w: 4, h: 6, label: '4 × 6 card', card: true },
    i58: { w: 5, h: 8, label: '5 × 8 card', card: true },
    custom: { w: 8.5, h: 11, label: 'Custom' }
  };
  const DEFAULTS = {
    paper: 'letter', orient: 'portrait', customW: 8.5, customH: 11, margin: 0.3,
    sides: 2, pages: 1, cols: 'auto', rules: false,
    sizeMode: 'auto', size: 8,
    showCat: true, showSub: true, showNames: true, showNotes: true, nameStyle: 'above', labels: false,
    pv: 'fit', dpi: 300
  };
  const PX_PER_IN = 96;
  const GUTTER_IN = 0.18;
  // Long equations shrink to their column (they never wrap), but not below this share of their natural width — past
  // it the solver prefers fewer columns over a bigger base size.
  const MIN_SHRINK = 0.55;
  const SIZE_MIN = 3;
  const SIZE_MAX = 28;
  const MAX_COLS = 6;

  function settingsFrom(saved) {
    const settings = Object.assign({}, DEFAULTS);
    if (saved && typeof saved === 'object') for (const k of Object.keys(DEFAULTS)) if (k in saved) settings[k] = saved[k];
    return settings;
  }

  // [width, height] in inches with orientation applied.
  function paperSize(s) {
    const p = s.paper === 'custom' ? { w: +s.customW || 8.5, h: +s.customH || 11 } : (PAPERS[s.paper] || PAPERS.letter);
    const w = Math.min(p.w, p.h), h = Math.max(p.w, p.h);
    return s.orient === 'landscape' ? [h, w] : [w, h];
  }
  // Everything the flow needs, in CSS px at 96/in, for k columns.
  function geometry(s, k) {
    const [Win, Hin] = paperSize(s);
    const W = Win * PX_PER_IN, H = Hin * PX_PER_IN;
    const mg = Math.max(0, +s.margin || 0) * PX_PER_IN, gut = GUTTER_IN * PX_PER_IN;
    const label = s.labels ? 10 : 0;
    return { Win, Hin, W, H, mg, gut, label, cw: (W - 2 * mg - (k - 1) * gut) / k, ch: H - 2 * mg - label };
  }

  // ---- selection tree -------------------------------------------------------------------------

  // groups: [{id, name, entries: [{id, name, note?, equations: [latex]}]}] → [{id, kind:'cat', label, children}]
  // A one-equation entry is a leaf; a several-equation entry is a list whose items get ids `${entryId}#${i}`.
  function buildTree(groups) {
    const cats = [];
    for (const g of groups || []) {
      const children = [];
      for (const e of g.entries || []) {
        const eqs = (e.equations || []).filter((x) => String(x).trim());
        if (!eqs.length) continue;
        if (eqs.length === 1) children.push({ id: e.id, kind: 'eq', label: e.name || '', note: e.note || '', latex: eqs[0], leaf: true });
        else children.push({ id: e.id, kind: 'list', label: e.name || '', note: e.note || '',
          children: eqs.map((latex, i) => ({ id: e.id + '#' + i, kind: 'eq', label: '', note: '', latex, leaf: true })) });
      }
      if (children.length) cats.push({ id: g.id, kind: 'cat', label: g.name || '', children });
    }
    return cats;
  }
  const leavesOf = (n) => (n.leaf ? [n] : n.children.flatMap(leavesOf));
  const allLeaves = (tree) => tree.flatMap(leavesOf);
  // 'on' | 'off' | 'mixed' — the tri-state checkbox of any node.
  function stateOf(n, sel) {
    if (n.leaf) return sel.has(n.id) ? 'on' : 'off';
    const ls = leavesOf(n);
    const k = ls.filter((l) => sel.has(l.id)).length;
    return k === 0 ? 'off' : k === ls.length ? 'on' : 'mixed';
  }
  function findNode(tree, id) {
    for (const n of tree) {
      if (n.id === id) return n;
      if (!n.leaf) { const f = findNode(n.children, id); if (f) return f; }
    }
    return null;
  }

  // ---- blocks: the flat print order ----------------------------------------------------------

  // [{t:'cat'|'list', text, note?} | {t:'eq', id, name, note, latex}] — only the selected equations, only the headings
  // that are switched on, in sheet order.
  function buildBlocks(tree, sel, s) {
    const blocks = [];
    const any = (n) => leavesOf(n).some((l) => sel.has(l.id));
    for (const cat of tree) {
      if (!any(cat)) continue;
      if (s.showCat && cat.label) blocks.push({ t: 'cat', text: cat.label });
      for (const ch of cat.children) {
        if (ch.leaf) {
          if (sel.has(ch.id)) blocks.push({ t: 'eq', id: ch.id, name: ch.label, note: ch.note, latex: ch.latex });
          continue;
        }
        if (!any(ch)) continue;
        if (s.showSub && ch.label) blocks.push({ t: 'list', text: ch.label, note: ch.note });
        for (const l of ch.children) if (sel.has(l.id)) blocks.push({ t: 'eq', id: l.id, name: '', note: '', latex: l.latex });
      }
    }
    return blocks;
  }

  // Greedy column flow. heights[i] is block i's height in px; colH the usable column height. Headings keep with
  // whatever follows them, so a heading is never stranded at the foot of a column. → [[blockIdx…], …]
  function flow(blocks, heights, colH) {
    const cols = [];
    let cur = [], y = 0;
    for (let i = 0; i < blocks.length; i++) {
      let need = heights[i], j = i;
      while (blocks[j].t !== 'eq' && j + 1 < blocks.length) { need += heights[j + 1]; j++; }
      if (y > 0 && y + need > colH) { cols.push(cur); cur = []; y = 0; }
      cur.push(i);
      y += heights[i];
    }
    if (cur.length) cols.push(cur);
    return cols;
  }

  // ---- the solver ------------------------------------------------------------------------------

  // fitAt(sizePt, k, geo) → {sides, minScale} is supplied by the caller (it measures real DOM). Auto mode finds, per
  // column count, the largest base size that lands on the allowed sides without crushing long equations past
  // MIN_SHRINK, then keeps the biggest. Fixed mode keeps the fewest columns that fit. If nothing satisfies the shrink
  // floor the search runs again without it (flagged `loose`) so the student still sees a sheet, plus a warning.
  function solve(s, fitAt) {
    const lim = Math.max(1, (+s.pages || 1) * (+s.sides || 1));
    const Ks = s.cols === 'auto' ? Array.from({ length: MAX_COLS }, (_, i) => i + 1) : [Math.max(1, +s.cols || 1)];
    const run = (guard) => {
      let best = null;
      for (const k of Ks) {
        const g = geometry(s, k);
        if (g.cw < 40) continue; // a column narrower than ~0.4 in isn't a column
        const ok = (r) => r.sides <= lim && (!guard || r.minScale >= MIN_SHRINK);
        let cand;
        if (s.sizeMode === 'fixed') {
          const size = Math.min(SIZE_MAX, Math.max(SIZE_MIN, +s.size || DEFAULTS.size));
          const r = fitAt(size, k, g);
          cand = Object.assign({ k, size }, r, { fits: ok(r) });
        } else {
          let lo = SIZE_MIN, hi = SIZE_MAX, rlo = fitAt(lo, k, g);
          if (!ok(rlo)) cand = Object.assign({ k, size: lo }, rlo, { fits: false });
          else {
            const rhi = fitAt(hi, k, g);
            if (ok(rhi)) { lo = hi; rlo = rhi; }
            else for (let i = 0; i < 8; i++) { const mid = (lo + hi) / 2; const r = fitAt(mid, k, g); if (ok(r)) { lo = mid; rlo = r; } else hi = mid; }
            lo = Math.floor(lo * 4) / 4; // quarter-point steps read cleanly
            rlo = fitAt(lo, k, g);
            cand = Object.assign({ k, size: lo }, rlo, { fits: ok(rlo) });
          }
        }
        if (!best) { best = cand; continue; }
        if (cand.fits !== best.fits) { if (cand.fits) best = cand; continue; }
        if (cand.fits) { if (s.sizeMode !== 'fixed' && cand.size > best.size) best = cand; } // fixed: fewest columns wins
        else if (cand.sides < best.sides) best = cand;
      }
      return best;
    };
    let best = run(true);
    if (!best || !best.fits) {
      const loose = run(false);
      if (loose && (loose.fits || !best)) { best = loose; best.loose = true; }
    }
    return best;
  }

  // How small the smallest ink on the page really is. KaTeX fonts have an x-height of ~0.43 em and set scripts at
  // 0.7×, so the subscript x-height in points is 0.43 × 0.7 × (base size × how far the most-shrunk equation scaled).
  // In printer dots that's the number that decides legibility.
  function legibility(sizePt, minScale, dpi, hasScripts) {
    const effPt = sizePt * minScale;
    const xhPt = 0.43 * (hasScripts ? 0.7 : 1) * effPt;
    const dots = xhPt / 72 * dpi;
    return { effPt, xhPt, dots, grade: dots >= 8 ? 'good' : dots >= 5 ? 'marginal' : 'hard to read' };
  }

  window.EqLayout = {
    PAPERS, DEFAULTS, PX_PER_IN, GUTTER_IN, MIN_SHRINK, SIZE_MIN, SIZE_MAX, MAX_COLS,
    settingsFrom, paperSize, geometry, buildTree, leavesOf, allLeaves, stateOf, findNode, buildBlocks, flow, solve, legibility
  };
})();
