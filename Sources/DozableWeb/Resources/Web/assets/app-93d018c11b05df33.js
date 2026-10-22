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

import { paintStartProgress } from './app/components/start-progress-d120ddafb051f626.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-b4259996eee60e3d.js';
import './app/core/agents-b5713528d20be964.js';
import { api } from './app/core/api-0560a03cb0de25ef.js';
import { connect } from './app/core/events-c35f213b2155e048.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-22495ecc7d657367.js';
import { act } from './app/core/operations-1789b4518e764708.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-cdaad179553cd212.js';
import { refresh, route } from './app/core/router-02a6e4601934e1fc.js';
import './app/core/sandboxes-a8ce08093e702ad4.js';
import { bootstrap, signedOut } from './app/core/session-40bbbfc9960e365d.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-d764a83ca7e652e0.js';
import { state } from './app/core/state-dde742b9b2d6390c.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-b989b43058be9b08.js';
import './app/components/access-step-d9f3866ee9fca9b3.js';
import './app/components/accounts-22b9da5974fbb6fb.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-b2be2d3eaa1a3fd0.js';
import { callout } from './app/components/callout-1fe929a7376b7fbc.js';
import './app/components/create-dialog-8978e10c6f0bbd64.js';
import './app/components/dialog-a776616f1988c401.js';
import { hostChanged, renderHostFoot } from './app/components/host-be4bae1fcff710f0.js';
import './app/components/image-picker-d2e2d886b90820fa.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-5633f225c09da44a.js';
import './app/components/menus-5554adcb670bde92.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-1095eed595678690.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-f9c8b8132c67f50d.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-63d38bfc28f739a5.js';
import './app/components/permissions-a3f215dcff459aba.js';
import { paintTransition } from './app/components/pills-13e9749e90c0c151.js';
import './app/components/prep-card-5d96a53549f6778c.js';
import { quickAdd } from './app/components/quick-add-3c22080f3f8c88d8.js';
import './app/components/rules-step-44f31e5fa9a8b8ad.js';
import './app/components/stepper-633627cca0db123f.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-a2a26ecfd1d1c37a.js';
import './app/components/workspace-chooser-063824534dc5bd7d.js';
import { viewAccounts } from './app/views/accounts-26a54eb17fbe68fd.js';
import { renderActivity, viewActivity } from './app/views/activity-ed6e810066d7ffa9.js';
import { viewDevices } from './app/views/devices-75be5c3b7d995b2d.js';
import { viewDoctor } from './app/views/doctor-42283ecaec4d3d08.js';
import { viewImages } from './app/views/images-91a532e25a887266.js';
import { viewMetrics } from './app/views/metrics-a9f750efffb7b104.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-d2b8a05c820ce6d9.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-75ff2b5864a45bad.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-4aa56f6d93d31c08.js';
import { viewOverview } from './app/views/overview-ba9b2fcd05463333.js';
import { viewResources } from './app/views/resources-c707af216e809a8e.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-241eefb6f9ffc3c8.js';
import './app/views/sandbox-dialogs-0539204c1221e451.js';
import { persistLayout } from './app/views/sandbox-layout-ec223d732f3c53e0.js';
import './app/views/sandbox-network-809179e21f42afd9.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-e2d520aa60c74eb8.js';
import { paintHome } from './app/views/sandbox-home-5afca77086473efc.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-d9a1f305072bad93.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-fd11302256892722.js';
import { viewSettings } from './app/views/settings-b6a6791d022e5d1e.js';
import './app/views/shortcuts-97e6516a1604ca12.js';

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
// 635 (owner): light / dark at the foot of the sidebar — it sets ui.theme (Settings › ui.theme "auto" follows macOS again).
const darkNow = () => document.documentElement.dataset.theme ? document.documentElement.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
function paintThemeToggle() {
  const dark = darkNow(), label = dark ? 'Light mode' : 'Dark mode';
  setButton($('theme-toggle'), label, dark ? 'sun' : 'moon');
  $('theme-toggle').title = label + ' (ui.theme)';
}
$('theme-toggle').addEventListener('click', () => {
  const next = darkNow() ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;                    // at once; the setting follows
  paintThemeToggle();
  saveSetting('ui.theme', next).catch((e) => pageFailure('ui.theme was not saved: ' + (e.message || e)));
});
new MutationObserver(paintThemeToggle).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', paintThemeToggle);
paintThemeToggle();
$('nav-toggle').replaceChildren(icon('panel-right'));
$('nav-toggle').addEventListener('click', (ev) => { ev.stopPropagation(); navRail(!document.body.classList.contains('nav-open')); });
document.addEventListener('click', (ev) => { if (document.body.classList.contains('nav-open') && !ev.target.closest('.side')) navRail(false); });
document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && document.body.classList.contains('nav-open')) navRail(false); });
// 635 (owner: "the spinning disc … keeps getting interrupted and resetting"): every spinner turns on the page's clock, not
// from its own start — a spinner drawn again by a refresh carries on at the same angle instead of jumping back to 0°.
document.addEventListener('animationstart', (ev) => {
  if (ev.animationName !== 'spin' || !ev.target.getAnimations) return;
  for (const a of ev.target.getAnimations()) if (a.animationName === 'spin') a.startTime = 0;
});

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
