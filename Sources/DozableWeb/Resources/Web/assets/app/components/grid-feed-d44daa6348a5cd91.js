// components/grid-feed — 648: the ONE poller of the page's session pictures. Every ui.grid_refresh_ms (500 ms by
// default), while the browser tab is
// visible and a subscribed picture is on screen, it asks `POST /api/v1/grids` for those pictures' screens — each with the
// `gen` it last painted, so the host answers `unchanged` for a screen that did not move — at most 64 a request (more go
// in the next request of the same pass). It never wakes or starts anything: a session the host cannot read is
// `unavailable` and its picture falls back to the saved screen. Errors back off (up to 8 s); a dashboard whose server
// has no such route (an older doz) is told `unavailable` and asked again a minute later.
//
// Also here: which pictures are on screen (one IntersectionObserver for every picture), and a session's SAVED screen
// (the session-screen route — its grid when the host kept one, else its VT read into a grid), fetched once per capture.
import { api } from '../core/api-91016dbc2d27b20b.js';
import { textToGrid, validGrid } from '../core/grid-4b92452852ac3a96.js';
import { setting } from '../core/settings-353cfb79867783e4.js';
import { vtToGrid } from '../core/vt-grid-95166c7ca01e9679.js';

const MAX_BACKOFF_MS = 8000, ROUTE_RETRY_MS = 60000, BATCH = 64;
/// How often the pictures are brought up to date: the setting ui.grid_refresh_ms, read at each pass (it applies at once).
export function refreshMs() {
  const v = Number(setting('ui.grid_refresh_ms', 500));
  return Number.isFinite(v) ? Math.min(10000, Math.max(200, v)) : 500;
}
const STATES = new Set(['grid', 'unchanged', 'unavailable']);

// ── on screen ────────────────────────────────────────────────────────────────
const seen = new Map();          // element → [fn(visible)]
const visibleEls = new Set();
const io = typeof IntersectionObserver === 'function' ? new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (e.isIntersecting) visibleEls.add(e.target); else visibleEls.delete(e.target);
    for (const fn of seen.get(e.target) || []) fn(e.isIntersecting);
  }
}, { rootMargin: '120px' }) : null;
/// Call `fn(visible)` whenever `el` comes on or goes off screen (within 120 px). Returns the way to stop.
export function watchVisible(el, fn) {
  if (!io) { fn(true); return () => {}; }
  const fns = seen.get(el) || [];
  fns.push(fn);
  if (fns.length === 1) { seen.set(el, fns); io.observe(el); } else if (visibleEls.has(el)) fn(true);
  return () => {
    const list = (seen.get(el) || []).filter((x) => x !== fn);
    if (list.length) seen.set(el, list);
    else { seen.delete(el); visibleEls.delete(el); io.unobserve(el); }
  };
}
export function isVisible(el) { return !io || visibleEls.has(el); }

// ── the feed ─────────────────────────────────────────────────────────────────
const feed = { subs: new Set(), timer: null, busy: false, backoff: 0, routeMissingUntil: 0, polls: 0 };

