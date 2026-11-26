// views/wsn-state — The New workspace wizard's state (782): the choices (`state.wsn`), kept in this tab's session storage
// (`doz.wsnew`) only for a reload of the wizard's own address and the browser's Back and Forward — every entry starts fresh
// (views/new-workspace.js openNewWorkspace) —, the templates' list, and the plan: asked on every change (debounced, the
// latest wins; `POST /api/v1/workspace-plan`, a look — nothing written, no daemon started), whose answer carries the next
// free name, each bot's fitness as the manager and the findings in the wizard's words.
import { api } from '../core/api-496fd9f39af2a514.js';
import { isRemote } from '../core/session-ac3b294ded6521bf.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { requestFrom } from '../core/ws-new-078b8d9bbef0201f.js';

const KEY = 'doz.wsnew';
const PLAN_WAIT_MS = 300;
/// What is kept (and restored) — the choices, never what was read.
const KEPT = ['screen', 'template', 'step', 'name', 'nameTouched', 'newFolder', 'folder', 'description', 'descOpen', 'manager', 'newBot',
  'workerIsolation', 'network', 'netPicked', 'room', 'invite', 'start', 'actsAsYou'];

export function fresh() {
  return { screen: 'gallery', template: null, step: 0, name: '', nameTouched: false, newFolder: true, folder: null, description: '', descOpen: false,
    manager: null, managerPicked: false, newBot: null, botForm: null, workerIsolation: 'fenced', network: 'locked', netPicked: false,
    room: { mode: 'new', name: '' }, invite: [], start: true, actsAsYou: false, chatStarting: false, plan: null, planError: '', error: '', busy: false, rooms: null };
}
export function save() {
  const w = state.wsn;
  if (!w) return;
  const kept = {};
  for (const k of KEPT) kept[k] = w[k];
  try { sessionStorage.setItem(KEY, JSON.stringify(kept)); } catch (_) { /* no storage here: this page keeps them */ }
}
export function restore() {
  try {
    const v = JSON.parse(sessionStorage.getItem(KEY) || 'null');
    if (!v || typeof v !== 'object') return null;
    const w = fresh();
    for (const k of KEPT) if (k in v && (v[k] === null || typeof v[k] === typeof w[k] || w[k] === null)) w[k] = v[k];
    w.step = Math.max(0, Math.min(4, +w.step || 0));
    if (!['gallery', 'template', 'custom'].includes(w.screen)) w.screen = 'gallery';
    if (!w.room || typeof w.room !== 'object') w.room = { mode: 'new', name: '' };
    if (!Array.isArray(w.invite)) w.invite = [];
    return w;
  } catch (_) { return null; }
}
/// Forget the choices (made, closed with ✕, or a new entry).
export function forgetNewWorkspace() {
  state.wsn = null;
  try { sessionStorage.removeItem(KEY); } catch (_) { /* nothing kept */ }
}
/// Whether the person has chosen anything a close would lose.
export function newWorkspaceDirty() {
  const w = state.wsn;
  return !!w && !w.busy && w.screen !== 'gallery' && (w.nameTouched || !!w.description.trim() || !!w.manager || !!w.newBot || w.step > 0);
}

/// Why this browser may not make or start a workspace (null: it may).
export const WSN_REMOTE = 'A workspace is made only in this Mac’s own browser, or with doz workspace new in a terminal on the Mac';
export function newWorkspaceRefusal() { return isRemote() ? WSN_REMOTE : null; }

export const bots = () => ((state.bots && state.bots.bots) || []).filter((b) => !b.retiredAt);
export const botOf = (n) => bots().find((b) => b.name === n) || null;
export const chatOn = () => !!(state.chat && state.chat.on);
/// Where the chosen manager runs (a new bot's own choice; else its bot's), or null.
export function managerWhere(w) {
  if (w.newBot && w.manager === w.newBot.name) return w.newBot.isolation;
  const b = w.manager ? botOf(w.manager) : null;
  return b ? b.isolation : null;
}

// ── the templates (read once per wizard)
let templates = null;
export async function loadTemplates() {
  if (!templates) templates = api('templates').catch((e) => { templates = null; throw e; });
  return templates;
}

// ── drawing again (views/new-workspace.js registers how)
let drawer = () => {};
export function onRender(fn) { drawer = fn; }
/// Draw the wizard again (`focus`: the step's first field).
export function render(focus) { drawer(focus); }
/// A choice changed: kept, the plan asked again, drawn again when `redraw`.
export function changed(redraw) {
  save();
  askPlan(false);
  if (redraw) render(false);
}

// ── the plan
let painter = () => {};
/// What repaints after a plan answer (views/new-workspace.js).
export function onPlan(fn) { painter = fn; }
let timer = null, reader = null;
/// The request the plan is asked for: Custom's, or (a template's screen) the name and folder alone.
export function planBody(w) {
  if (w.screen === 'custom') {
    const nb = w.newBot && w.manager === w.newBot.name;
    return requestFrom({ ...w, manager: nb ? null : w.manager, managerIsolation: nb ? null : managerWhere(w),
      fromProject: projectPreset(w) && !w.netPicked ? true : false });
  }
  const r = { workspace: w.name || '' };
  if (w.folder && w.folder.path) r.folders = [{ path: w.folder.path, mode: 'rw' }]; else r.newFolder = true;
  return r;
}
/// The main folder's doz_project.yaml preset, as the last plan read it (null: none).
export function projectPreset(w) {
  const p = w.plan && w.plan.project;
  return p && p.readable && p.preset ? p.preset : null;
}
export function askPlan(now) {
  clearTimeout(timer);
  timer = setTimeout(readPlan, now ? 0 : PLAN_WAIT_MS);
}
async function readPlan() {
  const w = state.wsn;
  if (!w || newWorkspaceRefusal() || w.screen === 'gallery') return;
  if (reader) reader.abort();
  const mine = new AbortController();
  reader = mine;
  try {
    const p = await api('workspace-plan', { method: 'POST', json: planBody(w), signal: mine.signal });
    if (reader !== mine || state.wsn !== w) return;
    w.plan = p;
    w.planError = '';
    // The first answer fills in the name: the next free workspaceN.
    if (!w.nameTouched && !w.name && p.suggested) { w.name = p.suggested.name; save(); askPlan(true); }
    // The project's preset is preselected (with its chip) until the person picks another.
    if (!w.netPicked && projectPreset(w) && w.network !== projectPreset(w)) { w.network = projectPreset(w); save(); }
  } catch (e) {
    if (e.name === 'AbortError' || reader !== mine) return;
    w.planError = e.message || String(e);
  } finally {
    if (reader === mine) reader = null;
  }
  painter();
}
