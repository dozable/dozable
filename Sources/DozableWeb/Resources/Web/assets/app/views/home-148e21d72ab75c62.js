// views/home — Home (#/home, the default page): every workspace, one row each — its state in the CLI's words, the
// workspace and its folders, who drives, its manager, who is working, its room, the room's last line, one next action (a
// button: Sleep, Wake, Reopen or Restore — its plan's dialog, components/ws-lifecycle.js) — waiting on you first, then
// working, starting, idle, setting up; asleep folds into "Asleep (N)", finished and archived into one line below it.
// With none: what a workspace is, Quick try, and the sandboxes and sessions already on this Mac in none.
// Read on arrival, hello, `changed` and an operation's end — never on a timer (listing the workspaces asks every session
// on this Mac for its state). Each row's workspace drawn small beside its name (components/space-picture.js: a space
// file's picture, read only while on screen; a plain tile for one made without a file). The room's last line is read only while the chat server runs and this browser may read it,
// for the rows on screen (at most 12).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-575fccc668c266ed.js';
import { plural, when } from '../core/format-b2e68384da8d2f36.js';
import { refresh } from '../core/router-f8a96ceede26ae43.js';
import { workspaceHash } from '../core/routes-ce13c8979e42e1cc.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { byState, isDone, loadWorkspace, loadWorkspaces } from '../core/workspaces-58675c2e3031a177.js';
import { panel } from '../components/blocks-6b2d43608253a84f.js';
import { btn } from '../components/button-8109d54546d946d3.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-d408fcba356d6a76.js';
import { paintWorkspaceCounts } from '../components/nav-aba7aef945f80df1.js';
import { toast } from '../components/notices-d1747982910355b9.js';
import { driverChip, managerChip, workspacePill } from '../components/ws-marks-26369af31d4dbb6f.js';
import { renderNavWorkspaces } from '../components/ws-nav-7565a258abff0d89.js';
import { forgetThumbs, spaceThumb } from '../components/space-picture-2509e0568df9fba2.js';
import { lifecycleCommand, lifecycleRefusal, openLifecycle, transitional } from '../components/ws-lifecycle-a834f678f04b60b4.js';
import { LIFECYCLE, primaryVerb } from '../core/ws-lifecycle-54187500e950c88c.js';
import { newWorkspaceHash, newWorkspaceRefusal } from './new-workspace-3debd77180194795.js';
import { WORKSPACE_DEFINITION } from '../core/ws-new-60f08868f5e5e130.js';

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
    h('p', { class: 'sub' }, plural(l.workspaces.length, 'workspace', 'workspaces') + ' on this Mac — the work, who drives it and who is working.'),
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
    h('td', null, w.room ? h('a', { href: workspaceHash(w.name), class: 'hm-room' }, '# ' + w.room) : h('span', { class: 'muted' }, '—')),
    h('td', { class: 'hm-last' }, last || ''),
    h('td', { class: 'hm-next' }, next(w, d)));
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

/// One next action: the button its state offers (Sleep, Wake, Reopen, Restore — the plan's dialog); a setting-up one's gaps
/// and the command that starts it; a started one's room beside.
function next(w, d) {
  const verb = primaryVerb(w.state);
  if (verb && verb !== 'start') {
    const why = lifecycleRefusal(), v = LIFECYCLE[verb];
    const b = h('button', { type: 'button', class: 'btn sm', 'data-home-next': verb, disabled: why || transitional(w.name) ? true : null,
      title: why ? why + ' — ' + lifecycleCommand(verb, w.name) : v.desc,
      on: { click: async () => {
        try { openLifecycle(await loadWorkspace(w.name, 0), verb, async () => { await loadWorkspaces(0).catch(() => null); refresh(false); }); } catch (e) { toast(e.message || String(e), true); }
      } } }, icon(v.icon), v.label);
    return h('div', { class: 'hm-next-acts' }, b, !isDone(w) && w.room ? h('a', { href: workspaceHash(w.name), class: 'btn sm quiet' }, icon('message-square'), 'Open room') : null);
  }
  if (isDone(w)) return null;
  if (w.state === 'setting-up') {
    const lines = d ? (d.gaps || []).map((g) => g.why).concat(d.notes) : [];
    const gaps = lines.length ? h('ul', { class: 'hm-gaps' }, ...lines.map((n) => h('li', null, n))) : null;
    return h('div', { class: 'hm-start' }, gaps, cmdLine('doz workspace start ' + w.name));
  }
  return w.room ? h('a', { href: workspaceHash(w.name), class: 'btn sm' }, icon('message-square'), 'Open room') : null;
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
