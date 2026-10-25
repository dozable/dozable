// views/debug — 647 (owner: "a Debug page with controls to simulate all the notifications"): every kind of notice the
// dashboard shows, made on demand with sample words. Nothing here asks the host or changes a sandbox — except a sample's
// own buttons that are the real ones (Start host, Reload), which do what they always do.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { showUpdate } from '../core/session-922929b008d99045.js';
import { saveSetting, setting } from '../core/settings-0b4a6cca79ee581c.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { btn } from '../components/button-f435595b4098d043.js';
import { hostChanged } from '../components/host-ca71f5ae3d64ecfb.js';
import { clearNotes, notesMode } from '../components/notes-e2b199cd1685c2ad.js';
import { banner, dropPageNotice, failureFor, pageFailure, toast } from '../components/notices-e1a47ffbab8f403c.js';
import { panel } from '../components/blocks-6b2d43608253a84f.js';

/// A sandbox's name for the samples: the first one this store has, else a made-up one.
function someSandbox() { const s = state.overview && state.overview.sandboxes[0]; return s ? s.name : 'web-app'; }
const fake = () => btn('Open', () => toast('(Debug) the button of a sample notice'), { small: true, quiet: true });

const SAMPLES = [
  { group: 'Successes — they go by themselves after 8 s (every countdown waits while the pointer is on a card)', items: [
    { label: 'A success', run: () => toast(someSandbox() + ' started in 3.2 s') },
    { label: 'A session’s notice', run: () => toast('hello copied 42 chars to the Mac’s clipboard', false, 'info', { cls: 'bridge', attrs: { 'data-bridge': 'debug' } }) },
    { label: 'Copied', run: () => toast('Copied the address') },
  ] },
  { group: 'Failures and warnings — they stay until you close them', items: [
    { label: 'An action failed', run: () => pageFailure('Start ' + someSandbox() + ': the image could not be prepared — the network did not answer', { key: 'debug-fail' }) },
    { label: 'A warning', run: () => pageFailure('Browser terminals are off (Settings → ui.terminals). Open in Terminal still works.', { tone: 'warn', key: 'debug-warn' }) },
    { label: 'Information', run: () => pageFailure(someSandbox() + ': a newer image is available — it is used from the next create', { tone: 'info', key: 'debug-info', title: 'A newer image is available' }) },
    { label: 'A sandbox’s failure', run: () => failureFor(someSandbox(), 'could not hibernate — it was shut down instead (its disk is kept)') },
    { label: 'A bridge refused', run: () => pageFailure('hello: opening files on the Mac is off for this sandbox (sandbox.open_files)', { tone: 'warn', key: 'debug-bridge' }) },
  ] },
  { group: 'Agents — done goes after 10 s; blocked and error stay while they are true', items: [
    { label: 'Agent done', run: () => agent('done', 'ok', 'is done', 'Turn complete in 4.0s.') },
    { label: 'Agent blocked', run: () => agent('blocked', 'warn', 'needs permission', 'Run npm install?') },
    { label: 'Agent error', run: () => agent('error', 'bad', 'stopped with an error', 'Service unavailable (502)') },
  ] },
  { group: 'The host', items: [
    { label: 'Host stopped', run: () => hostChanged({ state: 'stopped', reason: 'idle for 15 min', sandboxes: [someSandbox()] }) },
    { label: 'Host died', run: () => hostChanged({ state: 'died', sandboxes: [someSandbox()] }) },
    { label: 'Host is another build', run: () => hostChanged({ state: 'running', version: '0.37.18', previousVersion: '0.37.17', sandboxes: [] }) },
    { label: 'Version mismatch', run: () => banner('version', 'warn', ['This doz ui (0.37.18) is newer than the host (0.37.17) — restart the host to use the new build.'],
      [btn('Restart host', () => toast('(Debug) Restart host would ask here — use the status card’s Restart'), { small: true, primary: true, icon: 'rotate-ccw' })]) },
  ] },
  { group: 'The dashboard', items: [
    { label: 'Update available', run: () => showUpdate({ kind: 'available', version: '0.99.0', command: 'brew upgrade doz', text: 'doz 0.99.0 is available' }) },
    { label: 'Update installed', run: () => showUpdate({ kind: 'installed', version: '0.99.0', command: 'doz host restart', text: 'doz 0.99.0 was installed — restart to apply: doz host restart (this dashboard: doz ui restart)' }) },
    { label: 'Dashboard updated', run: () => banner('ui-updated', 'info', ['Dozable was updated to 0.99.0 — reload this page to use it.'],
      [btn('Reload', () => location.reload(), { small: true, primary: true, icon: 'refresh-cw' })]) },
    { label: 'Reconnecting', run: () => banner('ui-stopped', 'info', ['Reconnecting to Dozable…']) },
    { label: 'doz ui stopped', run: () => banner('ui-stopped', 'bad', ['The doz ui process stopped (last connected 14:02).']) },
    { label: 'doz ui moved', run: () => banner('ui-stopped', 'info', ['doz ui moved to 127.0.0.1:57200.']) },
  ] },
];
function agent(st, tone, says, msg) {
  const s = someSandbox(), key = 'agent:' + s + '/claude';
  dropPageNotice(key);
  pageFailure(msg, { key, tone, title: s + ' · claude ' + says, actions: [fake()] });
  if (st === 'done') setTimeout(() => dropPageNotice(key), 10000);
}

