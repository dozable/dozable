// views/sandbox-terminals — A sandbox's terminal area: tabs, the split, New shell / New terminal.
import { paintStartProgress } from '../components/start-progress-c1b970a0efee96d0.js';
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon, ICON_OPEN_IN_TERMINAL, phaseMark, setButton, withIcon } from '../dom/icons-0a9984f90615977d.js';
import { agentTitle } from '../core/agents-b5713528d20be964.js';
import { api } from '../core/api-0560a03cb0de25ef.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, transitionOf, waitForOp } from '../core/operations-773ff6e3f3377064.js';
import { opRunningFor, sandboxImage, sandboxPhase } from '../core/sandboxes-a8ce08093e702ad4.js';
import { saveSetting, setting, terminalsAllowed } from '../core/settings-f00434ef195e82b4.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { homePane, isAux, pageTerminals, SPLIT_KINDS, sview, terminals, termUI } from '../core/terminals-e2028f16ee8fa887.js';
import { splitArgs } from '../core/util-1195caf40612902f.js';
import { isRemote } from '../core/session-ca95e16e804ada35.js';
import { btn } from '../components/button-f435595b4098d043.js';
import { dialog } from '../components/dialog-ee9a9a31b03dc349.js';
import { sessionsWhyNot } from '../components/lifecycle-8b27035aea7b7d2b.js';
import { menuButton } from '../components/menus-23bc819d6d81d035.js';
import { markNavSession } from '../components/nav-42e868331cfa85a6.js';
import { agentChip } from '../components/agent-status-29b5cd8d540ae467.js';
import { failureFor, pageFailure } from '../components/notices-90920b2aaea4c446.js';
import { bootTerm, closeTerminal, focusTerm, openBuildLogTerminal, openConsoleTerminal, openHomePane, openTerminal, terminalTitle } from '../components/terminal-db5079cbec33b9cd.js';
import { editorItems, openOnMac } from '../components/open-with-fd762c5c77074f1f.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { openInTerminal, runDetachedDialog } from './sandbox-dialogs-93cc5aaad01eb4f3.js';
import { endSession, sessionAgent, sessionMenuItems } from '../components/session-actions-f9498df9105b2619.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const persistLayout = upcall('persistLayout'), paintHome = upcall('paintHome');

