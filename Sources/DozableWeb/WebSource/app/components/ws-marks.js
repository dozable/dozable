// components/ws-marks — A workspace's state (a pill in the CLI's words, the sidebar's dot), who drives it, its manager.
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';

/// A workspace's state as a pill: its glyph and the CLI's words (`setting up`, `waiting on you`); the tone says the state.
const WS_GLYPH = { 'waiting-on-you': 'triangle-alert', working: null, starting: null, idle: 'pause', 'setting-up': 'wrench', asleep: 'moon',
  finished: 'check', archived: 'box' };
export function workspacePill(st, words) {
  const g = st === 'starting' ? h('span', { class: 'mini-spin', 'aria-hidden': 'true' })
    : st === 'working' ? h('span', { class: 'dot ws-working', 'aria-hidden': 'true' }) : WS_GLYPH[st] ? icon(WS_GLYPH[st]) : null;
  return h('span', { class: 'pill ws-' + st, 'data-ws-state': st }, g, words || st.replace(/-/g, ' '));
}
/// The sidebar's mark of a workspace's state: a dot whose shape says it (a ring while setting up, turning while starting).
export function workspaceDot(st, words) {
  const shape = st === 'setting-up' || st === 'finished' || st === 'archived' ? ' mark-ring' : st === 'starting' ? ' mark-turning' : '';
  return h('span', { class: 'ph-dot ws-' + st + shape, role: 'img', 'aria-label': words || st.replace(/-/g, ' ') });
}
/// Who drives the workspace: "you" (the manager's turn comes later).
export function driverChip(driver) {
  return h('span', { class: 'ws-chip ws-driver', title: driver === 'you' ? 'You drive this workspace' : driver + ' drives this workspace' }, driver);
}
/// Its manager: "mira (fenced)"; an unfenced one "otto (unfenced · acts as you)" in the warning tone.
export function managerChip(m) {
  if (!m) return h('span', { class: 'muted' }, '—');
  return h('span', { class: 'ws-chip ws-manager' + (m.actsAsYou ? ' acts-as-you' : ''),
    title: m.actsAsYou ? 'Unfenced on this Mac: it acts as you' : 'Its manager — ' + m.state }, m.actsAsYou ? icon('triangle-alert') : null, m.words);
}
