/*
 * Thuban Study — tutor composer (composer.html, hosted by ComposerWebView): text with inline, rendered math.
 *
 *   Swift → JS   clear {}                     empty the editor
 *                setText {text}               restore a draft ("… $x^2$ …" becomes text with math fields)
 *                focus {}                     put the caret in the editor
 *                insertMath {latex?}          insert a math field at the caret (the native √x button)
 *                configure {placeholder?, label?, multiline?}
 *                                             multiline: Enter starts a new line and ⌘Enter submits (flashcard
 *                                             fields); otherwise Enter submits and Shift+Enter starts a new line
 *                theme {css, isDark}          handled by shared/bridge.js
 *   JS → Swift   ready, input {text}, submit {text}, height {px}
 *
 * The message is plain text with each formula as $…$ LaTeX, as the tutor and the transcript expect.
 * Typing "$" starts a formula; inside one, "$", Escape or → at its end leave it; ← at its start leaves to the left;
 * Backspace in an empty formula removes it. Enter sends, Shift+Enter starts a new line.
 */
(function () {
  'use strict';

  const thuban = window.thuban;
  const ON_BUNDLE = location.protocol === 'thuban:';
  const FONTS_DIRECTORY = ON_BUNDLE ? 'thuban://bundle/vendor/mathlive/fonts' : '../vendor/mathlive/fonts';
  const editor = document.getElementById('editor');
  let MathfieldElement = null;
  let inputTimer = 0;
  let multiline = false;

  /* ================================================================ serialising */

  function serialize(node) {
    let out = '';
    node.childNodes.forEach((child, index) => {
      if (child.nodeType === Node.TEXT_NODE) {
        out += child.data.replace(/​/g, '');
      } else if (child.nodeName === 'BR') {
        out += '\n';
      } else if (child.classList && child.classList.contains('math-chip')) {
        const mf = child.querySelector('math-field');
        const latex = mf ? mf.getValue('latex').trim() : '';
        const fence = child.dataset.display === 'true' ? '$$' : '$';
        if (latex) out += fence + latex + fence;
      } else if (child.nodeName === 'DIV' || child.nodeName === 'P') {
        if (index > 0 || out.length) out += '\n';
        out += serialize(child);
      } else {
        out += serialize(child);
      }
    });
    return out;
  }

  function currentText() { return serialize(editor).replace(/\n{3,}/g, '\n\n'); }

  function notifyInput() {
    clearTimeout(inputTimer);
    inputTimer = setTimeout(() => thuban.send('input', { text: currentText() }), 60);
    scheduleHeight();
  }

  /* ================================================================ math fields */

  function makeChip(latex, display) {
    const chip = document.createElement('span');
    chip.className = 'math-chip' + (display ? ' is-display' : '');
    if (display) chip.dataset.display = 'true';
    chip.contentEditable = 'false';
    const mf = new MathfieldElement();
    mf.mathVirtualKeyboardPolicy = 'manual';
    mf.smartFence = true;
    mf.smartSuperscript = true;
    try { mf.menuItems = []; } catch (_) { /* older API */ }
    mf.setAttribute('aria-label', 'Formula');
    if (latex) mf.value = latex;
    chip.appendChild(mf);
    mf.addEventListener('input', notifyInput);
    mf.addEventListener('keydown', (e) => onMathKey(e, chip, mf), true);
    return chip;
  }

  /// Puts the caret in the editor just before or after a chip (a zero-width space keeps a text position there).
  function caretBeside(chip, after) {
    let target = after ? chip.nextSibling : chip.previousSibling;
    if (!target || target.nodeType !== Node.TEXT_NODE) {
      target = document.createTextNode('​');
      chip.parentNode.insertBefore(target, after ? chip.nextSibling : chip);
    }
    editor.focus();
    const range = document.createRange();
    const offset = after ? Math.min(1, target.data.length) : Math.max(0, target.data.length - (target.data.endsWith('​') ? 1 : 0));
    range.setStart(target, after ? (target.data.startsWith('​') ? 1 : 0) : offset);
    range.collapse(true);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  function insertMath(latex) {
    editor.focus();
    const sel = window.getSelection();
    let range = sel.rangeCount ? sel.getRangeAt(0) : null;
    if (!range || !editor.contains(range.commonAncestorContainer)) {
      range = document.createRange();
      range.selectNodeContents(editor);
      range.collapse(false);
    }
    range.deleteContents();
    const chip = makeChip(latex || '');
    range.insertNode(chip);
    // A text position after the chip so typing can continue past it.
    const after = document.createTextNode('​');
    chip.parentNode.insertBefore(after, chip.nextSibling);
    const mf = chip.querySelector('math-field');
    requestAnimationFrame(() => { mf.focus(); });
    notifyInput();
  }

  function onMathKey(e, chip, mf) {
    const atEnd = () => { try { return mf.position >= mf.lastOffset; } catch (_) { return true; } };
    const atStart = () => { try { return mf.position <= 0; } catch (_) { return true; } };
    if (e.key === '$' || e.key === 'Escape' || (e.key === 'ArrowRight' && atEnd())) {
      e.preventDefault(); e.stopPropagation();
      caretBeside(chip, true);
    } else if (e.key === 'ArrowLeft' && atStart()) {
      e.preventDefault(); e.stopPropagation();
      caretBeside(chip, false);
    } else if (e.key === 'Backspace' && !mf.getValue('latex').trim()) {
      e.preventDefault(); e.stopPropagation();
      const before = chip.previousSibling;
      chip.remove();
      if (before && before.nodeType === Node.TEXT_NODE) {
        editor.focus();
        const range = document.createRange();
        range.setStart(before, before.data.length);
        range.collapse(true);
        const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
      } else {
        editor.focus();
      }
      notifyInput();
    } else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault(); e.stopPropagation();
      submit();
    } else if (e.key === 'Enter' && multiline) {
      // A new line after the formula.
      e.preventDefault(); e.stopPropagation();
      caretBeside(chip, true);
      document.execCommand('insertLineBreak');
      notifyInput();
    } else if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault(); e.stopPropagation();
      submit();
    }
  }

  /* ================================================================ editor */

  editor.addEventListener('keydown', (e) => {
    if (e.target !== editor) return;
    if (e.key === '$') {
      e.preventDefault();
      insertMath('');
    } else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      submit();
    } else if (e.key === 'Enter' && !e.shiftKey && !multiline) {
      e.preventDefault();
      submit();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      document.execCommand('insertLineBreak');
      notifyInput();
    }
  });
  editor.addEventListener('input', notifyInput);
  editor.addEventListener('paste', (e) => {
    e.preventDefault();
    const text = (e.clipboardData && e.clipboardData.getData('text/plain')) || '';
    document.execCommand('insertText', false, text);
  });

  function submit() {
    const text = currentText().trim();
    if (!text) return;
    clearTimeout(inputTimer);
    thuban.send('input', { text: currentText() });
    thuban.send('submit', { text });
  }

  function clear() {
    editor.innerHTML = '';
    thuban.send('input', { text: '' });
    scheduleHeight();
  }

  /// A draft in message form ("Is $x^2$ right?") back into text and math fields.
  function setText(payload) {
    editor.innerHTML = '';
    const text = String((payload && payload.text) || '');
    // $$…$$ (display) before $…$ (inline); line breaks come back as <br>.
    const pattern = /\$\$([^$]+)\$\$|\$([^$]+)\$/g;
    const appendText = (chunk) => {
      chunk.split('\n').forEach((line, i) => {
        if (i > 0) editor.appendChild(document.createElement('br'));
        if (line) editor.appendChild(document.createTextNode(line));
      });
    };
    let last = 0, m;
    while ((m = pattern.exec(text))) {
      if (m.index > last) appendText(text.slice(last, m.index));
      editor.appendChild(m[1] !== undefined ? makeChip(m[1], true) : makeChip(m[2], false));
      last = m.index + m[0].length;
    }
    if (last < text.length) appendText(text.slice(last));
    scheduleHeight();
  }

  function focus() {
    editor.focus();
    const range = document.createRange();
    range.selectNodeContents(editor);
    range.collapse(false);
    const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
  }

  /* ================================================================ height */

  let heightRaf = 0;
  function scheduleHeight() {
    if (heightRaf) return;
    heightRaf = requestAnimationFrame(() => {
      heightRaf = 0;
      thuban.send('height', { px: Math.ceil(editor.getBoundingClientRect().height) });
    });
  }

  /* ================================================================ wiring */

  function configure(payload) {
    const p = payload || {};
    if (typeof p.placeholder === 'string') editor.dataset.placeholder = p.placeholder;
    if (typeof p.label === 'string') editor.setAttribute('aria-label', p.label);
    if (typeof p.multiline === 'boolean') {
      multiline = p.multiline;
      document.body.classList.toggle('is-multiline', multiline);
    }
    scheduleHeight();
  }

  const HANDLERS = { clear, setText, focus, configure, insertMath: (p) => insertMath(p && p.latex) };
  const queued = [];
  let ready = false;
  for (const type of Object.keys(HANDLERS)) {
    thuban.on(type, (payload) => { if (ready) HANDLERS[type](payload); else queued.push([type, payload]); });
  }

  function init() {
    MathfieldElement = window.MathLive.MathfieldElement;
    MathfieldElement.fontsDirectory = FONTS_DIRECTORY;
    MathfieldElement.soundsDirectory = null;
    MathfieldElement.keypressVibration = false;
    if (window.ResizeObserver) new ResizeObserver(scheduleHeight).observe(editor);
    thuban.on('theme', scheduleHeight);
    ready = true;
    for (const [type, payload] of queued.splice(0)) HANDLERS[type](payload);
    scheduleHeight();
  }

  if (window.MathLive) init();
  else window.addEventListener('load', () => { if (window.MathLive) init(); });
})();
