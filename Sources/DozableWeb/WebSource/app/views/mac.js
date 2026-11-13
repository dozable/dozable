// views/mac — This Mac: the sessions held on this Mac (`doz run @mac`), which NOTHING isolates — they run as you, with
// your files, Keychain and network. The page lists, watches, types into (on a click), ends and restarts them; it never
// opens one (that is the person's command on the Mac). Its own section (`#mac`, beside the grid), so a live refresh never
// tears down the open pane. Every tile and the pane say "No isolation"; a session whose own command line bypasses its
// permissions is marked so. The pane opens in WATCH mode (nothing typed reaches the session); its two-state toggle
// (Watching | Controlling — the tile's Control) attaches interactively. Another computer gets what `serve.mac_sessions` allows (the server says, in `access`).
// 683 M5: a FENCED session (doz run @mac --fenced) is held to its folder and Dozable's proxy — its tile carries the
// server's chips (Fenced / Fenced (Xcode) / Guard rail / Keychain open / Shared config / GitHub: push, then "+N") instead of
// No isolation, and the marks that are news (stopped for git, network waiting, refusals). The pane has four tabs: the
// screen, "What it can do" (the host's capability rows; the bridges switched live), Network (read-only permissions + the
// log) and Conversations (archived transcripts, exported by a typed download). New session on this Mac… is the wizard.
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
import { actOrThrow } from '../core/operations.js';
import { bytes } from '../core/format.js';
import { dialog } from '../components/dialog.js';
import { panel, table } from '../components/blocks.js';
import { capChips, capabilitiesPanel, fenceMarks } from './mac-capabilities.js';
import { openMacWizard } from './mac-wizard.js';
import { networkPanel } from './sandbox-network.js';

const mac = { built: false, active: false, tiles: new Map(), sessions: [], access: 'interactive', plan: false, refused: '', lastList: 0, timer: null,
              body: null, status: null, pane: null, term: null, open: null, tab: 'screen', tabBody: null, tabs: null, head: null, newBtn: null, bridgeErr: '' };

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
  return callout('warn', { compact, cls: 'mac-callout', title: 'Not sandboxes',
    body: 'Sessions on this Mac run as you. A fenced one — the default for a new doz run @mac — is held to its folder and Dozable’s proxy, your Keychain closed; each tile says which, and “What it can do” says exactly. An unfenced one (doz run @mac --unfenced) has no isolation: your files, Keychain and network.' });
}

function build() {
  const root = $('mac');
  mac.status = h('span', { class: 'grid-status', role: 'status' });
  mac.body = h('div', { class: 'tiles mac-tiles' });
  mac.pane = h('div', { class: 'mac-pane', hidden: true });
  mac.newBtn = btn('New session on this Mac…', () => openMacWizard({ workdir: lastFolder() }), { small: true, primary: true, icon: 'plus' });
  mac.newBtn.hidden = true;
  root.replaceChildren(
    h('div', { class: 'head' }, h('h1', null, 'This Mac'),
      h('div', { class: 'actions' }, mac.newBtn, btn('Refresh', () => macRefresh(true), { small: true, icon: 'refresh-cw' }))),
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
    paintMacNavTag(mac.sessions);
    mac.access = r.access === 'watch' ? 'watch' : 'interactive';
    mac.plan = r.plan === true;
    mac.refused = '';
  } catch (e) {
    mac.sessions = [];
    mac.refused = e.status === 403 ? 'The sessions on this Mac are not shared with this browser (the Mac’s setting serve.mac_sessions).' : (e.message || String(e));
    if (e.status === 403) hideMacNav();
  }
  if (!mac.active) return;
  render();
}

/// The wizard's starting folder: the newest session's — never a temporary folder (/tmp, /var/folders and their /private
/// spellings: a session started from one is no project to offer again); then it starts empty.
export function isTemporaryFolder(p) {
  return /^(\/private)?\/(tmp|var\/folders)(\/|$)/.test(String(p || ''));
}
function lastFolder() {
  const s = mac.sessions.filter((x) => x.workdir).sort((a, b) => String(b.openedAt || '').localeCompare(String(a.openedAt || '')))[0];
  return s && !isTemporaryFolder(s.workdir) ? s.workdir : '';
}

