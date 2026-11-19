// core/ws-lifecycle — A workspace's lifecycle, its pure parts (components/ws-lifecycle.js draws the dialogs): the verbs, the
// one primary verb a workspace's state offers, how each is confirmed, the plan route's body and the action's, and the
// sizes as a person reads them. Pure: imports nothing.

/// The verbs, in the ⋯ menu's order: each its label, its menu item, its icon and how it is confirmed (`typed`: the name;
/// `yes`: a plain confirmation; `none`). The same as `WorkspaceVerb.confirm`.
export const LIFECYCLE = {
  stop: { label: 'Stop', item: 'Stop the manager', icon: 'power', confirm: 'none', desc: 'Its manager ends; its conversation is kept' },
  sleep: { label: 'Sleep', item: 'Sleep everything', icon: 'moon', confirm: 'none', desc: 'Every agent asleep: memory given back, conversations kept' },
  wake: { label: 'Wake', item: 'Wake everything', icon: 'sun', confirm: 'none', desc: 'Every agent it put to sleep, back in the same conversations' },
  finish: { label: 'Finish', item: 'Finish…', icon: 'check', confirm: 'yes', desc: 'The work is done: everything stops; the room and tokens are kept' },
  reopen: { label: 'Reopen', item: 'Reopen', icon: 'rotate-ccw', confirm: 'none', desc: 'Back from finished: asleep until you wake it' },
  archive: { label: 'Archive', item: 'Archive…', icon: 'box', confirm: 'typed', desc: 'Put away: its rooms read-only, anonymous workers retired' },
  restore: { label: 'Restore', item: 'Restore', icon: 'history', confirm: 'none', desc: 'Back from archived, finished' },
  delete: { label: 'Delete', item: 'Delete…', icon: 'trash-2', confirm: 'typed', desc: 'Its record, brief and log deleted; nothing on disk unless ticked' },
};
export const MENU_ORDER = ['stop', 'sleep', 'wake', null, 'finish', 'archive', 'delete'];

/// How `verb` is confirmed: `typed`, `yes` or `none`.
export function confirmKind(verb) { return LIFECYCLE[verb] ? LIFECYCLE[verb].confirm : 'none'; }

/// The one primary verb a workspace's state offers: setting up → start; running (idle, working, waiting, starting) → sleep;
/// asleep → wake; finished → reopen; archived → restore.
export function primaryVerb(st) {
  switch (st) {
    case 'setting-up': return 'start';
    case 'asleep': return 'wake';
    case 'finished': return 'reopen';
    case 'archived': return 'restore';
    case 'idle': case 'working': case 'waiting-on-you': case 'starting': return 'sleep';
    default: return null;
  }
}

/// The plan route's body for `verb` on `workspace` with the dialog's ticks.
export function planBody(workspace, verb, o) {
  const b = { workspace, verb };
  if ((verb === 'archive' || verb === 'delete') && o && o.removeSandboxes) b.removeSandboxes = true;
  if (verb === 'delete' && o && o.binFolders) b.binFolders = true;
  return b;
}

/// The action that does it: exactly the plan the person saw (its sha), the ticks, the typed name, the "acts as you" tick.
export function actionBody(plan, o) {
  const b = { action: 'workspace-' + plan.verb, workspace: plan.workspace, ifPlan: plan.sha };
  if ((plan.verb === 'archive' || plan.verb === 'delete') && o.removeSandboxes) b.removeSandboxes = true;
  if (plan.verb === 'delete' && o.binFolders) b.binFolders = true;
  if (plan.verb === 'wake' && o.actsAsYou) b.actsAsYou = true;
  if (confirmKind(plan.verb) === 'typed') b.confirm = o.typed || '';
  return b;
}

/// Whether the dialog's button may be pressed: nothing refused, the name typed exactly (`typed`), the unfenced tick given.
export function canConfirm(plan, o) {
  if (!plan || plan.refusals.length) return false;
  if (plan.confirm === 'typed' && (o.typed || '') !== plan.confirmName) return false;
  if (o.needsActsAsYou && !o.actsAsYou) return false;
  return true;
}

/// Bytes as a person reads them: 6.2 GB, 420 MB.
export function sizeWords(b) {
  if (!b || b <= 0) return '';
  const u = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = b;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return (i === 0 ? String(v) : v.toFixed(v < 10 ? 1 : 0)) + ' ' + u[i];
}

/// The transitional word while a verb's operation runs ("sleeping…"); null: none.
export const TRANSITIONAL = { sleep: 'sleeping…', wake: 'waking…', finish: 'finishing…', archive: 'archiving…', restore: 'restoring…', delete: 'deleting…', stop: 'stopping…', reopen: 'reopening…' };
