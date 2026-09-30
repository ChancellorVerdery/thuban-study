/*
 * Thuban Study — Markdown with LaTeX, rendered (the pipeline of the tutor transcript, chat.js, for other pages).
 *
 *   ThubanRich.render(target, markdown)   sanitized Markdown with $…$, $$…$$, \(…\) and \[…\] math rendered by
 *                                         MathLive; math is protected from Markdown first so `_` and `*` inside a
 *                                         formula stay LaTeX.
 * Needs marked, DOMPurify and MathLive (and mathlive-static.css) on the page.
 */
(function () {
  'use strict';

  var PH_OPEN = '', PH_CLOSE = '';
  var PH_RE = /(\d+)/g;
  var configured = false;

  function configure() {
    if (configured) return;
    configured = true;
    if (window.marked && typeof marked.use === 'function') marked.use({ breaks: true, gfm: true });
  }

  /** Math segments → private-use placeholders so Markdown does not mangle them. */
  function protectMath(src) {
    var chunks = [];
    var out = '';
    var i = 0, n = src.length;
    var inFence = false, fenceMark = '';
    function push(seg) { chunks.push(seg); out += PH_OPEN + (chunks.length - 1) + PH_CLOSE; }
    while (i < n) {
      var ch = src[i];
      var atLineStart = i === 0 || src[i - 1] === '\n';
      if (atLineStart) {
        var m = /^( {0,3})(`{3,}|~{3,})/.exec(src.slice(i, i + 80));
        if (m) {
          if (!inFence) { inFence = true; fenceMark = m[2][0]; }
          else if (m[2][0] === fenceMark) { inFence = false; }
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
      if (ch === '`') {
        var runEnd = i;
        while (runEnd < n && src[runEnd] === '`') runEnd++;
        var run = src.slice(i, runEnd);
        var close = src.indexOf(run, runEnd);
        if (close !== -1) { out += src.slice(i, close + run.length); i = close + run.length; }
        else { out += run; i = runEnd; }
        continue;
      }
      if (ch === '\\' && src[i + 1] === '$') { out += '\\$'; i += 2; continue; }
      if (ch === '\\' && (src[i + 1] === '[' || src[i + 1] === '(')) {
        var closer = src[i + 1] === '[' ? '\\]' : '\\)';
        var endIdx = src.indexOf(closer, i + 2);
        if (endIdx !== -1) { push(src.slice(i, endIdx + 2)); i = endIdx + 2; continue; }
      }
      if (ch === '$' && src[i + 1] === '$') {
        var end2 = src.indexOf('$$', i + 2);
        if (end2 !== -1) { push(src.slice(i, end2 + 2)); i = end2 + 2; continue; }
        out += '$$'; i += 2; continue;
      }
      if (ch === '$') {
        var next = src[i + 1];
        if (next && !/\s/.test(next)) {
          var j = i + 1, found = -1;
          while (j < n) {
            var c = src[j];
            if (c === '\\') { j += 2; continue; }
            if (c === '\n' && src[j + 1] === '\n') break;
            if (c === '$') {
              if (!/\s/.test(src[j - 1]) && !/\d/.test(src[j + 1] || '')) found = j;
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

  function restoreMath(root, chunks) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var nodes = [], node;
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
      textNode.parentNode.replaceChild(frag, textNode);
    });
    root.normalize();
  }

  var MATH_OPTIONS = {
    TeX: {
      delimiters: { inline: [['$', '$'], ['\\(', '\\)']], display: [['$$', '$$'], ['\\[', '\\]']] },
      processEnvironments: true
    },
    asciiMath: null,
    skipTags: ['noscript', 'style', 'textarea', 'pre', 'code', 'annotation', 'annotation-xml', 'math-field', 'svg'],
    ignoreClass: '^(tex2jax_ignore|ML__latex|no-math)$',
    renderAccessibleContent: ''
  };

  // MathLive has \ldots and \cdots but not amsmath's \dots family.
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
    el.querySelectorAll('span[data-latex]').forEach(function (span) {
      if (span.style.display === 'flex') span.classList.add('math-display');
    });
  }

  var SANITIZE_OPTIONS = {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ['style', 'form', 'input', 'button', 'iframe', 'object', 'embed'],
    FORBID_ATTR: ['style', 'target']
  };

  function escapeHtml(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  function render(target, markdown) {
    configure();
    var protectedMd = protectMath(String(markdown || ''));
    var html;
    try { html = window.marked ? marked.parse(protectedMd.text) : '<p>' + escapeHtml(protectedMd.text) + '</p>'; }
    catch (err) { html = '<p>' + escapeHtml(protectedMd.text) + '</p>'; }
    target.innerHTML = window.DOMPurify ? DOMPurify.sanitize(html, SANITIZE_OPTIONS) : escapeHtml(html);
    if (protectedMd.chunks.length) restoreMath(target, protectedMd.chunks);
    renderMath(target);
  }

  window.ThubanRich = { render: render, protectMath: protectMath };
})();
