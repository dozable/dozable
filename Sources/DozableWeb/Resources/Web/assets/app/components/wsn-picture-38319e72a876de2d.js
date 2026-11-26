// components/wsn-picture — The New workspace wizard's drawings (782): a template's card, a screen's header, the full-page
// view. Drawn with the dashboard's own renderer (core/space-pictures.js loadRenderer — the one lazy import), from a space
// document in the renderer's words: a template's comes from the templates route, Custom's from core/ws-new.js pictureText.
// A thumbnail has no words; the full view labels it. Nothing here is a control but ⤢ and the view's own buttons.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { currentTheme, loadRenderer } from '../core/space-pictures-25bdb63b8ef211eb.js';
import { btn } from './button-030d384b64f8d75d.js';

let seq = 0;
/// A drawing of `text` at `size` ({w, h}; `kind` 'thumb' — no words — or 'hero' — labelled), painted when the renderer is
/// loaded. → the element (an <img> for a thumb, the SVG for a hero, inside a frame).
export function drawing(text, size, kind = 'thumb', label = '') {
  const frame = h('span', { class: 'wz-pic wz-pic-' + kind, role: 'img', 'aria-label': label || 'The workspace, drawn', 'data-wz-pic': kind });
  const id = 'wz' + (++seq) + '-';
  loadRenderer().then((mod) => {
    // The page's theme when it sets one, else the viewer's own (the SVG's own style follows it as it changes).
    const theme = document.documentElement.dataset.theme ? currentTheme() : 'auto';
    const opts = { detail: kind, width: size.w, height: size.h, theme, idPrefix: id };
    if (kind === 'thumb') {
      const img = h('img', { alt: '', width: String(size.w), height: String(size.h), decoding: 'async',
        src: 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(mod.render(text, undefined, opts)) });
      frame.replaceChildren(img);
    } else {
      frame.replaceChildren(mod.renderElement(text, undefined, opts));
    }
    frame.dataset.wzPicDrawn = '';
  }).catch(() => { frame.replaceChildren(icon('boxes')); frame.dataset.wzPicFailed = ''; });
  return frame;
}

/// ⤢ — opens the full-page view (`open(button)`); its label names what it expands.
export function expandButton(name, open) {
  const b = h('button', { type: 'button', class: 'wz-expand', 'aria-label': 'Expand ' + name, title: 'Expand ' + name, 'data-wz-expand': name },
    icon('maximize-2'));
  b.addEventListener('click', (ev) => { ev.preventDefault(); ev.stopPropagation(); open(b); });
  return b;
}

/// The full-page view over the wizard: the drawing large and labelled (left; on a phone, on top), and beside it `info` —
/// the essentials as nodes — and, when given, the one action. ✕, Escape or a click outside the panel closes it (the
/// wizard stays open beneath it); focus starts on the action (else ✕), Tab stays inside, and closing returns focus to
/// `opener`. → close().
export function fullView(o) {
  const box = document.getElementById('wm-box');
  const under = box.firstElementChild;
  const close = () => {
    view.remove();
    if (under) under.inert = false;
    if (o.opener && o.opener.isConnected) o.opener.focus();
  };
  const x = btn('Close', close, { quiet: true, iconOnly: true, icon: 'x', title: 'Close (Esc)' });
  x.dataset.wzViewClose = '';
  const action = o.action ? h('button', { type: 'button', class: 'btn lg primary wz-view-act', 'data-wz-view-use': '' }, o.action.label) : null;
  if (action) action.addEventListener('click', () => { close(); o.action.run(); });
  const pic = drawing(o.text, { w: 960, h: 600 }, 'hero', o.title + ', drawn');
  const panel = h('div', { class: 'wz-view-panel', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'wz-view-title', 'data-wz-view': o.title },
    h('div', { class: 'wz-view-pic' }, pic),
    h('div', { class: 'wz-view-side' },
      h('div', { class: 'wz-view-head' }, h('h2', { id: 'wz-view-title' }, o.title), x),
      o.summary ? h('p', { class: 'wz-view-sum' }, o.summary) : null,
      h('div', { class: 'wz-view-info' }, ...o.info),
      action ? h('div', { class: 'wz-view-foot' }, action) : null));
  const view = h('div', { class: 'wz-view' }, panel);
  view.addEventListener('click', (ev) => { if (ev.target === view) close(); });
  view.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); close(); return; }
    if (ev.key !== 'Tab') return;
    ev.stopPropagation();
    const f = [...panel.querySelectorAll('button:not([disabled]), a[href]')].filter((e) => e.getClientRects().length > 0);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1], a = document.activeElement;
    if (ev.shiftKey && a === first) { ev.preventDefault(); last.focus(); } else if (!ev.shiftKey && a === last) { ev.preventDefault(); first.focus(); }
  });
  if (under) under.inert = true;
  box.append(view);
  (action || x).focus();
  return close;
}

/// One line of the view's essentials: a heading and its rows.
export function viewSection(title, ...rows) {
  return h('section', { class: 'wz-view-sec' }, h('h3', null, title), ...rows);
}
