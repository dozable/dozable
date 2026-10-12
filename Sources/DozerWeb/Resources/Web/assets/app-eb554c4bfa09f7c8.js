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
import { icon, setButton } from './app/dom/icons-75c107270d336b51.js';
import './app/core/agents-66154a04b9c4696c.js';
import { api } from './app/core/api-2e66c14d90f7f83a.js';
import { connect } from './app/core/events-5f9184e2765ed0e4.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-ba10509cd794543c.js';
import { act } from './app/core/operations-379cc141ea59a150.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-6f4fc40d19a11328.js';
import { refresh, route } from './app/core/router-3a1ce714db3aad62.js';
import './app/core/sandboxes-e50f57c55febd40a.js';
import { bootstrap, signedOut } from './app/core/session-1dc0b37f3aeff5e4.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-70247ce370cb44d9.js';
import { state } from './app/core/state-450cb6573a620304.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-fa5cf7fc28fdb48f.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-3abae15180cc8b7c.js';
import './app/components/access-step-57cb78b3c9629932.js';
import './app/components/accounts-cc1caf08b3ca017c.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-72d87e1085f00b4e.js';
import { callout } from './app/components/callout-48fdacc012091bbe.js';
import './app/components/create-dialog-8212e6b67ad2a008.js';
import './app/components/dialog-31a37550491de238.js';
import { hostChanged, renderHostFoot } from './app/components/host-20a6921b64701bb6.js';
import './app/components/image-picker-3d2e5f68e335620f.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-cfeb0ef8e59a3c13.js';
import './app/components/menus-08caea0a1297bf90.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-fc8b1fca66f681b4.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-5fbf7db49f5a5920.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-4f11f25c8bd17c51.js';
import './app/components/permissions-b83a821b54c2de94.js';
import { paintTransition } from './app/components/pills-226afbfa71a8bf6d.js';
import './app/components/prep-card-78c0ecb88e59836b.js';
import { quickAdd } from './app/components/quick-add-d223d9f279489257.js';
import './app/components/rules-step-124b3dfb793c8146.js';
import './app/components/stepper-eb70a810bda2f73e.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-5b3136026659a6f0.js';
import './app/components/workspace-chooser-0c55e45bda183c7e.js';
import { viewAccounts } from './app/views/accounts-4cd1876003e8ebee.js';
import { renderActivity, viewActivity } from './app/views/activity-bac8bec58ee5e8cd.js';
import { viewDevices } from './app/views/devices-518364fa502ad4ec.js';
import { viewDoctor } from './app/views/doctor-35e969ac5918226d.js';
import { viewImages } from './app/views/images-0c6ababbbbbea07d.js';
import { viewMetrics } from './app/views/metrics-05b6b0d21a0149bb.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-557ea0b7c54005e5.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-7ec02e3982961f2c.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-6711f3e8e41821f1.js';
import { viewOverview } from './app/views/overview-fc399d14887a1447.js';
import { viewResources } from './app/views/resources-740281c93fb5d8d8.js';
import { renderTryPrep, viewTry } from './app/views/try-816b4a5a76519445.js';
import './app/views/sandbox-dialogs-434802568c0dbe86.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-ed415c737786b1a3.js';
import './app/views/sandbox-network-54053535d19ddda5.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals-27e66a4a5a1205f2.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-7ab1c93f9838a657.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-94082105cd57cea0.js';
import { viewSettings } from './app/views/settings-e06bb0b26c9e6f3f.js';
import './app/views/shortcuts-089a530dcbffb214.js';

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
