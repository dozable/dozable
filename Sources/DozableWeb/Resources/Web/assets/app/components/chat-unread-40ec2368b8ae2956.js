// components/chat-unread — the rooms list's counts and previews, and the sidebar's Chat badge. The marker of each room is
// the newest seq this browser has seen there (core/chat-storage); the chat server counts after it.
import { state } from '../core/state-58b070d3f17c1c53.js';
import { getJSON, viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { cap, plain, shortWhen, shown } from '../core/chat-format-bc877d395788e64c.js';
import { getSeen, setSeen } from '../core/chat-storage-95add63ce40b26df.js';
import { avatar } from '../dom/chat-avatar-afd4621f27e3492b.js';
import { $ } from '../dom/h-f853cc7eb6672c45.js';

const presenceOf = (n) => state.chat.presence.find((p) => p.name === n) || {};

export function showUnread() {
  let total = 0, at = false;
  for (const b of document.querySelectorAll('#chat-rooms .chat-rm')) {
    const r = b.dataset.room, u = r === state.chat.room && state.chat.active ? null : state.chat.unread[r], n = u ? u.n : 0, t = b.querySelector('.chat-n');
    if (u && u.m) at = true;
    total += n;
    t.hidden = !n;
    t.textContent = shown(n);
    t.classList.toggle('is-at', !!(u && u.m));
    b.title = n ? n + ' unread' + (u.m ? ', ' + u.m + ' naming you' : '') : (b.classList.contains('is-archived') ? 'Archived: read-only' : '');
  }
  if (!document.querySelector('#chat-rooms .chat-rm')) {
    for (const r in state.chat.unread) { const u = state.chat.unread[r]; total += u.n; if (u.m) at = true; }
  }
  const nb = $('chat-badge');
  if (nb) {
    nb.hidden = !total;
    nb.textContent = shown(total);
    nb.classList.toggle('is-at', at);
    nb.title = total ? total + ' unread in chat' : '';
  }
}

export function showPreviews() {
  for (const b of document.querySelectorAll('#chat-rooms .chat-rm')) {
    const p = state.chat.previews[b.dataset.room], line = b.querySelector('.chat-pv'), t = b.querySelector('.chat-rt');
    if (!p) { line.replaceChildren(); t.textContent = ''; continue; }
    line.replaceChildren(avatar(presenceOf(p.sender).avatar, p.sender, 'xs'),
      document.createTextNode((p.sender === viewer() ? 'You' : cap(p.sender)) + ': ' + (plain(p.text) || '(attachment)')));
    t.textContent = shortWhen(p.at);
    t.title = new Date(p.at * 1000).toLocaleString();
  }
}

export function setPreview(r, m) {
  state.chat.previews[r] = { msg_id: m.msg_id, sender: m.from, text: String(m.content || '').slice(0, 140), at: m.at };
  showPreviews();
}

/// Ask the chat server how much is unread after this browser's markers (a room seen for the first time is read up to now).
export async function loadUnread() {
  if (!state.chat.srv) return;
  try {
    const q = Object.keys(state.chat.srv.rooms).filter((r) => getSeen(r) !== null).slice(0, 256).map((r) => encodeURIComponent(r) + '=' + getSeen(r));
    const j = await getJSON('/unread' + (q.length ? '?' + q.join('&') : ''));
    for (const r in j) {
      const x = j[r] || {};
      if (getSeen(r) === null) setSeen(r, +x.last || 0);
      if (!(r === state.chat.room && state.chat.active)) state.chat.unread[r] = { n: +x.count || 0, m: +x.mentions || 0 };
      if (x.preview) state.chat.previews[r] = x.preview;
    }
    showUnread();
    showPreviews();
  } catch (_) { /* the next look tries again */ }
}
