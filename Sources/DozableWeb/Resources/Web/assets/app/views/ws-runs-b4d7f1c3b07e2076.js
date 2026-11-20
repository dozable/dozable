// views/ws-runs — A workspace's Runs tab (#/w/NAME/runs): each run (a start or a reopen to its finish) with its window,
// its length, its archive (written, not written, none) and size and the timesheet's totals (`POST /api/v1/workspace-runs` —
// `workspace-runs`, read from the store, no daemon started); "Write its archive again" for a run whose archive could not be
// written (the `workspace-run-archive` action). A run opens to its archived messages, read-only (`POST
// /api/v1/workspace-run-chat`, from the archive's files, verified; this browser only as serve.chat lets it read chat) and its
// timesheet; conversations and screens are never served. Below, the workspace's rooms with their state and — this Mac's
// own browser only — Archive room… and Remove room… (the name typed), each exactly its action, each looked at first
// (`POST /api/v1/chat-room-plan`).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { api } from '../core/api-575fccc668c266ed.js';
import { full } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, waitForOp } from '../core/operations-13729f56119714a1.js';
import { isRemote } from '../core/session-312b29269085e944.js';
import { sizeWords } from '../core/ws-lifecycle-54187500e950c88c.js';
import { btn } from '../components/button-8109d54546d946d3.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-e34a50f80637ff89.js';
import { dialog } from '../components/dialog-4e65dd3da1ca3eeb.js';
import { toast } from '../components/notices-64b09147d0894f01.js';

const REMOTE = 'Only from this Mac’s own browser';
const STATUS = { open: 'open', written: 'archived', problem: 'archive not written', none: 'no archive', missing: 'archive missing' };
const length = (m) => Math.floor(m / 60) + ' h ' + String(m % 60).padStart(2, '0') + ' min';

/// Draw the tab for workspace `name` (its detail `d`) into `host`.
export async function runsTab(name, host, d) {
  host.replaceChildren(h('p', { class: 'muted' }, 'Reading its runs…'));
  let l;
  try { l = await api('workspace-runs', { method: 'POST', json: { workspace: name } }); } catch (e) {
    host.replaceChildren(callout('bad', { compact: true, body: e.message || String(e) }));
    return;
  }
  const rows = l.runs.slice().reverse().map((r) => h('li', { class: 'wr-run', 'data-wr-run': r.id, 'data-wr-status': r.archiveStatus },
    h('div', { class: 'wr-head' },
      h('b', null, 'Run ' + r.id), h('span', { class: 'pill' }, STATUS[r.archiveStatus] || r.archiveStatus),
      h('span', { class: 'muted' }, full(r.startedAt) + ' → ' + (r.endedAt ? full(r.endedAt) : 'now') + ' · ' + length(r.minutes))),
    h('div', { class: 'wr-totals muted' },
      r.archiveBytes ? sizeWords(r.archiveBytes) : null,
      r.messages != null ? ' · ' + r.messages + ' message' + (r.messages === 1 ? '' : 's') : null,
      r.calls != null ? ' · ' + r.calls + ' model calls · ' + (r.tokensIn || 0) + ' / ' + (r.tokensOut || 0) + ' tokens' : null,
      r.activeMinutes != null ? ' · ' + r.activeMinutes + ' min active' : null),
    r.archiveProblem ? callout('warn', { compact: true, body: 'Its archive was not written: ' + r.archiveProblem }) : null,
    h('div', { class: 'wr-actions' },
      r.archiveStatus === 'written' ? btn('Read its messages', () => openRun(name, host, d, r), { small: true, icon: 'chat' }) : null,
      r.archiveStatus === 'problem' || (r.archiveStatus === 'none' && r.endedAt && !r.legacy) ? archiveAgain(name, host, d, r) : null)));
  host.replaceChildren(h('section', { class: 'wr-runs' }, h('h2', null, 'Runs'),
    rows.length ? h('ol', { class: 'wr-list', 'data-wr-count': String(rows.length) }, ...rows) : h('p', { class: 'muted', 'data-wr-count': '0' }, l.note || 'No runs yet.')),
  await roomsSection(name, host, d));
}

function archiveAgain(name, host, d, r) {
  const why = isRemote() ? REMOTE : null;
  const b = btn('Write its archive again', async () => {
    try {
      const end = await waitForOp(await actOrThrow({ action: 'workspace-run-archive', workspace: name, run: r.id }), 300);
      if (end && end.state === 'done') toast(end.text); else throw new Error((end && end.text) || 'No answer yet');
    } catch (e) { toast(e.message || String(e), 'bad'); }
    runsTab(name, host, d);
  }, { small: true, icon: 'archive', title: why ? why + ' — doz workspace runs ' + name + ' --archive ' + r.id : null });
  b.dataset.wrArchiveAgain = r.id;
  if (why) b.disabled = true;
  return b;
}

