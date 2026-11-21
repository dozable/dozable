// chat.js — the chat window's entry: a room of the Chat page in a window of its own (/chat#/ROOM). It loads only chat's
// modules (the compiler checks its closure reaches no other view) and provides the calls up the layers they make: the
// notices and the notes for real; its own refresh, sign-out and start; nothing for the dashboard's parts it has not got.
//
// Rules this file keeps (as app.js does): every value from the server is rendered with textContent; the CSRF token lives
// in memory only; sign-in stays the dashboard's (a capability link, an access code) — a signed-out window says so and
// points there, and looks again when it is shown.
import { configure as configureChat, dashboardFileUrl } from './app/core/chat-api-ec968582d97ebdcb.js';
import { provide } from './app/core/hooks-a4b871a481b363cd.js';
import { api, apiFetch } from './app/core/api-47cfabfed13b475c.js';
import { followOps } from './app/core/op-stream-22349cf3104b232a.js';
import { chatWindowName, chatWindowRoom } from './app/core/routes-c03e6aed84ec9eb3.js';
import { adoptSession } from './app/core/session-76fecfa2ea8ff65b.js';
import { loadSettings } from './app/core/settings-b574facd5b73891b.js';
import { state } from './app/core/state-1036883eb74b9520.js';
import { callout } from './app/components/callout-f30e3ad8767a987a.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, toast } from './app/components/notices-447454cd1875c9d1.js';
import { paintNotes } from './app/components/notes-7c4f97201ba84f32.js';
import { $, h } from './app/dom/h-f853cc7eb6672c45.js';
import { withIcon } from './app/dom/icons-9b284ea0ffb2ad04.js';
import { chatRefresh, chatWindow } from './app/views/chat-a43906526d7fc4ca.js';
import { onLiveEnd } from './app/views/chat-live-b67e638957c4083c.js';

state.view = 'chat';                 // the chat view is this window's only view (Turn chat on reads it again here)
let firstVersion = null, firstStyle = null;

/// The room the fragment names (`#/ROOM`), shown; the window named for it, so the pop-out of that room reuses it.
async function showRoom() {
  const room = chatWindowRoom(location.hash);
  if (!room) {
    $('chat').replaceChildren(callout('info', { title: 'No room named here',
      body: [h('span', null, 'This window shows one room, named after # in its address. '),
        h('a', { href: '/#/chat', target: '_blank', rel: 'noopener' }, 'Open Chat in the dashboard')] }));
    return;
  }
  window.name = chatWindowName(room);
  await chatWindow(room);
}

/// The window's start, once signed in.
async function startApp() {
  if (state.started) return;
  state.started = true;
  firstVersion = state.version;
  const css = document.querySelector('link[rel="stylesheet"][href^="/assets/app-"]');
  firstStyle = css && css.getAttribute('href');
  await loadSettings();                  // ui.theme, ui.density, ui.notifications
  paintNotes();
  await showRoom();
  const t = $('chat-text');
  if (t && !t.disabled) t.focus();
}

/// A doz ui of another build answers now: this window's code is the older one until it reloads.
function helloSeen(hello) {
  if (!hello) return;
  const other = (hello.version && firstVersion && hello.version !== firstVersion) || (hello.style && firstStyle && hello.style !== firstStyle);
  if (!other) return;
  banner('ui-updated', 'info', ['doz ui was updated' + (hello.version ? ' to ' + hello.version : '') + ' — reload this window to use it.'],
    [h('button', { type: 'button', class: 'btn sm primary', 'data-reload': '' }, withIcon('refresh-cw', 'Reload'))]);
  const b = document.querySelector('[data-reload]');
  if (b) b.addEventListener('click', () => location.reload());
}

/// Signed out (a 401, or the stream's end): the window says so over itself. Signing in is the dashboard's.
function signedOut(message, code) {
  if (state.signedOut) return;
  state.signedOut = true;
  state.csrf = null;
  clearTimeout(state.renewTimer);
  cover('This window is signed out', [h('p', null, 'Sign in on the dashboard, then come back to this window — it looks again when it is shown.'),
    h('p', { class: 'muted' }, message || ''), h('p', null, h('a', { class: 'btn primary', href: '/', target: '_blank', rel: 'noopener', 'data-chat-signin': code || '' }, 'Open the dashboard'))]);
}