// ── a sandbox's terminal area: tabs, and a split (593: per sandbox; the grid's tiles are apart)
export function paintTabs() { if (state.view === 'sandbox') renderTerminals(); }
export function renderTerminals() {
  try { drawTerminals(); } finally { paintStartProgress(); }   // 617: the build panel follows the tabs (Console takes over at once)
}
function drawTerminals() {
  const root = $('terminals');
  if (!termUI.built) {
    // Split is a split button (owner, 591): the main part splits and ALWAYS fills the right pane
    // with the chosen kind (or, when split, unsplits); the ▾ menu picks the kind — and when already
    // split, adds that kind to the right pane at once.
    const unsplit = () => {
      const v = sview(state.param);
      v.split = false;
      for (const t of pageTerminals(state.param)) t.pane = 0;
      v.selected[0] = v.selected[0] ?? v.selected[1];
      v.selected[1] = null;
      v.focusedPane = 0;
      renderTerminals();
    };
    termUI.splitMain = btn('Split', () => {
      if (sview(state.param).split) unsplit();
      else splitWith(termUI.splitKind).catch((e) => failureFor(state.param, e.message || String(e)));
    }, { small: true, quiet: true, iconOnly: true, icon: 'columns-2', title: 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind] });
    // 603: the caret is a menuButton (kept on screen; the old menu opened off the left edge and its items
    // ended in a literal "null" — replaceChildren writes a null as text, h() skips it).
    const caret = h('button', { type: 'button', class: 'btn sm quiet split-caret caret', title: 'What the split adds', 'aria-label': 'What the split adds' },
      icon('chevron-down'));
    termUI.splitBtn = h('div', { class: 'btn-group split-button', role: 'group', 'aria-label': 'Split' }, termUI.splitMain, caret);
    termUI.splitCtl = menuButton(caret, [], { wrap: termUI.splitBtn, label: 'What the split adds' });
    termUI.splitMenu = termUI.splitCtl.menu;
    // 603 (E3): what makes or arranges terminals sits on the tab strip it changes.
    termUI.newShell = btn('New shell', () => { const n = state.param; newShellTerminal(n).catch((e) => failureFor(n, e.message || String(e))); },
      { small: true, quiet: true, title: 'A new shell session (shell-2, shell-3, …) in a browser terminal' });
    const nsCaret = h('button', { type: 'button', class: 'btn sm quiet caret', title: 'Other terminals', 'aria-label': 'Other terminals' }, icon('chevron-down'));
    const nsGroup = h('div', { class: 'btn-group', role: 'group', 'aria-label': 'New terminal' }, termUI.newShell, nsCaret);
    termUI.nsCtl = menuButton(nsCaret, [], { wrap: nsGroup, label: 'Other terminals' });
    // 635 (owner): a new session of the sandbox's own agent (claude-2, …) beside New shell — shown when it has one.
    termUI.newAgent = btn('New session', () => { const n = state.param; newAgentSession(n).catch((e) => failureFor(n, e.message || String(e))); },
      { small: true, quiet: true, icon: 'plus' });
    termUI.openTerm = btn('Open in Terminal', () => openInTerminal(state.param, null), { small: true, quiet: true, iconOnly: true, icon: ICON_OPEN_IN_TERMINAL });
    // 646 (owner: "open the workspace in my editor"): beside Open in Terminal — the workspace in the Finder or an editor.
    // Never for a LAN device's browser (the routes are mac-screen).
    const openFolder = btn('Open folder', () => {}, { small: true, quiet: true, iconOnly: true, icon: 'folder-open' });
    openFolder.dataset.openFolder = '';
    termUI.openFolderCtl = menuButton(openFolder, [], { label: 'Open the workspace on this Mac' });
    termUI.acts = h('div', { class: 'strip-acts', role: 'toolbar', 'aria-label': 'Terminals' }, termUI.newAgent, nsGroup, termUI.splitBtn,
      isRemote() ? null : termUI.openFolderCtl.el, isRemote() ? null : termUI.openTerm);
    // 635 (owner): the tabs menu, left of Home — every tab open here, Close all tabs, End all sessions.
    const tabsTrigger = h('button', { type: 'button', class: 'tab-x tabs-menu', title: 'The open tabs', 'aria-label': 'The open tabs', 'data-tabs-menu': '' },
      icon('chevron-down'));
    termUI.tabsCtl = menuButton(tabsTrigger, [], { label: 'The open tabs' });
    termUI.panes = [0, 1].map((i) => {
      const strip = h('div', { class: 'tabs', role: 'tablist', 'aria-label': 'Terminals' });
      const head = h('div', { class: 'term-strip' }, i === 0 ? termUI.tabsCtl.el : null, strip);
      const body = h('div', { class: 'term-body' });
      const empty = h('div', { class: 'term-empty' });
      const pane = h('div', { class: 'term-pane', 'data-pane': String(i) }, head, body);
      body.append(empty);
      pane.addEventListener('focusin', () => { if (state.param) sview(state.param).focusedPane = i; });
      pane.addEventListener('mousedown', () => { if (state.param) sview(state.param).focusedPane = i; });
      return { root: pane, strip, head, body, empty };
    });
    termUI.grid = h('div', { class: 'term-grid' }, termUI.panes[0].root, termUI.panes[1].root);
    root.replaceChildren(termUI.grid);
    termUI.built = true;
  }
  const name = state.view === 'sandbox' ? state.param : null;
  const v = name ? sview(name) : { split: false, selected: [null, null] };
  termUI.grid.classList.toggle('split', v.split);
  paintSplitButton();
  termUI.panes[1].root.hidden = !v.split;
  // Another sandbox's terminals stay open (hidden) — going back to it is instant.
  for (const t of terminals.values()) if (!t.grid && t.sandbox !== name) t.els.wrap.hidden = true;
  // 635: Home — the page's first tab, always there (a document: no engine, no socket).
  if (name && !homePane(name)) openHomePane(name);
  termUI.panes.forEach((p, i) => {
    // 635: Home, then Console, then the sessions, then the build log (its own tab, opened from Home); an agent's terminal
    // still PENDING (not drawn yet) is laid out but has no tab.
    const all = name ? pageTerminals(name).filter((t) => t.pane === i) : [];
    const mine = [...all.filter((t) => t.home), ...all.filter((t) => t.mode === 'console'), ...all.filter((t) => !isAux(t) && !t.pending), ...all.filter((t) => t.buildlog)];
    // 635: what is shown when the chosen tab is gone (a close, a session that ended) is Home — never Console.
    if (!mine.some((t) => t.id === v.selected[i])) {
      const home = mine.find((t) => t.home);
      v.selected[i] = home ? home.id : mine.length ? mine[mine.length - 1].id : null;
    }
    p.strip.replaceChildren(...mine.map((t) => tabElement(t, i)));
    scrollActiveTab(p.strip);
    p.empty.hidden = all.length > 0;
    for (const t of all) {
      if (t.els.wrap.parentNode !== p.body) p.body.append(t.els.wrap);
      t.els.wrap.classList.toggle('term-pending', !!t.pending);
      t.els.wrap.hidden = !t.pending && t.id !== v.selected[i];
      if (t.id === v.selected[i] && t.activity) t.activity = false;     // seen
      // 593 §9: a restored tab loads its engine the first time it is shown — a hidden frame has no size,
      // and an interactive attach at no size would resize its session.
      if (t.lazy && !t.els.wrap.hidden) {
        t.lazy = false;
        setTimeout(() => bootTerm(t, setting('ui.terminal_font_size', 13)), 0);
      }
    }
  });
  // The strip's actions on the rightmost pane shown.
  const host = (v.split ? termUI.panes[1] : termUI.panes[0]).head;
  if (termUI.acts.parentNode !== host) host.append(termUI.acts);
  paintStripActs();
  if (name) persistLayout(name);
  // The URL names the session shown (replaceState: no route); Home names none.
  const sel = name && terminals.get(v.selected[v.focusedPane] ?? v.selected[0]);
  // (603: never under a wizard's modal — its URL is #/new or #/onboarding; the page's hash follows.)
  if (sel && sel.session && state.session !== sel.session && !state.modal) {
    state.session = sel.session;
    history.replaceState(null, '', location.pathname + '#/sandbox/' + name + '/' + sel.session);
    state.bgHash = location.hash;
  } else if (sel && sel.home && state.session && !state.modal) {
    state.session = null;
    history.replaceState(null, '', location.pathname + '#/sandbox/' + name);
    state.bgHash = location.hash;
  }
  if (name) paintHome(name);                          // 635: Home's facts follow the tabs ("open in tab 2"), and its pictures
  markNavSession();                                   // 635: the sidebar marks the session shown (or the sandbox, on Home)
}
/// The strip's actions follow the sandbox: a session needs a VM (New shell, Run detached, Open in Terminal); a new
/// terminal waits while something is under way.
export function paintStripActs() {
  if (!termUI.acts) return;
  const name = state.param, s = state.sbx;
  const i = s && s.name === name && s.d ? s.d.info : null;
  const why = i ? sessionsWhyNot(name, i) : 'Loading…';
  const busy = !i || i.busy || i.phase === 'booting' || opRunningFor(name) || !!transitionOf(name);
  termUI.newShell.disabled = !!why;
  termUI.newShell.title = why || 'A new shell session (shell-2, shell-3, …) in a browser terminal';
  termUI.openTerm.disabled = !!why;
  termUI.openTerm.title = why || 'Open in Terminal — your terminal app attaches to the ' + (s && s.d ? s.d.defaultSession : 'default') + ' session';
  const agent = i && s.d.defaultArgv ? agentTitle(i) : null;
  termUI.newAgent.hidden = !agent;
  if (agent) {
    setButton(termUI.newAgent, 'New ' + agent + ' session', 'plus');
    termUI.newAgent.disabled = !!why;
    termUI.newAgent.title = why || 'Another ' + agent + ' session (' + s.d.defaultSession + '-2, …) beside the first, in the same folder';
  }
  if (!termUI.tabsCtl.isOpen()) termUI.tabsCtl.setItems(tabsMenuItems(name));
  if (!isRemote()) paintOpenFolder(name, i);
  if (termUI.nsCtl.isOpen()) return;
  termUI.nsCtl.setItems([
    { label: 'Terminal…', icon: 'terminal', desc: 'A new session: a shell, or a command', disabled: busy, why: 'Wait until it settles', onSelect: () => newTerminalDialog(name) },
    { label: 'Run detached…', icon: 'play', desc: 'A new session running a command, not opened here', disabled: !!why, why, onSelect: () => runDetachedDialog(name) },
  ]);
}
/// 646: the Open folder menu — Show in the Finder, then Open in <editor> for each the host offers (the last used first).
/// A shared workspace is on this Mac in any state of the sandbox; an isolated one has nothing here (disabled, with why).
function paintOpenFolder(name, i) {
  const b = termUI.openFolderCtl.button;
  const why = !i ? 'Loading…' : !i.workspace ? 'Isolated — nothing on this Mac is shared' : null;
  b.disabled = !!why;
  b.title = why || 'Open the workspace — in the Finder or an editor';
  if (why || termUI.openFolderCtl.isOpen()) return;
  const editors = editorItems(name, '/workspace', () => { if (state.param === name) paintStripActs(); });
  termUI.openFolderCtl.setItems([
    { label: 'Show in the Finder', icon: 'folder-open', desc: tildePath(i.workspace), data: { openFinder: '' }, onSelect: () => openOnMac(name, '/workspace') },
    { sep: true },
    ...(editors.length ? editors
      : [{ label: 'No editor found', icon: 'code-xml', disabled: true, why: 'None of the known editors is installed — or name one in bridges.open_apps' }]),
  ]);
}
/// 635 (owner): the tabs menu — every tab of this page (the one shown checked), then Close all tabs (the sessions keep
/// running) and End all sessions (asks first).
function tabsMenuItems(name) {
  if (!name) return [];
  const v = sview(name);
  const tabs = pageTerminals(name).filter((t) => !t.pending);
  const order = tabs.filter((x) => !isAux(x)).map((x) => x.id);
  const items = [...tabs.filter((t) => t.home), ...tabs.filter((t) => t.mode === 'console'), ...tabs.filter((t) => !isAux(t)), ...tabs.filter((t) => t.buildlog)].map((t) => ({
    label: t.home ? 'Home' : t.mode === 'console' ? 'Console' : t.buildlog ? 'Build log' : (order.indexOf(t.id) + 1) + ' · ' + terminalTitle(t),
    icon: t.home ? 'layout-grid' : t.mode === 'console' ? 'cpu' : t.buildlog ? 'wrench' : t.mode === 'watch' ? 'eye' : 'terminal',
    check: v.selected.includes(t.id), data: { tabsItem: String(t.id) },
    onSelect: () => { v.selected[t.pane] = t.id; v.focusedPane = t.pane; renderTerminals(); if (!t.home && !t.buildlog) focusTerm(t); },
  }));
  const closable = tabs.filter((t) => !t.home);
  const s = state.sbx;
  const live = s && s.name === name && s.d ? (s.d.sessions || []).filter((x) => !x.ended && !x.saved) : [];
  const running = sandboxPhase(name) === 'running';
  return [...items, { sep: true },
    { label: 'Close all tabs', icon: 'x', desc: 'Every tab but Home — the sessions keep running', disabled: !closable.length, why: 'Only Home is open',
      data: { tabsCloseAll: '' }, onSelect: () => closeAllTabs(name) },
    { label: 'End all sessions…', icon: 'power', danger: true, desc: 'Every program running in ' + name + ' stops', disabled: !running || !live.length,
      why: running ? 'Nothing is running' : 'Only while it runs', data: { tabsEndAll: '' }, onSelect: () => endAllDialog(name, live.map((x) => x.name)) },
  ];
}
function closeAllTabs(name) {
  const v = sview(name);
  for (const t of pageTerminals(name).filter((x) => !x.home)) {
    if (t.mode === 'console') v.consoleClosed = true;
    closeTerminal(t.id);
  }
  const home = homePane(name);
  if (home) { v.selected[0] = home.id; v.selected[1] = null; v.focusedPane = 0; }
  renderTerminals();
}
function endAllDialog(name, sessions) {
  dialog('End every session of ' + name + '?',
    sessions.length + ' running (' + sessions.join(', ') + ') — each program stops; whatever they are doing now is lost. The sandbox keeps running.',
    [], 'End all sessions', async () => {
      closeAllTabs(name);
      await Promise.all(sessions.map((x) => endSession(name, x)));
    }, { danger: true, icon: 'power' });
}
/// 635 (owner): another session of the sandbox's own agent — its default program, the host names it (claude-2, …).
async function newAgentSession(name) {
  const s = state.sbx;
  const argv = s && s.name === name && s.d ? s.d.defaultArgv : null;
  if (!argv || !argv.length) throw new Error('this sandbox runs no agent');
  const done = await waitForOp(await actOrThrow({ action: 'open-session', sandbox: name, argv }));
  if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
  const m = /^(?:started|already running:) session (\S+) in /.exec(done.text);
  if (!m) throw new Error(done.text);
  openTerminal(name, m[1], 'interactive', sview(name).split ? sview(name).focusedPane : 0);
}
/// A pane's tab strip scrolls sideways when its tabs overflow; the selected tab is always in view
/// (orchestrator ruling, 593 follow-up).
function scrollActiveTab(strip) {
  const w = strip.querySelector('.tab.active')?.closest('.tab-wrap');
  if (!w) return;
  const sr = strip.getBoundingClientRect(), wr = w.getBoundingClientRect();
  if (!sr.width) return;
  if (wr.left < sr.left) strip.scrollLeft += wr.left - sr.left;
  else if (wr.right > sr.right) strip.scrollLeft += wr.right - sr.right;
}
function tabElement(t, pane) {
  const phase = t.ended || t.errorText || t.disconnected ? 'ended'
    : t.saved ? sandboxPhase(t.sandbox) || 'unknown' : (t.state && t.state.phase) || 'unknown';
  const v = sview(t.sandbox);
  // Tabs are numbered (1, 2, …) per sandbox, so a shared session can say which tab it is shared with.
  // Numbered 1, 2, … — Home, the build log and Console are the page's own, not numbered; a pending one is not a tab yet.
  const order = pageTerminals(t.sandbox).filter((x) => !isAux(x) && !x.pending).map((x) => x.id);
  if (t.home) return homeTab(t, pane, v);
  if (t.mode === 'console') return consoleTab(t, pane, v);
  if (t.buildlog) return buildLogTab(t, pane, v);
  const num = order.indexOf(t.id) + 1;
  const label = num + ' · ' + terminalTitle(t);
  const twins = t.session && !t.ended ? pageTerminals(t.sandbox).filter((o) => o.id !== t.id && !o.ended && o.session === t.session) : [];
  const shared = twins.length ? h('span', { class: 'tag shared', title: 'Two views of ONE session: what is typed in either shows in both' },
    'shared with tab ' + twins.map((o) => order.indexOf(o.id) + 1).join(', ')) : null;
  const select = h('button', { type: 'button', role: 'tab', class: 'tab' + (t.id === v.selected[pane] ? ' active' : ''),
                               // 594 (W14): the one hint a mouse-using program needs.
                               title: (t.title ? t.title + ' — ' + label : label) + '\nShift+drag selects text while the program uses the mouse',
                               'data-term': String(t.id),
                               on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); focusTerm(t); } } },
    h('span', { class: 'tab-dot ph-' + phase + phaseMark(phase), 'aria-hidden': 'true' }), icon(t.mode === 'watch' ? 'eye' : 'terminal'), label,
    t.activity ? h('span', { class: 'tab-activity', 'data-tab-activity': '', title: 'Ready — it has drawn its screen', 'aria-label': 'ready' }) : null,
    t.mode === 'watch' ? h('span', { class: 'tag' }, 'watch') : null,
    t.session && !t.bootlog ? agentChip(t.sandbox, t.session) : null,     // 612: what its agent is doing
    t.saved ? h('span', { class: 'tag saved', title: 'Its last saved screen (' + (t.saved.reason || 'saved') + ', ' + when(t.saved.savedAt) + ') — it goes live when the sandbox runs' }, 'saved') : null,
    shared);
  const move = v.split ? h('button', { type: 'button', class: 'tab-x', title: 'Move to the other pane', 'aria-label': 'Move ' + label + ' to the other pane',
    on: { click: () => { t.pane = 1 - t.pane; v.selected[t.pane] = t.id; renderTerminals(); focusTerm(t); } } }, icon('arrow-left-right')) : null;
  // 635 (owner): the close box reads as "end it" — a running session's asks: End, Hide (it keeps running) or Cancel.
  const agent = isAgentTab(t);
  const close = h('button', { type: 'button', class: 'tab-x', 'aria-label': 'Close ' + label,
    title: askOnClose(t, twins) ? 'Close — end ' + t.session + ', or hide its tab and keep it running' : 'Close the tab',
    on: { click: () => (askOnClose(t, twins) ? closeTabDialog(t) : closeSessionTab(t, agent)) } }, icon('x'));
  // 608: Restart session / End session — for a running session of a running sandbox.
  const live = t.session && !t.saved && !t.ended && !t.restarting && !t.bootlog && sandboxPhase(t.sandbox) === 'running';
  // The menu is kept on the terminal across re-renders (a title or phase change re-renders the strip — an open
  // menu must not vanish under the pointer).
  if (live && !t.sessionMenu) {
    t.sessionMenu = menuButton(h('button', { type: 'button', class: 'tab-x', title: 'Session ' + t.session + ': restart or end it',
      'aria-label': 'More for session ' + t.session, 'data-session-menu': t.session }, icon('ellipsis-vertical')), sessionMenuItems(t.sandbox, t.session, null),
      { align: 'end', label: 'Session ' + t.session });
  } else if (!live && t.sessionMenu) t.sessionMenu = null;
  const menu = live ? t.sessionMenu.el : null;
  return h('div', { class: 'tab-wrap' + (t.id === v.selected[pane] ? ' is-active' : '') }, select, move, menu, close);
}
/// 635: the agent's own interactive tab on its running session — the one whose close lands on Home with the note.
function isAgentTab(t) {
  const s = state.sbx;
  return !!(s && s.name === t.sandbox && s.d && t.session && t.session === s.d.defaultSession && t.mode === 'interactive'
    && !t.saved && !t.ended && !t.pending && sandboxPhase(t.sandbox) === 'running');
}
/// 635 (owner): the close box asks when it would leave a running session with no view here — an interactive tab of a
/// running sandbox's live session that no other tab shows. A watch, a saved screen, an ended one or a twin just closes.
function askOnClose(t, twins) {
  return !!t.session && t.mode === 'interactive' && !t.saved && !t.ended && !t.restarting && !t.bootlog && !t.pending
    && !twins.length && sandboxPhase(t.sandbox) === 'running';
}
/// End (the default, destructive), Hide — keep it running (the tab goes, the session goes on), Cancel.
function closeTabDialog(t) {
  const who = sessionAgent(t.sandbox, t.session);
  const d = dialog('Close ' + t.session + '?',
    'End stops ' + (who || 'its program') + ' — whatever it is doing now is lost. Hide closes the tab and keeps it running: Home, the sidebar and the tabs menu open it again.',
    [], 'End session', async () => {
      closeSessionTab(t, false);
      await endSession(t.sandbox, t.session);
    }, { danger: true, icon: 'power' });
  const hide = h('button', { type: 'button', class: 'btn', 'data-close-hide': '', on: { click: () => { d.close(); closeSessionTab(t, false); } } },   // chosen knowing: no note on Home
    withIcon('eye-off', 'Hide — keep running'));
  d.querySelector('.dlg-buttons button[type="submit"]').before(hide);
  hide.focus();
}
/// 635: a person closed a session's tab: it goes (the session runs on) and Home is shown; the agent's tab marks its card.
function closeSessionTab(t, agent) {
  const v = sview(t.sandbox);
  const shown = v.selected.includes(t.id);
  if (agent && setting('ui.explain_tab_close', true)) v.justClosed = t.session;
  closeTerminal(t.id);
  const home = homePane(t.sandbox);
  if (shown && home && t.pane === 0) { v.selected[0] = home.id; v.focusedPane = 0; renderTerminals(); }
}
/// 635: Home — the page's first tab: a box, no number, no close box; the number of sessions running.
function homeTab(t, pane, v) {
  const s = state.sbx;
  const live = s && s.name === t.sandbox && s.d ? (s.d.sessions || []).filter((x) => !x.ended && !x.saved).length : 0;
  const select = h('button', { type: 'button', role: 'tab', class: 'tab tab-home' + (t.id === v.selected[pane] ? ' active' : ''),
    title: 'Home — every session of ' + t.sandbox + ', its logs and its folder', 'data-term': String(t.id), 'data-home-tab': t.sandbox,
    on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); } } },
    icon('layout-grid'), 'Home', live ? h('span', { class: 'count', title: live + ' running' }, String(live)) : null);
  return h('div', { class: 'tab-wrap is-home' + (t.id === v.selected[pane] ? ' is-active' : '') }, select);
}
/// 617: the system console. 635: an ordinary tab — closable at any time (even during a boot); once closed it stays
/// closed until the next Start (Home › Logs › Console opens it again).
function consoleTab(t, pane, v) {
  const select = h('button', { type: 'button', role: 'tab', class: 'tab tab-console' + (t.id === v.selected[pane] ? ' active' : ''),
    title: 'The system console (the kernel and vminitd) — what doz console ' + t.sandbox + ' shows; read-only', 'data-term': String(t.id), 'data-console-tab': t.sandbox,
    on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); focusTerm(t); } } },
    icon('cpu'), 'Console');
  const close = h('button', { type: 'button', class: 'tab-x', title: 'Close the console — it stays closed until the next start (Home › Logs opens it again)',
    'aria-label': 'Close Console', 'data-console-close': t.sandbox,
    on: { click: () => { v.consoleClosed = true; closeTerminal(t.id); } } }, icon('x'));
  return h('div', { class: 'tab-wrap' + (t.id === v.selected[pane] ? ' is-active' : '') }, select, close);
}
/// 635 (owner): the build log — its own tab, opened from Home › Logs (never by itself); a spanner, no number; closable.
function buildLogTab(t, pane, v) {
  const select = h('button', { type: 'button', role: 'tab', class: 'tab tab-buildlog' + (t.id === v.selected[pane] ? ' active' : ''),
    title: 'Build log — how ' + (t.buildlogInfo ? t.buildlogInfo.image : 'its image') + ' was built' + (t.buildlogInfo ? (t.buildlogInfo.state === 'done' ? ', ' : ' (it failed), ') + when(t.buildlogInfo.finishedAt) : '') + ': the steps and their output (read-only)',
    'data-term': String(t.id), 'data-buildlog-tab': t.sandbox,
    on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); } } },
    icon('wrench'), 'Build log');
  const close = h('button', { type: 'button', class: 'tab-x', title: 'Close the build log (Home › Logs opens it again)', 'aria-label': 'Close Build log',
    on: { click: () => closeTerminal(t.id) } }, icon('x'));
  return h('div', { class: 'tab-wrap' + (t.id === v.selected[pane] ? ' is-active' : '') }, select, close);
}
/// 617: the image's kept build log, read once per page (a 404: none kept), forgotten while the image is being built (its
/// new log replaces it when the build ends — `stale`). 635 (owner): never opened by itself — Home › Logs › Build log
/// opens it in its own tab (`openBuildLog`).
export function syncBuildLogTab(name) {
  if (!terminalsAllowed() || !name) return;
  const image = sandboxImage(name);
  const building = !!image && (state.preps || []).some((p) => p.image === image && (p.state === 'running' || p.state === 'cancelling'));
  const kept = (state.buildLogs = state.buildLogs || new Map());
  const was = (state.blogBuilding = state.blogBuilding || new Set());
  const stale = was.has(name) && !building;           // a build of its image just ended: its new log replaces the tab
  if (building) was.add(name); else was.delete(name);
  if (building || stale) { for (const t of pageTerminals(name).filter((x) => x.buildlog)) closeTerminal(t.id); kept.delete(name); }
  if (building || kept.has(name)) return;
  kept.set(name, null);
  api('sandboxes/' + name + '/build-log').then((log) => { kept.set(name, log); paintHome(name); })
    .catch(() => { /* none kept (404), or not now: Home has no Build log row */ });
}
/// 635: the build log in its own tab (shown), from what `syncBuildLogTab` read.
export function openBuildLog(name) {
  const log = state.buildLogs && state.buildLogs.get(name);
  const have = pageTerminals(name).find((t) => t.buildlog);
  const t = have || (log ? openBuildLogTerminal(name, log) : null);
  if (!t) return;
  const v = sview(name);
  v.selected[t.pane] = t.id; v.focusedPane = t.pane;
  renderTerminals();
}
/// 617: Console exists while the sandbox's VM is powered on (booting, running, paused); it goes when it shuts down,
/// sleeps or hibernates, and comes back at the next power-on. A start under way (an agent's terminal still pending)
/// shows it at once. 635: closed by the person, it stays closed until the next START — a cold boot from off or failed
/// (never a wake: someone who closed it does not want it back after every sleep).
export function syncConsoleTab(name, phase) {
  const on = ['booting', 'running', 'paused'].includes(phase);
  const v = sview(name);
  const before = v.consolePhase;
  v.consolePhase = phase;
  if (on && (before === 'off' || before === 'failed')) v.consoleClosed = false;
  const have = pageTerminals(name).filter((t) => t.mode === 'console');
  if (on && !have.length && !v.consoleClosed) openConsoleTerminal(name, pageTerminals(name).some((t) => t.pending));
  // A read of the phase can be older than the start under way: Console stays while the agent's terminal still waits.
  else if (!on && !pageTerminals(name).some((t) => t.pending)) for (const t of have) closeTerminal(t.id);
}
const SPLIT_ICONS = { shell: 'plus', watch: 'eye', attach: 'link', dialog: 'terminal' };
export function paintSplitButton() {
  if (!termUI.splitMain) return;
  const split = state.param ? sview(state.param).split : false;
  setButton(termUI.splitMain, split ? 'Unsplit' : 'Split', 'columns-2');
  termUI.splitMain.title = split ? 'Back to one pane (the right pane’s terminals move left)'
                                 : 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind];
  termUI.splitCtl.setItems(Object.entries(SPLIT_KINDS).map(([kind, label]) => ({
    label: (split ? 'Add a ' : 'Split with a ') + label, icon: SPLIT_ICONS[kind], check: kind === termUI.splitKind, data: { kind },
    desc: kind === termUI.splitKind ? 'the default (ui.split_default)' : null,
    onSelect: () => {
      termUI.splitKind = kind;
      // The choice is the setting ui.split_default (doz.toml), not this browser's.
      if (setting('ui.split_default', 'shell') !== kind) saveSetting('ui.split_default', kind).catch((e) => pageFailure('ui.split_default was not saved: ' + (e.message || e)));
      paintSplitButton();
      splitWith(kind).catch((e) => failureFor(state.param, e.message || String(e)));
    },
  })));
}
/// Split (if needed) and fill the right pane with `kind` — so a split always creates something.
/// With no terminal on the left there is nothing to watch, attach to or put a shell beside: the
/// New terminal dialog opens instead (for the right pane).
export async function splitWith(kind) {
  const name = state.param;
  if (state.view !== 'sandbox' || !name) return;
  const v = sview(name);
  const left = terminals.get(v.selected[0]) || pageTerminals(name).find((t) => t.pane === 0);
  if (!v.split) { v.split = true; renderTerminals(); }
  v.focusedPane = 1;
  if (kind === 'dialog' || !left) { await newTerminalDialog(name); return; }
  if (kind === 'watch' || kind === 'attach') {
    if (!left.session) throw new Error('the left terminal has no session yet — wait for it to start');
    openTerminal(name, left.session, kind === 'watch' ? 'watch' : 'interactive', 1);
    return;
  }
  await newShellTerminal(name, 1);
}

