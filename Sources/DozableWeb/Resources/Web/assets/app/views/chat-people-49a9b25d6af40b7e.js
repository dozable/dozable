// views/chat-people — who is in the room shown: presence, the standing lines for those quiet now, and the lines when
// someone's state changes; the room's menu (hold agent-only chatter, your avatar). Both are the chat server's commands
// (/hold, /avatar), posted as you with a helper to choose — the server says what changed, in the room.
import { state } from '../core/state-58b070d3f17c1c53.js';
import { canWrite, chatError, getJSON, request, roomUrl, viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { cap, mins, time } from '../core/chat-format-bc877d395788e64c.js';
import { status } from '../components/chat-log-48335b1e40e3a34f.js';
import { chatNote } from '../components/chat-note-7d9b58ce10feea44.js';
import { dialog } from '../components/dialog-e39f089eb330ea6e.js';
import { menuButton } from '../components/menus-f405ee3ec6f0c314.js';
import { AVATAR_COLOURS, AVATAR_EMOJI, AVATAR_SHAPES, avatar } from '../dom/chat-avatar-afd4621f27e3492b.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

/// One of the chat server's commands, posted as the person in the room shown.
async function command(text, what) {
  try {
    const r = await request(roomUrl(state.chat.room, '/messages'), { method: 'POST', json: { content: text } });
    if (!r.ok) throw await chatError(r);
    const j = await r.json();
    if (j.state === 'refused') throw new Error(j.detail || 'refused');
    chatNote(what);
  } catch (e) { chatNote('Not done: ' + (e.message || e), true); }
}

/// Your avatar: a letter, a shape or an emoji, in a colour — sent as /avatar vendor:shape:colour. No picture from elsewhere.
export function avatarDialog() {
  const looks = [['initial', 'A letter'], ...AVATAR_SHAPES.map((s) => [s, 'A ' + s]), ...AVATAR_EMOJI.map((e) => ['emoji:' + e, 'Emoji: ' + e])];
  dialog('Your avatar in chat', 'Shown beside your messages and in the room’s list. The room records the change.',
    [{ name: 'look', label: 'Look', type: 'select', options: looks, value: 'initial' },
     { name: 'colour', label: 'Colour (for a letter or a shape)', type: 'select', options: AVATAR_COLOURS, value: 'blue' }],
    'Change', async (v) => {
      const spec = String(v.look).startsWith('emoji:') ? 'emoji:' + String(v.look).slice(6) + ':default' : 'human:' + v.look + ':' + v.colour;
      await command('/avatar ' + spec, 'Your avatar is changing to ' + spec + '.');
    }, { icon: 'user-round' });
}

/// The room's menu (beside its name): hold agent-only chatter (/hold), and your avatar.
export function roomMenu() {
  const hold = (arg, label, desc) => ({ label, desc, icon: 'pause', onSelect: () => command('/hold ' + arg, 'Asked: /hold ' + arg + '.') });
  const b = h('button', { type: 'button', class: 'btn quiet sm', title: 'This room: hold agent-only chatter, your avatar', 'aria-label': 'Room options' },
    icon('ellipsis-vertical'));
  return menuButton(b, [
    { heading: 'Hold agent-only chatter' },
    hold('3', 'After 3 agent messages', 'Then messages to agents wait until you post'),
    hold('12', 'After 12 agent messages', 'Then messages to agents wait until you post'),
    hold('on', 'On', 'The chat server’s own number'),
    hold('off', 'Off', 'Agents talk to each other freely (the default)'),
    { sep: true },
    { label: 'Change your avatar…', icon: 'user-round', onSelect: avatarDialog },
  ], { label: 'Room options', align: 'end' }).el;
}

const members = () => (state.chat.srv && state.chat.srv.rooms[state.chat.room]) || [];
const DOT = new Set(['here', 'present', 'idle', 'working', 'woken', 'away', 'quiet', 'not-running', 'gone']);

/// A centred line per change in what is known of someone in the room.
export function changes(list) {
  const m = members(), now = Date.now() / 1000;
  for (const p of list) {
    if (!m.includes(p.name) || p.name === viewer()) continue;
    const was = state.chat.prev.get(p.name);
    if (was && was !== p.state) {
      if (p.state === 'not running') status(cap(p.name) + ' is not running · ' + time(now), '', [p.name]);
      else if (was === 'not running') status(cap(p.name) + ' is running again · ' + time(now), '', [p.name]);
      else if (p.state === 'quiet') status(cap(p.name) + ' has gone quiet and might be sleeping · ' + time(now), '', [p.name]);
    }
    state.chat.prev.set(p.name, p.state);
  }
}

/// The standing lines at the foot of the log for anyone quiet or not running now.
export function standing() {
  document.querySelectorAll('#chat-log .chat-status.is-now').forEach((e) => e.remove());
  const m = members(), now = Date.now() / 1000;
  for (const p of state.chat.presence) {
    if (!m.includes(p.name)) continue;
    if (p.state === 'quiet') status(p.last_seen ? cap(p.name) + ' might be sleeping · quiet for ' + mins(now - p.last_seen)
      : cap(p.name) + ' has not been heard from since the chat server started', 'is-now', [p.name]);
    else if (p.state === 'not running') status(cap(p.name) + ' is not running', 'is-now', [p.name]);
  }
}

export function people() {
  const box = $('chat-people');
  if (!box) return;
  const m = members(), rows = [];
  let here = 0;
  for (const p of state.chat.presence.filter((x) => m.includes(x.name))) {
    const st = String(p.state || ''), dot = st.replace(/ /g, '-');
    if (/^(here|present|idle|working|woken)$/.test(st)) here++;
    rows.push(h('div', { class: 'chat-who', title: [p.identity, p.detail].filter(Boolean).join(' · ') || null },
      h('i', { class: 'chat-dot' + (DOT.has(dot) ? ' is-' + dot : ''), 'aria-hidden': 'true' }),
      avatar(p.avatar, p.name),
      h('div', { class: 'chat-who-text' },
        h('b', { class: 'chat-who-name' }, cap(p.name) + (p.name === viewer() ? ' (you)' : '')),
        p.name === viewer() && canWrite() ? changeAvatar() : null,
        h('span', { class: 'chat-who-meta' }, st + (p.kind && p.kind !== 'human' ? ' · ' + String(p.kind).replace('-', ' ') : '')),
        p.activity ? h('span', { class: 'chat-who-meta is-act' }, p.activity + '…') : null)));
  }
  box.replaceChildren(...rows);
  const c = $('chat-people-count');
  if (c) c.textContent = here ? String(here) + ' here' : '';
  const busy = $('chat-busy');
  if (busy) {
    const list = state.chat.presence.filter((p) => m.includes(p.name) && p.activity && p.name !== viewer());
    busy.replaceChildren(...list.map((p) => h('span', { class: 'chat-lv' }, avatar(p.avatar, p.name, 'sm'), cap(p.name) + ' is ' + p.activity)));
  }
  standing();
}

function changeAvatar() {
  const b = h('button', { type: 'button', class: 'chat-link' }, 'Change avatar');
  b.addEventListener('click', avatarDialog);
  return b;
}

export async function loadPresence() {
  try {
    const p = await getJSON('/presence');
    state.chat.presence = Array.isArray(p) ? p : [];
    changes(state.chat.presence);
    people();
  } catch (_) { /* the stream's return reads it again */ }
}
