/*
 * calc.js — scientific calculator hosted by CalculatorWebView.
 *
 * Primary: Desmos.ScientificCalculator, created once 'config' delivers the API key.
 * Fallback (Desmos missing, the key not enabled for the scientific calculator, or the script failing to load):
 * a MathLive <math-field> whose expression is evaluated by the native MathEngine.
 *
 * Message contract:
 *   Swift → JS : config {desmosKey, forceFallback?}, result {latex, id?, error?}, theme {css, isDark}
 *   JS → Swift : ready, evaluate {latex, id}, copyToAnswer {latex}, error {message}
 */
(function () {
  'use strict';

  var DESMOS_API = 'https://www.desmos.com/api/v1.11/calculator.js';
  var LOAD_TIMEOUT_MS = 20000;
  var HISTORY_LIMIT = 20;

  // Absolute base for bundled resources. Under the app this is the custom scheme; in a browser we fall back to a
  // path relative to this page so the vendor libraries still resolve.
  var BUNDLE = location.protocol === 'thuban:' ? 'thuban://bundle/' : new URL('../', location.href).href;

  var bridge = window.thuban;
  var hosted = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.thuban) && !bridge.debug;

  var calculatorEl = document.getElementById('calculator');
  var statusEl = document.getElementById('status');
  var fallbackEl = document.getElementById('fallback');
  var noteEl = document.getElementById('fb-note');
  var mfHost = document.getElementById('mf-host');
  var evalButton = document.getElementById('eval');
  var resultEl = document.getElementById('result');
  var historyEl = document.getElementById('history');
  var copyButton = document.getElementById('copy');
  var clearButton = document.getElementById('clear-history');

  var calculator = null;     // Desmos instance when available
  var mathfield = null;      // MathLive element in fallback mode
  var loading = false;
  var loadTimer = null;
  var scriptEl = null;

  var history = [];          // [{id, input, result, error, pending}] newest first
  var selectedId = null;
  var nextId = 1;

  function send(type, payload) {
    try { bridge.send(type, payload || {}); } catch (e) { console.error('send failed', type, e); }
  }

  function cssVar(name, fallback) {
    var v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    return v || fallback;
  }

  /**
   * Desmos settings that carry the theme: the calculator body takes --panel, its text --ink and its chrome
   * (Enter key, RAD/DEG segment, links, focus rings) the app accent instead of Desmos' stock blue. These are
   * first-class Desmos settings (validated as hex); `invertedColors` is a CSS invert filter over the whole
   * calculator and would invert these too, so it stays off.
   */
  function themeSettings() {
    return {
      invertedColors: false,
      backgroundColor: cssVar('--panel', '#fffdf7'),
      textColor: cssVar('--ink', '#161a21'),
      accentColor: cssVar('--accent', '#e0b15c')
    };
  }

  function showStatus(text) { statusEl.textContent = text; statusEl.hidden = false; }
  function hideStatus() { statusEl.hidden = true; }

  // ---- Desmos ---------------------------------------------------------------------------------------------

  function loadDesmos(key) {
    if (window.Desmos) {
      // Script already present (e.g. the key was re-sent): the calculator is built once, never stacked.
      if (!calculator) createDesmos();
      return;
    }
    if (loading) return;
    if (!key) { useFallback('No Desmos API key is configured.'); return; }
    loading = true;
    showStatus('Loading calculator…');
    scriptEl = document.createElement('script');
    scriptEl.src = DESMOS_API + '?apiKey=' + encodeURIComponent(key);
    scriptEl.async = true;
    scriptEl.onload = function () {
      clearTimeout(loadTimer);
      loading = false;
      createDesmos();
    };
    scriptEl.onerror = function () {
      clearTimeout(loadTimer);
      loading = false;
      useFallback('Desmos could not be reached.');
    };
    loadTimer = setTimeout(function () {
      if (!window.Desmos) { loading = false; useFallback('Desmos took too long to load.'); }
    }, LOAD_TIMEOUT_MS);
    document.head.appendChild(scriptEl);
  }

  function createDesmos() {
    if (!window.Desmos || typeof Desmos.ScientificCalculator !== 'function') {
      useFallback('The Desmos scientific calculator is not enabled for this API key.');
      return;
    }
    try {
      calculator = Desmos.ScientificCalculator(calculatorEl, themeSettings());
    } catch (err) {
      calculator = null;
      useFallback('The Desmos scientific calculator failed to start.');
      return;
    }
    fallbackEl.hidden = true;
    calculatorEl.hidden = false;
    hideStatus();
  }

  // ---- Fallback: MathLive input + native evaluation -------------------------------------------------------

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = function () { reject(new Error('Failed to load ' + src)); };
      document.head.appendChild(s);
    });
  }

  function loadStylesheet(href) {
    var l = document.createElement('link');
    l.rel = 'stylesheet';
    l.href = href;
    document.head.appendChild(l);
  }

  function useFallback(reason) {
    if (calculator) { try { calculator.destroy(); } catch (e) { /* ignore */ } calculator = null; }
    calculatorEl.hidden = true;
    fallbackEl.hidden = false;
    if (reason) {
      noteEl.textContent = reason + ' Using the built-in calculator.';
      noteEl.hidden = false;
      send('error', { message: reason });
    }
    showStatus('Loading calculator…');

    var ready = window.MathLive
      ? Promise.resolve()
      : loadScript(BUNDLE + 'vendor/mathlive/mathlive.min.js');
    loadStylesheet(BUNDLE + 'vendor/mathlive/mathlive-static.css');

    ready.then(function () {
      hideStatus();
      if (!mathfield) buildMathfield();
      mathfield.focus();
    }).catch(function (err) {
      showStatus('The calculator could not be loaded.');
      send('error', { message: err.message });
    });
  }

  function buildMathfield() {
    var ME = window.MathfieldElement || (window.MathLive && window.MathLive.MathfieldElement);
    ME.fontsDirectory = BUNDLE + 'vendor/mathlive/fonts';
    ME.soundsDirectory = null;

    mathfield = new ME();
    mathfield.id = 'mf';
    mathfield.setAttribute('aria-label', 'Expression');
    // Mount first: MathLive creates the underlying field in connectedCallback and some setters (menuItems)
    // throw "Mathfield not mounted" before that.
    mfHost.appendChild(mathfield);
    mathfield.mathVirtualKeyboardPolicy = 'manual';
    mathfield.smartFence = true;
    mathfield.smartSuperscript = true;
    try { mathfield.menuItems = []; } catch (_) { /* older API: no context-menu control */ }
    mathfield.placeholder = 'e.g. \\sqrt{2}\\cdot\\sin\\left(\\frac{\\pi}{6}\\right)';

    // MathLive dispatches 'change' when Return/Enter is pressed inside the field.
    mathfield.addEventListener('change', function () { evaluateCurrent(); });
    evalButton.addEventListener('click', function () { evaluateCurrent(); mathfield.focus(); });
  }

  function evaluateCurrent() {
    var latex = (mathfield.value || '').trim();
    if (!latex) return;
    var entry = { id: 'c' + (nextId++), input: latex, result: null, error: null, pending: true };
    history.unshift(entry);
    if (history.length > HISTORY_LIMIT) history.length = HISTORY_LIMIT;
    selectedId = entry.id;
    renderResult(entry);
    renderHistory();
    if (hosted) {
      send('evaluate', { latex: latex, id: entry.id });
    } else {
      evaluateLocally(entry);
    }
  }

  /** Swift replies with {latex, id?, error?}; without an id, the newest pending entry is the target. */
  function receiveResult(p) {
    var entry = null;
    if (p.id) entry = history.find(function (e) { return e.id === p.id; });
    if (!entry) entry = history.find(function (e) { return e.pending; });
    if (!entry) return;
    entry.pending = false;
    if (p.error) entry.error = String(p.error);
    else entry.result = typeof p.latex === 'string' ? p.latex : String(p.latex || '');
    if (selectedId === entry.id) renderResult(entry);
    renderHistory();
  }

  /** Static markup for a LaTeX string, falling back to plain text. */
  function mathNode(latex, className) {
    var span = document.createElement('span');
    if (className) span.className = className;
    try {
      span.innerHTML = window.MathLive.convertLatexToMarkup(latex);
    } catch (err) {
      span.textContent = latex;
    }
    return span;
  }

  function renderResult(entry) {
    resultEl.innerHTML = '';
    if (!entry) {
      var ph = document.createElement('span');
      ph.className = 'placeholder';
      ph.textContent = 'Type an expression and press Return';
      resultEl.appendChild(ph);
      copyButton.disabled = true;
      return;
    }
    if (entry.pending) {
      var pend = document.createElement('span');
      pend.className = 'pending';
      pend.textContent = 'Evaluating…';
      resultEl.appendChild(pend);
      copyButton.disabled = true;
      return;
    }
    if (entry.error) {
      var err = document.createElement('span');
      err.className = 'error';
      err.textContent = entry.error;
      resultEl.appendChild(err);
      copyButton.disabled = true;
      return;
    }
    var eq = document.createElement('span');
    eq.className = 'eq';
    eq.textContent = '=';
    resultEl.appendChild(eq);
    resultEl.appendChild(mathNode(entry.result, 'value'));
    copyButton.disabled = false;
  }

  function renderHistory() {
    historyEl.innerHTML = '';
    if (!history.length) {
      var empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = 'Results appear here — select one to copy it into an answer.';
      historyEl.appendChild(empty);
      return;
    }
    history.forEach(function (entry) {
      var row = document.createElement('button');
      row.type = 'button';
      row.className = 'fb-entry';
      row.setAttribute('role', 'option');
      row.setAttribute('aria-selected', entry.id === selectedId ? 'true' : 'false');
      row.dataset.id = entry.id;
      row.appendChild(mathNode(entry.input, 'in'));
      var eq = document.createElement('span');
      eq.className = 'eq';
      eq.textContent = '=';
      row.appendChild(eq);
      if (entry.pending) {
        var p = document.createElement('span'); p.className = 'out'; p.textContent = '…'; row.appendChild(p);
      } else if (entry.error) {
        var e = document.createElement('span'); e.className = 'out error'; e.textContent = entry.error; row.appendChild(e);
      } else {
        row.appendChild(mathNode(entry.result, 'out'));
      }
      row.addEventListener('click', function () {
        selectedId = entry.id;
        renderResult(entry);
        renderHistory();
      });
      row.addEventListener('dblclick', function () {
        // Double-click loads the expression back into the field for editing.
        if (mathfield) { mathfield.value = entry.input; mathfield.focus(); }
      });
      historyEl.appendChild(row);
    });
  }

  copyButton.addEventListener('click', function () {
    var entry = history.find(function (e) { return e.id === selectedId; }) || history.find(function (e) { return e.result; });
    if (!entry || !entry.result) return;
    send('copyToAnswer', { latex: entry.result });
  });

  clearButton.addEventListener('click', function () {
    history = [];
    selectedId = null;
    renderResult(null);
    renderHistory();
    if (mathfield) mathfield.focus();
  });

  // Browser-only evaluation through the vendored Compute Engine, so the fallback is testable without the host.
  var enginePromise = null;
  function evaluateLocally(entry) {
    if (!enginePromise) {
      enginePromise = import(BUNDLE + 'vendor/compute-engine/compute-engine.esm.js')
        .then(function (mod) { return new mod.ComputeEngine(); });
    }
    enginePromise.then(function (ce) {
      var expr = ce.parse(entry.input);
      var value = expr.evaluate();
      var latex = value.latex;
      if (latex === entry.input || /[a-zA-Z\\]/.test(latex) && typeof value.N === 'function') {
        var numeric = value.N();
        if (numeric && numeric.latex) latex = numeric.latex;
      }
      receiveResult({ id: entry.id, latex: latex });
    }).catch(function (err) {
      receiveResult({ id: entry.id, error: err && err.message ? err.message : 'Could not evaluate' });
    });
  }

  // ---- bridge handlers ------------------------------------------------------------------------------------

  bridge.on('config', function (p) {
    p = p || {};
    if (p.forceFallback) { useFallback(''); return; }
    loadDesmos(p.desmosKey || p.apiKey || '');
  });

  bridge.on('result', function (p) { receiveResult(p || {}); });

  bridge.on('theme', function (p) {
    // bridge.js normally applies the CSS itself; apply here too in case this handler replaced it (idempotent).
    if (p && typeof p.css === 'string') {
      var styleEl = document.getElementById('theme');
      if (!styleEl) { styleEl = document.createElement('style'); styleEl.id = 'theme'; document.head.appendChild(styleEl); }
      if (styleEl.textContent !== p.css) styleEl.textContent = p.css;
      document.documentElement.dataset.theme = p.isDark ? 'dark' : 'light';
    }
    applyTheme();
  });

  function applyTheme() {
    if (calculator) { try { calculator.updateSettings(themeSettings()); } catch (e) { /* ignore */ } }
  }
  new MutationObserver(applyTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

  // ---- browser debugging ----------------------------------------------------------------------------------
  if (!hosted) {
    var key = new URLSearchParams(location.search).get('key');
    if (key) loadDesmos(key);
    else useFallback('');
  }
})();
