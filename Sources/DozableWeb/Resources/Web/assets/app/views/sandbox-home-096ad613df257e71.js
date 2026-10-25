// views/sandbox-home — A sandbox page's Home (635): its first tab — every session (the agent's as a card, the others as
// rows, each with a picture of its screen), its logs and its folder. Closing a tool's tab lands here.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon, ICON_OPEN_IN_TERMINAL, phaseMark } from '../dom/icons-0a9984f90615977d.js';
import { agentTitle } from '../core/agents-b5713528d20be964.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { transitionOf, TRANSITION_LABEL } from '../core/operations-773ff6e3f3377064.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { opRunningFor, SAVED_PHASES } from '../core/sandboxes-a8ce08093e702ad4.js';
import { isRemote } from '../core/session-bd22eba33578b6ab.js';
import { saveSetting, setting } from '../core/settings-0b4a6cca79ee581c.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { homePane, pageTerminals, sview } from '../core/terminals-e2028f16ee8fa887.js';
import { agentChip, agentStatusOf } from '../components/agent-status-427018a8ec783336.js';
import { btn } from '../components/button-f435595b4098d043.js';
import { callout } from '../components/callout-045a1af4db6ce704.js';
import { lifecycle, sessionsWhyNot } from '../components/lifecycle-9fa26d46167a3033.js';
import { moreMenu } from '../components/menus-23bc819d6d81d035.js';
import { failureFor } from '../components/notices-b9b2a3550693d815.js';
import { endSessionDialog, restartSessionDialog, sessionMenuItems } from '../components/session-actions-cff18777b25e6b57.js';
import { thumbFrame } from '../components/session-thumb-76e1bff2986027cf.js';
import { bootLogDialog, focusTerm, openConsoleTerminal, openDefaultTerminal, openTerminal } from '../components/terminal-1539c4919cc0399c.js';
import { openInTerminal, runDetachedDialog } from './sandbox-dialogs-7592631e73566cb8.js';
import { openSavedTerminal } from './sandbox-layout-e9c42a8ee819517e.js';
import { newShellTerminal, openBuildLog, renderTerminals } from './sandbox-terminals-bf5d4427f925ab69.js';

/// Each sandbox's Home: its document and the parts that hold a picture (built once and painted in place), keyed by
/// session.
const HOMES = new Map();

function homeOf(name) {
  let home = HOMES.get(name);
  if (home) return home;
  const head = h('div', { class: 'head has-title' });
  const lead = h('p', { class: 'home-lead' });
  const cardBox = h('div', { class: 'home-card-box' });
  const rowsBox = h('div', { class: 'home-rows', hidden: true });
  const endedBox = h('div', { class: 'home-rows home-ended', hidden: true });
  const logs = h('section', { class: 'home-sect', 'data-home-logs': '' });
  const folder = h('section', { class: 'home-sect', 'data-home-folder': '' });
  // 635 (owner): the sessions as a list (the agent's card, then rows) or as a grid of their live pictures — the same
  // elements, laid out by CSS (`.as-grid`); a picture is painted again at its new size.
  const tiles = h('div', { class: 'home-tiles' }, cardBox, rowsBox);
  const doc = h('div', { class: 'home-doc' + (gridView() ? ' as-grid' : ''), role: 'tabpanel', 'aria-label': 'Home of ' + name, 'data-home': name },
    h('section', { class: 'home-sect', 'data-home-sessions': '' }, head, lead, tiles, endedBox), logs, folder);
  home = { name, doc, head, lead, cardBox, rowsBox, endedBox, logs, folder, card: null, empty: null, rows: new Map() };
  HOMES.set(name, home);
  return home;
}
/// List or grid — in this browser, for every Home (a layout convenience, like the sidebar's folds; never a setting).
function gridView() { try { return localStorage.getItem('doz.home.view') === 'grid'; } catch (_) { return false; } }
function setGridView(on) {
  try { localStorage.setItem('doz.home.view', on ? 'grid' : 'list'); } catch (_) { /* no storage: this page only */ }
  for (const home of HOMES.values()) { home.doc.classList.toggle('as-grid', on); schedule(home.name); }
}
function viewSwitch() {
  const grid = gridView();
  const seg = (on, ic, label) => h('button', { type: 'button', class: 'btn sm quiet icon-only' + (on === grid ? ' on' : ''), 'aria-pressed': on === grid ? 'true' : 'false',
    'aria-label': label, title: label, 'data-home-view': on ? 'grid' : 'list',
    on: { click: () => { setGridView(on); for (const n of HOMES.keys()) paintHome(n); } } }, icon(ic));
  return h('div', { class: 'btn-group home-view', role: 'group', 'aria-label': 'Show the sessions as' },
    seg(false, 'list', 'A list'), seg(true, 'layout-grid', 'A grid of their live pictures'));
}
function thumbsOf(home) {
  return [home.card && home.card.thumb, ...[...home.rows.values()].map((r) => r.thumb)].filter(Boolean);
}

