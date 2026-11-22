// core/space-pictures — The workspace drawn: reads, queue, cache (web.md, "The workspace drawn"). The renderer loads
// when a picture first shows, through the ONE lazy load the compiler's table allows. Reads only for pictures on screen,
// only after an event marks them stale — never a timer; one render per frame, the hero first.
import { api } from './api-47cfabfed13b475c.js';
import { state } from './state-1036883eb74b9520.js';

let renderer = null;
/// Loaded once; a failed load stays failed (the fallback says so).
export function loadRenderer() {
  if (!renderer) renderer = import('/assets/vendor-space-editor-f0c1044ea2975882/space-render.js');
  return renderer;
}

export const pictureStats = { fileReads: 0, stateReads: 0, planReads: 0, renders: 0, hits: 0, ms: { hero: [], thumb: [] } };

const entries = new Map();
const views = new Set();
let fileEpoch = 1, stateEpoch = 1;
let marked = null;
let reading = 0;
const MAX_READS = 2, CACHE = 48;
const cache = new Map();

function entry(name) {
  if (!entries.has(name)) entries.set(name, { name, text: null, fileSha: null, st: null, fileAt: 0, stateAt: 0, stateFileAt: 0 });
  return entries.get(name);
}

/// Something may have changed (`file`: the file too). Coalesced; the pictures on screen are read again.
export function picturesStale(o = {}) {
  if (marked) { marked.file = marked.file || !!o.file; return; }
  marked = { file: !!o.file };
  queueMicrotask(() => { stateEpoch++; if (marked.file) fileEpoch++; marked = null; pump(); for (const fn of [...staleFns]) fn(); });
}
const staleFns = new Set();
/// Called after each (coalesced) mark — the space editor's Live reads on these events too. → stop.
export function onPicturesStale(fn) { staleFns.add(fn); return () => staleFns.delete(fn); }

export function forgetPictures(names) {
  for (const n of [...entries.keys()]) if (!names.includes(n)) entries.delete(n);
}

