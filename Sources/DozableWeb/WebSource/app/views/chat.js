// views/chat — the Chat page (#/chat, #/chat/ROOM): a section of its own (#chat, like This Mac), built ONCE, so a live
// refresh never tears down the composer or the reader's place. Chat is the chat server's (`doz chat`); the page never
// turns it on — while it is off, the command to run is shown. Shown in this Mac's own browser only (the server refuses
// another computer every chat route, and the sidebar's entry stays hidden there).
import { state } from '../core/state.js';
import { apiFetch } from '../core/api.js';
import { getJSON } from '../core/chat-api.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { showDown, toFoot } from '../components/chat-log.js';
import { loadUnread, showUnread } from '../components/chat-unread.js';
import { $, h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { initComposer } from './chat-composer.js';
import { loadOlder } from './chat-messages.js';
import { loadPresence, standing } from './chat-people.js';
import { drawRooms, mine, openRoom } from './chat-rooms.js';
import { startLive, stopLive } from './chat-live.js';

let built = false, loaded = false, statusT = 0, wanted = null, loading = false;

function build() {
  if (built) return;
  built = true;
  const log = h('div', { class: 'chat-log', id: 'chat-log', role: 'log', 'aria-label': 'Messages', tabindex: '0' });
  const text = h('textarea', { class: 'chat-text', id: 'chat-text', rows: '1', 'aria-label': 'Message', 'aria-autocomplete': 'list', 'aria-describedby': 'chat-note',
    'aria-controls': 'chat-cmds', 'aria-expanded': 'false', placeholder: 'Message the room' });
  const send = btn('Send', () => {}, { primary: true, icon: 'arrow-right' });
  send.id = 'chat-send';
  send.type = 'submit';
  $('chat').replaceChildren(
    h('div', { class: 'chat-head' }, h('h1', { class: 'chat-title' }, icon('message-square'), 'Chat'),
      h('span', { class: 'chat-room-name', id: 'chat-room-name' }), h('span', { class: 'chat-live is-off', id: 'chat-live', role: 'status' }, 'not connected')),
    h('div', { class: 'chat-notice', id: 'chat-notice' }),
    h('div', { class: 'chat-cols', id: 'chat-cols', hidden: true },
      h('nav', { class: 'chat-pane chat-rooms-pane', 'aria-label': 'Rooms' }, h('h2', { class: 'chat-sh' }, 'Rooms'), h('div', { class: 'chat-rooms', id: 'chat-rooms' })),
      h('div', { class: 'chat-center' },
        log,
        h('div', { class: 'chat-downwrap' }, h('button', { type: 'button', class: 'chat-down', id: 'chat-down', hidden: true })),
        h('div', { class: 'chat-busy', id: 'chat-busy', 'aria-live': 'polite' }),
        h('form', { class: 'chat-form', id: 'chat-form' },
          h('div', { class: 'chat-cmds', id: 'chat-cmds', role: 'listbox', 'aria-label': 'Suggestions', hidden: true }), text, send),
        h('p', { class: 'chat-note', id: 'chat-note', 'aria-live': 'polite' })),
      h('aside', { class: 'chat-pane chat-people-pane', 'aria-label': 'People in this room' },
        h('h2', { class: 'chat-sh' }, icon('users'), 'In this room', h('span', { class: 'chat-sh-n', id: 'chat-people-count' })),
        h('div', { class: 'chat-people', id: 'chat-people' }))));
  log.addEventListener('scroll', () => {
    const was = state.chat.atFoot;
    state.chat.atFoot = log.scrollHeight - log.scrollTop - log.clientHeight < 80;
    if (state.chat.atFoot) state.chat.missed = 0;
    if (was !== state.chat.atFoot || state.chat.atFoot) showDown();
    if (log.scrollTop < 120) loadOlder();
  }, { passive: true });
  $('chat-down').addEventListener('click', toFoot);
  initComposer();
  setInterval(() => { if (state.chat.active && state.chat.srv) standing(); }, 20000);
}

/// What the page says instead of chat while it cannot be used (off, starting, failing, no daemon, another computer).
function notice(st) {
  const box = $('chat-notice'), cols = $('chat-cols');
  const say = (tone, title, body, extra) => { cols.hidden = true; box.replaceChildren(callout(tone, { title, body: [body, extra].filter(Boolean) })); };
  const cmd = (t) => h('code', { class: 'chat-cmdline' }, t);
  switch (st.state) {
    case 'off': say('info', 'Chat is off', h('span', null, 'Turn it on in a terminal: ', cmd('doz chat on --name YOUR-NAME'))); break;
    case 'starting': say('info', 'Chat is starting…', 'This page looks again every few seconds.'); break;
    case 'no-daemon': say('warn', "Dozable's daemon is not running", h('span', null, 'Chat runs under it. In a terminal: ', cmd('doz daemon start'))); break;
    case 'failing': say('bad', 'Chat is not running', st.problem || 'Its server stopped.', h('span', null, 'In a terminal: ', cmd('doz chat status'))); break;
    case 'remote': say('info', 'Chat is shown only on this Mac', "Open the dashboard in this Mac's own browser to see chat."); break;
    default: box.replaceChildren(); cols.hidden = false; return true;
  }
  return false;
}

async function readStatus() {
  try {
    const r = await apiFetch('chat/status');
    if (r.status === 403) return { state: 'remote' };
    if (!r.ok) return { state: 'failing', problem: 'the dashboard answered ' + r.status };
    return await r.json();
  } catch (_) { return { state: 'failing', problem: 'the dashboard did not answer' }; }
}

/// Load what the chat server says and show `room` (else the default room, else the first the person is in).
async function load(room) {
  if (loading) return;
  loading = true;
  try {
    state.chat.srv = await getJSON('/state');
    const human = (state.chat.srv.participants || []).find((p) => p.kind === 'human');
    state.chat.human = human ? human.name : null;
    drawRooms();
    const rooms = Object.keys(state.chat.srv.rooms).filter(mine), d = state.chat.srv.default_room;
    const r = room && rooms.includes(room) ? room : (d && rooms.includes(d) ? d : rooms[0]);
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
export async function chatEnter(room) {
  build();
  state.chat.active = true;
  wanted = room || null;
  clearTimeout(statusT);
  const st = await readStatus();
  state.chat.status = st;
  if (!state.chat.active) return;
  if (!notice(st)) {
    if (st.state === 'starting') statusT = setTimeout(() => chatEnter(wanted), 3000);
    stopLive(true);
    loaded = false;
    return;
  }
  if (!loaded) { await load(wanted); return; }
  if (wanted && wanted !== state.chat.room && mine(wanted)) await openRoom(wanted);
  else showUnread();
  startLive();
}

/// Leaving the page: its stream closes 5 s later.
export function chatLeave() {
  if (!state.chat.active) return;
  state.chat.active = false;
  clearTimeout(statusT);
  stopLive(false);
}

/// The router's refresh while on the page: look at the status again (nothing is torn down).
export function chatRefresh() { if (state.chat.active) chatEnter(wanted); }

/// The sidebar's Chat entry: shown while chat is on (asked on hello and every minute); its badge, the unread elsewhere.
export async function chatNavCheck() {
  const st = await readStatus();
  state.chat.on = st.state !== 'off' && st.state !== 'remote';
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
