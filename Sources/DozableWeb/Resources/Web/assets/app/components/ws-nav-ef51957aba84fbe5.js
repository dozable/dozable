// components/ws-nav — The sidebar's Workspaces: one line per workspace (its state's mark, its name, a caret). The name
// opens its page (#/w/NAME — its Home tab). Unfolded (GET /api/v1/workspaces/{w}): its rooms (`# label`, each its Room
// tab's address: #/w/NAME/room, #/w/NAME/room/LABEL) and its agents — a sandbox's opens its page, a session on this Mac its pane, one elsewhere is a name only.
// Asleep and Finished & archived fold into a line each. What is unfolded is kept in this browser (doz.nav.ws). An unfolded
// workspace a space file made shows its picture first (ui.nav_thumbnails; components/space-picture.js).
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { agentHash, roomHash, workspaceHash } from '../core/routes-9e8c2eeae9c6e070.js';
import { state } from '../core/state-67e05db59fafd5df.js';
import { byState, forgetWorkspaces, isDone, loadWorkspace } from '../core/workspaces-81ddbb96a9d899fa.js';
import { setting } from '../core/settings-bf31bd210264060d.js';
import { forgetThumbs, spaceThumb } from './space-picture-728087b84e783125.js';
import { workspaceDot } from './ws-marks-26369af31d4dbb6f.js';

const KEY = 'doz.nav.ws';
let lastSig = '';
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
  // A picture of each unfolded workspace a space file made (ui.nav_thumbnails, on by default) — none without a file.
  const thumbs = setting('ui.nav_thumbnails', true) !== false;
  forgetThumbs(thumbs ? all.filter((w) => open.has(w.name)).map((w) => w.name) : [], 'nav');
  // Drawn again only when what it shows changed (a redraw is a style recalculation for the whole sidebar).
  const sig = JSON.stringify([all, thumbs, [...open].sort(), [...state.wsDetails.entries()].filter(([n]) => open.has(n)),
    !state.modal && state.view === 'workspace' ? [state.param, state.wsRoom, state.wsTab] : null, state.frame ? [state.frame.workspace, state.frame.agent] : null]);
  if (sig === lastSig && box.childElementCount) { if (!opts.details) for (const w of all) if (open.has(w.name)) readDetail(w.name, 0); return; }
  lastSig = sig;
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
  const here = !state.modal && state.view === 'workspace' && state.param === w.name;
  const toggle = () => { setOpen(w.name, !unfolded); renderNavWorkspaces(); if (!unfolded) readDetail(w.name, 1000); };
  const link = h('a', { href: workspaceHash(w.name), class: 'nav-child nav-ws-name' + (here ? ' active' : ''), 'data-ws-link': w.name,
    title: w.name + ' — ' + w.words + (w.room ? '' : ' · no room yet'), 'aria-current': here ? 'page' : null },
    workspaceDot(w.state, w.words), h('span', { class: 'nav-name' }, w.name));
  const caret = h('button', { type: 'button', class: 'nav-caret' + (unfolded ? '' : ' folded'), 'data-ws-fold': w.name,
    'aria-expanded': unfolded ? 'true' : 'false', 'aria-label': (unfolded ? 'Fold ' : 'Show ') + w.name + '’s rooms and agents',
    title: unfolded ? 'Fold its rooms and agents' : 'Show its rooms and agents',
    on: { click: (ev) => { ev.preventDefault(); ev.stopPropagation(); toggle(); } } }, icon('chevron-down'));
  const thumb = unfolded && setting('ui.nav_thumbnails', true) !== false ? spaceThumb(w, 'nav') : null;
  return h('div', { class: 'nav-sbx nav-ws', role: 'listitem', 'data-nav-ws': w.name }, link, caret,
    thumb ? h('a', { href: workspaceHash(w.name), class: 'nav-ws-thumb', tabindex: '-1', 'aria-hidden': 'true' }, thumb) : null, unfolded ? inside(w) : null);
}

function inside(w) {
  const d = state.wsDetails.get(w.name);
  if (!d) return h('div', { class: 'nav-sessions', role: 'list', 'aria-label': w.name }, h('span', { class: 'nav-sess nav-ws-wait', role: 'listitem' }, 'reading…'));
  const rooms = d.rooms.slice().sort((a, b) => (a.main ? -1 : b.main ? 1 : a.label.localeCompare(b.label))).map((r) => {
    const on = !state.modal && state.view === 'workspace' && state.param === w.name && state.wsTab === 'room' && (r.main ? !state.wsRoom : state.wsRoom === r.label);
    return h('div', { class: 'nav-sess-row', role: 'listitem' },
      h('a', { href: roomHash(w.name, r.main ? null : r.label), class: 'nav-sess nav-ws-room' + (on ? ' active' : ''), 'data-ws-room': r.room,
        title: (r.main ? 'Its main room' : 'Its room') + ' ' + r.room, 'aria-current': on ? 'page' : null },
        h('span', { class: 'nav-hash', 'aria-hidden': 'true' }, '#'), h('span', { class: 'ns-name' }, r.main ? r.room : r.label)));
  });
  const agents = d.agents.map((a) => {
    const dot = h('span', { class: 'ph-dot ph-' + agentPhase(a.state), role: 'img', 'aria-label': a.state + (a.activity ? ' · ' + a.activity : '') });
    const parts = [dot, h('span', { class: 'ns-name' }, a.name), h('span', { class: 'nav-ws-role' }, a.role)];
    const title = a.name + ' — ' + a.role + ' · ' + (a.kind === 'mac' ? 'on this Mac' : a.kind === 'sandbox' ? 'micro VM ' + a.sandbox : 'elsewhere') + ' · ' + a.state
      + (a.activity ? ' · ' + a.activity : '');
    // Its screen in the workspace: its sandbox's or its session's page, framed (an agent elsewhere: its card).
    const on = state.frame && state.frame.workspace === w.name && state.frame.agent === a.name;
    const el = h('a', { href: agentHash(w.name, a.name), class: 'nav-sess nav-ws-agent' + (on ? ' active' : ''), 'data-ws-agent': a.name, title,
      'aria-current': on ? 'page' : null }, ...parts);
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
