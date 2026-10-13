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

import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-3758b5050701761c.js';
import './app/core/agents-66154a04b9c4696c.js';
import { api } from './app/core/api-2e66c14d90f7f83a.js';
import { connect } from './app/core/events-d5c9a973c3108d0e.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-ba10509cd794543c.js';
import { act } from './app/core/operations-73b26effbe04935d.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-db311945f71c633c.js';
import { refresh, route } from './app/core/router-01efde03fb80ec68.js';
import './app/core/sandboxes-e50f57c55febd40a.js';
import { bootstrap, signedOut } from './app/core/session-1aade2056efaf7bf.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-70247ce370cb44d9.js';
import { state } from './app/core/state-450cb6573a620304.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-fa5cf7fc28fdb48f.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-3abae15180cc8b7c.js';
import './app/components/access-step-3eca16d95b2d9b40.js';
import './app/components/accounts-04562d99a52eeb10.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-a9b0357c06093925.js';
import { callout } from './app/components/callout-e08cdc5a5cc374bb.js';
import './app/components/create-dialog-e75df476b20764c7.js';
import './app/components/dialog-4d39657de89884ed.js';
import { hostChanged, renderHostFoot } from './app/components/host-2cbf9da41a9e3fff.js';
import './app/components/image-picker-47459405c68906ea.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-6df34f5d0e7faaae.js';
import './app/components/menus-899ea287ec89b464.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-4bece47591b5e2c7.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-1f61b51635a876ef.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-82f2fa6c4cb061e0.js';
import './app/components/permissions-55f927897cfaacbc.js';
import { paintTransition } from './app/components/pills-b1ced72bf0decf4f.js';
import './app/components/prep-card-23eefbc3cb5edd13.js';
import { quickAdd } from './app/components/quick-add-44a29da2e6b88d81.js';
import './app/components/rules-step-7ba262fa77612bef.js';
import './app/components/stepper-86c6252bb76b9d50.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-9954af88b5e8d9b3.js';
import './app/components/workspace-chooser-9f693b1ddde34d32.js';
import { viewAccounts } from './app/views/accounts-19fcd213dc7569fa.js';
import { renderActivity, viewActivity } from './app/views/activity-bac8bec58ee5e8cd.js';
import { viewDevices } from './app/views/devices-d809a40fc60fdf11.js';
import { viewDoctor } from './app/views/doctor-b3d65f202ae82d4f.js';
import { viewImages } from './app/views/images-67a7bb93cd0b4216.js';
import { viewMetrics } from './app/views/metrics-71ae564f8e6d357f.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-7244b1e5bed26ee7.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-1ee80bef1138003a.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-dd59f595a66afa17.js';
import { viewOverview } from './app/views/overview-d19a9f1a65041c94.js';
import { viewResources } from './app/views/resources-b9d0df424171f9e6.js';
import { renderTryPrep, viewTry } from './app/views/try-3d403576e648e81d.js';
import './app/views/sandbox-dialogs-7a820a56e0818100.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-c175ad5f20b2a98b.js';
import './app/views/sandbox-network-0398d41627c35a1c.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals-cace7f50ce9c4550.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-c70600d65c49b0b2.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-f9b372b551ce0a62.js';
import { viewSettings } from './app/views/settings-7556e8bfdb740267.js';
import './app/views/shortcuts-563ebbbb0528fe22.js';

// 599c: Quick add in the sidebar, beside Sandboxes.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
// 617 (owner): TRY is a section of its own — its + opens the Quick try, as its one item does.
$('nav-try-add').replaceChildren(icon('plus'));
$('nav-try-add').addEventListener('click', (ev) => { ev.preventDefault(); location.hash = '#/try'; });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozer.', 'signed-out');
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
  acknowledgeOps, banner, btn, callout, closeWizardModal, connect, dropBanner, failureFor, gridEnter, gridLeave,
  gridRefresh, hostChanged, lifecycle, modalInert, opFailed, openSavedTerminal, openWizardModal, pageFailure,
  paintCover, paintNav, paintResTotal, paintRowOps, paintSplitButton, paintTabs, paintTermEmpty, paintTransition,
  persistLayout, reattachTerminals, refresh, refreshNav, refreshSandbox, renderActivity, renderHostFoot, renderOps,
  renderTerminals, renderTryPrep, renderWizard, showSandbox, signedOut, startApp, toast, viewAccounts, viewActivity, viewDevices, viewDoctor,
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
