// views/sessions — All sessions: the grid (593).
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon, PHASE_GLYPH, phaseMark } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-d08918bd09e973a0.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { SAVED_PHASES, VERBS } from '../core/sandboxes-bbbfdf9cf3b69d40.js';
import { saveSetting, setting } from '../core/settings-3a7090f6674fcf5d.js';
import { state } from '../core/state-70a2676e16bde561.js';
import { btn } from '../components/button-8109d54546d946d3.js';
import { lifecycle } from '../components/lifecycle-7a6e83f5d61654a0.js';
import { renderNavSandboxes, sessionGlyph } from '../components/nav-95d9af3cc1f4df6b.js';
import { hidePeek, hoverPeek } from '../components/nav-peek-2724010a65b554d0.js';
import { agentChip } from '../components/agent-status-29792e2f0cc1a9c4.js';
import { pageFailure } from '../components/notices-b8a38e4f2acdece8.js';
import { pictureSource } from '../components/session-thumb-a5dcd102d35e1168.js';

// ── All sessions: the grid (593) ────────────────────────────────────────────
// A tile per session of every RUNNING sandbox, and the saved screens of every sleeping one. 648: each tile is PAINTED
// on a canvas from its screen's grid (components/session-thumb.js) — every running one live from the host's feed, which
// asks only for the tiles on screen; no terminal engine, frame or socket, so no live cap and nothing to take turns. A
// sandbox that is not running and kept no screens is one static tile (an open grid never keeps a host alive for it).
// Sessions are listed on entry, on Refresh, and on a live change at most every 10 s (listing asks the guest).
const grid = { built: false, active: false, tiles: new Map(), sandbox: '', phase: '', lastList: 0, listTimer: null,
               sessions: {}, scheduled: false, status: null, body: null };
const TILE_SCALE = { small: 0.3, medium: 0.42, large: 0.62 };
/// 642 (owner: "add a toggle for the larger picture"): resting on a tile shows it larger — on unless turned off here.
function peekOn() { try { return localStorage.getItem('doz.sessions.peek') !== 'off'; } catch (_) { return true; } }
function peekToggle() {
  const box = h('input', { type: 'checkbox', 'data-sessions-peek': '', on: { change: (ev) => {
    try { localStorage.setItem('doz.sessions.peek', ev.target.checked ? 'on' : 'off'); } catch (_) { /* this page only */ }
    if (!ev.target.checked) hidePeek();
  } } });
  box.checked = peekOn();
  return h('label', { class: 'ov-toggle', title: 'Resting on a tile’s picture for half a second shows it larger' }, box, 'Larger on hover');
}

