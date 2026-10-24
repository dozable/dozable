// components/session-thumb — A session's screen, small: a live (watch) or saved terminal laid out at its own geometry
// and scaled. All sessions' tiles (593) and the sandbox Home's thumbnails (635) both draw theirs with it.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { setting } from '../core/settings-f00434ef195e82b4.js';
import { terminals } from '../core/terminals-e2028f16ee8fa887.js';
import { bootTerm, closeTerminal, freezeTerm, goLive, newTerm, paintCover, thawTerm } from './terminal-db5079cbec33b9cd.js';

/// The virtual size a thumbnail's terminal is laid out at (then scaled by CSS): the grid's tile size.
export const THUMB_COLS_PX = 960, THUMB_ROWS_PX = 560;

/// Attach a terminal for `session` into `screen` (an element laid out at 960 × 560): a WATCH terminal (no size of its
/// own, nothing typed — a viewer that never resizes the session), or its SAVED screen when `saved` is given (no socket:
/// it keeps no host alive). Not a tab of any page (`grid`). Returns the terminal.
export function thumbTerm(sandbox, session, saved, screen) {
  const t = newTerm(sandbox, session, 'watch');
  t.grid = true;
  if (saved) t.saved = { savedAt: saved.savedAt, reason: saved.savedReason };
  paintCover(t);
  screen.append(t.els.wrap);
  bootTerm(t, 13);
  return t;
}

/// Let it go: its socket closes, its frame and engine instance go.
export function dropThumbTerm(t) { if (t) closeTerminal(t.id); }

/// A saved thumbnail whose sandbox runs again becomes the live one in place (the frame leaves saved mode).
export function thumbGoLive(t) { if (t && t.saved) goLive(t); }

/// 642: a live thumbnail lets go of its socket and keeps its last frame; and attaches again.
export function thumbFreeze(t) { freezeTerm(t); }
export function thumbThaw(t) { thawTerm(t); }

/// How many sockets this page holds now (every terminal with one) — the server allows 16 per UI.
export function openSockets() { return [...terminals.values()].filter((t) => t.ws).length; }

/// The live thumbnails a page may hold at once: ui.grid_live_tiles, at most `max`.
export function liveCap(max) { return Math.max(1, Math.min(max, Number(setting('ui.grid_live_tiles', 8)) || 8)); }

/// A thumbnail's frame: a button (a click is Open, or Show) holding the scaled screen, a plate for when it is not
/// drawn, and a badge (live · saved). Text only.
export function thumbFrame(label, onClick, big) {
  const screen = h('div', { class: 'thumb-screen' });
  const plate = h('span', { class: 'th-plate' });
  const badge = h('span', { class: 'th-badge', hidden: true });
  const el = h('button', { type: 'button', class: 'home-thumb' + (big ? ' big' : ''), 'aria-label': label, title: label,
    on: { click: (ev) => { ev.stopPropagation(); onClick(); } } }, screen, plate, badge);
  return { el, screen, plate, badge, term: null, kind: null, visible: false };
}

/// Say what a thumbnail shows: its kind (live | saved | frozen — 642: its last live frame, between turns | null) and,
/// when it shows nothing, why.
export function paintThumb(th, kind, plateText) {
  th.el.dataset.kind = kind || 'none';
  th.el.classList.toggle('saved', kind === 'saved');
  th.plate.hidden = !!th.term;
  th.plate.textContent = th.term ? '' : (plateText || '');
  th.badge.hidden = !th.term;
  // 642 (owner): a saved screen says how long ago it was saved.
  const at = kind === 'saved' && th.term && th.term.saved ? th.term.saved.savedAt : null;
  const [cls, word] = kind === 'live' ? ['th-live', 'live'] : kind === 'frozen' ? ['th-frozen', 'paused'] : ['th-saved', at ? 'saved ' + when(at) : 'saved'];
  if (th.term) th.badge.replaceChildren(h('span', { class: cls, 'aria-hidden': 'true' }), word);
}
