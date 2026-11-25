// views/workspace — A workspace's page (#/w/NAME: its Home tab, views/ws-home.js; #/w/NAME/room[/LABEL]: its Room tab —
// its main room or another of its rooms; #/w/NAME/agents: its Agents tab, views/ws-agents.js). A section of its own (#ws), built once: the
// title row (its name, state, who drives, its manager, one primary button by state — Start, Sleep, Wake, Reopen, Restore —
// and ⋯ with its lifecycle: Stop the manager, Sleep and Wake everything, Finish…, Archive…, Delete…, each a dialog drawn from
// its plan — components/ws-lifecycle.js),
// the tabs (Home — the workspace drawn and its cards —, Room, Agents, Network & secrets, Folders & points, Activity and Runs work —
// views/ws-network.js, ws-folders.js, ws-activity.js, ws-runs.js, each read afresh on every visit; Permissions and Settings say
// what they will hold); on the Room tab the brief ("The work", components/ws-brief.js), the room — THE chat surface of the Chat page, moved here
// (views/chat.js mountChat) and scoped to this workspace's rooms, its log's lines drawn among the messages — and the side
// panel (components/ws-panel.js). Read on arrival, hello, `changed` and an operation's end — never on a timer.
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { api } from '../core/api-496fd9f39af2a514.js';
import { actOrThrow, waitForOp } from '../core/operations-283a20408c4a56b6.js';
import { activityHash, agentsHash, foldersHash, networkHash, roomHash, runsHash, workspaceHash } from '../core/routes-0babfc190b1519e4.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { loadBots, loadWorkspace, loadWorkspaces, readWorkspaceAfresh } from '../core/workspaces-eb44da5e11322b41.js';
import { briefEdits, forRoom, lineAt, mergeLines } from '../core/ws-log-725b407c6811cd6c.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { cmdLine } from '../components/cmd-line-0addb11225f36cdd.js';
import { menuButton } from '../components/menus-2bfb74f31fa5969c.js';
import { pageFailure, toast } from '../components/notices-7a75ec167a650349.js';
import { dialog } from '../components/dialog-2df3db2fbea6647b.js';
import { startsOnce } from '../components/ws-gaps-84574317f2b79044.js';
import { newWorkspaceRefusal } from './new-workspace-7e3534021fa9e04c.js';
import { briefCard } from '../components/ws-brief-5efa0e74436e5613.js';
import { driverChip, managerChip, workspacePill } from '../components/ws-marks-d5ea1fd9ab813391.js';
import { renderNavWorkspaces } from '../components/ws-nav-c82002bf767d71c2.js';
import { lifecycleItems, primaryButton, transitional } from '../components/ws-lifecycle-1f22039888a2636e.js';
import { agentMeta, wsPanel } from '../components/ws-panel-f74c61083ef5e232.js';
import { chatLeave, chatNavCheck, chatRefresh, mountChat } from './chat-6e67e0ac70ad4582.js';
import { chatOnForm } from '../components/chat-on-14a79727e31321e0.js';
import { drawSys } from './chat-messages-546ce3c54f32646b.js';
import { openRoom, refreshState } from './chat-rooms-2d45e272b060f31a.js';
import { agentsTab } from './ws-agents-b48a9aae1312d182.js';
import { networkTab } from './ws-network-ab61d4a0165a1a39.js';
import { foldersTab } from './ws-folders-041c31335389d8db.js';
import { activityTab } from './ws-activity-360606b564c37b82.js';
import { runsTab } from './ws-runs-25bf4c8770f5e17f.js';
import { homeDispose, homeTab } from './ws-home-78f186ea1b1d049a.js';

