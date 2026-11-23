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

import { chatEnter, chatLeave, chatNavCheck, chatRefresh } from './app/views/chat-b2d296f1bc3e627e.js';
import { PERMISSIONS_TAB, wsEnter, wsRefresh } from './app/views/workspace-6f9597d6bd2551d7.js';
import { viewWsAgent } from './app/views/ws-agents-73e6a43117c09ff1.js';
import { viewIsolationGuide } from './app/views/isolation-guide-16dd1551dd7ab9f3.js';
import { viewAddWorker } from './app/views/add-worker-cff3c3557cf991db.js';
import { interleave } from './app/core/ws-log-725b407c6811cd6c.js';
import { configure as configureChat, dashboardFileUrl } from './app/core/chat-api-ec968582d97ebdcb.js';
import { paintStartProgress } from './app/components/start-progress-9f3ef8012f418d15.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-f853cc7eb6672c45.js';
import { icon, setButton } from './app/dom/icons-aaec6b77d82a3494.js';
import './app/core/agents-b5713528d20be964.js';
import { api, apiFetch } from './app/core/api-47cfabfed13b475c.js';
import { connect } from './app/core/events-c0d052f67dbd0444.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-da7286b35f0a0fcb.js';
import { act } from './app/core/operations-334116643b267884.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-fdf414960b585569.js';
import { refresh, route } from './app/core/router-0b3910a30f3a336d.js';
import './app/core/sandboxes-746d41a01f5b633d.js';
import { pictureStats } from './app/core/space-pictures-663f59439e29c10d.js';
import { bootstrap, signedOut } from './app/core/session-d2120671b8ea9d60.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-b574facd5b73891b.js';
import { state } from './app/core/state-1036883eb74b9520.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-0745432f65992dcb.js';
import { WIZ } from './app/core/wizards-58ec31b532e6415d.js';
import './app/components/access-step-017bf0f3b469df2e.js';
import './app/components/accounts-c2133a78ba36a60f.js';
import './app/components/blocks-6b2d43608253a84f.js';
import { btn } from './app/components/button-030d384b64f8d75d.js';
import { callout } from './app/components/callout-a906e34ef11cba9d.js';
import './app/components/create-dialog-68a9d9331806a290.js';
import './app/components/dialog-24dd4e7505bf6489.js';
import { hostChanged, paintUpdates, renderHostFoot } from './app/components/host-103450404132d448.js';
import './app/components/image-picker-9c3460724ba57437.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-8651c415d34b7d4a.js';
import { macPicker, refreshMacPicker } from './app/components/mac-picker-e8018b4ec4c55186.js';
import './app/components/menus-2bfb74f31fa5969c.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-33051ba8b13ef29a.js';
import { applyRail, navMenuClick, navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-70a6bdfb5f057069.js';
import { paintNotes } from './app/components/notes-69d2f6b952196f79.js';
import { watchPageTitle } from './app/components/page-title-b07e56c4587e1e16.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-0178e08a24128523.js';
import './app/components/permissions-1f18285830987757.js';
import { paintTransition } from './app/components/pills-028df737f71b1d32.js';
import './app/components/prep-card-fc4fb00f154d9c44.js';
import { quickAdd } from './app/components/quick-add-ae89bc9e53bb1566.js';
import './app/components/rules-step-cac5aa73d2ddfdaa.js';
import './app/components/stepper-9f1fb5c64eac92d6.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-bbb072f6f6d54da5.js';
import './app/components/workspace-chooser-3dc61f03b81c29dc.js';
import { viewAccounts } from './app/views/accounts-92c50f2d72c77d2f.js';
import { renderActivity, viewActivity } from './app/views/activity-db07126e02c5810a.js';
import { viewDebug } from './app/views/debug-c79fb3fead88aecb.js';
import { viewNotifications } from './app/views/notifications-3c75fad9b47b73ee.js';
import { viewDevices } from './app/views/devices-a4a3c5554e5b2cd0.js';
import { viewDoctor } from './app/views/doctor-1fa5b266b9306a9f.js';
import { viewImages } from './app/views/images-22f7d5e3286f6b6f.js';
import { viewMetrics } from './app/views/metrics-b7358fb5ca3d13be.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-497a8cdd5cdf2eae.js';
import { forgetNewWorkspace, newWorkspaceDirty, newWorkspaceRefusal, viewNewWorkspace } from './app/views/new-workspace-3f94cf8b7517d730.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-9f51f7ff064e290b.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-c2462e296a6e96bc.js';
import { viewBots } from './app/views/bots-b54a9446cce4d938.js';
import { viewBot } from './app/views/bot-291bd2529a03a9fc.js';
import { viewHome } from './app/views/home-031ba34e0abb6ab1.js';
import { viewWorkspaces } from './app/views/workspaces-b0efb18c07dc480c.js';
import { viewLoose } from './app/views/loose-9cf88a41726a0826.js';
import { viewMacs } from './app/views/macs-e408ab3822a15bea.js';
import { viewOverview } from './app/views/overview-19dc5e8853fd480f.js';
import { viewResources } from './app/views/resources-2dd5543ec6ce19de.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-00b07ed1dbf37b0d.js';
import './app/views/sandbox-dialogs-114d79a1ec81697f.js';
import { persistLayout } from './app/views/sandbox-layout-794af3f572862085.js';
import './app/views/sandbox-network-0abca19644660a77.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-0fbae89e281826d6.js';
import { paintHome } from './app/views/sandbox-home-b25ac58785373ddc.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-21181b4eeda2e583.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-ad80c39d51c615c4.js';
import { macEnter, macLeave, macRefresh } from './app/views/mac-6d924f67f5de8b79.js';
import { viewBrowse, viewRecipes, viewSettings } from './app/views/settings-ef6f3a048fcd6786.js';
import { viewThisMac } from './app/views/this-mac-25057881e4f19a64.js';
import './app/views/shortcuts-127c9d2326d9a51f.js';
import { spaceEnter, spaceLeave, spaceNow } from './app/views/space-page-798bd1ba74f653d6.js';

// 599c: Quick add in the sidebar, beside This Mac.
$('nav-quick-add').replaceChildren(icon('plus'));
// The sidebar's Workspaces +: the New workspace wizard (this Mac's own browser only — another computer sees why).
$('nav-ws-new').replaceChildren(icon('plus'));
$('nav-ws-new').addEventListener('click', (ev) => {
  ev.preventDefault();
  const why = newWorkspaceRefusal();
  if (why) { toast(why, true); return; }
  location.hash = '#/new-workspace';
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
