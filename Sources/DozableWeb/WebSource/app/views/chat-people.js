// views/chat-people — who is in the room shown: presence, the standing lines for those quiet now, and the lines when
// someone's state changes. (Reading only: the person's own avatar is set from the dashboard later.)
import { state } from '../core/state.js';
import { getJSON, viewer } from '../core/chat-api.js';
import { cap, mins, time } from '../core/chat-format.js';
import { status } from '../components/chat-log.js';
import { avatar } from '../dom/chat-avatar.js';
import { $, h } from '../dom/h.js';

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

export async function loadPresence() {
  try {
    const p = await getJSON('/presence');
    state.chat.presence = Array.isArray(p) ? p : [];
    changes(state.chat.presence);
    people();
  } catch (_) { /* the stream's return reads it again */ }
}
