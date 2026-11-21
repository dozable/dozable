// views/ws-home — A workspace's Home tab (#/w/NAME, the page's default): the workspace drawn (its space file's picture,
// live and read-only — a click opens the full window; a plain one says how one draws it), then its cards, each linking
// to the tab that holds the whole of it: Needs you (only when something waits — the setting-up checklist and Start, its
// rooms' open asks, an agent blocked or in error), State and run, Who, The room (its last two messages), Recent activity,
// Folders, Network. Drawn from what views/workspace.js already read (the workspace, its log); two reads of its own while
// it is the tab — the main room's last two messages and the open asks (GET /api/v1/chat/asks) — on arrival, hello,
// `changed` and an operation's end, and, while chat's stream happens to be open, on a new message or an ask's change.
// Never on a timer; it never opens the stream. Asks are answered only in the room's decision card.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-4b89ba3d74057e14.js';
import { askName, onAskChange } from '../core/asks-17ee0e03d84ce987.js';
import { full, when } from '../core/format-b2e68384da8d2f36.js';
import { isRemote } from '../core/session-32b26efd4b3dc47f.js';
import { lineText } from '../core/ws-log-725b407c6811cd6c.js';
import { activityHash, agentHash, agentsHash, foldersHash, networkHash, roomHash, runsHash } from '../core/routes-9e8c2eeae9c6e070.js';
import { state } from '../core/state-67e05db59fafd5df.js';
import { LIFECYCLE, primaryVerb } from '../core/ws-lifecycle-54187500e950c88c.js';
import { cmdLine } from '../components/cmd-line-be6be849d82e80b8.js';
import { onPreview } from '../components/chat-unread-12bb6f8f35e1c2b3.js';
import { heroNone, spaceHero } from '../components/space-picture-d45b196392c06203.js';
import { wsCard } from '../components/ws-card-feff31ac1cb2dd1e.js';
import { gapsList } from '../components/ws-gaps-1cce6f6aaeda94a1.js';
import { lifecycleCommand, lifecycleRefusal, openLifecycle, transitional } from '../components/ws-lifecycle-4bfc5bc84c8f8bb6.js';
import { driverChip, managerChip, workspacePill } from '../components/ws-marks-26369af31d4dbb6f.js';
import { agentsBox, foldersBox, networkBox } from '../components/ws-panel-c78c63139bdf4333.js';

const ACTIVITY_LINES = 5;
let cur = null;          // {name, host, heroSlot, needs, cards, o, asks, last, asOf}
let hero = null;         // the workspace drawn, built once per workspace
let readGen = 0;

const shown = () => !!cur && state.view === 'workspace' && state.wsTab === 'home' && state.param === cur.name && !cur.host.hidden;
const mainOf = (d) => d.rooms.find((r) => r.main) || null;
const roomsOf = (d) => new Set(d.rooms.map((r) => r.room));

/// Draw Home into `host` from `o` {detail, lines, logHidden, startButton(), onLifecycle, onChatOn}; `read`: its own two
/// reads again (arrival, hello, `changed`, an operation's end — never a redraw of what is already known).
export function homeTab(o, host, read) {
  const d = o.detail;
  if (!cur || cur.name !== d.name || cur.host !== host) {
    homeDispose();
    const heroSlot = h('div', { class: 'ws-home-pic' }), needs = h('div', { class: 'ws-home-needs' }), cards = h('div', { class: 'ws-cards' });
    host.replaceChildren(h('div', { class: 'ws-home', 'data-ws-home': d.name }, heroSlot, needs, cards));
    cur = { name: d.name, host, heroSlot, needs, cards, o, asks: null, last: null, asOf: null };
  }
  cur.o = o;
  paintHero(d);
  paint();
  if (read) readMore();
}

/// Leaving the workspace (another one opened): the drawing let go.
export function homeDispose() {
  if (hero) { hero.dispose(); hero = null; }
  cur = null;
}

