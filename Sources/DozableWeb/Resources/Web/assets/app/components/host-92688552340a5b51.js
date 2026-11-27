// components/host — The host (594 W18): the sidebar's foot, Start/Restart host, the host's transitions told once.
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { api } from '../core/api-496fd9f39af2a514.js';
import { liveRefresh } from '../core/events-a2b48e9565c99bd2.js';
import { paintFootLine, showUpdate } from '../core/session-ac3b294ded6521bf.js';
import { plural, when } from '../core/format-b2e68384da8d2f36.js';
import { act, actOrThrow } from '../core/operations-d4d2df05019ab596.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { card } from './blocks-6b2d43608253a84f.js';
import { btn } from './button-030d384b64f8d75d.js';
import { dialog } from './dialog-bae4e8002b142b21.js';
import { refreshNav } from './nav-22009a21319061d8.js';
import { banner, dropBanner, pageFailure, toast } from './notices-0c2ff2db323bba12.js';

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
  const note = host && host.versionNote;
  if (note && !state.uiDown) {
    const pair = host.uiVersion + '|' + (host.running ? host.version : '') + '|' + (host.installedVersion || '');
    let seen = state.versionNoted === pair;
    try { seen = seen || localStorage.getItem('doz.versionNoted') === pair; } catch (_) { /* no storage: once per page */ }
    if (!seen) {
      state.versionNoted = pair;
      try { localStorage.setItem('doz.versionNoted', pair); } catch (_) { /* */ }
      banner('version', 'warn', [note.text], note.older === 'host' ? [restartHostButton(host)]
        : note.older === 'ui' && canRestartDashboard() ? [restartDashboardButton()] : []);
    }
  } else if (host && !host.versionNote) {
    dropBanner('version');
  }
}
/// Restart host (`doz host restart`): stop it (its sandboxes hibernate, and wake when used) and start this UI's build.
/// 594 W20 offered it for an OLDER host (the banner); 647 (owner) on the status card for any running host.
function restartHostButton(host, opts = {}) {
  return btn(opts.label || 'Restart daemon', () => {
    // What runs NOW (the banner may be older than the last overview).
    host = (state.overview && state.overview.host) || host;
    const live = host.liveSandboxes || [];
    const same = !host.uiVersion || host.uiVersion === host.version;
    dialog('Restart the daemon?',
      'The daemon (doz ' + host.version + ') stops and ' + (same ? 'starts again' : 'doz ' + host.uiVersion + ' starts in its place') + '. ' +
      (live.length ? 'Its running sandboxes (' + live.join(', ') + ') hibernate first — sessions kept — and wake when you use them.'
                   : 'No sandbox is running.'),
      [], 'Restart daemon', async () => { await actOrThrow({ action: 'daemon-restart' }); dropBanner('version'); }, { icon: 'rotate-ccw' });
  }, { small: true, primary: !opts.quiet, quiet: !!opts.quiet, icon: 'rotate-ccw', title: 'Stop the daemon (its running sandboxes hibernate) and start doz ' + (host.uiVersion || host.version) });
}
/// 714: Restart dashboard — this doz ui restarts as `doz ui restart` does (the doz installed now, the same port); the page
/// waits for it and reloads. Offered only in this Mac's own browser: the server refuses another computer's (mac-only).
function canRestartDashboard() { return !state.serve; }
function restartDashboardButton(opts = {}) {
  return btn(opts.label || 'Restart dashboard', async (ev) => {
    const b = ev.currentTarget;
    b.disabled = true;
    try {
      await api('ui/restart', { method: 'POST', json: {} });
      state.reloadAfterRestart = true;            // the next hello is the new doz ui's: reload into its page
      dropBanner('version');
      toast('Restarting the dashboard — this page reloads by itself');
    } catch (e) {
      b.disabled = false;
      pageFailure('Restart dashboard: ' + (e.message || String(e)), { key: 'ui-restart' });
    }
  }, { small: true, primary: !opts.quiet, quiet: !!opts.quiet, icon: 'rotate-ccw',
       title: 'Restart doz ui as the doz installed now (doz ui restart) — open pages reconnect and terminals reattach' });
}
function startHostButton(opts = {}) {
  return btn(opts.label || 'Start daemon', async (ev) => {
    ev.currentTarget.disabled = true;
    await act({ action: 'daemon-start' });
  }, { small: true, primary: !opts.quiet, quiet: !!opts.quiet, icon: 'play', title: 'Starts the store’s daemon the normal way (detached, as the CLI does)' });
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
  const vn = host && !state.uiDown ? host.versionNote : null;
  const differ = !!vn || !!(host && host.running && host.uiVersion && host.version && host.uiVersion !== host.version);
  const text = differ ? (vn && vn.text) || ('The daemon runs doz ' + host.version + '; this dashboard is doz ' + host.uiVersion + '.') : '';
  // 714: an older dashboard (than the daemon, or than the doz installed now) — Restart dashboard, in this Mac's browser.
  const offer = !!(vn && vn.older === 'ui' && canRestartDashboard());
  note.hidden = !differ;
  const nk = text + (offer ? '|restart' : '');
  if (note.dataset.k !== nk) {
    note.dataset.k = nk;
    note.replaceChildren(h('span', null, text), ...(offer ? [' ', restartDashboardButton({ quiet: true })] : []));
  }
  note.classList.toggle('warn', differ);
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
      banner('host-build', '', ['The daemon is now ', h('code', null, 'doz ' + c.version), ' (was ', h('code', null, c.previousVersion), ').']);
    }
  } else if (c.state === 'stopped') {
    const why = c.reason ? ' (' + c.reason + ')' : '';
    banner('host-stopped', 'warn', n
      ? ['The doz daemon stopped' + why + ' — your sandboxes were hibernated: ', ...sandboxLinks(c.sandboxes),
         h('span', { class: 'muted' }, ' Waking one starts the daemon again, as the CLI does.')]
      : ['The doz daemon stopped' + why + '. Nothing was running. ', h('span', { class: 'muted' }, 'Any action starts the daemon again, as the CLI does.')],
      [startHostButton()]);
  } else {
    banner('host-died', 'bad', n
      ? ['The doz daemon died — ' + plural(n, 'sandbox was', 'sandboxes were') + ' running; ' + (n === 1 ? 'it is' : 'they are') +
         ' shut down (restart ' + (n === 1 ? 'it' : 'them') + '): ', ...sandboxLinks(c.sandboxes)]
      : ['The doz daemon died (killed or crashed). No sandbox was running.'],
      state.overview && state.overview.host.running ? [] : [startHostButton()]);
  }
  // Every page's phases follow at once (the grid and the sandbox pages too).
  refreshNav();
  liveRefresh();
}

/// This Mac's daemon line: what the status bar says, and Restart (running) or Start (stopped) as there.
export function hostAction(host) {
  if (!host) return null;
  return host.running ? restartHostButton(host, { quiet: true }) : startHostButton({ quiet: true });
}

export function hostCard(host) {
  if (host.running) {
    return card('Daemon', 'running', 'pid ' + host.pid + ' · ' + (host.version || '') + ' · since ' + when(host.startedAt) +
      (host.idleSeconds ? ' · idle ' + Math.round(host.idleSeconds) + ' s' : ''));
  }
  // 594 W18: every action starts a host on demand (as the CLI does); this starts one on its own.
  const c = card('Daemon', 'not running', host.recoveryPending.length ? 'recovery pending: ' + host.recoveryPending.join(', ') : 'nothing is running — shown from the store');
  c.append(h('div', { class: 'n-act' }, startHostButton()));
  return c;
}
