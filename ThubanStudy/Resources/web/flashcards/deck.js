/*
 * Thuban Study — flashcards page (deck.html, hosted by FlashcardDeckWebView). Cards are Markdown with LaTeX,
 * rendered by shared/richtext.js (the transcript's renderer). Swift owns the deck and the review session; this page
 * draws and reports gestures.
 *
 *   Swift → JS   card {side: "front"|"back", text, hint}     one face of the card under review
 *                bank {cards: [{id, front, back, chip, chipKind}], emptyMessage}
 *                preview {front, back}                       both faces (the editor's live preview)
 *                pick {cards: [{front, back, on}]}           generated cards to choose from, each with a checkbox
 *                theme {css, isDark}                         handled by shared/bridge.js
 *   JS → Swift   ready
 *                flip {}                                     click on the card
 *                key {key: " "|"1"|"2"|"Escape"}             review keys while the page has focus
 *                edit {id}                                   double-click a bank row, or its edit button
 *                delete {id}                                 its delete button (Swift asks first)
 *                toggle {index, on}                          a generated card ticked or unticked
 */
(function () {
  'use strict';

  const thuban = window.thuban;
  const root = document.getElementById('root');

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }
  function rich(target, text) {
    if (window.ThubanRich) window.ThubanRich.render(target, text);
    else target.textContent = text;
  }

  /* ---------------------------------------------------------------- review */

  function showCard(payload) {
    document.body.className = 'is-card';
    root.textContent = '';
    const card = el('button', 'flash is-' + (payload.side === 'back' ? 'back' : 'front'));
    card.type = 'button';
    card.setAttribute('aria-label', (payload.side === 'back' ? 'Answer' : 'Question') + '. Click or press Space to flip.');
    const face = el('div', 'flash__face', payload.side === 'back' ? 'Answer' : 'Question');
    const content = el('div', 'flash__content');
    rich(content, payload.text || '');
    const hint = el('div', 'flash__hint', payload.hint || '');
    card.appendChild(face);
    card.appendChild(content);
    card.appendChild(hint);
    card.addEventListener('click', () => thuban.send('flip', {}));
    root.appendChild(card);
    requestAnimationFrame(() => card.focus({ preventScroll: true }));
  }

  document.addEventListener('keydown', (e) => {
    if (!document.body.classList.contains('is-card')) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const key = e.key === ' ' || e.code === 'Space' ? ' ' : e.key;
    if (key === ' ' || key === '1' || key === '2' || key === 'Escape' || key === 'Enter') {
      e.preventDefault();
      thuban.send('key', { key: key === 'Enter' ? ' ' : key });
    }
  });

  /* ------------------------------------------------------------------ bank */

  const ICONS = {
    edit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 20h4L19 9l-4-4L4 16v4z"/></svg>',
    del: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>'
  };

  function showBank(payload) {
    document.body.className = 'is-bank';
    root.textContent = '';
    const cards = Array.isArray(payload.cards) ? payload.cards : [];
    if (!cards.length) {
      root.appendChild(el('p', 'empty', payload.emptyMessage || 'No cards yet.'));
      return;
    }
    const list = el('div', 'rows');
    for (const c of cards) {
      const row = el('div', 'row');
      row.dataset.id = c.id;
      const front = el('div', 'row__front');
      rich(front, c.front);
      const back = el('div', 'row__back');
      rich(back, c.back);
      const chip = el('span', 'chip chip--' + (c.chipKind || 'neutral'), c.chip || '');
      const acts = el('div', 'row__acts');
      const edit = el('button', 'icon-btn');
      edit.type = 'button';
      edit.innerHTML = ICONS.edit;
      edit.setAttribute('aria-label', 'Edit card');
      edit.addEventListener('click', () => thuban.send('edit', { id: c.id }));
      const del = el('button', 'icon-btn');
      del.type = 'button';
      del.innerHTML = ICONS.del;
      del.setAttribute('aria-label', 'Delete card');
      del.addEventListener('click', () => thuban.send('delete', { id: c.id }));
      acts.appendChild(edit);
      acts.appendChild(del);
      row.appendChild(front);
      row.appendChild(back);
      row.appendChild(chip);
      row.appendChild(acts);
      row.addEventListener('dblclick', () => thuban.send('edit', { id: c.id }));
      list.appendChild(row);
    }
    root.appendChild(list);
  }

  /* --------------------------------------------------------------- preview */

  function showPreview(payload) {
    document.body.className = 'is-preview';
    root.textContent = '';
    for (const [label, text] of [['Front', payload.front], ['Back', payload.back]]) {
      const box = el('section', 'preview');
      box.appendChild(el('div', 'preview__label', label));
      const content = el('div', 'preview__content');
      if (String(text || '').trim()) rich(content, text);
      else content.appendChild(el('span', 'preview__empty', 'Nothing yet'));
      box.appendChild(content);
      root.appendChild(box);
    }
  }

  /* ------------------------------------------------------------------ pick */

  function showPick(payload) {
    document.body.className = 'is-bank is-pick';
    root.textContent = '';
    const cards = Array.isArray(payload.cards) ? payload.cards : [];
    const list = el('div', 'rows');
    cards.forEach((c, index) => {
      const row = el('label', 'row row--pick' + (c.on ? '' : ' is-off'));
      const box = el('input', 'pick');
      box.type = 'checkbox';
      box.checked = !!c.on;
      box.setAttribute('aria-label', 'Keep card ' + (index + 1));
      box.addEventListener('change', () => {
        row.classList.toggle('is-off', !box.checked);
        thuban.send('toggle', { index, on: box.checked });
      });
      const front = el('div', 'row__front');
      rich(front, c.front);
      const back = el('div', 'row__back');
      rich(back, c.back);
      row.appendChild(box);
      row.appendChild(front);
      row.appendChild(back);
      list.appendChild(row);
    });
    root.appendChild(list);
  }

  thuban.on('pick', showPick);
  thuban.on('card', showCard);
  thuban.on('bank', showBank);
  thuban.on('preview', showPreview);
})();