export async function viewDebug() {
  const mode = notesMode();
  const seg = h('div', { class: 'segmented', role: 'group', 'aria-label': 'ui.notifications', 'data-debug-notes': '' },
    ['cards', 'pills', 'bell'].map((c) => h('button', { type: 'button', class: 'seg' + (c === mode ? ' active' : ''), 'aria-pressed': c === mode ? 'true' : 'false',
      on: { click: async () => {
        if (c === setting('ui.notifications', 'cards')) return;
        try { await saveSetting('ui.notifications', c); } catch (e) { pageFailure('ui.notifications was not saved: ' + (e.message || e)); }
        for (const b of seg.querySelectorAll('.seg')) { const me = b.textContent.toLowerCase() === notesMode(); b.classList.toggle('active', me); b.setAttribute('aria-pressed', me ? 'true' : 'false'); }
      } } }, c[0].toUpperCase() + c.slice(1))));
  const burst = () => {
    toast(someSandbox() + ' started in 3.2 s');
    pageFailure('Shut down notes: the guest did not answer in 30 s', { key: 'debug-b1' });
    pageFailure('ui.split_default was not saved: the settings file does not read', { tone: 'warn', key: 'debug-b2' });
    agent('blocked', 'warn', 'has a question', 'Which branch should I push to?');
    hostChanged({ state: 'stopped', reason: 'idle for 15 min', sandboxes: [someSandbox()] });
    toast('Copied the address');
  };
  return h('div', { class: 'debug-page' },
    h('div', { class: 'head' }, h('h1', null, 'Debug')),
    h('p', { class: 'sub' }, 'Make each kind of notification the dashboard shows, with sample words, to see how it looks. Nothing here asks the host or changes a sandbox.'),
    panel(h('div', { class: 'debug-groups' },
      h('div', { class: 'debug-group' }, h('h3', null, 'Show notifications as (ui.notifications)'), seg),
      ...SAMPLES.map((g) => h('div', { class: 'debug-group' }, h('h3', null, g.group),
        h('div', { class: 'debug-acts' }, ...g.items.map((it) => btn(it.label, it.run, { small: true, icon: 'bell' }))))),
      h('div', { class: 'debug-group' }, h('h3', null, 'All at once'),
        h('div', { class: 'debug-acts' }, btn('Six at once', burst, { small: true, icon: 'layers' }),
          btn('Dismiss all', () => clearNotes(), { small: true, quiet: true, icon: 'x' }),
          btn('Open the history', () => { location.hash = '#/notifications'; }, { small: true, quiet: true, icon: 'history' }))))));
}
