/*
 * Thuban Study — process-diagram answers ("sketch the processes on p–V coordinates").
 *
 * ThubanDiagram.create(setup, onChange) → { element, getValue(), setValue(json), focus() }
 *   setup: { xAxis, yAxis, stateIds, shadeWork }; an axis is { label, unit?, symbol?, min, max, step? }.
 *   The value is JSON: { states:[{id,x,y}], processes:[{from,to,path:"line"|"curve",n?}], shaded:["1-2",…] }
 *   in axis units (symbolic axes: grid units; the student chooses where the reference sits).
 *
 * Click the grid to place the chosen state (or move it there). Drag a state to move it. Click one state, then
 * another, to draw a process from the first to the second with the chosen path. Click a process to select it
 * (shade its work area, reverse it, delete it). Delete/Backspace removes the selection.
 */
(function () {
  'use strict';

  const NS = 'http://www.w3.org/2000/svg';
  const HEIGHT = 360;
  const MARGIN = { left: 58, right: 16, top: 14, bottom: 46 };

  function svg(tag, attrs, parent) {
    const node = document.createElementNS(NS, tag);
    for (const k in attrs || {}) node.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(node);
    return node;
  }
  function html(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  /// "p_1" → p₁, "V_{12}" → V₁₂ (plain text for SVG labels and hints).
  const SUB = { 0: '₀', 1: '₁', 2: '₂', 3: '₃', 4: '₄', 5: '₅', 6: '₆', 7: '₇', 8: '₈', 9: '₉' };
  const SUP = { '-': '⁻', 0: '⁰', 1: '¹', 2: '²', 3: '³', 4: '⁴', 5: '⁵', 6: '⁶', 7: '⁷', 8: '⁸', 9: '⁹' };
  function pretty(text) {
    return String(text || '')
      .replace(/\\mathrm\{([^}]*)\}|\\text\{([^}]*)\}/g, (m, a, b) => a || b)
      .replace(/_\{(\d+)\}|_(\d)/g, (m, a, b) => (a || b).split('').map((c) => SUB[c] || c).join(''))
      .replace(/\^\{(-?\d+)\}|\^(-?\d)/g, (m, a, b) => (a || b).split('').map((c) => SUP[c] || c).join(''))
      .replace(/\\cdot|\*/g, '·');
  }

  function niceStep(span) {
    const raw = span / 6;
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    const f = raw / mag;
    return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * mag;
  }
  function round(v) { return Math.round(v * 10000) / 10000; }
  function fmt(v) { return String(Math.round(v * 1000) / 1000); }

  function axisOf(a) {
    const axis = Object.assign({ label: '', min: 0, max: 1 }, a || {});
    axis.symbolic = !!(axis.symbol && String(axis.symbol).trim());
    if (!(axis.max > axis.min)) axis.max = axis.min + 1;
    axis.step = axis.symbolic ? 0.5 : (axis.step > 0 ? axis.step : niceStep(axis.max - axis.min));
    axis.snap = axis.symbolic ? 0.125 : axis.step / 4;
    return axis;
  }

  function create(setup, onChange) {
    const xAxis = axisOf(setup && setup.xAxis);
    const yAxis = axisOf(setup && setup.yAxis);
    const stateIds = (setup && Array.isArray(setup.stateIds) && setup.stateIds.length) ? setup.stateIds.map(String) : ['1', '2', '3', '4'];
    const shadeWork = !!(setup && setup.shadeWork);

    let states = [];          // {id, x, y}
    let processes = [];       // {from, to, path, n}
    let shaded = new Set();   // "from-to"
    let selection = null;     // {type:'state'|'process', key}
    let width = 560;

    const root = html('div', 'dg');

    // ------------------------------------------------------------- toolbar
    const bar = html('div', 'dg-bar');
    const placeLabel = html('label', 'dg-field');
    placeLabel.appendChild(html('span', 'dg-label', 'State'));
    const stateSelect = html('select', 'dg-select');
    stateSelect.setAttribute('aria-label', 'State to place');
    for (const id of stateIds) { const o = html('option', null, id); o.value = id; stateSelect.appendChild(o); }
    placeLabel.appendChild(stateSelect);
    bar.appendChild(placeLabel);

    const pathLabel = html('div', 'dg-field');
    pathLabel.appendChild(html('span', 'dg-label', 'Path'));
    const seg = html('div', 'dg-seg');
    const lineBtn = html('button', 'dg-seg-btn', 'Straight');
    const curveBtn = html('button', 'dg-seg-btn', pretty(yAxis.label) + pretty(xAxis.label) + 'ⁿ = const');
    lineBtn.type = curveBtn.type = 'button';
    seg.appendChild(lineBtn); seg.appendChild(curveBtn);
    pathLabel.appendChild(seg);
    const nWrap = html('label', 'dg-field dg-n');
    nWrap.appendChild(html('span', 'dg-label', 'n ='));
    const nInput = html('input', 'dg-num');
    nInput.type = 'number'; nInput.step = '0.1'; nInput.value = '1';
    nInput.setAttribute('aria-label', 'Exponent n');
    nWrap.appendChild(nInput);
    pathLabel.appendChild(nWrap);
    bar.appendChild(pathLabel);

    const actions = html('div', 'dg-actions');
    const shadeBtn = html('button', 'dg-btn', 'Shade work');
    const reverseBtn = html('button', 'dg-btn', 'Reverse');
    const deleteBtn = html('button', 'dg-btn', 'Delete');
    const clearBtn = html('button', 'dg-btn dg-quiet', 'Clear');
    for (const b of [shadeBtn, reverseBtn, deleteBtn, clearBtn]) { b.type = 'button'; actions.appendChild(b); }
    bar.appendChild(actions);
    root.appendChild(bar);

    let curveMode = false;
    function setCurveMode(on) {
      curveMode = on;
      lineBtn.classList.toggle('is-on', !on);
      curveBtn.classList.toggle('is-on', on);
      lineBtn.setAttribute('aria-pressed', String(!on));
      curveBtn.setAttribute('aria-pressed', String(on));
      nWrap.style.display = on ? '' : 'none';
      // The path buttons also restyle a selected process.
      const p = selectedProcess();
      if (p) { p.path = on ? 'curve' : 'line'; if (on) p.n = currentN(); changed(); }
    }
    function currentN() { const v = parseFloat(nInput.value); return isFinite(v) ? v : 1; }
    lineBtn.addEventListener('click', () => setCurveMode(false));
    curveBtn.addEventListener('click', () => setCurveMode(true));
    nInput.addEventListener('input', () => { const p = selectedProcess(); if (p && p.path === 'curve') { p.n = currentN(); changed(); } });

    const hint = html('p', 'dg-hint');
    const pieces = ['Click the grid to place a state and drag to move it; click two states to join them.'];
    const symbolic = [xAxis, yAxis].filter((a) => a.symbolic);
    if (symbolic.length) {
      const names = symbolic.map((a) => pretty(a.label)).join(' and ');
      const refs = symbolic.map((a) => pretty(a.symbol)).join(' and ');
      const first = symbolic[symbolic.length - 1];
      pieces.push('The ' + names + (symbolic.length > 1 ? ' axes are' : ' axis is') + ' unnumbered: place ' + refs +
        ' anywhere, then keep proportions (2' + pretty(first.symbol) + ' sits twice as far from the axis as ' + pretty(first.symbol) + ').');
    }
    if (shadeWork) pieces.push('Select a process, then Shade work.');
    hint.textContent = pieces.join(' ');
    root.appendChild(hint);

    // ----------------------------------------------------------------- svg
    const canvas = svg('svg', { class: 'dg-svg', role: 'application', tabindex: '0', height: HEIGHT });
    root.appendChild(canvas);
    const gGrid = svg('g', {}, canvas);
    const gShade = svg('g', {}, canvas);
    const gPaths = svg('g', {}, canvas);
    const gStates = svg('g', {}, canvas);

    function plotW() { return Math.max(120, width - MARGIN.left - MARGIN.right); }
    function plotH() { return HEIGHT - MARGIN.top - MARGIN.bottom; }
    function px(x) { return MARGIN.left + (x - xAxis.min) / (xAxis.max - xAxis.min) * plotW(); }
    function py(y) { return MARGIN.top + plotH() - (y - yAxis.min) / (yAxis.max - yAxis.min) * plotH(); }
    function dataX(sx) { return xAxis.min + (sx - MARGIN.left) / plotW() * (xAxis.max - xAxis.min); }
    function dataY(sy) { return yAxis.min + (MARGIN.top + plotH() - sy) / plotH() * (yAxis.max - yAxis.min); }
    function snap(v, axis) {
      const s = Math.round(v / axis.snap) * axis.snap;
      return round(Math.min(axis.max, Math.max(axis.min, s)));
    }

    function drawGrid() {
      gGrid.textContent = '';
      canvas.setAttribute('width', width);
      canvas.setAttribute('viewBox', '0 0 ' + width + ' ' + HEIGHT);
      const x0 = px(xAxis.min), x1 = px(xAxis.max), y0 = py(yAxis.min), y1 = py(yAxis.max);
      for (const [axis, vertical] of [[xAxis, true], [yAxis, false]]) {
        const minor = axis.step / 2;
        for (let v = axis.min; v <= axis.max + 1e-9; v += minor) {
          const major = Math.abs(v / axis.step - Math.round(v / axis.step)) < 1e-6;
          const attrs = vertical ? { x1: px(v), x2: px(v), y1: y0, y2: y1 } : { x1: x0, x2: x1, y1: py(v), y2: py(v) };
          attrs.class = major ? 'dg-grid' : 'dg-grid dg-minor';
          svg('line', attrs, gGrid);
          if (major && !axis.symbolic && Math.abs(v - axis.min) > 1e-9) {
            const t = vertical
              ? svg('text', { x: px(v), y: y0 + 16, class: 'dg-tick', 'text-anchor': 'middle' }, gGrid)
              : svg('text', { x: x0 - 6, y: py(v) + 4, class: 'dg-tick', 'text-anchor': 'end' }, gGrid);
            t.textContent = fmt(v);
          }
        }
      }
      svg('line', { x1: x0, x2: x1, y1: y0, y2: y0, class: 'dg-axis' }, gGrid);
      svg('line', { x1: x0, x2: x0, y1: y0, y2: y1, class: 'dg-axis' }, gGrid);
      const xl = svg('text', { x: (x0 + x1) / 2, y: HEIGHT - 8, class: 'dg-axis-label', 'text-anchor': 'middle' }, gGrid);
      xl.textContent = pretty(xAxis.label) + (xAxis.unit ? ' (' + pretty(xAxis.unit) + ')' : '');
      const yl = svg('text', { x: 14, y: (y0 + y1) / 2, class: 'dg-axis-label', 'text-anchor': 'middle',
        transform: 'rotate(-90 14 ' + (y0 + y1) / 2 + ')' }, gGrid);
      yl.textContent = pretty(yAxis.label) + (yAxis.unit ? ' (' + pretty(yAxis.unit) + ')' : '');
    }

    function stateById(id) { return states.find((s) => s.id === id) || null; }
    function key(p) { return p.from + '-' + p.to; }
    function selectedProcess() {
      return selection && selection.type === 'process' ? processes.find((p) => key(p) === selection.key) || null : null;
    }

    /// Points (data units) along a process: a straight segment, or y·xⁿ = const from the first state towards the
    /// second (joined to it by a straight piece when the two states are not on the same curve).
    function pathPoints(p) {
      const a = stateById(p.from), b = stateById(p.to);
      if (!a || !b) return [];
      if (p.path !== 'curve' || Math.abs(a.x - b.x) < 1e-9 || a.x <= 0 || b.x <= 0) return [[a.x, a.y], [b.x, b.y]];
      const n = isFinite(p.n) ? p.n : 1;
      const c = a.y * Math.pow(a.x, n);
      const pts = [];
      const steps = 48;
      for (let i = 0; i <= steps; i++) {
        const x = a.x + (b.x - a.x) * i / steps;
        pts.push([x, c / Math.pow(x, n)]);
      }
      const end = pts[pts.length - 1];
      if (Math.abs(end[1] - b.y) > 1e-6) pts.push([b.x, b.y]);
      return pts;
    }

    function draw() {
      gShade.textContent = '';
      gPaths.textContent = '';
      gStates.textContent = '';
      for (const p of processes) {
        const pts = pathPoints(p);
        if (pts.length < 2) continue;
        const d = pts.map((q, i) => (i ? 'L' : 'M') + px(q[0]).toFixed(1) + ' ' + py(Math.max(yAxis.min, Math.min(yAxis.max, q[1]))).toFixed(1)).join(' ');
        const k = key(p);
        if (shaded.has(k)) {
          const base = py(Math.max(yAxis.min, 0));
          const area = d + ' L' + px(pts[pts.length - 1][0]).toFixed(1) + ' ' + base + ' L' + px(pts[0][0]).toFixed(1) + ' ' + base + ' Z';
          svg('path', { d: area, class: 'dg-shade' }, gShade);
        }
        const selected = selection && selection.type === 'process' && selection.key === k;
        svg('path', { d, class: 'dg-hit', 'data-process': k }, gPaths);
        svg('path', { d, class: 'dg-path' + (selected ? ' is-selected' : ''), 'data-process': k }, gPaths);
        // Arrowhead at the middle, pointing from → to.
        const mid = Math.floor((pts.length - 1) / 2);
        const q0 = pts[Math.max(0, mid - 1)], q1 = pts[Math.min(pts.length - 1, mid + 1)];
        const mx = (px(pts[mid][0]) + px(q1[0])) / 2, my = (py(pts[mid][1]) + py(q1[1])) / 2;
        const ang = Math.atan2(py(q1[1]) - py(q0[1]), px(q1[0]) - px(q0[0])) * 180 / Math.PI;
        svg('path', { d: 'M -6 -5 L 6 0 L -6 5 Z', class: 'dg-arrow' + (selected ? ' is-selected' : ''),
          transform: 'translate(' + mx.toFixed(1) + ' ' + my.toFixed(1) + ') rotate(' + ang.toFixed(1) + ')' }, gPaths);
      }
      for (const s of states) {
        const selected = selection && selection.type === 'state' && selection.key === s.id;
        const g = svg('g', { class: 'dg-state' + (selected ? ' is-selected' : ''), 'data-state': s.id }, gStates);
        svg('circle', { cx: px(s.x), cy: py(s.y), r: 11, class: 'dg-state-hit' }, g);
        svg('circle', { cx: px(s.x), cy: py(s.y), r: 5.5, class: 'dg-dot' }, g);
        const t = svg('text', { x: px(s.x) + 9, y: py(s.y) - 9, class: 'dg-state-label' }, g);
        t.textContent = s.id;
      }
      const sel = selectedProcess();
      shadeBtn.style.display = shadeWork && sel ? '' : 'none';
      shadeBtn.classList.toggle('is-on', !!(sel && shaded.has(key(sel))));
      reverseBtn.style.display = sel ? '' : 'none';
      deleteBtn.style.display = selection ? '' : 'none';
      clearBtn.style.display = states.length ? '' : 'none';
      canvas.setAttribute('aria-label', describe());
    }

    function describe() {
      if (!states.length) return 'Empty diagram grid';
      let text = 'States ' + states.map((s) => s.id + ' at (' + fmt(s.x) + ', ' + fmt(s.y) + ')').join(', ');
      if (processes.length) text += '; processes ' + processes.map((p) => p.from + ' to ' + p.to + (p.path === 'curve' ? ' curve n ' + fmt(p.n) : ' straight')).join(', ');
      return text;
    }

    function nextUnplaced() {
      const free = stateIds.find((id) => !stateById(id));
      if (free) stateSelect.value = free;
    }

    function changed() {
      draw();
      if (typeof onChange === 'function') onChange();
    }

    // ---------------------------------------------------------- pointer
    let drag = null;   // {id, startX, startY, moved}
    function local(e) {
      const r = canvas.getBoundingClientRect();
      return [(e.clientX - r.left) * (width / r.width), (e.clientY - r.top) * (HEIGHT / r.height)];
    }
    canvas.addEventListener('pointerdown', (e) => {
      canvas.focus();
      const stateEl = e.target.closest && e.target.closest('[data-state]');
      const procEl = e.target.closest && e.target.closest('[data-process]');
      if (stateEl) {
        const [sx, sy] = local(e);
        drag = { id: stateEl.getAttribute('data-state'), startX: sx, startY: sy, moved: false };
        canvas.setPointerCapture(e.pointerId);
        return;
      }
      if (procEl) {
        const k = procEl.getAttribute('data-process');
        selection = selection && selection.type === 'process' && selection.key === k ? null : { type: 'process', key: k };
        const p = selectedProcess();
        if (p) { nInput.value = fmt(isFinite(p.n) ? p.n : 1); curveMode = p.path === 'curve'; lineBtn.classList.toggle('is-on', !curveMode); curveBtn.classList.toggle('is-on', curveMode); nWrap.style.display = curveMode ? '' : 'none'; }
        draw();
        return;
      }
      // Empty grid: place (or move) the chosen state.
      const [sx, sy] = local(e);
      if (sx < MARGIN.left - 4 || sy > MARGIN.top + plotH() + 4) return;
      const id = stateSelect.value;
      const x = snap(dataX(sx), xAxis), y = snap(dataY(sy), yAxis);
      const existing = stateById(id);
      if (existing) { existing.x = x; existing.y = y; } else states.push({ id, x, y });
      selection = null;
      nextUnplaced();
      changed();
    });
    canvas.addEventListener('pointermove', (e) => {
      if (!drag) return;
      const [sx, sy] = local(e);
      if (!drag.moved && Math.hypot(sx - drag.startX, sy - drag.startY) < 4) return;
      drag.moved = true;
      const s = stateById(drag.id);
      if (!s) return;
      s.x = snap(dataX(sx), xAxis);
      s.y = snap(dataY(sy), yAxis);
      draw();
    });
    canvas.addEventListener('pointerup', () => {
      if (!drag) return;
      const d = drag;
      drag = null;
      if (d.moved) { changed(); return; }
      // A click on a state: select it, or draw a process from the selected state to it.
      if (selection && selection.type === 'state' && selection.key !== d.id) {
        const from = selection.key, to = d.id;
        if (!processes.some((p) => p.from === from && p.to === to)) {
          processes = processes.filter((p) => !(p.from === to && p.to === from));
          processes.push({ from, to, path: curveMode ? 'curve' : 'line', n: curveMode ? currentN() : undefined });
        }
        selection = { type: 'process', key: from + '-' + to };
        changed();
        return;
      }
      selection = selection && selection.type === 'state' && selection.key === d.id ? null : { type: 'state', key: d.id };
      stateSelect.value = d.id;
      draw();
    });

    function removeSelection() {
      if (!selection) return;
      if (selection.type === 'state') {
        const id = selection.key;
        states = states.filter((s) => s.id !== id);
        processes = processes.filter((p) => p.from !== id && p.to !== id);
        for (const k of Array.from(shaded)) { const [a, b] = k.split('-'); if (a === id || b === id) shaded.delete(k); }
        stateSelect.value = id;
      } else {
        processes = processes.filter((p) => key(p) !== selection.key);
        shaded.delete(selection.key);
      }
      selection = null;
      changed();
    }
    deleteBtn.addEventListener('click', removeSelection);
    canvas.addEventListener('keydown', (e) => {
      if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); removeSelection(); }
      if (e.key === 'Escape') { selection = null; draw(); }
    });
    reverseBtn.addEventListener('click', () => {
      const p = selectedProcess();
      if (!p) return;
      const wasShaded = shaded.delete(key(p));
      [p.from, p.to] = [p.to, p.from];
      if (wasShaded) shaded.add(key(p));
      selection = { type: 'process', key: key(p) };
      changed();
    });
    shadeBtn.addEventListener('click', () => {
      const p = selectedProcess();
      if (!p) return;
      const k = key(p);
      if (shaded.has(k)) shaded.delete(k); else shaded.add(k);
      changed();
    });
    clearBtn.addEventListener('click', () => {
      states = []; processes = []; shaded = new Set(); selection = null;
      stateSelect.value = stateIds[0];
      changed();
    });

    // Width follows the pane.
    function measure() {
      const w = Math.min(640, Math.max(280, root.clientWidth || 560));
      if (Math.abs(w - width) > 1) { width = w; drawGrid(); draw(); }
    }
    if (window.ResizeObserver) new ResizeObserver(measure).observe(root);
    requestAnimationFrame(measure);

    setCurveMode(false);
    drawGrid();
    draw();

    return {
      element: root,
      focus() { try { canvas.focus(); } catch (_) { /* ignore */ } },
      getValue() {
        if (!states.length) return '';
        return JSON.stringify({
          states: states.map((s) => ({ id: s.id, x: round(s.x), y: round(s.y) })),
          processes: processes.map((p) => p.path === 'curve' ? { from: p.from, to: p.to, path: 'curve', n: round(isFinite(p.n) ? p.n : 1) } : { from: p.from, to: p.to, path: 'line' }),
          shaded: Array.from(shaded)
        });
      },
      setValue(json) {
        let v = null;
        try { v = json ? JSON.parse(json) : null; } catch (_) { v = null; }
        states = v && Array.isArray(v.states) ? v.states.map((s) => ({ id: String(s.id), x: +s.x, y: +s.y })) : [];
        processes = v && Array.isArray(v.processes) ? v.processes.map((p) => ({ from: String(p.from), to: String(p.to), path: p.path === 'curve' ? 'curve' : 'line', n: p.n })) : [];
        shaded = new Set(v && Array.isArray(v.shaded) ? v.shaded.map(String) : []);
        selection = null;
        nextUnplaced();
        draw();
      }
    };
  }

  window.ThubanDiagram = { create };
})();
