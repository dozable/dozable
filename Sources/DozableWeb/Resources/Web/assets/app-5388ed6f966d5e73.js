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

import { paintStartProgress } from './app/components/start-progress-18f229f5beea64c6.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-b4259996eee60e3d.js';
import './app/core/agents-b5713528d20be964.js';
import { api } from './app/core/api-3e1b927edbd234c5.js';
import { connect } from './app/core/events-88bdf7eaed539ded.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-5ec74f6b4925485e.js';
import { act } from './app/core/operations-ff189ebd5e81fa10.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-d3d59b63e6c1a5c4.js';
import { refresh, route } from './app/core/router-649c6f7118f85118.js';
import './app/core/sandboxes-02cb10ff22462e6d.js';
import { bootstrap, signedOut } from './app/core/session-78090e7e17e019fd.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-d5d1cc502b79180e.js';
import { state } from './app/core/state-1378d79c750c8380.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-b989b43058be9b08.js';
import './app/components/access-step-960e181cf05bd8af.js';
import './app/components/accounts-ac225e9a73cb8134.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-b2be2d3eaa1a3fd0.js';
import { callout } from './app/components/callout-1fe929a7376b7fbc.js';
import './app/components/create-dialog-15dd3efbe35bd8d8.js';
import './app/components/dialog-756ae9b4e276284d.js';
import { hostChanged, renderHostFoot } from './app/components/host-ab99dd81fabb516d.js';
import './app/components/image-picker-b86569d41584a9eb.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-eed34c088324ed4f.js';
import './app/components/menus-5554adcb670bde92.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-e54acca13b808c72.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-ad310570f0801d8c.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-f6630ec2e36e2d1c.js';
import './app/components/permissions-ed5e35f213c9f9ea.js';
import { paintTransition } from './app/components/pills-adc6d8fb09939989.js';
import './app/components/prep-card-83a3985c6cb00ced.js';
import { quickAdd } from './app/components/quick-add-74c24f0d9bbce8d0.js';
import './app/components/rules-step-44f31e5fa9a8b8ad.js';
import './app/components/stepper-633627cca0db123f.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-45739c714df654f9.js';
import './app/components/workspace-chooser-ac0ab2d6ed9fcdbc.js';
import { viewAccounts } from './app/views/accounts-ea1853cb2575abe6.js';
import { renderActivity, viewActivity } from './app/views/activity-4f2c3378ca22d8c2.js';
import { viewDevices } from './app/views/devices-5b537cf5466785d4.js';
import { viewDoctor } from './app/views/doctor-a5a2520734d7f6f1.js';
import { viewImages } from './app/views/images-252da622dd09280e.js';
import { viewMetrics } from './app/views/metrics-10590154858af3c1.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-6414deb9ff342ee6.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-830d69ef4efd62cb.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-b5c11841ca536b78.js';
import { viewOverview } from './app/views/overview-44fe57be192a10a4.js';
import { viewResources } from './app/views/resources-3d48a8554b107048.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-38dab521825892b9.js';
import './app/views/sandbox-dialogs-5fdc1743fdacd269.js';
import { persistLayout } from './app/views/sandbox-layout-6b00edcb151a4a9f.js';
import './app/views/sandbox-network-35a31b055999849f.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-3b2fbf60132dd0d8.js';
import { paintHome } from './app/views/sandbox-home-fde9ef05953c9ff6.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-92cfe75d59d961c5.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-57c40ce6c23051af.js';
import { viewSettings } from './app/views/settings-818330c9a54264de.js';
import './app/views/shortcuts-c7665e31bba00c2a.js';

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