async function newTerminalDialog(sandbox) {
  const names = [sandbox || state.param].filter(Boolean);
  if (!names.length) { pageFailure('Open a sandbox first'); return; }
  const first = names[0];
  // What to open: ALWAYS a new session (593 §9 S4, owner — after "New terminal" attached to a session that
  // already ran): a new shell, or a new session running a command. A running session is reached through
  // its pane or the sessions list (Details › Sessions: Open / Watch), never from here.
  const d = dialog('New terminal in ' + first, 'A new session: a shell, or a command. A session that already runs is opened from the Sessions list.', [
    { name: 'sandbox', label: 'Sandbox', type: 'select', options: names, value: first },
    { name: 'what', label: 'Open', type: 'select', options: [['new', 'New shell'], ['command', 'New session running a command…']] },
    { name: 'session', label: 'Session name (new session only)', placeholder: 'e.g. worker' },
    { name: 'command', label: 'Command (new session only)', placeholder: 'e.g. htop — no shell in front (say bash -lc \'…\' for one)' },
  ], 'Open', async (v) => {
    const sv = sview(v.sandbox);
    const pane = sv.split ? sv.focusedPane : 0;
    if (v.what === 'new') { await newShellTerminal(v.sandbox, pane); return; }
    if (v.what === 'command') {
      const argv = splitArgs(v.command);
      if (!argv.length) throw new Error('the command is empty');
      if (!v.session) throw new Error('a new session needs a name');
      const done = await waitForOp(await actOrThrow({ action: 'open-session', sandbox: v.sandbox, session: v.session, argv }));
      if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
      if (!done.text.startsWith('started')) throw new Error('a session named ' + v.session + ' already runs — pick another name (open it from the Sessions list)');
      openTerminal(v.sandbox, v.session, 'interactive', pane);
      return;
    }
    throw new Error('pick what to open');
  });
  const sandboxSel = d.querySelector('[name="sandbox"]'), whatSel = d.querySelector('[name="what"]');
  sandboxSel.closest('label').hidden = true;             // 593: the page's sandbox
  const nameField = d.querySelector('[name="session"]').closest('label'), cmdField = d.querySelector('[name="command"]').closest('label');
  const showFields = () => { const c = whatSel.value === 'command'; nameField.hidden = !c; cmdField.hidden = !c; };
  whatSel.addEventListener('change', showFields);
  showFields();
}