/// The workspace drawn from its space file and its live state (redrawn only when what it shows changed), or — made
/// without a file — the compact band that says how one draws it.
function paintHero(d) {
  const slot = cur.heroSlot;
  if (!d.space) {
    if (hero) { hero.dispose(); hero = null; }
    if (!slot.querySelector('[data-ws-hero-none]')) slot.replaceChildren(heroNone(d.name));
    return;
  }
  const o = { name: d.name, file: d.space.file, edit: !isRemote() };
  if (!hero) { hero = spaceHero(o); slot.replaceChildren(hero.el); } else hero.set(o);
}

function paint() {
  const { detail: d } = cur.o;
  const needs = needsCard(d);
  cur.needs.replaceChildren(...(needs ? [needs] : []));
  cur.cards.replaceChildren(stateCard(d), whoCard(d), roomCard(d), activityCard(d), wsCard({ id: 'folders', title: 'Folders', icon: 'folder',
    href: foldersHash(d.name), linkLabel: 'Folders & points', count: d.folders.length, body: foldersBox(d, { compact: true }) }),
  wsCard({ id: 'network', title: 'Network', icon: 'shield', href: networkHash(d.name), linkLabel: 'Network & secrets', body: networkBox(d, { compact: true }) }));
}

/// Needs you: what waits on you here — null when nothing does (the card is not drawn).
function needsCard(d) {
  const items = [];
  if (d.state === 'setting-up') {
    const gaps = d.gaps || [];
    items.push(h('div', { class: 'ws-home-setup', 'data-ws-setup': String(gaps.length) },
      h('p', { class: 'ws-home-lead' }, h('b', null, 'Setting up'), ' — the work starts once it is fully set up'),
      gaps.length ? gapsList(gaps, { onChatOn: cur.o.onChatOn }) : h('p', { class: 'muted' }, 'Nothing is missing: it can start.'),
      h('div', { class: 'ws-start-row' }, cur.o.startButton(), cmdLine('doz workspace start ' + d.name))));
  }
  if (d.notes.length) items.push(h('ul', { class: 'hm-gaps', 'data-ws-home-notes': '' }, ...d.notes.map((n) => h('li', null, n))));
  const asks = (cur.asks || []).filter((x) => roomsOf(d).has(x.room));
  if (asks.length) items.push(h('ul', { class: 'ws-home-list', 'data-ws-home-asks': String(asks.length) }, ...asks.map((x) => askLine(d, x))));
  const stuck = d.agents.filter((a) => a.activity === 'blocked' || a.activity === 'error' || a.state === 'failed');
  if (stuck.length) {
    items.push(h('ul', { class: 'ws-home-list', 'data-ws-home-stuck': String(stuck.length) }, ...stuck.map((a) => h('li', { 'data-ws-stuck': a.name },
      icon('triangle-alert'), h('a', { href: agentHash(d.name, a.name) }, a.name),
      a.activity === 'blocked' ? ' is blocked' : a.state === 'failed' ? ' failed' : ' ended in error', ' · ',
      h('a', { href: agentsHash(d.name) }, 'Agents')))));
  }
  if (!items.length) return null;
  return wsCard({ id: 'needs', title: 'Needs you', icon: 'bell', tone: 'needs', body: [...items, asOf()] });
}

/// One open ask: #N, who asks, its question's first line, when it expires — and the room, where its card answers it.
function askLine(d, x) {
  const m = x.message || {}, a = m.ask || {};
  const wr = d.rooms.find((r) => r.room === x.room);
  const q = String(a.question || m.content || '').split('\n')[0].slice(0, 160);
  return h('li', { class: 'ws-home-ask', 'data-ws-home-ask': m.msg_id || '' },
    icon('info'), h('b', null, askName(m)), ' ', h('span', { class: 'muted' }, (m.from || '') + ' asks: '), q,
    a.expires_at ? h('span', { class: 'muted', title: full(a.expires_at) }, ' · expires ' + when(a.expires_at)) : null, ' ',
    h('a', { href: roomHash(d.name, wr && !wr.main ? wr.label : null), class: 'btn sm', 'data-ws-home-answer': x.room }, icon('message-square'), 'Answer in the room'));
}