function gridBuild() {
  const root = $('grid');
  const sandboxSel = h('select', { 'aria-label': 'Sandbox' });
  const phaseSel = h('select', { 'aria-label': 'Phase' }, [['', 'every phase'], ['running', 'running'], ['paused', 'paused'], ['asleep', 'asleep'],
    ['hibernated', 'hibernated'], ['off', 'shut down'], ['failed', 'failed']].map(([v, l]) => h('option', { value: v }, l)));
  const sizeSel = h('select', { 'aria-label': 'Tile size' }, ['small', 'medium', 'large'].map((s) => h('option', { value: s }, s + ' tiles')));
  sandboxSel.addEventListener('change', () => { grid.sandbox = sandboxSel.value; gridRender(); });
  phaseSel.addEventListener('change', () => { grid.phase = phaseSel.value; gridRender(); });
  sizeSel.addEventListener('change', () => {
    gridApplySize(sizeSel.value);
    saveSetting('ui.grid_tile_size', sizeSel.value).catch((e) => pageFailure('ui.grid_tile_size was not saved: ' + (e.message || e)));
  });
  grid.status = h('span', { class: 'grid-status', role: 'status' });
  grid.body = h('div', { class: 'tiles' });
  grid.sandboxSel = sandboxSel;
  grid.sizeSel = sizeSel;
  root.replaceChildren(
    h('div', { class: 'head' }, h('h1', null, 'All sessions'), h('div', { class: 'actions' }, btn('Refresh', () => gridRefresh(true), { small: true }))),
    h('p', { class: 'sub' }, 'Every session of every running sandbox, live and read-only. Click one to open it on its sandbox’s page.'),
    h('div', { class: 'toolbar' }, sandboxSel, phaseSel, sizeSel, peekToggle(), grid.status),
    grid.body);
  grid.built = true;
}
function gridApplySize(size) {
  const s = TILE_SCALE[size] ? size : 'medium';
  for (const k of Object.keys(TILE_SCALE)) $('grid').classList.toggle('tiles-' + k, k === s);
  if (grid.sizeSel) grid.sizeSel.value = s;
}
export async function gridEnter() {
  if (!grid.built) gridBuild();
  grid.active = true;
  gridApplySize(setting('ui.grid_tile_size', 'medium'));
  await gridRefresh(true);
}
export function gridLeave() {
  if (!grid.active) return;
  grid.active = false;
  clearTimeout(grid.listTimer);
  for (const tile of grid.tiles.values()) tile.source.want(null);
}
export async function gridRefresh(force) {
  if (!grid.active) return;
  const wait = 10000 - (Date.now() - grid.lastList);
  if (!force && wait > 0) {
    clearTimeout(grid.listTimer);
    grid.listTimer = setTimeout(() => gridRefresh(true), wait);
    return;
  }
  grid.lastList = Date.now();
  let o;
  try { o = await api('overview'); } catch (e) { pageFailure(e.message || String(e), { key: 'grid' }); return; }
  state.overview = o;
  renderNavSandboxes();
  // A running sandbox's sessions come from its guest; any other's from its saved screens (593 §9 — S3:
  // read from the sandbox's directory, nothing woken).
  await Promise.all(o.sandboxes.filter((s) => s.phase !== 'booting').map(async (s) => {
    try {
      const rows = await api('sandboxes/' + s.name + '/sessions');
      grid.sessions[s.name] = s.phase === 'running'
        ? rows.filter((r) => !r.ended && !r.saved).map((r) => ({ name: r.name, command: r.command }))
        : rows.filter((r) => r.saved).map((r) => ({ name: r.name, command: r.command, saved: r }));
    } catch (_) { /* it changed meanwhile: its last list stays */ }
  }));
  if (!grid.active) return;
  gridRender();
}
/// The tiles the filters ask for, made to match the DOM (a kept tile keeps its picture).
function gridRender() {
  const o = state.overview;
  if (!o) return;
  const names = o.sandboxes.map((s) => s.name).sort();
  grid.sandboxSel.replaceChildren(h('option', { value: '' }, 'every sandbox'), ...names.map((n) => h('option', { value: n }, n)));
  grid.sandboxSel.value = names.includes(grid.sandbox) ? grid.sandbox : '';
  const want = [];
  for (const s of o.sandboxes.slice().sort((a, b) => a.name.localeCompare(b.name))) {
    if (grid.sandbox && s.name !== grid.sandbox) continue;
    if (grid.phase && s.phase !== grid.phase) continue;
    if (s.phase === 'running') {
      // 635: the agent's session first in each sandbox (the host's registry says which is its own).
      const own = ((s.sessionList || []).find((b) => b.isDefault) || {}).name;
      const live = (grid.sessions[s.name] || []).filter((x) => !x.saved).sort((a, b) => (b.name === own) - (a.name === own));
      for (const x of live) want.push({ key: s.name + '/' + x.name, sandbox: s.name, session: x.name, command: x.command, s });
      if (!live.length) want.push({ key: s.name + '/', sandbox: s.name, session: null, s, none: true });
    } else {
      // 593 §9 (S3): its saved screens, a tile each (same key as the live tile: waking swaps it in place).
      // Shut down or failed: no tiles of sessions (owner, 2026-09-30) — one static tile with Start.
      const saved = !SAVED_PHASES.includes(s.phase) ? [] : (grid.sessions[s.name] || []).filter((x) => x.saved);
      for (const x of saved) want.push({ key: s.name + '/' + x.name, sandbox: s.name, session: x.name, command: x.command, s, saved: x.saved });
      if (!saved.length) want.push({ key: s.name + '/', sandbox: s.name, session: null, s });
    }
  }
  const keep = new Set(want.map((w) => w.key));
  for (const [k, tile] of grid.tiles) if (!keep.has(k)) { tile.source.drop(); tile.el.remove(); grid.tiles.delete(k); }
  let prev = null;
  for (const w of want) {
    let tile = grid.tiles.get(w.key);
    if (!tile) { tile = makeTile(w); grid.tiles.set(w.key, tile); }
    paintTile(tile, w);
    const next = prev ? prev.nextSibling : grid.body.firstChild;
    if (next !== tile.el) grid.body.insertBefore(tile.el, next);
    prev = tile.el;
  }
  if (!want.length) grid.body.replaceChildren(h('div', { class: 'empty' }, o.sandboxes.length ? 'Nothing matches the filters.' : 'No sandboxes yet.'));
  else for (const n of [...grid.body.children]) if (!n.dataset.key) n.remove();
  gridSchedule();
}
/// The host's word on a tile's session (its program's mark), from the overview.
function briefOf(w) { return ((w.s && w.s.sessionList) || []).find((b) => b.name === w.session) || null; }
function makeTile(w) {
  const dot = h('span', { class: 'ph-dot', 'aria-hidden': 'true' });
  const title = h('span', { class: 'tile-title' });
  const phase = h('span', { class: 'tile-phase' });
  const act = h('span', { class: 'tile-act' });
  const agent = w.session ? agentChip(w.sandbox, w.session) : h('span');   // 612: what its agent is doing
  const tag = h('span', { class: 'tile-phase tile-tag' });                   // 642/648: live · its last screen
  const canvas = h('canvas', { class: 'tile-paint', 'aria-hidden': 'true' });
  const note = h('div', { class: 'tile-note', hidden: true });
  const hit = h('button', { type: 'button', class: 'tile-hit', title: 'Open on its sandbox’s page',
                            'aria-label': 'Open ' + (w.session ? w.sandbox + ' · ' + w.session : w.sandbox) + ' on its page' },
    h('span', { class: 'tile-hit-icon' }, icon('maximize-2')));
  const glyph = w.session ? sessionGlyph(briefOf(w)) : null;                  // 642: its agent's mark, else a terminal
  const body = h('div', { class: 'tile-body' }, canvas, note, hit);
  const el = h('div', { class: 'tile', 'data-key': w.key, 'data-sandbox': w.sandbox, 'data-session': w.session || '' },
    h('div', { class: 'tile-head' }, dot, glyph, title, agent, tag, phase, act), body);
  const tile = { key: w.key, sandbox: w.sandbox, session: w.session, el, dot, glyph, title, tag, phase, act, canvas, note, hit, kind: null, saved: null };
  tile.source = pictureSource(canvas, (st) => paintTag(tile, st));
  hit.addEventListener('click', () => { location.hash = '#/sandbox/' + w.sandbox + (tile.session ? '/' + tile.session : ''); });
  // 642 (owner: "add the larger hover picture there too"): resting on a session's picture shows it larger, as on All sandboxes.
  if (w.session) hoverPeek(body, w.sandbox, () => ({ name: tile.session, saved: !!tile.saved,
    savedAt: tile.saved ? tile.saved.savedAt : null, savedReason: tile.saved ? tile.saved.savedReason : null }), peekOn);
  return tile;
}
function paintTile(tile, w) {
  const s = w.s;
  // A tile is live (painted from the feed), saved (the session's saved screen) or static (no session).
  const kind = !w.session ? 'static' : w.saved ? 'saved' : 'live';
  tile.kind = kind;
  tile.saved = w.saved || null;
  tile.el.dataset.kind = kind;
  tile.el.dataset.phase = s.phase;
  tile.dot.className = 'ph-dot ph-' + s.phase + phaseMark(s.phase);
  if (tile.glyph) { const g = sessionGlyph(briefOf(w)); if (g.dataset.mark !== tile.glyph.dataset.mark) { tile.glyph.replaceWith(g); tile.glyph = g; } }
  tile.title.textContent = w.session ? w.sandbox + ' · ' + w.session : w.sandbox;
  tile.title.title = w.command ? w.command : '';
  tile.phase.textContent = w.saved ? s.phaseLabel + ' · saved ' + when(w.saved.savedAt) : s.phaseLabel;
  const verb = { paused: 'resume', asleep: 'wake', hibernated: 'wake', off: 'start', failed: 'start' }[s.phase];
  tile.act.replaceChildren(verb && (!w.session || w.saved) && !s.busy ? btn(VERBS[verb][0], () => lifecycle(verb, w.sandbox), { small: true }) : '');
  tile.canvas.hidden = !w.session;
  if (!w.session) {
    const known = grid.sessions[w.sandbox] || [];
    tile.note.hidden = false;
    tile.note.className = 'tile-note static';
    tile.note.replaceChildren(
      ...(!w.none && PHASE_GLYPH[s.phase] ? [h('div', { class: 'tc-glyph' }, icon(PHASE_GLYPH[s.phase]))] : []),   // (no null: replaceChildren writes it as text)
      h('div', { class: 'tile-note-head' }, w.none ? 'No sessions running' : s.phaseLabel),
      h('div', null, w.none ? 'Open one from its page.' : s.phase === 'off' ? 'Starting boots it fresh — new sessions.'
        : known.length ? 'Sessions when it last ran: ' + known.map((x) => x.name).join(', ') : 'Its sessions are listed while it runs.'));
  }
}
/// Place every tile's picture (its source); the feed itself asks only for the tiles on screen.
export function gridSchedule() {
  if (grid.scheduled) return;
  grid.scheduled = true;
  setTimeout(() => { grid.scheduled = false; gridPlace(); }, 30);
}
function gridPlace() {
  if (!grid.active) return;
  const on = setting('ui.terminals', true);
  let live = 0, total = 0;
  for (const el of grid.body.children) {
    const t = grid.tiles.get(el.dataset.key);
    if (!t) continue;
    const running = t.kind === 'live' && t.el.dataset.phase === 'running';
    if (t.session) total++;
    t.source.want(!on || !t.session ? null
      : t.kind === 'saved' ? { kind: 'saved', sandbox: t.sandbox, session: t.session, savedAt: t.saved ? t.saved.savedAt : null }
      : running ? { kind: 'live', sandbox: t.sandbox, session: t.session } : null);
    if (t.source.spec && t.source.spec.kind === 'live') live++;
  }
  grid.status.textContent = total + ' session' + (total === 1 ? '' : 's') + ' · ' + live + ' live';
  $('grid').dataset.live = String(live);
}
/// What the tile shows now: live, its saved screen, its last screen (the host could not give the live one), or why not.
function paintTag(tile, st) {
  const k = st ? st.kind : null;
  tile.tag.textContent = k === 'live' ? 'live' : k === 'last' ? 'last screen' : '';
  tile.el.dataset.term = k === 'live' || k === 'saved' || k === 'last' ? k : 'none';
  if (!tile.session) return;
  const why = k === 'none' ? (st.reason || 'no picture') : '';
  tile.note.hidden = !why;
  if (why) { tile.note.className = 'tile-note'; tile.note.replaceChildren(h('div', { class: 'tile-note-head' }, 'No picture'), h('div', null, why)); }
}
