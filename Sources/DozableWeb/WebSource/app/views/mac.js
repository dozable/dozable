// views/mac — This Mac: the sessions held on this Mac (`doz run @mac`), which NOTHING isolates — they run as you, with
// your files, Keychain and network. The page lists, watches, types into (on a click), ends and restarts them; it never
// opens one (that is the person's command on the Mac). Its own section (`#mac`, beside the grid), so a live refresh never
// tears down the open pane. Every tile and the pane say "No isolation"; a session whose own command line bypasses its
// permissions is marked so. The pane opens in WATCH mode (nothing typed reaches the session); Type into it attaches
// interactively. Another computer gets what `serve.mac_sessions` allows (the server says, in `access`).
import { $, h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { when } from '../core/format.js';
import { tildePath } from '../core/paths.js';
import { MAC } from '../core/places.js';
import { setting, terminalsAllowed } from '../core/settings.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { confirmAction } from '../components/dialog.js';
import { paintStatusChip, statusChip } from '../components/agent-status.js';
import { pictureSource } from '../components/session-thumb.js';
import { bootTerm, closeTerminal, newTerm, paintCover } from '../components/terminal.js';

const mac = { built: false, active: false, tiles: new Map(), sessions: [], access: 'interactive', refused: '', lastList: 0, timer: null,
              body: null, status: null, pane: null, term: null, open: null };

/// The permanent mark of everything here: no sandbox, no proxy, nothing around it.
export function noIsolationChip() {
  return h('span', { class: 'mac-chip', title: 'Runs as you on this Mac: your files, Keychain and network. No sandbox, no proxy.' },
    icon('triangle-alert'), 'No isolation');
}
/// A session whose own command line bypasses its permissions (Dozable never adds that).
export function bypassedChip() {
  return h('span', { class: 'mac-chip mac-bypassed', title: 'Its own command line asked for this — nothing around it' }, 'permissions bypassed');
}
/// The callout every view of these sessions starts with.
export function noIsolationCallout(compact) {
  return callout('warn', { compact, cls: 'mac-callout', title: 'No isolation',
    body: 'Sessions on this Mac run as you: your files, Keychain and network. No sandbox, no proxy. Open one with doz run @mac in a terminal on the Mac.' });
}

function build() {
  const root = $('mac');
  mac.status = h('span', { class: 'grid-status', role: 'status' });
  mac.body = h('div', { class: 'tiles mac-tiles' });
  mac.pane = h('div', { class: 'mac-pane', hidden: true });
  root.replaceChildren(
    h('div', { class: 'head' }, h('h1', null, 'This Mac', noIsolationChip()),
      h('div', { class: 'actions' }, btn('Refresh', () => macRefresh(true), { small: true }))),
    noIsolationCallout(false),
    h('div', { class: 'toolbar' }, mac.status),
    mac.pane, mac.body);
  mac.built = true;
}

export async function macEnter(session) {
  if (!mac.built) build();
  mac.active = true;
  await macRefresh(true);
  clearInterval(mac.timer);
  mac.timer = setInterval(() => macRefresh(false), 5000);
  if (session && mac.sessions.some((s) => s.name === session)) openPane(session, 'watch');
}
export function macLeave() {
  if (!mac.active) return;
  mac.active = false;
  clearInterval(mac.timer);
  for (const t of mac.tiles.values()) t.source.want(null);
  closePane();
}

/// The list (at most every 2 s unless forced; looking never starts a host — the server reads the Mac's socket folder).
export async function macRefresh(force) {
  if (!mac.active) return;
  if (!force && Date.now() - mac.lastList < 2000) return;
  mac.lastList = Date.now();
  try {
    const r = await api('mac/sessions');
    mac.sessions = Array.isArray(r.sessions) ? r.sessions : [];
    mac.access = r.access === 'watch' ? 'watch' : 'interactive';
    mac.refused = '';
  } catch (e) {
    mac.sessions = [];
    mac.refused = e.status === 403 ? 'The sessions on this Mac are not shared with this browser (the Mac’s setting serve.mac_sessions).' : (e.message || String(e));
    if (e.status === 403) hideMacNav();
  }
  if (!mac.active) return;
  render();
}

function render() {
  if (mac.refused) {
    for (const t of mac.tiles.values()) { t.source.drop(); t.el.remove(); }
    mac.tiles.clear();
    mac.body.replaceChildren(h('div', { class: 'empty' }, mac.refused));
    mac.status.textContent = '';
    return;
  }
  const want = mac.sessions.slice().sort((a, b) => (a.state === 'running' ? 0 : 1) - (b.state === 'running' ? 0 : 1) || a.name.localeCompare(b.name));
  const keep = new Set(want.map((s) => s.name));
  for (const [k, t] of mac.tiles) if (!keep.has(k)) { t.source.drop(); t.el.remove(); mac.tiles.delete(k); }
  let prev = null;
  for (const s of want) {
    let t = mac.tiles.get(s.name);
    if (!t) { t = makeTile(s.name); mac.tiles.set(s.name, t); }
    paintTile(t, s);
    const next = prev ? prev.nextSibling : mac.body.firstChild;
    if (next !== t.el) mac.body.insertBefore(t.el, next);
    prev = t.el;
  }
  if (!want.length) mac.body.replaceChildren(h('div', { class: 'empty' }, 'No sessions on this Mac. In a terminal on the Mac: doz run @mac -d --session NAME --workdir DIR -- COMMAND'));
  else for (const n of [...mac.body.children]) if (!n.dataset.key) n.remove();
  const running = want.filter((s) => s.state === 'running').length;
  mac.status.textContent = want.length + ' session' + (want.length === 1 ? '' : 's') + ' · ' + running + ' running'
    + (mac.access === 'watch' ? ' · watch only from this browser' : '');
  if (mac.open && !keep.has(mac.open.session)) closePane();
}

function makeTile(name) {
  const title = h('span', { class: 'tile-title' }, name);
  const agent = statusChip(null);
  const tag = h('span', { class: 'tile-phase tile-tag' });
  const phase = h('span', { class: 'tile-phase' });
  const marks = h('span', { class: 'mac-marks' });
  const canvas = h('canvas', { class: 'tile-paint', 'aria-hidden': 'true' });
  const note = h('div', { class: 'tile-note', hidden: true });
  const hit = h('button', { type: 'button', class: 'tile-hit', title: 'Watch it here (read-only)', 'aria-label': 'Watch ' + name },
    h('span', { class: 'tile-hit-icon' }, icon('eye')));
  const folder = h('div', { class: 'mac-folder' });
  const acts = h('div', { class: 'mac-acts' });
  const el = h('div', { class: 'tile mac-tile', 'data-key': name, 'data-place': MAC, 'data-session': name },
    h('div', { class: 'tile-head' }, h('span', { class: 'tile-glyph' }, icon('monitor')), title, agent, tag, phase, marks),
    h('div', { class: 'tile-body' }, canvas, note, hit), folder, acts);
  const t = { name, el, title, agent, tag, phase, marks, canvas, note, hit, folder, acts };
  t.source = pictureSource(canvas, (st) => paintTag(t, st));
  hit.addEventListener('click', () => openPane(name, 'watch'));
  return t;
}

function paintTile(t, s) {
  t.el.dataset.state = s.state;
  t.phase.textContent = s.state === 'running' ? 'running' : s.state === 'gone' ? 'gone' : 'ended' + (s.exitCode != null ? ' (exit ' + s.exitCode + ')' : '');
  t.phase.title = s.state === 'gone' ? 'Its holder is gone (the Mac restarted, or it was killed) — Restart starts it again' : '';
  t.title.title = s.command || '';
  paintStatusChip(t.agent, s.status);
  t.marks.replaceChildren(noIsolationChip(), ...(s.bypassed ? [bypassedChip()] : []));
  t.folder.textContent = s.workdir ? tildePath(s.workdir) : '';
  t.folder.title = s.workdir || '';
  const can = mac.access === 'interactive';
  t.acts.replaceChildren(
    btn('Watch', () => openPane(s.name, 'watch'), { small: true, quiet: true, icon: 'eye' }),
    ...(can && s.state === 'running' ? [btn('Type into it', () => openPane(s.name, 'interactive'), { small: true, quiet: true, icon: 'terminal' })] : []),
    ...(can ? [btn('Restart…', () => restart(s), { small: true, quiet: true })] : []),
    ...(can && s.state === 'running' ? [btn('End…', () => end(s), { small: true, quiet: true, danger: true })] : []));
  t.hit.hidden = s.state !== 'running';
  t.source.want(!setting('ui.terminals', true) ? null
    : s.state === 'running' ? { kind: 'live', sandbox: MAC, session: s.name }
    : s.state === 'gone' ? { kind: 'saved', sandbox: MAC, session: s.name, savedAt: null } : null);
  if (s.state === 'ended') { t.note.hidden = false; t.note.className = 'tile-note static'; t.note.replaceChildren(h('div', { class: 'tile-note-head' }, 'Ended'), h('div', null, 'Restart starts it again in the same folder.')); }
}
function paintTag(t, st) {
  const k = st ? st.kind : null;
  t.tag.textContent = k === 'live' ? 'live' : k === 'saved' || k === 'last' ? 'last screen' + (st.savedAt ? ' · ' + when(st.savedAt) : '') : '';
  if (t.el.dataset.state === 'ended') return;
  const why = k === 'none' ? (st.reason || 'no picture') : '';
  t.note.hidden = !why;
  if (why) { t.note.className = 'tile-note'; t.note.replaceChildren(h('div', { class: 'tile-note-head' }, 'No picture'), h('div', null, why)); }
}

function end(s) {
  confirmAction('End ' + s.name, 'Its program on this Mac is hung up, then terminated, then killed if it must be. What it is doing now is lost.', s.name,
    { action: 'mac-session-end', session: s.name });
}
function restart(s) {
  confirmAction('Restart ' + s.name, 'Its program stops and starts again in ' + (s.workdir ? tildePath(s.workdir) : 'its folder') + '. Claude continues the folder’s newest conversation when there is one.',
    s.name, { action: 'mac-session-restart', session: s.name });
}

// ── the pane: watch by default, interactive on a click ──────────────────────────
function openPane(session, mode) {
  if (!terminalsAllowed()) return;
  if (mode === 'interactive' && mac.access !== 'interactive') mode = 'watch';
  if (mac.open && mac.open.session === session && mac.open.mode === mode) return;
  closePane();
  const s = mac.sessions.find((x) => x.name === session) || {};
  const t = newTerm(MAC, session, mode);
  t.grid = true;                                   // never a tab of a sandbox page
  if (s.state === 'gone') t.saved = { savedAt: null, reason: 'gone' };
  mac.term = t;
  mac.open = { session, mode };
  const host = h('div', { class: 'mac-pane-host' });
  const switchBtn = mode === 'watch'
    ? (mac.access === 'interactive' && s.state === 'running' ? btn('Type into it', () => openPane(session, 'interactive'), { small: true, primary: true, icon: 'terminal' }) : null)
    : btn('Watch only', () => openPane(session, 'watch'), { small: true, icon: 'eye' });
  mac.pane.replaceChildren(
    h('div', { class: 'mac-pane-head' },
      h('span', { class: 'mac-pane-title' }, icon('monitor'), session),
      noIsolationChip(), ...(s.bypassed ? [bypassedChip()] : []),
      h('span', { class: 'mac-pane-mode' }, mode === 'watch' ? 'watching — what you type does not reach it' : 'typing into it'),
      h('span', { class: 'mac-pane-acts' }, ...(switchBtn ? [switchBtn] : []), btn('Close', closePane, { small: true, quiet: true, iconOnly: true, icon: 'x' }))),
    host);
  mac.pane.hidden = false;
  host.append(t.els.wrap);
  paintCover(t);
  history.replaceState(null, '', location.pathname + '#/mac/' + encodeURIComponent(session));
  bootTerm(t, setting('ui.terminal_font_size', 13));
}
function closePane() {
  if (mac.term) { closeTerminal(mac.term.id); mac.term = null; }
  mac.open = null;
  if (mac.pane) { mac.pane.hidden = true; mac.pane.replaceChildren(); }
}

/// Another computer that may not see the sessions on this Mac does not get the sidebar's entry either (the server is the
/// wall; this only hides what it refuses).
function hideMacNav() { const a = $('nav-mac'); if (a) a.hidden = true; }

// ── All sessions' "This Mac" section ────────────────────────────────────────────
/// A section of tiles that lead to This Mac (nothing when there are none, or this browser may not see them).
export async function macSection() {
  let r;
  try { r = await api('mac/sessions'); } catch (e) { if (e.status === 403) hideMacNav(); return null; }
  const sessions = Array.isArray(r.sessions) ? r.sessions : [];
  if (!sessions.length) return null;
  const running = sessions.filter((s) => s.state === 'running').length;
  return h('section', { class: 'mac-section', 'data-mac-section': '' },
    h('h2', null, icon('monitor'), 'This Mac', noIsolationChip()),
    h('p', { class: 'sub' }, running + ' of ' + sessions.length + ' session' + (sessions.length === 1 ? '' : 's') + ' running — they run as you, with nothing around them. ',
      h('a', { href: '#/mac' }, 'Open This Mac')),
    h('ul', { class: 'mac-list' }, ...sessions.map((s) => h('li', null,
      h('a', { href: '#/mac/' + encodeURIComponent(s.name) }, s.name), ' ', h('span', { class: 'mac-list-state' }, s.state),
      ...(s.bypassed ? [' ', bypassedChip()] : [])))));
}
