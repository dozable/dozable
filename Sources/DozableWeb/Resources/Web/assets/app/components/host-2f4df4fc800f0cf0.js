// components/host — The host (594 W18): the sidebar's foot, Start/Restart host, the host's transitions told once.
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { api } from '../core/api-0560a03cb0de25ef.js';
import { liveRefresh } from '../core/events-df09e5a656060809.js';
import { paintFootLine, showUpdate } from '../core/session-bd22eba33578b6ab.js';
import { plural, when } from '../core/format-b2e68384da8d2f36.js';
import { act, actOrThrow } from '../core/operations-773ff6e3f3377064.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { card } from './blocks-6b2d43608253a84f.js';
import { btn } from './button-f435595b4098d043.js';
import { dialog } from './dialog-ee9a9a31b03dc349.js';
import { refreshNav } from './nav-ff6366e8c8d63067.js';
import { banner, dropBanner, pageFailure, toast } from './notices-0fbf2b02156017c5.js';

function sandboxLinks(names) {
  return names.map((n) => h('a', { href: '#/sandbox/' + n, 'data-sandbox-link': n }, n));
}
/// The host's fact in the footer: from the last overview, or — while doz ui is away — what the page last
/// knew, said as such.
export function renderHostFoot() {
  const el = $('host-live');
  if (!el) return;
  const host = state.overview && state.overview.host;
  let kind = '', text = '—';
  if (host) {
    const died = state.hostChange && state.hostChange.state === 'died' && !host.running;
    if (host.running) { kind = 'on'; text = 'running · doz ' + (host.version || '?'); }
    else if (died) { kind = 'bad'; text = 'died'; }
    else { kind = 'warn'; text = 'stopped'; }
  }
  if (state.uiDown) { text = host ? 'last seen ' + text : 'unknown'; kind += ' stale'; }
  el.className = 'live' + (kind ? ' ' + kind : '');
  el.dataset.host = host ? (host.running ? 'running' : (state.hostChange && state.hostChange.state === 'died' ? 'died' : 'stopped')) : '';
  $('host-text').textContent = text;
  paintHostCard(host);
  paintFootLine();
  // One note, once per pair of builds: this UI and the host it talks to differ. 594 W20: the server
  // compares them and advises the OLDER side (a host older than this UI: stop it — Restart host).
  const note = host && host.running && host.versionNote;
  if (note && !state.uiDown) {
    const pair = host.uiVersion + '|' + host.version;
    let seen = state.versionNoted === pair;
    try { seen = seen || localStorage.getItem('doz.versionNoted') === pair; } catch (_) { /* no storage: once per page */ }
    if (!seen) {
      state.versionNoted = pair;
      try { localStorage.setItem('doz.versionNoted', pair); } catch (_) { /* */ }
      banner('version', 'warn', [note.text], note.older === 'host' ? [restartHostButton(host)] : []);
    }
  } else if (host && host.running && !host.versionNote) {
    dropBanner('version');
  }
}
/// Restart host (`doz host restart`): stop it (its sandboxes hibernate, and wake when used) and start this UI's build.
/// 594 W20 offered it for an OLDER host (the banner); 647 (owner) on the status card for any running host.
function restartHostButton(host, opts = {}) {
  return btn(opts.label || 'Restart host', () => {
    // What runs NOW (the banner may be older than the last overview).
    host = (state.overview && state.overview.host) || host;
    const live = host.liveSandboxes || [];
    const same = !host.uiVersion || host.uiVersion === host.version;
    dialog('Restart the host?',
      'The host (doz ' + host.version + ') stops and ' + (same ? 'starts again' : 'doz ' + host.uiVersion + ' starts in its place') + '. ' +
      (live.length ? 'Its running sandboxes (' + live.join(', ') + ') hibernate first — sessions kept — and wake when you use them.'
                   : 'No sandbox is running.'),
      [], 'Restart host', async () => { await actOrThrow({ action: 'host-restart' }); dropBanner('version'); }, { icon: 'rotate-ccw' });
  }, { small: true, primary: !opts.quiet, quiet: !!opts.quiet, icon: 'rotate-ccw', title: 'Stop the host (its running sandboxes hibernate) and start doz ' + (host.uiVersion || host.version) });
}
function startHostButton(opts = {}) {
  return btn(opts.label || 'Start host', async (ev) => {
    ev.currentTarget.disabled = true;
    await act({ action: 'host-start' });
  }, { small: true, primary: !opts.quiet, quiet: !!opts.quiet, icon: 'play', title: 'Starts the store’s host the normal way (detached, as the CLI does)' });
}