/// A run's page: its archived messages (read-only) and its timesheet.
async function openRun(name, host, d, r) {
  const rooms = r.rooms.map((x) => x.room);
  host.replaceChildren(h('p', { class: 'muted' }, 'Reading run ' + r.id + '’s archive…'));
  const parts = [];
  let sheet = null;
  for (const room of rooms) {
    try {
      const a = await api('workspace-run-chat', { method: 'POST', json: { workspace: name, run: r.id, room } });
      sheet = sheet || a.timesheet;
      parts.push(h('section', { class: 'wr-chat', 'data-wr-room': room, 'data-wr-messages': String(a.messages.length) },
        h('h3', null, '#' + room),
        a.messages.length ? h('ol', { class: 'wr-log' }, ...a.messages.map((m) => h('li', { class: 'wr-msg' + (m.kind ? ' is-change' : '') },
          h('span', { class: 'wr-from' }, m.from), h('span', { class: 'wr-at muted' }, m.at ? full(m.at * 1000) : ''),
          h('div', { class: 'wr-text' }, m.content))))
          : h('p', { class: 'muted' }, 'No messages in this run.')));
    } catch (e) {
      parts.push(callout('bad', { compact: true, body: '#' + room + ': ' + (e.message || String(e)) }));
    }
  }
  host.replaceChildren(h('div', { class: 'wr-page', 'data-wr-page': r.id },
    btn('All runs', () => runsTab(name, host, d), { small: true, icon: 'arrow-left' }),
    h('h2', null, 'Run ' + r.id),
    h('p', { class: 'muted' }, 'Read from its archive (verified). Nothing here can be written to.'),
    ...parts,
    sheet ? h('details', { class: 'wr-sheet', open: true }, h('summary', null, 'Timesheet'), h('pre', { class: 'wr-pre' }, sheet)) : null));
}

/// The workspace's rooms, their state, and their archive and removal.
async function roomsSection(name, host, d) {
  const items = [];
  for (const r of d.rooms || []) {
    let p = null;
    try { p = await api('chat-room-plan', { method: 'POST', json: { room: r.room, verb: 'archive' } }); } catch (e) { p = null; }
    const state = r.goneAt ? 'gone' : p ? p.state : 'open';
    const why = isRemote() ? REMOTE : null;
    const acts = [];
    if (!r.goneAt && r.owned !== false) {
      const a = btn('Archive room…', () => roomDialog(name, host, d, r.room, 'archive'), { small: true, icon: 'archive', title: why ? why + ' — doz chat room archive ' + r.room : null });
      a.dataset.wrRoomArchive = r.room;
      const x = btn('Remove room…', () => roomDialog(name, host, d, r.room, 'rm'), { small: true, icon: 'trash', title: why ? why + ' — doz chat room rm ' + r.room : null });
      x.dataset.wrRoomRm = r.room;
      if (why) { a.disabled = true; x.disabled = true; }
      acts.push(a, x);
    }
    items.push(h('li', { class: 'wr-room', 'data-wr-room-state': state, 'data-room': r.room },
      h('b', null, '#' + r.room), h('span', { class: 'pill wr-state is-' + state }, state),
      r.owned === false ? h('span', { class: 'muted' }, 'linked: never archived or removed here') : null,
      state === 'gone' ? h('span', { class: 'muted' }, 'removed for good — read it in its run’s archive') : null,
      ...acts));
  }
  return h('section', { class: 'wr-rooms' }, h('h2', null, 'Rooms'), items.length ? h('ul', { class: 'wr-room-list' }, ...items) : h('p', { class: 'muted' }, 'No room.'));
}

/// Archive room… / Remove room…: its plan first; rm's button only once the name is typed.
async function roomDialog(name, host, d, room, verb) {
  let plan = null, typed = '';
  const body = h('div', { class: 'wr-plan' }, h('p', { class: 'muted' }, 'Reading what it would do…'));
  const input = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', 'data-wr-typed': '', placeholder: room });
  const ok = () => !!plan && !plan.refusals.length && (verb !== 'rm' || typed === room);
  const dlg = dialog((verb === 'rm' ? 'Remove #' : 'Archive #') + room + '?', null,
    [{ name: 'plan', type: 'custom', el: h('div', null, body, verb === 'rm' ? h('label', { class: 'field' }, h('span', null, 'Type ' + room + ' to remove it for good'), input) : null), get: () => null }],
    verb === 'rm' ? 'Remove for good' : 'Archive', async () => {
      if (!ok()) throw new Error('Nothing to do until it can be done.');
      const b = { action: verb === 'rm' ? 'chat-room-rm' : 'chat-room-archive', room, ifPlan: plan.sha };
      if (verb === 'rm') b.confirm = typed;
      const end = await waitForOp(await actOrThrow(b), 300);
      if (!end) throw new Error('No answer yet — Operations shows how it ends.');
      if (end.state !== 'done') throw new Error(end.text || 'It did not finish.');
      toast(end.text);
      runsTab(name, host, d);
    }, { danger: verb === 'rm', icon: verb === 'rm' ? 'trash' : 'archive' });
  dlg.dataset.wrRoomDialog = verb;
  const submit = dlg.querySelector('.dlg-buttons button[type="submit"]');
  const gate = () => { if (submit) submit.disabled = !ok(); };
  input.addEventListener('input', () => { typed = input.value.trim(); gate(); });
  gate();
  try { plan = await api('chat-room-plan', { method: 'POST', json: { room, verb } }); } catch (e) {
    body.replaceChildren(callout('bad', { compact: true, body: e.message || String(e) }));
    return;
  }
  body.replaceChildren(
    h('p', null, '#' + room + ' is ' + plan.state + (plan.lastSeq != null ? ', ' + plan.lastSeq + ' messages' : '') + '.'),
    plan.archive ? h('p', { class: 'muted' }, (verb === 'rm' ? 'Its archived copy: ' : 'Its history goes into ') + plan.archive) : null,
    plan.refusals.length ? callout('bad', { compact: true, title: 'It cannot be done now', body: h('ul', null, ...plan.refusals.map((x) => h('li', null, x))), attrs: { 'data-wr-refusals': String(plan.refusals.length) } }) : null,
    ...plan.notes.map((n) => h('p', { class: 'muted' }, n)),
    h('details', null, h('summary', null, 'Show the command'), cmdLine(plan.command)));
  dlg.dataset.wrSha = plan.sha;
  gate();
}

