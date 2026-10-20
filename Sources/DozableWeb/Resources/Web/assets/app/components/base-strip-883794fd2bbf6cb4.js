// components/base-strip — The store's base at the foot of the setup (634; the owner's onboarding-v2: "move the download
// progress strip to the bottom, on top of the wizard controls strip; its details should show a popover style modal").
// One line, the modal's full width, just above the buttons, from the step after Base image on: downloading (a bar, the
// bytes, the time left) → preparing (step N of M) → ready (green, Build log) → failed (red, Retry). Details opens a
// POPOVER over the step, anchored to it and opening upwards: the base, its steps with their times, the output's tail,
// where it can be watched and Cancel. It holds no choice and is not a step: ✕, Esc or a click outside close it, and the
// setup behind it goes on. When ready it is the record — the steps and their times (no full build log: a base
// preparation runs no script).
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-2b30ba761d2d921b.js';
import { bytes, dur } from '../core/format-b2e68384da8d2f36.js';
import { act, prepRunning } from '../core/operations-aeb47e4b98173dcf.js';
import { btn } from './button-cbb8a60e3220f977.js';
import { dialog } from './dialog-3079696fba2b7682.js';

const KEPT = 'It goes on if you close this window — Operations shows it, and a sandbox started meanwhile waits for it.';
// The popover's open state survives the strip's repaints (a poll repaints the strip, never the step).
let popOpen = false;
// The bar never moves back while one preparation runs (its id → the largest fraction drawn).
const SHOWN = new Map();

/// The base's preparation in `preps` (the newest), or null.
export function basePrep(preps, id) {
  const name = 'base:' + id;
  return (preps || []).filter((p) => p.image === name).sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt))[0] || null;
}

/// The strip's phase: none (nothing to show) · download · prepare · ready · failed.
export function stripPhase(p, base) {
  if (p && prepRunning(p)) return p.transferTotalBytes && (p.transferBytes || 0) < p.transferTotalBytes ? 'download' : 'prepare';
  if (p && p.state === 'done') return 'ready';
  if (p) return 'failed';
  return base && base.prepared ? 'ready' : 'none';
}

/// How far it is, 0…1, never back for one preparation.
function fraction(p, phase) {
  if (phase === 'ready') return 1;
  if (!p) return 0;
  const m = p.plannedSteps || 4, n = Math.max(1, p.stepIndex || 1);
  let f = (n - 1) / m;
  if (p.transferTotalBytes) f = Math.max(f, ((n - 1) + (p.transferBytes || 0) / p.transferTotalBytes) / m);
  else if (p.stepUsualSeconds && p.stepSeconds) f = Math.max(f, ((n - 1) + Math.min(0.9, p.stepSeconds / p.stepUsualSeconds)) / m);
  const was = SHOWN.get(p.id) || 0;
  const v = Math.max(was, Math.min(phase === 'failed' ? 1 : 0.99, f));
  SHOWN.set(p.id, v);
  return v;
}

/// How far the strip last drew it, 0…1 (the First sandbox's "waits for the base (N %)" says the same number).
export function baseFraction(p) { return p ? SHOWN.get(p.id) || 0 : 0; }

function left(p) { return p && p.remainingSeconds != null ? 'about ' + (p.remainingSeconds < 60 ? Math.max(1, Math.round(p.remainingSeconds)) + ' s' : Math.round(p.remainingSeconds / 60) + ' min') + ' left' : ''; }

