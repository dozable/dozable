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

import { paintStartProgress } from './app/components/start-progress-fc15d02d5c6b35b1.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-2b30ba761d2d921b.js';
import './app/core/agents-b0c34d5ef450e352.js';
import { api } from './app/core/api-2e66c14d90f7f83a.js';
import { connect } from './app/core/events-7eaaff800f9950b1.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-ba10509cd794543c.js';
import { act } from './app/core/operations-b157c160346b7775.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-df8d259c5e981f96.js';
import { refresh, route } from './app/core/router-ce5dd6bcbdf7c5fe.js';
import './app/core/sandboxes-e50f57c55febd40a.js';
import { bootstrap, signedOut } from './app/core/session-58420e477c9d4278.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-3ae9fe68f586ce42.js';
import { state } from './app/core/state-450cb6573a620304.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-933851e9be49078e.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-3abae15180cc8b7c.js';
import './app/components/access-step-09afb06a7cf08f27.js';
import './app/components/accounts-27f14f4df79f023b.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-cbb8a60e3220f977.js';
import { callout } from './app/components/callout-e7d97c36b36fe970.js';
import './app/components/create-dialog-8484aa411d69673e.js';
import './app/components/dialog-c156b45597794d5a.js';
import { hostChanged, renderHostFoot } from './app/components/host-7c8a44d23bf28f0c.js';
import './app/components/image-picker-d2725bb4df416a4a.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-0540d1744b9a654c.js';
import './app/components/menus-b1e7a64fdf6f51f5.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-c994024a746823eb.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-4c4539148a8a27c0.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-0e797679ef46047b.js';
import './app/components/permissions-32ce4e99960020cf.js';
import { paintTransition } from './app/components/pills-24d9953a9a9b39a1.js';
import './app/components/prep-card-be35217ab46f1958.js';
import { quickAdd } from './app/components/quick-add-ee3db9271baa994b.js';
import './app/components/rules-step-5de53662175cc5bd.js';
import './app/components/stepper-61e5dacc702ce715.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-3860fb4a366360aa.js';
import './app/components/workspace-chooser-0e2bcb412d5048c8.js';
import { viewAccounts } from './app/views/accounts-87fc3adce320ff09.js';
import { renderActivity, viewActivity } from './app/views/activity-bac8bec58ee5e8cd.js';
import { viewDevices } from './app/views/devices-d85757b9f62ed93f.js';
import { viewDoctor } from './app/views/doctor-8052567462c974b5.js';
import { viewImages } from './app/views/images-7b2f4aa0e242c276.js';
import { viewMetrics } from './app/views/metrics-c67df51642a47760.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-7634c08b641b125e.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-3a5acc3a6e2ff265.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-5ee6c870cfd7e549.js';
import { viewOverview } from './app/views/overview-f676927901454ca6.js';
import { viewResources } from './app/views/resources-42cc94c7c97742a9.js';
import { renderTryPrep, viewTry } from './app/views/try-449a4b21c944ec1f.js';
import './app/views/sandbox-dialogs-8a24b813977ec776.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-47d24bc8daed146c.js';
import './app/views/sandbox-network-e11c4d8f8eea379d.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-82daec0e376499e5.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-3d471795b2395a5a.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-c173200cf1273925.js';
import { viewSettings } from './app/views/settings-18d2a177c592d600.js';
import './app/views/shortcuts-0cb7e44ef957c3fe.js';

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
