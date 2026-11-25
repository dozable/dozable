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

import { chatEnter, chatLeave, chatNavCheck, chatRefresh } from './app/views/chat-9afb11a937fb03b6.js';
import { PERMISSIONS_TAB, wsEnter, wsRefresh } from './app/views/workspace-61f075c3f9ee5867.js';
import { viewWsAgent } from './app/views/ws-agents-4b9a3d6529fd0678.js';
import { viewIsolationGuide } from './app/views/isolation-guide-eb702745d8c20c03.js';
import { viewAddWorker } from './app/views/add-worker-018c4d02e63f0e90.js';
import { interleave } from './app/core/ws-log-725b407c6811cd6c.js';
import { configure as configureChat, dashboardFileUrl } from './app/core/chat-api-ec968582d97ebdcb.js';
import { paintStartProgress } from './app/components/start-progress-fa89383c29b23cd6.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-f853cc7eb6672c45.js';
import { icon, setButton } from './app/dom/icons-aaec6b77d82a3494.js';
import './app/core/agents-b5713528d20be964.js';
import { api, apiFetch } from './app/core/api-496fd9f39af2a514.js';
import { connect } from './app/core/events-5758d9d4888935fa.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-87e7e939edcc17db.js';
import { act } from './app/core/operations-03041bf9d59d2862.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-ec29af3a276597fc.js';
import { refresh, route } from './app/core/router-1159bbe5d01b97aa.js';
import './app/core/sandboxes-00ef9eae41f10eb7.js';
import { pictureStats } from './app/core/space-pictures-8029e9901879ab72.js';
import { bootstrap, signedOut } from './app/core/session-ac3b294ded6521bf.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-1dd31ee086a35147.js';
import { state } from './app/core/state-f551ebce9066b2c8.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-0745432f65992dcb.js';
import { WIZ } from './app/core/wizards-58ec31b532e6415d.js';
import './app/components/access-step-3ea69438a621bf28.js';
import './app/components/accounts-c8ea18016204bd57.js';
import './app/components/blocks-6b2d43608253a84f.js';
import { btn } from './app/components/button-030d384b64f8d75d.js';
import { callout } from './app/components/callout-a906e34ef11cba9d.js';
import './app/components/create-dialog-7d16f610037b34b8.js';
import './app/components/dialog-705988b4803973e1.js';
import { hostChanged, paintUpdates, renderHostFoot } from './app/components/host-1a8e40cae444468d.js';
import './app/components/image-picker-21d953057e8a85f8.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-1c168fad8c77af9c.js';
import { macPicker, refreshMacPicker } from './app/components/mac-picker-66c81707ab74a517.js';
import './app/components/menus-2bfb74f31fa5969c.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-038081d1fc380929.js';
import { applyRail, navMenuClick, navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-e39b101c39ba19ea.js';
import { paintNotes } from './app/components/notes-b982b305c6f4f5bc.js';
import { watchPageTitle } from './app/components/page-title-b07e56c4587e1e16.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-0ff282536e70c5c2.js';
import './app/components/permissions-3302800a2250ba01.js';
import { paintTransition } from './app/components/pills-a227261f986b0161.js';
import './app/components/prep-card-aaffc798d69d365f.js';
import { quickAdd } from './app/components/quick-add-8a3acc69f40b7e55.js';
import './app/components/rules-step-cac5aa73d2ddfdaa.js';
import './app/components/stepper-9f1fb5c64eac92d6.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-b21ad591c2b7df2d.js';
import './app/components/workspace-chooser-e7d3cfb487a920db.js';
import { viewAccounts } from './app/views/accounts-1bcd7484bdeebac3.js';
import { renderActivity, viewActivity } from './app/views/activity-45a6d5bf6e8cbdbe.js';
import { viewDebug } from './app/views/debug-69e73c95d1e2a92e.js';
import { viewNotifications } from './app/views/notifications-bb745a5ea5323bba.js';
import { viewDevices } from './app/views/devices-e36a4058aed40bb0.js';
import { viewDoctor } from './app/views/doctor-971f7d292f9e8525.js';
import { viewImages } from './app/views/images-648a5e2499b8ba84.js';
import { viewMetrics } from './app/views/metrics-677126b1796b1539.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-dec30449dc53d83d.js';
import { forgetNewWorkspace, newWorkspaceDirty, newWorkspaceRefusal, openNewWorkspace, viewNewWorkspace } from './app/views/new-workspace-1842ebb075efaa99.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-35e0df5c1a53b092.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-cc6d4019f45c8ea7.js';
import { viewBots } from './app/views/bots-56bdf71c6d037162.js';
import { viewBot } from './app/views/bot-eaee40619871956a.js';
import { viewHome } from './app/views/home-ab856fd0b8fc43e2.js';
import { viewWorkspaces } from './app/views/workspaces-40875ac8094205dc.js';
import { viewLoose } from './app/views/loose-943965a09bcbdd00.js';
import { viewMacs } from './app/views/macs-866027a275698262.js';
import { viewOverview } from './app/views/overview-1eaacaf8c49573dd.js';
import { viewResources } from './app/views/resources-c08cdbb07d39071a.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-32375414763c0f62.js';
import './app/views/sandbox-dialogs-3309e740d8338679.js';
import { persistLayout } from './app/views/sandbox-layout-603ec521ef583700.js';
import './app/views/sandbox-network-8a334fcb58d4066b.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-4d80651cf21300ee.js';
import { paintHome } from './app/views/sandbox-home-12be03490ececf1c.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-3decc6d6090d73c4.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-e9fca0f37b97f34e.js';
import { macEnter, macLeave, macRefresh } from './app/views/mac-2a00267d70c0e4f9.js';
import { viewBrowse, viewRecipes, viewSettings } from './app/views/settings-3784036c279846be.js';
import { viewThisMac } from './app/views/this-mac-be479edf62d84c5d.js';
import './app/views/shortcuts-b1dfd82b58f88b9d.js';
import { spaceEnter, spaceLeave, spaceNow } from './app/views/space-page-d49e77e4ca91b5e3.js';

// 599c: Quick add in the sidebar, beside This Mac.
$('nav-quick-add').replaceChildren(icon('plus'));
// The sidebar's Workspaces +: the New workspace wizard (this Mac's own browser only — another computer sees why).
$('nav-ws-new').replaceChildren(icon('plus'));
$('nav-ws-new').addEventListener('click', (ev) => {
  ev.preventDefault();
  const why = newWorkspaceRefusal();
  if (why) { toast(why, true); return; }
  openNewWorkspace();
});
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
    if (newWorkspaceRefusal()) { $('nav-ws-new').disabled = true; $('nav-ws-new').title = newWorkspaceRefusal(); }
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
  acknowledgeOps, backToTrySetup, banner, btn, callout, chatEnter, chatLeave, chatNavCheck, chatRefresh, closeWizardModal, connect, dropBanner, failureFor, forgetNewWorkspace, gridEnter, gridLeave,
  gridRefresh, hostChanged, lifecycle, macEnter, macLeave, macRefresh, modalInert, opFailed, openWizardModal, pageFailure,
  paintCover, paintHome, paintNav, paintNotes, paintResTotal, paintRowOps, paintSplitButton, paintTabs, paintTransition, paintUpdates,
  persistLayout, reattachTerminals, refresh, refreshMacPicker, refreshNav, refreshSandbox, renderActivity, renderHostFoot, renderOps,
  renderTerminals, renderTryPrep, renderWizard, showSandbox, signedOut, spaceEnter, spaceLeave, startApp, syncConsoleTab, syncBuildLogTab, paintStartProgress, toast, viewAccounts, viewActivity, viewDebug, viewDevices, viewDoctor, viewNotifications,
  viewBots, viewBot, viewHome, viewImages, viewLoose, viewMacs, viewMetrics, viewNew, viewNewWorkspace, newWorkspaceDirty, viewOnboarding, viewOperations, viewOverview, viewBrowse, viewRecipes, viewResources, viewSettings,
  viewThisMac, viewTry, viewWsAgent, viewIsolationGuide, viewAddWorker, viewWorkspaces, wizardStopPolling, wsEnter, wsRefresh,
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
  // The workspace drawn: what was read and drawn (the walk counts the reads and the cache's hits).
  pictureStats,
  // The space editor's page: what it holds (the walk reads the text and the features).
  spaceNow,
});

(async () => { if (await bootstrap()) startApp(); })();
