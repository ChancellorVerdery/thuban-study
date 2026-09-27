/*
 * chat.js — tutor transcript renderer hosted by ChatWebView.
 *
 * Message contract (see ARCHITECTURE.md › Web bridge protocols):
 *   Swift → JS : setTranscript {messages:[{id, role, html?, markdown, toolEvents, streaming}]},
 *                appendMessage {message}, appendDelta {id, text}, finish {id}, clear {}, theme {css, isDark}
 *   JS → Swift : ready, linkClicked {href, url}
 *
 * Rendering: Markdown (marked, gfm + breaks) → DOMPurify → MathLive static math. Math segments are lifted out of
 * the Markdown before parsing so `_`, `*`, `\(` and friends inside formulas survive, then put back as text nodes
 * and rendered with renderMathInElement ($…$, $$…$$, \(…\), \[…\]; code is skipped).
 *
 * Roles: "student" (right, accent tint) · "tutor" (left, panel-2) · "system" / "tool" (centered 12px line with icon).
 * Streaming messages re-render at most ~30 times a second and show a blinking caret until 'finish'.
 */
(function () {
  'use strict';

  var FRAME_MS = 1000 / 30;          // streaming re-render throttle
  var STICKY_PX = 40;                // auto-scroll only when this close to the bottom

  var BUNDLE = location.protocol === 'thuban:' ? 'thuban://bundle/' : new URL('../', location.href).href;
  var bridge = window.thuban;
  var hosted = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.thuban) && !bridge.debug;

  var transcript = document.getElementById('transcript');
  var messagesEl = document.getElementById('messages');
  var emptyEl = document.getElementById('empty');

  var order = [];               // message ids in display order
  var messages = new Map();     // id → record {id, role, markdown, html, toolEvents, streaming, el, bodyEl, eventsEl}

  // ---- libraries ------------------------------------------------------------------------------------------

  var libsReady = null;

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = function () { reject(new Error('Failed to load ' + src)); };
      document.head.appendChild(s);
    });
  }

  /** Resolves once marked, DOMPurify and MathLive are present (loads them from the bundle if the static tags failed). */
  function ensureLibs() {
    if (libsReady) return libsReady;
    var tasks = [];
    if (!window.marked) tasks.push(loadScript(BUNDLE + 'vendor/marked/marked.min.js'));
    if (!window.DOMPurify) tasks.push(loadScript(BUNDLE + 'vendor/dompurify/purify.min.js'));
    if (!window.MathLive) tasks.push(loadScript(BUNDLE + 'vendor/mathlive/mathlive.min.js'));
    if (tasks.length && location.protocol !== 'thuban:') {
      var l = document.createElement('link');
      l.rel = 'stylesheet';
      l.href = BUNDLE + 'vendor/mathlive/mathlive-static.css';
      document.head.appendChild(l);
    }
    libsReady = Promise.all(tasks).then(function () {
      if (window.marked && typeof marked.use === 'function') {
        marked.use({ breaks: true, gfm: true });
      }
      if (window.MathfieldElement) {
        window.MathfieldElement.fontsDirectory = BUNDLE + 'vendor/mathlive/fonts';
        window.MathfieldElement.soundsDirectory = null;
      }
    });
    return libsReady;
  }

  // ---- math protection -----------------------------------------------------------------------------------

  var PH_OPEN = '\uE000', PH_CLOSE = '\uE001';
  var PH_RE = /\uE000(\d+)\uE001/g;

  /**
   * Replace math segments with private-use placeholders so Markdown does not mangle them.
   * Returns {text, chunks} where chunks[i] is the original source (delimiters included).
   */
  function protectMath(src) {
    var chunks = [];
    var out = '';
    var i = 0, n = src.length;
    var inFence = false, fenceMark = '';

    function push(seg) { chunks.push(seg); out += PH_OPEN + (chunks.length - 1) + PH_CLOSE; }

    while (i < n) {
      var ch = src[i];
      var atLineStart = i === 0 || src[i - 1] === '\n';

      // Fenced code blocks: copy through untouched.
      if (atLineStart) {
        var m = /^( {0,3})(`{3,}|~{3,})/.exec(src.slice(i, i + 80));
        if (m) {
          var mark = m[2];
          if (!inFence) { inFence = true; fenceMark = mark[0]; }
          else if (mark[0] === fenceMark) { inFence = false; }
          var eol = src.indexOf('\n', i);
          if (eol === -1) eol = n;
          out += src.slice(i, eol + 1);
          i = eol + 1;
          continue;
        }
      }
      if (inFence) {
        var e2 = src.indexOf('\n', i);
        if (e2 === -1) e2 = n;
        out += src.slice(i, e2 + 1);
        i = e2 + 1;
        continue;
      }

      // Inline code: a run of backticks closed by an equal run.
      if (ch === '`') {
        var runEnd = i;
        while (runEnd < n && src[runEnd] === '`') runEnd++;
        var run = src.slice(i, runEnd);
        var close = src.indexOf(run, runEnd);
        while (close !== -1 && src[close + run.length] === '`') {
          // longer run than ours: skip it
          var k = close;
          while (k < n && src[k] === '`') k++;
          close = src.indexOf(run, k);
        }
        if (close !== -1) { out += src.slice(i, close + run.length); i = close + run.length; }
        else { out += run; i = runEnd; }
        continue;
      }

      // Escaped dollar stays literal for Markdown to unescape.
      if (ch === '\\' && src[i + 1] === '$') { out += '\\$'; i += 2; continue; }

      // \[ … \]  and  \( … \)
      if (ch === '\\' && (src[i + 1] === '[' || src[i + 1] === '(')) {
        var closer = src[i + 1] === '[' ? '\\]' : '\\)';
        var endIdx = src.indexOf(closer, i + 2);
        if (endIdx !== -1) { push(src.slice(i, endIdx + 2)); i = endIdx + 2; continue; }
      }

      // $$ … $$
      if (ch === '$' && src[i + 1] === '$') {
        var end2 = src.indexOf('$$', i + 2);
        if (end2 !== -1) { push(src.slice(i, end2 + 2)); i = end2 + 2; continue; }
        out += '$$'; i += 2; continue;
      }

      // $ … $ — opening $ must be followed by non-space; closing $ preceded by non-space and not followed by a digit.
      if (ch === '$') {
        var next = src[i + 1];
        if (next && !/\s/.test(next)) {
          var j = i + 1, found = -1;
          while (j < n) {
            var c = src[j];
            if (c === '\\') { j += 2; continue; }
            if (c === '\n' && src[j + 1] === '\n') break;         // no paragraph breaks inside inline math
            if (c === '$') {
              if (!/\s/.test(src[j - 1]) && !/\d/.test(src[j + 1] || '')) { found = j; }
              break;
            }
            j++;
          }
          if (found !== -1) { push(src.slice(i, found + 1)); i = found + 1; continue; }
        }
        out += '$'; i++; continue;
      }

      out += ch;
      i++;
    }
    return { text: out, chunks: chunks };
  }

  /** Put protected math back as text nodes (never as HTML). */
  function restoreMath(root, chunks) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var nodes = [];
    var node;
    while ((node = walker.nextNode())) { if (node.data.indexOf(PH_OPEN) !== -1) nodes.push(node); }
    nodes.forEach(function (textNode) {
      var frag = document.createDocumentFragment();
      var data = textNode.data, last = 0, match;
      PH_RE.lastIndex = 0;
      while ((match = PH_RE.exec(data))) {
        if (match.index > last) frag.appendChild(document.createTextNode(data.slice(last, match.index)));
        var chunk = chunks[Number(match[1])];
        frag.appendChild(document.createTextNode(chunk !== undefined ? chunk : match[0]));
        last = match.index + match[0].length;
      }
      if (last < data.length) frag.appendChild(document.createTextNode(data.slice(last)));
      // Merge adjacent text nodes so MathLive sees one contiguous string.
      textNode.parentNode.replaceChild(frag, textNode);
    });
    root.normalize();
  }

  var MATH_OPTIONS = {
    TeX: {
      delimiters: {
        inline: [['$', '$'], ['\\(', '\\)']],
        display: [['$$', '$$'], ['\\[', '\\]']]
      },
      processEnvironments: true
    },
    asciiMath: null,
    skipTags: ['noscript', 'style', 'textarea', 'pre', 'code', 'annotation', 'annotation-xml', 'math-field', 'svg'],
    ignoreClass: '^(tex2jax_ignore|ML__latex|no-math)$',
    renderAccessibleContent: ''
  };

  // MathLive has \\ldots and \\cdots but not amsmath's \\dots family; rewrite them in the text before rendering.
  function fixDots(el) {
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.nodeValue.indexOf('\\dots') < 0) continue;
      node.nodeValue = node.nodeValue
        .replace(/\\dots[bm](?![a-zA-Z])/g, '\\cdots')
        .replace(/\\dots[cio]?(?![a-zA-Z])/g, '\\ldots');
    }
  }

  function renderMath(el) {
    if (!window.MathLive || typeof MathLive.renderMathInElement !== 'function') return;
    fixDots(el);
    try { MathLive.renderMathInElement(el, MATH_OPTIONS); }
    catch (err) { console.warn('renderMathInElement failed', err); return; }
    // MathLive marks display math only with an inline `display:flex`; give it a class so chat.css can style it.
    el.querySelectorAll('span[data-latex]').forEach(function (span) {
      if (span.style.display === 'flex') span.classList.add('math-display');
    });
  }

  var SANITIZE_OPTIONS = {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ['style', 'form', 'input', 'button', 'iframe', 'object', 'embed'],
    FORBID_ATTR: ['style', 'target']
  };

  /** Markdown (or pre-rendered html) → sanitized DOM with math rendered, written into `target`. */
  function renderInto(target, record) {
    var html, chunks = [];
    if (typeof record.html === 'string' && record.html.length) {
      html = record.html;
    } else {
      var protectedMd = protectMath(record.markdown || '');
      chunks = protectedMd.chunks;
      try { html = marked.parse(protectedMd.text); }
      catch (err) { html = '<p>' + escapeHtml(protectedMd.text) + '</p>'; }
    }
    var clean = window.DOMPurify ? DOMPurify.sanitize(html, SANITIZE_OPTIONS) : escapeHtml(html);
    target.innerHTML = clean;
    if (chunks.length) restoreMath(target, chunks);
    renderMath(target);
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  // ---- icons for system / tool lines ----------------------------------------------------------------------

  var ICONS = {
    graph: '<path d="M4 4v16h16"/><path d="M7 15c2.5-6 5-6 7.5 0S18 9 20 6"/>',
    calculator: '<rect x="6" y="3" width="12" height="18" rx="2"/><path d="M9 7h6M9 12h.01M12 12h.01M15 12h.01M9 16h.01M12 16h.01M15 16h.01"/>',
    hint: '<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.6 10.8c.6.5 1 1.2 1.1 2.2h5c.1-1 .5-1.7 1.1-2.2A6 6 0 0 0 12 3z"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
    question: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h4"/>',
    check: '<circle cx="12" cy="12" r="9"/><path d="m8.5 12.5 2.5 2.5 4.5-5"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
    warn: '<path d="M12 3 2.5 20h19L12 3z"/><path d="M12 10v4M12 17h.01"/>'
  };

  function iconFor(kind) {
    var k = String(kind || '').toLowerCase();
    var name = 'info';
    if (/warn|error|fail/.test(k)) name = 'warn';
    else if (/graph|plot|surface/.test(k)) name = 'graph';
    else if (/calc/.test(k)) name = 'calculator';
    else if (/hint/.test(k)) name = 'hint';
    else if (/solution|lock/.test(k)) name = 'lock';
    else if (/question|source|document|doc/.test(k)) name = 'question';
    else if (/check|grade|correct|done/.test(k)) name = 'check';
    if (ICONS[k]) name = k;
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.75');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');
    svg.innerHTML = ICONS[name];
    return svg;
  }

  function eventLine(ev) {
    var line = document.createElement('div');
    line.className = ev.isError ? 'event error' : 'event';
    var kind = ev.icon || ev.kind || ev.type || ev.name || ev.tool || '';
    line.appendChild(iconFor(ev.isError ? 'warn' : kind));
    var span = document.createElement('span');
    span.className = 'summary';
    span.textContent = ev.summary || ev.text || ev.markdown || ev.name || '';
    line.appendChild(span);
    return line;
  }

  // ---- messages --------------------------------------------------------------------------------------------

  function normalizeRole(role) {
    var r = String(role || '').toLowerCase();
    if (r === 'user' || r === 'student') return 'student';
    if (r === 'assistant' || r === 'tutor') return 'tutor';
    return 'event';
  }

  function isNearBottom() {
    return transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight <= STICKY_PX;
  }

  function scrollToBottom() {
    transcript.scrollTop = transcript.scrollHeight;
  }

  function updateEmptyState() {
    emptyEl.hidden = order.length > 0;
  }

  /** Build the DOM shell for a message record and return it (body rendered separately). */
  function buildMessage(record) {
    if (record.role === 'event') {
      var ev = eventLine({
        kind: record.kind || record.icon || (Array.isArray(record.toolEvents) && record.toolEvents[0] && (record.toolEvents[0].kind || record.toolEvents[0].type)),
        summary: record.markdown || record.summary || record.text ||
                 (Array.isArray(record.toolEvents) && record.toolEvents[0] && record.toolEvents[0].summary) || ''
      });
      ev.dataset.id = record.id;
      record.el = ev;
      record.bodyEl = null;
      return ev;
    }

    var wrap = document.createElement('div');
    wrap.className = 'msg msg-' + record.role;
    wrap.dataset.id = record.id;

    var events = document.createElement('div');
    events.className = 'events';
    wrap.appendChild(events);
    record.eventsEl = events;

    var bubble = document.createElement('div');
    bubble.className = 'bubble';
    wrap.appendChild(bubble);

    record.el = wrap;
    record.bodyEl = bubble;
    renderEvents(record);
    return wrap;
  }

  function renderEvents(record) {
    if (!record.eventsEl) return;
    record.eventsEl.innerHTML = '';
    var list = Array.isArray(record.toolEvents) ? record.toolEvents : [];
    list.forEach(function (ev) { record.eventsEl.appendChild(eventLine(ev || {})); });
    record.eventsEl.hidden = list.length === 0;
  }

  function renderBody(record) {
    if (!record.bodyEl) return;
    var hasText = (record.markdown && record.markdown.length) || (record.html && record.html.length);
    if (!hasText && !record.streaming) {
      // A tutor turn that only produced tool events: no bubble.
      record.bodyEl.hidden = true;
      return;
    }
    record.bodyEl.hidden = false;
    record.bodyEl.classList.toggle('streaming', !!record.streaming);
    renderInto(record.bodyEl, record);
    if (record.streaming) appendCaret(record.bodyEl);
  }

  /** Put the blinking caret at the end of the last text-bearing block so it follows the words. */
  function appendCaret(body) {
    var target = body;
    var DESCEND = { P: 1, LI: 1, UL: 1, OL: 1, BLOCKQUOTE: 1, H1: 1, H2: 1, H3: 1, H4: 1, DIV: 1 };
    while (target.lastElementChild && DESCEND[target.lastElementChild.tagName]) target = target.lastElementChild;
    var caret = document.createElement('span');
    caret.className = 'caret';
    caret.setAttribute('aria-hidden', 'true');
    target.appendChild(caret);
  }

  function makeRecord(m) {
    return {
      id: String(m.id),
      role: normalizeRole(m.role),
      kind: m.kind || m.icon,
      markdown: typeof m.markdown === 'string' ? m.markdown : (typeof m.text === 'string' ? m.text : ''),
      html: typeof m.html === 'string' ? m.html : null,
      summary: m.summary,
      toolEvents: Array.isArray(m.toolEvents) ? m.toolEvents : [],
      streaming: !!m.streaming,
      el: null, bodyEl: null, eventsEl: null
    };
  }

  function insertMessage(m) {
    if (!m || m.id === undefined || m.id === null) return null;
    var id = String(m.id);
    var existing = messages.get(id);
    if (existing) {
      // Replace in place.
      var fresh = makeRecord(m);
      var el = buildMessage(fresh);
      existing.el.replaceWith(el);
      messages.set(id, fresh);
      renderBody(fresh);
      return fresh;
    }
    var record = makeRecord(m);
    var node = buildMessage(record);
    messagesEl.appendChild(node);
    order.push(id);
    messages.set(id, record);
    renderBody(record);
    return record;
  }

  function clearAll() {
    order = [];
    messages.clear();
    messagesEl.innerHTML = '';
    pendingRender.clear();
    updateEmptyState();
  }

  // ---- throttled streaming renders ----------------------------------------------------------------------

  var pendingRender = new Set();
  var renderScheduled = false;
  var lastFrame = 0;

  function scheduleRender(id) {
    pendingRender.add(id);
    if (renderScheduled) return;
    renderScheduled = true;
    var wait = Math.max(0, FRAME_MS - (performance.now() - lastFrame));
    setTimeout(function () {
      requestAnimationFrame(flushRenders);
    }, wait);
  }

  function flushRenders() {
    renderScheduled = false;
    lastFrame = performance.now();
    var ids = Array.from(pendingRender);
    pendingRender.clear();
    var stick = isNearBottom();
    ids.forEach(function (id) {
      var record = messages.get(id);
      if (record) renderBody(record);
    });
    if (stick) scrollToBottom();
  }

  // ---- bridge handlers ------------------------------------------------------------------------------------

  // Every handler waits for the libraries so early messages are not lost in a browser-debug session.
  function guarded(fn) {
    return function (payload) {
      if (typeof payload === 'string') { try { payload = JSON.parse(payload); } catch (e) { /* keep */ } }
      ensureLibs().then(function () { fn(payload || {}); })
        .catch(function (err) { console.error('chat: libraries unavailable', err); });
    };
  }

  bridge.on('setTranscript', guarded(function (p) {
    clearAll();
    var list = Array.isArray(p.messages) ? p.messages : [];
    list.forEach(insertMessage);
    updateEmptyState();
    scrollToBottom();
  }));

  bridge.on('appendMessage', guarded(function (p) {
    var stick = isNearBottom();
    insertMessage(p.message || p);
    updateEmptyState();
    if (stick) scrollToBottom();
  }));

  bridge.on('appendDelta', guarded(function (p) {
    if (p.id === undefined) return;
    var id = String(p.id);
    var record = messages.get(id);
    if (!record) {
      // Delta for an unknown message: start a streaming tutor message so nothing is dropped.
      var stick = isNearBottom();
      record = insertMessage({ id: id, role: p.role || 'tutor', markdown: '', streaming: true });
      updateEmptyState();
      if (stick) scrollToBottom();
    }
    record.streaming = true;
    record.html = null;
    record.markdown += (typeof p.text === 'string' ? p.text : String(p.text || ''));
    scheduleRender(id);
  }));

  bridge.on('finish', guarded(function (p) {
    if (p.id === undefined) return;
    var record = messages.get(String(p.id));
    if (!record) return;
    record.streaming = false;
    if (typeof p.markdown === 'string') record.markdown = p.markdown;   // optional final text
    pendingRender.delete(record.id);
    var stick = isNearBottom();
    renderBody(record);
    if (stick) scrollToBottom();
  }));

  bridge.on('clear', guarded(function () {
    clearAll();
  }));

  bridge.on('theme', function (p) {
    // bridge.js normally applies the CSS itself; apply here too in case this handler replaced it (idempotent).
    if (p && typeof p.css === 'string') {
      var styleEl = document.getElementById('theme');
      if (!styleEl) { styleEl = document.createElement('style'); styleEl.id = 'theme'; document.head.appendChild(styleEl); }
      if (styleEl.textContent !== p.css) styleEl.textContent = p.css;
      document.documentElement.dataset.theme = p.isDark ? 'dark' : 'light';
    }
  });

  // Links open natively.
  transcript.addEventListener('click', function (e) {
    var a = e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    e.preventDefault();
    bridge.send('linkClicked', { href: a.getAttribute('href'), url: a.href });
  });

  // Start loading libraries right away.
  ensureLibs().then(updateEmptyState);

  // Small debug surface.
  window.thubanChat = { messages: messages, order: order, render: renderInto, protectMath: protectMath };

  // ---- demo content when opened without the native host -------------------------------------------------
  if (!hosted) {
    var demo = [
      { id: 'd1', role: 'student', markdown: 'I got parts a and b but I don\'t know how to start the tangent plane.' },
      { id: 'd2', role: 'tutor', markdown: 'Good — you already have the two numbers the tangent plane needs. What does $f_x(1, 2)$ tell you about how $z$ changes if you nudge $x$ a little while holding $y$ fixed?' },
      { id: 'd3', role: 'student', markdown: 'The slope in the x direction?' },
      { id: 'd4', role: 'tutor',
        toolEvents: [{ kind: 'graph', summary: 'Tutor opened the graph to show the surface and the plane at P' }],
        markdown: 'Exactly. So the plane must have that slope in $x$ and $f_y$\'s slope in $y$, and it must pass through $P$.\n\nThe general form is\n\n$$z - z_0 = f_x(x_0, y_0)\\,(x - x_0) + f_y(x_0, y_0)\\,(y - y_0)$$\n\nTry writing $z - z_0$ in terms of $(x - 1)$ and $(y - 2)$. What is $z_0$ here?' },
      { id: 'd5', role: 'system', kind: 'check', markdown: 'Parts (a) and (b) checked — both correct' },
      { id: 'd6', role: 'student', markdown: 'Is it f(1,2)? So `2 + 24 - 4`?' }
    ];
    window.thuban.receive('setTranscript', { messages: demo });

    // Simulate a streamed reply to exercise the caret and the throttle.
    var reply = 'Yes — $z_0 = f(1, 2) = 22$. Now put the three numbers into the formula above and simplify. ' +
      'A quick check: if you set $x = 1$ and $y = 2$, the right-hand side should vanish, so the plane really passes through $P$. ' +
      'You can see it on the graph: the plane just touches the surface at $P$ and tilts more steeply in the $y$ direction because $f_y > f_x$.';
    var pos = 0;
    setTimeout(function step() {
      if (pos === 0) window.thuban.receive('appendDelta', { id: 'd7', text: '' });
      var n = 3 + Math.floor(Math.random() * 6);
      window.thuban.receive('appendDelta', { id: 'd7', text: reply.slice(pos, pos + n) });
      pos += n;
      if (pos < reply.length) setTimeout(step, 40);
      else window.thuban.receive('finish', { id: 'd7' });
    }, 900);
  }
})();
