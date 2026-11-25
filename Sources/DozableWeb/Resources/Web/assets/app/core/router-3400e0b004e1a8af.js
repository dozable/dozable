// core/router — Routing (the addresses are core/routes.js's); the wizards are modals over the page; refresh() renders the view.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { $ } from '../dom/h-f853cc7eb6672c45.js';
import { remeasure } from './measure-da7286b35f0a0fcb.js';
import { loadPreparations } from './operations-7b4c8e49fe46d1d8.js';
import { agentsHash, canonical, HOME, MODAL_VIEWS, parse } from './routes-c03e6aed84ec9eb3.js';
import { state } from './state-1036883eb74b9520.js';
import { loadWorkspace } from './workspaces-5230dd4ac3dbaa71.js';
import { picturesStale } from './space-pictures-a2587b972747a557.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const acknowledgeOps = upcall('acknowledgeOps'), callout = upcall('callout'), chatEnter = upcall('chatEnter'), chatLeave = upcall('chatLeave'),
  chatRefresh = upcall('chatRefresh'), wsEnter = upcall('wsEnter'), wsRefresh = upcall('wsRefresh'),
  closeWizardModal = upcall('closeWizardModal'), gridEnter = upcall('gridEnter'), gridLeave = upcall('gridLeave'),
  gridRefresh = upcall('gridRefresh'), macEnter = upcall('macEnter'), macLeave = upcall('macLeave'), macRefresh = upcall('macRefresh'), openWizardModal = upcall('openWizardModal'), paintNav = upcall('paintNav'),
  paintRowOps = upcall('paintRowOps'), refreshSandbox = upcall('refreshSandbox'),
  showSandbox = upcall('showSandbox'), viewAccounts = upcall('viewAccounts'), viewActivity = upcall('viewActivity'),
  viewDoctor = upcall('viewDoctor'), viewImages = upcall('viewImages'), viewMetrics = upcall('viewMetrics'),
  viewOperations = upcall('viewOperations'), viewOverview = upcall('viewOverview'), viewHome = upcall('viewHome'), viewWorkspaces = upcall('viewWorkspaces'), viewThisMac = upcall('viewThisMac'), viewLoose = upcall('viewLoose'), viewBots = upcall('viewBots'), viewBot = upcall('viewBot'), viewMacs = upcall('viewMacs'),
  viewBrowse = upcall('viewBrowse'), viewRecipes = upcall('viewRecipes'), viewResources = upcall('viewResources'), viewSettings = upcall('viewSettings'), viewDevices = upcall('viewDevices'), viewDebug = upcall('viewDebug'),
  spaceEnter = upcall('spaceEnter'), spaceLeave = upcall('spaceLeave'), viewNotifications = upcall('viewNotifications'), viewWsAgent = upcall('viewWsAgent'), viewIsolationGuide = upcall('viewIsolationGuide'), viewAddWorker = upcall('viewAddWorker'),
  wizardStopPolling = upcall('wizardStopPolling');

