// components/chat-log — the room's log as a timeline: where a message goes, the moment lines between spurts of talk, the
// standing lines, and keeping the reader's place (the Latest button, the count of what came while they read above).
import { state } from '../core/state-d6b90484a98480b9.js';
import { MOMENT_GAP, momentLabel } from '../core/chat-format-bc877d395788e64c.js';
import { avatar } from '../dom/chat-avatar-afd4621f27e3492b.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

const log = () => $('chat-log');
const presenceOf = (n) => state.chat.presence.find((p) => p.name === n) || {};

export function showDown() {
  const d = $('chat-down');
  if (!d) return;
  d.hidden = state.chat.atFoot;
  d.classList.toggle('is-new', state.chat.missed > 0);
  d.replaceChildren(icon('arrow-down'), document.createTextNode(state.chat.missed > 0 ? state.chat.missed + ' new' : 'Latest'));
}
export function toFoot() { const l = log(); l.scrollTop = l.scrollHeight; state.chat.atFoot = true; state.chat.missed = 0; showDown(); }
export function stick(counts) {
  if (state.chat.atFoot) { const l = log(); l.scrollTop = l.scrollHeight; } else { if (counts) state.chat.missed++; showDown(); }
}

/// The moment lines, worked out again from what the log shows.
export function moments() {
  const l = log(), need = new Set();
  let prev = null;
  for (const c of l.children) {
    if (c.dataset.at === undefined || c.classList.contains('chat-moment') || c.hidden) continue;
    const at = +c.dataset.at;
    if (prev === null || at - prev >= MOMENT_GAP) need.add(c);
    prev = at;
  }
  for (const s of [...l.children]) {
    if (!s.classList.contains('chat-moment')) continue;
    const n = s.nextElementSibling;
    if (!n || !need.has(n) || s.dataset.at !== n.dataset.at) s.remove();
  }
  for (const c of need) {
    const b = c.previousElementSibling;
    if (b && b.classList.contains('chat-moment')) continue;
    l.insertBefore(h('div', { class: 'chat-moment', 'data-at': c.dataset.at }, momentLabel(+c.dataset.at)), c);
  }
}

/// A node into the log: in place of `instead` (the reader's place kept), at the top (`older`), or at the foot.
export function place(node, instead, older) {
  const l = log();
  if (instead && instead.parentNode) {
    const above = !state.chat.atFoot && instead.getBoundingClientRect().bottom < l.getBoundingClientRect().top, h0 = instead.offsetHeight;
    instead.replaceWith(node);
    if (above) l.scrollTop += node.offsetHeight - h0; else if (state.chat.atFoot) l.scrollTop = l.scrollHeight;
    if (!state.chat.bulk) moments();
    return;
  }
  if (older) { l.prepend(node); return; }
  const f = l.querySelector('.chat-status.is-now');
  if (f) l.insertBefore(node, f); else l.append(node);
  if (!state.chat.bulk) moments();
  stick(true);
}

/// A centred line about the room (a change, someone gone quiet); `names` get their small avatar in front.
export function status(text, cls, names) {
  const d = h('div', { class: 'chat-status' + (cls ? ' ' + cls : '') }, ...(names || []).map((n) => avatar(presenceOf(n).avatar, n, 'sm')), text);
  log().append(d);
  stick(false);
  return d;
}
