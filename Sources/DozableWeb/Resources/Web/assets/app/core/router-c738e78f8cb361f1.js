// core/router — Routing (the addresses are core/routes.js's); the wizards are modals over the page; refresh() renders the view.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { $ } from '../dom/h-f853cc7eb6672c45.js';
import { remeasure } from './measure-0234deeea92fad9a.js';
import { loadPreparations } from './operations-ba32b0f4492c5676.js';
import { canonical, HOME, MODAL_VIEWS, parse } from './routes-c2d7dfd271680357.js';
import { state } from './state-58b070d3f17c1c53.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const acknowledgeOps = upcall('acknowledgeOps'), callout = upcall('callout'), chatEnter = upcall('chatEnter'), chatLeave = upcall('chatLeave'),
  chatRefresh = upcall('chatRefresh'),
  closeWizardModal = upcall('closeWizardModal'), gridEnter = upcall('gridEnter'), gridLeave = upcall('gridLeave'),
  gridRefresh = upcall('gridRefresh'), macEnter = upcall('macEnter'), macLeave = upcall('macLeave'), macRefresh = upcall('macRefresh'), openWizardModal = upcall('openWizardModal'), paintNav = upcall('paintNav'),
  paintRowOps = upcall('paintRowOps'), refreshSandbox = upcall('refreshSandbox'),
  showSandbox = upcall('showSandbox'), viewAccounts = upcall('viewAccounts'), viewActivity = upcall('viewActivity'),
  viewDoctor = upcall('viewDoctor'), viewImages = upcall('viewImages'), viewMetrics = upcall('viewMetrics'),
  viewOperations = upcall('viewOperations'), viewOverview = upcall('viewOverview'), viewHome = upcall('viewHome'), viewThisMac = upcall('viewThisMac'), viewLoose = upcall('viewLoose'), viewBots = upcall('viewBots'), viewMacs = upcall('viewMacs'),
  viewBrowse = upcall('viewBrowse'), viewRecipes = upcall('viewRecipes'), viewResources = upcall('viewResources'), viewSettings = upcall('viewSettings'), viewDevices = upcall('viewDevices'), viewDebug = upcall('viewDebug'),
  viewNotifications = upcall('viewNotifications'),
  wizardStopPolling = upcall('wizardStopPolling');

// ── routing ─────────────────────────────────────────────────────────────────
// The addresses are core/routes.js's: an old one is REPLACED by its canonical address first (LEGACY), then parsed.
// 603 (owner, on rc.1): #/new and #/onboarding are MODALS over the page under them — that page (state.view, its
// hash state.bgHash) is never re-rendered or torn down by opening or closing one (the sandbox page's terminals
// stay as they are). A deep link opens the modal over Home.
export { MODAL_VIEWS };
export function route() {
  const c = canonical(location.hash);
  if (c !== location.hash) { location.replace(c); return; }      // its hashchange routes again
  const p = parse(c);
  state.recipe = p.recipe;
  // 617: #/try/AGENT — the Quick try modal with that agent chosen.
  if (p.modal) {
    if (p.view === 'try') state.tryAgent = p.param;
    const first = !state.bgHash;
    if (first) { state.view = 'home'; state.param = null; state.session = null; state.bgHash = HOME; routePage(); }
    openWizardModal(p.view, !first);
    return;
  }
  if (state.modal) {
    closeWizardModal();
    if (location.hash === state.bgHash) return;                   // back to the page under it, as it was
  }
  state.view = p.view;
  state.param = p.param;
  state.session = p.session;
  state.bgHash = location.hash;
  routePage();
}
function routePage() {
  paintNav();
  // 591: the terminals live in their own section, never re-rendered by refresh() (a live update
  // must not steal a terminal's focus or reparent its canvas). 593: that section is the sandbox
  // page's terminal area; the grid is a section of its own too.
  // This Mac is a section of its own too (its pane is a live terminal).
  const onSbx = state.view === 'sandbox', onGrid = state.view === 'sessions', onMac = state.view === 'mac', onChat = state.view === 'chat';
  $('sbx').hidden = !onSbx;
  $('grid').hidden = !onGrid;
  $('mac').hidden = !onMac;
  $('chat').hidden = !onChat;
  $('view').hidden = onSbx || onGrid || onMac || onChat;
  $('main').classList.toggle('main-chat', onChat);
  $('main').classList.toggle('main-terms', onSbx);
  if (!onGrid) gridLeave();
  if (!onMac) macLeave();
  if (!onChat) chatLeave();
  if (state.view !== 'operations') state.opsBox = null;
  if (state.view === 'operations') { acknowledgeOps(); loadPreparations(); }
  if (state.modal !== 'onboarding') wizardStopPolling();
  if (state.view === 'images' || state.view === 'resources') remeasure();   // 595: measured on arrival, Refresh, an op's end
  if (onSbx) { showSandbox(); return; }
  if (onGrid) { gridEnter(); return; }
  if (onMac) { macEnter(state.session); return; }
  if (onChat) { chatEnter(state.param); return; }
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
  if (!state.signedOut) route();
});

let refreshing = false, again = false;
export async function refresh(scrollTop) {
  if (state.signedOut) return;
  if (state.view === 'sandbox') { refreshSandbox(); return; }
  if (state.view === 'sessions') { gridRefresh(false); return; }
  if (state.view === 'mac') { macRefresh(false); return; }
  if (state.view === 'chat') { chatRefresh(); return; }
  if (refreshing) { again = true; return; }
  refreshing = true;
  try {
    const views = { home: viewHome, thismac: viewThisMac, loose: viewLoose, bots: viewBots, macs: viewMacs, overview: viewOverview, images: viewImages, resources: viewResources, operations: viewOperations, accounts: viewAccounts,
                    metrics: viewMetrics, activity: viewActivity, doctor: viewDoctor, settings: viewSettings, recipes: viewRecipes, browse: viewBrowse, devices: viewDevices, debug: viewDebug, notifications: viewNotifications };
    const fn = views[state.view] || viewHome;
    const node = await fn();
    if (node && !state.signedOut) {
      $('view').replaceChildren(node);
      paintRowOps();
      if (scrollTop) window.scrollTo(0, 0);           // 647: the document scrolls (the header is sticky), not main
    }
  } catch (e) {
    if (!state.signedOut) {
      if (e.status === 404 && state.view === 'sandbox') { location.hash = '#/mac/sandboxes'; return; }
      $('view').replaceChildren(callout('bad', { cls: 'notice', title: 'This page could not be read', body: e.message || String(e) }));
    }
  } finally {
    refreshing = false;
    if (again) { again = false; refresh(false); }
  }
}
