// views/chat-rooms — the rooms the person is in (archived ones grouped below), and opening one. On a workspace's page
// (state.chat.scope) only that workspace's rooms, by their short labels, each its workspace address, and "+ room".
import { state } from '../core/state-1036883eb74b9520.js';
import { canWrite, getJSON, viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { loadDraft, saveDraft } from '../components/chat-composer-box-0bd02e4fca9e7f89.js';
import { closeDrawer } from '../components/chat-drawers-b5519cc89145589b.js';
import { endEdit } from '../components/chat-edit-1bf1f8cfe9545a5b.js';
import { showDown } from '../components/chat-log-e1b72169c7992e47.js';
import { showPreviews, showUnread } from '../components/chat-unread-9284e62b88511529.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { fill } from './chat-messages-064817e790adaeff.js';
import { chatWindowName, chatWindowPath } from '../core/routes-c03e6aed84ec9eb3.js';
import { people } from './chat-people-235cf30742bf403f.js';

/// The rooms the chat server shows the person: those they are in.
export const mine = (r) => !viewer() || ((state.chat.srv.rooms[r] || []).includes(viewer()));

/// How a room is named where it is shown: on a workspace's page `# label` (the main room by its own name), else its name.
export function roomTitle(r) {
  const sc = state.chat.scope, wr = sc && sc.rooms.find((x) => x.room === r);
  return wr ? '# ' + (wr.main ? wr.room : wr.label) : r;
}

/// A workspace's rooms as a strip: the ones the person is in, each its address (#/w/W, #/w/W/room/LABEL), then "+ room"
/// (drawn, not working: another room is made with a command that comes later).
function drawScoped(box, sc) {
  const kids = sc.rooms.filter((wr) => state.chat.srv.rooms[wr.room] && mine(wr.room)).map((wr) => {
    const on = wr.room === state.chat.room;
    return h('a', { class: 'chat-rm' + (on ? ' is-on' : ''), href: sc.address(wr), 'data-room': wr.room, 'data-ws-label': wr.main ? '' : wr.label,
      'aria-current': on ? 'page' : null },
      h('span', { class: 'chat-r1' }, h('span', { class: 'chat-rname' }, roomTitle(wr.room)), h('span', { class: 'chat-n', hidden: true }),
        h('span', { class: 'chat-rt', hidden: true })), h('span', { class: 'chat-pv', hidden: true }));
  });
  if (!kids.length) kids.push(h('p', { class: 'chat-empty' }, 'You are in none of its rooms.'));
  kids.push(h('button', { type: 'button', class: 'btn sm quiet chat-rm-add', disabled: true, 'aria-disabled': 'true',
    title: 'Another room for this workspace — coming: for now every agent talks in its main room' }, '+ room'));
  box.replaceChildren(...kids);
  showUnread();
}

export function drawRooms() {
  const box = $('chat-rooms');
  if (!box || !state.chat.srv) return;
  if (state.chat.scope) { drawScoped(box, state.chat.scope); return; }
  const arch = state.chat.srv.archived || [], dflt = state.chat.srv.default_room;
  const names = Object.keys(state.chat.srv.rooms).filter(mine).sort((a, b) => (a === dflt ? -1 : b === dflt ? 1 : a.localeCompare(b)));
  const row = (r) => {
    const on = r === state.chat.room;
    return h('a', { class: 'chat-rm' + (arch.includes(r) ? ' is-archived' : '') + (on ? ' is-on' : ''), href: '#/chat/' + r, 'data-room': r,
      'aria-current': on ? 'page' : null },
      h('span', { class: 'chat-r1' }, h('span', { class: 'chat-rname' }, r), h('span', { class: 'chat-n', hidden: true }), h('span', { class: 'chat-rt' })),
      h('span', { class: 'chat-pv' }));
  };
  const kids = names.filter((r) => !arch.includes(r)).map(row);
  const old = names.filter((r) => arch.includes(r));
  if (old.length) kids.push(h('div', { class: 'chat-grp' }, 'Archived'), ...old.map(row));
  if (!names.length) kids.push(h('p', { class: 'chat-empty' }, 'You are in no room yet.'));
  box.replaceChildren(...kids);
  showUnread();
  showPreviews();
}

/// What the chat server says of rooms and people now (after a room changed), the rooms list and the shown room redrawn.
export async function refreshState() {
  try {
    const j = await getJSON('/state');
    state.chat.srv = j;
    drawRooms();
    state.chat.members = new Set((j.rooms[state.chat.room] || []).map((n) => n.toLowerCase()));
    people();
  } catch (_) { /* the next event tries again */ }
}

/// The head's pop-out: the room shown, as its window's address and name — hidden with no room, in the window itself and
/// while the notice stands instead of the room.
export function paintPop() {
  const a = $('chat-pop'), cols = $('chat-cols');
  if (!a) return;
  const r = state.chat.room;
  a.hidden = !r || !!state.chat.solo || !cols || cols.hidden;
  if (r) { a.href = chatWindowPath(r); a.target = chatWindowName(r); }
  if (state.chat.solo) document.title = (r || state.chat.solo) + ' — ' + SOLO_TITLE;
}
/// The chat window document's own title (the server names it for its Mac: "Chat – NAME").
const SOLO_TITLE = document.title;

/// Show room `r`: its draft, its log from the newest page, its people (null: none — a workspace with no room of the person's).
export async function openRoom(r) {
  if (!state.chat.srv) return;
  if (r !== state.chat.room) closeDrawer(false);   // a room opened from the rooms drawer closes it
  endEdit();
  saveDraft();
  if (!r) {
    state.chat.room = null;
    state.chat.byId = new Map();
    $('chat-log').replaceChildren();
    $('chat-room-name').textContent = '';
    paintPop();
    for (const id of ['chat-text', 'chat-clip', 'chat-send']) $(id).disabled = true;
    drawRooms();
    people();
    return;
  }
  state.chat.room = r;
  state.chat.byId = new Map();
  state.chat.lastSeq = 0;
  state.chat.firstSeq = 0;
  state.chat.older = true;
  state.chat.prev = new Map();
  state.chat.atFoot = true;
  state.chat.missed = 0;
  state.chat.members = new Set((state.chat.srv.rooms[r] || []).map((n) => n.toLowerCase()));
  delete state.chat.unread[r];
  $('chat-log').replaceChildren();
  $('chat-room-name').textContent = roomTitle(r);
  paintPop();
  const arch = (state.chat.srv.archived || []).includes(r);
  // A closed room (its workspace is finished): readable, the composer off until the workspace is reopened.
  const closedBy = !arch ? (state.chat.srv.closed || {})[r] : null;
  const ro = !canWrite();
  for (const id of ['chat-text', 'chat-clip', 'chat-send']) $(id).disabled = arch || !!closedBy || ro;
  $('chat-text').placeholder = ro ? 'This browser may read chat only' : arch ? 'This room is archived: read-only.'
    : closedBy ? 'Closed: its workspace ' + closedBy + ' is finished. Reopen it to post' : 'Message ' + r;
  $('chat-text').dataset.closed = closedBy || '';
  loadDraft();
  showDown();
  drawRooms();
  await fill();
  people();
}
