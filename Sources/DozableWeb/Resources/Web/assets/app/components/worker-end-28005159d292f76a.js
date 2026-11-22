// components/worker-end — Ending a workspace's worker from the dashboard: `worker-end` {workspace, name, confirm} — exactly
// `doz worker end W NAME` (never --rm), this Mac's own browser only. A dialog with a box to tick; another computer gets the
// item disabled with the command to type on the Mac. Also where "Add a worker" leads, and why this browser may not.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { actOrThrow, waitForOp } from '../core/operations-c9aa14c479d822d2.js';
import { addWorkerHash } from '../core/routes-c03e6aed84ec9eb3.js';
import { isRemote } from '../core/session-76fecfa2ea8ff65b.js';
import { dialog } from './dialog-408f2bb247f85767.js';
import { toast } from './notices-b29072c7b381a4ec.js';

/// Why this browser may not add or end a worker (null: it may).
export const WORKERS_REMOTE = 'Only from this Mac’s own browser';
export function workerRefusal() { return isRemote() ? WORKERS_REMOTE : null; }
export const endCommand = (w, n) => 'doz worker end ' + w + ' ' + n;
export const addCommand = (w) => 'doz worker add ' + w + ' --task "…"';

/// Confirm, then end `name` in `workspace`; `onDone` after it ended.
export function endWorkerDialog(workspace, name, onDone) {
  const d = dialog('End ' + name, name + '’s session (or its own sandbox) ends; its record and disk are kept. An anonymous worker leaves the room and its token is refused from now on; a bot’s token is kept.',
    [], 'End', async () => {
      const end = await waitForOp(await actOrThrow({ action: 'worker-end', workspace, name, confirm: name }), 120);
      if (!end) throw new Error('No answer yet — Operations shows how it ends.');
      if (end.state !== 'done') throw new Error(end.text || name + ' was not ended.');
      toast(end.text);
      if (onDone) onDone(end);
    }, { danger: true, confirmCheck: 'Yes, end ' + name, icon: 'power' });
  d.dataset.workerEnd = name;
  return d;
}

/// The ⋯ item that ends a live worker (the Agents tab, an agent's screen).
export function endWorkerItem(workspace, a, onDone) {
  const why = workerRefusal();
  return { label: 'End…', icon: 'power', desc: why ? why + ': ' + endCommand(workspace, a.name) : 'Its session ends; the room is told by who leaves',
    disabled: !!why, why: why ? why + ' — ' + endCommand(workspace, a.name) : null, data: { 'worker-end': a.name },
    onSelect: () => endWorkerDialog(workspace, a.name, onDone) };
}

/// "+ Add a worker": a link to its page here; another computer's is disabled, titled, with the command.
export function addWorkerLink(workspace, label, cls) {
  const why = workerRefusal();
  if (why) {
    return h('span', { class: 'aw-link-off' }, h('button', { type: 'button', class: cls || 'btn sm', disabled: true, title: why, 'data-add-worker': workspace }, label),
      h('code', { class: 'muted', title: why }, addCommand(workspace)));
  }
  return h('a', { class: cls || 'btn sm', href: addWorkerHash(workspace), 'data-add-worker': workspace }, label);
}
