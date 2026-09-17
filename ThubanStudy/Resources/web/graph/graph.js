/*
 * graph.js — Desmos 2D / 3D grapher hosted by GraphWebView.
 *
 * Message contract (see ARCHITECTURE.md › Web bridge protocols):
 *   Swift → JS : config {desmosKey, mode?}, setMode {mode}, setExpressions {expressions}, addExpression {…},
 *                removeExpression {id}, clear {}, setViewport {xmin,xmax,ymin,ymax}, getState {}, setState {state},
 *                resetView {}, theme {css, isDark}
 *   JS → Swift : ready, expressionsChanged {expressions:[{id, latex}]}, state {state, mode}, error {message}
 *
 * The Desmos script is injected only after 'config' delivers the API key. One calculator instance exists at a
 * time; each mode ("2d" / "3d") keeps its own expression list so switching modes rebuilds the other calculator
 * with its own content. Messages that arrive before the calculator exists are queued and replayed.
 */
(function () {
  'use strict';

  var DESMOS_API = 'https://www.desmos.com/api/v1.11/calculator.js';
  var LOAD_TIMEOUT_MS = 20000;
  var CHANGE_DEBOUNCE_MS = 250;

  var bridge = window.thuban;
  var container = document.getElementById('calculator');
  var statusEl = document.getElementById('status');
  var statusText = document.getElementById('status-text');
  var noticeEl = document.getElementById('notice');
  var noticeText = document.getElementById('notice-text');
  var noticeDetail = document.getElementById('notice-detail');
  var retryButton = document.getElementById('retry');

  // ---- state ----------------------------------------------------------------------------------------------

  var desmosKey = null;          // API key from 'config'
  var showExpressions = true;    // false for figure panes: paper only, no expression list
  var mode = '2d';               // '2d' | '3d'
  var calculator = null;         // the live Desmos instance
  var scriptEl = null;           // the injected <script>
  var loadTimer = null;
  var loading = false;
  var pendingOps = [];           // [{type, payload}] received before the calculator existed
  var lastReported = '';         // JSON of the last {id, latex} list we reported or applied ourselves
  var changeTimer = null;
  var defaultColor = null;       // the theme accent used for default expression colours

  // Per-mode content. `expressions` mirrors what Swift knows about (id → descriptor); `savedState` is the full
  // Desmos state captured when the mode was last active, which also preserves the viewport.
  var modes = {
    '2d': { expressions: new Map(), savedState: null },
    '3d': { expressions: new Map(), savedState: null }
  };

  // ---- helpers ---------------------------------------------------------------------------------------------

  function cssVar(name, fallback) {
    var v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    return v || fallback;
  }

  function isDark() {
    return document.documentElement.dataset.theme === 'dark';
  }

  function accentColor() {
    return cssVar('--accent', '#e0b15c');
  }

  function send(type, payload) {
    try { bridge.send(type, payload || {}); } catch (e) { console.error('send failed', type, e); }
  }

  function reportError(message, detail) {
    send('error', { message: message + (detail ? ' (' + detail + ')' : '') });
  }

  /** After the calculator has parsed a batch, report every row Desmos could not graph (once, per batch). */
  function reportAnalysis(ids) {
    if (!calculator || !ids.length) return;
    setTimeout(function () {
      var analysis;
      try { analysis = calculator.expressionAnalysis || {}; } catch (e) { return; }
      var problems = [];
      var summary = [];
      ids.forEach(function (id) {
        var a = analysis[id];
        if (a && a.isError) problems.push(id + ': ' + (a.errorMessage || 'error'));
        summary.push(id + '=' + (a ? (a.isError ? 'err' : (a.isGraphable ? 'ok' : 'nograph')) : 'none'));
      });
      send('rowAnalysis', { summary: summary.join(' ') });
      if (problems.length) send('rowErrors', { rows: problems });
    }, 400);
  }

  function showStatus(text) {
    statusText.textContent = text;
    statusEl.hidden = false;
    noticeEl.hidden = true;
  }

  function hideStatus() {
    statusEl.hidden = true;
  }

  function showNotice(detail) {
    noticeText.textContent = 'Desmos could not load — check the API key in Settings › Grapher or your connection.';
    if (detail) { noticeDetail.textContent = detail; noticeDetail.hidden = false; }
    else { noticeDetail.hidden = true; }
    statusEl.hidden = true;
    noticeEl.hidden = false;
  }

  function hideNotice() {
    noticeEl.hidden = true;
  }

  function normalizeMode(m) {
    return String(m || '').toLowerCase() === '3d' ? '3d' : '2d';
  }

  /** Map a lineStyle string from Swift to the Desmos constant. */
  function lineStyleFor(name) {
    if (!window.Desmos || !Desmos.Styles) return undefined;
    switch (String(name || '').toUpperCase()) {
      case 'DASHED': return Desmos.Styles.DASHED;
      case 'DOTTED': return Desmos.Styles.DOTTED;
      case 'SOLID': return Desmos.Styles.SOLID;
      default: return undefined;
    }
  }

  /** Build the object handed to calculator.setExpression from a Swift expression descriptor. */
  function toDesmosExpression(e) {
    var out = { id: String(e.id) };
    if (typeof e.latex === 'string') out.latex = e.latex;
    out.color = e.color || defaultColor || accentColor();
    var style = lineStyleFor(e.lineStyle);
    if (style) out.lineStyle = style;
    if (typeof e.label === 'string' && e.label.length) {
      out.label = e.label;
      out.showLabel = e.showLabel !== false;
    } else if (typeof e.showLabel === 'boolean') {
      out.showLabel = e.showLabel;
    }
    if (typeof e.hidden === 'boolean') out.hidden = e.hidden;
    if (typeof e.fillOpacity === 'number') { out.fill = true; out.fillOpacity = String(e.fillOpacity); }
    if (e.parametricDomain && typeof e.parametricDomain === 'object') {
      out.parametricDomain = { min: String(e.parametricDomain.min), max: String(e.parametricDomain.max) };
    }
    if (typeof e.points === 'boolean') out.points = e.points;
    if (typeof e.lineWidth === 'number') out.lineWidth = String(e.lineWidth);
    if (e.sliderBounds && typeof e.sliderBounds === 'object') {
      var b = {};
      if (e.sliderBounds.min !== undefined) b.min = String(e.sliderBounds.min);
      if (e.sliderBounds.max !== undefined) b.max = String(e.sliderBounds.max);
      if (e.sliderBounds.step !== undefined) b.step = String(e.sliderBounds.step);
      out.sliderBounds = b;
    }
    return out;
  }

  /** {id, latex} for every expression row currently in the calculator (folders, text and images are skipped). */
  function currentList() {
    if (!calculator) return [];
    var list = [];
    try {
      calculator.getExpressions().forEach(function (e) {
        if (e.type === 'expression' && typeof e.latex === 'string') list.push({ id: e.id, latex: e.latex });
      });
    } catch (err) { /* calculator being torn down */ }
    return list;
  }

  /** Remember the current content as "already known to Swift" so our own edits are not echoed back. */
  function snapshot() {
    lastReported = JSON.stringify(currentList());
    syncModeMap();
  }

  /** Keep the active mode's expression map in step with the calculator (user edits included). */
  function syncModeMap() {
    if (!calculator) return;
    var map = modes[mode].expressions;
    map.clear();
    try {
      calculator.getExpressions().forEach(function (e) {
        if (e.type === 'expression') map.set(e.id, e);
      });
    } catch (err) { /* ignore */ }
  }

  // ---- change observation --------------------------------------------------------------------------------

  function onCalculatorChange() {
    if (changeTimer) clearTimeout(changeTimer);
    changeTimer = setTimeout(function () {
      changeTimer = null;
      if (!calculator) return;
      var list = currentList();
      var key = JSON.stringify(list);
      if (key === lastReported) return;
      lastReported = key;
      syncModeMap();
      send('expressionsChanged', { expressions: list, mode: mode });
    }, CHANGE_DEBOUNCE_MS);
  }

  // ---- Desmos script loading -----------------------------------------------------------------------------

  function loadDesmos() {
    if (window.Desmos) { createCalculator(); return; }
    if (loading) return;
    if (!desmosKey) { showNotice('No API key configured.'); return; }
    loading = true;
    hideNotice();
    showStatus('Loading Desmos…');

    scriptEl = document.createElement('script');
    scriptEl.src = DESMOS_API + '?apiKey=' + encodeURIComponent(desmosKey);
    scriptEl.async = true;
    scriptEl.onload = function () {
      clearTimeout(loadTimer);
      loading = false;
      if (!window.Desmos) { failLoad('Script loaded but Desmos is undefined.'); return; }
      createCalculator();
    };
    scriptEl.onerror = function () {
      clearTimeout(loadTimer);
      loading = false;
      failLoad('Network error or invalid API key.');
    };
    loadTimer = setTimeout(function () {
      if (!window.Desmos) { loading = false; failLoad('Timed out after ' + (LOAD_TIMEOUT_MS / 1000) + ' s.'); }
    }, LOAD_TIMEOUT_MS);
    document.head.appendChild(scriptEl);
  }

  function failLoad(detail) {
    if (scriptEl && scriptEl.parentNode) scriptEl.parentNode.removeChild(scriptEl);
    scriptEl = null;
    showNotice(detail);
    reportError('Desmos could not load', detail);
  }

  retryButton.addEventListener('click', function () {
    loadDesmos();
  });

  // ---- calculator lifecycle ------------------------------------------------------------------------------

  function calculatorOptions() {
    defaultColor = accentColor();
    // Desmos cycles through the `colors` map for new rows: putting the theme accent first makes it the default.
    var colors = { ACCENT: defaultColor };
    if (Desmos.Colors) {
      Object.keys(Desmos.Colors).forEach(function (k) { colors[k] = Desmos.Colors[k]; });
    }
    var options = {
      expressions: showExpressions,
      keypad: false,
      settingsMenu: showExpressions,
      zoomButtons: true,
      border: false,
      expressionsCollapsed: false,
      lockViewport: false,
      colors: colors
    };
    var theme = themeSettings();
    Object.keys(theme).forEach(function (k) { options[k] = theme[k]; });
    return options;
  }

  /**
   * The Desmos settings that carry the theme. In 2D the paper, expression list and chrome take the app's own
   * tokens (`backgroundColor` / `textColor` / `accentColor` are first-class Desmos settings, validated as hex).
   * `invertedColors` is a plain CSS `filter: invert()` over the whole calculator, so it must never be combined
   * with custom colours; it is used only for 3D, whose plane material keys off it.
   */
  function themeSettings() {
    if (mode === '3d') return { invertedColors: isDark() };
    return {
      invertedColors: false,
      backgroundColor: cssVar('--panel', '#fffdf7'),
      textColor: cssVar('--ink', '#161a21'),
      accentColor: accentColor()
    };
  }

  /** True when the live calculator reports every theme setting we asked for (unknown settings count as applied). */
  function themeSettingsApplied(wanted) {
    try {
      var s = calculator && calculator.settings;
      if (!s) return true;
      return Object.keys(wanted).every(function (k) {
        var have = s[k];
        if (have === undefined || have === null) return true;
        if (typeof have === 'string' && typeof wanted[k] === 'string') return have.toLowerCase() === wanted[k].toLowerCase();
        return have === wanted[k];
      });
    } catch (err) { return true; }
  }

  function createCalculator() {
    destroyCalculator();
    hideNotice();
    document.documentElement.dataset.graphMode = mode;   // graph.html styles Desmos chrome per mode
    var ctor = mode === '3d' ? Desmos.Calculator3D : Desmos.GraphingCalculator;
    if (typeof ctor !== 'function') {
      var msg = mode === '3d' ? 'Desmos 3D is not available for this API key.' : 'Desmos.GraphingCalculator is unavailable.';
      showNotice(msg);
      reportError(msg);
      return;
    }
    try {
      calculator = ctor(container, calculatorOptions());
    } catch (err) {
      calculator = null;
      var detail = (err && err.message) ? err.message : String(err);
      showNotice(detail);
      reportError('Desmos failed to initialize', detail);
      return;
    }
    hideStatus();

    // Restore this mode's content: the full saved state if we have one, otherwise the expression list.
    var m = modes[mode];
    if (m.savedState) {
      try { calculator.setState(m.savedState); } catch (err) { applyExpressionMap(m.expressions); }
    } else if (m.expressions.size) {
      applyExpressionMap(m.expressions);
    }
    snapshot();

    calculator.observeEvent('change', onCalculatorChange);

    // Replay anything that arrived while we had no calculator.
    var ops = pendingOps;
    pendingOps = [];
    ops.forEach(function (op) { handle(op.type, op.payload); });
  }

  function destroyCalculator() {
    if (!calculator) return;
    try { calculator.unobserveEvent('change'); } catch (err) { /* ignore */ }
    try { calculator.destroy(); } catch (err) { /* ignore */ }
    calculator = null;
    container.innerHTML = '';
  }

  function applyExpressionMap(map) {
    map.forEach(function (e) {
      try { calculator.setExpression(toDesmosExpression(e)); } catch (err) { console.warn('setExpression failed', e, err); }
    });
  }

  /** Run `fn` now if the calculator exists, otherwise queue the message until it does. */
  function whenReady(type, payload, fn) {
    if (calculator) { fn(); }
    else { pendingOps.push({ type: type, payload: payload }); }
  }

  // ---- message handlers ----------------------------------------------------------------------------------

  function handle(type, payload) {
    var h = handlers[type];
    if (h) h(payload || {});
  }

  var handlers = {

    config: function (p) {
      if (p.mode) mode = normalizeMode(p.mode);
      if (typeof p.expressions === 'boolean') showExpressions = p.expressions;
      var key = p.desmosKey || p.apiKey || '';
      if (window.Desmos) {
        // Script already present (e.g. the key was re-sent): just (re)build the calculator.
        if (!calculator) createCalculator();
        return;
      }
      desmosKey = key;
      loadDesmos();
    },

    setMode: function (p) {
      var next = normalizeMode(p.mode);
      if (next === mode && calculator) return;
      if (calculator) {
        try { modes[mode].savedState = calculator.getState(); } catch (err) { modes[mode].savedState = null; }
        syncModeMap();
      }
      mode = next;
      if (window.Desmos) createCalculator();
      // Otherwise the mode is picked up when the script finishes loading.
    },

    setExpressions: function (p) {
      whenReady('setExpressions', p, function () {
        var list = Array.isArray(p.expressions) ? p.expressions : [];
        var map = modes[mode].expressions;
        map.clear();
        // Remove rows one by one rather than setBlank(): Swift re-sends the list on every mode switch and page
        // load, and the viewport (or 3D camera) the student set must survive that.
        try {
          calculator.getExpressions().forEach(function (e) {
            try { calculator.removeExpression({ id: e.id }); } catch (err) { /* ignore */ }
          });
        } catch (err) { /* ignore */ }
        list.forEach(function (e) {
          if (!e || e.id === undefined) return;
          map.set(String(e.id), e);
          try { calculator.setExpression(toDesmosExpression(e)); } catch (err) { console.warn('setExpression failed', e, err); }
        });
        snapshot();
        reportAnalysis(list.map(function (e) { return String(e.id); }));
      });
    },

    addExpression: function (p) {
      whenReady('addExpression', p, function () {
        var e = p.expression || p;
        if (!e || e.id === undefined) return;
        modes[mode].expressions.set(String(e.id), e);
        try { calculator.setExpression(toDesmosExpression(e)); } catch (err) { console.warn('setExpression failed', e, err); }
        snapshot();
      });
    },

    removeExpression: function (p) {
      whenReady('removeExpression', p, function () {
        if (p.id === undefined) return;
        var id = String(p.id);
        modes[mode].expressions.delete(id);
        try { calculator.removeExpression({ id: id }); } catch (err) { /* ignore */ }
        // The row may belong to the other mode (Swift tracks both); drop it there too so it does not come back.
        Object.keys(modes).forEach(function (k) {
          if (k === mode) return;
          modes[k].expressions.delete(id);
          var s = modes[k].savedState;
          if (s && s.expressions && Array.isArray(s.expressions.list)) {
            s.expressions.list = s.expressions.list.filter(function (e) { return !e || e.id !== id; });
          }
        });
        snapshot();
      });
    },

    clear: function (p) {
      whenReady('clear', p, function () {
        modes[mode].expressions.clear();
        try { calculator.setBlank(); } catch (err) { /* ignore */ }
        snapshot();
      });
    },

    setViewport: function (p) {
      whenReady('setViewport', p, function () {
        if (typeof calculator.setMathBounds !== 'function') return;
        var b = {};
        if (p.xmin !== undefined) b.left = Number(p.xmin);
        if (p.xmax !== undefined) b.right = Number(p.xmax);
        if (p.ymin !== undefined) b.bottom = Number(p.ymin);
        if (p.ymax !== undefined) b.top = Number(p.ymax);
        try { calculator.setMathBounds(b); } catch (err) { console.warn('setMathBounds failed', err); }
      });
    },

    getState: function (p) {
      whenReady('getState', p, function () {
        var state = null;
        try { state = calculator.getState(); } catch (err) { /* ignore */ }
        send('state', { state: state, mode: mode });
      });
    },

    setState: function (p) {
      whenReady('setState', p, function () {
        var state = p.state;
        if (typeof state === 'string') { try { state = JSON.parse(state); } catch (err) { return; } }
        if (!state) return;
        try { calculator.setState(state); } catch (err) { console.warn('setState failed', err); }
        snapshot();
      });
    },

    resetView: function (p) {
      whenReady('resetView', p, function () {
        if (mode === '2d' && typeof calculator.setMathBounds === 'function') {
          // Desmos' default 2D view: the shorter axis spans ±10 with square pixels.
          var w = container.clientWidth || 1, h = container.clientHeight || 1, r = h / w;
          var hx = r <= 1 ? 10 : 10 / r, hy = r <= 1 ? 10 * r : 10;
          try { calculator.setMathBounds({ left: -hx, right: hx, bottom: -hy, top: hy }); } catch (err) { /* ignore */ }
          return;
        }
        // 3D: dropping the viewport (and camera) from the state makes Desmos fall back to its default view.
        try {
          var s = calculator.getState();
          if (s && s.graph) {
            delete s.graph.viewport;
            delete s.graph.rotation;
            delete s.graph.orientation;
          }
          calculator.setState(s);
        } catch (err) { console.warn('resetView failed', err); }
        snapshot();
      });
    },

    theme: function (p) {
      // bridge.js normally applies the CSS itself. If registering this handler replaced it, apply it here too
      // (idempotent: same element, same content).
      if (p && typeof p.css === 'string') {
        var styleEl = document.getElementById('theme');
        if (!styleEl) { styleEl = document.createElement('style'); styleEl.id = 'theme'; document.head.appendChild(styleEl); }
        if (styleEl.textContent !== p.css) styleEl.textContent = p.css;
        document.documentElement.dataset.theme = p.isDark ? 'dark' : 'light';
      }
      applyThemeToCalculator();
    }
  };

  /** Called after the theme CSS changed: re-themes Desmos' paper and chrome and re-tints default-coloured rows. */
  function applyThemeToCalculator() {
    if (!calculator) return;
    var oldColor = defaultColor;
    var newColor = accentColor();
    var wanted = themeSettings();
    try { calculator.updateSettings(wanted); } catch (err) { /* ignore */ }
    if (!themeSettingsApplied(wanted)) {
      // Desmos did not take the settings through updateSettings: rebuild the calculator with them set at
      // construction, exactly as a mode switch does (state — rows and viewport — is saved and restored).
      try { modes[mode].savedState = calculator.getState(); } catch (err) { modes[mode].savedState = null; }
      syncModeMap();
      createCalculator();
      if (!calculator) return;
      // `oldColor` still names the accent the restored rows carry, so the re-tint below applies to them too.
    }
    if (newColor !== oldColor) {
      defaultColor = newColor;
      try {
        var colors = { ACCENT: newColor };
        if (Desmos.Colors) Object.keys(Desmos.Colors).forEach(function (k) { colors[k] = Desmos.Colors[k]; });
        calculator.updateSettings({ colors: colors });
        calculator.getExpressions().forEach(function (e) {
          if (e.type === 'expression' && oldColor && e.color && e.color.toLowerCase() === oldColor.toLowerCase()) {
            calculator.setExpression({ id: e.id, color: newColor });
          }
        });
      } catch (err) { /* ignore */ }
      snapshot();
    }
  }

  // Also react to theme flips applied by bridge.js directly (data-theme attribute), in case our 'theme' handler
  // is not the one that runs.
  new MutationObserver(function () { applyThemeToCalculator(); })
    .observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

  Object.keys(handlers).forEach(function (type) { bridge.on(type, handlers[type]); });

  // Expose a small debug surface for the console.
  window.thubanGraph = {
    get calculator() { return calculator; },
    get mode() { return mode; },
    handle: handle
  };

  // ---- debug: no native host -----------------------------------------------------------------------------
  if (bridge.debug || !(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.thuban)) {
    // Opened in a browser: try an API key from the query string (?key=…) so the page can be exercised standalone.
    var key = new URLSearchParams(location.search).get('key');
    if (key) {
      handle('config', { desmosKey: key });
      handle('setExpressions', { expressions: [
        { id: 'f', latex: 'f(x)=\\frac{2x^2+1}{x^2-4}' },
        { id: 'a1', latex: 'x=-2', lineStyle: 'DASHED', color: '#a17f42' },
        { id: 'a2', latex: 'x=2', lineStyle: 'DASHED', color: '#a17f42' },
        { id: 'a3', latex: 'y=2', lineStyle: 'DOTTED', color: '#74d6c4' },
        { id: 'a', latex: 'a=2', sliderBounds: { min: -5, max: 5, step: 0.5 } }
      ] });
    } else {
      showStatus('Open with ?key=<Desmos API key> to test in a browser.');
    }
  }
})();