/// The window's overlay: everything but the notes inert under it.
function cover(title, body) {
  const o = $('ui-overlay');
  o.replaceChildren(h('div', { class: 'ui-ov-card' }, h('div', { class: 'ui-ov-head' }, h('h2', { id: 'ui-ov-title' }, title)), h('div', { id: 'ui-ov-desc' }, ...body)));
  o.setAttribute('role', 'alertdialog');
  o.setAttribute('aria-modal', 'true');
  o.setAttribute('aria-labelledby', 'ui-ov-title');
  o.setAttribute('aria-describedby', 'ui-ov-desc');
  $('chat').inert = true;
  document.body.classList.add('ui-paused');
  o.hidden = false;
  o.focus();
}
function uncover() {
  const o = $('ui-overlay');
  o.hidden = true;
  o.replaceChildren();
  $('chat').inert = false;
  document.body.classList.remove('ui-paused');
}

/// The stream ended for good: signed out, or doz ui moved to another port (this window cannot follow it).
onLiveEnd((why) => {
  if (why === 'moved') cover('The dashboard moved', [h('p', null, 'doz ui is on another port now. Open the dashboard again, then this room from it.')]);
  else signedOut(why === 'rotated' ? 'A new link was made for this dashboard: every page signed out.' : '', why);
});

/// Shown again: the theme from the dashboard, the session (signed in again elsewhere? another build?), the room read again.
async function looked() {
  if (document.visibilityState !== 'visible') return;
  if (state.signedOut) {
    try {
      adoptSession(await apiAgain());
      state.signedOut = false;
      uncover();
      if (!state.started) { startApp(); return; }
      chatRefresh();
    } catch (_) { /* still signed out */ }
    return;
  }
  loadSettings();
  chatRefresh();
}
/// GET session without the 401 signing out again (the overlay already stands).
async function apiAgain() {
  const r = await apiFetch('session');
  if (!r.ok) throw new Error('HTTP ' + r.status);
  const info = await r.json();
  helloSeen({ version: info.version });
  return info;
}
document.addEventListener('visibilitychange', looked);
window.addEventListener('focus', () => { if (state.signedOut) looked(); });
window.addEventListener('hashchange', () => { if (state.started) showRoom(); });

// The calls up the layers the chat modules make. The window's own: a refresh is the room read again (and the dashboard's
// stream followed while one of its operations runs); the rest of the dashboard is not here, so those do nothing.
const refresh = () => { chatRefresh(); followOps(); };
const none = () => {};
const backToTrySetup = none, connect = none, lifecycle = none, modalInert = none, paintCover = none, paintResTotal = none, paintRowOps = none,
  paintSplitButton = none, paintTransition = none, paintUpdates = none, refreshNav = none, renderOps = none;
provide({
  banner, dropBanner, failureFor, opFailed, pageFailure, paintNotes, toast, refresh, signedOut, startApp, helloSeen,
  backToTrySetup, connect, lifecycle, modalInert, paintCover, paintResTotal, paintRowOps, paintSplitButton, paintTransition, paintUpdates,
  refreshNav, renderOps,
});

configureChat({
  title: 'Chat',
  request: (path, o = {}) => apiFetch('chat' + path, { method: o.method, json: o.json, bytes: o.bytes, type: o.type, actionId: o.actionId }),
  viewer: () => state.chat.human,
  canWrite: () => !state.chat.status || state.chat.status.access !== 'read',
  fileUrl: dashboardFileUrl,
});

(async () => {
  try { adoptSession(await api('session')); } catch (e) {
    if (!state.signedOut) pageFailure('Dozable did not answer: ' + (e.message || e) + '. Is doz ui running?');
    return;
  }
  startApp();
})();
