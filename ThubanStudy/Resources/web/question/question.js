/*
 * Thuban Study — question form page (question.html, hosted by QuestionFormWebView).
 * Contract: ARCHITECTURE.md → "Web bridge protocols" → question.html.
 *
 *   Swift → JS   load {instance}            render stem + parts
 *                setVerdicts {verdicts: {partId: {outcome, message, failedConditions}}}
 *                focusPart {partId}
 *                insert {latex}             insert at the caret of the focused math field (calculator "copy to answer")
 *                setKeyboardVisible {visible}
 *                theme {css, isDark}        handled by shared/bridge.js
 *   JS → Swift   ready, input {partId, latex, ascii} (debounced 150 ms), submit {}, keyboardVisible {visible}, height {px}
 *
 * Plain ES2020, no build step. Vendors: MathLive 0.110 (UMD global `MathLive`), marked, DOMPurify.
 */
(function () {
  'use strict';

  /* ================================================================ config */

  const ON_BUNDLE = location.protocol === 'thuban:';
  // Vendor files are referenced as absolute thuban://bundle/… URLs in the app. When the page is opened straight
  // from disk in Safari (debugging), the same files are reachable relative to this page.
  const VENDOR_URL = ON_BUNDLE ? 'thuban://bundle/vendor/' : new URL('../vendor/', location.href).href;
  const FONTS_DIRECTORY = ON_BUNDLE ? 'thuban://bundle/vendor/mathlive/fonts' : VENDOR_URL + 'mathlive/fonts';

  const INPUT_DEBOUNCE_MS = 150;
  const MATH_PLACEHOLDER = 'Type math';
  const NUMERIC_PLACEHOLDER = 'Type a number';
  const DEFAULT_MATH_HINT = 'Any algebraically equivalent form is accepted.';

  const thuban = window.thuban;

  /* ============================================== shared math input */

  // Inline shortcuts, keyboard layouts and field options live in shared/mathinput.js (also used by the equation editor).
  const THUBAN_SHORTCUTS = window.ThubanMathInput.shortcuts;
  const KEYBOARD_LAYOUTS = window.ThubanMathInput.layouts;
  const configureMathfield = window.ThubanMathInput.configure;

  /* =============================================================== state */

  let MathfieldElement = null;     // set by init() once MathLive is available
  let renderMathInElement = null;
  let ready = false;               // init() finished
  let instance = null;             // last loaded QuestionInstanceView
  let entries = [];                // one per part, in order
  const entryById = new Map();
  let lastFocusedField = null;     // the math-field that most recently had focus
  let keyboardVisible = false;
  let lastHeight = -1;
  const pendingInputs = new Map(); // partId → debounce timer
  const queued = [];               // messages received before init finished

  const formEl = document.getElementById('form');
  const stemEl = document.getElementById('stem');
  const partsEl = document.getElementById('parts');

  /* ===================================================== rich text render */

  const RENDER_OPTIONS = {
    TeX: {
      delimiters: { inline: [['$', '$'], ['\\(', '\\)']], display: [['$$', '$$'], ['\\[', '\\]']] },
      processEnvironments: true
    },
    asciiMath: null,
    renderAccessibleContent: 'mathml',
    skipTags: ['noscript', 'style', 'textarea', 'pre', 'code', 'math-field', 'annotation', 'annotation-xml']
  };

  function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // Markdown → sanitized HTML, with every math span protected from the Markdown parser
  // (otherwise `_` and `\` inside LaTeX get mangled). MathLive renders the math afterwards.
  const MATH_SPAN = /\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|\$(?:\\.|[^$\n\\])+?\$/g;
  function markdownToHtml(source) {
    const text = String(source == null ? '' : source);
    const math = [];
    const shielded = text.replace(MATH_SPAN, (m) => { math.push(m); return '' + (math.length - 1) + ''; });
    let html;
    if (window.marked && typeof window.marked.parse === 'function') {
      html = window.marked.parse(shielded, { gfm: true, breaks: false, async: false });
    } else {
      html = '<p>' + escapeHtml(shielded) + '</p>';
    }
    if (window.DOMPurify) {
      html = window.DOMPurify.sanitize(html, { USE_PROFILES: { html: true }, FORBID_TAGS: ['style'] });
    }
    return html.replace(/(\d+)/g, (_, i) => escapeHtml(math[Number(i)] || ''));
  }

  /// MathLive has \\ldots and \\cdots but not amsmath's \\dots family; rewrite them in the text before rendering.
  function fixDots(el) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.nodeValue.indexOf('\\dots') < 0) continue;
      node.nodeValue = node.nodeValue
        .replace(/\\dots[bm](?![a-zA-Z])/g, '\\cdots')
        .replace(/\\dots[cio]?(?![a-zA-Z])/g, '\\ldots');
    }
  }

  function renderRich(el, source) {
    el.innerHTML = markdownToHtml(source);
    fixDots(el);
    if (renderMathInElement) {
      try { renderMathInElement(el, RENDER_OPTIONS); }
      catch (err) { console.error('[question] math render failed:', err); }
    }
  }

  /* ===================================================== part rendering */

  // answerKind arrives as "math" | "numeric" | "text" | "choice" | "freeResponse", or as a Swift enum object
  // such as {"choice": {"options": […]}}. Normalize to the bare name.
  function kindOf(part) {
    const k = part.answerKind;
    if (typeof k === 'string') return k;
    if (k && typeof k === 'object') { const keys = Object.keys(k); if (keys.length) return keys[0]; }
    return 'math';
  }
  function choicesOf(part) {
    if (Array.isArray(part.choices)) return part.choices;
    const k = part.answerKind;
    if (k && typeof k === 'object' && k.choice && Array.isArray(k.choice.options)) return k.choice.options;
    return [];
  }
  const isMathKind = (kind) => kind === 'math' || kind === 'numeric';

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function buildMathInput(entry, part) {
    const wrap = el('div', 'mf-wrap');
    const mf = new MathfieldElement();
    mf.dataset.partId = part.id;
    mf.setAttribute('aria-label', 'Answer for part ' + part.id);
    wrap.appendChild(mf);
    const placeholder = el('span', 'mf-placeholder', entry.kind === 'numeric' ? NUMERIC_PLACEHOLDER : MATH_PLACEHOLDER);
    placeholder.setAttribute('aria-hidden', 'true');
    wrap.appendChild(placeholder);
    entry.wrap = wrap;
    entry.field = mf;
    return wrap;
  }

  /// "m^3/kg" → m³/kg, "ft*lbf/s" → ft·lbf/s, "W/m^2·K" → W/m²·K (HTML-escaped, exponents as superscripts).
  function formatUnit(text) {
    const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    return escaped
      .replace(/\\cdot|\*/g, '·')
      .replace(/\\,|\\;|\\ /g, ' ')
      .replace(/\\(?:mathrm|text)\{([^{}]*)\}/g, '$1')
      .replace(/\^\{([^{}]*)\}|\^(-?[0-9]+)/g, (m, a, b) => '<sup>' + (a || b) + '</sup>');
  }

  /// A short text box that widens with what is typed (up to the pane).
  function autosize(input) {
    const measure = () => {
      input.style.width = '0px';
      input.style.width = Math.max(150, input.scrollWidth + 24) + 'px';
    };
    input.addEventListener('input', measure);
    requestAnimationFrame(measure);
  }

  function buildTextInput(entry, part) {
    const input = el('input', 'field');
    input.type = 'text';
    autosize(input);
    input.autocomplete = 'off';
    input.spellcheck = false;
    input.placeholder = 'Type your answer';
    input.setAttribute('aria-label', 'Answer for part ' + part.id);
    input.dataset.partId = part.id;
    entry.field = input;
    return input;
  }

  function buildDiagram(entry, part) {
    entry.diagram = window.ThubanDiagram.create(part.diagram || {}, () => onValueChanged(entry));
    return entry.diagram.element;
  }

  function buildFreeResponse(entry, part) {
    const ta = el('textarea', 'field');
    ta.rows = 4;
    ta.placeholder = 'Write your response';
    ta.setAttribute('aria-label', 'Response for part ' + part.id);
    ta.dataset.partId = part.id;
    entry.field = ta;
    return ta;
  }

  function buildChoice(entry, part) {
    const group = el('fieldset', 'choice-group');
    const legend = el('legend', 'sr-only', 'Choices for part ' + part.id);
    group.appendChild(legend);
    const name = 'choice-' + part.id;
    entry.radios = [];
    // Picture options (graphs, phase portraits, sketches): a grid of figures, each with its label.
    const images = Array.isArray(part.choiceImages) ? part.choiceImages : null;
    if (images) group.classList.add('choice-grid');
    choicesOf(part).forEach((choice, i) => {
      const label = el('label', images ? 'choice choice-figure' : 'choice');
      const radio = el('input');
      radio.type = 'radio';
      radio.name = name;
      radio.value = String(choice);
      radio.dataset.partId = part.id;
      radio.dataset.index = String(i);
      const text = el('span', 'choice-text');
      renderRich(text, String(choice));
      if (images) {
        const picture = el('div', 'choice-picture');
        if (images[i]) {
          const img = el('img');
          img.src = images[i];
          img.alt = String(choice);
          img.addEventListener('load', () => scheduleHeight(), { once: true });
          picture.appendChild(img);
        } else {
          picture.classList.add('pending');
        }
        const caption = el('div', 'choice-caption');
        caption.appendChild(radio);
        caption.appendChild(text);
        label.appendChild(picture);
        label.appendChild(caption);
      } else {
        label.appendChild(radio);
        label.appendChild(text);
      }
      group.appendChild(label);
      entry.radios.push(radio);
    });
    return group;
  }

  function buildPart(part, index) {
    const kind = kindOf(part);
    const entry = { id: String(part.id), part, kind, index, row: null, wrap: null, field: null, radios: [],
      echo: null, verdictEl: null, verdict: null };

    const row = el('section', 'part');
    row.dataset.partId = entry.id;
    row.setAttribute('aria-label', 'Part ' + entry.id);
    row.appendChild(el('div', 'part-label', '(' + entry.id + ')'));

    const body = el('div', 'part-body');
    const prompt = el('div', 'part-prompt');
    renderRich(prompt, part.prompt);
    body.appendChild(prompt);

    const inputWrap = el('div', 'part-input');
    let control;
    if (isMathKind(kind)) control = buildMathInput(entry, part);
    else if (kind === 'choice') control = buildChoice(entry, part);
    else if (kind === 'freeResponse') control = buildFreeResponse(entry, part);
    else if (kind === 'diagram') control = buildDiagram(entry, part);
    else control = buildTextInput(entry, part);
    inputWrap.appendChild(control);
    // The unit follows the box: the student types only the number.
    if (part.unit && kind !== 'choice' && kind !== 'freeResponse' && kind !== 'diagram') {
      const unit = el('span', 'part-unit');
      unit.innerHTML = formatUnit(String(part.unit));
      unit.setAttribute('aria-label', 'in ' + String(part.unit));
      inputWrap.classList.add('has-unit');
      inputWrap.appendChild(unit);
    }
    body.appendChild(inputWrap);

    if (isMathKind(kind)) {
      entry.echo = el('div', 'part-echo');
      entry.echo.setAttribute('aria-label', 'As typed');
      body.appendChild(entry.echo);
    }

    const hintText = part.conditionsText != null ? String(part.conditionsText)
      : (isMathKind(kind) ? DEFAULT_MATH_HINT : '');
    const hint = el('div', 'part-hint');
    if (hintText) renderRich(hint, hintText);
    body.appendChild(hint);

    entry.verdictEl = el('div', 'part-verdict');
    entry.verdictEl.setAttribute('aria-live', 'polite');
    body.appendChild(entry.verdictEl);

    row.appendChild(body);
    entry.row = row;
    return entry;
  }

  // Apply a prefilled value (latex for math kinds, text otherwise) without posting an 'input'.
  function setValue(entry, value) {
    if (value == null) return;
    const v = String(value);
    if (isMathKind(entry.kind)) {
      entry.field.value = v;
      refreshEcho(entry);
    } else if (entry.kind === 'choice') {
      for (const r of entry.radios) r.checked = (r.value === v);
    } else if (entry.kind === 'diagram') {
      entry.diagram.setValue(v);
    } else {
      entry.field.value = v;
    }
  }

  function wireEntry(entry) {
    if (isMathKind(entry.kind)) {
      const mf = entry.field;
      mf.addEventListener('input', () => { refreshEcho(entry); onValueChanged(entry); });
      mf.addEventListener('focusin', () => { lastFocusedField = mf; });
      // 'change' fires on Enter / the ⏎ keycap (commit) and also on blur when the value changed;
      // only the former should advance, and hasFocus() is already false during the blur one.
      mf.addEventListener('change', () => { if (mf.hasFocus()) onEnter(entry); });
    } else if (entry.kind === 'choice') {
      for (const r of entry.radios) r.addEventListener('change', () => onValueChanged(entry));
    } else if (entry.kind === 'diagram') {
      // The diagram reports its own changes.
    } else {
      entry.field.addEventListener('input', () => onValueChanged(entry));
    }
  }

  // ASCII-math separates adjacent single letters ("168.1m g" for 168.1mg, "k N" for kN); written together they
  // mean the same product and read as the unit the student typed. Function names ("sin x") stay apart.
  const ECHO_FUNCTIONS = new Set(['sin', 'cos', 'tan', 'sec', 'csc', 'cot', 'arcsin', 'arccos', 'arctan', 'sinh', 'cosh',
    'tanh', 'ln', 'log', 'exp', 'sqrt', 'abs', 'lim', 'det', 'max', 'min']);
  function joinLetters(ascii) {
    return String(ascii).replace(/([A-Za-z]+) (?=[A-Za-z])/g, (match, word) => ECHO_FUNCTIONS.has(word) ? match : word);
  }

  function refreshEcho(entry) {
    const mf = entry.field;
    let latex = '', ascii = '';
    try { latex = mf.getValue('latex'); ascii = mf.getValue('ascii-math'); } catch (_) { /* not mounted yet */ }
    if (entry.echo) entry.echo.textContent = latex.trim() === '' ? '' : joinLetters(ascii);
    if (entry.wrap) entry.wrap.dataset.empty = latex.trim() === '' ? 'true' : 'false';
  }

  /* ============================================================= values */

  function valueOf(entry) {
    if (isMathKind(entry.kind)) {
      let latex = '', ascii = '';
      try { latex = entry.field.getValue('latex'); ascii = entry.field.getValue('ascii-math'); } catch (_) { /* ignore */ }
      return { latex, ascii };
    }
    if (entry.kind === 'diagram') {
      const json = entry.diagram.getValue();
      return { latex: json, ascii: json };
    }
    if (entry.kind === 'choice') {
      const checked = entry.radios.find((r) => r.checked);
      const v = checked ? checked.value : '';
      return { latex: v, ascii: v };
    }
    const v = entry.field ? entry.field.value : '';
    return { latex: v, ascii: v };
  }

  function postInput(entry) {
    const v = valueOf(entry);
    thuban.send('input', { partId: entry.id, latex: v.latex, ascii: v.ascii });
  }

  function onValueChanged(entry) {
    // A verdict no longer describes the current answer once the student edits it.
    if (entry.verdict && entry.verdictEl) entry.verdictEl.classList.add('is-stale');
    clearTimeout(pendingInputs.get(entry.id));
    pendingInputs.set(entry.id, setTimeout(() => { pendingInputs.delete(entry.id); postInput(entry); }, INPUT_DEBOUNCE_MS));
    scheduleHeight();
  }

  function flushInputs() {
    for (const [id, timer] of pendingInputs) {
      clearTimeout(timer);
      const entry = entryById.get(id);
      if (entry) postInput(entry);
    }
    pendingInputs.clear();
  }

  /* ========================================================== navigation */

  function focusEntry(entry) {
    if (!entry) return;
    let target = null;
    if (isMathKind(entry.kind)) target = entry.field;
    else if (entry.kind === 'choice') target = entry.radios.find((r) => r.checked) || entry.radios[0] || null;
    else if (entry.kind === 'diagram') { entry.diagram.focus(); return; }
    else target = entry.field;
    if (!target) return;
    try { target.focus(); } catch (_) { /* ignore */ }
    if (typeof target.scrollIntoView === 'function') target.scrollIntoView({ block: 'nearest' });
  }

  function submit() {
    flushInputs();
    thuban.send('submit', {});
  }

  // Enter in the last part submits; elsewhere it moves to the next part.
  function onEnter(entry) {
    if (entry.index >= entries.length - 1) submit();
    else focusEntry(entries[entry.index + 1]);
  }

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    if (e.metaKey || e.ctrlKey) {            // Cmd/Ctrl+Enter anywhere → submit
      e.preventDefault();
      submit();
      return;
    }
    if (e.altKey || e.shiftKey) return;
    const target = e.target;
    if (!target || target.tagName === 'MATH-FIELD') return;      // math fields advance via their 'change' event
    if (target.tagName === 'TEXTAREA') return;                    // newline; Cmd+Enter submits
    const partId = target.dataset && target.dataset.partId;
    const entry = partId ? entryById.get(partId) : null;
    if (!entry) return;
    e.preventDefault();
    onEnter(entry);
  }, true);

  /* ============================================================ verdicts */

  const ICONS = {
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    cross: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6.5 6.5l11 11"/><path d="M17.5 6.5l-11 11"/></svg>',
    tilde: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4.5 13.5c2-3.5 4.5-3.5 7 0s5 3.5 8 0"/></svg>',
    question: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 9.5a3 3 0 1 1 4.5 2.6c-1 .6-1.5 1.2-1.5 2.2v.4"/><path d="M12 18h.01"/></svg>',
    compass: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 5.5l1.5 4 4 1.5-4 1.5-1.5 4-1.5-4-4-1.5 4-1.5z"/></svg>'
  };
  const VERDICT_STYLE = {
    correct: { chip: 'chip-pos', icon: 'check', fallback: 'Correct' },
    incorrect: { chip: 'chip-neg', icon: 'cross', fallback: 'Not quite' },
    equivalentButConditionFailed: { chip: 'chip-warn', icon: 'tilde', fallback: 'Equivalent, but a condition of this part is not met' },
    unparseable: { chip: 'chip-neutral', icon: 'question', fallback: 'That could not be read as math' },
    needsTutor: { chip: 'chip-signal', icon: 'compass', fallback: 'The tutor will look at this one' }
  };

  function renderVerdict(entry, verdict) {
    entry.verdict = verdict || null;
    entry.verdictEl.classList.remove('is-stale');
    entry.verdictEl.textContent = '';
    if (!verdict || !verdict.outcome) {
      delete entry.row.dataset.verdict;
      return;
    }
    const style = VERDICT_STYLE[verdict.outcome] || VERDICT_STYLE.unparseable;
    entry.row.dataset.verdict = verdict.outcome;
    const chip = el('span', 'chip chip-wrap ' + style.chip);
    chip.setAttribute('role', 'status');
    chip.innerHTML = ICONS[style.icon];
    const message = (verdict.message && String(verdict.message).trim()) || style.fallback;
    const text = el('span');
    renderRich(text, message);
    chip.appendChild(text);
    entry.verdictEl.appendChild(chip);
  }

  /* ================================================================ load */

  function load(payload) {
    const inst = (payload && payload.instance) || payload || {};
    instance = inst;
    flushInputs();
    pendingInputs.clear();
    entries = [];
    entryById.clear();
    lastFocusedField = null;
    partsEl.textContent = '';

    renderRich(stemEl, inst.stem || '');

    const parts = Array.isArray(inst.parts) ? inst.parts : [];
    parts.forEach((part, index) => {
      const entry = buildPart(part, index);
      entries.push(entry);
      entryById.set(entry.id, entry);
      partsEl.appendChild(entry.row);
      // configure after the element is connected: MathLive mounts on connectedCallback
      if (isMathKind(entry.kind)) configureMathfield(entry.field);
      setValue(entry, part.value);
      if (isMathKind(entry.kind)) refreshEcho(entry);
      wireEntry(entry);
      if (part.verdict) renderVerdict(entry, part.verdict);
    });

    formEl.setAttribute('aria-busy', 'false');
    lastHeight = -1;               // always report after a fresh render
    scheduleHeight();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(scheduleHeight);
  }

  function setVerdicts(payload) {
    const map = (payload && payload.verdicts && typeof payload.verdicts === 'object') ? payload.verdicts : (payload || {});
    for (const partId of Object.keys(map)) {
      const entry = entryById.get(String(partId));
      if (entry) renderVerdict(entry, map[partId]);
    }
    scheduleHeight();
  }

  function focusPart(payload) {
    const entry = entryById.get(String(payload && payload.partId));
    focusEntry(entry);
  }

  // The math field that should receive programmatic insertions.
  function targetField() {
    const active = document.activeElement;
    if (active && active.tagName === 'MATH-FIELD') return active;
    if (lastFocusedField && lastFocusedField.isConnected) return lastFocusedField;
    const first = entries.find((e) => isMathKind(e.kind));
    return first ? first.field : null;
  }

  function insert(payload) {
    const latex = payload && payload.latex;
    if (typeof latex !== 'string' || latex === '') return;
    const mf = targetField();
    if (!mf) return;
    mf.focus();
    try {
      mf.insert(latex, { format: 'latex', mode: 'math', focus: true, feedback: false, selectionMode: 'placeholder' });
    } catch (err) {
      console.error('[question] insert failed:', err);
      return;
    }
    const entry = entryById.get(mf.dataset.partId);
    if (entry) { refreshEcho(entry); onValueChanged(entry); }
  }

  /* ============================================================ keyboard */

  function keyboard() { return window.mathVirtualKeyboard || null; }

  function setKeyboardVisible(payload) {
    const kb = keyboard();
    if (!kb) return;
    const visible = !!(payload && payload.visible);
    if (visible) {
      // The keyboard types into the focused math field; make sure there is one.
      const mf = targetField();
      if (mf && !mf.hasFocus()) mf.focus();
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
    const px = document.body.scrollHeight;
    if (px === lastHeight) return;
    lastHeight = px;
    thuban.send('height', { px });
  }
  function scheduleHeight() {
    if (heightRaf) return;
    heightRaf = requestAnimationFrame(postHeight);
  }

  /* ================================================================ init */

  // Debug affordance: opened from disk in Safari, the absolute thuban:// vendor tags fail; load the same files relatively.
  function loadScript(url) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = url; s.async = false;
      s.onload = resolve; s.onerror = () => reject(new Error('failed to load ' + url));
      document.head.appendChild(s);
    });
  }
  async function ensureVendor() {
    if (window.MathLive && window.marked && window.DOMPurify) return;
    if (ON_BUNDLE) throw new Error('vendor libraries missing from the bundle');
    const css = document.getElementById('mathlive-static-css');
    if (css) css.href = VENDOR_URL + 'mathlive/mathlive-static.css';
    if (!window.MathLive) await loadScript(VENDOR_URL + 'mathlive/mathlive.min.js');
    if (!window.marked) await loadScript(VENDOR_URL + 'marked/marked.min.js');
    if (!window.DOMPurify) await loadScript(VENDOR_URL + 'dompurify/purify.min.js');
  }

  function init() {
    MathfieldElement = window.MathLive.MathfieldElement;
    renderMathInElement = window.MathLive.renderMathInElement;

    // MathLive statics
    MathfieldElement.fontsDirectory = FONTS_DIRECTORY;
    MathfieldElement.soundsDirectory = null;
    MathfieldElement.keypressVibration = false;

    // Virtual keyboard: our layouts only, mounted on <body>, shown/hidden solely by the native toggle.
    window.ThubanMathInput.installKeyboard(onKeyboardToggle, scheduleHeight);

    // Height reporting
    if (window.ResizeObserver) {
      const ro = new ResizeObserver(scheduleHeight);
      ro.observe(document.documentElement);
      ro.observe(document.body);
    }
    window.addEventListener('resize', scheduleHeight);
    thuban.on('theme', scheduleHeight);

    ready = true;
    // Replay anything Swift sent while the vendors were still loading (only happens in the Safari fallback path).
    for (const [type, payload] of queued.splice(0)) handle(type, payload);

    if (!thuban.hasBridge && !instance) load({ instance: DEMO_INSTANCE });
    scheduleHeight();
  }

  const HANDLERS = { load, setVerdicts, focusPart, insert, setKeyboardVisible };
  function handle(type, payload) {
    if (!ready) { queued.push([type, payload]); return; }
    HANDLERS[type](payload);
  }
  for (const type of Object.keys(HANDLERS)) thuban.on(type, (payload) => handle(type, payload));

  ensureVendor().then(init).catch((err) => {
    console.error('[question] init failed:', err);
    document.getElementById('empty').textContent = 'The question form could not start: ' + err.message;
  });

  /* ======================================================== debug surface */

  // Demo instance shown when there is no native host (open question.html in Safari to eyeball the page).
  const DEMO_INSTANCE = {
    questionId: 'demo', seed: '4f2a',
    stem: 'Let $f(x, y) = x^2 y + 3xy^3 - 2y$. The surface $z = f(x, y)$ passes through the point $P(1, 2, f(1, 2))$.',
    parts: [
      { id: 'a', prompt: 'Find $f_x(1, 2)$.', answerKind: 'numeric', conditionsText: 'Exact value.',
        value: '28', verdict: { outcome: 'correct', message: 'Correct.' } },
      { id: 'b', prompt: 'Find $f_y(1, 2)$.', answerKind: 'numeric', conditionsText: 'Exact value.',
        value: '35', verdict: { outcome: 'correct', message: 'Correct.' } },
      { id: 'c', prompt: 'Write the equation of the tangent plane to the surface at $P$.', answerKind: 'math',
        conditionsText: 'Any algebraically equivalent form is accepted.', value: 'z-22=28(x-1)+35(y-2)',
        verdict: { outcome: 'equivalentButConditionFailed', message: 'Equivalent, but this part asks for the plane solved for $z$.' } },
      { id: 'd', prompt: 'Find the direction of steepest ascent at $P$ as a unit vector. Answer must be **exact** (no rounding).',
        answerKind: 'math', conditionsText: 'Exact form required · fractions and radicals OK' },
      { id: 'e', prompt: 'Which statement about $\\nabla f(1, 2)$ is true?', answerKind: 'choice',
        choices: ['It points in the direction of steepest ascent.', 'It is tangent to the level curve through $P$.', 'It is the zero vector.'],
        value: 'It is tangent to the level curve through $P$.',
        verdict: { outcome: 'incorrect', message: 'Not this one — think about how the gradient sits relative to a level curve.' } },
      { id: 'f', prompt: 'Name the theorem that guarantees $f_{xy} = f_{yx}$ here.', answerKind: 'text',
        conditionsText: 'One or two words.', value: '???',
        verdict: { outcome: 'unparseable', message: 'That could not be read as an answer.' } },
      { id: 'g', prompt: 'In a sentence, explain why the gradient is perpendicular to the level curve.', answerKind: 'freeResponse',
        conditionsText: 'Graded by the tutor.', verdict: { outcome: 'needsTutor' } }
    ]
  };

  window.ThubanQuestion = {
    load: (inst) => handle('load', { instance: inst || DEMO_INSTANCE }),
    setVerdicts: (map) => handle('setVerdicts', map),
    focusPart: (partId) => handle('focusPart', { partId }),
    insert: (latex) => handle('insert', { latex }),
    setKeyboardVisible: (visible) => handle('setKeyboardVisible', { visible }),
    values: () => entries.map((e) => Object.assign({ partId: e.id, kind: e.kind }, valueOf(e))),
    get instance() { return instance; },
    get entries() { return entries; },
    layouts: KEYBOARD_LAYOUTS,
    shortcuts: THUBAN_SHORTCUTS,
    demo: DEMO_INSTANCE
  };
})();
