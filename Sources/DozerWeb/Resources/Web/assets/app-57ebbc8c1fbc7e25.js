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
import './app/components/accounts-aa06fa2b3ae29e8b.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-a9b0357c06093925.js';
import { callout } from './app/components/callout-e08cdc5a5cc374bb.js';
import './app/components/create-dialog-b89653ce84cdd392.js';
import './app/components/dialog-5af479db6c46c58c.js';
import { hostChanged, renderHostFoot } from './app/components/host-05543a811c4a2925.js';
import './app/components/image-picker-47459405c68906ea.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-2318de5c343910dd.js';
import './app/components/menus-899ea287ec89b464.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-794f9b6c9caf58ce.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-4b973d0fdc466021.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-82f2fa6c4cb061e0.js';
import './app/components/permissions-609e71de85fb75ca.js';
import { paintTransition } from './app/components/pills-b1ced72bf0decf4f.js';
import './app/components/prep-card-23eefbc3cb5edd13.js';
import { quickAdd } from './app/components/quick-add-24ff327b1777c583.js';
import './app/components/rules-step-7ba262fa77612bef.js';
import './app/components/stepper-86c6252bb76b9d50.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-9954af88b5e8d9b3.js';
import './app/components/workspace-chooser-9f693b1ddde34d32.js';
import { viewAccounts } from './app/views/accounts-34398a09f21e9d9f.js';
import { renderActivity, viewActivity } from './app/views/activity-bac8bec58ee5e8cd.js';
import { viewDevices } from './app/views/devices-bef3e0ab59434972.js';
import { viewDoctor } from './app/views/doctor-b3d65f202ae82d4f.js';
import { viewImages } from './app/views/images-0d4c093b95063626.js';
import { viewMetrics } from './app/views/metrics-71ae564f8e6d357f.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-62c885623314f852.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-25ab0083fa8d753a.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-dd59f595a66afa17.js';
import { viewOverview } from './app/views/overview-dc2cf7759aeac1a3.js';
import { viewResources } from './app/views/resources-31309373e17a5813.js';
import { renderTryPrep, viewTry } from './app/views/try-f436ab2b12006946.js';
import './app/views/sandbox-dialogs-984436aacf865759.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-252e474dccc509db.js';
import './app/views/sandbox-network-1d77d0e89a6d8e28.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals-db88a53fdb9de72f.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-fd160f52fb2c9b77.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-6e8b71ae291d94f0.js';
import { viewSettings } from './app/views/settings-8cf91647f2b320d1.js';
import './app/views/shortcuts-563ebbbb0528fe22.js';

// 599c: Quick add in the sidebar, beside Sandboxes.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozer.', 'signed-out');
});

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { devices: 'user-round', overview: 'box', sessions: 'layout-grid', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', onboarding: 'rocket', doctor: 'stethoscope', settings: 'settings' };
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
