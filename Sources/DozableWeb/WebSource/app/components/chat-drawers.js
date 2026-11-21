// components/chat-drawers — a room's side panes as drawers where the window is too narrow to show them beside the log:
// the people (below 1101 px) and, on the Chat page, the rooms (at phone width). A pane opens over the log by its toggle in
// the head — one at a time —, with a scrim; the scrim, Escape and the toggle close it; Tab stays inside while it is open;
// the focus goes back to its toggle. Opening a room closes the rooms drawer. The state is a class on the surface
// (.is-people-open, .is-rooms-open), so the stylesheet decides where a pane is a drawer at all.
import { h } from '../dom/h.js';

const panes = new Map();   // which → { btn, pane }
let surface = null, scrim = null, open = null;

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
const focusables = (el) => [...el.querySelectorAll(FOCUSABLE)].filter((e) => e.getClientRects().length > 0);

/// The scrim behind an open drawer (put in the surface by the view).
export function drawerScrim() {
  scrim = h('div', { class: 'chat-scrim', 'aria-hidden': 'true' });
  scrim.addEventListener('click', () => closeDrawer(true));
  return scrim;
}

/// A pane `which` that its toggle `btn` opens as a drawer over `host` (the surface).
export function drawer(host, which, btn, pane) {
  surface = host;
  panes.set(which, { btn, pane });
  btn.setAttribute('aria-expanded', 'false');
  if (pane.id) btn.setAttribute('aria-controls', pane.id);
  btn.addEventListener('click', () => { if (open === which) closeDrawer(true); else openDrawer(which); });
  pane.addEventListener('keydown', (e) => {
    if (open !== which) return;
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeDrawer(true); return; }
    if (e.key !== 'Tab') return;
    const list = focusables(pane);
    if (!list.length) { e.preventDefault(); return; }
    const first = list[0], last = list[list.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus({ preventScroll: true }); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus({ preventScroll: true }); }
  });
}

/// Open the drawer `which` (any other one closes first); the focus goes into it.
export function openDrawer(which) {
  const p = panes.get(which);
  if (!p || !surface) return;
  if (open && open !== which) closeDrawer(false);
  open = which;
  surface.classList.add('is-' + which + '-open');
  p.btn.setAttribute('aria-expanded', 'true');
  if (!p.pane.hasAttribute('tabindex')) p.pane.setAttribute('tabindex', '-1');
  const target = focusables(p.pane)[0] || p.pane;
  target.focus({ preventScroll: true });   // a drawer never scrolls what is under it
}

/// Close the open drawer; `back`: the focus returns to its toggle.
export function closeDrawer(back) {
  if (!open || !surface) return;
  const p = panes.get(open);
  surface.classList.remove('is-' + open + '-open');
  open = null;
  if (!p) return;
  p.btn.setAttribute('aria-expanded', 'false');
  if (back && p.btn.getClientRects().length) p.btn.focus({ preventScroll: true });
}
