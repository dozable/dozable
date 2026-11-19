// views/workspace — A workspace's page (#/w/NAME: its main room; #/w/NAME/room/LABEL: another of its rooms;
// #/w/NAME/agents: its Agents tab, views/ws-agents.js): the room comes first. A section of its own (#ws), built once: the
// title row (its name, state, who drives, its manager, ⋯ with the commands that start or stop it — never an action here),
// the tabs (Room and Agents work; the others say what they will hold), the brief ("The work", components/ws-brief.js), the room — THE chat surface of the Chat page, moved here
// (views/chat.js mountChat) and scoped to this workspace's rooms, its log's lines drawn among the messages — and the side
// panel (components/ws-panel.js). Read on arrival, hello, `changed` and an operation's end — never on a timer.
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-575fccc668c266ed.js';
import { actOrThrow, waitForOp } from '../core/operations-1d3580afdab883c9.js';
import { agentsHash, workspaceHash } from '../core/routes-7411f656fa0a4220.js';
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { loadBots, loadWorkspace, loadWorkspaces } from '../core/workspaces-b3af0b563b1896fb.js';
import { briefEdits, forRoom, lineAt, mergeLines } from '../core/ws-log-725b407c6811cd6c.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-3231e9d35221efc6.js';
import { menuButton } from '../components/menus-b8f822d6b7817c72.js';
import { pageFailure, toast } from '../components/notices-5a3ce779547f2571.js';
import { dialog } from '../components/dialog-772c5fc0f55959e6.js';
import { gapsList, startsOnce } from '../components/ws-gaps-7883615e1c353bcf.js';
import { newWorkspaceRefusal } from './new-workspace-5d396b4159020930.js';
import { briefCard } from '../components/ws-brief-55f6bdce94b7ff34.js';
import { driverChip, managerChip, workspacePill } from '../components/ws-marks-16479f7b77b97bee.js';
import { renderNavWorkspaces } from '../components/ws-nav-8eedb7ac58799334.js';
import { agentMeta, wsPanel } from '../components/ws-panel-3f441a3bea2475a4.js';
import { chatRefresh, mountChat } from './chat-72013a10e8da2d45.js';
import { drawSys } from './chat-messages-13a6a219353a3d66.js';
import { agentsTab } from './ws-agents-fd54249847ad0f20.js';

/// The permissions tab's name — ONE constant (the owner's choice; every place that names the tab reads it).
export const PERMISSIONS_TAB = 'Permissions';
/// The tabs, in the mockups' order: Room and Agents work (each an address); each other says what it will hold.
export const WS_TABS = [
  { id: 'room', label: 'Room', href: (w) => workspaceHash(w) },
  { id: 'agents', label: 'Agents', href: (w) => agentsHash(w) },
  { id: 'permissions', label: PERMISSIONS_TAB, coming: 'What each agent may do here: allow, ask or never, by role, and who decides' },
  { id: 'network', label: 'Network & secrets', coming: 'The sites its agents reach, the ports forwarded, the secrets they hold as placeholders' },
  { id: 'folders', label: 'Folders & points', coming: 'Its folders, what changed in them, and restore points' },
  { id: 'activity', label: 'Activity', coming: 'Everything that happened: its log, operations, what each agent did' },
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
    h('div', { class: 'ws-body' },
      h('div', { class: 'ws-main' },
        h('div', { class: 'ws-notice', id: 'ws-notice' }),
        h('div', { class: 'ws-brief-slot', id: 'ws-brief' }),
        h('div', { class: 'ws-room', id: 'ws-room', role: 'region', 'aria-label': 'The room' })),
      h('aside', { class: 'ws-panel', id: 'ws-panel', 'aria-label': 'Who is here and in what' })),
    h('div', { class: 'ws-agents-tab', id: 'ws-agents', hidden: true, role: 'tabpanel', 'aria-label': 'Agents' }));
}

/// The tab row's state for `name` on `tab` (null: the room): each working tab is a link to its address.
function paintTabs(name, tab) {
  for (const el of $('ws').querySelectorAll('.ws-tabs [data-ws-tab]')) {
    const t = WS_TABS.find((x) => x.id === el.dataset.wsTab);
    if (!t || t.coming) continue;
    const on = t.id === (tab || 'room');
    el.setAttribute('href', t.href(name));
    el.setAttribute('aria-selected', on ? 'true' : 'false');
    el.classList.toggle('is-on', on);
  }
  const agents = tab === 'agents';
  $('ws').querySelector('.ws-body').hidden = agents;
  $('ws-agents').hidden = !agents;
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
    address: (wr) => workspaceHash(d.name, wr.main ? null : wr.label),
  };
}

