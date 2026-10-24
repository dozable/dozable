// components/open-with — 646 (owner: "open the workspace in my editor"): a shared workspace, or a folder or file in it,
// opened on the Mac — in the Finder or in an editor.
//
// Rules this module keeps:
//   · The editors are the HOST's answer (`GET /api/v1/editors`: the known editors installed on this Mac, then
//     bridges.open_apps) — asked once per page; the page never names an app the host did not offer.
//   · The editor last used comes first (this browser's `doz.openWith` — a per-viewer convenience, no setting).
//   · Only the Mac's own browser: a LAN device's never offers it (the routes are mac-screen; callers check isRemote()).
import { api } from '../core/api-0560a03cb0de25ef.js';
import { failureFor, toast } from './notices-0c6c4de774aaf1a4.js';

const KEY = 'doz.openWith';
let editors = null;          // [{id, name}] once the host answered
let asking = null;
const waiting = new Set();

/// The editors, once known (else []); the first call asks the host, and `onReady` runs when it answered.
export function editorsNow(onReady) {
  if (editors) return editors;
  if (onReady) waiting.add(onReady);
  if (!asking) {
    asking = api('editors').then((list) => { editors = Array.isArray(list) ? list : []; })
      .catch(() => { editors = []; })
      .finally(() => { const w = [...waiting]; waiting.clear(); for (const f of w) f(); });
  }
  return [];
}
function remembered() { try { return localStorage.getItem(KEY) || ''; } catch (_) { return ''; } }
function remember(id) { try { localStorage.setItem(KEY, id); } catch (_) { /* no storage: this page only */ } }
/// The editors with the one last used first.
export function editorsInOrder(onReady) {
  const list = editorsNow(onReady), last = remembered();
  const i = list.findIndex((e) => e.id === last);
  return i > 0 ? [list[i], ...list.slice(0, i), ...list.slice(i + 1)] : list;
}

/// Open `path` (a guest path in /workspace) of sandbox `name` on the Mac: in `app` (an editor's id), else the Finder for
/// a folder / its default app for a file, or `reveal` it. The host's sentence is the toast; a refusal is the sandbox's.
export async function openOnMac(name, path, { app, reveal } = {}) {
  try {
    const r = await api('sandboxes/' + name + '/files/open', { method: 'POST', json: app ? { path, app } : { path, reveal: !!reveal } });
    if (app) remember(app);
    toast(r.message);
  } catch (e) { failureFor(name, e.message || String(e)); }
}

/// The menu items "Open in <editor>" for `path` — the last used first; while the host has not answered, none (`onReady`
/// redraws the menu).
export function editorItems(name, path, onReady) {
  return editorsInOrder(onReady).map((e) => ({ label: 'Open in ' + e.name, icon: 'code-xml', data: { openWith: e.id },
    onSelect: () => openOnMac(name, path, { app: e.id }) }));
}
