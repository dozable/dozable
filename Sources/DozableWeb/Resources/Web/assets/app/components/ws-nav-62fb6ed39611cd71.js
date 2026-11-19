// components/ws-nav — The sidebar's Workspaces: one line per workspace (its state's mark, its name, a caret). The name
// opens its main room (#/chat/ROOM); with no room the line only unfolds. Unfolded (GET /api/v1/workspaces/{w}): its rooms
// (`# label`) and its agents — a sandbox's opens its page, a session on this Mac its pane, one elsewhere is a name only.
// Asleep and Finished & archived fold into a line each. What is unfolded is kept in this browser (doz.nav.ws).
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { state } from '../core/state-58b070d3f17c1c53.js';
import { byState, forgetWorkspaces, isDone, loadWorkspace } from '../core/workspaces-ad329f235e66b166.js';
import { workspaceDot } from './ws-marks-16479f7b77b97bee.js';

const KEY = 'doz.nav.ws';
function openSet() {
  try { const v = JSON.parse(localStorage.getItem(KEY) || '[]'); return new Set(Array.isArray(v) ? v.filter((x) => typeof x === 'string') : []); } catch (_) { return new Set(); }
}
function setOpen(name, on) {
  const s = openSet();
  if (on) s.add(name); else s.delete(name);
  try { localStorage.setItem(KEY, JSON.stringify([...s].slice(-200))); } catch (_) { /* no storage: this page only */ }
}

/// Draw the tree from the last list read (state.workspaces); the unfolded ones' details are read again.
export function renderNavWorkspaces(opts = {}) {
  const box = $('nav-workspaces');
  if (!box) return;
  const all = state.workspaces ? state.workspaces.workspaces : null;
  if (!all) return;
  // The focus stays where it was (the same caret, link or line) across a redraw.
  const f = box.contains(document.activeElement) ? focusKey(document.activeElement) : null;
  forgetWorkspaces(all.map((w) => w.name));
  const open = openSet();
  const sorted = byState(all);
  const live = sorted.filter((w) => w.state !== 'asleep' && !isDone(w));
  const asleep = sorted.filter((w) => w.state === 'asleep');
  const done = sorted.filter(isDone);
  const lines = live.map((w) => line(w, open));
  if (asleep.length) lines.push(group('~asleep', 'Asleep', asleep, open));
  if (done.length) lines.push(group('~done', 'Finished & archived', done, open));
  if (!all.length) lines.push(h('div', { class: 'nav-ws-none', role: 'listitem' }, 'none yet'));
  box.replaceChildren(...lines);
  if (f) { const again = box.querySelector(f); if (again) again.focus(); }
  if (!opts.details) for (const w of all) if (open.has(w.name)) readDetail(w.name, 0);
}

const FOCUS_KEYS = ['wsFold', 'wsLink', 'wsGroup', 'wsAgent', 'wsRoom'];
function focusKey(el) {
  for (const k of FOCUS_KEYS) if (el.dataset && el.dataset[k] !== undefined) {
    return '[data-' + k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase()) + '="' + CSS.escape(el.dataset[k]) + '"]';
  }
  return null;
}

function readDetail(name, maxAgeMs) {
  loadWorkspace(name, maxAgeMs).then(() => renderNavWorkspaces({ details: true })).catch(() => { /* the last one read */ });
}

function line(w, open) {
  const unfolded = open.has(w.name);
  const here = !state.modal && state.view === 'chat' && !!w.room && state.param === w.room;
  const toggle = () => { setOpen(w.name, !unfolded); renderNavWorkspaces(); if (!unfolded) readDetail(w.name, 1000); };
  const link = h('a', { href: w.room ? '#/chat/' + w.room : '#/home', class: 'nav-child nav-ws-name' + (here ? ' active' : ''), 'data-ws-link': w.name,
    title: w.name + ' — ' + w.words + (w.room ? '' : ' · no room yet'), 'aria-current': here ? 'page' : null,
    on: { click: (ev) => { if (!w.room) { ev.preventDefault(); toggle(); } } } },
    workspaceDot(w.state, w.words), h('span', { class: 'nav-name' }, w.name));
  const caret = h('button', { type: 'button', class: 'nav-caret' + (unfolded ? '' : ' folded'), 'data-ws-fold': w.name,
    'aria-expanded': unfolded ? 'true' : 'false', 'aria-label': (unfolded ? 'Fold ' : 'Show ') + w.name + '’s rooms and agents',
    title: unfolded ? 'Fold its rooms and agents' : 'Show its rooms and agents',
    on: { click: (ev) => { ev.preventDefault(); ev.stopPropagation(); toggle(); } } }, icon('chevron-down'));
  return h('div', { class: 'nav-sbx nav-ws', role: 'listitem', 'data-nav-ws': w.name }, link, caret, unfolded ? inside(w) : null);
}

