// components/bot-invite — "Add to a room…": an Agent / Bot brought into a room as a voice — it reads and speaks there, with
// no grants and no token step. It is the chat server's own `/invite @NAME`, posted as you through the chat post route
// (POST /api/v1/chat/rooms/ROOM/messages — `serve.chat` decides who may), never an action or a daemon operation: a bot is
// already a participant, so including it is a tick in a list. From a room (its people's menu: which bot?) and from a bot's
// ⋯ (which room?).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { api } from '../core/api-496fd9f39af2a514.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { loadBots } from '../core/workspaces-07036f2cf12d8805.js';
import { dialog } from './dialog-bae4e8002b142b21.js';
import { toast } from './notices-0c2ff2db323bba12.js';

const VOICE = 'It joins as a voice: it reads and speaks in the room, with no grants there and no token step.';

/// The chat server's rooms and who is in each (`GET /api/v1/chat/state`), or null while chat is off or not readable here.
export async function chatRooms() {
  const st = state.chat.status;
  if (!st || st.state !== 'running') return null;
  try { return await api('chat/state'); } catch (_) { return null; }
}

/// Post `/invite @bot` in `room` as you; the chat server's refusal is said.
export async function inviteBot(room, bot) {
  const r = await api('chat/rooms/' + encodeURIComponent(room) + '/messages', { method: 'POST', json: { content: '/invite @' + bot } });
  if (r && r.state === 'refused') throw new Error(r.detail || 'the chat server refused it');
  toast(bot + ' was invited to #' + room + ' — as a voice');
}

function chatOffNote() {
  toast('Chat is off, or not shared with this browser — in a terminal on this Mac: doz chat send ROOM "/invite @NAME"', true);
}

/// From a bot's ⋯ (and its screen): which room? Every room it is not in.
export async function includeInRoom(bot) {
  const s = await chatRooms();
  if (!s) { chatOffNote(); return; }
  const archived = new Set(s.archived || []);
  const rooms = Object.keys(s.rooms || {}).filter((r) => !archived.has(r) && !(s.rooms[r] || []).includes(bot)).sort();
  if (!rooms.length) { toast(bot + ' is in every room already'); return; }
  dialog('Include ' + bot + ' in a room', VOICE, [{ name: 'room', label: 'The room', type: 'select', options: rooms.map((r) => [r, '#' + r]) }],
    'Invite', async (v) => inviteBot(v.room, bot), { icon: 'users' });
}

/// From a room's menu: which Agent / Bot? Every bot not in the room.
export async function addBotToRoom(room) {
  const [s, b] = await Promise.all([chatRooms(), loadBots(1000).catch(() => null)]);
  if (!s) { chatOffNote(); return; }
  const members = new Set((s.rooms && s.rooms[room]) || []);
  const bots = (b ? b.bots : []).filter((x) => !members.has(x.name) && x.inChat);
  if (!bots.length) { toast('Every Agent / Bot is in #' + room + ' already'); return; }
  const list = h('p', { class: 'muted' }, 'or type /invite @NAME in the room.');
  dialog('Add an Agent / Bot to #' + room, VOICE,
    [{ name: 'bot', label: 'The Agent / Bot', type: 'select', options: bots.map((x) => [x.name, x.name + (x.manages.length ? ' · manages ' + x.manages.join(', ') : '')]) },
     { name: 'or', type: 'custom', el: list, get: () => null }],
    'Add', async (v) => inviteBot(room, v.bot), { icon: 'users' });
}
