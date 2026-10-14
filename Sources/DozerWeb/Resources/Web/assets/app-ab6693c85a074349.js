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

import { paintStartProgress } from './app/components/start-progress-4cdc3233cf47b295.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-3758b5050701761c.js';
import './app/core/agents-66154a04b9c4696c.js';
import { api } from './app/core/api-2e66c14d90f7f83a.js';
import { connect } from './app/core/events-a801390ab99d7153.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-ba10509cd794543c.js';
import { act } from './app/core/operations-b157c160346b7775.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-65462804e40f611f.js';
import { refresh, route } from './app/core/router-ce5dd6bcbdf7c5fe.js';
import './app/core/sandboxes-e50f57c55febd40a.js';
import { bootstrap, signedOut } from './app/core/session-444bcd7608e10aa5.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-3ae9fe68f586ce42.js';
import { state } from './app/core/state-450cb6573a620304.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-933851e9be49078e.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-3abae15180cc8b7c.js';
import './app/components/access-step-bcb9a9cdd95094a2.js';
import './app/components/accounts-93adf2bfb08e23da.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-a9b0357c06093925.js';
import { callout } from './app/components/callout-e08cdc5a5cc374bb.js';
import './app/components/create-dialog-59c5c5763b898edf.js';
import './app/components/dialog-95ecf7dc813b5568.js';
import { hostChanged, renderHostFoot } from './app/components/host-a529bf50cb2ac187.js';
import './app/components/image-picker-3080351bee6082b8.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-46682df2daa422ac.js';
import './app/components/menus-899ea287ec89b464.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-b4e4415533e9e533.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-4d7b6d251ae0f6fd.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-e8352beef02d66d2.js';
import './app/components/permissions-183532240d65b069.js';
import { paintTransition } from './app/components/pills-138e30c7f4fd75c4.js';
import './app/components/prep-card-96c72f29e759cc3b.js';
import { quickAdd } from './app/components/quick-add-a8648dbfe359e875.js';
import './app/components/rules-step-7ba262fa77612bef.js';
import './app/components/stepper-86c6252bb76b9d50.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-4eaf172a8969cd10.js';
import './app/components/workspace-chooser-8f60af6e5a520950.js';
import { viewAccounts } from './app/views/accounts-e807854393cedd64.js';
import { renderActivity, viewActivity } from './app/views/activity-bac8bec58ee5e8cd.js';
import { viewDevices } from './app/views/devices-69ed9b5e002b0aa6.js';
import { viewDoctor } from './app/views/doctor-c7265a10c92b83c4.js';
import { viewImages } from './app/views/images-cb6d0811ec6cd896.js';
import { viewMetrics } from './app/views/metrics-da8d956a633d476d.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-0432bc95c059e17f.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-b0f4d02d8077f167.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-bb951c04fc3f2d95.js';
import { viewOverview } from './app/views/overview-e171237ca4b3d7bf.js';
import { viewResources } from './app/views/resources-f6cbe713791d31d7.js';
import { renderTryPrep, viewTry } from './app/views/try-a8c2c205e5fba799.js';
import './app/views/sandbox-dialogs-0f5051107745050b.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-2321b4ce82ac657c.js';
import './app/views/sandbox-network-cbcfb233b41f254e.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-313e76728d3bcb80.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-1e5df4db1f225eda.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-27a09bce24713a88.js';
import { viewSettings } from './app/views/settings-41d819256b9f5004.js';
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