/// The permissions tab's name — ONE constant (the owner's choice; every place that names the tab reads it).
export const PERMISSIONS_TAB = 'Permissions';
/// The tabs, in the mockups' order: Home (the workspace's own address), Room and the rest that work (each an address);
/// each other says what it will hold.
export const WS_TABS = [
  { id: 'home', label: 'Home', href: (w) => workspaceHash(w) },
  { id: 'room', label: 'Room', href: (w) => roomHash(w) },
  { id: 'agents', label: 'Agents', href: (w) => agentsHash(w) },
  { id: 'permissions', label: PERMISSIONS_TAB, coming: 'What each agent may do here: allow, ask or never, by role, and who decides — today: each agent’s Can do' },
  { id: 'network', label: 'Network & secrets', href: (w) => networkHash(w) },
  { id: 'folders', label: 'Folders & points', href: (w) => foldersHash(w) },
  { id: 'activity', label: 'Activity', href: (w) => activityHash(w) },
  { id: 'runs', label: 'Runs', href: (w) => runsHash(w) },
  { id: 'settings', label: 'Settings', coming: 'Its defaults: isolation, network, the manager, finishing and archiving' },
];
const FOLD_KEY = (w) => 'doz.ws.fold:' + w;

let built = false;
let cur = null;          // {name, label, detail, bots, brief, denied, lines, room, missing}
let card = null;
const peopleSlot = h('div', { class: 'ws-people-slot' });

function build() {
  if (built) return;
  built = true;
  const tabs = h('div', { class: 'ws-tabs', role: 'tablist', 'aria-label': 'This workspace' }, ...WS_TABS.map((t) => t.coming
    ? h('button', { type: 'button', role: 'tab', class: 'ws-tab is-coming', 'aria-selected': 'false', 'aria-disabled': 'true', 'data-ws-tab': t.id,
      title: t.label + ' — coming: ' + t.coming }, t.label, h('span', { class: 'ws-coming' }, 'coming'))
    : h('a', { role: 'tab', class: 'ws-tab', 'aria-selected': 'false', 'data-ws-tab': t.id, href: '#/home' }, t.label)));
  $('ws').replaceChildren(
    h('div', { class: 'ws-head', id: 'ws-head' }),
    tabs,
    h('div', { class: 'ws-home-tab', id: 'ws-home', hidden: true, role: 'tabpanel', 'aria-label': 'Home' }),
    h('div', { class: 'ws-body', hidden: true },
      h('div', { class: 'ws-main' },
        h('div', { class: 'ws-notice', id: 'ws-notice' }),
        h('div', { class: 'ws-brief-slot', id: 'ws-brief' }),
        h('div', { class: 'ws-room', id: 'ws-room', role: 'region', 'aria-label': 'The room' })),
      h('aside', { class: 'ws-panel', id: 'ws-panel', 'aria-label': 'Who is here and in what' })),
    h('div', { class: 'ws-agents-tab', id: 'ws-agents', hidden: true, role: 'tabpanel', 'aria-label': 'Agents' }),
    h('div', { class: 'ws-view-tab', id: 'ws-view', hidden: true, role: 'tabpanel' }));
}

/// The tab row's state for `name` on `tab` (home, room, agents, …): each working tab is a link to its address.
function paintTabs(name, tab) {
  for (const el of $('ws').querySelectorAll('.ws-tabs [data-ws-tab]')) {
    const t = WS_TABS.find((x) => x.id === el.dataset.wsTab);
    if (!t || t.coming) continue;
    const on = t.id === tab;
    el.setAttribute('href', t.href(name));
    el.setAttribute('aria-selected', on ? 'true' : 'false');
    el.classList.toggle('is-on', on);
  }
  const agents = tab === 'agents', view = VIEW_TABS.includes(tab);
  $('ws-home').hidden = tab !== 'home';
  $('ws').querySelector('.ws-body').hidden = tab !== 'room';
  $('ws-agents').hidden = !agents;
  $('ws-view').hidden = !view;
  if (view) $('ws-view').setAttribute('aria-label', WS_TABS.find((t) => t.id === tab).label);
}

/// The tabs drawn from a read of their own (each read afresh on every visit).
const VIEW_TABS = ['network', 'folders', 'activity', 'runs'];

/// The places of the workspace's agents, as a person types them (the activity's operations are filtered by them).
const placesOf = (d) => d.agents.map((a) => (a.kind === 'sandbox' ? a.sandbox : a.kind === 'mac' ? '@mac/' + a.session : null)).filter(Boolean);