/// Arriving on #/w/NAME[/room/LABEL] or #/w/NAME/agents (`tab`).
export async function wsEnter(name, label, tab) {
  build();
  paintTabs(name, tab);
  const fresh = !cur || cur.name !== name;
  if (fresh) {
    cur = { name, label, tab, detail: null, bots: null, brief: null, denied: false, lines: [], room: null, missing: null };
    $('ws-agents').replaceChildren();
    card = null;
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
    $('ws-notice').replaceChildren(callout(e.status === 404 ? 'warn' : 'bad', { title: e.status === 404 ? name + ' is not a workspace' : 'This workspace could not be read',
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
  draw();
  // The sidebar's tree marks this page; a page opened here first reads the list once (never on a timer).
  if (state.workspaces) renderNavWorkspaces(); else loadWorkspaces(1000).then(() => renderNavWorkspaces()).catch(() => { /* the next hello */ });
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
  draw();
  if (cur.tab === 'agents') return;
  chatRefresh();
  drawSys();
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

function draw() {
  const d = cur.detail, started = !!d.startedAt;
  // The title row: name, state, who drives, its manager, ⋯ (the commands — start and stop are the CLI's here).
  const manager = d.agents.find((a) => a.role === 'manager');
  const items = [];
  if (d.state === 'setting-up') items.push({ label: 'Copy: doz workspace start ' + d.name, icon: 'copy', desc: 'Starts the work once it is fully set up',
    onSelect: () => copy('doz workspace start ' + d.name) });
  if (manager) items.push({ label: 'Copy: doz workspace stop ' + d.name, icon: 'copy', desc: 'Stops its manager; its conversation is kept',
    onSelect: () => copy('doz workspace stop ' + d.name) });
  if (d.notes.length) { items.push({ sep: true }, { heading: 'Not set up yet' }); for (const n of d.notes) items.push({ label: n, disabled: true, why: 'doz workspace show ' + d.name }); }
  items.push({ sep: true }, { label: 'Copy: doz workspace show ' + d.name, icon: 'copy', onSelect: () => copy('doz workspace show ' + d.name) });
  const more = menuButton(h('button', { type: 'button', class: 'btn quiet icon-only', 'aria-label': 'More for ' + d.name, title: 'More for ' + d.name }, icon('ellipsis')),
    items, { label: 'More for ' + d.name, align: 'end' }).el;
  const managerRow = manager ? { bot: manager.bot || manager.name, isolation: manager.isolation || 'fenced', actsAsYou: manager.actsAsYou, state: manager.state,
    words: (manager.bot || manager.name) + ' (' + (manager.actsAsYou ? 'unfenced · acts as you' : manager.isolation || 'fenced') + ')' } : null;
  $('ws-head').replaceChildren(...[h('h1', { class: 'ws-name' }, d.name), workspacePill(d.state, d.words), driverChip(d.driver),
    managerRow ? managerChip(managerRow) : null, h('span', { class: 'ws-sp' }), more].filter(Boolean));
  // The notices: setting up (what is missing, the command), a room address that names no room, no room at all.
  const notes = [];
  if (cur.missing) notes.push(callout('warn', { compact: true, attrs: { 'data-ws-missing': '' }, body: cur.missing + ' — this is its main room.' }));
  if (d.state === 'setting-up') {
    // What its start would refuse now (`workspace-show`'s gaps — a look), live; Start is the wizard's same action, this
    // Mac's own browser only, and disabled while anything is missing.
    const gaps = d.gaps || [];
    const why = newWorkspaceRefusal();
    const start = h('button', { type: 'button', class: 'btn sm primary', 'data-ws-start': d.name, disabled: why || gaps.length || starting ? true : null,
      title: why ? 'A workspace is started only in this Mac’s own browser, or with doz workspace start in a terminal on the Mac' : gaps.length ? startsOnce(gaps) : 'Post the brief as your first message and start the work',
      on: { click: () => startWorkspace(d) } }, icon(starting ? 'hourglass' : 'play'), 'Start');
    notes.push(callout('info', { compact: true, cls: 'ws-setup', title: 'Setting up — the work starts once it is fully set up',
      attrs: { 'data-ws-setup': String(gaps.length) },
      body: [gaps.length ? gapsList(gaps) : h('p', { class: 'muted' }, 'Nothing is missing: it can start.'),
        d.notes.length ? h('ul', { class: 'hm-gaps' }, ...d.notes.map((n) => h('li', null, n))) : null,
        h('div', { class: 'ws-start-row' }, start, cmdLine('doz workspace start ' + d.name))].filter(Boolean) }));
  }
  if (!d.rooms.length) notes.push(callout('info', { compact: true, title: 'No room yet', body: cmdLine('doz workspace edit ' + d.name + ' --make-room') }));
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
