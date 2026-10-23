// components/nav — The sidebar: a child per sandbox (593), the rail, the Resources total.
import { upcall } from '../core/hooks.js';
import { $, h } from '../dom/h.js';
import { icon, mark } from '../dom/icons.js';
import { api } from '../core/api.js';
import { bytes } from '../core/format.js';
import { state } from '../core/state.js';
import { brokenCount } from './account-problems.js';
import { agentChip, agentDot, paintAgentStatuses } from './agent-status.js';
import { moreMenu } from './menus.js';
import { canPeek, peekIcon, peekRegion } from './nav-peek.js';
import { renameItem } from './rename-dialog.js';
import { sessionMenuItems } from './session-actions.js';
import { isAux, pageTerminals } from '../core/terminals.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const renderHostFoot = upcall('renderHostFoot');

// ── the nav: a child per sandbox (593) ──────────────────────────────────────
// From the overview (`ls` without session counts — never the guest's session holders), re-read on
// the stream's hello, on `changed`, and when an operation ends. Text only.
let navTimer = null, navAccounts = false;
/// opts.accounts (641): read the accounts too — on hello, when the server says they changed, and when an account action
/// ends; never on the poll. The badge is otherwise painted from the last list read and the fresh overview.
export function refreshNav(opts) {
  if (opts && opts.accounts) navAccounts = true;
  clearTimeout(navTimer);
  navTimer = setTimeout(async () => {
    const withAccounts = navAccounts;
    navAccounts = false;
    try {
      const [o, a] = await Promise.all([api('overview'), withAccounts ? api('accounts').catch(() => null) : null]);
      state.overview = o;
      if (a) state.accounts = a;
      renderNavSandboxes();
    } catch (_) { /* the last list */ }
  }, 300);
}
/// 641 (owner, D3): Accounts & keys' badge — how many problems break a sandbox's next session (the page's Needs you
/// lines that name one). From the last accounts list and overview; nothing is fetched here.
export function paintAccountsBadge() {
  const el = $('acc-badge');
  if (!el) return;
  const n = state.accounts && state.overview ? brokenCount(state.accounts, state.overview.sandboxes) : 0;
  el.hidden = !n;
  el.textContent = n ? String(n) : '';
  el.title = n ? (n === 1 ? 'A key or sign-in a sandbox relies on does not work' : n + ' keys or sign-ins that sandboxes rely on do not work') : '';
  el.setAttribute('aria-label', el.title);
}
export function renderNavSandboxes() {
  // 594 (owner: "add a link to Onboarding in the left nav"): a dot until this store is onboarded.
  if (state.overview) $('onb-dot').hidden = state.overview.onboarded !== false;
  renderHostFoot();
  paintAccountsBadge();
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
  if (!$('nav-sbx-more').firstChild) $('nav-sbx-more').append(sandboxesMenu());                                       // 642
  $('nav-sandboxes').replaceChildren(...list.map((s) => {
    const here = !state.modal && state.view === 'sandbox' && state.param === s.name;
    const sessions = inTabOrder(s.name, s.sessionList || []);
    const total = sessions.length + (s.sessionMore || 0);
    const fold = total > 0 && folded.has(s.name);
    // 642 (owner): the sandbox's line opens its Home; a click on it while its Home is shown folds or shows its sessions.
    const link = h('a', { href: '#/sandbox/' + s.name + '/~home', class: 'nav-child child' + (here && !shownSession(s.name) ? ' active' : ''), 'aria-current': here ? 'page' : null,
      'data-sandbox': s.name, title: s.name + ' — ' + s.phaseLabel,
      on: { click: (ev) => { if (total > 0 && ev.currentTarget.classList.contains('active')) { ev.preventDefault(); setFolded(s.name, !fold); renderNavSandboxes(); } } } },
      phaseGlyph(s), h('span', { class: 'nav-name' }, s.name),
      fold ? h('span', { class: 'nav-count', title: total + ' session' + (total === 1 ? '' : 's') }, String(total)) : null,
      agentDot(s));                                  // 612: its most urgent agent, when one says something
    const caret = total > 0 ? h('button', { type: 'button', class: 'nav-caret' + (fold ? ' folded' : ''), 'data-nav-fold': s.name,
      'aria-expanded': fold ? 'false' : 'true', 'aria-label': (fold ? 'Show ' : 'Fold ') + s.name + '’s sessions', title: fold ? 'Show its sessions' : 'Fold its sessions',
      on: { click: (ev) => { ev.preventDefault(); ev.stopPropagation(); setFolded(s.name, !fold); renderNavSandboxes(); } } }, icon('chevron-down')) : null;
    const lines = (fold ? sessions.filter((x) => urgent(s, x.name)) : sessions).map((x) => sessionLine(s, x));
    return h('div', { class: 'nav-sbx', role: 'listitem', 'data-nav-sbx': s.name }, link, caret, sandboxLineMenu(s),
      lines.length ? h('div', { class: 'nav-sessions', role: 'list', 'aria-label': s.name + '’s sessions', 'data-nav-sessions': s.name }, ...lines) : null);
  }));
  paintAgentStatuses();                              // 612: the chips on screen, and a notice per change
}

