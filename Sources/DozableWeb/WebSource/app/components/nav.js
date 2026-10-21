// components/nav — The sidebar: a child per sandbox (593), the rail, the Resources total.
import { upcall } from '../core/hooks.js';
import { $, h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { bytes } from '../core/format.js';
import { state } from '../core/state.js';
import { agentChip, agentDot, paintAgentStatuses } from './agent-status.js';
import { moreMenu } from './menus.js';
import { canPeek, peekIcon, peekRegion } from './nav-peek.js';
import { sessionMenuItems } from './session-actions.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const renderHostFoot = upcall('renderHostFoot');

// ── the nav: a child per sandbox (593) ──────────────────────────────────────
// From the overview (`ls` without session counts — never the guest's session holders), re-read on
// the stream's hello, on `changed`, and when an operation ends. Text only.
let navTimer = null;
export function refreshNav() {
  clearTimeout(navTimer);
  navTimer = setTimeout(async () => {
    try { state.overview = await api('overview'); renderNavSandboxes(); } catch (_) { /* the last list */ }
  }, 300);
}
export function renderNavSandboxes() {
  // 594 (owner: "add a link to Onboarding in the left nav"): a dot until this store is onboarded.
  if (state.overview) $('onb-dot').hidden = state.overview.onboarded !== false;
  renderHostFoot();
  const list = state.overview ? state.overview.sandboxes.slice() : [];
  // 617: a try whose create is under way is listed from its Start (its page is already there).
  const p = state.pendingTry;
  if (p && !p.error && !list.some((s) => s.name === p.name)) list.push({ name: p.name, phase: 'off', phaseLabel: 'being made' });
  list.sort((a, b) => a.name.localeCompare(b.name));
  $('nav-count').textContent = state.overview ? String(list.length) : '';
  // A menu open on a session line is never pulled from under the pointer: its close draws the sidebar again.
  if ($('nav-sandboxes').querySelector('.menu:not([hidden])')) return;
  // 603: each sandbox under "All sandboxes", its phase as a dot whose shape says whether it holds RAM (and
  // its word for assistive tech and the tooltip); the one shown is the page's current item.
  // 635 (owner: variant A, collapsible): under each, its sessions — from the host's registry in the overview (never a
  // guest call); a caret folds it to one line with its session count (remembered in this browser).
  const folded = foldedSet();
  if (!$('nav-sandboxes').dataset.peek) { $('nav-sandboxes').dataset.peek = '1'; peekRegion($('nav-sandboxes')); }   // 635
  $('nav-sandboxes').replaceChildren(...list.map((s) => {
    const here = !state.modal && state.view === 'sandbox' && state.param === s.name;
    const sessions = s.sessionList || [];
    const total = sessions.length + (s.sessionMore || 0);
    const fold = total > 0 && folded.has(s.name);
    const link = h('a', { href: '#/sandbox/' + s.name, class: 'nav-child child' + (here && !shownSession(s.name) ? ' active' : ''), 'aria-current': here ? 'page' : null,
      'data-sandbox': s.name, title: s.name + ' — ' + s.phaseLabel },
      h('span', { class: 'ph-dot ph-' + s.phase, role: 'img', 'aria-label': s.phaseLabel }), h('span', { class: 'nav-name' }, s.name),
      fold ? h('span', { class: 'nav-count', title: total + ' session' + (total === 1 ? '' : 's') }, String(total)) : null,
      agentDot(s));                                  // 612: its most urgent agent, when one says something
    const caret = total > 0 ? h('button', { type: 'button', class: 'nav-caret' + (fold ? ' folded' : ''), 'data-nav-fold': s.name,
      'aria-expanded': fold ? 'false' : 'true', 'aria-label': (fold ? 'Show ' : 'Fold ') + s.name + '’s sessions', title: fold ? 'Show its sessions' : 'Fold its sessions',
      on: { click: (ev) => { ev.preventDefault(); ev.stopPropagation(); setFolded(s.name, !fold); renderNavSandboxes(); } } }, icon('chevron-down')) : null;
    const lines = navLines(s, sessions, total, fold);
    return h('div', { class: 'nav-sbx', role: 'listitem', 'data-nav-sbx': s.name }, link, caret,
      lines.length ? h('div', { class: 'nav-sessions', role: 'list', 'aria-label': s.name + '’s sessions', 'data-nav-sessions': s.name }, ...lines) : null);
  }));
  paintAgentStatuses();                              // 612: the chips on screen, and a notice per change
}

// ── 635: a sandbox's sessions in the sidebar ────────────────────────────────────────────────────────────────────────
/// At most this many lines under a sandbox (the last one "N more — Home" when there are more sessions).
const NAV_LINES = 4;
/// The folds, per sandbox, in this browser (a layout convenience, like the inspector's width — never a setting).
function foldedSet() {
  try { const v = JSON.parse(localStorage.getItem('doz.nav.folded') || '[]'); return new Set(Array.isArray(v) ? v.filter((x) => typeof x === 'string') : []); } catch (_) { return new Set(); }
}
function setFolded(name, on) {
  const f = foldedSet();
  if (on) f.add(name); else f.delete(name);
  try { localStorage.setItem('doz.nav.folded', JSON.stringify([...f].slice(-200))); } catch (_) { /* no storage: this page only */ }
}
/// The session the sandbox's page shows now (its selected tab), when that page is open.
function shownSession(name) {
  return !state.modal && state.view === 'sandbox' && state.param === name ? state.session || null : null;
}
function urgent(s, session) {
  const st = (s.sessionStatuses || []).find((x) => x.session === session);
  return !!st && (st.state === 'blocked' || st.state === 'error');
}
/// Which lines a sandbox shows: folded, only a session that needs you or failed; open, all of them up to four —
/// past that, the agent's, any that needs you or failed, the one shown, the rest in order, and "N more — Home" as the
/// fourth line. Always drawn in the list's own order (the agent's first, then by when opened): nothing moves.
function navLines(s, sessions, total, fold) {
  let pick;
  if (fold) pick = sessions.filter((x) => urgent(s, x.name));
  else if (total <= NAV_LINES) pick = sessions;
  else {
    const want = new Set();
    const add = (x) => { if (x && want.size < NAV_LINES - 1) want.add(x.name); };
    add(sessions.find((x) => x.isDefault));
    for (const x of sessions) if (urgent(s, x.name)) add(x);
    add(sessions.find((x) => x.name === shownSession(s.name)));
    for (const x of sessions) add(x);
    pick = sessions.filter((x) => want.has(x.name));
  }
  const lines = pick.map((x) => sessionLine(s, x));
  if (!fold && total > pick.length) {
    lines.push(h('div', { class: 'nav-sess-row', role: 'listitem' },
      h('a', { href: '#/sandbox/' + s.name + '/~home', class: 'nav-sess more', title: 'Every session of ' + s.name + ', on its Home' }, (total - pick.length) + ' more — Home')));
  }
  return lines;
}
function sessionLine(s, x) {
  const active = shownSession(s.name) === x.name;
  const a = h('a', { href: '#/sandbox/' + s.name + '/' + x.name, class: 'nav-sess' + (x.saved ? ' saved' : '') + (active ? ' active' : ''),
    'data-session': x.name, title: x.program + ' · ' + x.name + (x.saved ? ' — its saved screen' : '') },
    icon('terminal'), h('span', { class: 'ns-name' }, x.name), agentChip(s.name, x.name));
  // ⋯ on hover: End and Restart — a running sandbox's (ending a program never wakes one).
  const menu = s.phase === 'running' && !s.busy
    ? moreMenu('More for ' + x.name, sessionMenuItems(s.name, x.name, null), { small: true, data: { navMore: x.name }, onClose: () => setTimeout(renderNavSandboxes, 0) }).el
    : null;
  const row = h('div', { class: 'nav-sess-row', role: 'listitem' }, a);
  // 635 (owner): the screen icon on hover — resting on it shows the session's picture (ui.nav_thumbnails).
  if (canPeek(s.phase, x)) row.append(peekIcon(row, s.name, x));
  if (menu) row.append(menu);
  return row;
}
/// The page's tab changed: the sidebar marks the session it shows (or the sandbox, when Home is shown) — in place.
export function markNavSession() {
  for (const box of document.querySelectorAll('#nav-sandboxes [data-nav-sbx]')) {
    const name = box.dataset.navSbx, shown = shownSession(name);
    const here = !state.modal && state.view === 'sandbox' && state.param === name;
    const link = box.querySelector('a.nav-child');
    if (link) link.classList.toggle('active', here && !shown);
    for (const a of box.querySelectorAll('a.nav-sess[data-session]')) a.classList.toggle('active', a.dataset.session === shown);
  }
}
export function paintNav() {
  for (const a of document.querySelectorAll('#nav > a')) {
    // A sandbox's own page marks its child entry; New sandbox belongs to All sandboxes.
    // (603: an open wizard's entry — Onboarding, or All sandboxes for New sandbox — marks the nav under its modal.)
    const cur = state.modal === 'onboarding' ? 'onboarding' : state.modal === 'new' ? 'overview' : state.modal === 'try' ? 'try' : state.view;
    const on = a.dataset.view === cur;
    a.classList.toggle('active', on);
    if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
  renderNavSandboxes();
  navRail(false);
}
/// 603: below 980 px the sidebar is an icon rail; its toggle shows the whole sidebar over the page.
export function navRail(open) {
  document.body.classList.toggle('nav-open', !!open);
  $('nav-toggle').setAttribute('aria-expanded', open ? 'true' : 'false');
  $('nav-toggle').setAttribute('aria-label', open ? 'Hide the menu' : 'Show the menu');
}
export function paintResTotal(r) {
  const el = $('res-total');
  if (!el || !r) return;
  el.hidden = false;
  el.textContent = bytes(r.totalBytes);
  el.title = 'Dozable uses ' + bytes(r.totalBytes) + ' of disk' + (r.unattributedBytes ? ' — ' + bytes(r.unattributedBytes) + ' unattributed' : '');
  el.classList.toggle('bad', r.unattributedBytes !== 0);
}
