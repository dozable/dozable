// views/quick-make — A sandbox made the quick way (617's Quick try Start; 634: the setup's First sandbox too — one path,
// never two). From the host's plan (`POST plan`, purpose try or first): the click's own frame moves — the sandbox's page
// draws its header and the build panel from the plan (`state.pendingTry`) while the ordinary `create` action runs
// behind it; then the start with the boot view (Console, then the tool's tab). A create that fails stays on that page
// with Back (to the Quick try's setup, or to the setup wizard — `back`).
import { api } from '../core/api-b1749184317a6239.js';
import { actOrThrow, beginTransition, cancelTransition, waitOp } from '../core/operations-4219a26d2d8bc16f.js';
import { state } from '../core/state-d6b90484a98480b9.js';
import { startWithBootView } from '../components/lifecycle-15ef0fe1a904b8be.js';
import { renderNavSandboxes } from '../components/nav-2ee956b561ddc5f1.js';
import { paintStartProgress } from '../components/start-progress-2af0a8a9a56225c0.js';
import { drawPendingTry } from './sandbox-3a37c3be12532fd6.js';
import { placeHash } from '../core/routes-d1a9302f8a2fae19.js';

/// plan: the host's plan; agent/title: the tool; account: the setup's account choice (kept for Back); back: 'onboarding'
/// when the setup wizard made it (else Back reopens the Quick try's setup); before(): close what is open, in this frame.
/// Resolves true once the start has begun, false when the create failed (said on the page).
export async function startQuickMade({ plan, agent, title, account = null, back = null, before = () => {} }) {
  const c = plan.create, name = plan.name;
  state.pendingTry = { name, agent, title, image: c.image, imageTitle: plan.image && plan.image.title,
    folder: c.folder || null, account: plan.account && plan.account.name, network: c.network || 'agent',
    plan, account_: account, back, error: null, at: Date.now() };
  beginTransition(name, 'start', ['start']);
  renderNavSandboxes();
  before();
  location.hash = placeHash('sandbox', name, null, state.frame);
  try {
    const op = await actOrThrow({ action: 'create', sandbox: name, image: c.image,
      ...(c.network ? { network: c.network } : {}), ...(c.folder ? { folder: c.folder } : { isolated: true }),
      ...(c.account ? { account: c.account } : {}),
      ...(c.modelSource ? { modelSource: c.modelSource } : {}), ...(c.model ? { model: c.model } : {}),
      ...(c.localPort ? { localPort: c.localPort } : {}) });
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
