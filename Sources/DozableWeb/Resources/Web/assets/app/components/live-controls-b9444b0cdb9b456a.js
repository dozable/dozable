// components/live-controls — 642 (owner): how many session pictures a page keeps live at once, and whether the live
// ones take turns (All sandboxes, All sessions): Live − N + · Cycle · − S s each +. Each page's choice is this browser's.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { liveCap } from './session-thumb-0d5a39a79157577e.js';

/// Of the UI's 16 terminal sockets a page's pictures use at most this many — the rest are kept for real tabs.
export const SOCKET_CEILING = 12;

function pref(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (_) { return d; } }
function setPref(k, v) { try { localStorage.setItem(k, String(v)); } catch (_) { /* this page only */ } }

/// A page's choices, kept as `doz.<page>.live|cycle|hold`; until changed, Live is ui.grid_live_tiles (at most `max`).
export function livePrefs(page, max) {
  const k = (x) => 'doz.' + page + '.' + x;
  return {
    limit() { const n = parseInt(pref(k('live'), ''), 10); return Number.isInteger(n) ? Math.max(0, Math.min(SOCKET_CEILING, n)) : liveCap(max); },
    cycle() { return pref(k('cycle'), 'off') === 'on'; },
    hold() { const n = parseInt(pref(k('hold'), '2'), 10); return n >= 1 && n <= 10 ? n : 2; },
    setLimit(v) { setPref(k('live'), v); },
    setCycle(on) { setPref(k('cycle'), on ? 'on' : 'off'); },
    setHold(v) { setPref(k('hold'), v); },
  };
}

function stepper(label, value, text, min, max, set) {
  const b = (sign, d) => h('button', { type: 'button', class: 'btn sm quiet icon-only', 'aria-label': label + (d < 0 ? ' — fewer' : ' — more'),
    disabled: (d < 0 ? value <= min : value >= max) ? '' : null, on: { click: () => set(value + d) } }, sign);
  return h('span', { class: 'ov-step', role: 'group', 'aria-label': label }, b('−', -1), h('span', { class: 'ov-step-v' }, text), b('+', 1));
}

/// The controls. `changed(what)` — 'limit' | 'cycle' | 'hold' — after the choice is kept: the page redraws them and
/// places its pictures again.
export function liveControls(p, changed) {
  const n = p.limit(), hold = p.hold();
  const cyc = h('input', { type: 'checkbox', 'data-ov-cycle': '', on: { change: (ev) => { p.setCycle(ev.target.checked); changed('cycle'); } } });
  cyc.checked = p.cycle();
  return h('span', { class: 'ov-live', 'data-ov-live': '' },
    h('span', { class: 'ov-lbl', title: 'How many session pictures are live at once — the rest show their last screen' }, 'Live'),
    stepper('Live pictures', n, String(n), 0, SOCKET_CEILING, (v) => { p.setLimit(v); changed('limit'); }),
    h('label', { class: 'ov-toggle', title: 'The live pictures take turns, so every one is brought up to date' }, cyc, 'Cycle'),
    p.cycle() ? stepper('Seconds live per turn', hold, hold + ' s each', 1, 10, (v) => { p.setHold(v); changed('hold'); }) : null,
    h('span', { class: 'ov-cycle-status', 'data-ov-cycle-status': '' }));
}

/// "20 pictures · each again every ~6 s" — or nothing when it does not cycle.
export function paintLiveStatus(root, p, cand) {
  const el = root && root.querySelector('[data-ov-cycle-status]');
  if (!el) return;
  const n = p.limit();
  el.textContent = !p.cycle() || !cand ? '' : cand <= n ? 'all ' + cand + ' live' : cand + ' pictures · each again every ~' + Math.ceil(cand / Math.max(1, n)) * p.hold() + ' s';
}

/// The pictures that hold a live place now, from `cand` (the running ones on screen, in the page's order): `firm` first
/// (the pointed-at sandbox's); then, cycling, the next of the rest in turn `turn`; else those already live
/// (`isLive`), then the first in order.
export function liveTurn(cand, firm, cap, cycling, turn, isLive) {
  const set = new Set(firm.slice(0, cap));
  if (cycling) {
    const rest = cand.filter((x) => !set.has(x));
    const k = cap - set.size, start = rest.length && k > 0 ? ((turn || 0) * k) % rest.length : 0;
    for (let i = 0; i < Math.min(k, rest.length); i++) set.add(rest[(start + i) % rest.length]);
  } else {
    for (const x of cand) if (set.size < cap && isLive(x)) set.add(x);
    for (const x of cand) if (set.size < cap) set.add(x);
  }
  return set;
}
