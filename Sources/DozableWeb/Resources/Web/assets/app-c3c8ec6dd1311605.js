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

import { chatEnter, chatLeave, chatNavCheck, chatRefresh } from './app/views/chat-9ab605bb0f3ba535.js';
import { PERMISSIONS_TAB, wsEnter, wsRefresh } from './app/views/workspace-194ea0408a8bd37a.js';
import { viewWsAgent } from './app/views/ws-agents-dc36bfb4c3bb18dd.js';
import { interleave } from './app/core/ws-log-725b407c6811cd6c.js';
import { configure as configureChat, dashboardFileUrl } from './app/core/chat-api-ec968582d97ebdcb.js';
import { paintStartProgress } from './app/components/start-progress-2af0a8a9a56225c0.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-f853cc7eb6672c45.js';
import { icon, setButton } from './app/dom/icons-9b284ea0ffb2ad04.js';
import './app/core/agents-b5713528d20be964.js';
import { api, apiFetch } from './app/core/api-b1749184317a6239.js';
import { connect } from './app/core/events-196ff338fbd70671.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-52b65124a4efdf67.js';
import { act } from './app/core/operations-4219a26d2d8bc16f.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-9e3a59a36528725a.js';
import { refresh, route } from './app/core/router-142dbd70a847b7e5.js';
import './app/core/sandboxes-312e59097bf1f9a9.js';
import { bootstrap, signedOut } from './app/core/session-9961c3a88880fade.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-bde0f0609314b816.js';
import { state } from './app/core/state-d6b90484a98480b9.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-0745432f65992dcb.js';
import { WIZ } from './app/core/wizards-58ec31b532e6415d.js';
import './app/components/access-step-7d3e644c0d58268d.js';
import './app/components/accounts-1af507a6e34a951a.js';
import './app/components/blocks-6b2d43608253a84f.js';
import { btn } from './app/components/button-8109d54546d946d3.js';
import { callout } from './app/components/callout-f30e3ad8767a987a.js';
import './app/components/create-dialog-aeaa6e47e3b1d1b1.js';
import './app/components/dialog-88c11408712b1209.js';
import { hostChanged, paintUpdates, renderHostFoot } from './app/components/host-c6af64e2645db47d.js';
import './app/components/image-picker-466847c3c5436bc2.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-15ef0fe1a904b8be.js';
import { macPicker, refreshMacPicker } from './app/components/mac-picker-645354d07c18284e.js';
import './app/components/menus-b8f822d6b7817c72.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-8bc49348e27c773f.js';
import { applyRail, navMenuClick, navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-2ee956b561ddc5f1.js';
import { paintNotes } from './app/components/notes-bc0a253ed3fc0897.js';
import { watchPageTitle } from './app/components/page-title-b07e56c4587e1e16.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-9d5654315aaca1f6.js';
import './app/components/permissions-b1361a85a03fc470.js';
import { paintTransition } from './app/components/pills-6df861fd992e6dfc.js';
import './app/components/prep-card-26e1ed186082b2d7.js';
import { quickAdd } from './app/components/quick-add-503323f6bfc7afb4.js';
import './app/components/rules-step-555a16e56d4c1bd9.js';
import './app/components/stepper-7c3bf700447c8338.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-994e3c00169c34ba.js';
import './app/components/workspace-chooser-3298bbb9c828e6be.js';
import { viewAccounts } from './app/views/accounts-a780039325ed2261.js';
import { renderActivity, viewActivity } from './app/views/activity-a3fed0033640589d.js';
import { viewDebug } from './app/views/debug-58a2dd1033608919.js';
import { viewNotifications } from './app/views/notifications-3ffe81c8d85734ed.js';
import { viewDevices } from './app/views/devices-d22e38b63b404413.js';
import { viewDoctor } from './app/views/doctor-47be072dadd8170c.js';
import { viewImages } from './app/views/images-d660ffabb38b4981.js';
import { viewMetrics } from './app/views/metrics-26f9c54d75186c36.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-20b89356d73f4e59.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-5a1dc4095bdc5dd9.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-f8bae9aaa175d950.js';
import { viewBots } from './app/views/bots-67e5d02a29d8454f.js';
import { viewBot } from './app/views/bot-319b7c96f4c6323d.js';
import { viewHome } from './app/views/home-12c8df521159b702.js';
import { viewLoose } from './app/views/loose-488c438f7ce78e5e.js';
import { viewMacs } from './app/views/macs-3887faf5416a4c4d.js';
import { viewOverview } from './app/views/overview-69991de53ee10049.js';
import { viewResources } from './app/views/resources-d698f4aa11b468ef.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-8d60045b4f572556.js';
import './app/views/sandbox-dialogs-920f556e8641f117.js';
import { persistLayout } from './app/views/sandbox-layout-75a62e071ebd7847.js';
import './app/views/sandbox-network-97e25b1103eba684.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-296aba1bf06cba2c.js';
import { paintHome } from './app/views/sandbox-home-173c14f5a3f82ca7.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-3a37c3be12532fd6.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-22c2bec761834810.js';
import { macEnter, macLeave, macRefresh } from './app/views/mac-80d2af5b9a833481.js';
import { viewBrowse, viewRecipes, viewSettings } from './app/views/settings-8fee8fbb7f999c29.js';
import { viewThisMac } from './app/views/this-mac-4d8c299efd2a8220.js';
import './app/views/shortcuts-1e3fcb1cea575c00.js';

// 599c: Quick add in the sidebar, beside This Mac.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
// 617 (owner): TRY is a section of its own — its + opens the Quick try. 669 (owner): the section is RECIPES — the
// recipes installed on this Mac, Browse (the whole catalogue), then Quick try; its + still opens the Quick try. Since the
// dashboard's new shell it is This Mac › Templates.
$('nav-try-add').replaceChildren(icon('plus'));
$('nav-try-add').addEventListener('click', (ev) => { ev.preventDefault(); location.hash = '#/try'; });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozable.', 'signed-out');
});

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { home: 'house', needs: 'triangle-alert', bots: 'bot', thismac: 'laptop', loose: 'briefcase', chat: 'message-square', devices: 'user-round', overview: 'box', sessions: 'layout-grid', mac: 'square-terminal', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', onboarding: 'rocket', doctor: 'stethoscope', settings: 'settings', recipes: 'monitor', browse: 'search', try: 'play', debug: 'bug', notifications: 'bell' };
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
// The machine picker: "Dozable · <this Mac> ▾" in the sidebar's head and the phone's top bar opens Your Macs.
macPicker($('mac-picker'));
macPicker($('top-mac-picker'), { top: true });
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
    if (!/^#\/[a-z]/.test(location.hash)) history.replaceState(null, '', location.pathname + '#/home');
    await loadSettings();
    // 594 (D8): a store never onboarded opens on the setup wizard (once per page load).
    try {
      const o = await api('overview');
      state.overview = o;
      renderNavSandboxes();
      if (o.onboarded === false && location.hash === '#/home') history.replaceState(null, '', location.pathname + '#/onboarding');
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
// Chat (views/chat*.js): the dashboard's particulars, handed to core/chat-api once — the one request function (its CSRF
// header, a 401's sign-out), who is looking, and the only addresses an attachment may have: this chat server's files, at
// the dashboard's own /api/v1/chat/files/ID/NAME.
configureChat({
  title: 'Chat',
  request: (path, o = {}) => apiFetch('chat' + path, { method: o.method, json: o.json, bytes: o.bytes, type: o.type, actionId: o.actionId }),
  viewer: () => state.chat.human,
  canWrite: () => !state.chat.status || state.chat.status.access !== 'read',
  fileUrl: dashboardFileUrl,
});
setInterval(chatNavCheck, 60000);
provide({
  acknowledgeOps, backToTrySetup, banner, btn, callout, chatEnter, chatLeave, chatNavCheck, chatRefresh, closeWizardModal, connect, dropBanner, failureFor, gridEnter, gridLeave,
  gridRefresh, hostChanged, lifecycle, macEnter, macLeave, macRefresh, modalInert, opFailed, openWizardModal, pageFailure,
  paintCover, paintHome, paintNav, paintNotes, paintResTotal, paintRowOps, paintSplitButton, paintTabs, paintTransition, paintUpdates,
  persistLayout, reattachTerminals, refresh, refreshMacPicker, refreshNav, refreshSandbox, renderActivity, renderHostFoot, renderOps,
  renderTerminals, renderTryPrep, renderWizard, showSandbox, signedOut, startApp, syncConsoleTab, syncBuildLogTab, paintStartProgress, toast, viewAccounts, viewActivity, viewDebug, viewDevices, viewDoctor, viewNotifications,
  viewBots, viewBot, viewHome, viewImages, viewLoose, viewMacs, viewMetrics, viewNew, viewOnboarding, viewOperations, viewOverview, viewBrowse, viewRecipes, viewResources, viewSettings,
  viewThisMac, viewTry, viewWsAgent, wizardStopPolling, wsEnter, wsRefresh,
});
// The browser probes' names. The one script's top-level names were globals, and the workspace's browser probes
// (probes/*, over CDP Runtime.evaluate) read and call some of them; module names are not globals, so these stay
// reachable by name as before (only this page's own scripts run here: script-src 'self'). One a lower layer calls
// up is reached through its hook — a probe that wraps it wraps what the page calls. The page itself never uses them.
expose({
  act, api, closeTerminal, focusTerm, gridRefresh, gridSchedule, newSandboxWizard, newShellTerminal, openTerminal,
  pageTerminals, paintTabs, refresh, renderTerminals, resetSetting, saveSetting, sendInput, showUiOverlay, splitWith,
  state, sview, terminals, termUI, uiLost, uiRetryTick, WIZ, wizGo,
  // A workspace's page: the tab's name and the pure merge of messages and log lines (the walk checks it against fixtures).
  PERMISSIONS_TAB, interleave,
});

(async () => { if (await bootstrap()) startApp(); })();
