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

import { chatEnter, chatLeave, chatNavCheck, chatRefresh } from './app/views/chat-793cff4ab1942f78.js';
import { PERMISSIONS_TAB, wsEnter, wsRefresh } from './app/views/workspace-8617133349f9df9c.js';
import { viewWsAgent } from './app/views/ws-agents-ab27453e52af1c00.js';
import { viewIsolationGuide } from './app/views/isolation-guide-d07d087aff899dd8.js';
import { viewAddWorker } from './app/views/add-worker-7ed0979ee598f3bf.js';
import { interleave } from './app/core/ws-log-725b407c6811cd6c.js';
import { configure as configureChat, dashboardFileUrl } from './app/core/chat-api-ec968582d97ebdcb.js';
import { paintStartProgress } from './app/components/start-progress-01dafd2054616263.js';
import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-f853cc7eb6672c45.js';
import { icon, setButton } from './app/dom/icons-9b284ea0ffb2ad04.js';
import './app/core/agents-b5713528d20be964.js';
import { api, apiFetch } from './app/core/api-4b89ba3d74057e14.js';
import { connect } from './app/core/events-ad48c64f764d3d0c.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-a38bfd31f8558f51.js';
import { act } from './app/core/operations-acff205947254e5d.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-d4df5cec321fe456.js';
import { refresh, route } from './app/core/router-b611dac933d06f5d.js';
import './app/core/sandboxes-518299e79a5dbb63.js';
import { pictureStats } from './app/core/space-pictures-9251f4fb56789e9d.js';
import { bootstrap, signedOut } from './app/core/session-32b26efd4b3dc47f.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-bf31bd210264060d.js';
import { state } from './app/core/state-67e05db59fafd5df.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-e2028f16ee8fa887.js';
import './app/core/util-0745432f65992dcb.js';
import { WIZ } from './app/core/wizards-58ec31b532e6415d.js';
import './app/components/access-step-84d69abb84872077.js';
import './app/components/accounts-5dfadee4bff7c700.js';
import './app/components/blocks-6b2d43608253a84f.js';
import { btn } from './app/components/button-8109d54546d946d3.js';
import { callout } from './app/components/callout-f30e3ad8767a987a.js';
import './app/components/create-dialog-ade9f34b37a5e597.js';
import './app/components/dialog-acff76b5caf114a8.js';
import { hostChanged, paintUpdates, renderHostFoot } from './app/components/host-ecbc23c25a866876.js';
import './app/components/image-picker-f46b8336b103c333.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-c3404e9ead1a56f5.js';
import { macPicker, refreshMacPicker } from './app/components/mac-picker-0ede4b88d01bc361.js';
import './app/components/menus-b8f822d6b7817c72.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-30b15ef55f7473a0.js';
import { applyRail, navMenuClick, navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-06c6534495dcc4b5.js';
import { paintNotes } from './app/components/notes-34d08e1aa17039c6.js';
import { watchPageTitle } from './app/components/page-title-b07e56c4587e1e16.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-3f6ec9d1305281db.js';
import './app/components/permissions-eb36c9e4a6540d97.js';
import { paintTransition } from './app/components/pills-7a53d8caf36e96e6.js';
import './app/components/prep-card-c9b0b70a0d60b6d1.js';
import { quickAdd } from './app/components/quick-add-7b85fa22419fb04b.js';
import './app/components/rules-step-555a16e56d4c1bd9.js';
import './app/components/stepper-2c0827f6cc22be2c.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-e91cb95cd94e208b.js';
import './app/components/workspace-chooser-cf1f733a95bcc634.js';
import { viewAccounts } from './app/views/accounts-c1b405ed6d0fd41a.js';
import { renderActivity, viewActivity } from './app/views/activity-2af8bd5c29d78536.js';
import { viewDebug } from './app/views/debug-f7cd717d0a8df047.js';
import { viewNotifications } from './app/views/notifications-20a523c8dc497805.js';
import { viewDevices } from './app/views/devices-a7c49c95842db98e.js';
import { viewDoctor } from './app/views/doctor-ed1c9c8726a5ffe5.js';
import { viewImages } from './app/views/images-cb619c1f355c71c8.js';
import { viewMetrics } from './app/views/metrics-77526886ec8136b2.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-f0a5034a1f1f7e78.js';
import { forgetNewWorkspace, newWorkspaceDirty, newWorkspaceRefusal, viewNewWorkspace } from './app/views/new-workspace-5141d3bae01f28de.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-cf38b51c36ab8cb0.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-c387889f4f8bcd59.js';
import { viewBots } from './app/views/bots-fed713a033401b2f.js';
import { viewBot } from './app/views/bot-9bb78f76f2d16675.js';
import { viewHome } from './app/views/home-b611423506666c33.js';
import { viewWorkspaces } from './app/views/workspaces-95439d161ee6fbc8.js';
import { viewLoose } from './app/views/loose-3feb26ee8222225c.js';
import { viewMacs } from './app/views/macs-b265526916ff2a2b.js';
import { viewOverview } from './app/views/overview-bb73b507d100f039.js';
import { viewResources } from './app/views/resources-ffcfa1942bc649db.js';
import { backToTrySetup, renderTryPrep, viewTry } from './app/views/try-b0de8d669440c6bb.js';
import './app/views/sandbox-dialogs-48c53b1e6dedeb8e.js';
import { persistLayout } from './app/views/sandbox-layout-de305644b86f18e8.js';
import './app/views/sandbox-network-64c671f7686a6f65.js';
import { newShellTerminal, paintSplitButton, paintTabs, renderTerminals, splitWith, syncBuildLogTab, syncConsoleTab } from './app/views/sandbox-terminals-c4645657114dc0cb.js';
import { paintHome } from './app/views/sandbox-home-9a68dc3d787c161d.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-c20b36fdee3b6356.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-0cbbb1954f3907f8.js';
import { macEnter, macLeave, macRefresh } from './app/views/mac-9c7a3393a5278e4e.js';
import { viewBrowse, viewRecipes, viewSettings } from './app/views/settings-830fed99689082b6.js';
import { viewThisMac } from './app/views/this-mac-f13cd0cae34b47bd.js';
import './app/views/shortcuts-12ae8b21b0949fb7.js';
import { spaceEnter, spaceLeave, spaceNow } from './app/views/space-page-8f3fde124c9ebd34.js';

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