/// The dashboard's theme (data-theme), else this Mac's.
export function currentTheme() {
  const t = document.documentElement.dataset.theme;
  if (t === 'light' || t === 'dark') return t;
  return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

// ── the pictures on screen
let watching = false;
function watchTheme() {
  if (watching) return;
  watching = true;
  const again = () => { for (const v of views) if (v.visible) want(v); };
  new MutationObserver(again).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', again);
}

/// paint({svg}|{src} + key, problem | {fallback} | {reading}).
export function pictureView(name, kind, size, el, paint) {
  watchTheme();
  const v = { name, kind, w: size.w, h: size.h, el, paint, visible: false, key: null, painted: null, dropped: false };
  views.add(v);
  return v;
}
export function setPictureVisible(v, on) {
  v.visible = !!on && !v.dropped;
  if (v.visible) { want(v); pump(); }
}
export function setPictureSize(v, size) {
  if (v.w === size.w && v.h === size.h) return;
  v.w = size.w; v.h = size.h;
  if (v.visible) want(v);
}
export function dropPicture(v) { v.dropped = true; v.visible = false; views.delete(v); renders.delete(v); }
const onScreen = (v) => v.visible && !v.dropped && v.el.isConnected;

// ── reads
function quiet(name) {
  const w = state.workspaces && state.workspaces.workspaces.find((x) => x.name === name);
  return !!w && ['asleep', 'finished', 'archived'].includes(w.state);
}
const needsFile = (e) => e.fileAt < fileEpoch;
// asleep, finished, archived: read once more, then only on a file mark
const needsState = (e) => !!e.text && (quiet(e.name) && e.wasQuiet ? e.stateFileAt < fileEpoch : e.stateAt < stateEpoch);

function pump() {
  const names = [...new Set([...views].filter(onScreen).map((v) => v.name))];
  for (const n of names) {
    const e = entry(n);
    if (e.inflight) continue;
    if (needsFile(e) || needsState(e)) {
      if (reading >= MAX_READS) return;
      readOne(e);
    } else for (const v of views) if (v.name === n && onScreen(v)) want(v);
  }
}

async function readOne(e) {
  e.inflight = true;
  reading++;
  try {
    if (needsFile(e)) {
      const at = fileEpoch;
      pictureStats.fileReads++;
      try {
        const f = await api('workspace-space', { method: 'POST', json: { workspace: e.name } });
        if (f.sha256 !== e.fileSha) { e.text = f.text; e.fileSha = f.sha256; e.problems = null; }
        e.shownPath = f.shownPath; e.denied = false;
      } catch (err) { e.denied = err.status === 403; e.text = e.fileSha = null; }
      e.fileAt = at;
    }
    if (needsState(e)) {
      const at = stateEpoch, fat = fileEpoch;
      pictureStats.stateReads++;
      try { e.st = await api('workspace-state', { method: 'POST', json: { workspace: e.name } }); } catch (_) { e.st = null; }
      e.stateAt = at; e.stateFileAt = fat; e.wasQuiet = quiet(e.name);
    }
  } finally {
    e.inflight = false;
    reading--;
  }
  for (const v of views) if (v.name === e.name && onScreen(v)) want(v);
  pump();
}

/// Dozable's verdict on a file that doesn't read (the plan route, once per file sha).
export async function pictureProblems(name) {
  const e = entries.get(name);
  if (!e || !e.text) return null;
  if (e.problems && e.problems.sha === e.fileSha) return e.problems;
  const p = { sha: e.fileSha, list: [], count: 0, shownPath: e.shownPath };
  pictureStats.planReads++;
  try {
    const errs = ((await api('workspace-space-plan', { method: 'POST', json: { workspace: name, text: e.text } })).problems || []).filter((x) => x.severity === 'error');
    p.list = errs.slice(0, 2).map((x) => x.message); p.count = errs.length;
  } catch (err) { p.error = err.message || String(err); }
  return (e.problems = p);
}

// ── drawing
const renders = new Set();
let frame = 0, failed = false;
const ORDER = { hero: 0, thumb: 1 };

function keyOf(v, e) {
  const st = e.st;
  const expiring = st && Array.isArray(st.attention) && st.attention.some((a) => a.expiresAt);
  return [e.fileSha, st ? st.sha : '-', v.kind === 'thumb' ? 'thumb' : 'hero', v.w + 'x' + v.h, currentTheme(), expiring ? st.observedAt : ''].join('|');
}
function want(v) {
  if (!onScreen(v)) return;
  const e = entries.get(v.name);
  if (!e || (e.fileAt === 0 && !e.text)) { if (v.painted !== 'reading') { v.painted = 'reading'; v.paint({ reading: true }); } return; }
  if (!e.text) {
    const why = e.denied ? 'Shown to another computer only with serve.chat read' : 'The picture could not be drawn';
    if (v.painted !== why) { v.painted = why; v.key = null; v.paint({ fallback: why }); }
    return;
  }
  if (failed) { if (v.painted !== 'failed') { v.painted = 'failed'; v.paint({ fallback: 'The picture could not be drawn' }); } return; }
  if (v.key === keyOf(v, e)) return;
  renders.add(v);
  if (!frame) frame = requestAnimationFrame(drawNext);
}
function lru(key, value) {
  cache.delete(key); cache.set(key, value);
  if (cache.size > CACHE) cache.delete(cache.keys().next().value);
}
async function drawNext() {
  frame = 0;
  const list = [...renders].filter(onScreen);
  renders.clear();
  if (!list.length) return;
  list.sort((a, b) => ORDER[a.kind] - ORDER[b.kind] || a.el.getBoundingClientRect().top - b.el.getBoundingClientRect().top);
  const [v, ...rest] = list;
  for (const r of rest) renders.add(r);
  let mod;
  try { mod = await loadRenderer(); } catch (_) {
    failed = true;
    for (const x of [v, ...rest]) want(x);
    return;
  }
  const e = entries.get(v.name);
  if (e && e.text && onScreen(v)) {
    const key = keyOf(v, e);
    if (v.key !== key) {
      let got = cache.get(key);
      if (got !== undefined) { pictureStats.hits++; lru(key, got); } else {
        pictureStats.renders++;
        const prefix = (v.kind === 'hero' ? 'dzh-' : 'dzt-') + v.name + '-';
        const opts = { detail: v.kind === 'thumb' ? 'thumb' : 'hero', width: v.w, height: v.h, theme: currentTheme(), idPrefix: prefix };
        const st = e.st || undefined, t0 = performance.now();
        got = v.kind === 'thumb' ? 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(mod.render(e.text, st, opts)) : mod.renderElement(e.text, st, opts);
        pictureStats.ms[v.kind] = pictureStats.ms[v.kind].concat(Math.round(performance.now() - t0)).slice(-20);
        lru(key, got);
      }
      v.key = key;
      v.painted = key;
      if (typeof got === 'string') v.paint({ src: got, key, problem: got.includes('%20problem%22') });
      else v.paint({ svg: got.cloneNode(true), key, problem: got.classList.contains('problem') });
    }
  }
  if (renders.size && !frame) frame = requestAnimationFrame(drawNext);
}