function render() {
  if (mac.newBtn) mac.newBtn.hidden = !mac.plan;
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
  if (!want.length) mac.body.replaceChildren(h('div', { class: 'empty' }, 'No sessions on this Mac. In a terminal on the Mac: doz run @mac -d --session NAME --workdir DIR -- COMMAND (fenced; --unfenced for none)'
    + (mac.plan ? ' — or New session on this Mac… for the command.' : '')));
  else for (const n of [...mac.body.children]) if (!n.dataset.key) n.remove();
  const running = want.filter((s) => s.state === 'running');
  const fenced = running.filter((s) => s.fenced).length;
  mac.status.textContent = want.length + ' session' + (want.length === 1 ? '' : 's') + ' · ' + running.length + ' running'
    + (running.length ? ' (' + fenced + ' fenced, ' + (running.length - fenced) + ' no isolation)' : '')
    + (mac.access === 'watch' ? ' · watch only from this browser' : '');
  if (mac.open && !keep.has(mac.open.session)) closePane();
  else if (mac.open) paintPaneHead();
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
  t.marks.replaceChildren(capChips(s, () => openPane(s.name, 'watch', 'can')), ...fenceMarks(s, (tab) => openPane(s.name, 'watch', tab)),
    ...(s.bypassed ? [bypassedChip()] : []));
  t.el.dataset.fenced = s.fenced ? 'true' : 'false';
  t.folder.textContent = s.workdir ? tildePath(s.workdir) : '';
  t.folder.title = s.workdir || '';
  const can = mac.access === 'interactive';
  t.acts.replaceChildren(
    btn('Watch', () => openPane(s.name, 'watch'), { small: true, quiet: true, icon: 'eye' }),
    ...(can && s.state === 'running' ? [btn('Control', () => openPane(s.name, 'interactive'), { small: true, quiet: true, icon: 'terminal', title: 'Attach: what you type reaches it' })] : []),
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
function openPane(session, mode, tab) {
  if (!terminalsAllowed()) return;
  if (mode === 'interactive' && mac.access !== 'interactive') mode = 'watch';
  if (mac.open && mac.open.session === session && mac.open.mode === mode) { if (tab) showTab(tab); return; }
  closePane();
  mac.tab = tab || 'screen';
  const s = mac.sessions.find((x) => x.name === session) || {};
  const t = newTerm(MAC, session, mode);
  t.grid = true;                                   // never a tab of a sandbox page
  if (s.state === 'gone') t.saved = { savedAt: null, reason: 'gone' };
  mac.term = t;
  mac.open = { session, mode };
  const host = h('div', { class: 'mac-pane-host' });
  mac.head = h('div', { class: 'mac-pane-head' });
  mac.tabs = h('div', { class: 'segmented mac-tabs', role: 'tablist', 'aria-label': 'Session' });
  mac.tabBody = h('div', { class: 'mac-tab-body' });
  mac.stop = h('div', { class: 'mac-stop' });
  mac.pane.replaceChildren(mac.head, mac.stop, h('div', { class: 'mac-tabs-row' }, mac.tabs), host, mac.tabBody);
  mac.host = host;
  paintPaneHead();
  mac.pane.hidden = false;
  host.append(t.els.wrap);
  showTab(mac.tab);
  paintCover(t);
  history.replaceState(null, '', location.pathname + '#/mac/' + encodeURIComponent(session));
  bootTerm(t, setting('ui.terminal_font_size', 13));
}
function current() { return mac.open ? mac.sessions.find((x) => x.name === mac.open.session) || null : null; }

/// The pane's head, tabs and stop notice — painted again at each list (the terminal is never rebuilt).
function paintPaneHead() {
  const s = current();
  if (!s || !mac.head) return;
  const mode = mac.open.mode, session = s.name;
  mac.head.replaceChildren(
    h('span', { class: 'mac-pane-title' }, icon('monitor'), session),
    capChips(s, () => showTab('can')), ...fenceMarks(s, (tab) => showTab(tab)), ...(s.bypassed ? [bypassedChip()] : []),
    modeToggle(s, mode),
    ...(mode === 'watch' ? [h('span', { class: 'mac-pane-mode' }, 'what you type does not reach it')] : []),
    h('span', { class: 'mac-pane-acts' }, btn('Close', closePane, { small: true, quiet: true, iconOnly: true, icon: 'x' })));
  mac.pane.classList.toggle('is-fenced', !!s.fenced);
  // Stopped for a git config change: Review (what was taken out) and Resume (the host refuses while it is there again).
  const f = s.fence;
  mac.stop.replaceChildren(...(f && f.stoppedForGit ? [callout('bad', { compact: true, cls: 'mac-stopped', attrs: { 'data-stopped': '' }, title: 'Stopped: git config',
    body: 'It changed a git config in a way a fenced session may not (' + f.stoppedForGit + '). The change was taken out and kept aside; every process of its fence is paused until you resume it.',
    actions: [btn('Review…', () => review(s), { small: true, icon: 'list-checks' }),
      mac.access === 'interactive' ? btn('Resume', () => resume(s), { small: true, primary: true, icon: 'play' }) : null] })] : []));
  const tabs = [['screen', 'Screen', 'monitor'], ['can', 'What it can do', 'shield'], ...(s.fenced ? [['network', 'Network', 'activity'], ['conversations', 'Conversations', 'history']] : [])];
  if (!tabs.some(([id]) => id === mac.tab)) mac.tab = 'screen';
  mac.tabs.replaceChildren(...tabs.map(([id, label, ic]) => h('button', { type: 'button', class: 'seg' + (id === mac.tab ? ' active' : ''), role: 'tab', 'data-mac-tab': id,
    'aria-selected': id === mac.tab ? 'true' : 'false', on: { click: () => showTab(id) } }, icon(ic), label)));
  if (mac.tab === 'can') paintTab();
}

/// The pane's two-state toggle: Watching (nothing typed reaches it) | Controlling (attached for real). Controlling is
/// offered only to a browser that may type (`access` interactive) and only while the session runs; otherwise it is
/// disabled with the reason in its title.
function modeToggle(s, mode) {
  const why = mac.access !== 'interactive' ? 'This browser may only watch (the Mac’s setting serve.mac_sessions)'
    : s.state !== 'running' ? 'It is not running' : '';
  const seg = (id, label, ic, disabled, title) => h('button', { type: 'button', class: 'seg' + (mode === id ? ' active' : ''),
    'aria-pressed': mode === id ? 'true' : 'false', 'data-mac-mode': id, disabled: disabled || null, title: title || null,
    on: { click: () => { if (mode !== id) openPane(s.name, id, mac.tab); } } }, icon(ic), label);
  return h('span', { class: 'segmented mac-mode-toggle', role: 'group', 'aria-label': 'Watching or controlling' },
    seg('watch', 'Watching', 'eye', false, 'Read-only: nothing you type reaches it'),
    seg('interactive', 'Controlling', 'terminal', !!why && mode !== 'interactive', why || 'Attached: what you type reaches the program'));
}

function showTab(tab) {
  mac.tab = tab;
  for (const b of mac.tabs ? mac.tabs.children : []) { const on = b.dataset.macTab === tab; b.classList.toggle('active', on); b.setAttribute('aria-selected', on ? 'true' : 'false'); }
  if (mac.host) mac.host.hidden = tab !== 'screen';
  paintTab();
}

async function paintTab() {
  const s = current();
  if (!s || !mac.tabBody) return;
  const tab = mac.tab;
  mac.tabBody.hidden = tab === 'screen';
  if (tab === 'screen') { mac.tabBody.replaceChildren(); return; }
  if (tab === 'can') {
    mac.tabBody.replaceChildren(
      mac.bridgeErr ? callout('bad', { compact: true, body: mac.bridgeErr, dismiss: () => { mac.bridgeErr = ''; paintTab(); } }) : '',
      capabilitiesPanel(s, { canEdit: mac.access === 'interactive' && s.state === 'running', onBridge: (field, v) => bridge(s, field, v), onNetwork: () => showTab('network') }));
    return;
  }
  if (tab === 'network') {
    try {
      const r = await api('mac/sessions/' + encodeURIComponent(s.name) + '/network');
      if (mac.tab !== 'network' || current()?.name !== s.name) return;
      const denials = r.denials.slice().reverse().map((x) => h('tr', null, h('td', null, when(x.time)), h('td', { class: 'mono' }, x.process), h('td', null, x.operation), h('td', { class: 'mono' }, x.target)));
      mac.tabBody.replaceChildren(networkPanel(r.network, { commands: r.commands }),
        h('h2', null, 'What its fence refused'),
        h('div', { class: 'toolbar' }, r.denialLog === 'on' ? r.denials.length + ' seen (macOS folds repeats of one)' : r.denialLog === 'unavailable' ? 'This account may not read the system log — the refusals are not shown (nothing else is affected).' : 'Shown while a host runs.'),
        panel(table(['When', 'Program', 'What', 'Refused'], denials), 'No refusals seen.'));
    } catch (e) { mac.tabBody.replaceChildren(callout('bad', { compact: true, body: e.message || String(e) })); }
    return;
  }
  if (tab === 'conversations') {
    try {
      const r = await api('mac/sessions/' + encodeURIComponent(s.name) + '/transcripts');
      if (mac.tab !== 'conversations') return;
      const base = '/api/v1/mac/sessions/' + encodeURIComponent(s.name) + '/transcripts/';
      const rows = r.items.map((x) => h('tr', { 'data-transcript': x.name }, h('td', null, stamp(x.endedAt)), h('td', { class: 'mono' }, x.name), h('td', { class: 'num' }, bytes(x.bytes)),
        h('td', null, mac.access === 'interactive' ? h('a', { class: 'btn sm quiet', href: base + encodeURIComponent(x.endedAt) + '/' + encodeURIComponent(x.name), download: x.endedAt + '-' + x.name }, icon('download'), 'Export') : '')));
      mac.tabBody.replaceChildren(
        h('p', { class: 'sub' }, 'Conversations of this fenced session, kept in Dozable’s archive when it ended (history: keep)'
          + (r.carriedTo ? ' — and copied into ' + tildePath(r.carriedTo) + ', where a later claude --resume finds them' : '') + '. Transcripts only: never its memory or settings.'),
        panel(table(['Ended', 'Conversation', 'Size', ''], rows, [2]), 'None kept yet — they are archived when the session ends.'));
    } catch (e) { mac.tabBody.replaceChildren(callout(e.status === 404 ? 'info' : 'bad', { compact: true, body: e.message || String(e) })); }
  }
}
/// An archive stamp (`20261113T101500Z`) as a time.
function stamp(st) {
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(st || '');
  return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6])).toLocaleString() : st;
}

