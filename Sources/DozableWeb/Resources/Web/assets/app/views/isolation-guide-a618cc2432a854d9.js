// views/isolation-guide — Where an agent runs (#/guide/isolation[/vm|fenced|unfenced|elsewhere]): the four choices in order
// of isolation, each a card — a small CSS diagram, what it is, what it is for and not for, today's commands — and the one
// line that holds for all of them (keys never go inside). Static: no route, no HostOp, the same for every browser. Every
// isolation chip links here (components/iso-chip.js) and lands on its card, highlighted. The words are core/isolation.js's.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { ISOLATIONS, KEYS_NEVER_INSIDE } from '../core/isolation-eeb96279e071283f.js';
import { guideHash } from '../core/routes-ce13c8979e42e1cc.js';
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-e34a50f80637ff89.js';

/// The card's picture, drawn with boxes: the Mac and what stands between the agent and it.
function figure(x) {
  const [outer, box, line1, line2] = x.figure;
  if (x.id === 'elsewhere') {
    return h('div', { class: 'iso-fig iso-fig-elsewhere', 'aria-hidden': 'true' },
      h('div', { class: 'iso-fig-mac' }, outer), h('div', { class: 'iso-fig-link' }, line1), h('div', { class: 'iso-fig-other' }, box));
  }
  const inner = x.id === 'unfenced'
    ? h('div', { class: 'iso-fig-none' }, h('span', null, line1), h('span', null, line2))
    : h('div', { class: 'iso-fig-box iso-fig-' + x.id }, h('span', { class: 'iso-fig-label' }, box), h('span', null, line1), h('span', null, line2));
  return h('div', { class: 'iso-fig', 'aria-hidden': 'true' }, h('div', { class: 'iso-fig-mac' }, h('span', { class: 'iso-fig-label' }, outer), inner));
}

function card(x, current) {
  return h('article', { class: 'iso-card iso-card-' + x.id + (current ? ' is-current' : ''), id: 'iso-' + x.id, 'data-iso-card': x.id,
    'aria-current': current ? 'true' : null, 'aria-labelledby': 'iso-h-' + x.id },
    h('h2', { class: 'iso-card-h', id: 'iso-h-' + x.id },
      h('a', { class: 'ws-iso ws-iso-' + x.chip.replace(/ /g, '-'), href: guideHash(x.id), 'data-iso': x.chip, title: 'Link to this choice' }, x.chip),
      h('span', { class: 'iso-card-title' }, x.title)),
    figure(x),
    h('p', { class: 'iso-what' }, x.what),
    h('p', { class: 'iso-for' }, h('b', null, 'For: '), x.for),
    h('p', { class: 'iso-not' }, h('b', null, 'Not for: '), x.notFor),
    x.id === 'elsewhere' ? h('p', { class: 'iso-honest' }, icon('triangle-alert'), 'Not isolated by Dozable.') : null,
    h('div', { class: 'iso-cmds' }, ...x.commands.map(([c, why]) => h('div', { class: 'iso-cmd' }, cmdLine(c), h('span', { class: 'muted' }, why)))));
}

export function viewIsolationGuide() {
  const at = state.param;
  const node = h('div', { class: 'iso-guide', 'data-iso-guide-page': at || '' },
    h('div', { class: 'head' }, h('h1', null, 'Where an agent runs')),
    h('p', { class: 'sub' }, 'The four choices, in order of isolation — from a separate machine to none at all. A workspace’s manager and its workers each run in one of them.'),
    h('div', { class: 'iso-cards' }, ...ISOLATIONS.map((x) => card(x, x.id === at))),
    callout('info', { cls: 'iso-keys', title: 'Your keys never go inside', body: KEYS_NEVER_INSIDE }));
  if (at) {
    requestAnimationFrame(() => {
      const c = node.querySelector('[data-iso-card="' + at + '"]');
      if (c && c.isConnected) c.scrollIntoView({ block: 'nearest' });
    });
  }
  return node;
}