/// The strip. base: the step's base ({id, title, reference, downloadBytes}); p: its preparation (or null);
/// onRetry(): start it again. Returns null when there is nothing to show.
export function baseStrip({ base, prep: p, onRetry }) {
  const phase = stripPhase(p, base);
  if (phase === 'none' || !base) return null;
  const title = (base.title || base.id) + ' base';
  const f = fraction(p, phase);
  const pct = Math.round(f * 100);
  const bar = (cls) => h('span', { class: cls, role: cls === 'wb-bar' ? 'progressbar' : null, 'aria-valuenow': String(pct), 'aria-valuemin': '0', 'aria-valuemax': '100',
    'aria-label': cls === 'wb-bar' ? title + ' — ' + pct + '%' : null }, h('span', { 'data-w': String(pct) }));
  const toggle = h('button', { type: 'button', class: 'linkish', 'data-pop-toggle': '', 'aria-haspopup': 'dialog', 'aria-controls': 'wb-pop',
    'aria-expanded': String(popOpen) }, phase === 'ready' ? 'Build log' : 'Details');
  const pop = popover({ base, p, phase, title, f });
  pop.hidden = !popOpen;
  const total = p && p.transferTotalBytes ? p.transferTotalBytes : base.downloadBytes;
  let lead, text;
  if (phase === 'download') {
    lead = icon('download');
    text = ['Downloading · ' + bytes(p.transferBytes || 0) + ' of ' + bytes(total), h('span', { class: 'wb-long' }, left(p) ? ' · ' + left(p) : '')];
  } else if (phase === 'prepare') {
    lead = h('span', { class: 'mini-spin', 'aria-hidden': 'true' });
    text = ['Preparing · step ' + (p.stepIndex || 1) + ' of ' + (p.plannedSteps || 4) + (p.step ? ' · ' + p.step : '')];
  } else if (phase === 'ready') {
    lead = icon('circle-check');
    text = [p ? bytes(total) + ' downloaded and prepared in ' + dur(p.seconds) : 'ready in this store', h('span', { class: 'wb-long' }, ' — every tool is added to it as a layer')];
  } else {
    lead = icon('circle-x');
    text = [p.error || 'it did not finish', h('span', { class: 'wb-long' }, ' — the setup goes on')];
  }
  const strip = h('div', { class: 'wm-base at-foot' + (phase === 'ready' ? ' ready' : phase === 'failed' ? ' failed' : ''), 'data-base-strip': phase,
    role: phase === 'failed' ? 'alert' : 'status', 'aria-label': 'The base image' },
    lead, h('b', null, phase === 'ready' ? title + ' ready' : phase === 'failed' ? (p.state === 'cancelled' ? 'The base download was cancelled' : 'The base download stopped') : title),
    phase === 'download' || phase === 'prepare' ? bar('wb-bar') : null,
    h('span', { class: 'wb-text' }, ...text), h('span', { class: 'wb-gap' }),
    phase === 'failed' ? h('span', { class: 'wb-acts' }, toggle, btn('Retry', () => onRetry(), { small: true, icon: 'refresh-cw' })) : toggle,
    pop);
  // The bars' widths are set through the style property (the page has no inline style attribute).
  for (const s of strip.querySelectorAll('[data-w]')) s.style.width = s.dataset.w + '%';
  toggle.addEventListener('click', (ev) => { ev.stopPropagation(); setOpen(strip, !popOpen); });
  pop.addEventListener('click', (ev) => ev.stopPropagation());
  return strip;
}

function setOpen(strip, open) {
  popOpen = open;
  const pop = strip.querySelector('.wb-pop'), t = strip.querySelector('[data-pop-toggle]');
  if (!pop || !t) return;
  pop.hidden = !open;
  t.setAttribute('aria-expanded', String(open));
  if (open) { const c = pop.querySelector('.wp-close'); if (c) c.focus(); } else t.focus();
}

/// Close an open popover (Esc, a click outside). True when one was open.
export function closeBasePop() {
  const strip = document.querySelector('[data-base-strip]');
  if (!popOpen || !strip) { popOpen = false; return false; }
  setOpen(strip, false);
  return true;
}

// Esc closes the popover first (before the modal's own Esc, which would close the setup); a click outside closes it.
document.addEventListener('keydown', (ev) => {
  if (ev.key !== 'Escape' || !popOpen || !document.querySelector('[data-base-strip] .wb-pop:not([hidden])')) return;
  ev.preventDefault();
  ev.stopPropagation();
  closeBasePop();
}, true);
document.addEventListener('click', (ev) => {
  if (!popOpen) return;
  const pop = document.querySelector('[data-base-strip] .wb-pop');
  if (pop && !pop.contains(ev.target)) closeBasePop();
});