/// "as of HH:MM" while chat's stream is closed: the asks and the room's lines are as last read.
function asOf() {
  if (!cur.asOf || state.chat.live === 'live') return null;
  return h('p', { class: 'ws-home-asof muted' }, 'as of ' + cur.asOf.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));
}

function stateCard(d) {
  const since = d.archivedAt ? ['archived', d.archivedAt] : d.finishedAt ? ['finished', d.finishedAt] : d.startedAt ? ['started', d.startedAt] : ['made', d.createdAt];
  const s = d.space;
  const space = s ? h('p', { class: 'ws-space-line muted', 'data-ws-space': s.file }, 'Defined by ', h('code', null, s.file), ' ',
    h('span', { class: 'pill ' + (s.up ? 'st-ok' : 'st-off'), 'data-ws-space-pill': s.up ? 'up' : 'down' },
      s.up ? 'up' + (s.run ? ' · run ' + s.run : '') + (s.runSince ? ' since ' + new Date(s.runSince).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '') : 'down')) : null;
  // Its verbs beside the page's own: not the head's primary (it is there), not Archive or Delete (⋯ keeps them).
  const primary = primaryVerb(d.state), why = lifecycleRefusal(), busy = transitional(d.name);
  const verbs = ['stop', 'sleep', 'wake', 'finish', 'reopen', 'restore'].filter((v) => v !== primary && fits(d, v)).map((verb) => {
    const v = LIFECYCLE[verb];
    return h('button', { type: 'button', class: 'btn sm', 'data-ws-home-verb': verb, disabled: why || busy ? true : null,
      title: why ? why + ' — ' + lifecycleCommand(verb, d.name) : v.desc, on: { click: () => openLifecycle(d, verb, cur.o.onLifecycle) } }, icon(v.icon), v.label);
  });
  return wsCard({ id: 'state', title: 'State and run', icon: 'activity', href: runsHash(d.name), linkLabel: 'Runs', body: [
    h('p', { class: 'ws-home-state' }, workspacePill(d.state, d.words, busy), h('span', { class: 'muted', title: full(since[1]) }, ' ' + since[0] + ' ' + when(since[1]))),
    space,
    h('div', { class: 'ws-home-acts' }, ...verbs, h('a', { href: runsHash(d.name), class: 'btn sm quiet' }, icon('history'), 'Runs'))] });
}

/// Whether a verb means anything in the workspace's state (the dialog's plan says the rest).
function fits(d, verb) {
  const done = d.state === 'finished' || d.state === 'archived';
  if (verb === 'stop') return !done && d.agents.some((a) => a.role === 'manager');
  if (verb === 'sleep') return !done && d.state !== 'asleep' && d.state !== 'setting-up';
  if (verb === 'wake') return d.state === 'asleep';
  if (verb === 'finish') return !done && d.state !== 'setting-up';
  if (verb === 'reopen') return d.state === 'finished';
  return verb === 'restore' && d.state === 'archived';
}

function whoCard(d) {
  const m = d.agents.find((a) => a.role === 'manager');
  const chip = m ? managerChip({ isolation: m.isolation || 'fenced', actsAsYou: m.actsAsYou, state: m.state,
    words: (m.bot || m.name) + ' (' + (m.actsAsYou ? 'unfenced · acts as you' : m.isolation || 'fenced') + ')' }) : null;
  return wsCard({ id: 'who', title: 'Who', icon: 'bot', href: agentsHash(d.name), linkLabel: 'Agents', count: d.agents.length, body: [
    h('p', { class: 'ws-home-who' }, h('span', { class: 'muted' }, 'Driven by '), driverChip(d.driver), chip ? h('span', { class: 'muted' }, ' · managed by ') : null, chip),
    agentsBox(d, { compact: true, mainRoom: mainOf(d) ? mainOf(d).room : null })] });
}