async function bridge(s, field, value) {
  try { mac.bridgeErr = ''; await actOrThrow({ action: 'mac-session-bridges', session: s.name, [field]: value }); setTimeout(() => macRefresh(true), 600); }
  catch (e) { mac.bridgeErr = e.message || String(e); paintTab(); }
}
async function review(s) {
  let items = [];
  try { items = (await api('mac/sessions/' + encodeURIComponent(s.name) + '/quarantine')).items; } catch (e) { items = [{ name: 'error', text: e.message || String(e) }]; }
  const list = h('div', { class: 'mac-quarantine' }, items.length ? items.map((x) => h('div', null, h('div', { class: 'muted' }, x.name), h('pre', { class: 'mac-q-text' }, x.text)))
    : h('div', { class: 'empty' }, 'Nothing kept aside.'));
  dialog('What was taken out of ' + s.name, 'The git guard took these out of the session’s git config and kept them here. Resume continues the session without them.',
    [{ name: 'q', type: 'custom', el: list, get: () => null }], mac.access === 'interactive' ? 'Resume' : 'Close',
    async () => { if (mac.access === 'interactive') await resume(s); }, { icon: mac.access === 'interactive' ? 'play' : 'x' });
}
async function resume(s) {
  try { await actOrThrow({ action: 'mac-session-resume', session: s.name }); setTimeout(() => macRefresh(true), 600); }
  catch (e) { mac.bridgeErr = e.message || String(e); showTab('can'); }
}