// ── routing ─────────────────────────────────────────────────────────────────
// The addresses are core/routes.js's: an old one is REPLACED by its canonical address first (LEGACY), then parsed.
// 603 (owner, on rc.1): #/new and #/onboarding are MODALS over the page under them — that page (state.view, its
// hash state.bgHash) is never re-rendered or torn down by opening or closing one (the sandbox page's terminals
// stay as they are). A deep link opens the modal over Home.
export { MODAL_VIEWS };
// 744: a page that must not be left as it is (the space editor with a dirty file): `fn(to)` → true when it holds the way
// (it asks itself, and sets the address when the person says Leave). A modal's address passes through.
let leaveGuard = null;
export function setLeaveGuard(fn) { leaveGuard = fn || null; }
export function route() {
  const c = canonical(location.hash);
  if (c !== location.hash) { location.replace(c); return; }      // its hashchange routes again
  const p = parse(c);
  state.recipe = p.recipe;
  // 617: #/try/AGENT — the Quick try modal with that agent chosen.
  if (p.modal) {
    if (p.view === 'try') state.tryAgent = p.param;
    if (p.view === 'new-workspace') state.wsnBot = p.param;            // ?bot=NAME: that bot chosen as its manager
    const first = !state.bgHash;
    if (first) { state.view = 'home'; state.param = null; state.session = null; state.bgHash = HOME; routePage(); }
    openWizardModal(p.view, !first);
    return;
  }
  if (state.modal) {
    closeWizardModal();
    if (location.hash === state.bgHash) return;                   // back to the page under it, as it was
  }
  // #/w/NAME/agent/AGENT: its sandbox's or its session's page, framed by the workspace (read first).
  if (p.view === 'wsagent') { enterAgent(p, c); return; }
  state.frame = null;                                             // leaving an agent's screen
  state.wsTab = p.tab;
  state.botTab = p.view === 'bot' ? p.tab : null;            // a bot screen's tab (#/bots/NAME/TAB)
  state.view = p.view;
  state.param = p.param;
  state.session = p.session;
  state.wsRoom = p.room;
  state.bgHash = location.hash;
  routePage();
}
/// An agent's screen: the router reads the workspace's detail, finds the agent and shows the page that already exists for
/// its place — a sandbox's (`state.view = 'sandbox'`, its session selected) or a session's on this Mac (`'mac'`) — with
/// `state.frame` set, so every check of `state.view` keeps working and every address the page writes stays framed
/// (core/routes.js placeHash). An agent with no page (elsewhere, a manager not started, a place gone, none) is a card.
let agentGen = 0;
async function enterAgent(p, hash) {
  const gen = ++agentGen;
  let d = null, error = null;
  try { d = await loadWorkspace(p.param, 1000); } catch (e) { error = e; }
  if (gen !== agentGen || location.hash !== hash) return;
  const a = d ? d.agents.find((x) => x.name === p.agent) || null : null;
  // Can do (#/w/NAME/agent/AGENT/can-do) is a page of its own — the agent's capability table, framed the same way.
  const page = p.tab === 'can-do' ? null
    : a && a.state !== 'gone' && a.state !== 'not started' ? (a.kind === 'sandbox' && a.sandbox ? 'sandbox' : a.kind === 'mac' && a.session ? 'mac' : null) : null;
  state.frame = { workspace: p.param, agent: p.agent, kind: page || 'card', place: page === 'sandbox' ? a.sandbox : page === 'mac' ? a.session : null,
    row: a, detail: d, error, tab: p.tab };
  state.wsTab = null;
  state.wsRoom = null;
  if (page === 'sandbox') { state.view = 'sandbox'; state.param = a.sandbox; state.session = p.session || a.session || null; }
  else if (page === 'mac') { state.view = 'mac'; state.param = null; state.session = a.session; }
  else { state.view = 'wsagent'; state.param = p.param; state.session = null; }
  state.bgHash = location.hash;
  routePage();
}
/// Where a framed page that lost its place goes: its workspace's agents; else the list it came from.
export function lostPlaceHash(fallback) { return state.frame ? agentsHash(state.frame.workspace) : fallback; }