function roomCard(d) {
  const main = mainOf(d);
  const lines = !main ? [h('p', { class: 'muted' }, 'No room yet — the Room tab makes one.')]
    : cur.last === null ? [h('p', { class: 'muted' }, state.chat.status && state.chat.status.state === 'running' ? 'reading…' : 'Chat is not running here.')]
      : cur.last.length ? cur.last.map(messageLine) : [h('p', { class: 'muted' }, 'Nothing said yet.')];
  return wsCard({ id: 'room', title: main ? '# ' + main.room : 'The room', icon: 'message-square', href: roomHash(d.name), linkLabel: 'Room',
    count: d.rooms.length > 1 ? d.rooms.length : null, body: [h('div', { class: 'ws-home-msgs', 'data-ws-home-msgs': cur.last ? String(cur.last.length) : '' }, ...lines),
      main ? asOf() : null] });
}

/// A message as Home shows it: who, its first words, when — a direct message, an ask or a deleted one by what it is.
function messageLine(m) {
  const text = m.deleted ? 'a message was deleted' : m.kind === 'private' ? 'a direct message'
    : m.kind === 'ask' ? 'asks: ' + String((m.ask && m.ask.question) || m.content || '').split('\n')[0] : String(m.content || '').replace(/\s+/g, ' ').trim();
  const at = +m.at ? new Date(m.at * 1000).toISOString() : null;
  return h('p', { class: 'hm-line', 'data-ws-home-msg': m.msg_id || '' }, h('b', null, (m.from || '') + ': '), text.slice(0, 160),
    at ? h('span', { class: 'hm-age' }, ' · ' + when(at)) : null);
}

function activityCard(d) {
  const { lines, logHidden } = cur.o;
  const you = state.chat.status && state.chat.status.named;
  const recent = (lines || []).slice(-ACTIVITY_LINES).reverse();
  return wsCard({ id: 'activity', title: 'Recent activity', icon: 'list', href: activityHash(d.name), linkLabel: 'Activity', body: [
    recent.length ? h('ul', { class: 'ws-home-log' }, ...recent.map((l) => h('li', null, h('span', { class: 'hm-age', title: full(l.at) }, when(l.at) + ' · '), lineText(l, you))))
      : h('p', { class: 'muted' }, 'Nothing yet.'),
    logHidden ? h('p', { class: 'muted' }, logHidden + ' of its log’s lines are about sessions on this Mac and are not shown to this browser.') : null] });
}

/// Home's own reads: the main room's last two messages and the open asks — only while chat runs and this browser may read.
async function readMore() {
  if (!cur) return;
  const gen = ++readGen, d = cur.o.detail, main = mainOf(d);
  const st = state.chat.status;
  if (!st || st.state !== 'running') { cur.last = null; cur.asks = null; paint(); return; }
  const [last, asks] = await Promise.all([
    main ? api('chat/rooms/' + main.room + '/messages?limit=2').catch(() => null) : null,
    api('chat/asks').catch(() => null)]);
  if (!cur || gen !== readGen || cur.name !== d.name) return;
  cur.last = Array.isArray(last) ? last : main ? [] : null;
  cur.asks = Array.isArray(asks) ? asks : null;
  cur.asOf = new Date();
  paint();
}

// While chat's stream happens to be open (the Room tab was visited), a new message or an ask's change here reads again.
let soon = 0;
function again(room) {
  if (!shown() || (room && !roomsOf(cur.o.detail).has(room)) || soon) return;
  soon = 1;
  queueMicrotask(() => { soon = 0; readMore(); });
}
onAskChange(() => again(null));
onPreview(again);