/// Draw a view tab: `fresh` on arrival (everything read again), else its own refresh (Activity: the newest page merged).
function drawView(fresh) {
  if (!cur || !VIEW_TABS.includes(cur.tab) || !cur.detail) return;
  const host = $('ws-view'), name = cur.name;
  if (fresh) host.replaceChildren(h('p', { class: 'muted' }, 'reading…'));
  if (cur.tab === 'network') networkTab(name, host);
  else if (cur.tab === 'folders') foldersTab(name, host, cur.detail);
  else if (cur.tab === 'runs') runsTab(name, host, cur.detail);
  else activityTab(name, host, placesOf(cur.detail), fresh);
}

function folded(name, label) {
  if (label) return true;                  // a room's address: the brief on one line, the room keeps the space
  try { return localStorage.getItem(FOLD_KEY(name)) === 'folded'; } catch (_) { return false; }
}
function rememberFold(name, f) {
  try { if (f) localStorage.setItem(FOLD_KEY(name), 'folded'); else localStorage.removeItem(FOLD_KEY(name)); } catch (_) { /* this page only */ }
}

async function readBrief(name) {
  try { return { brief: await api('workspaces/' + encodeURIComponent(name) + '/brief'), denied: false }; } catch (e) {
    return { brief: null, denied: e.status === 403 };
  }
}
async function readLog(name, since) {
  try {
    const q = since ? '?since=' + since : '';
    return await api('workspaces/' + encodeURIComponent(name) + '/log' + q);
  } catch (_) { return null; }
}

/// What this browser may change of the brief: this Mac's own browser always; another only with serve.chat = write.
function canEdit() {
  if (!state.serve) return { ok: true };
  const st = state.chat.status;
  return st && st.access === 'write' ? { ok: true } : { ok: false, why: 'This browser may not edit the brief — on the Mac: doz config set serve.chat write' };
}

const mainOf = (d) => (d ? d.rooms.find((r) => r.main) || null : null);

/// The room an address names: the main one, or another by its label (unknown: the main one, and the line saying so).
function roomFor(d, label) {
  const main = mainOf(d);
  if (!label) return { wr: main, missing: null };
  const wr = d.rooms.find((r) => !r.main && r.label === label);
  return wr ? { wr, missing: null } : { wr: main, missing: 'no room ' + label + ' in ' + d.name };
}

function scope() {
  const d = cur.detail, main = mainOf(d);
  return {
    workspace: d.name,
    rooms: d.rooms.slice().sort((a, b) => (a.main ? -1 : b.main ? 1 : a.label.localeCompare(b.label))),
    who: (n) => (cur && cur.detail ? agentMeta(cur.detail, cur.bots, n) : null),
    sysLines: (room) => (cur ? forRoom(cur.lines, room, main ? main.room : null) : []),
    address: (wr) => roomHash(d.name, wr.main ? null : wr.label),
  };
}

/// Arriving on #/w/NAME (`tab` home), #/w/NAME/room[/LABEL] (room) or another tab.
export async function wsEnter(name, label, tab) {
  build();
  paintTabs(name, tab);
  const fresh = !cur || cur.name !== name;
  if (fresh) {
    cur = { name, label, tab, detail: null, bots: null, brief: null, denied: false, lines: [], room: null, missing: null };
    $('ws-agents').replaceChildren();
    card = null;
    homeDispose();
    $('ws-home').replaceChildren(h('p', { class: 'muted' }, 'reading…'));
    $('ws-head').replaceChildren(h('h1', null, name));
    $('ws-brief').replaceChildren();
    $('ws-notice').replaceChildren();
    $('ws-panel').replaceChildren(h('p', { class: 'muted' }, 'reading…'));
  }
  if (fresh || cur.label !== label) cur.folded = folded(name, label);
  cur.label = label;
  cur.tab = tab;
  let d;
  try { d = await loadWorkspace(name, 0); } catch (e) {
    if (!cur || cur.name !== name) return;
    homeDispose();
    $(tab === 'home' ? 'ws-home' : 'ws-notice').replaceChildren(callout(e.status === 404 ? 'warn' : 'bad', { title: e.status === 404 ? name + ' is not a workspace' : 'This workspace could not be read',
      body: e.status === 404 ? h('span', null, 'It may have been renamed. ', h('a', { href: '#/home' }, 'Home'), ' lists the workspaces.') : e.message || String(e) }));
    return;
  }
  const [bots, b, log] = await Promise.all([loadBots(5000).catch(() => null), readBrief(name), readLog(name)]);
  if (!cur || cur.name !== name || state.view !== 'workspace') return;
  cur.detail = d;
  cur.bots = bots ? bots.bots : null;
  cur.brief = b.brief; cur.denied = b.denied;
  cur.lines = log ? log.lines : [];
  cur.logHidden = log ? log.hidden : 0;
  const { wr, missing } = roomFor(d, label);
  cur.room = wr; cur.missing = missing;
  draw(true);
  // The sidebar's tree marks this page; a page opened here first reads the list once (never on a timer).
  if (state.workspaces) renderNavWorkspaces(); else loadWorkspaces(1000).then(() => renderNavWorkspaces()).catch(() => { /* the next hello */ });
  if (VIEW_TABS.includes(tab)) { drawView(true); window.scrollTo(0, 0); return; }     // read afresh on every visit
  // Home never holds chat's stream (being here is not being in the room): a stream the Room tab opened closes 5 s later.
  if (tab === 'home') { chatLeave(); window.scrollTo(0, 0); return; }
  if (tab === 'agents') { window.scrollTo(0, 0); return; }       // the room is mounted when its tab is shown
  await mountChat({ room: $('ws-room'), people: peopleSlot }, scope(), wr ? wr.room : null);
  drawSys();
}

