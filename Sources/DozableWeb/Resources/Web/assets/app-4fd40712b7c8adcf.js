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

import { paintStartProgress } from './app/components/start-progress-42de28081f7e3e7d.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-daa54d8199b5d712.js';
import './app/core/agents-3a91dadbbdacda1a.js';
import { api } from './app/core/api-3e1b927edbd234c5.js';
import { connect } from './app/core/events-e28893cf7f3f66bc.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-5ec74f6b4925485e.js';
import { act } from './app/core/operations-aeb47e4b98173dcf.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-3930dcc1d1b06874.js';
import { refresh, route } from './app/core/router-61f034481475286a.js';
import './app/core/sandboxes-02cb10ff22462e6d.js';
import { bootstrap, signedOut } from './app/core/session-6371c623805d830f.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-704be829834babad.js';
import { state } from './app/core/state-1378d79c750c8380.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-933851e9be49078e.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-b989b43058be9b08.js';
import './app/components/access-step-9ce9a0fd10f01172.js';
import './app/components/accounts-8517e1a1544b2220.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-570a54a4d3e9cb51.js';
import { callout } from './app/components/callout-1bfb54ab68058bf5.js';
import './app/components/create-dialog-7576d6b26fbda013.js';
import './app/components/dialog-f5a388605bcd2029.js';
import { hostChanged, renderHostFoot } from './app/components/host-d2b9286b1058a13d.js';
import './app/components/image-picker-70b2940cea4fe675.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-d8cb0eb45c9dfc30.js';
import './app/components/menus-67717e11502dafd8.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-97b9abdfd7050f52.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-ac01601be0f1560a.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-6df8238349d487dd.js';
import './app/components/permissions-4106587d2e534b77.js';
import { paintTransition } from './app/components/pills-ee4579836f0ea2a1.js';
import './app/components/prep-card-2b52fee2b2ed15dd.js';
import { quickAdd } from './app/components/quick-add-aa730691a0cdb481.js';
import './app/components/rules-step-c11f4eecf5d4bc4c.js';
import './app/components/stepper-95296ab50568cb6b.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-4e782aa781756869.js';
import './app/components/workspace-chooser-251de38c53fb1983.js';
import { viewAccounts } from './app/views/accounts-f052f8f9ef505076.js';
import { renderActivity, viewActivity } from './app/views/activity-4fcc8319c661df51.js';
import { viewDevices } from './app/views/devices-d83f67a29e814654.js';
import { viewDoctor } from './app/views/doctor-347065cff4702c27.js';
import { viewImages } from './app/views/images-0ceba5c0696221ee.js';
import { viewMetrics } from './app/views/metrics-a441e3a61e27a2af.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-7f466a9a2a7c6617.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-81fbba887413cbf7.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-506ae7ebaab6cba3.js';
import { viewOverview } from './app/views/overview-735e75f292b32104.js';
import { viewResources } from './app/views/resources-e2daed12a06c2f51.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-13db29e0e2963cb7.js';
import './app/views/sandbox-dialogs-defaacff40054e59.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-6aa315aea045e78b.js';
import './app/views/sandbox-network-5321931ec25e12be.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-4f4c0d9c45f30893.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-e08d20d367c9e403.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-39925be795a2fa80.js';
import { viewSettings } from './app/views/settings-f645a5a56650f5cf.js';
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
