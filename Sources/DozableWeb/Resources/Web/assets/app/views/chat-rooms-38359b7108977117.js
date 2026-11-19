// views/chat-rooms — the rooms the person is in (archived ones grouped below), and opening one.
import { state } from '../core/state-58b070d3f17c1c53.js';
import { canWrite, getJSON, viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { loadDraft, saveDraft } from '../components/chat-composer-box-b0d21047d10349a7.js';
import { endEdit } from '../components/chat-edit-276f5d437cd3c571.js';
import { showDown } from '../components/chat-log-48335b1e40e3a34f.js';
import { showPreviews, showUnread } from '../components/chat-unread-40ec2368b8ae2956.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { fill } from './chat-messages-4ba31a42bd30e58e.js';
import { people } from './chat-people-aa98c40dbb249586.js';

/// The rooms the chat server shows the person: those they are in.
export const mine = (r) => !viewer() || ((state.chat.srv.rooms[r] || []).includes(viewer()));

export function drawRooms() {
  const box = $('chat-rooms');
  if (!box || !state.chat.srv) return;
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

/// Show room `r`: its draft, its log from the newest page, its people.
export async function openRoom(r) {
  if (!state.chat.srv) return;
  endEdit();
  saveDraft();
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
  $('chat-room-name').textContent = r;
  const arch = (state.chat.srv.archived || []).includes(r);
  const ro = !canWrite();
  for (const id of ['chat-text', 'chat-clip', 'chat-send']) $(id).disabled = arch || ro;
  $('chat-text').placeholder = ro ? 'This browser may read chat only' : arch ? 'This room is archived: read-only.' : 'Message ' + r;
  loadDraft();
  showDown();
  drawRooms();
  await fill();
  people();
}
