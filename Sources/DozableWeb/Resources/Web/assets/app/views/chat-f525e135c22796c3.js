// views/chat — the Chat page (#/chat, #/chat/ROOM): a section of its own (#chat, like This Mac), built ONCE, so a live
// refresh never tears down the composer or the reader's place. The room surface it builds (the head, the notice, the
// rooms, the log with its composer, the people) is the ONE chat client: a workspace's page shows it too — `mountChat`
// MOVES the same subtree into the workspace page's room and back, scoped to that workspace's rooms; never a second fetch
// path, stream or composer. Chat is the chat server's (`doz chat`); the page never
// turns it on — while it is off, the command to run is shown. Shown in this Mac's own browser only (the server refuses
// another computer every chat route, and the sidebar's entry stays hidden there).
// A room pops out into a window of its own (`/chat#/ROOM`, chat.js — `chatWindow`): the same surface, that room alone.
import { state } from '../core/state-1036883eb74b9520.js';
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { apiFetch } from '../core/api-47cfabfed13b475c.js';
import { getJSON } from '../core/chat-api-ec968582d97ebdcb.js';
import { btn } from '../components/button-030d384b64f8d75d.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { chatOnForm, rememberChatStatus } from '../components/chat-on-9a75307516e1fcf5.js';
import { closeDrawer, drawer, drawerScrim } from '../components/chat-drawers-b5519cc89145589b.js';
import { showDown, toFoot } from '../components/chat-log-1fc6c219d594a8e3.js';
import { CHAT_READ_ONLY, chatNote } from '../components/chat-note-95e0cc435178e0d8.js';
import { loadUnread, showUnread } from '../components/chat-unread-9284e62b88511529.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { openOwnWindow } from '../core/windows-392fe33565b4f8f7.js';
import { chatWindowName, chatWindowPath } from '../core/routes-c03e6aed84ec9eb3.js';
import { initComposer } from './chat-composer-daad80d7e1fe30b1.js';
import { loadOlder, watchTaps } from './chat-messages-f361e16efe39277b.js';
import { loadPresence, roomMenu, standing } from './chat-people-aa4e8e6ae724e58f.js';
import { drawRooms, mine, openRoom, paintPop, refreshState } from './chat-rooms-36692d733c3728ed.js';
import { startLive, stopLive } from './chat-live-9800fdc96dff1a78.js';

let built = false, loaded = false, statusT = 0, wanted = null, loading = false, scopeKey = '';

