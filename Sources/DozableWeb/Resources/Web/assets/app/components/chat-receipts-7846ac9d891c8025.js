// components/chat-receipts — what happened to a message: one mark for the whole message (sent, delivered, answered, held,
// failed) and, in its detail, a chip per recipient and who reacted, in words.
import { cap } from '../core/chat-format-bc877d395788e64c.js';
import { viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

const ORDER = ['cancelled', 'queued', 'woken', 'delivered', 'held', 'failed', 'started', 'answered'];
const KNOWN = new Set(ORDER);
const DID = { like: 'liked this', love: 'loved this', lol: 'laughed', wow: 'said wow', sad: 'felt sad about this', thanks: 'said thanks',
  yes: 'said yes', no: 'said no', eyes: 'is looking at this', party: 'celebrated' };

export function chips(m) {
  const box = m._states;
  if (!box) return;
  const best = new Map();
  for (const s of m.states || []) {
    const b = best.get(s.recipient);
    if (!b || ORDER.indexOf(s.state) >= ORDER.indexOf(b.state)) best.set(s.recipient, s);
  }
  const kids = [];
  for (const [who, s] of best) {
    kids.push(h('span', { class: 'chat-chip' + (KNOWN.has(s.state) ? ' is-' + s.state : ''), title: s.detail || null }, cap(who) + ': ' + s.state));
  }
  const said = reactedText(m);
  if (said) kids.push(h('span', { class: 'chat-said' }, said));
  box.replaceChildren(...kids);
  tick(m, best);
}

function tick(m, best) {
  const t = m._tick;
  if (!t) return;
  const st = [...best.values()].map((s) => s.state), all = (f) => st.length > 0 && st.every(f), any = (x) => st.includes(x);
  let g = 'check', c = 'is-sent', label = 'Sent';
  if (any('failed')) { g = 'triangle-alert'; c = 'is-bad'; label = 'Not delivered to someone'; }
  else if (any('held')) { g = 'hourglass'; c = 'is-warn'; label = 'Held: too many agent messages in a row; waiting for you to post'; }
  else if (all((x) => x === 'answered')) { g = 'check-check'; c = 'is-done'; label = 'Answered by everyone'; }
  else if (any('answered') || any('started')) { g = 'check-check'; c = 'is-seen'; label = any('answered') ? 'Delivered, and answered by someone' : 'Delivered, and someone has started on it'; }
  else if (all((x) => x === 'delivered')) { g = 'check-check'; c = 'is-ok'; label = 'Delivered to everyone'; }
  t.className = 'chat-tick ' + c;
  t.title = label + '\n' + [...best.entries()].map(([w, s]) => w + ': ' + s.state + (s.detail ? ' · ' + s.detail : '')).join('\n');
  t.setAttribute('aria-label', label);
  t.replaceChildren(icon(g));
}

function reactedText(m) {
  const by = new Map();
  for (const r of m.reactions || []) {
    if (!by.has(r.reaction)) by.set(r.reaction, []);
    by.get(r.reaction).push(r.who === viewer() ? 'You' : cap(r.who));
  }
  const parts = [];
  for (const [what, who] of by) {
    let did = DID[what] || ('reacted ' + what);
    if (who.length > 1) did = did.replace(/^is /, 'are ');
    parts.push(who.join(', ') + ' ' + did);
  }
  return parts.join(' · ');
}
