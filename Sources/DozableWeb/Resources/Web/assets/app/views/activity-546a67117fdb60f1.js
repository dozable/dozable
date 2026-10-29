// views/activity — Activity.
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { api } from '../core/api-38ff3d6b44282c1f.js';
import { clock } from '../core/format-b2e68384da8d2f36.js';
import { state } from '../core/state-c85a0de5f7fc1060.js';
import { panel } from '../components/blocks-6b2d43608253a84f.js';

export async function viewActivity() {
  const recent = await api('events');
  const seen = new Set(state.activity.map((a) => a.seq));
  for (const a of recent) if (!seen.has(a.seq)) state.activity.push(a);
  state.activity.sort((x, y) => x.seq - y.seq);
  return activityNode();
}
function activityNode() {
  const items = state.activity.slice().reverse().map((a) => h('li', null,
    h('span', { class: 't' }, clock(a.time)), h('span', { class: 'who muted' }, a.sandbox || a.kind),
    h('span', { class: 'text' }, a.text)));
  // 635 (owner: a message went "too fast — i couldnt read it"): every message this tab showed, newest first.
  const TONE = { ok: 'done', info: 'note', warn: 'warning', bad: 'failed' };
  const msgs = (state.messages || []).slice().reverse().map((m) => h('li', { 'data-message': m.tone },
    h('span', { class: 't' }, clock(new Date(m.at).toISOString())), h('span', { class: 'who muted' }, TONE[m.tone] || m.tone),
    h('span', { class: 'text' }, m.text)));
  return h('div', null, h('h1', null, 'Activity'),
    h('h2', { class: 'h-section' }, 'Messages'),
    h('p', { class: 'sub' }, 'Every message this page showed — the ones that go by themselves too — since this tab opened.'),
    panel(msgs.length ? h('ul', { class: 'feed', 'data-messages': '' }, msgs) : null, 'No messages yet.'),
    h('h2', { class: 'h-section' }, 'The host'),
    h('p', { class: 'sub' }, 'What the host does — phases, timed steps, notes — while a sandbox is live and this page is open.'),
    panel(items.length ? h('ul', { class: 'feed' }, items) : null, 'Nothing yet. Start or wake a sandbox and it shows here.'));
}
export function renderActivity() { $('view').replaceChildren(activityNode()); }
