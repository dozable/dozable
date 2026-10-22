// components/quick-add — Quick add (599c): a sandbox with every default, started and opened.
import { api } from '../core/api-0560a03cb0de25ef.js';
import { act, actOrThrow, waitOp } from '../core/operations-1789b4518e764708.js';
import { setting, terminalsAllowed } from '../core/settings-d764a83ca7e652e0.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { btn } from './button-b2be2d3eaa1a3fd0.js';
import { createDialog } from './create-dialog-8978e10c6f0bbd64.js';
import { startWithBootView } from './lifecycle-5633f225c09da44a.js';
import { pageFailure, toast } from './notices-63d38bfc28f739a5.js';
import { openTerminal } from './terminal-a2a26ecfd1d1c37a.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';

// ── 599c: Quick add (owner: "a "Quick Add" sandbox that picks defaults for workspace name etc and opens
// it immediately") — one click, no form: the default image (defaults.image), a free name (claude-sandbox,
// -2, …), its workspace <defaults.projects_dir>/<name> (made), the default account and permissions;
// created, started with the boot view, its page open. What one click cannot decide (the agent's
// account) opens New sandbox with the requirement said; 635: an out-of-date image is used and said.
function quickAddTitle() {
  return 'One click: a ' + setting('defaults.image', 'lab') + ' sandbox with a free name, its folder in ' + setting('defaults.projects_dir', '~/doz-workspaces') + ' — started and opened';
}
export function quickAddButton() {
  const b = btn('Quick add', (ev) => quickAdd(ev.currentTarget), { icon: 'rocket', title: quickAddTitle() });
  b.dataset.quickAdd = '';
  return b;
}
export async function quickAdd(button) {
  if (state.quickAdding) return;
  state.quickAdding = true;
  const buttons = [...document.querySelectorAll('[data-quick-add]')];
  for (const b of buttons) b.disabled = true;
  try {
    const p = await api('quick-add', { method: 'POST', json: {} });
    if (p.requirement) { createDialog({ why: p.requirement, kind: p.requirementKind, image: p.image }); return; }
    const op = await actOrThrow({ action: 'create', sandbox: p.name, image: p.image, ...(p.workspace ? { workspace: p.workspace } : { isolated: true }) });
    const end = await waitOp(op.id);
    if (!end || end.state !== 'done') return;        // a failure is said by the operation's own toast
    toast('Quick add: ' + p.name + ' · ' + p.image + ' · ' + (p.workspace ? tildePath(p.workspace) : 'isolated'));
    // 635: an out-of-date image is used as it is — said, never asked (a newer patch release stopped Quick add).
    if (p.notice) pageFailure(p.name + ': ' + p.notice, { key: 'quick-add-image', tone: 'info', title: 'A newer image is available' });
    // 617: the start sequence (the build, then tab zero Console, then the agent's tab), on its page.
    if (terminalsAllowed()) { location.hash = '#/sandbox/' + p.name; await startWithBootView(p.name); return; }
    location.hash = '#/sandbox/' + p.name;
    const started = await act({ action: 'start', sandbox: p.name });
    if (started && terminalsAllowed()) {
      const s = await waitOp(started.id, 600000);
      if (s && s.state === 'done' && state.view === 'sandbox' && state.param === p.name) openTerminal(p.name, null, 'interactive');
    }
  } catch (e) {
    pageFailure('Quick add: ' + (e.message || String(e)), { key: 'quick-add' });
  } finally {
    state.quickAdding = false;
    for (const b of document.querySelectorAll('[data-quick-add]')) b.disabled = false;
    if (button && button.isConnected) button.disabled = false;
  }
}