/// The router's refresh while on the page (hello, `changed`, an operation's end): the workspace, its log since the last
/// line read and its brief again; nothing torn down (the room keeps its place, an open edit its text).
export async function wsRefresh() {
  if (!cur || state.view !== 'workspace') return;
  const name = cur.name;
  const last = cur.lines.length ? Math.floor(lineAt(cur.lines[cur.lines.length - 1])) : 0;
  let d;
  try { d = await loadWorkspace(name, 0); } catch (_) { return; }
  const [b, log] = await Promise.all([readBrief(name), readLog(name, last)]);
  if (!cur || cur.name !== name || state.view !== 'workspace') return;
  cur.detail = d;
  cur.brief = b.brief; cur.denied = b.denied;
  if (log) { cur.lines = mergeLines(cur.lines, log.lines); cur.logHidden = log.hidden; }
  draw(true);
  // Activity follows a change (its newest page); Network & secrets and Folders & points are read on each visit only — a
  // walk of the folders is never run on an event.
  if (cur.tab === 'activity') drawView(false);
  if (cur.tab !== 'room') return;
  chatRefresh();
  drawSys();
}

/// Chat came on from this page: the sidebar's entry, then the workspace read again (its gaps, its room).
async function chatCameOn() {
  await chatNavCheck();
  if (cur) readWorkspaceAfresh(cur.name);
  await wsRefresh();
}

/// "No room yet": Make its room — exactly `doz workspace edit W --make-room` (this Mac's own browser; another computer the
/// command). While chat is off, the chat-on form first and the button off until chat is on.
function noRoomBody(d) {
  const command = cmdLine('doz workspace edit ' + d.name + ' --make-room');
  if (newWorkspaceRefusal()) return command;
  const on = !!state.chat.on;
  const err = h('p', { class: 'chat-on-error', role: 'alert', 'data-ws-make-room-error': '', hidden: true });
  const make = h('button', { type: 'button', class: 'btn sm primary', 'data-ws-make-room': d.name, disabled: on ? null : true,
    title: on ? 'Make its room in chat now, named after the workspace' : 'Chat is off: turn it on first' }, icon('plus'), 'Make its room');
  make.addEventListener('click', async () => {
    make.disabled = true;
    err.hidden = true;
    try {
      const end = await waitForOp(await actOrThrow({ action: 'workspace-make-room', workspace: d.name }), 120);
      // Made: the page read again as on arriving (its room mounted, the set-up items again).
      if (end && end.state === 'done') {
        readWorkspaceAfresh(d.name);
        if (cur && cur.name === d.name) await wsEnter(cur.name, cur.label, cur.tab);
        return;
      }
      err.textContent = (end && end.text) || 'No answer yet — Operations shows how it ends.';
    } catch (e) { err.textContent = e.message || String(e); }
    err.hidden = false;
    make.disabled = false;
  });
  return [on ? null : chatOnForm({ onOn: chatCameOn }), h('div', { class: 'ws-start-row' }, make, command), err].filter(Boolean);
}