function inside(w) {
  const d = state.wsDetails.get(w.name);
  if (!d) return h('div', { class: 'nav-sessions', role: 'list', 'aria-label': w.name }, h('span', { class: 'nav-sess nav-ws-wait', role: 'listitem' }, 'reading…'));
  const rooms = d.rooms.map((r) => h('div', { class: 'nav-sess-row', role: 'listitem' },
    h('a', { href: '#/chat/' + r.room, class: 'nav-sess nav-ws-room', 'data-ws-room': r.room, title: 'Its room ' + r.room + ' in chat' },
      h('span', { class: 'nav-hash', 'aria-hidden': 'true' }, '#'), h('span', { class: 'ns-name' }, r.label))));
  const agents = d.agents.map((a) => {
    const dot = h('span', { class: 'ph-dot ph-' + agentPhase(a.state), role: 'img', 'aria-label': a.state + (a.activity ? ' · ' + a.activity : '') });
    const parts = [dot, h('span', { class: 'ns-name' }, a.name), h('span', { class: 'nav-ws-role' }, a.role)];
    const title = a.name + ' — ' + a.role + ' · ' + (a.kind === 'mac' ? 'on this Mac' : a.kind === 'sandbox' ? 'micro VM ' + a.sandbox : 'elsewhere') + ' · ' + a.state
      + (a.activity ? ' · ' + a.activity : '');
    const href = a.kind === 'sandbox' ? '#/sandbox/' + a.sandbox + '/~home' : a.kind === 'mac' ? '#/mac/here/' + encodeURIComponent(a.session) : null;
    const el = href ? h('a', { href, class: 'nav-sess nav-ws-agent', 'data-ws-agent': a.name, title }, ...parts)
      : h('span', { class: 'nav-sess nav-ws-agent', 'data-ws-agent': a.name, title }, ...parts);
    return h('div', { class: 'nav-sess-row', role: 'listitem' }, el);
  });
  const hidden = d.hidden ? [h('span', { class: 'nav-sess nav-ws-wait', role: 'listitem' }, d.hidden + ' on this Mac not shown here')] : [];
  const none = !rooms.length && !agents.length && !hidden.length ? [h('span', { class: 'nav-sess nav-ws-wait', role: 'listitem' }, 'no room or agent yet')] : [];
  return h('div', { class: 'nav-sessions', role: 'list', 'aria-label': w.name + '’s rooms and agents', 'data-ws-inside': w.name }, ...rooms, ...agents, ...hidden, ...none);
}

/// An agent's state as a phase the dots know (a sandbox's phase; a session's running / ended / gone).
function agentPhase(s) {
  return ['running', 'booting', 'paused', 'asleep', 'hibernated', 'off', 'failed', 'ended'].includes(s) ? s : 'off';
}

/// Asleep (N), Finished & archived (N): folded into one line; unfolded, their workspaces under it.
function group(key, label, list, open) {
  const unfolded = open.has(key);
  const btn = h('button', { type: 'button', class: 'nav-ws-group', 'data-ws-group': key, 'aria-expanded': unfolded ? 'true' : 'false',
    on: { click: () => { setOpen(key, !unfolded); renderNavWorkspaces(); } } },
    h('span', { class: 'nav-ws-gcaret' + (unfolded ? '' : ' folded') }, icon('chevron-down')), h('span', { class: 'nav-name' }, label + ' (' + list.length + ')'));
  return h('div', { class: 'nav-ws-fold', role: 'listitem' }, btn,
    unfolded ? h('div', { class: 'nav-ws-under', role: 'list', 'aria-label': label }, ...list.map((w) => line(w, open))) : null);
}
