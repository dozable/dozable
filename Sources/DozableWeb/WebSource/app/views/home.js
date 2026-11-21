// views/home — Home (#/home, the default page): every workspace, one row each — its state in the CLI's words, the
// workspace and its folders, who drives, its manager, who is working, its room, the room's last line, one next action (a
// button: Sleep, Wake, Reopen or Restore — its plan's dialog, components/ws-lifecycle.js) — waiting on you first, then
// working, starting, idle, setting up; asleep folds into "Asleep (N)", finished and archived into one line below it.
// With none: what a workspace is, Quick try, and the sandboxes and sessions already on this Mac in none.
// Read on arrival, hello, `changed` and an operation's end — never on a timer (listing the workspaces asks every session
// on this Mac for its state). Each row's workspace drawn small beside its name (components/space-picture.js: a space
// file's picture, read only while on screen; a plain tile for one made without a file). The room's last line is read only while the chat server runs and this browser may read it,
// for the rows on screen (at most 12).
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { plural, when } from '../core/format.js';
import { refresh } from '../core/router.js';
import { roomHash, workspaceHash } from '../core/routes.js';
import { tildePath } from '../core/paths.js';
import { state } from '../core/state.js';
import { byState, isDone, loadWorkspace, loadWorkspaces } from '../core/workspaces.js';
import { panel } from '../components/blocks.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { cmdLine } from '../components/cmd-line.js';
import { paintWorkspaceCounts } from '../components/nav.js';
import { driverChip, managerChip, workspacePill } from '../components/ws-marks.js';
import { renderNavWorkspaces } from '../components/ws-nav.js';
import { forgetThumbs, spaceThumb } from '../components/space-picture.js';
import { transitional } from '../components/ws-lifecycle.js';
import { wsNext } from '../components/ws-next.js';
import { newWorkspaceHash, newWorkspaceRefusal } from './new-workspace.js';
import { WORKSPACE_DEFINITION } from '../core/ws-new.js';

const LAST_ROWS = 12;
let doneOpen = false;
let asleepOpen = false;

export async function viewHome() {
  const l = await loadWorkspaces(0);
  forgetThumbs(l.workspaces.map((w) => w.name), 'home');
  paintWorkspaceCounts();
  renderNavWorkspaces();
  const head = h('div', { class: 'head' }, h('h1', null, 'Home'), newWorkspaceButton());
  const needs = h('div', { id: 'home-needs', class: 'hm-needs', hidden: true });     // Needs you comes here in its step
  const hidden = l.hidden ? callout('info', { compact: true, body: plural(l.hidden, 'sandbox or session', 'sandboxes and sessions') + ' on this Mac not shown to this browser (serve.mac_sessions).' }) : null;
  if (!l.workspaces.length) return h('div', { class: 'hm-page', 'data-home': '' }, head, needs, empty(l), hidden);
  const sorted = byState(l.workspaces);
  const live = sorted.filter((w) => !isDone(w) && w.state !== 'asleep'), asleep = sorted.filter((w) => w.state === 'asleep'), done = sorted.filter(isDone);
  // What only a workspace's own read says: a setting-up one's gaps, a waiting one's reason (the rows on screen).
  const details = new Map();
  await Promise.all(live.slice(0, LAST_ROWS).filter((w) => w.state === 'setting-up' || w.state === 'waiting-on-you')
    .map((w) => loadWorkspace(w.name, 1000).then((d) => details.set(w.name, d)).catch(() => null)));
  const last = await lastLines(live.slice(0, LAST_ROWS));
  const rows = live.map((w) => row(w, details.get(w.name), last.get(w.name)));
  if (asleep.length) {
    rows.push(h('tr', { class: 'hm-done hm-asleep' }, h('td', { colspan: '8' },
      h('button', { type: 'button', class: 'nav-ws-group hm-done-toggle', 'aria-expanded': asleepOpen ? 'true' : 'false', 'data-home-group': 'asleep',
        on: { click: () => { asleepOpen = !asleepOpen; refresh(false); } } },
        h('span', { class: 'nav-ws-gcaret' + (asleepOpen ? '' : ' folded') }, icon('chevron-down')), 'Asleep (' + asleep.length + ')'))));
    if (asleepOpen) for (const w of asleep) rows.push(row(w, null, null));
  }
  if (done.length) {
    rows.push(h('tr', { class: 'hm-done' }, h('td', { colspan: '8' },
      h('button', { type: 'button', class: 'nav-ws-group hm-done-toggle', 'aria-expanded': doneOpen ? 'true' : 'false',
        on: { click: () => { doneOpen = !doneOpen; refresh(false); } } },
        h('span', { class: 'nav-ws-gcaret' + (doneOpen ? '' : ' folded') }, icon('chevron-down')), 'Finished & archived (' + done.length + ')'))));
    if (doneOpen) for (const w of done) rows.push(row(w, null, null));
  }
  const table = h('table', { class: 'hm-table' },
    h('thead', null, h('tr', null, ...['State', 'Workspace', 'Driver', 'Manager', 'Who is working', 'Room', 'Last', h('span', { class: 'sr-only' }, 'Next')].map((c) => h('th', null, c)))),
    h('tbody', null, rows));
  return h('div', { class: 'hm-page', 'data-home': '' }, head,
    h('p', { class: 'sub' }, plural(l.workspaces.length, 'workspace', 'workspaces') + ' on this Mac — the work, who drives it and who is working. ',
      h('a', { href: '#/workspaces', 'data-home-all': '' }, 'All workspaces →')),
    needs, hidden, panel(table));
}
function row(w, d, last) {
  const folders = w.folders.length ? w.folders.map((f) => h('span', { class: 'hm-folder' }, tildePath(f))) : [h('span', { class: 'hm-folder muted' }, 'no folder')];
  return h('tr', { 'data-ws': w.name },
    h('td', null, workspacePill(w.state, w.words, transitional(w.name))),
    h('td', null, h('div', { class: 'hm-ws-cell' }, h('a', { href: workspaceHash(w.name), class: 'hm-thumb-link', tabindex: '-1', 'aria-hidden': w.space ? null : 'true' }, spaceThumb(w, 'home')),
      h('div', { class: 'hm-ws' }, h('a', { href: workspaceHash(w.name), class: 'hm-ws-name' }, h('b', null, w.name)), h('div', { class: 'hm-folders' }, ...folders)))),
    h('td', null, driverChip(w.driver)),
    h('td', null, managerChip(w.manager)),
    h('td', { class: 'hm-who' }, who(w, d)),
    h('td', null, w.room ? h('a', { href: roomHash(w.name), class: 'hm-room' }, '# ' + w.room) : h('span', { class: 'muted' }, '—')),
    h('td', { class: 'hm-last' }, last || ''),
    h('td', { class: 'hm-next' }, wsNext(w, d)));
}