/// Owner, 2026-10-23 ("new three-dot menu in the left nav for each sandbox name"): ⋯ on the sandbox's line, shown on its
/// hover or focus like a session line's — Rename… (the dialog says why it must wait). Never on a try still being made.
function sandboxLineMenu(s) {
  if (!state.overview || !state.overview.sandboxes.some((x) => x.name === s.name)) return null;
  const m = moreMenu('More for ' + s.name, [renameItem(s.name)],
    { small: true, data: { navLineMore: s.name }, onClose: () => setTimeout(renderNavSandboxes, 0) });
  m.el.classList.add('nav-sbx-menu');
  return m.el;
}
/// The sandbox's phase as a dot (its shape says whether it holds RAM); 642 (owner): a hibernated one, a crescent moon.
function phaseGlyph(s) {
  if (s.phase === 'hibernated') { const g = icon('moon'); g.setAttribute('class', 'icon ph-moon ph-hibernated'); g.removeAttribute('aria-hidden');
    g.setAttribute('role', 'img'); g.setAttribute('aria-label', s.phaseLabel); return g; }
  return h('span', { class: 'ph-dot ph-' + s.phase, role: 'img', 'aria-label': s.phaseLabel });
}

// ── 635: a sandbox's sessions in the sidebar ────────────────────────────────────────────────────────────────────────
/// 642 (owner: "always show all sessions in the order they appear in the tab bar"): every session, those with a tab
/// on the sandbox's page first, in the tab bar's order, then the rest in the host's (the agent's, then by when opened).
export function inTabOrder(name, sessions) {
  const tabs = [];
  for (const t of pageTerminals(name)) if (!isAux(t) && t.session && !tabs.includes(t.session)) tabs.push(t.session);
  if (!tabs.length) return sessions;
  const at = (x) => { const i = tabs.indexOf(x.name); return i < 0 ? tabs.length : i; };
  return sessions.map((x, i) => [x, i]).sort((a, b) => at(a[0]) - at(b[0]) || a[1] - b[1]).map(([x]) => x);
}
/// 642 (owner): the Sandboxes heading's ⋯ — Expand all / Collapse all.
function sandboxesMenu() {
  const names = () => (state.overview ? state.overview.sandboxes : []).filter((s) => (s.sessionList || []).length).map((s) => s.name);
  const m = moreMenu('More for Sandboxes', [
    { label: 'Expand all', icon: 'chevron-down', desc: 'Every sandbox’s sessions', onSelect: () => { setFoldedAll([]); renderNavSandboxes(); } },
    { label: 'Collapse all', icon: 'chevron-right', desc: 'Each sandbox on one line (a session that needs you still shows)', onSelect: () => { setFoldedAll(names()); renderNavSandboxes(); } },
  ], { small: true, data: { navSandboxesMore: '' } });
  return m.el;
}
/// The folds, per sandbox, in this browser (a layout convenience, like the inspector's width — never a setting).
function foldedSet() {
  try { const v = JSON.parse(localStorage.getItem('doz.nav.folded') || '[]'); return new Set(Array.isArray(v) ? v.filter((x) => typeof x === 'string') : []); } catch (_) { return new Set(); }
}
function setFolded(name, on) {
  const f = foldedSet();
  if (on) f.add(name); else f.delete(name);
  try { localStorage.setItem('doz.nav.folded', JSON.stringify([...f].slice(-200))); } catch (_) { /* no storage: this page only */ }
}
function setFoldedAll(names) {
  try { localStorage.setItem('doz.nav.folded', JSON.stringify(names.slice(-200))); } catch (_) { /* no storage: this page only */ }
}
/// The session the sandbox's page shows now (its selected tab), when that page is open.
function shownSession(name) {
  return !state.modal && state.view === 'sandbox' && state.param === name ? state.session || null : null;
}
function urgent(s, session) {
  const st = (s.sessionStatuses || []).find((x) => x.session === session);
  return !!st && (st.state === 'blocked' || st.state === 'error');
}
/// 642 (owner: "bring back the app icons in the session glyphs"): the agent's mark when its program is one, else a terminal.
export function sessionGlyph(x) { return x && x.icon && x.icon.d ? mark(x.icon, 'ns-mark') : icon('terminal'); }
function sessionLine(s, x) {
  const active = shownSession(s.name) === x.name;
  const a = h('a', { href: '#/sandbox/' + s.name + '/' + x.name, class: 'nav-sess' + (x.saved ? ' saved' : '') + (active ? ' active' : ''),
    'data-session': x.name, title: x.program + ' · ' + x.name + (x.saved ? ' — its saved screen' : '') },
    sessionGlyph(x), h('span', { class: 'ns-name' }, x.name), agentChip(s.name, x.name));
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
  // 642: a tab opened or closed can change the order — then the sidebar is drawn again.
  for (const s of state.overview ? state.overview.sandboxes : []) {
    const drawn = [...document.querySelectorAll('#nav-sandboxes [data-nav-sbx="' + CSS.escape(s.name) + '"] a.nav-sess[data-session]')].map((a) => a.dataset.session);
    const want = inTabOrder(s.name, s.sessionList || []).map((x) => x.name).filter((n) => drawn.includes(n));
    if (want.join('\n') !== drawn.join('\n')) { renderNavSandboxes(); return; }
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
