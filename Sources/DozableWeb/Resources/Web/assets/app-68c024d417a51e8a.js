// doz ui — phase 2: the dashboard, and actions.
//
// Rules this file keeps (590.01-DESIGN.md):
//   · Every value from the server is rendered with textContent — never parsed as HTML. Much of it comes
//     from inside a sandbox (hostnames in the net log, session commands, image notes) and a sandbox
//     is untrusted.
//   · The link's capability is read from the fragment ONCE, removed from the address bar and history
//     before anything else, and sent only in the bootstrap's Authorization header.
//   · The CSRF token lives in this page's memory only (never storage, a cookie or a URL).
//   · Every action is one typed request (POST /api/v1/actions, {action, …}); a destructive one carries
//     `confirm`, filled only from a name the person typed. No action ever carries a secret (590's D3).
//     594 (owner ruling): an ACCOUNT's key or token may be typed in a masked field (accountForm) — one
//     POST /api/v1/accounts body, while ui.allow_secret_entry; a sandbox's own key likewise (keyEntry,
//     POST /api/v1/sandboxes/NAME/key).
//   · Forms live in <dialog>s outside the view, so a live refresh never wipes what is being typed.
//   · 605: the page outlives its server. doz ui restarting is a calm pause (terminals reattach, operations
//     resolve, a newer build offers a reload); a sign-in again happens INSIDE the page, over what it shows.

import { paintStartProgress } from './app/components/start-progress-eb5c0bcd9789f74a.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-daa54d8199b5d712.js';
import './app/core/agents-b5713528d20be964.js';
import { api } from './app/core/api-3e1b927edbd234c5.js';
import { connect } from './app/core/events-b3c6922c2fc5a2f9.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-5ec74f6b4925485e.js';
import { act } from './app/core/operations-ff189ebd5e81fa10.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-c4c70d086fc091e4.js';
import { refresh, route } from './app/core/router-54c34db03c1f68ec.js';
import './app/core/sandboxes-02cb10ff22462e6d.js';
import { bootstrap, signedOut } from './app/core/session-47bf3f53b8ee99b4.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-d5d1cc502b79180e.js';
import { state } from './app/core/state-1378d79c750c8380.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-b989b43058be9b08.js';
import './app/components/access-step-df851549cefbfad4.js';
import './app/components/accounts-e9120336569eee1d.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-570a54a4d3e9cb51.js';
import { callout } from './app/components/callout-1bfb54ab68058bf5.js';
import './app/components/create-dialog-97ac79bc108fbeb4.js';
import './app/components/dialog-e229366c3d5e86b3.js';
import { hostChanged, renderHostFoot } from './app/components/host-8f40e8707a02c4fd.js';
import './app/components/image-picker-d09210ffcb0580df.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-9efdfb1dbd54c36a.js';
import './app/components/menus-67717e11502dafd8.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-fcbd61ca069b885e.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-6a291182d8154151.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-4d2f95c7aa4e231b.js';
import './app/components/permissions-3237c4adfe332a77.js';
import { paintTransition } from './app/components/pills-4637e5a942e8545f.js';
import './app/components/prep-card-a2e5a096d3c2d579.js';
import { quickAdd } from './app/components/quick-add-d1a802bff376c9fe.js';
import './app/components/rules-step-c11f4eecf5d4bc4c.js';
import './app/components/stepper-95296ab50568cb6b.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-88f6545ba798f8f7.js';
import './app/components/workspace-chooser-2f3cbbc995e425a0.js';
import { viewAccounts } from './app/views/accounts-208005f62c0d74ff.js';
import { renderActivity, viewActivity } from './app/views/activity-4fcc8319c661df51.js';
import { viewDevices } from './app/views/devices-8a4946df3fb16085.js';
import { viewDoctor } from './app/views/doctor-335af69b8fbc0753.js';
import { viewImages } from './app/views/images-a98cc73e6f1abc47.js';
import { viewMetrics } from './app/views/metrics-878633d142495756.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-2adf0e17ccd37619.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-6d1db33abc13f24e.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-77c6a9afd4734e9d.js';
import { viewOverview } from './app/views/overview-32719af886cb3edc.js';
import { viewResources } from './app/views/resources-06c7c8d461acf4e1.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-72f3094b85aa05d8.js';
import './app/views/sandbox-dialogs-8ee5cb86841d0f0a.js';
import { persistLayout } from './app/views/sandbox-layout-c536e7944211a19d.js';
import './app/views/sandbox-network-e0e77a28b3bc1f30.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-bbf8017a7d1c40f6.js';
import { paintHome } from './app/views/sandbox-home-f6223d3ec4b70ea1.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-f66d1e6f9df67e06.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-f90e20b474eb5829.js';
import { viewSettings } from './app/views/settings-0823739779f37815.js';
import './app/views/shortcuts-548fd5b613309046.js';