function build() {
  if (built) return;
  built = true;
  const log = h('div', { class: 'chat-log', id: 'chat-log', role: 'log', 'aria-label': 'Messages', tabindex: '0' });
  const text = h('textarea', { class: 'chat-text', id: 'chat-text', rows: '1', 'aria-label': 'Message', 'aria-autocomplete': 'list', 'aria-describedby': 'chat-note',
    'aria-controls': 'chat-cmds', 'aria-expanded': 'false', placeholder: 'Message the room' });
  const send = btn('Send', () => {}, { primary: true, icon: 'arrow-right' });
  send.id = 'chat-send';
  send.type = 'submit';
  // Attach (the clip; a paste or a drop does the same): a file chooser that is never shown, opened by the clip.
  const clip = h('button', { type: 'button', class: 'chat-ibtn chat-clip', id: 'chat-clip', title: 'Attach files (or paste or drop them) — at most 20 MB each',
    'aria-label': 'Attach files' }, icon('paperclip'));
  const pick = h('input', { type: 'file', id: 'chat-pick', multiple: true, hidden: true, tabindex: '-1', 'aria-hidden': 'true' });
  const editx = h('button', { type: 'button', class: 'chat-ibtn', id: 'chat-editx', title: 'Stop editing (Esc)', 'aria-label': 'Stop editing' }, icon('x'));
  // The pop-out: the room shown, in a window of its own (one per room — a second click brings it forward). A plain click
  // opens the window; a modified click is the link's (a new tab).
  const pop = h('a', { class: 'btn sm quiet icon-only chat-pop', id: 'chat-pop', href: '/chat', hidden: true,
    title: 'Open this room in its own window', 'aria-label': 'Open this room in its own window' }, icon('external-link'));
  pop.addEventListener('click', (ev) => {
    const r = state.chat.room;
    if (!r || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
    if (openOwnWindow(chatWindowPath(r), chatWindowName(r), { w: 440, h: 760 })) ev.preventDefault();
  });
  // The chat window's way back: this room in the dashboard (a new tab). At phone width its icon alone (its label kept).
  const dash = h('a', { class: 'btn sm quiet chat-dash', id: 'chat-dash', href: '/#/chat', target: '_blank', rel: 'noopener', hidden: true,
    'aria-label': 'Open in the dashboard' }, icon('house'), h('span', { class: 'chat-dash-label' }, 'Open in the dashboard'));
  // The side panes' toggles: where a pane does not fit beside the log it is a drawer (components/chat-drawers.js) — the
  // people below 1101 px, the rooms at phone width (the Chat page's only: a workspace's Room tab keeps its strip).
  const roomsBtn = h('button', { type: 'button', class: 'btn sm quiet icon-only chat-pane-btn chat-rooms-btn', id: 'chat-rooms-btn', title: 'Rooms',
    'aria-label': 'Rooms' }, icon('list'));
  const peopleBtn = h('button', { type: 'button', class: 'btn sm quiet chat-pane-btn chat-people-btn', id: 'chat-people-btn', title: 'People in this room',
    'aria-label': 'People in this room' }, icon('users'), h('span', { class: 'chat-people-n', id: 'chat-people-n' }));
  const roomsPane = h('nav', { class: 'chat-pane chat-rooms-pane', id: 'chat-rooms-pane', 'aria-label': 'Rooms' }, h('h2', { class: 'chat-sh' }, 'Rooms'),
    h('div', { class: 'chat-rooms', id: 'chat-rooms' }));
  const peoplePane = h('aside', { class: 'chat-pane chat-people-pane', id: 'chat-people-pane', 'aria-label': 'People in this room' },
    h('h2', { class: 'chat-sh' }, icon('users'), 'In this room', h('span', { class: 'chat-sh-n', id: 'chat-people-count' })),
    h('div', { class: 'chat-people', id: 'chat-people' }));
  const surface = h('div', { class: 'chat-surface', id: 'chat-surface' },
    h('div', { class: 'chat-head' }, roomsBtn, h('h1', { class: 'chat-title' }, icon('message-square'), 'Chat'),
      h('span', { class: 'chat-room-name', id: 'chat-room-name' }), h('span', { class: 'chat-live is-off', id: 'chat-live', role: 'status' }, 'not connected'),
      h('span', { class: 'chat-head-sp' }), peopleBtn, h('span', { class: 'chat-room-tools', id: 'chat-room-tools' }), pop, dash),
    h('div', { class: 'chat-notice', id: 'chat-notice' }),
    h('div', { class: 'chat-cols', id: 'chat-cols', hidden: true },
      roomsPane,
      h('div', { class: 'chat-center' },
        log,
        h('div', { class: 'chat-downwrap' }, h('button', { type: 'button', class: 'chat-down', id: 'chat-down', hidden: true })),
        h('div', { class: 'chat-busy', id: 'chat-busy', 'aria-live': 'polite' }),
        h('form', { class: 'chat-form', id: 'chat-form' },
          h('div', { class: 'chat-cmds', id: 'chat-cmds', role: 'listbox', 'aria-label': 'Suggestions', hidden: true }),
          h('div', { class: 'chat-editbar', id: 'chat-editbar', hidden: true }, icon('pencil'), h('span', null, 'Editing your message — Enter saves, Esc stops'), editx),
          h('div', { class: 'chat-pend', id: 'chat-pend', hidden: true, 'aria-live': 'polite' }),
          h('div', { class: 'chat-inputs' }, clip, text, send), pick),
        h('p', { class: 'chat-note', id: 'chat-note', 'aria-live': 'polite' })),
      peoplePane),
    drawerScrim());
  $('chat').replaceChildren(surface);
  drawer(surface, 'rooms', roomsBtn, roomsPane);
  drawer(surface, 'people', peopleBtn, peoplePane);
  log.addEventListener('scroll', () => {
    const was = state.chat.atFoot;
    state.chat.atFoot = log.scrollHeight - log.scrollTop - log.clientHeight < 80;
    if (state.chat.atFoot) state.chat.missed = 0;
    if (was !== state.chat.atFoot || state.chat.atFoot) showDown();
    if (log.scrollTop < 120) loadOlder();
  }, { passive: true });
  $('chat-down').addEventListener('click', toFoot);
  watchTaps(log);
  initComposer();
  setInterval(() => { if (state.chat.active && state.chat.srv) standing(); }, 20000);
}

const refresh = upcall('refresh');

/// Chat came on from the page: the sidebar's entry, then the view read again (a workspace's page reads its gaps and room).
async function chatCameOn() {
  await chatNavCheck();
  if (state.view === 'chat') chatRefresh(); else refresh();
}

/// What the page says instead of chat while it cannot be used (off, starting, failing, no daemon, another computer).
function notice(st) {
  const box = $('chat-notice'), cols = $('chat-cols');
  const say = (tone, title, body, extra) => { cols.hidden = true; box.replaceChildren(callout(tone, { title, body: [body, extra].filter(Boolean) })); };
  const cmd = (t) => h('code', { class: 'chat-cmdline' }, t);
  switch (st.state) {
    case 'off':
      // Turned on here (this Mac's own browser), or in a terminal: then the page reads again — the room view loads.
      rememberChatStatus(st);
      say('info', 'Chat is off', chatOnForm({ status: st, onOn: chatCameOn }));
      break;
    case 'starting': say('info', 'Chat is starting…', 'This page looks again every few seconds.'); break;
    case 'no-daemon': say('warn', "Dozable's daemon is not running", h('span', null, 'Chat runs under it. In a terminal: ', cmd('doz daemon start'))); break;
    case 'failing': say('bad', 'Chat is not running', st.problem || 'Its server stopped.', h('span', null, 'In a terminal: ', cmd('doz chat status'))); break;
    case 'remote': say('info', 'Chat is not shared with this browser', h('span', null, 'Chat is off for your other browsers. On the Mac: ', cmd('doz config set serve.chat read'), ' (or write).')); break;
    default: box.replaceChildren(); cols.hidden = false; paintPop(); return true;
  }
  paintPop();
  return false;
}

/// The chat window's room is not one of the person's rooms here (a stale bookmark, a room removed): said, with the way to
/// the dashboard's Chat.
function soloMissing() {
  if (!state.chat.solo || candidates().length) return false;
  $('chat-cols').hidden = true;
  $('chat-notice').replaceChildren(callout('warn', { title: 'This room is not here',
    body: [h('span', null, '# ' + state.chat.solo + ' is not one of your rooms on this Mac. '),
      h('a', { href: '/#/chat', target: '_blank', rel: 'noopener', 'data-chat-dash': '' }, 'Open Chat in the dashboard')] }));
  paintPop();
  return true;
}

async function readStatus() {
  try {
    const r = await apiFetch('chat/status');
    if (r.status === 403) return { state: 'remote' };
    if (!r.ok) return { state: 'failing', problem: 'the dashboard answered ' + r.status };
    return await r.json();
  } catch (_) { return { state: 'failing', problem: 'the dashboard did not answer' }; }
}

/// Whether this browser may write (chat/status's access): a reading browser's composer and every control that changes
/// something are off, and the line under the box says why.
function writable() {
  const ro = state.chat.status && state.chat.status.access === 'read';
  const form = $('chat-form');
  form.classList.toggle('is-read-only', !!ro);
  for (const id of ['chat-text', 'chat-send', 'chat-clip']) $(id).disabled = !!ro;
  $('chat-text').placeholder = ro ? 'This browser may read chat only' : 'Message the room';
  $('chat-room-tools').replaceChildren(ro ? '' : roomMenu());
  if (ro) chatNote(CHAT_READ_ONLY);
}

/// The rooms this view may show: on a workspace's page its rooms only (the main one first), else every room.
function candidates() {
  if (state.chat.solo) return state.chat.srv.rooms[state.chat.solo] && mine(state.chat.solo) ? [state.chat.solo] : [];
  const sc = state.chat.scope;
  return sc ? sc.rooms.map((r) => r.room).filter((r) => state.chat.srv.rooms[r] && mine(r)) : Object.keys(state.chat.srv.rooms).filter(mine);
}

/// Load what the chat server says and show `room` (else the default room, else the first the person is in; on a
/// workspace's page, else its main room).
async function load(room) {
  if (loading) return;
  loading = true;
  try {
    state.chat.srv = await getJSON('/state');
    const human = (state.chat.srv.participants || []).find((p) => p.kind === 'human');
    state.chat.human = human ? human.name : null;
    drawRooms();
    const rooms = candidates(), d = state.chat.scope ? null : state.chat.srv.default_room;
    const r = room && rooms.includes(room) ? room : (d && rooms.includes(d) ? d : rooms[0]);
    soloMissing();
    await loadPresence();
    if (r) await openRoom(r);
    loadUnread();
    loaded = true;
    startLive();
  } catch (e) {
    notice({ state: e.code === 'chat-off' ? 'off' : 'failing', problem: e.message });
  } finally { loading = false; }
}

/// Arriving on #/chat[/ROOM].
export async function chatEnter(room) { return mountChat(null, null, room); }

/// The room surface into `host` — a workspace's page: {room, people} elements and its `scope` ({workspace, rooms, who,
/// sysLines}) — or back into the Chat page (`host` null), then `room` shown there. The subtree is moved, never built again:
/// the log, the composer and its draft, unread and the live stream are the Chat page's own. A change of scope always opens
/// the room again (a stale room or focus never survives the move).
export async function mountChat(host, scope, room) {
  build();
  const surface = $('chat-surface'), people = $('chat-people-pane');
  closeDrawer(false);
  if (host) {
    if (surface.parentNode !== host.room) host.room.append(surface);
    if (host.people && people.parentNode !== host.people) host.people.append(people);
  } else {
    if (surface.parentNode !== $('chat')) $('chat').append(surface);
    if (people.parentNode !== $('chat-cols')) $('chat-cols').append(people);
  }
  surface.classList.toggle('is-scoped', !!scope);
  const key = scope ? scope.workspace + ':' + scope.rooms.map((r) => r.room).join(',') : '';
  const moved = key !== scopeKey;
  scopeKey = key;
  state.chat.scope = scope || null;
  if (moved && loaded) { drawRooms(); state.chat.room = null; }
  return enter(room);
}

async function enter(room) {
  state.chat.active = true;
  wanted = room || null;
  clearTimeout(statusT);
  const st = await readStatus();
  state.chat.status = st;
  if (!state.chat.active) return;
  if (!notice(st)) {
    if (st.state === 'starting') statusT = setTimeout(() => enter(wanted), 3000);
    stopLive(true);
    loaded = false;
    return;
  }
  writable();
  if (!loaded) { await load(wanted); return; }
  if (soloMissing()) return;
  const rooms = candidates(), d = state.chat.srv.default_room;
  const first = state.chat.scope || !(d && rooms.includes(d)) ? rooms[0] : d;
  const r = wanted && rooms.includes(wanted) ? wanted : (state.chat.scope || !state.chat.room ? first : null);
  if (r && r !== state.chat.room) await openRoom(r);
  // Back in the same room: its state read again (it may have been closed, archived or opened meanwhile).
  else if (r && r === state.chat.room) { await refreshState(); await openRoom(r); }
  else if (!r && state.chat.scope) await openRoom(null);
  else showUnread();
  startLive();
}

/// The chat window (`/chat#/ROOM`): the Chat page's surface with that one room — no rooms pane, the way back to the
/// dashboard in its head. A change of the fragment opens another room in the same window.
export async function chatWindow(room) {
  build();
  const changed = state.chat.solo !== room;
  state.chat.solo = room;
  $('chat-surface').classList.add('is-solo');
  const dash = $('chat-dash');
  dash.href = '/#/chat/' + room;
  dash.hidden = false;
  if (changed) state.chat.room = null;
  return mountChat(null, null, room);
}

/// Leaving the page: its stream closes 5 s later.
export function chatLeave() {
  if (!state.chat.active) return;
  state.chat.active = false;
  clearTimeout(statusT);
  stopLive(false);
}

/// The router's refresh while on the page: look at the status again (nothing is torn down).
export function chatRefresh() { if (state.chat.active) enter(wanted); }

/// The sidebar's Chat entry: shown while chat is on (asked on hello and every minute); its badge, the unread elsewhere.
export async function chatNavCheck() {
  const st = await readStatus();
  state.chat.on = st.state !== 'off' && st.state !== 'remote';
  if (!state.chat.active) state.chat.status = st;          // Home reads a room's last line only while it runs
  const a = $('nav-chat');
  if (a) a.hidden = !state.chat.on;
  if (!state.chat.on || state.chat.active) return;
  if (st.state === 'running') {
    try {
      if (!state.chat.srv) state.chat.srv = await getJSON('/state');
      await loadUnread();
    } catch (_) { /* the next look tries again */ }
  }
}
