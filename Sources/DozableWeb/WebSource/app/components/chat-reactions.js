// components/chat-reactions — a message's reactions: one chip per emoji with its count; who reacted, and when, in its title.
// (Shown only: reacting from the dashboard comes later.)
import { viewer } from '../core/chat-api.js';
import { h } from '../dom/h.js';
import { chips } from './chat-receipts.js';

export function reacts(m) {
  const box = m._rx;
  if (!box) return;
  const by = new Map();
  for (const r of m.reactions || []) {
    if (!by.has(r.emoji)) by.set(r.emoji, []);
    by.get(r.emoji).push(r);
  }
  const kids = [];
  for (const [emoji, list] of by) {
    const mine = list.some((r) => r.who === viewer());
    const when = (r) => new Date(r.at * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    kids.push(h('span', { class: 'chat-rc' + (mine ? ' is-mine' : ''), title: list.map((r) => r.who + ' · ' + when(r)).join('\n'),
      'aria-label': emoji + ' from ' + list.map((r) => r.who).join(', ') }, emoji, list.length > 1 ? h('b', { class: 'chat-rc-n' }, String(list.length)) : null));
  }
  box.replaceChildren(...kids);
  chips(m);
}