// 599c: Quick add in the sidebar, beside Sandboxes.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
// 617 (owner): TRY is a section of its own — its + opens the Quick try, as its one item does.
$('nav-try-add').replaceChildren(icon('plus'));
$('nav-try-add').addEventListener('click', (ev) => { ev.preventDefault(); location.hash = '#/try'; });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozable.', 'signed-out');
});

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { devices: 'user-round', overview: 'box', sessions: 'layout-grid', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', onboarding: 'rocket', doctor: 'stethoscope', settings: 'settings', try: 'play' };
for (const a of document.querySelectorAll('#nav > a[data-view]')) {
  if (NAV_ICONS[a.dataset.view]) a.prepend(icon(NAV_ICONS[a.dataset.view]));
  a.title = a.querySelector('.lbl').textContent;       // the rail's tooltip (the label stays readable to assistive tech)
}
setButton($('sign-out'), 'Sign out');
$('nav-toggle').replaceChildren(icon('panel-right'));
$('nav-toggle').addEventListener('click', (ev) => { ev.stopPropagation(); navRail(!document.body.classList.contains('nav-open')); });
document.addEventListener('click', (ev) => { if (document.body.classList.contains('nav-open') && !ev.target.closest('.side')) navRail(false); });
document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && document.body.classList.contains('nav-open')) navRail(false); });

/// The page's start, once signed in (at load, or — 605 — after its first sign-in inside the page).
async function startApp() {
  if (state.started) return;
  state.started = true;
  {
    if (!/^#\/[a-z]/.test(location.hash)) history.replaceState(null, '', location.pathname + '#/overview');
    await loadSettings();
    // 594 (D8): a store never onboarded opens on the setup wizard (once per page load).
    try {
      const o = await api('overview');
      state.overview = o;
      renderNavSandboxes();
      if (o.onboarded === false && location.hash === '#/overview') history.replaceState(null, '', location.pathname + '#/onboarding');
    } catch (_) { /* the overview says so itself */ }
    route();
    connect();
    if (state.view !== 'resources') scheduleResTotal(0);   // 595: the nav's total (the page measures on its own)
    setInterval(() => {
      if (![...state.ops.values()].some((o) => o.state === 'running')) return;
      paintRowOps();
      if (state.view === 'operations') renderOperations();     // the running ones count their seconds
    }, 1000);
    setInterval(paintRowOps, 15000);
    setInterval(() => { for (const t of terminals.values()) paintCover(t); }, 30000);   // "asleep 7 min"
    // 599 (594.B4): the tabs' {time}, at each minute.
    setTimeout(() => { paintTabs(); setInterval(paintTabs, 60000); }, 60000 - (Date.now() % 60000) + 50);
  }
}

// The calls that go UP the layers (core/hooks.js): every upcall('name') a lower module makes is provided here, once,
// before anything runs.
provide({
  acknowledgeOps, backToTrySetup, banner, btn, callout, closeWizardModal, connect, dropBanner, failureFor, gridEnter, gridLeave,
  gridRefresh, hostChanged, lifecycle, modalInert, opFailed, openWizardModal, pageFailure,
  paintCover, paintHome, paintNav, paintResTotal, paintRowOps, paintSplitButton, paintTabs, paintTransition,
  persistLayout, reattachTerminals, refresh, refreshNav, refreshSandbox, renderActivity, renderHostFoot, renderOps,
  renderTerminals, renderTryPrep, renderWizard, showSandbox, signedOut, startApp, syncConsoleTab, syncBuildLogTab, paintStartProgress, toast, viewAccounts, viewActivity, viewDevices, viewDoctor,
  viewImages, viewMetrics, viewNew, viewOnboarding, viewOperations, viewOverview, viewResources, viewSettings,
  viewTry, wizardStopPolling,
});
// The browser probes' names. The one script's top-level names were globals, and the workspace's browser probes
// (probes/*, over CDP Runtime.evaluate) read and call some of them; module names are not globals, so these stay
// reachable by name as before (only this page's own scripts run here: script-src 'self'). One a lower layer calls
// up is reached through its hook — a probe that wraps it wraps what the page calls. The page itself never uses them.
expose({
  act, api, closeTerminal, focusTerm, gridRefresh, gridSchedule, newSandboxWizard, newShellTerminal, openTerminal,
  pageTerminals, paintTabs, refresh, renderTerminals, resetSetting, saveSetting, sendInput, showUiOverlay, splitWith,
  state, sview, terminals, termUI, uiLost, uiRetryTick, WIZ, wizGo,
});

(async () => { if (await bootstrap()) startApp(); })();
