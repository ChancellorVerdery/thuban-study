/*
 * Thuban Study — shared Swift ⇄ JS bridge.
 *
 * Every WKWebView-hosted page includes this file FIRST. It defines `window.thuban`:
 *
 *   thuban.send(type, payload)      JS → Swift. Posts {type, payload} to webkit.messageHandlers.thuban.
 *   thuban.on(type, fn)             Registers a handler for a Swift → JS message. Several handlers per type are allowed.
 *   thuban.receive(type, payload)   What Swift calls (via evaluateJavaScript). `payload` may be a JSON string or an object.
 *   thuban.hasBridge                true when running inside the app (webkit.messageHandlers.thuban exists).
 *
 * Built in:
 *   - 'ready' is posted on DOMContentLoaded, i.e. after every page script has registered its handlers
 *     (page scripts are parser-inserted / deferred, so they run before DOMContentLoaded fires).
 *   - a 'theme' handler applies payload.css into <style id="theme"> and sets <html data-theme="dark|light">.
 *   - without a bridge (page opened in Safari for debugging) send() logs to the console and to a small
 *     debug panel, and a Brass light/dark theme is synthesized from prefers-color-scheme so the page can be eyeballed.
 */
(function () {
  'use strict';

  if (window.thuban) return; // already installed (a page included the script twice)

  var handlers = Object.create(null);   // type → [fn, …]
  var messageHandler = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.thuban) || null;
  var hasBridge = !!messageHandler;

  /* ------------------------------------------------------------------ send */

  function send(type, payload) {
    var message = { type: String(type), payload: payload === undefined ? {} : payload };
    if (hasBridge) {
      try {
        messageHandler.postMessage(message);
      } catch (err) {
        console.error('[thuban] postMessage failed for "' + type + '":', err);
      }
      return;
    }
    // Debug mode: no native host. Log and show in the panel.
    try { console.log('[thuban → swift] ' + type, message.payload); } catch (_) { /* ignore */ }
    debugLog(type, message.payload);
  }

  /* --------------------------------------------------------------- receive */

  function on(type, fn) {
    if (typeof fn !== 'function') return;
    (handlers[type] || (handlers[type] = [])).push(fn);
  }

  function off(type, fn) {
    var list = handlers[type];
    if (!list) return;
    var i = list.indexOf(fn);
    if (i >= 0) list.splice(i, 1);
  }

  function receive(type, payload) {
    // Swift passes the payload as a JSON string; be lenient and accept an object too.
    if (typeof payload === 'string') {
      try { payload = payload.length ? JSON.parse(payload) : {}; }
      catch (err) { console.error('[thuban] bad JSON payload for "' + type + '":', err); return false; }
    }
    if (payload === undefined || payload === null) payload = {};
    var list = handlers[type];
    if (!list || list.length === 0) {
      console.warn('[thuban] no handler for message type "' + type + '"');
      return false;
    }
    for (var i = 0; i < list.length; i++) {
      try { list[i](payload, type); }
      catch (err) { console.error('[thuban] handler for "' + type + '" threw:', err); }
    }
    return true;
  }

  /* ----------------------------------------------------------------- theme */

  function themeStyleElement() {
    var el = document.getElementById('theme');
    if (!el) {
      el = document.createElement('style');
      el.id = 'theme';
      (document.head || document.documentElement).appendChild(el);
    }
    return el;
  }

  function applyTheme(payload) {
    if (!payload) return;
    if (typeof payload.css === 'string') themeStyleElement().textContent = payload.css;
    document.documentElement.dataset.theme = payload.isDark ? 'dark' : 'light';
    document.documentElement.style.colorScheme = payload.isDark ? 'dark' : 'light';
  }
  on('theme', applyTheme);

  /*
   * Brass fallbacks used only when there is no native host (Safari debugging).
   * Values mirror docs/design-brief.md; the real app always sends the resolved theme.
   */
  var BRASS_LIGHT = ':root{--bg:#f6f2e8;--panel:#fffdf7;--panel-2:#F1ECE0;--line:#E3E0D9;--line-2:#D3D0C8;' +
    '--ink:#161a21;--ink-dim:#535a68;--ink-faint:#858c9b;--accent:#e0b15c;--accent-text:#A5772A;--accent-deep:#a17f42;' +
    '--accent-tint:#F8EBD4;--on-accent:#14100a;--signal:#74d6c4;--signal-text:#2E8C7C;--pos:#5fd08a;--pos-text:#2F8A55;' +
    '--neg:#e08c8c;--neg-text:#B5484A;--pos-soft:#DFF3E6;--neg-soft:#F9E1E1;--warn-soft:#F8EBD4;--signal-soft:#DDF4F0;' +
    '--accent-rgb:224,177,92;--ink-rgb:22,26,33}';
  var BRASS_DARK = ':root{--bg:#090b11;--panel:#0e1219;--panel-2:#151A24;--line:#1C2028;--line-2:#29303E;' +
    '--ink:#e9e7df;--ink-dim:#9aa0ad;--ink-faint:#5c616e;--accent:#e0b15c;--accent-text:#e0b15c;--accent-deep:#a17f42;' +
    '--accent-tint:#21201A;--on-accent:#14100a;--signal:#74d6c4;--signal-text:#74d6c4;--pos:#5fd08a;--pos-text:#5fd08a;' +
    '--neg:#e08c8c;--neg-text:#e08c8c;--pos-soft:#12261A;--neg-soft:#2C1516;--warn-soft:#21201A;--signal-soft:#10262A;' +
    '--accent-rgb:224,177,92;--ink-rgb:202,214,242}';

  function synthesizeTheme() {
    var mq = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
    var apply = function () {
      var dark = !!(mq && mq.matches);
      receive('theme', { css: dark ? BRASS_DARK : BRASS_LIGHT, isDark: dark });
    };
    apply();
    if (mq && mq.addEventListener) mq.addEventListener('change', apply);
  }

  /* ----------------------------------------------------------- debug panel */

  var panel = null, panelList = null, panelCount = 0;

  function debugPanel() {
    if (panel || !document.body) return panel;
    panel = document.createElement('div');
    panel.id = 'thuban-debug';
    panel.setAttribute('aria-live', 'polite');
    panel.style.cssText =
      'position:fixed;top:8px;right:8px;z-index:2147483000;max-width:min(360px,60vw);' +
      'font:11px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ink-dim,#535a68);' +
      'background:var(--panel,#fffdf7);border:1px solid var(--line-2,#D3D0C8);border-radius:8px;' +
      'box-shadow:none;opacity:.94;overflow:hidden;';
    var head = document.createElement('button');
    head.type = 'button';
    head.textContent = 'thuban bridge · debug (no native host)';
    head.style.cssText =
      'display:block;width:100%;text-align:left;font:inherit;font-weight:600;color:var(--accent-text,#A5772A);' +
      'background:var(--panel-2,#F1ECE0);border:0;border-bottom:1px solid var(--line,#E3E0D9);padding:5px 8px;cursor:pointer;';
    head.setAttribute('aria-expanded', 'true');
    panelList = document.createElement('div');
    panelList.style.cssText = 'padding:4px 8px;max-height:200px;overflow:auto;white-space:pre-wrap;word-break:break-word;';
    head.addEventListener('click', function () {
      var open = panelList.style.display !== 'none';
      panelList.style.display = open ? 'none' : '';
      head.setAttribute('aria-expanded', String(!open));
    });
    panel.appendChild(head);
    panel.appendChild(panelList);
    document.body.appendChild(panel);
    return panel;
  }

  function debugLog(type, payload) {
    if (!debugPanel()) {
      // body not parsed yet — retry once the DOM is ready
      document.addEventListener('DOMContentLoaded', function () { debugLog(type, payload); }, { once: true });
      return;
    }
    var line = document.createElement('div');
    var text;
    try { text = JSON.stringify(payload); } catch (_) { text = String(payload); }
    if (text && text.length > 160) text = text.slice(0, 157) + '…';
    line.textContent = (++panelCount) + '  → ' + type + '  ' + (text === '{}' ? '' : text);
    panelList.appendChild(line);
    while (panelList.childNodes.length > 12) panelList.removeChild(panelList.firstChild);
    panelList.scrollTop = panelList.scrollHeight;
  }

  /* ------------------------------------------------------------------ boot */

  window.thuban = {
    send: send,
    on: on,
    off: off,
    receive: receive,
    hasBridge: hasBridge,
    applyTheme: applyTheme
  };

  document.addEventListener('DOMContentLoaded', function () {
    if (!hasBridge) synthesizeTheme();
    send('ready', {});
  });
})();