function closePane() {
  if (mac.term) { closeTerminal(mac.term.id); mac.term = null; }
  mac.open = null;
  if (mac.pane) { mac.pane.hidden = true; mac.pane.replaceChildren(); }
}

/// Another computer that may not see the sessions on this Mac does not get the sidebar's entry either (the server is the
/// wall; this only hides what it refuses).
function hideMacNav() { const a = $('nav-mac'); if (a) a.hidden = true; }

/// The sidebar's tag on This Mac says what is TRUE now: how many running sessions have no isolation (none: no tag — a new
/// session is fenced by default, and each tile says which it is). Painted wherever the list is read.
function paintMacNavTag(sessions) {
  const tag = document.querySelector('#nav-mac .nav-mac-tag');
  if (!tag) return;
  const open = sessions.filter((s) => s.state === 'running' && !s.fenced).length;
  tag.hidden = !open;
  tag.textContent = open ? open + ' no isolation' : '';
  tag.title = open ? open + (open === 1 ? ' session on this Mac runs' : ' sessions on this Mac run') + ' as you — no isolation' : '';
}

// ── All sessions' "This Mac" section ────────────────────────────────────────────
/// A section of tiles that lead to This Mac (nothing when there are none, or this browser may not see them).
export async function macSection() {
  let r;
  try { r = await api('mac/sessions'); } catch (e) { if (e.status === 403) hideMacNav(); return null; }
  const sessions = Array.isArray(r.sessions) ? r.sessions : [];
  paintMacNavTag(sessions);
  if (!sessions.length) return null;
  const running = sessions.filter((s) => s.state === 'running').length;
  const open = sessions.filter((s) => s.state === 'running' && !s.fenced).length;
  return h('section', { class: 'mac-section', 'data-mac-section': '' },
    h('h2', null, icon('monitor'), 'This Mac', open ? noIsolationChip() : null),
    h('p', { class: 'sub' }, running + ' of ' + sessions.length + ' session' + (sessions.length === 1 ? '' : 's') + ' running — '
      + (open ? open + ' with no isolation (they run as you, with nothing around them). ' : 'each held by its fence. '),
      h('a', { href: '#/mac' }, 'Open This Mac')),
    h('ul', { class: 'mac-list' }, ...sessions.map((s) => h('li', null,
      h('a', { href: '#/mac/' + encodeURIComponent(s.name) }, s.name), ' ', h('span', { class: 'mac-list-state' }, s.state + (s.fenced ? ' · fenced' : '')),
      ...(s.bypassed ? [' ', bypassedChip()] : [])))));
}