// ── 647 (owner: "make the footer popup interactive"): the status card's actions ─────────────────────────────────────
/// The host's row: Restart (running) or Start (stopped, died); the line under it when the host and this dashboard are
/// different builds. Built only when what it says changes (a poll never replaces a button under the pointer).
function paintHostCard(host) {
  const slot = $('host-act'), note = $('foot-mismatch');
  if (!slot || !note) return;
  const k = !host || state.uiDown ? '' : host.running ? 'restart|' + host.version + '|' + (host.uiVersion || '') : 'start';
  if (slot.dataset.k !== k) {
    slot.dataset.k = k;
    slot.replaceChildren(...(k === '' ? [] : host.running ? [restartHostButton(host, { quiet: true, label: 'Restart' })] : [startHostButton({ quiet: true, label: 'Start' })]));
  }
  const differ = host && host.running && host.uiVersion && host.version && host.uiVersion !== host.version;
  const text = differ ? (host.versionNote && host.versionNote.text) || ('The host runs doz ' + host.version + '; this dashboard is doz ' + host.uiVersion + '.') : '';
  note.hidden = !differ;
  if (note.textContent !== text) note.textContent = text;
  note.classList.toggle('warn', !!differ);
}
/// The updates row: what the last check found (the session's `update`, or the answer of Check), and Check — the feed
/// asked now (POST /api/v1/updates/check; a development build is never updated, and says so).
export function paintUpdates() {
  const row = $('upd-live'), text = $('upd-text'), slot = $('upd-act');
  if (!row || !text || !slot) return;
  const u = state.update, c = state.updateCheck;
  let kind = '', words = 'not checked here yet';
  if (state.updateChecking) words = 'checking…';
  else if (c && c.disabled) { kind = 'stale'; words = c.disabled; }
  else if (u && u.kind === 'installed') { kind = 'warn'; words = u.text; }
  else if (u) { kind = 'info'; words = 'doz ' + u.version + ' is available — ' + u.command; }
  else if (c && c.offline) { kind = 'warn'; words = 'the update feed could not be reached'; }
  else if (c) { kind = 'on'; words = 'up to date (doz ' + c.current + ') · checked ' + new Date(c.checkedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); }
  row.className = 'live upd' + (kind ? ' ' + kind : '');
  text.textContent = words;
  if (!slot.firstChild) {
    slot.append(btn('Check', () => checkUpdates(), { small: true, quiet: true, icon: 'refresh-cw', title: 'Look for a newer doz now' }));
  }
  const b = slot.querySelector('button');
  if (b) b.disabled = !!state.updateChecking || !!(c && c.disabled);
  paintFootLine();
}
async function checkUpdates() {
  state.updateChecking = true;
  paintUpdates();
  try {
    const r = await api('updates/check', { method: 'POST', json: {} });
    state.updateCheck = r;
    if (!r.disabled) { state.update = r.update || null; showUpdate(state.update); }
    if (r.problem) pageFailure(r.problem, { key: 'update-problem', tone: 'warn', title: 'Updates' });
    else if (!r.disabled && !r.offline && !r.update) toast('doz ' + r.current + ' is the newest on its channel');
  } catch (e) {
    pageFailure('Check for updates: ' + (e.message || String(e)), { key: 'update-check' });
  } finally {
    state.updateChecking = false;
    paintUpdates();
  }
}
/// SSE `host`: one transition of the host.
export function hostChanged(c) {
  state.hostChange = c;
  const n = c.sandboxes.length;
  if (c.state === 'running') {
    dropBanner('host-stopped');
    if (c.previousVersion) {
      banner('host-build', '', ['The host is now ', h('code', null, 'doz ' + c.version), ' (was ', h('code', null, c.previousVersion), ').']);
    }
  } else if (c.state === 'stopped') {
    const why = c.reason ? ' (' + c.reason + ')' : '';
    banner('host-stopped', 'warn', n
      ? ['The doz host stopped' + why + ' — your sandboxes were hibernated: ', ...sandboxLinks(c.sandboxes),
         h('span', { class: 'muted' }, ' Waking one starts a host again, as the CLI does.')]
      : ['The doz host stopped' + why + '. Nothing was running. ', h('span', { class: 'muted' }, 'Any action starts a host again, as the CLI does.')],
      [startHostButton()]);
  } else {
    banner('host-died', 'bad', n
      ? ['The doz host died — ' + plural(n, 'sandbox was', 'sandboxes were') + ' running; ' + (n === 1 ? 'it is' : 'they are') +
         ' shut down (restart ' + (n === 1 ? 'it' : 'them') + '): ', ...sandboxLinks(c.sandboxes)]
      : ['The doz host died (killed or crashed). No sandbox was running.'],
      state.overview && state.overview.host.running ? [] : [startHostButton()]);
  }
  // Every page's phases follow at once (the grid and the sandbox pages too).
  refreshNav();
  liveRefresh();
}

export function hostCard(host) {
  if (host.running) {
    return card('Host', 'running', 'pid ' + host.pid + ' · ' + (host.version || '') + ' · since ' + when(host.startedAt) +
      (host.idleSeconds ? ' · idle ' + Math.round(host.idleSeconds) + ' s' : ''));
  }
  // 594 W18: every action starts a host on demand (as the CLI does); this starts one on its own.
  const c = card('Host', 'not running', host.recoveryPending.length ? 'recovery pending: ' + host.recoveryPending.join(', ') : 'nothing is running — shown from the store');
  c.append(h('div', { class: 'n-act' }, startHostButton()));
  return c;
}
