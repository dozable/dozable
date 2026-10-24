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

import { paintStartProgress } from './app/components/start-progress-c1b970a0efee96d0.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-f853cc7eb6672c45.js';
import { icon, setButton } from './app/dom/icons-0a9984f90615977d.js';
import './app/core/agents-b5713528d20be964.js';
import { api } from './app/core/api-0560a03cb0de25ef.js';
import { connect } from './app/core/events-5f7d44da81a05c54.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-22495ecc7d657367.js';
import { act } from './app/core/operations-773ff6e3f3377064.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-edfc023781d71857.js';
import { refresh, route } from './app/core/router-8ebdf5b2cbf5479f.js';
import './app/core/sandboxes-a8ce08093e702ad4.js';
import { bootstrap, signedOut } from './app/core/session-81e998f6bbb5650a.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-f00434ef195e82b4.js';
import { state } from './app/core/state-dde742b9b2d6390c.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-b989b43058be9b08.js';
import './app/components/access-step-18f48f09f9d0c75e.js';
import './app/components/accounts-8f66ef0dfb05f93a.js';
import './app/components/blocks-6b2d43608253a84f.js';
import { btn } from './app/components/button-f435595b4098d043.js';
import { callout } from './app/components/callout-045a1af4db6ce704.js';
import './app/components/create-dialog-f509ea2d17d7ad69.js';
import './app/components/dialog-ee9a9a31b03dc349.js';
import { hostChanged, renderHostFoot } from './app/components/host-50f984429c6d7ea9.js';
import './app/components/image-picker-6635d4506d316a99.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-8b27035aea7b7d2b.js';
import './app/components/menus-23bc819d6d81d035.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-e09494a00630f43b.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-8ff005d496c3ab03.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-90920b2aaea4c446.js';
import './app/components/permissions-e49cffa2c0d6b8da.js';
import { paintTransition } from './app/components/pills-d7769a342034f780.js';
import './app/components/prep-card-46c3d88d0cf84e93.js';
import { quickAdd } from './app/components/quick-add-c6046f005ed78bfd.js';
import './app/components/rules-step-f6e11413ec922aa2.js';
import './app/components/stepper-42382a875b43605e.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-db5079cbec33b9cd.js';
import './app/components/workspace-chooser-35cbe6cb454a56e1.js';
import { viewAccounts } from './app/views/accounts-2c35099dedd755de.js';
import { renderActivity, viewActivity } from './app/views/activity-e18fdfc0b030760f.js';
import { viewDevices } from './app/views/devices-990da84d646a379c.js';
import { viewDoctor } from './app/views/doctor-53163abff05205c4.js';
import { viewImages } from './app/views/images-edefff53d2244b32.js';
import { viewMetrics } from './app/views/metrics-671b0afd56d21794.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-e9981ed82979c21e.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-8829b7c0f1907065.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-54d1f68d30f0afdc.js';
import { viewOverview } from './app/views/overview-cb558a3a807188cd.js';
import { viewResources } from './app/views/resources-7a82f81002a5ed40.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-3811123acc52b177.js';
import './app/views/sandbox-dialogs-981c469316268b9e.js';
import { persistLayout } from './app/views/sandbox-layout-774bf5ca778dfbe7.js';
import './app/views/sandbox-network-4cc5455d727ccdbc.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-49b920c76e60bb2e.js';
import { paintHome } from './app/views/sandbox-home-287c2b7213ee387d.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-0dd7ab4961fad385.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-f143aa3297ea2b2b.js';
import { viewSettings } from './app/views/settings-c7e031863970cfec.js';
import './app/views/shortcuts-f0237bec9856ab31.js';

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
// 647: below 760 px a top bar replaces the rail — the menu (the sidebar as a drawer), the brand, a key alert, Quick add.
$('nav-menu').replaceChildren(icon('list'));
$('nav-menu').addEventListener('click', (ev) => { ev.stopPropagation(); navRail(!document.body.classList.contains('nav-open')); });
$('top-keys').replaceChildren(icon('key-round'));
$('top-quick-add').replaceChildren(icon('plus'));
$('top-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
// 647: the foot's status card — on hover or keyboard focus (CSS), and on a tap (no hover on a phone) until it loses focus.
$('foot-status').addEventListener('click', () => $('foot-card').classList.toggle('is-open'));
$('foot-status').addEventListener('blur', () => $('foot-card').classList.remove('is-open'));
// A click elsewhere closes it too (Safari never focuses a clicked button, so its blur never comes).
document.addEventListener('click', (ev) => { if (!ev.target.closest('#foot-status')) $('foot-card').classList.remove('is-open'); });
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