/// A NEW shell session in `sandbox` — `shell-2`, `shell-3`, … (the next name not taken), running a
/// login shell — opened with the ordinary open-session action (one HostOp; its idempotency unchanged:
/// a name that turns out to be taken answers "already running", and the next name is tried).
export async function newShellTerminal(sandbox, pane) {
  if (!terminalsAllowed()) return;
  let rows = [], detail = null;
  try { [detail, rows] = await Promise.all([api('sandboxes/' + sandbox), api('sandboxes/' + sandbox + '/sessions')]); } catch (_) { /* asleep: listed after the wake */ }
  const argv = loginShell(detail, rows);
  const taken = new Set(rows.map((r) => r.name));
  for (let n = 2, tries = 0; tries < 20; n++) {
    const name = 'shell-' + n;
    if (taken.has(name)) continue;
    tries++;
    const op = await actOrThrow({ action: 'open-session', sandbox, session: name, argv });
    const done = await waitForOp(op);
    if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
    if (done.text.startsWith('started')) { openTerminal(sandbox, name, 'interactive', pane); return; }
    taken.add(name);                                   // it already ran (a sandbox that was asleep): the next one
  }
  throw new Error('no free shell-N name');
}
/// `bash -l` where the image has bash (the built-in images, and custom images made from them; or
/// any running session that is bash), else `sh -l`.
function loginShell(detail, rows) {
  const image = detail && detail.info ? detail.info.image : '';
  const hasBash = ['lab', 'claude-code', 'pi', 'codex'].includes(image) || rows.some((r) => /(^|\/)bash(\s|$)/.test(r.command));
  return hasBash ? ['bash', '-l'] : ['sh', '-l'];
}