/// Open a session here: its tab when the page has one, else a new interactive tab.
function openSession(name, session) {
  const v = sview(name);
  const have = pageTerminals(name).find((t) => t.session === session && t.mode === 'interactive' && !t.ended && !t.saved);
  if (have) { v.selected[have.pane] = have.id; v.focusedPane = have.pane; renderTerminals(); focusTerm(have); return; }
  openTerminal(name, session, 'interactive');
}
/// Show a saved session (the sandbox sleeps): its saved-screen tab.
function showSaved(name, row) { openSavedTerminal(name, row); }
/// "open in tab 2" / "not open here".
function tabFact(name, session) {
  const order = pageTerminals(name).filter((x) => !x.home && !x.buildlog && x.mode !== 'console' && !x.pending);
  const tabs = order.map((t, i) => (t.session === session ? i + 1 : 0)).filter(Boolean);
  return tabs.length ? 'open in tab ' + tabs.join(', ') : 'not open here';
}
function sinceText(row) {
  if (row.saved) return 'screen saved ' + when(row.savedAt) + (row.savedReason ? ' (' + row.savedReason + ')' : '');
  if (!row.openedAt) return 'running';
  return 'running since ' + new Date(row.openedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
function moreFor(name, session, why) {
  return moreMenu('More for ' + session, [
    { label: 'Watch', icon: 'eye', desc: 'Read-only: nothing you type reaches it, it never resizes', onSelect: () => openTerminal(name, session, 'watch') },
    isRemote() ? null : { label: 'Open in Terminal', icon: ICON_OPEN_IN_TERMINAL, desc: 'In your terminal app (doz attach)', disabled: !!why, why, onSelect: () => openInTerminal(name, session) },
    ...sessionMenuItems(name, session, why),
  ].filter(Boolean), { small: true, onClose: () => paintHome(name) });
}

/// Draw (or bring up to date) a sandbox's Home. Cheap enough to run after every tab change.
export function paintHome(name) {
  const hp = homePane(name);
  if (!hp) return;
  const home = homeOf(name);
  if (home.doc.parentNode !== hp.els.host) hp.els.host.replaceChildren(home.doc);
  // An open menu inside Home is never pulled from under the pointer: its close repaints.
  if (home.doc.querySelector('.menu:not([hidden])')) return;
  const s = state.sbx;
  if (!s || s.name !== name || !s.d) {
    home.lead.textContent = 'Loading…';
    schedule(name);
    return;
  }
  const d = s.d, i = d.info;
  const own = d.defaultSession;
  const title = agentTitle(i);
  const ownTitle = title || own;
  const tr = transitionOf(name);
  const busy = i.busy || i.phase === 'booting' || opRunningFor(name) || !!tr;
  const why = sessionsWhyNot(name, i);
  const running = i.phase === 'running' && !i.busy;
  const rows = d.sessions || [];
  const live = rows.filter((r) => !r.ended && !r.saved);
  const saved = rows.filter((r) => r.saved);
  const ended = rows.filter((r) => r.ended && !r.saved);
  const v = sview(name);
  // ── the head and its one line ──
  const newShell = btn('New shell', () => newShellTerminal(name).catch((e) => failureFor(name, e.message || String(e))), { small: true, icon: 'plus', title: why || 'A new shell session (shell-2, shell-3, …)' });
  const detached = btn('Run detached…', () => runDetachedDialog(name), { small: true, quiet: true, icon: 'play', title: why || 'A new session running a command, not opened here' });
  if (why) { newShell.disabled = true; detached.disabled = true; }
  home.head.replaceChildren(h('h2', null, 'Sessions'), h('div', { class: 'actions' }, viewSwitch(), newShell, detached));
  home.lead.textContent = busy ? (tr ? TRANSITION_LABEL[tr.action] : i.phaseLabel + '…')
    : running ? (live.length ? live.length + ' running. Each keeps running when its tab is closed — End stops one.' : 'Nothing is running in it.')
    : SAVED_PHASES.includes(i.phase) ? (i.phaseLabel.replace(/^./, (c) => c.toUpperCase()) + ' — its sessions wake with it, exactly as they were. A key typed in a saved screen wakes it.')
    : i.phase === 'failed' ? 'It failed to start. Start boots it fresh, with new sessions.'
    : 'Shut down — its sessions ended with it. Nothing is kept of their screens.';
  // ── the agent's session: a card (live or saved), else what starts it ──
  const ownRow = rows.find((r) => r.name === own && !r.ended);
  if (ownRow) {
    if (home.empty) { home.empty.remove(); home.empty = null; }
    paintCard(home, name, ownRow, { title: ownTitle, isAgent: !!title, running, why, v });
  } else {
    if (home.card) { home.card.thumb.source.drop(); home.card.el.remove(); home.card = null; }
    const start = i.phase === 'off' || i.phase === 'failed'
      ? btn('Start ' + ownTitle, () => lifecycle('start', name), { icon: 'play', title: 'Boot ' + name + ' and open ' + ownTitle })
      : btn('Start ' + ownTitle, () => openDefaultTerminal(name), { icon: 'play', title: why || 'Start the image’s own session (' + own + ')' });
    if (busy || (why && i.phase !== 'off' && i.phase !== 'failed')) start.disabled = true;
    const e = h('div', { class: 'home-empty', 'data-home-empty': '' }, icon('terminal'),
      h('div', { class: 't' }, ownTitle + ' is not running'),
      h('div', { class: 'd' }, i.phase === 'off' || i.phase === 'failed'
        ? 'Start boots ' + name + ' fresh and opens ' + ownTitle + (title ? ' — it resumes its last conversation.' : '.')
        : 'Its session is not running — Start opens it here.'),
      h('div', { class: 'acts' }, start));
    if (home.empty) home.empty.replaceWith(e); else home.cardBox.append(e);
    home.empty = e;
  }
  // ── the other sessions: a row each (live, or saved), in a stable order ──
  const others = (i.phase === 'running' ? live : saved).filter((r) => r.name !== own);
  const keep = new Set(others.map((r) => r.name));
  for (const [k, r] of home.rows) if (!keep.has(k)) { r.thumb.source.drop(); r.el.remove(); home.rows.delete(k); }
  let prev = null;
  for (const row of others) {
    let r = home.rows.get(row.name);
    if (!r) { r = makeRow(name, row.name); home.rows.set(row.name, r); }
    paintRow(r, name, row, why);
    const next = prev ? prev.nextSibling : home.rowsBox.firstChild;
    if (next !== r.el) home.rowsBox.insertBefore(r.el, next);
    prev = r.el;
  }
  home.rowsBox.hidden = !others.length;
  // An ended session (its program exited; the holder is still there): a quiet row — Restart brings it back.
  home.endedBox.replaceChildren(...(running ? ended : []).map((row) => h('div', { class: 'home-row dim', 'data-home-ended': row.name }, icon('terminal'),
    h('span', { class: 'nm' }, row.name), h('span', { class: 'cmd-t', title: row.command }, row.command),
    h('span', { class: 'st' }, 'ended' + (row.exitCode != null ? ' (exit ' + row.exitCode + ')' : '')),
    h('div', { class: 'row-acts' }, btn('Restart', () => restartSessionDialog(name, row.name), { small: true, quiet: true, icon: 'rotate-ccw', title: 'Start its program again, in the same folder' })))));
  home.endedBox.hidden = !(running && ended.length);
  paintLogs(home, name, i);
  paintFolder(home, i);
  schedule(name);
}

function paintCard(home, name, row, o) {
  if (!home.card) {
    const thumb = thumbFrame('Open ' + row.name, () => { const r = cardRow(home); if (!r) return; if (r.saved) showSaved(name, r); else openSession(name, r.name); }, true);
    const el = h('div', { class: 'home-agent has-thumb', 'data-home-agent': row.name });
    const t = h('div', { class: 't' }), meta = h('div', { class: 'meta' }), msg = h('div', { class: 'msg' }), acts = h('div', { class: 'acts' }), note = h('div', { class: 'home-note' });
    el.append(thumb.el, t, meta, msg, acts, note);
    home.card = { el, thumb, t, meta, msg, acts, note, session: row.name, row };
    home.cardBox.prepend(el);
  }
  const c = home.card;
  c.row = row;
  c.thumb.session = row.name;
  c.thumb.row = row;
  const st = agentStatusOf(name, row.name);
  c.t.replaceChildren(icon('terminal'), h('span', null, o.title), agentChip(name, row.name));
  c.meta.replaceChildren(...['session ' + row.name, sinceText(row), tabFact(name, row.name),
    o.isAgent && !row.saved ? 'resumes its last conversation when restarted' : null].filter(Boolean).map((x) => h('span', null, x)));
  c.msg.textContent = st && st.message ? st.message : '';
  c.msg.title = c.msg.textContent;
  c.msg.hidden = !c.msg.textContent;
  if (row.saved) {
    c.acts.replaceChildren(btn('Show', () => showSaved(name, row), { icon: 'eye', title: 'Its last saved screen in a tab (read-only; a key typed in it wakes the sandbox)' }));
  } else {
    const end = btn('End…', () => endSessionDialog(name, row.name), { quiet: true, danger: true, icon: 'power', title: o.why || 'Stop ' + o.title + ' — its program ends' });
    if (o.why) end.disabled = true;
    c.acts.replaceChildren(btn('Open', () => openSession(name, row.name), { primary: true, icon: 'terminal', title: 'Its screen, in a tab here' }), end,
      moreFor(name, row.name, o.why).el);
  }
  // The note: the agent's tab was just closed — it goes on (every time, until "Don't say this again").
  const say = o.v.justClosed === row.name && !row.saved && setting('ui.explain_tab_close', true);
  c.el.classList.toggle('just-closed', !!say);
  c.note.replaceChildren(say ? callout('info', { compact: true, attrs: { 'data-home-note': '' }, title: o.title + ' is still running',
    body: 'You closed its tab, not ' + o.title + ': it goes on working — and asks here and in the sidebar when it needs you. Open brings its screen back; End stops it.',
    actions: [btn('Don’t say this again', () => {
      saveSetting('ui.explain_tab_close', false).then(() => { o.v.justClosed = null; paintHome(name); })
        .catch((e) => failureFor(name, 'ui.explain_tab_close was not saved: ' + (e.message || e)));
    }, { small: true, quiet: true, icon: 'x', title: 'Settings › ui.explain_tab_close' })],
    dismiss: () => { o.v.justClosed = null; paintHome(name); } }) : '');
  if (!say && o.v.justClosed === row.name && row.saved) o.v.justClosed = null;
}
function cardRow(home) { return home.card ? home.card.row : null; }

function makeRow(name, session) {
  const r = { session, row: null };
  r.thumb = thumbFrame('Open ' + session, () => { if (!r.row) return; if (r.row.saved) showSaved(name, r.row); else openSession(name, session); }, false);
  r.thumb.session = session;
  r.nm = h('span', { class: 'nm' });
  r.cmd = h('span', { class: 'cmd-t' });
  r.st = h('span', { class: 'st' });
  r.acts = h('div', { class: 'row-acts' });
  r.el = h('div', { class: 'home-row has-thumb', 'data-home-row': session }, r.thumb.el, r.nm, r.cmd, r.st, r.acts);
  return r;
}
function paintRow(r, name, row, why) {
  r.row = row;
  r.thumb.row = row;
  r.nm.replaceChildren(h('span', null, row.name), agentChip(name, row.name));
  r.cmd.textContent = row.command;
  r.cmd.title = row.command;
  const dotPhase = row.saved ? state.sbx.d.info.phase : 'running';
  r.st.replaceChildren(h('span', { class: 'dot ph-' + dotPhase + phaseMark(dotPhase), 'aria-hidden': 'true' }),
    h('span', null, row.saved ? sinceText(row) : sinceText(row) + ' · ' + tabFact(name, row.name)));
  r.acts.replaceChildren(...(row.saved
    ? [btn('Show', () => showSaved(name, row), { small: true, quiet: true, icon: 'eye', title: 'Its last saved screen in a tab (read-only)' })]
    : [btn('Open', () => openSession(name, row.name), { small: true, quiet: true, icon: 'terminal', title: 'Its screen, in a tab here' }), moreFor(name, row.name, why).el]));
}

function logRow(ic, nm, desc, st, action, dim) {
  return h('div', { class: 'home-row' + (dim ? ' dim' : '') }, icon(ic), h('span', { class: 'nm' }, nm), h('span', { class: 'cmd-t' }, desc),
    h('span', { class: 'st' }, st), h('div', { class: 'row-acts' }, action));
}
function paintLogs(home, name, i) {
  const powered = ['booting', 'running', 'paused'].includes(i.phase);
  const v = sview(name);
  const cons = pageTerminals(name).find((t) => t.mode === 'console');
  const consoleOpen = btn('Open', () => {
    v.consoleClosed = false;
    const c = pageTerminals(name).find((t) => t.mode === 'console');
    if (c) { v.selected[c.pane] = c.id; v.focusedPane = c.pane; renderTerminals(); } else openConsoleTerminal(name, true);
  }, { small: true, quiet: true, icon: 'cpu', title: powered ? 'The system console, in a tab' : 'Only while it runs' });
  if (!powered) consoleOpen.disabled = true;
  // 635 (owner): the build log opens in its own tab from here (never by itself).
  const blog = state.buildLogs && state.buildLogs.get(name);
  const blogTab = pageTerminals(name).some((t) => t.buildlog);
  home.logs.replaceChildren(h('div', { class: 'head has-title' }, h('h2', null, 'Logs')), h('div', { class: 'home-rows' },
    logRow('cpu', 'Console', 'the kernel and vminitd, read-only', powered ? (cons ? 'open in a tab' : 'while it runs') : 'only while it runs', consoleOpen, !powered),
    blog ? logRow('wrench', 'Build log', 'how ' + (blog.image || 'its image') + ' was built',
      [blog.finishedAt ? when(blog.finishedAt) : '', blogTab ? 'open in a tab' : ''].filter(Boolean).join(' · '),
      btn('Open', () => openBuildLog(name), { small: true, quiet: true, icon: 'wrench', title: 'The build log, in its own tab' })) : null,
    logRow('history', 'Boot logs', 'its last boots: the steps and the console', '',
      btn('Show', () => bootLogDialog(name), { small: true, quiet: true, icon: 'eye', title: 'Its kept boots' }))));
}
function paintFolder(home, i) {
  const facts = [];
  const fact = (k, val) => facts.push(h('dt', null, k), h('dd', null, val));
  if (i.workspace) {
    fact('On this Mac', h('code', null, tildePath(i.workspace)));
    fact('In the sandbox', [h('code', null, '/workspace'), ' — live, both ways']);
    fact('Files it opens', setting('sandbox.open_files', true) ? 'open on this Mac — an .html page in your browser, with a notice (sandbox.open_files: on)'
      : 'not opened on this Mac (sandbox.open_files: off)');
    fact('Workspace rules', i.workspaceRules || 'none — the folder is shared as is');
  } else {
    fact('Folder', 'isolated — no folder of this Mac is shared');
  }
  home.folder.replaceChildren(h('div', { class: 'head has-title' }, h('h2', null, 'Folder')), h('dl', { class: 'home-facts' }, ...facts));
}

// ── the pictures (648: painted — components/session-thumb.js). Every session has one, however many: a session with a
// tab here is mirrored from that tab's own frame, one without from the host's feed; a sleeping sandbox's from its saved
// screen. They are asked for only while Home is the shown tab of a visible page and the picture is on screen (a hidden
// Home is not on screen), and nothing is asked of a sandbox that does not run. ─────────────────────────────────────
const scheduled = new Set();
function schedule(name) {
  if (scheduled.has(name)) return;
  scheduled.add(name);
  setTimeout(() => { scheduled.delete(name); placeThumbs(name); }, 40);
}
function placeThumbs(name) {
  const home = HOMES.get(name);
  if (!home) return;
  const s = state.sbx;
  const info = s && s.name === name && s.d ? s.d.info : null;
  // The sandbox page's detail is of another sandbox (or not read yet): this Home's pictures stay as they are.
  if (!info) return;
  const running = info.phase === 'running' && !info.busy;
  let live = 0;
  for (const th of thumbsOf(home)) {
    th.source.want(specOf(name, th, running));
    if (th.source.spec && th.source.spec.kind === 'live') live++;
  }
  home.doc.dataset.live = String(live);
}
/// The picture a thumbnail shows: the session's tab when it has one here (the tab's own frame), else the feed; saved.
function specOf(name, th, running) {
  const r = th.row;
  if (!r || r.ended) return null;
  if (r.saved) return { kind: 'saved', sandbox: name, session: th.session, savedAt: r.savedAt || null };
  if (!running || !setting('ui.terminals', true)) return null;
  const tab = pageTerminals(name).find((t) => t.session === th.session && !t.saved && !t.ended && !t.closed && t.booted && t.frame
    && (t.mode === 'interactive' || t.mode === 'watch'));
  return { kind: 'live', sandbox: name, session: th.session, tab: tab || null };
}
/// Tabs change (opened, closed, booted): Home's pictures follow on its next paint; and when the page's tab comes back.
function placeAll() { for (const name of HOMES.keys()) schedule(name); }
window.addEventListener('hashchange', () => setTimeout(placeAll, 0));
document.addEventListener('visibilitychange', placeAll);
