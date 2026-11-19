// core/workspaces — The workspaces, their details, the loose agents and the Agents / Bots, as the page last read them
// (GET /api/v1/workspaces, /workspaces/{w}, /loose, /bots — each one read-only daemon operation). Read on hello,
// `changed`, an operation's end and arriving on a page — never on a timer: listing the workspaces asks each session
// on this Mac for its state. A read under way is shared; a read newer than `maxAgeMs` is reused.
import { api } from './api-fa1e04fa0a2ef189.js';
import { state } from './state-3b49d54e8d9b6a73.js';

const reads = new Map();      // key → {at, value, inflight}
function cached(key, path, maxAgeMs) {
  const r = reads.get(key) || {};
  if (r.value !== undefined && Date.now() - r.at < maxAgeMs) return Promise.resolve(r.value);
  if (r.inflight) return r.inflight;
  const inflight = api(path).then((value) => { reads.set(key, { at: Date.now(), value }); return value; })
    .finally(() => { const now = reads.get(key); if (now && now.inflight === inflight) delete now.inflight; });
  reads.set(key, { ...r, inflight });
  return inflight;
}

/// The workspaces and the loose agents: {workspaces: [...], loose: [...], hidden}.
export async function loadWorkspaces(maxAgeMs = 1000) {
  state.workspaces = await cached('workspaces', 'workspaces', maxAgeMs);
  return state.workspaces;
}
/// One workspace (its rooms and agents) — kept in state.wsDetails for the sidebar's tree.
export async function loadWorkspace(name, maxAgeMs = 1000) {
  const d = await cached('ws:' + name, 'workspaces/' + encodeURIComponent(name), maxAgeMs);
  state.wsDetails.set(name, d);
  return d;
}
export async function loadLoose(maxAgeMs = 1000) { return cached('loose', 'loose', maxAgeMs); }
export async function loadBots(maxAgeMs = 1000) {
  state.bots = await cached('bots', 'bots', maxAgeMs);
  return state.bots;
}
/// A workspace gone from the list: forget its details.
export function forgetWorkspaces(names) {
  for (const n of [...state.wsDetails.keys()]) if (!names.includes(n)) { state.wsDetails.delete(n); reads.delete('ws:' + n); }
}

/// The order Home and the sidebar list workspaces in: waiting on you, working, starting, idle, setting up, asleep; then
/// finished and archived (folded below the rest).
export const STATE_ORDER = ['waiting-on-you', 'working', 'starting', 'idle', 'setting-up', 'asleep', 'finished', 'archived'];
export function byState(list) {
  const at = (s) => { const i = STATE_ORDER.indexOf(s); return i < 0 ? STATE_ORDER.length : i; };
  return list.slice().sort((a, b) => at(a.state) - at(b.state) || a.name.localeCompare(b.name));
}
export const isDone = (w) => w.state === 'finished' || w.state === 'archived';