/// Follow a running session's screen: `cb({state: 'grid', grid})` when it changed, `cb({state: 'unavailable', reason})`
/// when the host cannot give it (once, until a grid comes again). Polled only while `el` is on screen. Returns
/// `{drop()}`.
export function feedSubscribe(sandbox, session, el, cb) {
  const sub = { sandbox, session, el, cb, gen: 0, visible: false, unavailable: '', dropped: false };
  sub.unwatch = watchVisible(el, (v) => { sub.visible = v; if (v) { if (feedMissing()) tell(sub, 'unavailable', 'this dashboard’s server sends no screens'); kick(); } });
  feed.subs.add(sub);
  sub.drop = () => { if (sub.dropped) return; sub.dropped = true; sub.unwatch(); feed.subs.delete(sub); };
  return sub;
}
function feedMissing() { return Date.now() < feed.routeMissingUntil; }
function tell(sub, state, reason) {
  if (sub.dropped) return;
  if (state === 'unavailable') { if (sub.unavailable) return; sub.unavailable = reason || 'unavailable'; sub.cb({ state, reason: sub.unavailable }); }
}
function wanted() {
  if (document.visibilityState !== 'visible') return [];
  return [...feed.subs].filter((s) => s.visible && s.el.isConnected);
}
/// Poll soon (a picture came on screen, the tab came back).
function kick() { if (!feed.timer && !feed.busy) feed.timer = setTimeout(tick, 0); }
async function tick() {
  feed.timer = null;
  const subs = wanted();
  if (!subs.length) return;                                   // nothing to follow: no timer until something is
  if (feedMissing()) { for (const s of subs) tell(s, 'unavailable', 'this dashboard’s server sends no screens'); schedule(feed.routeMissingUntil - Date.now()); return; }
  feed.busy = true;
  let ok = true;
  try {
    for (let i = 0; i < subs.length; i += BATCH) {
      const part = subs.slice(i, i + BATCH);
      const r = await api('grids', { method: 'POST', json: { items: part.map((s) => ({ sandbox: s.sandbox, session: s.session, gen: s.gen })) } });
      answer(part, r);
    }
    feed.polls++;
  } catch (e) {
    ok = false;
    if (e && (e.status === 404 || e.status === 405)) {
      feed.routeMissingUntil = Date.now() + ROUTE_RETRY_MS;
      for (const s of subs) tell(s, 'unavailable', 'this dashboard’s server sends no screens');
    }
  } finally { feed.busy = false; }
  const period = refreshMs();
  feed.backoff = ok ? 0 : Math.min(MAX_BACKOFF_MS, Math.max(period, feed.backoff * 2 || 1000));
  schedule(ok ? period : feed.backoff);
}
function schedule(ms) { if (!feed.timer) feed.timer = setTimeout(tick, Math.max(0, ms)); }
/// The answer, item by item, matched to what was asked — a malformed one is that picture's `unavailable`, never drawn.
function answer(part, r) {
  const items = r && Array.isArray(r.items) ? r.items : [];
  for (const sub of part) {
    const it = items.find((x) => x && x.sandbox === sub.sandbox && x.session === sub.session);
    if (!it || !STATES.has(it.state)) { tell(sub, 'unavailable', 'no answer for it'); continue; }
    if (it.state === 'unchanged') continue;
    if (it.state === 'unavailable') { tell(sub, 'unavailable', typeof it.reason === 'string' ? it.reason.slice(0, 120) : 'unavailable'); continue; }
    if (!validGrid(it.grid)) { tell(sub, 'unavailable', 'its screen could not be read'); continue; }
    sub.gen = it.grid.gen;
    sub.unavailable = '';
    if (!sub.dropped) sub.cb({ state: 'grid', grid: it.grid });
  }
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') kick(); });
/// For the probes: how many passes the feed has made, and how many pictures it follows.
export function feedStats() { return { polls: feed.polls, subs: feed.subs.size, visible: wanted().length, backoff: feed.backoff, routeMissing: feedMissing() }; }

// ── saved screens ────────────────────────────────────────────────────────────
const savedCache = new Map();    // 'sandbox/session' → {at, promise}
let fetching = 0;
const queue = [];
const SAVED_PARALLEL = 3, SAVED_FRESH_MS = 60000;
/// A session's saved screen as a grid — `{grid, savedAt, reason}` — or null when none is kept. `savedAt`: the capture
/// the page knows of (a new one is fetched again); without it (a running session's periodic capture) a minute's copy.
export function savedPicture(sandbox, session, savedAt) {
  const key = sandbox + '/' + session;
  const c = savedCache.get(key);
  const stamp = savedAt || '';
  if (c && (stamp ? c.stamp === stamp : Date.now() - c.at < SAVED_FRESH_MS)) return c.promise;
  const promise = new Promise((resolve) => { queue.push({ sandbox, session, resolve }); pump(); });
  savedCache.set(key, { at: Date.now(), stamp, promise });
  promise.then((v) => { if (!v) { const now = savedCache.get(key); if (now && now.promise === promise) now.at = Date.now() - SAVED_FRESH_MS + 10000; } });
  return promise;
}
function pump() {
  while (fetching < SAVED_PARALLEL && queue.length) {
    const job = queue.shift();
    fetching++;
    loadSaved(job.sandbox, job.session).then(job.resolve, () => job.resolve(null)).finally(() => { fetching--; pump(); });
  }
}
async function loadSaved(sandbox, session) {
  let s;
  try { s = await api('sandboxes/' + encodeURIComponent(sandbox) + '/sessions/' + encodeURIComponent(session) + '/screen'); } catch (_) { return null; }
  if (!s || typeof s !== 'object') return null;
  const meta = { savedAt: typeof s.savedAt === 'string' ? s.savedAt : null, reason: typeof s.reason === 'string' ? s.reason : '' };
  // The host's grid when it kept one (a capture by a holder that knows GRID); else the VT the screen was saved as.
  if (s.grid !== undefined && validGrid(s.grid)) return { ...meta, grid: s.grid };
  if (typeof s.vt === 'string' && s.vt) {
    try {
      const bin = atob(s.vt);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return { ...meta, grid: vtToGrid(bytes, s.cols, s.rows) };
    } catch (_) { return null; }
  }
  if (typeof s.text === 'string') return { ...meta, grid: textToGrid(s.text, s.cols, s.rows) };
  return null;
}
