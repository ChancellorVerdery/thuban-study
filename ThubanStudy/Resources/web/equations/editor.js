/*
 * Thuban Study — equation entry editor (editor.html, hosted by EquationEditorWebView).
 *
 *   Swift → JS   load {equations: [latex]}         one field per equation (at least one)
 *                focus {index}
 *                setKeyboardVisible {visible}
 *                theme {css, isDark}                handled by shared/bridge.js
 *   JS → Swift   ready, changed {equations: [latex]} (on every edit, so a native ⌘⏎ never saves stale text), submit {} (Enter in the last field or ⌘⏎),
 *                keyboardVisible {visible}, height {px}
 *
 * The fields are configured exactly like the answer form's (shared/mathinput.js): same inline shortcuts, same
 * virtual keyboard, Enter moves to the next field.
 */
(function () {
  'use strict';

  const thuban = window.thuban;
  const rowsEl = document.getElementById('rows');
  const addEl = document.getElementById('add');
  const REMOVE_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg>';

  let MathfieldElement = null;
  let ready = false;
  const queued = [];
  let fields = [];
  let lastFocused = null;
  let keyboardVisible = false;
  let lastHeight = -1;

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function latexOf(mf) {
    try { return mf.getValue('latex'); } catch (_) { return mf.value || ''; }
  }

  function values() { return fields.map((f) => latexOf(f.mf)); }

  function refresh(field) {
    const latex = latexOf(field.mf);
    field.latex.textContent = latex;
    field.wrap.dataset.empty = latex.trim() === '' ? 'true' : 'false';
  }

  function postChanged() {
    thuban.send('changed', { equations: values() });
  }

  function renumber() {
    fields.forEach((field, i) => {
      field.index.textContent = String(i + 1);
      field.mf.setAttribute('aria-label', 'Equation ' + (i + 1));
      field.remove.setAttribute('aria-label', 'Remove equation ' + (i + 1));
      field.remove.disabled = fields.length < 2;
      field.remove.title = fields.length < 2 ? 'An entry keeps at least one equation' : 'Remove equation ' + (i + 1);
    });
  }

  function buildRow(latex) {
    const row = el('li', 'eq-row');
    const index = el('div', 'eq-index');
    index.setAttribute('aria-hidden', 'true');
    const body = el('div', 'eq-body');
    const wrap = el('div', 'mf-wrap');
    const mf = new MathfieldElement();
    wrap.appendChild(mf);
    const placeholder = el('span', 'mf-placeholder', 'Type math — try sqrt, /, ^, theta, int');
    placeholder.setAttribute('aria-hidden', 'true');
    wrap.appendChild(placeholder);
    body.appendChild(wrap);
    const latexEl = el('div', 'eq-latex');
    latexEl.setAttribute('aria-label', 'LaTeX');
    body.appendChild(latexEl);
    const remove = el('button', 'remove');
    remove.type = 'button';
    remove.innerHTML = REMOVE_ICON;

    row.appendChild(index);
    row.appendChild(body);
    row.appendChild(remove);

    const field = { row, index, wrap, mf, latex: latexEl, remove };
    rowsEl.appendChild(row);
    window.ThubanMathInput.configure(mf);
    mf.value = String(latex || '');
    refresh(field);

    mf.addEventListener('input', () => { refresh(field); postChanged(); scheduleHeight(); });
    mf.addEventListener('focusin', () => { lastFocused = mf; });
    // 'change' fires on Enter / the ⏎ keycap (and on blur, when hasFocus() is already false).
    mf.addEventListener('change', () => { if (mf.hasFocus()) onEnter(field); });
    remove.addEventListener('click', () => removeField(field));
    return field;
  }

  function onEnter(field) {
    const i = fields.indexOf(field);
    if (i >= 0 && i < fields.length - 1) {
      fields[i + 1].mf.focus();
    } else {
      postChanged();
      thuban.send('submit', {});
    }
  }

  function addField(focus) {
    const field = buildRow('');
    fields.push(field);
    renumber();
    postChanged();
    scheduleHeight();
    if (focus) requestAnimationFrame(() => field.mf.focus());
  }

  function removeField(field) {
    if (fields.length < 2) return;
    const i = fields.indexOf(field);
    field.row.remove();
    fields.splice(i, 1);
    renumber();
    postChanged();
    scheduleHeight();
    const next = fields[Math.min(i, fields.length - 1)];
    if (next) next.mf.focus();
  }

  /* ============================================================ messages */

  function load(payload) {
    const list = Array.isArray(payload && payload.equations) && payload.equations.length ? payload.equations : [''];
    rowsEl.textContent = '';
    fields = list.map(buildRow);
    renumber();
    lastHeight = -1;
    scheduleHeight();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(scheduleHeight);
  }

  function focus(payload) {
    const i = Math.max(0, Math.min(fields.length - 1, Number(payload && payload.index) || 0));
    if (fields[i]) fields[i].mf.focus();
  }

  function keyboard() { return window.mathVirtualKeyboard || null; }

  function setKeyboardVisible(payload) {
    const kb = keyboard();
    if (!kb) return;
    if (payload && payload.visible) {
      const target = (lastFocused && lastFocused.isConnected) ? lastFocused : (fields[0] && fields[0].mf);
      if (target && !target.hasFocus()) target.focus();
      kb.show({ animate: true });
    } else {
      kb.hide({ animate: true });
    }
  }

  function onKeyboardToggle() {
    const kb = keyboard();
    const visible = !!(kb && kb.visible);
    if (visible !== keyboardVisible) {
      keyboardVisible = visible;
      thuban.send('keyboardVisible', { visible });
    }
    scheduleHeight();
  }

  /* ============================================================== height */

  let heightRaf = 0;
  function postHeight() {
    heightRaf = 0;
    const main = document.querySelector('.editor');
    let px = Math.ceil(main.getBoundingClientRect().height);
    const kb = keyboard();
    if (kb && kb.visible && kb.boundingRect) px += Math.ceil(kb.boundingRect.height);
    if (px === lastHeight) return;
    lastHeight = px;
    thuban.send('height', { px });
  }
  // A timer rather than requestAnimationFrame: WebKit may hold animation frames back in a sheet window that is
  // still animating in, and the sheet cannot size itself until the first height arrives.
  function scheduleHeight() {
    if (heightRaf) return;
    heightRaf = setTimeout(postHeight, 16);
  }

  /* ================================================================ init */

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      postChanged();
      thuban.send('submit', {});
    }
  }, true);

  function init() {
    MathfieldElement = window.MathLive.MathfieldElement;
    MathfieldElement.fontsDirectory = 'thuban://bundle/vendor/mathlive/fonts';
    MathfieldElement.soundsDirectory = null;
    MathfieldElement.keypressVibration = false;
    window.ThubanMathInput.installKeyboard(onKeyboardToggle, scheduleHeight);
    addEl.addEventListener('click', () => addField(true));
    if (window.ResizeObserver) new ResizeObserver(scheduleHeight).observe(document.body);
    ready = true;
    for (const [type, payload] of queued.splice(0)) handle(type, payload);
    if (!thuban.hasBridge && fields.length === 0) load({ equations: ['\\sum_{n=0}^{\\infty} ar^n = \\frac{a}{1-r}', ''] });
  }

  const HANDLERS = { load, focus, setKeyboardVisible };
  function handle(type, payload) {
    if (!ready) { queued.push([type, payload]); return; }
    HANDLERS[type](payload);
  }
  for (const type of Object.keys(HANDLERS)) thuban.on(type, (payload) => handle(type, payload));

  if (window.MathLive && window.ThubanMathInput) init();
  else console.error('[editor] MathLive or the shared math input setup is missing');

  window.ThubanEquationEditor = { load: (list) => handle('load', { equations: list }), values };
})();
