// components/chat-reactions — a message's reactions: one chip per emoji with its count, who reacted and when in its title;
// a chip is a button that adds or takes off that reaction. The picker (smile-plus) offers the chat server's reactions and
// any emoji. Each reaction is sent with its own X-Chat-Id, so the server does it once.
import { state } from '../core/state-716ecb2258797bb6.js';
import { canWrite, chatError, request, roomUrl, viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { dialog } from './dialog-bddce55b465a4027.js';
import { chatNote } from './chat-note-7d9b58ce10feea44.js';
import { menuButton } from './menus-b8f822d6b7817c72.js';
import { chips } from './chat-receipts-7846ac9d891c8025.js';

const when = (r) => new Date(r.at * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

export function reacts(m) {
  const box = m._rx;
  if (!box) return;
  const by = new Map();
  for (const r of m.reactions || []) {
    const e = String(r.emoji || r.reaction || '');
    if (!by.has(e)) by.set(e, []);
    by.get(e).push(r);
  }
  const write = canWrite();
  const kids = [];
  for (const [emoji, list] of by) {
    const mine = list.some((r) => r.who === viewer());
    const attrs = { class: 'chat-rc' + (mine ? ' is-mine' : ''), title: list.map((r) => String(r.who) + ' · ' + when(r)).join('\n'),
      'aria-label': emoji + ' from ' + list.map((r) => String(r.who)).join(', ') + (write ? (mine ? ' — take yours off' : ' — add yours') : '') };
    const n = list.length > 1 ? h('b', { class: 'chat-rc-n' }, String(list.length)) : null;
    if (write) {
      const b = h('button', { type: 'button', ...attrs, 'aria-pressed': mine ? 'true' : 'false' }, emoji, n);
      b.addEventListener('click', (e) => { e.stopPropagation(); react(m.msg_id, String(list[0].reaction || emoji)); });
      kids.push(b);
    } else kids.push(h('span', attrs, emoji, n));
  }
  box.replaceChildren(...kids);
  chips(m);
}

/// The person reacts (the same reaction again takes it off — the chat server's rule).
export async function react(msgId, what) {
  try {
    const r = await request(roomUrl(state.chat.room, '/reactions'), { method: 'POST', json: { msg_id: msgId, reaction: what }, once: true });
    if (!r.ok) throw await chatError(r);
    const j = await r.json();
    if (j.state === 'refused') chatNote('Reaction not added: ' + (j.detail || 'refused'), true);
  } catch (e) { chatNote('Reaction not added: ' + (e.message || e), true); }
}

/// Any emoji, typed.
function another(msgId) {
  dialog('React with an emoji', 'Type or paste one emoji (or a reaction’s name, like thanks).', [{ name: 'emoji', label: 'Emoji', required: true }],
    'React', async (v) => { const x = String(v.emoji || '').trim(); if (x) await react(msgId, x); }, { icon: 'smile-plus' });
}

/// The smile-plus button and its menu: the server's reactions, then Another emoji….
export function picker(m) {
  const b = h('button', { type: 'button', class: 'chat-ibtn', title: 'React', 'aria-label': 'React to this message' }, icon('smile-plus'));
  const items = ((state.chat.srv && state.chat.srv.reactions) || []).map((r) => ({
    label: String(r.emoji || '') + '  ' + String(r.name || ''), icon: 'smile-plus', onSelect: () => react(m.msg_id, String(r.name || r.emoji)),
  }));
  items.push({ sep: true }, { label: 'Another emoji…', icon: 'ellipsis', onSelect: () => another(m.msg_id) });
  const ctl = menuButton(b, items, { label: 'React with', align: 'end', wrap: h('span', { class: 'menu-wrap chat-pick' }, b) });
  return ctl.el;
}
