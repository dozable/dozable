// components/rename-dialog — Rename a sandbox (owner, 2026-10-23: "new three-dot menu in the left nav for each sandbox
// name" and the sandbox page's ⋯): the same sandbox under another name — its disks, restore points, folder and settings.
import { actOrThrow, waitOp } from '../core/operations-b9f6dfadadad7ca9.js';
import { sandboxBusy, sandboxPhase } from '../core/sandboxes-ceb80fb565978598.js';
import { state } from '../core/state-c85a0de5f7fc1060.js';
import { sview } from '../core/terminals-e2028f16ee8fa887.js';
import { callout } from './callout-f30e3ad8767a987a.js';
import { dialog } from './dialog-3d0b77f12fdc6c0f.js';

/// The host's rule (`rename`): shut down (or failed), nothing under way. Null: it can be renamed now (after a shut down
/// the dialog does itself — `mustShutDown`); else why not.
export function renameWhyNot(name) {
  const phase = sandboxPhase(name);
  if (sandboxBusy(name) || phase === 'booting') return 'Wait until it settles';
  return null;
}
/// Owner (2026-10-24: "the rename button doesnt activate" — every sandbox was hibernated): one that is not shut down is
/// shut down by the dialog first, said before the person confirms.
const mustShutDown = (name) => !['off', 'failed'].includes(sandboxPhase(name));
/// The ⋯ item (the sidebar's, the page's): always offered — the dialog says why it cannot be done yet.
export function renameItem(name) {
  return { label: 'Rename…', icon: 'pencil', desc: 'Another name — the same disks, restore points and folder', data: { 'rename-item': name },
    onSelect: () => renameDialog(name) };
}
/// What is wrong with a new name (null: nothing) — the host checks again.
function nameProblem(name, to) {
  if (!to) return 'A name is required';
  if (to === name) return 'That is its name now';
  if (to.length > 40 || !/^[a-z0-9][a-z0-9-]*$/.test(to)) return '1–40 characters of a-z, 0-9 and - (not starting with -)';
  if (state.overview && state.overview.sandboxes.some((s) => s.name === to)) return 'A sandbox called ' + to + ' exists';
  return null;
}
export function renameDialog(name) {
  const why = renameWhyNot(name);
  const shutFirst = mustShutDown(name);
  const dlg = dialog('Rename ' + name, 'The same sandbox under another name: its disks, restore points, folder, account and settings stay as they are. Its folder on the Mac keeps its own name.',
    [{ name: 'newName', label: 'New name', value: name, required: true, help: '1–40 characters of a-z, 0-9 and -' }], shutFirst ? 'Shut down and rename' : 'Rename', async (v) => {
      const to = v.newName;
      const bad = nameProblem(name, to);
      if (bad) throw new Error(bad);
      if (mustShutDown(name)) {
        const down = await actOrThrow({ action: 'shutdown', sandbox: name });
        const downEnd = await waitOp(down.id);
        if (downEnd && downEnd.state === 'failed') throw new Error(downEnd.text || name + ' did not shut down');
      }
      const op = await actOrThrow({ action: 'rename', sandbox: name, newName: to });
      const end = await waitOp(op.id);
      if (end && end.state === 'failed') throw new Error(end.text || 'The rename failed');
      if (end && end.state === 'done') movePageMemory(name, to);
    }, { icon: 'pencil' });
  const submit = dlg.querySelector('button[type="submit"]');
  const error = dlg.querySelector('.dlg-error');
  const input = dlg.inputs.newName;
  // Said in the dialog's body, where it is read — not only beside the buttons.
  const note = why ? callout('info', { compact: true, body: why + ' — ' + name + ' is ' + (sandboxPhase(name) || 'busy') + '.' })
    : shutFirst ? callout('warn', { compact: true, attrs: { 'data-rename-shutdown': '' },
      body: name + ' is ' + sandboxPhase(name) + '. Renaming shuts it down first: its running programs end; its disk, restore points and folder stay.' })
    : null;
  if (note) dlg.querySelector('.dlg-extra').append(note);
  input.setAttribute('maxlength', '40');
  input.dataset.renameName = name;
  // Said as it is typed (the same name is simply not a change yet: no message, the button waits).
  const check = () => {
    const to = input.value.trim();
    const bad = to === name ? null : nameProblem(name, to);
    error.textContent = bad || '';
    submit.disabled = !!why || !!bad || to === name;
  };
  input.addEventListener('input', check);
  check();
  input.select();
}
/// The page's own memory of the old name, carried to the new one where it is cheap: the inspector's tab and the
/// sidebar's fold (`doz.nav.folded`, components/nav.js). The page itself follows in core/operations.js (trackOp).
function movePageMemory(from, to) {
  const tab = sview(from).inspTab;
  if (tab) sview(to).inspTab = tab;
  try {
    const v = JSON.parse(localStorage.getItem('doz.nav.folded') || '[]');
    if (Array.isArray(v) && v.includes(from)) localStorage.setItem('doz.nav.folded', JSON.stringify(v.map((x) => (x === from ? to : x))));
  } catch (_) { /* no storage: nothing kept */ }
}
