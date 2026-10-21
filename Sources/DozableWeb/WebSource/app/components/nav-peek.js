// components/nav-peek — 635 (owner): a session's picture from the sidebar. Hovering a session's line shows a screen icon;
// resting on the icon fills it for half a second, then the session's live picture (or, asleep, its saved screen) opens
// beside the sidebar. While it is open, moving to another session's line shows that one's picture at once; leaving the
// sidebar's sessions closes it; a click on the icon opens the session (642). ui.nav_thumbnails: false — no icon, no picture. One watch terminal at most (a viewer:
// nothing typed, never a resize).
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { setting } from '../core/settings.js';
import { dropThumbTerm, THUMB_COLS_PX, THUMB_ROWS_PX, thumbTerm } from './session-thumb.js';

const ARM_MS = 500, HIDE_MS = 250, SCALE = 0.4;
const peek = { pop: null, screen: null, label: null, key: null, term: null, armKey: null, armAt: 0, armTimer: null, hideTimer: null };
const keyOf = (sandbox, session) => sandbox + '/' + session;

/// Whether a session line gets the icon: the setting, and a picture to show (running, or a saved screen).
export function canPeek(phase, x) {
  return setting('ui.nav_thumbnails', true) && (x.saved || phase === 'running');
}

/// The screen icon for a session line, and the line's own hover (switches an open picture at once).
export function peekIcon(row, sandbox, x) {
  const key = keyOf(sandbox, x.name);
  const b = h('button', { type: 'button', class: 'nav-peek', tabindex: '-1', 'aria-hidden': 'true', 'data-nav-peek': x.name,
    title: 'Open ' + x.name + ' — rest here to see its screen' }, icon('monitor'));
  // A line drawn again under a pointer still arming (the sidebar refreshes) carries on where it was.
  if (peek.armKey === key) { b.classList.add('arming'); b.style.setProperty('--arm-delay', -(performance.now() - peek.armAt) + 'ms'); }
  b.addEventListener('pointerenter', () => {
    cancelHide();
    if (peek.pop && !peek.pop.hidden) { show(sandbox, x, row); return; }
    if (peek.armKey === key) return;
    disarm();
    peek.armKey = key; peek.armAt = performance.now();
    b.classList.add('arming');
    peek.armTimer = setTimeout(() => { disarm(); show(sandbox, x, b.closest('.nav-sess-row') || row); }, ARM_MS);
  });
  b.addEventListener('pointerleave', () => { if (peek.armKey === key) disarm(); });
  // 642 (owner): a click opens the session, as its name does (resting still shows the picture).
  b.addEventListener('click', (ev) => { ev.preventDefault(); ev.stopPropagation(); disarm(); hidePeek(); location.hash = '#/sandbox/' + sandbox + '/' + x.name; });
  row.addEventListener('pointerenter', () => { cancelHide(); if (peek.pop && !peek.pop.hidden && peek.key !== key) show(sandbox, x, row); });
  return b;
}

/// 642 (owner): the same picture from a session's thumbnail elsewhere (All sandboxes): resting on `el` opens it beside
/// it; moving to another thumbnail while it is open shows that one's at once; leaving closes it. `getX`: the session row.
export function hoverPeek(el, sandbox, getX) {
  el.addEventListener('pointerenter', () => {
    cancelHide();
    if (peek.pop && !peek.pop.hidden) { show(sandbox, getX(), el); return; }
    disarm();
    peek.armKey = keyOf(sandbox, getX().name); peek.armAt = performance.now();
    peek.armTimer = setTimeout(() => { disarm(); if (el.isConnected) show(sandbox, getX(), el); }, ARM_MS);
  });
  el.addEventListener('pointerleave', () => { disarm(); scheduleHide(); });
  el.addEventListener('click', () => { disarm(); hidePeek(); });
}

/// The sidebar's session lists: leaving them closes the picture (after a moment — the way to the picture crosses a gap).
export function peekRegion(el) {
  el.addEventListener('pointerleave', () => { disarm(); scheduleHide(); });
}

function disarm() {
  clearTimeout(peek.armTimer);
  peek.armTimer = null; peek.armKey = null;
  for (const b of document.querySelectorAll('.nav-peek.arming')) { b.classList.remove('arming'); b.style.removeProperty('--arm-delay'); }
}
function cancelHide() { clearTimeout(peek.hideTimer); peek.hideTimer = null; }
function scheduleHide() { cancelHide(); peek.hideTimer = setTimeout(hidePeek, HIDE_MS); }

function popover() {
  if (peek.pop) return peek.pop;
  peek.screen = h('div', { class: 'thumb-screen' });
  peek.label = h('div', { class: 'np-label' });
  const frame = h('div', { class: 'np-frame' }, peek.screen);
  // (CSSOM, never a style attribute: the page's CSP admits no inline style.)
  frame.style.setProperty('--s', String(SCALE));
  frame.style.width = THUMB_COLS_PX * SCALE + 'px';
  frame.style.height = THUMB_ROWS_PX * SCALE + 'px';
  peek.pop = h('div', { class: 'nav-peek-pop', hidden: true, role: 'img', 'data-nav-peek-pop': '' }, frame, peek.label);
  peek.pop.addEventListener('pointerenter', cancelHide);
  peek.pop.addEventListener('pointerleave', scheduleHide);
  document.body.append(peek.pop);
  return peek.pop;
}

function show(sandbox, x, row) {
  const pop = popover();
  const key = keyOf(sandbox, x.name);
  cancelHide();
  if (peek.key !== key) {
    dropThumbTerm(peek.term);
    peek.term = thumbTerm(sandbox, x.name, x.saved ? { savedAt: x.savedAt, savedReason: x.savedReason } : null, peek.screen);
    peek.key = key;
    peek.label.replaceChildren(icon('monitor'), h('b', null, x.name), h('span', null, ' · ' + sandbox + (x.saved ? ' · its saved screen' : ' · live')));
  }
  pop.setAttribute('aria-label', x.name + ' in ' + sandbox);
  pop.hidden = false;
  // The line as drawn now (the sidebar may have drawn it again since the pointer arrived).
  const now = row && row.isConnected ? row
    : document.querySelector('#nav-sandboxes [data-nav-sbx="' + CSS.escape(sandbox) + '"] a.nav-sess[data-session="' + CSS.escape(x.name) + '"]')
      || document.querySelector('#nav-sandboxes');
  const r = now.getBoundingClientRect();
  // Beside the sidebar for its lines; beside the thumbnail elsewhere (on its left when the right has no room).
  const side = now.closest('.side') ? document.querySelector('.side') : null;
  const pw = pop.offsetWidth, ph = pop.offsetHeight;
  let left = (side ? side.getBoundingClientRect().right : r.right) + 8;
  if (!side && left + pw > innerWidth - 8) left = Math.max(8, r.left - pw - 8);
  pop.style.left = Math.round(left) + 'px';
  pop.style.top = Math.round(Math.max(8, Math.min(r.top + r.height / 2 - ph / 2, innerHeight - ph - 8))) + 'px';
}

/// Close the picture and let its terminal go.
export function hidePeek() {
  cancelHide();
  if (!peek.pop) return;
  peek.pop.hidden = true;
  dropThumbTerm(peek.term);
  peek.term = null; peek.key = null;
}
window.addEventListener('hashchange', hidePeek);
document.addEventListener('visibilitychange', () => { if (document.visibilityState !== 'visible') hidePeek(); });
