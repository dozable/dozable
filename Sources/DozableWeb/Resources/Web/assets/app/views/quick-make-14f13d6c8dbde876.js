// views/quick-make — A sandbox made the quick way (617's Quick try Start; 634: the setup's First sandbox too — one path,
// never two). From the host's plan (`POST plan`, purpose try or first): the click's own frame moves — the sandbox's page
// draws its header and the build panel from the plan (`state.pendingTry`) while the ordinary `create` action runs
// behind it; then the start with the boot view (Console, then the tool's tab). A create that fails stays on that page
// with Back (to the Quick try's setup, or to the setup wizard — `back`).
import { api } from '../core/api-91016dbc2d27b20b.js';
import { actOrThrow, beginTransition, cancelTransition, waitOp } from '../core/operations-03d7dd105dcc61d2.js';
import { state } from '../core/state-2d94fd2b00c043b7.js';
import { startWithBootView } from '../components/lifecycle-ba62b68bdffd9011.js';
import { renderNavSandboxes } from '../components/nav-4bb64c7e1ee51864.js';
import { paintStartProgress } from '../components/start-progress-bfc81ca87feaa14d.js';
import { drawPendingTry } from './sandbox-9ace7f45a00cb7cd.js';

/// plan: the host's plan; agent/title: the tool; account: the setup's account choice (kept for Back); back: 'onboarding'
/// when the setup wizard made it (else Back reopens the Quick try's setup); before(): close what is open, in this frame.
/// Resolves true once the start has begun, false when the create failed (said on the page).
export async function startQuickMade({ plan, agent, title, account = null, back = null, before = () => {} }) {
  const c = plan.create, name = plan.name;
  state.pendingTry = { name, agent, title, image: c.image, imageTitle: plan.image && plan.image.title,
    workspace: c.workspace || null, account: plan.account && plan.account.name, network: c.network || 'agent',
    plan, account_: account, back, error: null, at: Date.now() };
  beginTransition(name, 'start', ['start']);
  renderNavSandboxes();
  before();
  location.hash = '#/sandbox/' + name;
  try {
    const op = await actOrThrow({ action: 'create', sandbox: name, image: c.image,
      ...(c.network ? { network: c.network } : {}), ...(c.workspace ? { workspace: c.workspace } : { isolated: true }),
      ...(c.account ? { account: c.account } : {}),
      ...(c.modelSource ? { modelSource: c.modelSource } : {}), ...(c.model ? { model: c.model } : {}) });
    const end = await waitOp(op.id);
    if (!end || end.state !== 'done') throw new Error((end && end.text) || name + ' was not made');
    // The nav lists it, then its own page takes over from the plan's (the start keeps the transition and the panel).
    try { state.overview = await api('overview'); renderNavSandboxes(); } catch (_) { /* the next poll */ }
    const p = state.pendingTry;
    if (p && p.name === name) state.pendingTry = null;
    startWithBootView(name);
    return true;
  } catch (e) {
    const p = state.pendingTry;
    if (p && p.name === name) p.error = e.message || String(e);
    cancelTransition(name, 'start');
    renderNavSandboxes();
    if (state.view === 'sandbox' && state.param === name) { drawPendingTry(name); paintStartProgress(); }
    return false;
  }
}
