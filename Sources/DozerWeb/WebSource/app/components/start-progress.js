// components/start-progress — 617 (owner: "we shouldnt show the blank terminal area until the build is finished, and
// while the build completes, we should show the progress in that area"). While a sandbox this page shows is STARTING
// (its `start` operation runs — an image being prepared, the VM booting, the session opening), its terminal area shows
// the progress instead: the steps in plain words, the one under way with how long it has taken, and the last lines of
// a build's output — the operation's own `progress` (WebOpProgress), the same events Operations shows. When the start
// is done it gets out of the way (the terminal has the session); a failure stays, with what happened and what to do.
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { upcall } from '../core/hooks.js';
import { state } from '../core/state.js';
import { btn } from './button.js';

const lifecycle = upcall('lifecycle');

const STARTS = ['start'];
let ticker = null;

function elapsed(since) {
  const s = Math.max(0, Math.round((Date.now() - new Date(since).getTime()) / 1000));
  return s < 60 ? s + ' s' : Math.floor(s / 60) + ' min ' + (s % 60) + ' s';
}

/// The start of `name` this page should show: the running one, else a failed one not yet dismissed.
function startOf(name) {
  const ops = [...state.ops.values()].filter((o) => o.sandbox === name && STARTS.includes(o.action));
  const running = ops.find((o) => o.state === 'running');
  if (running) return running;
  const last = ops[ops.length - 1];
  return last && last.state === 'failed' && !(state.startDismissed || new Set()).has(last.id) ? last : null;
}

function panelFor(name, o) {
  const p = o.progress || { steps: [], tail: [] };
  const failed = o.state === 'failed';
  const steps = (p.steps || []).map((s) => h('li', { class: 'sp-step' + (s.failed ? ' failed' : '') },
    icon(s.failed ? 'circle-x' : 'check'), h('span', null, s.text), s.seconds >= 0.1 ? h('span', { class: 'muted' }, s.seconds.toFixed(1) + ' s') : null));
  const current = !failed && p.current ? h('li', { class: 'sp-step current', 'data-sp-current': '' },
    h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('span', null, p.current.replace(/…$/, '') + '…'),
    h('span', { class: 'muted', 'data-sp-since': p.since || '' }, ' · ' + (p.since ? elapsed(p.since) : '')),
    p.transfer ? h('span', { class: 'muted' }, ' · ' + p.transfer) : null) : null;
  const tail = !failed && (p.tail || []).length ? h('pre', { class: 'sp-tail', 'data-sp-tail': '' }, (p.tail || []).join('\n')) : null;
  const what = failed
    ? h('div', { class: 'sp-failed', role: 'alert' },
      h('p', null, h('strong', null, name + ' did not start: '), o.text || 'the start failed'),
      h('p', { class: 'muted' }, 'Start tries again (an image that failed to prepare is prepared again); Operations has the whole story.'),
      h('div', { class: 'sp-acts' },
        btn('Start', () => { (state.startDismissed = state.startDismissed || new Set()).add(o.id); paintStartProgress(); lifecycle('start', name); }, { primary: true, small: true }),
        btn('Dismiss', () => { (state.startDismissed = state.startDismissed || new Set()).add(o.id); paintStartProgress(); }, { small: true, quiet: true })))
    : null;
  return h('div', { class: 'start-progress', 'data-start-progress': name, role: 'status', 'aria-live': 'polite' },
    h('div', { class: 'sp-box' },
      h('h3', null, failed ? 'Starting ' + name + ' failed' : 'Starting ' + name + '…'),
      h('p', { class: 'muted' }, failed ? '' : 'Its terminal opens here as soon as the sandbox runs and its session is open.'),
      h('ol', { class: 'sp-steps' }, ...steps, current),
      tail, what));
}

/// Draw (or remove) the progress panel over the terminal area of the sandbox this page shows. Cheap: called on every
/// operation event; a second ticker keeps the elapsed time moving while a step runs.
export function paintStartProgress() {
  const root = document.getElementById('terminals');
  if (!root) return;
  const name = state.view === 'sandbox' ? state.param : null;
  const o = name ? startOf(name) : null;
  const have = root.querySelector(':scope > .start-progress');
  if (!o) {
    if (have) have.remove();
    root.classList.remove('starting');
    if (ticker) { clearInterval(ticker); ticker = null; }
    return;
  }
  const key = o.id + '|' + o.state + '|' + JSON.stringify(o.progress || null) + '|' + o.text;
  if (!have || have.dataset.key !== key) {
    const el = panelFor(name, o);
    el.dataset.key = key;
    if (have) have.replaceWith(el); else root.append(el);
  }
  root.classList.add('starting');
  if (!ticker && o.state === 'running') {
    ticker = setInterval(() => {
      const s = document.querySelector('[data-sp-since]');
      if (s && s.dataset.spSince) s.textContent = ' · ' + elapsed(s.dataset.spSince);
    }, 1000);
  }
}
