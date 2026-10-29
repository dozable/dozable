// views/operations — Operations (593): its own page, and the nav badge.
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { busyMark, icon, isWaitStep, OP_GLYPH, QUEUED_GLYPH } from '../dom/icons-9b284ea0ffb2ad04.js';
import { clock, ms } from '../core/format-b2e68384da8d2f36.js';
import { act, cancelOps, opEnded, prepRunning } from '../core/operations-03d7dd105dcc61d2.js';
import { state } from '../core/state-2d94fd2b00c043b7.js';
import { panel, table } from '../components/blocks-6b2d43608253a84f.js';
import { btn } from '../components/button-8109d54546d946d3.js';
import { prepCard, prepProgressText } from '../components/prep-card-64953b51817dc9bc.js';

export function renderOps() {
  const running = [...state.ops.values()].filter((o) => o.state === 'running').length + state.preps.filter(prepRunning).length;
  const badge = $('ops-badge');
  badge.hidden = running === 0;
  badge.replaceChildren(h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), String(running));
  const queued = [...state.ops.values()].filter((o) => o.state === 'running' && o.queued).length;     // 650: counted, and said
  badge.title = queued ? (running - queued) + ' running · ' + queued + ' queued' : running + ' running';
  if (state.view === 'operations') state.opsSeenAt = Date.now();
  const unseen = [...state.ops.values()].some((o) => o.state === 'failed' && opEnded(o) > state.opsSeenAt);
  $('ops-alert').hidden = !unseen;
  if (state.view === 'operations') renderOperations();
}
export function acknowledgeOps() {
  state.opsSeenAt = Date.now();
  $('ops-alert').hidden = true;
}
export function viewOperations() {
  acknowledgeOps();
  const box = h('div');
  state.opsBox = box;
  renderOperations();
  return box;
}
export function renderOperations() {
  const box = state.opsBox;
  if (!box) return;
  const all = [...state.ops.values()].reverse();
  const names = [...new Set(all.map((o) => o.sandbox).filter(Boolean))].sort();
  const filter = h('select', { 'aria-label': 'Filter by sandbox' }, h('option', { value: '' }, 'every sandbox'), names.map((n) => {
    const o = h('option', { value: n }, n);
    if (n === state.opsFilter) o.selected = true;
    return o;
  }));
  filter.addEventListener('change', () => { state.opsFilter = filter.value; renderOperations(); });
  const list = all.filter((o) => !state.opsFilter || o.sandbox === state.opsFilter);
  const rows = list.map((o) => {
    // 650: a queued one has not started — no time of its own yet; its mark waits, and it may be cancelled.
    const queued = o.state === 'running' && o.queued;
    const secs = queued ? '—' : o.state === 'running' ? Math.max(0, Math.round((Date.now() - new Date(o.startedAt).getTime()) / 1000)) + ' s' : (o.milliseconds ? ms(o.milliseconds) : '—');
    return h('tr', { class: 'op-row op-' + (queued ? 'queued' : o.state), 'data-op': o.id },
      h('td', null, queued ? h('span', { class: 'wait-mark', title: 'queued' }, icon(QUEUED_GLYPH))
        : o.state === 'running' ? busyMark(isWaitStep(o.text)) : h('span', { class: 'op-state', title: o.state }, o.state === 'done' ? '✓' : o.state === 'interrupted' ? '–' : '✕')),
      h('td', { class: 'op-action' }, OP_GLYPH[o.action] ? icon(OP_GLYPH[o.action]) : null, o.action), h('td', null, o.sandbox ? h('a', { href: '#/sandbox/' + o.sandbox }, o.sandbox) : '—'),
      h('td', null, clock(o.startedAt)), h('td', { class: 'num' }, secs),
      // 594 W22: an operation of several parts (Restart host) lists each finished one.
      h('td', { class: 'op-text' }, o.text, o.lines && o.lines.length ? h('ul', { class: 'op-lines' }, o.lines.map((l) => h('li', null, l))) : null,
        queued ? btn('Cancel', () => cancelOps([o.id]), { small: true, quiet: true, title: 'Withdraw it — nothing was done yet' }) : null));
  });
  const waiting = all.filter((o) => o.state === 'running' && o.queued).map((o) => o.id);
  // (replaceChildren writes a null as the text "null" — h() skips it, replaceChildren does not.)
  box.replaceChildren(h('h1', null, 'Operations'),
    ...(state.preps.length ? [preparationsSection()] : []),
    h('p', { class: 'sub' }, 'What this UI asked the host to do, newest first: live progress while it runs, then its result. A failure also raises a message.'),
    h('div', { class: 'toolbar' }, filter, list.length + ' of ' + all.length,
      waiting.length ? btn('Cancel ' + waiting.length + ' queued', () => cancelOps(waiting), { small: true, quiet: true, icon: 'x', title: 'Withdraw every operation still waiting its turn' }) : null),
    panel(table(['', 'Action', 'Sandbox', 'Started', 'Took', 'Progress / result'], rows, [4]), 'Nothing yet — actions you take show here.'));
}
function preparationsSection() {
  // A row per preparation and, beneath it, the same card as the wizard's (the running ones in full).
  // (prep-row, not op-row: a preparation is the host's, not one of this page's operations — the
  // operations table's filter and its "newest first" are the UI's own actions only.)
  const rows = state.preps.flatMap((p) => [h('tr', { class: 'prep-row op-' + (prepRunning(p) ? 'running' : p.state === 'done' ? 'done' : 'failed'), 'data-prep': p.image },
    h('td', null, prepRunning(p) ? busyMark(isWaitStep(p.step), p.state) : h('span', { class: 'op-state', title: p.state }, p.state === 'done' ? '✓' : '✕')),
    h('td', { class: 'op-action' }, icon('flame'), 'prepare ' + (p.base ? 'the ' + (p.baseTitle || p.base) + ' base' : p.image)),
    h('td', null, p.requestedBy.join(', ')),
    h('td', null, clock(p.startedAt)), h('td', { class: 'num' }, Math.round(p.seconds) + ' s'),
    h('td', { class: 'op-text' }, prepProgressText(p)),
    h('td', null, prepRunning(p) && p.state !== 'cancelling'
      ? btn('Cancel preparation', () => act(p.base ? { action: 'prepare-cancel', base: p.base } : { action: 'prepare-cancel', images: [p.image] }), { small: true, danger: true }) : null)),
    h('tr', { class: 'prep-detail-row', 'data-prep-detail': p.image }, h('td', { colspan: '7' }, prepCard(p, { open: false })))]);
  return h('div', { class: 'ops-preps' }, h('h2', null, 'Image preparations (in the host)'),
    h('p', { class: 'sub' }, 'The kernel, the base image and the bake of a built-in image — asked for by doz onboard, the onboarding wizard, doz image bake or a first start. One per image at a time; whoever asks next joins it.'),
    panel(table(['', 'Image', 'Asked by', 'Started', 'Took', 'Progress', ''], rows, [4])));
}