function popover({ base, p, phase, title, f }) {
  const pill = phase === 'ready' ? h('span', { class: 'pill st-ok' }, icon('circle-check'), 'Ready')
    : phase === 'failed' ? null : h('span', { class: 'pill ph-busy' }, h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), phase === 'download' ? 'Downloading' : 'Preparing');
  const close = btn('Close the details', () => closeBasePop(), { quiet: true, iconOnly: true, icon: 'x', small: true });
  close.classList.add('wp-close');
  const nums = [];
  if (p && p.transferTotalBytes && phase !== 'ready') nums.push(h('span', null, h('b', null, bytes(p.transferBytes || 0)), ' of ' + bytes(p.transferTotalBytes)));
  if (p && (phase === 'download' || phase === 'prepare')) {
    nums.push(h('span', null, 'Step ', h('b', null, String(p.stepIndex || 1)), ' of ' + (p.plannedSteps || 4)));
    nums.push(h('span', null, dur(p.seconds) + ' so far'));
    if (left(p)) nums.push(h('span', null, left(p)));
  } else if (p && phase === 'ready') {
    nums.push(h('span', null, h('b', null, bytes(p.transferTotalBytes || base.downloadBytes))), h('span', null, dur(p.seconds) + ' in all'));
  } else if (p && phase === 'failed') {
    nums.push(h('span', null, 'stopped at ' + dur(p.seconds)));
  }
  // The steps: the finished ones with their times, the one under way, then how many are left.
  const rows = [];
  for (const s of (p ? p.steps : []).filter((s) => s.kind !== 'transfer')) {
    rows.push(h('li', { class: s.kind === 'failed' ? 'failed' : 'done' }, icon(s.kind === 'failed' ? 'circle-x' : 'circle-check'), h('span', null, s.label),
      h('span', { class: 't' }, dur(s.seconds)), s.error ? h('span', { class: 'wp-sub' }, s.error) : null));
  }
  if (p && prepRunning(p) && p.step) {
    rows.push(h('li', { class: 'current' }, h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('span', null, p.step), h('span', { class: 't' }, dur(p.stepSeconds || 0)),
      p.transferLine ? h('span', { class: 'wp-sub' }, p.transferLine) : null));
  }
  const later = p && prepRunning(p) ? Math.max(0, (p.plannedSteps || 4) - (p.stepIndex || 1)) : 0;
  if (later) rows.push(h('li', { class: 'later' }, h('span', { class: 'wp-n' }, String((p.stepIndex || 1) + 1)),
    h('span', null, later === 1 ? 'one more step' : later + ' more steps'), h('span', { class: 't' }, '')));
  if (!rows.length && phase === 'ready') rows.push(h('li', { class: 'done' }, icon('circle-check'), h('span', null, 'Prepared in this store'), h('span', { class: 't' }, '')));
  const tail = p && prepRunning(p) && p.output && p.output.length ? h('pre', { class: 'wp-tail' }, p.output.slice(-2).join('\n')) : null;
  const acts = [];
  if (p && prepRunning(p)) {
    acts.push(btn('Operations', () => { closeBasePop(); location.hash = '#/operations'; }, { small: true, quiet: true, icon: 'activity' }), h('span', { class: 'wp-gap' }),
      btn(phase === 'download' ? 'Cancel download…' : 'Cancel…', () => dialog('Cancel the ' + title + '?',
        'Its download stops; what was downloaded is kept, so a later try resumes. The setup goes on — each tool’s first start prepares the base then.',
        [], 'Cancel it', async () => { await act({ action: 'prepare-cancel', base: base.id }); }, { danger: true, icon: 'circle-x' }), { small: true, quiet: true, danger: true, icon: 'circle-x' }));
  }
  const note = phase === 'ready' ? 'Every tool you try is added to it as a layer, so a second tool costs only what it adds.'
    : phase === 'failed' ? 'Retry resumes from what is already here. The questions go on meanwhile — nothing they write needs the base.' : KEPT;
  const bar = h('div', { class: 'wp-bar' }, h('span', { 'data-w': String(Math.round(f * 100)) }));
  return h('div', { class: 'wb-pop' + (phase === 'ready' ? ' ok' : phase === 'failed' ? ' bad' : ''), id: 'wb-pop', role: 'dialog', 'aria-label': title + ' — details', 'data-base-pop': '' },
    h('div', { class: 'wp-head' }, icon(phase === 'ready' ? 'list-checks' : phase === 'failed' ? 'triangle-alert' : 'layers'), h('b', null, title), pill, h('span', { class: 'wp-gap' }), close),
    h('div', { class: 'wp-meta' }, h('code', null, base.reference || base.id), h('span', null, 'linux/arm64')),
    bar, nums.length ? h('div', { class: 'wp-nums' }, ...nums) : null,
    h('ol', { class: 'wp-steps' }, ...rows), tail, h('p', { class: 'wp-note' }, note),
    acts.length ? h('div', { class: 'wp-acts' }, ...acts) : null);
}
