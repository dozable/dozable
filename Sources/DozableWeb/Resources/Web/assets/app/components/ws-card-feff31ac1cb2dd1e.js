// components/ws-card — One card of a workspace's Home tab (views/ws-home.js): a titled section whose heading is a link to
// the tab that holds the whole of it ("Agents →"), an optional count beside the title, and a body that is never a link
// itself (only its own links and buttons are).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

/// o: {id, title, icon, href, linkLabel, count, body, tone} → <section class="ws-card" data-ws-card=ID>.
export function wsCard(o) {
  const hid = 'ws-card-h-' + o.id;
  const title = o.href
    ? h('a', { href: o.href, class: 'ws-card-link', title: o.linkLabel || null }, o.title, h('span', { class: 'ws-card-go', 'aria-hidden': 'true' }, ' →'))
    : o.title;
  return h('section', { class: 'ws-card' + (o.tone ? ' is-' + o.tone : ''), 'data-ws-card': o.id, 'aria-labelledby': hid },
    h('h2', { class: 'ws-card-h', id: hid }, o.icon ? icon(o.icon) : null, title,
      o.count != null ? h('span', { class: 'ws-card-n' }, String(o.count)) : null),
    h('div', { class: 'ws-card-body' }, ...[].concat(o.body || []).filter(Boolean)));
}