/// Save the brief: one `workspace-brief` (the sha256 read with it — a brief changed since is refused, nothing written).
async function save(text, sha) {
  try {
    const op = await actOrThrow({ action: 'workspace-brief', workspace: cur.name, brief: text, ifBrief: sha });
    const end = await waitForOp(op, 120);
    if (!end) return 'No answer yet — Operations shows how it ends.';
    if (end.state !== 'done') return end.text || 'The brief was not saved.';
    toast(end.text || 'Saved');
    await wsRefresh();
    return null;
  } catch (e) { return e.message || String(e); }
}

function jump(edit) {
  const t = Math.floor(lineAt(edit.line));
  const el = [...document.querySelectorAll('#chat-log .chat-sys[data-action="brief-edited"]')].find((x) => Math.floor(+x.dataset.at) === t);
  if (!el) { pageFailure('That edit is older than the messages loaded — scroll up in the room to load them.'); return; }
  const next = el.nextElementSibling && el.nextElementSibling.classList.contains('chat-row') ? el.nextElementSibling : el;
  next.scrollIntoView({ block: 'center' });
  next.classList.add('is-flash');
  setTimeout(() => next.classList.remove('is-flash'), 1600);
}

/// A lifecycle verb ended: the workspace read again (a deleted one leaves for Home), the sidebar and Home follow.
async function lifecycleDone(end) {
  const name = cur && cur.name;
  await loadWorkspaces(0).catch(() => null);
  renderNavWorkspaces();
  if (end && /^workspace-delete$/.test(end.action || '') || (name && state.workspaces && !state.workspaces.workspaces.some((w) => w.name === name))) {
    location.hash = '#/home';
    return;
  }
  await wsRefresh();
  // A finish, an archive or a restore changed what its room is: the chat server's state read again (on any tab — the Room
  // tab opened later must not draw the room as it was), the room shown as it now is (the closed or archived notice, the
  // composer off — or back on).
  if (state.chat.srv) await refreshState();
  if (cur && cur.tab === 'room' && state.chat.room) await openRoom(state.chat.room);
}