/// Who is working — and, waiting on you, the reason known today (an agent blocked or in error, a sandbox failed).
function who(w, d) {
  if (w.state === 'waiting-on-you' && d) {
    const why = d.agents.filter((a) => a.activity === 'blocked' || a.activity === 'error' || a.state === 'failed')
      .map((a) => a.name + (a.activity === 'blocked' ? ' is blocked' : a.state === 'failed' ? ' failed' : ' ended in error'));
    if (why.length) return h('span', { class: 'hm-why' }, icon('triangle-alert'), why.join(' · '));
  }
  if (w.working && w.working.length) return w.working.join(', ');
  return h('span', { class: 'muted' }, w.working ? 'nobody' : '—');
}

/// The latest line of each row's room — only while the chat server runs and this browser may read it.
async function lastLines(list) {
  const out = new Map();
  const st = state.chat.status;
  if (!st || st.state !== 'running') return out;
  await Promise.all(list.filter((w) => w.room).map(async (w) => {
    try {
      const ms = await api('chat/rooms/' + w.room + '/messages?limit=1');
      const m = Array.isArray(ms) ? ms[ms.length - 1] : null;
      if (!m) return;
      const at = +m.at ? new Date(m.at * 1000).toISOString() : null;
      const text = m.deleted ? 'a message was deleted' : m.kind === 'private' ? 'a direct message' : String(m.content || '').replace(/\s+/g, ' ').trim();
      out.set(w.name, h('span', { class: 'hm-line', title: (m.from || '') + ': ' + text }, h('b', null, (m.from || '') + ': '), text.slice(0, 120),
        at ? h('span', { class: 'hm-age' }, ' · ' + when(at)) : null));
    } catch (_) { /* nothing said */ }
  }));
  return out;
}

/// New workspace: the wizard (#/new-workspace) — disabled with why in another computer's browser.
function newWorkspaceButton(primary) {
  const why = newWorkspaceRefusal();
  const b = btn('New workspace', () => { location.hash = newWorkspaceHash(); }, { primary: !!primary, icon: 'folder-plus', title: why || 'The work, who manages it, where it runs and when it starts' });
  b.dataset.wsNew = 'home';
  if (why) b.disabled = true;
  return b;
}

/// No workspace yet (S02): what one is, Quick try, and what is already on this Mac in none.
function empty(l) {
  const sbx = l.loose.filter((a) => a.kind === 'sandbox').length, macs = l.loose.length - sbx;
  return h('div', { class: 'hm-empty', 'data-home-empty': '' },
    h('h2', null, 'No workspaces yet'),
    h('p', { class: 'hm-def' }, WORKSPACE_DEFINITION),
    h('div', { class: 'hm-acts' }, newWorkspaceButton(true), btn('Just try an agent', () => { location.hash = '#/try'; }, { icon: 'play', title: 'Quick try: an agent in a fresh sandbox, safe defaults' })),
    l.loose.length ? h('p', null, h('b', null, 'Already have sandboxes? '),
      plural(sbx, 'sandbox', 'sandboxes') + ' and ' + plural(macs, 'session', 'sessions') + ' on this Mac are not in any workspace. ',
      h('a', { href: '#/mac/loose' }, 'Put them in workspaces…')) : null,
    h('p', null, h('b', null, 'An agent elsewhere? '), 'A bot on another machine can join a room with its own token. ', h('a', { href: '#/bots' }, 'Agents / Bots…')),
    h('p', { class: 'sub' }, 'Make one in a terminal on this Mac: ', cmdLine('doz workspace new NAME --prompt-file BRIEF.md')));
}
