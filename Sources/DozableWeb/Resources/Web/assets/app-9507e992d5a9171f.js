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

import { paintStartProgress } from './app/components/start-progress-ba7b50460be30c3f.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-f853cc7eb6672c45.js';
import { icon, setButton } from './app/dom/icons-9b284ea0ffb2ad04.js';
import './app/core/agents-b5713528d20be964.js';
import { api } from './app/core/api-38ff3d6b44282c1f.js';
import { connect } from './app/core/events-27a23ba043a9dbfe.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-036f22e138c6fb5b.js';
import { act } from './app/core/operations-b9f6dfadadad7ca9.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-e489534c51bff882.js';
import { refresh, route } from './app/core/router-550aa1a2250c9b09.js';
import './app/core/sandboxes-ceb80fb565978598.js';
import { bootstrap, signedOut } from './app/core/session-b3765fc4fb0cab62.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-f1f173ac0c1e102e.js';
import { state } from './app/core/state-c85a0de5f7fc1060.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-b989b43058be9b08.js';
import './app/components/access-step-8e514962d93fdbeb.js';
import './app/components/accounts-1beeff9465046133.js';
import './app/components/blocks-6b2d43608253a84f.js';
import { btn } from './app/components/button-8109d54546d946d3.js';
import { callout } from './app/components/callout-f30e3ad8767a987a.js';
import './app/components/create-dialog-975125687cd5ae3a.js';
import './app/components/dialog-3d0b77f12fdc6c0f.js';
import { hostChanged, paintUpdates, renderHostFoot } from './app/components/host-4b9d7ad9c78e7ad8.js';
import './app/components/image-picker-12be33101ec5d68d.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-7c8667f26a967e4c.js';
import './app/components/menus-f405ee3ec6f0c314.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-2dbf4333db9bdcac.js';
import { applyRail, navMenuClick, navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-2a810b8c662947cc.js';
import { paintNotes } from './app/components/notes-0e92364a8b2a9a7e.js';
import { watchPageTitle } from './app/components/page-title-b07e56c4587e1e16.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-314200da4c855ab4.js';
import './app/components/permissions-5fac31a2cb9a716c.js';
import { paintTransition } from './app/components/pills-37a5191612e3f2ad.js';
import './app/components/prep-card-ad535e2917b739b2.js';
import { quickAdd } from './app/components/quick-add-d6fca846db8f65f2.js';
import './app/components/rules-step-3f5b3888eba73fc0.js';
import './app/components/stepper-7c3bf700447c8338.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-dd34afa2e6e5d6cf.js';
import './app/components/workspace-chooser-5bc15c339c243309.js';
import { viewAccounts } from './app/views/accounts-12dff5be30ec4ed4.js';
import { renderActivity, viewActivity } from './app/views/activity-546a67117fdb60f1.js';
import { viewDebug } from './app/views/debug-a2d4ddd1aa835341.js';
import { viewNotifications } from './app/views/notifications-981b055e37d7458c.js';
import { viewDevices } from './app/views/devices-62455dbbefd50807.js';
import { viewDoctor } from './app/views/doctor-7702a64d89dad9a2.js';
import { viewImages } from './app/views/images-20d8493b7f3956b5.js';
import { viewMetrics } from './app/views/metrics-bf274062c23b4aa5.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-fe07e5fa6253f5d0.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-81c038e84fd8ca3f.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-8071185cbb17eaed.js';
import { viewOverview } from './app/views/overview-ed252b2c448e2e5b.js';
import { viewResources } from './app/views/resources-9192e93470a5abd5.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-8e6d40490ef82d42.js';
import './app/views/sandbox-dialogs-9460c7d2f0856d85.js';
import { persistLayout } from './app/views/sandbox-layout-50b9f3ac43e2b9ca.js';
import './app/views/sandbox-network-9a060c8e1a0f4235.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-da8e6613460f4a51.js';
import { paintHome } from './app/views/sandbox-home-e95e48da8320ed1b.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-cecadc83ce045e52.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-8b0392546c92f13a.js';
import { viewRecipes, viewSettings } from './app/views/settings-33e0f8ad58d5074c.js';
import './app/views/shortcuts-65d243744e58e024.js';

// 599c: Quick add in the sidebar, beside Sandboxes.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
// 617 (owner): TRY is a section of its own — its + opens the Quick try. 669 (owner): the section is RECIPES — the
// recipes on this Mac, then Quick try; its + still opens the Quick try.
$('nav-try-add').replaceChildren(icon('plus'));
$('nav-try-add').addEventListener('click', (ev) => { ev.preventDefault(); location.hash = '#/try'; });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozable.', 'signed-out');
});

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { devices: 'user-round', overview: 'box', sessions: 'layout-grid', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', onboarding: 'rocket', doctor: 'stethoscope', settings: 'settings', recipes: 'monitor', try: 'play', debug: 'bug', notifications: 'bell' };
for (const a of document.querySelectorAll('#nav a[data-view]')) {
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
// 647 (owner: "make the header in the navbar only"): the sidebar's head — the menu (wider than 980 px it collapses the
// sidebar to the rail; below, the whole sidebar over the page), the brand and the store. Below 760 px the header row
// (#topbar) has its own menu for the drawer, a key alert and Quick add. The notifications keep the top-right corner.
for (const id of ['nav-menu', 'top-menu']) {
  $(id).replaceChildren(icon('list'));
  $(id).addEventListener('click', (ev) => { ev.stopPropagation(); navMenuClick(); });
}
applyRail();                       // 647: the rail below 980 px, or wider when collapsed (this browser remembers)
watchPageTitle();                  // 647: a page's title bar and its tables' column heads stick as it scrolls
$('top-keys').replaceChildren(icon('key-round'));
$('top-quick-add').replaceChildren(icon('plus'));
$('top-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
paintNotes();
// 647: the foot's status card — on hover or keyboard focus (CSS), and pinned open by a click (a tap on a phone). It has
// buttons now (Restart / Start the host, Check for updates), so it stays while the pointer or the focus is in it.
function footCard(on) {
  $('foot-card').classList.toggle('is-open', on);
  $('foot-status').setAttribute('aria-expanded', on ? 'true' : 'false');
}
$('foot-status').addEventListener('click', () => footCard(!$('foot-card').classList.contains('is-open')));
// Tab away closes it; a click elsewhere too (by the event's path: Safari never focuses a clicked button, and a button in
// the card may have redrawn itself by the time the click reaches the document).
$('statusbar').addEventListener('focusout', (ev) => { if (ev.relatedTarget && !$('statusbar').contains(ev.relatedTarget)) footCard(false); });
document.addEventListener('click', (ev) => { if (!ev.composedPath().includes($('statusbar'))) footCard(false); });
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
  paintCover, paintHome, paintNav, paintNotes, paintResTotal, paintRowOps, paintSplitButton, paintTabs, paintTransition, paintUpdates,
  persistLayout, reattachTerminals, refresh, refreshNav, refreshSandbox, renderActivity, renderHostFoot, renderOps,
  renderTerminals, renderTryPrep, renderWizard, showSandbox, signedOut, startApp, syncConsoleTab, syncBuildLogTab, paintStartProgress, toast, viewAccounts, viewActivity, viewDebug, viewDevices, viewDoctor, viewNotifications,
  viewImages, viewMetrics, viewNew, viewOnboarding, viewOperations, viewOverview, viewRecipes, viewResources, viewSettings,
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