/// `read`: Home's own reads again too (arrival, hello, `changed`, an operation's end — never a redraw of what is known).
function draw(read) {
  const d = cur.detail, started = !!d.startedAt;
  // The title row: name, state (or what a lifecycle operation is doing to it), who drives, its manager, the one primary
  // button its state offers, ⋯ (the lifecycle — each a dialog drawn from its plan).
  const manager = d.agents.find((a) => a.role === 'manager');
  const items = lifecycleItems(d, lifecycleDone);
  if (d.notes.length) { items.push({ sep: true }, { heading: 'Not set up yet' }); for (const n of d.notes) items.push({ label: n, disabled: true, why: 'doz workspace show ' + d.name }); }
  items.push({ sep: true }, { label: 'Copy: doz workspace show ' + d.name, icon: 'copy', onSelect: () => copy('doz workspace show ' + d.name) });
  const more = menuButton(h('button', { type: 'button', class: 'btn quiet icon-only', 'aria-label': 'More for ' + d.name, title: 'More for ' + d.name }, icon('ellipsis')),
    items, { label: 'More for ' + d.name, align: 'end' }).el;
  const managerRow = manager ? { bot: manager.bot || manager.name, isolation: manager.isolation || 'fenced', actsAsYou: manager.actsAsYou, state: manager.state,
    words: (manager.bot || manager.name) + ' (' + (manager.actsAsYou ? 'unfenced · acts as you' : manager.isolation || 'fenced') + ')' } : null;
  const primary = d.state === 'setting-up' ? startButton(d, { 'data-ws-primary': 'start' }) : primaryButton(d, lifecycleDone);
  $('ws-head').replaceChildren(...[h('h1', { class: 'ws-name' }, d.name), workspacePill(d.state, d.words, transitional(d.name)), driverChip(d.driver),
    managerRow ? managerChip(managerRow) : null, h('span', { class: 'ws-sp' }), primary, more].filter(Boolean));
  // The Room tab's notices: a room address that names no room, setting up (Home has what is missing), no room at all.
  const notes = [];
  if (cur.missing) notes.push(callout('warn', { compact: true, attrs: { 'data-ws-missing': '' }, body: cur.missing + ' — this is its main room.' }));
  if (d.state === 'setting-up') {
    notes.push(callout('info', { compact: true, cls: 'ws-setup', attrs: { 'data-ws-setup-line': String((d.gaps || []).length) },
      body: h('span', null, 'Setting up — ', h('a', { href: workspaceHash(d.name) }, 'Home'), ' shows what is missing') }));
  }
  if (!d.rooms.length) notes.push(callout('info', { compact: true, title: 'No room yet', attrs: { 'data-ws-noroom': d.name }, body: noRoomBody(d) }));
  if (cur.logHidden) notes.push(callout('info', { compact: true, body: cur.logHidden + ' of its log’s lines are about sessions on this Mac and are not shown to this browser.' }));
  $('ws-notice').replaceChildren(...notes);
  // The brief.
  const e = canEdit();
  const o = { workspace: d.name, brief: cur.brief, denied: cur.denied, edits: briefEdits(cur.lines), started, folded: cur.folded,
    onFold: (f) => { cur.folded = f; if (!cur.label) rememberFold(d.name, f); }, canEdit: e.ok, editWhy: e.why, onSave: save, onJump: jump };
  if (!card || card.dataset.wsBrief !== d.name) { card = briefCard(o); $('ws-brief').replaceChildren(card); } else card.redraw(o);
  // The side panel.
  $('ws-panel').replaceChildren(wsPanel({ detail: d, mainRoom: mainOf(d) ? mainOf(d).room : null, peopleSlot }));
  // The Agents tab (drawn while it is shown).
  if (cur.tab === 'agents') $('ws-agents').replaceChildren(agentsTab({ detail: d, lines: cur.lines, onChanged: () => wsRefresh() }));
  // Home (drawn while it is shown; its picture kept across redraws).
  if (cur.tab === 'home') {
    homeTab({ detail: d, lines: cur.lines, logHidden: cur.logHidden, onLifecycle: lifecycleDone, onChatOn: chatCameOn,
      startButton: () => startButton(d, { 'data-ws-start': d.name }) }, $('ws-home'), read);
  }
}

/// Start (setting up): the wizard's same action, this Mac's own browser only, disabled while anything is missing.
function startButton(d, attrs) {
  const why = newWorkspaceRefusal(), gaps = d.gaps || [];
  return h('button', { type: 'button', class: 'btn sm primary', ...attrs, disabled: why || gaps.length || starting ? true : null,
    title: why ? 'A workspace is started only in this Mac’s own browser, or with doz workspace start in a terminal on the Mac'
      : gaps.length ? startsOnce(gaps) : 'Post the brief as your first message and start the work',
    on: { click: () => startWorkspace(d) } }, icon(starting ? 'hourglass' : 'play'), 'Start');
}

/// Start: `workspace-start` — the brief posted as you, the manager started. An unfenced manager was confirmed when it was
/// named (the wizard's "acts as you"); here it is confirmed again first.
let starting = false;
async function startWorkspace(d) {
  const m = d.agents.find((a) => a.role === 'manager');
  const go = async () => {
    starting = true;
    draw();
    try {
      const end = await waitForOp(await actOrThrow({ action: 'workspace-start', workspace: d.name, actsAsYou: !!(m && m.actsAsYou) }), 300);
      if (!end) toast('No answer yet — Operations shows how it ends.', true);
      else if (end.state === 'done') toast(end.text);
      else pageFailure(end.text || d.name + ' did not start');
    } catch (e) { pageFailure(e.message || String(e)); }
    starting = false;
    await wsRefresh();
  };
  if (m && m.actsAsYou) {
    dialog(m.name + ' acts as you', m.name + ' runs unfenced: no proxy, no placeholders, no guard.', [], 'Start', async () => { go(); },
      { danger: true, confirmCheck: 'Yes, ' + m.name + ' acts as me', icon: 'triangle-alert' });
    return;
  }
  go();
}

async function copy(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied — paste it in a terminal on this Mac'); } catch (_) { pageFailure('This browser could not copy — ' + text); }
}
