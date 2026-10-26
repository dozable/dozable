// components/session-thumb — A session's screen, small. 648: every picture on All sessions, All sandboxes and a sandbox's
// Home is PAINTED on a canvas from a grid (components/screen-paint.js) — no terminal engine, no frame, no socket: a
// running session's from the host's feed (components/grid-feed.js), or on Home from its own tab's frame when it has
// one; a sleeping sandbox's from its saved screen. Only Larger on hover and the sidebar's peek are a real (watch)
// terminal still: `thumbTerm`, laid out at its session's geometry and scaled.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { feedSubscribe, isVisible, refreshMs, savedPicture, watchVisible } from './grid-feed-1845116086f22c8c.js';
import { picture } from './screen-paint-6e36213aa05daa71.js';
import { bootTerm, closeTerminal, newTerm, paintCover, requestGrid } from './terminal-fe950acd70dc3353.js';

/// The virtual size a peek's terminal is laid out at (then scaled by CSS).
export const THUMB_COLS_PX = 960, THUMB_ROWS_PX = 560;

/// A WATCH terminal for `session` in `screen` (an element laid out at 960 × 560) — no size of its own, nothing typed, a
/// viewer that never resizes the session — or its SAVED screen when `saved` is given (no socket: it keeps no host
/// alive). Not a tab of any page (`grid`). The sidebar's peek and Larger on hover. Returns the terminal.
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

// ── a painted picture's source ───────────────────────────────────────────────
/// What a picture shows, and from where (`want(spec)`):
///   null                                         nothing (its plain background)
///   {kind: 'live', sandbox, session}             the host's feed; when it cannot give it, the session's last saved
///                                                 screen (state `last`), else none
///   {kind: 'live', sandbox, session, tab}        on Home: the tab's own frame (a terminal record), polled while the
///                                                 picture is on screen — the feed once the tab is gone
///   {kind: 'saved', sandbox, session, savedAt}   its saved screen, fetched once it is on screen
/// `onState({kind, savedAt?, reason?})` — kind live | saved | last | pending | none | null — after each change.
export function pictureSource(canvas, onState) {
  const pic = picture(canvas);
  const s = { canvas, pic, spec: null, key: '', sub: null, tabGen: 0, asking: false, unwatch: null, state: null };
  const set = (state) => { s.state = state; onState(state); };
  const stop = () => {
    if (s.sub) { s.sub.drop(); s.sub = null; }
    if (s.unwatch) { s.unwatch(); s.unwatch = null; }
    tabPolls.delete(s);
  };
  // When the live screen cannot be had: the session's last saved one (a running session's periodic capture), else none.
  const fallback = (key, reason) => {
    savedPicture(s.spec.sandbox, s.spec.session, null).then((got) => {
      if (s.key !== key) return;
      if (got) { pic.show(got.grid, 'saved:' + got.savedAt); set({ kind: 'last', savedAt: got.savedAt, reason }); }
      else set({ kind: 'none', reason });
    });
  };
  s.want = (spec) => {
    const key = spec ? [spec.kind, spec.sandbox, spec.session, spec.tab ? spec.tab.id : '', spec.savedAt || ''].join('|') : '';
    if (key === s.key) return;
    stop();
    s.key = key; s.spec = spec;
    if (!spec) { pic.clear(); set({ kind: null }); return; }
    if (spec.kind === 'live' && spec.tab) {
      s.tabGen = 0;
      s.unwatch = watchVisible(canvas, (v) => { if (v) pollTabs(); });
      tabPolls.add(s);
      startTabPolls();
      if (!s.state || s.state.kind !== 'live') set({ kind: 'pending' });
    } else if (spec.kind === 'live') {
      s.sub = feedSubscribe(spec.sandbox, spec.session, canvas, (r) => {
        if (s.key !== key) return;
        if (r.state === 'grid') { pic.show(r.grid, 'host'); set({ kind: 'live' }); }
        else fallback(key, r.reason);
      });
      if (!s.state || s.state.kind !== 'live') set({ kind: 'pending' });
    } else {
      let asked = false;
      s.unwatch = watchVisible(canvas, (v) => {
        if (!v || asked) return;
        asked = true;
        savedPicture(spec.sandbox, spec.session, spec.savedAt).then((got) => {
          if (s.key !== key) return;
          if (got) { pic.show(got.grid, 'saved:' + (got.savedAt || spec.savedAt)); set({ kind: 'saved', savedAt: got.savedAt || spec.savedAt }); }
          else set({ kind: 'none', reason: 'no saved screen' });
        });
      });
      if (!s.state || s.state.kind !== 'saved') set({ kind: 'pending' });
    }
  };
  s.set = set;
  s.drop = () => { stop(); s.key = ''; s.spec = null; pic.drop(); };
  return s;
}