function routePage() {
  picturesStale({ file: true });                                  // arriving: the pictures on screen read afresh
  paintNav();
  // 591: the terminals live in their own section, never re-rendered by refresh() (a live update
  // must not steal a terminal's focus or reparent its canvas). 593: that section is the sandbox
  // page's terminal area; the grid is a section of its own too.
  // This Mac is a section of its own too (its pane is a live terminal).
  // A workspace's page is a section too (#ws): the room surface the Chat page shows is MOVED into it (views/chat.js
  // mountChat — one chat client), so leaving one for the other never closes the stream.
  const onSbx = state.view === 'sandbox', onGrid = state.view === 'sessions', onMac = state.view === 'mac', onChat = state.view === 'chat',
    onWs = state.view === 'workspace', onRoom = onWs && state.wsTab === 'room', onSpace = state.view === 'space';
  $('sbx').hidden = !onSbx;
  $('grid').hidden = !onGrid;
  $('mac').hidden = !onMac;
  $('chat').hidden = !onChat;
  $('ws').hidden = !onWs;
  $('space').hidden = !onSpace;
  document.body.classList.toggle('space-page', onSpace);
  $('view').hidden = onSbx || onGrid || onMac || onChat || onWs || onSpace;
  $('main').classList.toggle('main-chat', onChat || onRoom);
  $('main').classList.toggle('main-ws', onRoom);
  $('main').classList.toggle('main-terms', onSbx);
  if (!onGrid) gridLeave();
  if (!onMac) macLeave();
  if (!onChat && !onWs) chatLeave();
  if (!onSpace) spaceLeave();
  if (state.view !== 'operations') state.opsBox = null;
  if (state.view === 'operations') { acknowledgeOps(); loadPreparations(); }
  if (state.modal !== 'onboarding') wizardStopPolling();
  if (state.view === 'images' || state.view === 'resources') remeasure();   // 595: measured on arrival, Refresh, an op's end
  if (onSbx) { showSandbox(); return; }
  if (onGrid) { gridEnter(); return; }
  if (onMac) { macEnter(state.session); return; }
  if (onChat) { chatEnter(state.param); return; }
  if (onWs) { wsEnter(state.param, state.wsRoom, state.wsTab); return; }
  if (onSpace) { spaceEnter(state.param, state.wsTab === 'watch' ? 'watch' : 'edit'); return; }
  refresh(true);
}
window.addEventListener('hashchange', () => {
  // 605: a link opened in this tab while it waits to sign in signs it in, in place.
  if (state.signedOut && /^#cap=[A-Za-z0-9_-]{16,256}$/.test(location.hash)) {
    const link = location.href;
    history.replaceState(null, '', location.pathname + (state.bgHash || HOME));
    const field = $('signin-link');
    if (field) { field.value = link; $('signin-form').requestSubmit(); }
    return;
  }
  if (state.signedOut) return;
  const to = location.hash, p = parse(canonical(to));
  if (leaveGuard && to !== state.bgHash && !(p && p.modal) && leaveGuard(to)) {
    history.replaceState(null, '', location.pathname + (state.bgHash || HOME));
    return;
  }
  route();
});

let refreshing = false, again = false;
export async function refresh(scrollTop) {
  if (state.signedOut) return;
  if (state.view === 'sandbox') { refreshSandbox(); return; }
  if (state.view === 'sessions') { gridRefresh(false); return; }
  if (state.view === 'mac') { macRefresh(false); return; }
  if (state.view === 'chat') { chatRefresh(); return; }
  if (state.view === 'workspace') { wsRefresh(); return; }
  if (state.view === 'space') return;                             // the editor is never re-rendered by a refresh
  if (refreshing) { again = true; return; }
  refreshing = true;
  try {
    const views = { home: viewHome, workspaces: viewWorkspaces, thismac: viewThisMac, loose: viewLoose, bots: viewBots, bot: viewBot, macs: viewMacs, overview: viewOverview, images: viewImages, resources: viewResources, operations: viewOperations, accounts: viewAccounts,
                    metrics: viewMetrics, activity: viewActivity, doctor: viewDoctor, settings: viewSettings, recipes: viewRecipes, browse: viewBrowse, devices: viewDevices, debug: viewDebug, notifications: viewNotifications,
                    wsagent: viewWsAgent, guide: viewIsolationGuide, addworker: viewAddWorker };
    const fn = views[state.view] || viewHome;
    const node = await fn();
    if (node && !state.signedOut) {
      $('view').replaceChildren(node);
      paintRowOps();
      if (scrollTop) window.scrollTo(0, 0);           // 647: the document scrolls (the header is sticky), not main
    }
  } catch (e) {
    if (!state.signedOut) {
      if (e.status === 404 && state.view === 'sandbox') { location.hash = lostPlaceHash('#/mac/sandboxes'); return; }
      $('view').replaceChildren(callout('bad', { cls: 'notice', title: 'This page could not be read', body: e.message || String(e) }));
    }
  } finally {
    refreshing = false;
    if (again) { again = false; refresh(false); }
  }
}
