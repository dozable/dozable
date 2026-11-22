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

import { chatEnter, chatLeave, chatNavCheck, chatRefresh } from './app/views/chat-b70ba1c04bfa9c3b.js';
import { PERMISSIONS_TAB, wsEnter, wsRefresh } from './app/views/workspace-7e4d4a708fa8b5f7.js';
import { viewWsAgent } from './app/views/ws-agents-5a5bcb0749800bdc.js';
import { viewIsolationGuide } from './app/views/isolation-guide-f2e9ce1e41d5b2db.js';
import { viewAddWorker } from './app/views/add-worker-ad5de6c2179fcef1.js';
import { interleave } from './app/core/ws-log-725b407c6811cd6c.js';
import { configure as configureChat, dashboardFileUrl } from './app/core/chat-api-ec968582d97ebdcb.js';
import { paintStartProgress } from './app/components/start-progress-599da089b23d6ca9.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-f853cc7eb6672c45.js';
import { icon, setButton } from './app/dom/icons-9b284ea0ffb2ad04.js';
import './app/core/agents-b5713528d20be964.js';
import { api, apiFetch } from './app/core/api-47cfabfed13b475c.js';
import { connect } from './app/core/events-834d1e2509e732a6.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-da7286b35f0a0fcb.js';
import { act } from './app/core/operations-c9aa14c479d822d2.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-71565620659cb182.js';
import { refresh, route } from './app/core/router-9bb5e215e0ec1e32.js';
import './app/core/sandboxes-746d41a01f5b633d.js';
import { pictureStats } from './app/core/space-pictures-f97d261e64557c76.js';
import { bootstrap, signedOut } from './app/core/session-76fecfa2ea8ff65b.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-b574facd5b73891b.js';
import { state } from './app/core/state-1036883eb74b9520.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-0745432f65992dcb.js';
import { WIZ } from './app/core/wizards-58ec31b532e6415d.js';
import './app/components/access-step-757a81989a5788e6.js';
import './app/components/accounts-1b2f6d2d301364b6.js';
import './app/components/blocks-6b2d43608253a84f.js';
import { btn } from './app/components/button-8109d54546d946d3.js';
import { callout } from './app/components/callout-f30e3ad8767a987a.js';
import './app/components/create-dialog-882a4232e3b0b9ec.js';
import './app/components/dialog-408f2bb247f85767.js';
import { hostChanged, paintUpdates, renderHostFoot } from './app/components/host-af6776f70634612e.js';
import './app/components/image-picker-81764744799e7997.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-be5043dafb63fc4e.js';
import { macPicker, refreshMacPicker } from './app/components/mac-picker-458ab013f66f10f1.js';
import './app/components/menus-b8f822d6b7817c72.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-e49ba23264d245a3.js';
import { applyRail, navMenuClick, navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-2fbf2a52eee20f71.js';
import { paintNotes } from './app/components/notes-7c4f97201ba84f32.js';
import { watchPageTitle } from './app/components/page-title-b07e56c4587e1e16.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-b29072c7b381a4ec.js';
import './app/components/permissions-a6548420f04a6385.js';
import { paintTransition } from './app/components/pills-0f977e7ec72bcf82.js';
import './app/components/prep-card-8bebac138c20793e.js';
import { quickAdd } from './app/components/quick-add-3adbe0009e078bff.js';
import './app/components/rules-step-555a16e56d4c1bd9.js';
import './app/components/stepper-2c0827f6cc22be2c.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-aa332686405e890a.js';
import './app/components/workspace-chooser-adf1fc5023eac6d0.js';
import { viewAccounts } from './app/views/accounts-8035fb1ef6a6b2b3.js';
import { renderActivity, viewActivity } from './app/views/activity-db07126e02c5810a.js';
import { viewDebug } from './app/views/debug-30177cf408723427.js';
import { viewNotifications } from './app/views/notifications-3b1d9efc5da78307.js';
import { viewDevices } from './app/views/devices-fec759938e7243fa.js';
import { viewDoctor } from './app/views/doctor-1884edf53b15987f.js';
import { viewImages } from './app/views/images-65d9b5fa38848178.js';
import { viewMetrics } from './app/views/metrics-b530750a5bd5c15b.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-fbf251b6720af490.js';
import { forgetNewWorkspace, newWorkspaceDirty, newWorkspaceRefusal, viewNewWorkspace } from './app/views/new-workspace-be94035128e3d0e3.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-d9504948d4884a71.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-50bcf0e91a6f2867.js';
import { viewBots } from './app/views/bots-9104d66d57bc4aff.js';
import { viewBot } from './app/views/bot-2000abf2505332ab.js';
import { viewHome } from './app/views/home-6d5aceb4375113ab.js';
import { viewWorkspaces } from './app/views/workspaces-4423f1a5bce4809e.js';
import { viewLoose } from './app/views/loose-d347bc64b6f5992e.js';
import { viewMacs } from './app/views/macs-63d10ae188591095.js';
import { viewOverview } from './app/views/overview-2d517af3b3f27df5.js';
import { viewResources } from './app/views/resources-69af67aaaffdec01.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-4d6dc8da9d3299aa.js';
import './app/views/sandbox-dialogs-1e0acfa9cebba5a1.js';
import { persistLayout } from './app/views/sandbox-layout-bcb3d5479dfe7a13.js';
import './app/views/sandbox-network-d329f2fbe8b85fa0.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-fd6a34c956275671.js';
import { paintHome } from './app/views/sandbox-home-396dc972bbdd3966.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-f61370bbb2953f3a.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-a349aad11dffa0d2.js';
import { macEnter, macLeave, macRefresh } from './app/views/mac-21bf8a805da42bc4.js';
import { viewBrowse, viewRecipes, viewSettings } from './app/views/settings-6094ac35bc914e7d.js';
import { viewThisMac } from './app/views/this-mac-cff0f6631958b300.js';
import './app/views/shortcuts-3f250bc921b7e631.js';
import { spaceEnter, spaceLeave, spaceNow } from './app/views/space-page-a94ed96cb4b1ae87.js';

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
