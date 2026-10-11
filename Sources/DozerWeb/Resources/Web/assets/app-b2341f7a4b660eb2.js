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
import { api } from './app/core/api-2c3b9826610441d3.js';
import { connect } from './app/core/events-85d5787dd7102ad1.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-9286c622e396fbda.js';
import { act } from './app/core/operations-430d70a292bbd389.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-8ffea41971e59768.js';
import { refresh, route } from './app/core/router-7644c1ee7ecf2350.js';
import './app/core/sandboxes-21105e5d17330dbc.js';
import { bootstrap, signedOut } from './app/core/session-b9f1ef59241a2198.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-2df0efadfc2dcdae.js';
import { state } from './app/core/state-d453713f2a04f6d3.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-fa5cf7fc28fdb48f.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-3abae15180cc8b7c.js';
import './app/components/access-step-a99f9fd587f2ab54.js';
import './app/components/accounts-4085d9653ec62a45.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-72d87e1085f00b4e.js';
import { callout } from './app/components/callout-48fdacc012091bbe.js';
import './app/components/create-dialog-1851d831bbddcc37.js';
import './app/components/dialog-39f26d1bf619d148.js';
import { hostChanged, renderHostFoot } from './app/components/host-0b7239f42398c1b5.js';
import './app/components/image-picker-0179b7fe957b1953.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-859f7b9c19bde1f3.js';
import './app/components/menus-08caea0a1297bf90.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-e04005196044f9ec.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-278258bf224378a9.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-77c4597c42011d6e.js';
import './app/components/permissions-02eca9cf8719959d.js';
import { paintTransition } from './app/components/pills-4768bb74cc2cf525.js';
import './app/components/prep-card-90fc2a630a3d1dbc.js';
import { quickAdd } from './app/components/quick-add-0660b92555f385b1.js';
import './app/components/rules-step-124b3dfb793c8146.js';
import './app/components/stepper-eb70a810bda2f73e.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-547d4aaa0d8a60f6.js';
import './app/components/workspace-chooser-fc12b399ad37dee0.js';
import { viewAccounts } from './app/views/accounts-7b4ac97f01a48414.js';
import { renderActivity, viewActivity } from './app/views/activity-ad20c42c93678edd.js';
import { viewDevices } from './app/views/devices-251a976cc21adb2d.js';
import { viewDoctor } from './app/views/doctor-ba4faefb0af02619.js';
import { viewImages } from './app/views/images-30c65acbc9140c32.js';
import { viewMetrics } from './app/views/metrics-13adb58a0b12484f.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-1788096b67bad7bf.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-e32313f46ecf2f18.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-392ba2828ae3e98f.js';
import { viewOverview } from './app/views/overview-501c30337603594e.js';
import { viewResources } from './app/views/resources-7df3416b6ee371a5.js';
import './app/views/sandbox-dialogs-59d737fcd15e7fc2.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-979e885e39bc1958.js';
import './app/views/sandbox-network-0f64d493a119501c.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals-9dfd61fd1ba44989.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-a6c2fe1b0cd56275.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-ad2c93bada8a29be.js';
import { viewSettings } from './app/views/settings-f613b129a5cb52af.js';
import './app/views/shortcuts-eab3cd8ea0914d97.js';

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
  renderTerminals, renderWizard, showSandbox, signedOut, startApp, toast, viewAccounts, viewActivity, viewDevices, viewDoctor,
  viewImages, viewMetrics, viewNew, viewOnboarding, viewOperations, viewOverview, viewResources, viewSettings,
  wizardStopPolling,
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