// Home's pictures of sessions with a tab: ONE timer for all of them, every ui.grid_refresh_ms (the feed's period) while
// any is on screen and the browser tab is visible; each asks its tab's frame for the screen unless it is still the gen it
// painted. The timer re-arms itself, so a changed setting applies at the next pass.
const tabPolls = new Set();
let tabTimer = null;
function startTabPolls() { if (!tabTimer) tabTimer = setTimeout(tabPass, refreshMs()); }
function tabPass() {
  tabTimer = null;
  pollTabs();
  if (tabPolls.size) startTabPolls();
}
function pollTabs() {
  if (!tabPolls.size) return;
  if (document.visibilityState !== 'visible') return;
  for (const s of [...tabPolls]) {
    const tab = s.spec && s.spec.tab;
    if (!tab) continue;
    // The tab is gone (closed, or it ended): the host's feed from now on.
    if (tab.closed || tab.ended) { s.want({ kind: 'live', sandbox: s.spec.sandbox, session: s.spec.session }); continue; }
    if (s.asking || !isVisible(s.canvas) || !s.canvas.isConnected) continue;
    s.asking = true;
    const key = s.key;
    requestGrid(tab, s.tabGen).then((r) => {
      s.asking = false;
      if (s.key !== key || !r || r === 'same') return;
      s.tabGen = r.gen;
      s.pic.show(r, 'tab:' + tab.id);
      if (!s.state || s.state.kind !== 'live') s.set({ kind: 'live' });
    });
  }
}

// ── a thumbnail: a button holding the picture, a plate for when there is none, and a badge ───────────────────────
/// A thumbnail's frame: a button (a click is Open, or Show) holding the painted picture (a canvas), a plate for when it
/// shows nothing, and a badge (live · saved · last screen). Text only. `th.source` is its `pictureSource`.
export function thumbFrame(label, onClick, big) {
  const canvas = h('canvas', { class: 'thumb-paint', 'aria-hidden': 'true' });
  const plate = h('span', { class: 'th-plate' });
  const badge = h('span', { class: 'th-badge', hidden: true });
  const el = h('button', { type: 'button', class: 'home-thumb' + (big ? ' big' : ''), 'aria-label': label, title: label,
    on: { click: (ev) => { ev.stopPropagation(); onClick(); } } }, canvas, plate, badge);
  const th = { el, canvas, plate, badge, kind: null, plateText: '' };
  th.source = pictureSource(canvas, (st) => paintThumb(th, st));
  return th;
}

/// Say what a thumbnail shows (`st` from its source): live · saved N ago · last screen, or nothing with why (the plate).
export function paintThumb(th, st) {
  const kind = st ? st.kind : null;
  th.kind = kind;
  const drawn = kind === 'live' || kind === 'saved' || kind === 'last';
  th.el.dataset.kind = drawn ? kind : kind === 'pending' ? 'pending' : 'none';
  th.el.classList.toggle('saved', kind === 'saved');
  const plateText = drawn || kind === 'pending' ? '' : (st && st.reason) || th.plateText || 'no picture';
  th.plate.hidden = !plateText;
  th.plate.textContent = plateText;
  th.badge.hidden = !drawn;
  if (!drawn) { th.badge.replaceChildren(); return; }
  // 642 (owner): a saved screen says how long ago it was saved.
  const [cls, word] = kind === 'live' ? ['th-live', 'live'] : kind === 'last' ? ['th-frozen', 'last screen']
    : ['th-saved', st.savedAt ? 'saved ' + when(st.savedAt) : 'saved'];
  th.badge.replaceChildren(h('span', { class: cls, 'aria-hidden': 'true' }), word);
}
