// views/new-workspace — The New workspace wizard (#/new-workspace[?bot=NAME]): a modal over the page under it, like New
// sandbox (#/new). Four steps, the mockups' S04–S07: 1 the work (the prompt → the brief, its references, the name, any
// folders, the main folder's doz_project.yaml used to fill in choices, a built-in to start from), 2 who manages (an Agent /
// Bot from the roster, a new one through its editor, or you), 3 where it runs (the manager's isolation — unfenced only when
// named and confirmed: it acts as you —, new workers' default, the network preset), 4 grants & when (the honest line, the
// room, when it starts, the plan with its gaps and the commands). Nothing here changes anything but the two actions at the
// end, each exactly one HostOp the CLI also sends: `workspace-new` (Create, keep setting up) and then `workspace-start`
// (Create and start). Every change asks the plan route (`POST /api/v1/workspace-plan`, debounced, the latest wins), a
// look: nothing written, no daemon started. Only this Mac's own browser makes or starts a workspace; another computer
// sees the command. The choices are kept in this tab's session storage (`doz.wsnew`), so a trip to the Agent / Bot editor
// and back keeps them.
import { h, markChildren } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { api } from '../core/api-47cfabfed13b475c.js';
import { actOrThrow, waitForOp } from '../core/operations-7b4c8e49fe46d1d8.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { botHash, workspaceHash } from '../core/routes-c03e6aed84ec9eb3.js';
import { isRemote } from '../core/session-d2120671b8ea9d60.js';
import { setting } from '../core/settings-b574facd5b73891b.js';
import { state } from '../core/state-1036883eb74b9520.js';
import { utf8 } from '../core/util-0745432f65992dcb.js';
import { loadBots, loadWorkspaces } from '../core/workspaces-5230dd4ac3dbaa71.js';
import { WORKSPACE_DEFINITION, WORKSPACE_NAME, WSN_STEPS, gapStep, requestFrom, slugFrom } from '../core/ws-new-02275ee0f50e659e.js';
import { chatRooms } from '../components/bot-invite-0409f2fe8e1b4bc2.js';
import { btn } from '../components/button-030d384b64f8d75d.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { choiceCard } from '../components/choice-fdde57632eb1dcb5.js';
import { cmdLine } from '../components/cmd-line-c02dc337399eeaea.js';
import { dialog } from '../components/dialog-6c4b0145eb6f40c0.js';
import { wizHead, wizMount } from '../components/modal-903b3bf0592d5d0f.js';
import { addNote } from '../components/notes-69d2f6b952196f79.js';
import { pageFailure, toast } from '../components/notices-6181dc77834224ab.js';
import { stepperNode } from '../components/stepper-9f1fb5c64eac92d6.js';
import { BRIEF_MAX_BYTES } from '../components/ws-brief-5f8b2338dc17dd0c.js';
import { gapsPanel, startsOnce } from '../components/ws-gaps-f1793c0092ac7724.js';
import { chatOnForm } from '../components/chat-on-374e5679ed08c0c9.js';
import { chatNavCheck } from './chat-f5455ff994a36ba6.js';

/// Why this browser may not make or start a workspace (null: it may).
export const WSN_REMOTE = 'A workspace is made only in this Mac’s own browser, or with doz workspace new … in a terminal on the Mac';
export function newWorkspaceRefusal() { return isRemote() ? WSN_REMOTE : null; }

const KEY = 'doz.wsnew';
const BODY_MAX_BYTES = 16 * 1024 - 64;
const PLAN_WAIT_MS = 400;
const ISO_WORDS = { fenced: 'fenced on this Mac', vm: 'micro VM', unfenced: 'unfenced on this Mac', elsewhere: 'elsewhere' };
const CONTROL = { fenced: 'proxy · placeholders · guard', vm: 'micro VM · proxy · placeholders', unfenced: 'no proxy · no placeholders · no guard · acts as you' };
const NETWORKS = [
  ['locked', 'Locked', 'its AI model only, and the room'],
  ['standard', 'Standard', 'its model, GitHub, package registries, error reports, and the room'],
  ['open', 'Open', 'any site, every connection logged'],
];
const DELIVER_WORDS = { poll: 'polls with dozchat', inbox: 'its inbox (a session on this Mac)', webhook: 'a webhook' };
/// The choices kept (and restored) — everything but what was read.
const KEPT = ['step', 'name', 'nameTouched', 'brief', 'refs', 'folders', 'newFolder', 'fromProject', 'projectAsked', 'preset', 'manager',
  'managerIsolation', 'unfencedConfirmed', 'workerIsolation', 'network', 'sites', 'roomChoice', 'when'];

function fresh() {
  return { step: 0, name: '', nameTouched: false, brief: '', refs: [], folders: [], newFolder: false, fromProject: false, projectAsked: false,
           preset: 'blank', manager: null, managerIsolation: 'fenced', unfencedConfirmed: false, workerIsolation: 'fenced', network: 'locked', sites: [],
           roomChoice: 'make', when: 'now', plan: null, planError: '', error: '', busy: '', refTyped: '', folderTyped: '' };
}
function save() {
  const w = state.wsn;
  if (!w) return;
  const kept = {};
  for (const k of KEPT) kept[k] = w[k];
  try { sessionStorage.setItem(KEY, JSON.stringify(kept)); } catch (_) { /* no storage here: this page keeps them */ }
}
function restore() {
  try {
    const v = JSON.parse(sessionStorage.getItem(KEY) || 'null');
    if (!v || typeof v !== 'object') return null;
    const w = fresh();
    for (const k of KEPT) {
      if (k === 'manager') { if (v[k] === null || typeof v[k] === 'string') w[k] = v[k]; } else if (k in v && typeof v[k] === typeof w[k]) w[k] = v[k];
    }
    w.refs = Array.isArray(v.refs) ? v.refs.filter((x) => typeof x === 'string').slice(0, 16) : [];
    w.folders = Array.isArray(v.folders) ? v.folders.filter((f) => f && typeof f.path === 'string').map((f) => ({ path: f.path, mode: f.mode === 'ro' ? 'ro' : 'rw' })).slice(0, 8) : [];
    w.step = Math.max(0, Math.min(3, +w.step || 0));
    return w;
  } catch (_) { return null; }
}
/// Forget the choices (made, or closed with ✕).
export function forgetNewWorkspace() {
  state.wsn = null;
  try { sessionStorage.removeItem(KEY); } catch (_) { /* nothing kept */ }
}
/// Whether the person has chosen anything a close would lose.
export function newWorkspaceDirty() {
  const w = state.wsn;
  return !!w && !w.busy && (w.step > 0 || !!w.brief.trim() || w.refs.length > 0 || w.folders.length > 0 || !!w.manager || w.newFolder);
}

const choices = () => state.wsn;
const req = () => requestFrom({ ...choices(), ...roomFields() });
const bots = () => ((state.bots && state.bots.bots) || []).filter((b) => !b.retiredAt);
const botOf = (n) => bots().find((b) => b.name === n) || null;
const chatOn = () => !!(state.chat && state.chat.on);
const mainName = () => (state.wsn.name || 'NAME');

// ── the plan: asked on every change (debounced), the latest answer wins ──────────────────────────────────────────────
let planTimer = null, planReader = null;
function askPlan(now) {
  clearTimeout(planTimer);
  planTimer = setTimeout(readPlan, now ? 0 : PLAN_WAIT_MS);
}
async function readPlan() {
  const w = state.wsn;
  if (!w || newWorkspaceRefusal()) return;
  if (planReader) planReader.abort();
  const reader = new AbortController();
  planReader = reader;
  try {
    const p = await api('workspace-plan', { method: 'POST', json: req(), signal: reader.signal });
    if (planReader !== reader || state.wsn !== w) return;
    w.plan = p;
    w.planError = '';
    // The main folder's project file fills in choices unless the person said no.
    if (p.project && p.project.readable && !w.projectAsked && !w.fromProject) { w.fromProject = true; save(); askPlan(true); }
    if (!p.project && w.fromProject) { w.fromProject = false; save(); askPlan(true); }
  } catch (e) {
    if (e.name === 'AbortError' || planReader !== reader) return;
    w.planError = e.message || String(e);
  } finally {
    if (planReader === reader) planReader = null;
  }
  paintPlan();
}

/// The plan's gaps, each with its step (0-based), and how many each step has.
function gaps() { return ((state.wsn.plan && state.wsn.plan.gaps) || []).map((g) => ({ ...g, step: g.step || gapStep(g.item) + 1 })); }
function refusals() {
  const p = state.wsn.plan;
  if (!p) return [];
  // An empty brief is said once: as the brief's gap.
  return p.refusals.filter((r) => !(r === 'the brief is empty' && gaps().some((g) => g.item === 'brief')));
}
function stepCount(i) { return gaps().filter((g) => g.step - 1 === i).length + (i === 0 ? refusals().length : 0); }
/// The bot already runs in another live workspace (for now a bot runs in one at a time): the sentence, else null.
function liveElsewhere() {
  const w = state.wsn, b = w.manager ? botOf(w.manager) : null;
  if (!b) return null;
  const other = b.running && b.running !== w.name ? b.running : b.worksIn && b.worksIn !== w.name ? b.worksIn : null;
  if (!other) return null;
  return b.running === other
    ? b.name + ' already manages ' + other + ', which is running. For now a bot runs in one live workspace at a time — doz workspace stop ' + other + ' first.'
    : b.name + ' already works in ' + other + ', which is running. For now a bot runs in one live workspace at a time — doz worker end ' + other + ' ' + b.name + ' first.';
}
function tooBig() {
  const body = utf8.encode(JSON.stringify({ action: 'workspace-new', ...req() })).length;
  return utf8.encode(state.wsn.brief).length > BRIEF_MAX_BYTES || body > BODY_MAX_BYTES;
}
function nameProblem() {
  const v = state.wsn.name;
  if (!v) return 'Give it a name';
  if (!WORKSPACE_NAME.test(v)) return '1–40 characters of a-z, 0-9 and -, not starting with -';
  const l = state.workspaces;
  if (l && l.workspaces.some((x) => x.name === v)) return 'There is already a workspace ' + v;
  return null;
}

// ── the view ─────────────────────────────────────────────────────────────────────────────────────────────────────────
export async function viewNewWorkspace() {
  const remote = newWorkspaceRefusal();
  if (remote) {
    return h('div', { class: 'wizard wsn', 'data-wsn': 'remote' }, wizHead('New workspace', null, [], null),
      h('div', { class: 'wiz-card' }, markChildren(h('div', { class: 'w-body' },
        callout('info', { cls: 'notice', icon: 'lock', attrs: { 'data-wsn-remote': '' }, title: 'Only on this Mac', body: WSN_REMOTE + '.' }),
        h('p', { class: 'sub' }, WORKSPACE_DEFINITION),
        cmdLine('doz workspace new NAME --prompt-file BRIEF.md')), 'w-item')));
  }
  if (!state.wsn) state.wsn = restore() || fresh();
  const w = state.wsn;
  if (state.wsnBot) {
    w.manager = state.wsnBot;
    state.wsnBot = null;
  }
  try { await Promise.all([loadBots(0), loadWorkspaces(0)]); } catch (_) { /* said where they are used */ }
  if (w.manager) {
    const b = botOf(w.manager);
    if (!b || b.isolation === 'elsewhere') w.manager = null;
    else if (!w.unfencedConfirmed && w.managerIsolation === 'unfenced') w.managerIsolation = 'fenced';
  }
  w.rooms = null;
  chatRooms().then((s) => {
    if (!s || state.wsn !== w) return;
    const owned = new Set(((state.workspaces && state.workspaces.workspaces) || []).map((x) => x.room).filter(Boolean));
    const archived = new Set(s.archived || []);
    w.rooms = Object.keys(s.rooms || {}).filter((r) => !owned.has(r) && !archived.has(r)).sort();
    if (w.step === 3) render(false);
  });
  save();
  askPlan(true);
  return node();
}

function render(focus) {
  if (state.modal !== 'new-workspace' || !state.wsn) return;
  wizMount(node(), focus);
}
function go(i) {
  const w = state.wsn;
  w.step = Math.max(0, Math.min(3, i));
  w.error = '';
  save();
  render(true);
}
function changed(redraw) {
  save();
  askPlan(false);
  if (redraw) render(false);
}

function stepper() {
  const w = state.wsn;
  return stepperNode(WSN_STEPS, w.step, { data: 'data-wsn-step', href: '#/new-workspace', count: (i) => stepCount(i),
    go: (i) => (i !== w.step ? () => go(i) : null) });
}

function node() {
  const w = state.wsn;
  const id = WSN_STEPS[w.step].id;
  const body = { work: stepWork, manager: stepManager, where: stepWhere, when: stepWhen }[id]();
  const error = h('div', { class: 'dlg-error', role: 'alert', 'data-wsn-error': '' }, w.error || '');
  const back = w.step > 0 ? btn('Back', () => go(w.step - 1), { icon: 'arrow-left' }) : null;
  const foot = w.step < 3
    ? [back, h('span', { class: 'wiz-gap' }), h('button', { type: 'submit', class: 'btn lg primary', 'data-wsn-next': '' }, h('span', { class: 'btn-label' }, 'Next: ' + WSN_STEPS[w.step + 1].title.toLowerCase()), icon('arrow-right'))]
    : [back, h('span', { class: 'wiz-gap' }), ...createButtons()];
  const form = h('form', { class: 'wiz-card', 'data-wsn-body': id, novalidate: '' },
    markChildren(h('div', { class: 'w-body' }, ...body, error), 'w-item'),
    h('div', { class: 'w-foot wiz-buttons', 'data-wsn-foot': '' }, ...foot));
  form.addEventListener('submit', (ev) => { ev.preventDefault(); if (w.step < 3) go(w.step + 1); });
  form.addEventListener('keydown', (ev) => {
    if (ev.altKey && ev.key === 'ArrowLeft' && w.step > 0) { ev.preventDefault(); go(w.step - 1); }
    if (ev.altKey && ev.key === 'ArrowRight' && w.step < 3) { ev.preventDefault(); go(w.step + 1); }
  });
  return h('div', { class: 'wizard wsn', 'data-wsn': id },
    wizHead('New workspace', 'The work first, then who manages it, where it runs and when it starts. The same as doz workspace new in a terminal.', [], stepper()),
    form);
}

/// Repaint what the plan's answer decides, in place (a field being typed in keeps its focus).
function paintPlan() {
  const box = document.getElementById('wm-box');
  if (!box || state.modal !== 'new-workspace' || !state.wsn) return;
  const s = box.querySelector('.wm-steps');
  if (s) { const st = stepper(); s.replaceChildren(st.compact, st.list); }
  for (const el of box.querySelectorAll('[data-wsn-slot]')) {
    const fill = SLOTS[el.dataset.wsnSlot];
    if (fill) el.replaceChildren(...[].concat(fill()).filter(Boolean));
  }
  const foot = box.querySelector('[data-wsn-foot]');
  if (foot && state.wsn.step === 3) {
    const back = btn('Back', () => go(2), { icon: 'arrow-left' });
    foot.replaceChildren(back, h('span', { class: 'wiz-gap' }), ...createButtons());
  }
}
const slot = (name) => h('div', { class: 'wsn-slot', 'data-wsn-slot': name }, ...[].concat(SLOTS[name]()).filter(Boolean));
const SLOTS = {
  name: () => {
    const p = nameProblem() || (state.wsn.plan && state.wsn.plan.refusals.find((r) => /workspace|room/.test(r) && r.includes(state.wsn.name)) || null);
    return h('small', { class: 'wsn-check' + (p ? ' is-bad' : ''), role: 'status', 'data-wsn-name-check': '' },
      p || (state.wsn.nameTouched ? 'Free' : 'Suggested from the prompt — change it if you like'));
  },
  project: () => {
    const p = state.wsn.plan && state.wsn.plan.project;
    if (!p) return null;
    const box = h('input', { type: 'checkbox', 'data-wsn-from-project': '' });
    box.checked = !!state.wsn.fromProject;
    box.disabled = !p.readable;
    box.addEventListener('change', () => { state.wsn.fromProject = box.checked; state.wsn.projectAsked = true; changed(false); });
    const what = !p.readable ? 'Found ' + p.file + ' in ' + p.folder + ', but it cannot be read — fix it there, or leave it out.'
      : p.preset ? 'Found ' + p.file + ' in ' + p.folder + ': its network preset (' + p.preset + ') is filled in for you.'
        : 'Found ' + p.file + ' in ' + p.folder + ': it names no network preset.';
    return callout('info', { compact: true, cls: 'wsn-project', icon: 'layout-template', attrs: { 'data-wsn-project': p.file },
      body: [what, ' ', h('label', { class: 'wsn-inline-check' }, box, ' Use it to fill in choices (it is never written)')] });
  },
  refusals: () => {
    const r = refusals();
    const live = liveElsewhere();
    const out = [];
    if (state.wsn.planError) out.push(callout('bad', { compact: true, attrs: { 'data-wsn-plan-error': '' }, body: state.wsn.planError }));
    if (r.length) out.push(callout('bad', { compact: true, title: 'It cannot be made yet', attrs: { 'data-wsn-refusals': String(r.length) },
      body: h('ul', { class: 'hm-gaps' }, ...r.map((x) => h('li', null, x))) }));
    if (live && state.wsn.step >= 1) out.push(callout('warn', { compact: true, attrs: { 'data-wsn-live': '' }, body: live }));
    return out;
  },
  gaps: () => gapsPanel(gaps(), { goStep: (i) => go(i), readyText: 'Fully set up — it can start', startWords: 'what the start would refuse now',
    onChatOn: chatCameOn }),
  lines: () => {
    const p = state.wsn.plan;
    return p ? h('ul', { class: 'wsn-lines', 'data-wsn-lines': '' }, ...p.lines.map((l) => h('li', { class: /acts as you/.test(l) ? 'is-acts' : null }, tildePath(l),
      /acts as you/.test(l) ? h('span', { class: 'ws-chip acts-as-you' }, icon('triangle-alert'), 'acts as you') : null))) : h('p', { class: 'muted' }, 'Reading the plan…');
  },
  commands: () => {
    const text = commandsText();
    if (!text) return null;
    const copy = btn('Copy as doz commands', async () => {
      try { await navigator.clipboard.writeText(text); toast('Copied — paste it in a terminal on this Mac'); } catch (_) { pageFailure('This browser could not copy — select the commands below'); }
    }, { small: true, icon: 'copy' });
    copy.dataset.wsnCopy = '';
    return h('div', { class: 'wsn-commands' }, copy, h('pre', { class: 'wsn-cmd-text', 'data-wsn-commands': '' }, text));
  },
};
function commandsText() {
  const p = state.wsn.plan;
  if (!p) return '';
  // Chat turned on in the wizard: the copy turns it on too (harmless where it is on already), so it works in a fresh terminal.
  const on = state.wsn.chatTurnedOn ? 'doz chat on' + (state.wsn.chatOnName ? ' --name ' + state.wsn.chatOnName : '') + '\n' : '';
  return on + p.commands + (state.wsn.when === 'now' ? p.startCommand + '\n' : '');
}

/// Chat came on from the wizard: what was typed is kept; the sidebar's entry, the rooms and the plan are read again.
async function chatCameOn(name) {
  const w = state.wsn;
  if (!w) return;
  w.chatTurnedOn = true;
  w.chatOnName = name || null;
  await chatNavCheck();
  const s = await chatRooms();
  if (state.wsn !== w) return;
  if (s) {
    const owned = new Set(((state.workspaces && state.workspaces.workspaces) || []).map((x) => x.room).filter(Boolean));
    const archived = new Set(s.archived || []);
    w.rooms = Object.keys(s.rooms || {}).filter((r) => !owned.has(r) && !archived.has(r)).sort();
  }
  changed(true);
}

function createButtons() {
  const w = state.wsn;
  const g = gaps(), r = refusals(), live = liveElsewhere(), big = tooBig();
  const cannot = !w.plan || r.length > 0 || !!w.planError || big || !!w.busy;
  const keep = h('button', { type: 'button', class: 'btn lg' + (w.when === 'later' ? ' primary' : ''), 'data-wsn-create': 'later', disabled: cannot ? true : null,
    title: big ? 'Too long for this page — copy the commands' : r[0] || null, on: { click: () => create(false) } },
    w.busy === 'later' ? icon('hourglass') : icon('folder-plus'), 'Create, keep setting up');
  const why = g.length ? startsOnce(g) : live || '';
  const start = h('button', { type: 'button', class: 'btn lg' + (w.when === 'now' ? ' primary' : ''), 'data-wsn-create': 'now',
    disabled: cannot || g.length || live ? true : null, title: why || (big ? 'Too long for this page — copy the commands' : r[0] || null), on: { click: () => create(true) } },
    w.busy === 'now' ? icon('hourglass') : icon('play'), 'Create and start');
  return [keep, start];
}

// ── 1 · the work ─────────────────────────────────────────────────────────────────────────────────────────────────────
function stepWork() {
  const w = state.wsn;
  const brief = h('textarea', { name: 'brief', rows: 6, spellcheck: 'true', 'data-wsn-brief': '',
    placeholder: 'What is the work? Say what it is for, what done looks like, and anything the agents should know.' });
  brief.value = w.brief;
  const size = h('small', { class: 'wsn-size', 'data-wsn-brief-size': '' });
  const sizeText = () => {
    const n = utf8.encode(w.brief).length;
    size.textContent = n > BRIEF_MAX_BYTES ? 'Too long for this page (' + Math.ceil(n / 1024) + ' KiB) — copy the commands on the last step: the CLI takes up to 256 KiB.'
      : 'The prompt and its references become the work’s brief, pinned above its room; the manager gets it as its first message.';
    size.classList.toggle('is-bad', n > BRIEF_MAX_BYTES);
  };
  sizeText();
  const nameInput = h('input', { type: 'text', name: 'workspace', autocomplete: 'off', spellcheck: 'false', 'data-wsn-name': '', maxlength: 40 });
  nameInput.value = w.name;
  brief.addEventListener('input', () => {
    w.brief = brief.value;
    sizeText();
    if (!w.nameTouched) { w.name = slugFrom(w.brief); nameInput.value = w.name; }
    changed(false);
  });
  nameInput.addEventListener('input', () => { w.name = nameInput.value.trim(); w.nameTouched = true; changed(false); });

  return [
    h('h2', null, 'What is the work?'),
    h('label', { class: 'field wsn-brief' }, h('span', null, 'The prompt'), brief, size),
    refsField(),
    h('label', { class: 'field wsn-name' }, h('span', null, 'Name'), nameInput, slot('name')),
    foldersField(),
    slot('project'),
    presetsField(),
    slot('refusals'),
  ];
}

function refsField() {
  const w = state.wsn;
  const input = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', 'data-wsn-ref-input': '', placeholder: '~/notes/storyboard.pdf or https://…' });
  input.value = w.refTyped;
  const add = () => {
    const v = input.value.trim();
    if (!v) return;
    if (!/^(https?:\/\/|\/|~\/)/.test(v)) { pageFailure('A reference is a path (/… or ~/…) or an http(s) address'); return; }
    if (w.refs.length >= 16) { pageFailure('At most 16 references from this page'); return; }
    if (!w.refs.includes(v)) w.refs.push(v);
    w.refTyped = '';
    changed(true);
  };
  input.addEventListener('input', () => { w.refTyped = input.value; });
  input.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); add(); } });
  const chips = w.refs.map((r, i) => h('span', { class: 'wsn-chip', 'data-wsn-ref': r }, icon(/^https?:/.test(r) ? 'link' : 'file'), tildePath(r),
    h('button', { type: 'button', class: 'wsn-chip-x', 'aria-label': 'Remove ' + r, title: 'Remove', on: { click: () => { w.refs.splice(i, 1); changed(true); } } }, icon('x'))));
  const choose = btn('Choose…', async () => {
    try {
      const r = await api('folder/choose', { method: 'POST', json: {} });
      if (r.cancelled || !r.path) return;
      if (!w.refs.includes(r.path)) w.refs.push(r.path);
      changed(true);
    } catch (e) { pageFailure(e.message || String(e)); }
  }, { small: true, icon: 'folder-open', title: 'This Mac’s folder picker' });
  return h('div', { class: 'field wsn-refs' }, h('span', null, 'References'),
    chips.length ? h('div', { class: 'wsn-chips' }, ...chips) : null,
    h('div', { class: 'wsn-add' }, input, btn('Add', add, { small: true, icon: 'plus' }), choose),
    h('small', null, 'Files, folders or links the brief points to — each is checked on this Mac.'));
}

function foldersField() {
  const w = state.wsn;
  const ro = presetOf(w.preset) && presetOf(w.preset).foldersReadOnly;
  const rows = w.folders.map((f, i) => {
    const mode = h('select', { 'data-wsn-folder-mode': f.path, 'aria-label': 'Its mode' }, h('option', { value: 'rw' }, 'read-write'), h('option', { value: 'ro' }, 'read-only'));
    mode.value = f.mode;
    mode.addEventListener('change', () => { f.mode = mode.value; changed(false); });
    const main = i === 0 && !w.newFolder;
    return h('div', { class: 'wsn-folder', 'data-wsn-folder': f.path }, icon('folder'), h('span', { class: 'wsn-path' }, tildePath(f.path)), mode,
      main ? h('span', { class: 'ws-chip' }, 'main folder') : null,
      h('button', { type: 'button', class: 'btn sm quiet icon-only', 'aria-label': 'Remove ' + f.path, title: 'Remove', on: { click: () => { w.folders.splice(i, 1); changed(true); } } }, icon('x')));
  });
  const input = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', 'data-wsn-folder-input': '', placeholder: '~/code/my-app — add :ro for read-only' });
  input.value = w.folderTyped;
  const add = () => {
    let v = input.value.trim(), mode = ro ? 'ro' : 'rw';
    if (!v) return;
    const m = /^(.*):(ro|rw)$/.exec(v);
    if (m) { v = m[1]; mode = m[2]; }
    if (!/^(\/|~\/)/.test(v)) { pageFailure('A folder is an absolute path (/… or ~/…)'); return; }
    if (w.folders.length >= 8) { pageFailure('At most 8 folders from this page'); return; }
    if (!w.folders.some((f) => f.path === v)) w.folders.push({ path: v, mode });
    w.folderTyped = '';
    changed(true);
  };
  input.addEventListener('input', () => { w.folderTyped = input.value; });
  input.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); add(); } });
  const choose = btn('Add a folder (Choose…)', async () => {
    try {
      const r = await api('folder/choose', { method: 'POST', json: {} });
      if (r.cancelled || !r.path) return;
      if (!w.folders.some((f) => f.path === r.path)) w.folders.push({ path: r.path, mode: ro ? 'ro' : 'rw' });
      changed(true);
    } catch (e) { pageFailure(e.message || String(e)); }
  }, { small: true, icon: 'folder-open', title: 'This Mac’s folder picker' });
  const nf = h('input', { type: 'checkbox', 'data-wsn-new-folder': '' });
  nf.checked = !!w.newFolder;
  nf.addEventListener('change', () => { w.newFolder = nf.checked; changed(true); });
  const where = tildePath(projectsDir() + '/' + mainName());
  const none = !w.folders.length && !w.newFolder
    ? h('p', { class: 'muted wsn-none', 'data-wsn-no-folders': '' }, 'No folders — that is fine. The manager works in ' + where + '.') : null;
  return h('div', { class: 'field wsn-folders' }, h('span', null, 'Folders'),
    w.newFolder ? h('div', { class: 'wsn-folder is-new', 'data-wsn-folder': 'new' }, icon('folder-plus'), h('span', { class: 'wsn-path' }, where + ' (made empty)'),
      h('span', { class: 'ws-chip' }, 'main folder')) : null,
    ...rows, none,
    h('div', { class: 'wsn-add' }, input, btn('Add', add, { small: true, icon: 'plus' }), choose),
    h('label', { class: 'wsn-inline-check' }, nf, ' A new empty folder ', h('code', null, where)),
    h('small', null, 'Optional. The first is the main folder; read-only folders are only read. A workspace may work on several, or none.'));
}
function projectsDir() { return setting('defaults.projects_dir', '~/doz-workspaces'); }

function presetOf(id) { const p = state.wsn.plan; return ((p && p.presets) || []).find((x) => x.id === id) || null; }
function presetsField() {
  const w = state.wsn;
  const list = (w.plan && w.plan.presets) || [];
  const cards = list.map((p) => {
    const input = h('input', { type: 'radio', name: 'wsn-preset', value: p.id, 'data-wsn-preset': p.id });
    input.checked = w.preset === p.id;
    input.addEventListener('change', () => { if (input.checked) applyPreset(p); });
    return choiceCard({ class: 'wiz-choice wsn-preset' }, input, h('span', { class: 'wsn-cc' }, h('span', { class: 'wsn-cc-title' }, p.title), h('span', { class: 'wsn-cc-desc' }, p.summary)));
  });
  return h('fieldset', { class: 'wiz-choices wsn-presets' }, h('legend', null, 'Start from'),
    h('div', { class: 'wsn-preset-grid' }, ...cards),
    h('small', { class: 'muted' }, 'Built in: each fills in today’s choices — change any of them later. Templates you make come later.'));
}
function applyPreset(p) {
  const w = state.wsn;
  w.preset = p.id;
  if (p.workerIsolation) w.workerIsolation = p.workerIsolation;
  if (p.network && !w.fromProject) w.network = p.network;
  w.sites = (p.sites || []).slice();     // a preset's sites (remotion-video: remotion.media); another preset's go
  if (p.managerIsolation && w.manager && p.managerIsolation !== 'unfenced') { w.managerIsolation = p.managerIsolation; w.unfencedConfirmed = false; }
  if (p.foldersReadOnly) for (const f of w.folders) f.mode = 'ro';
  changed(true);
}

// ── 2 · who manages ──────────────────────────────────────────────────────────────────────────────────────────────────
function stepManager() {
  const w = state.wsn;
  const roster = bots().map((b) => {
    const elsewhere = b.isolation === 'elsewhere';
    const input = h('input', { type: 'radio', name: 'wsn-manager', value: b.name, 'data-wsn-bot': b.name, disabled: elsewhere ? true : null });
    input.checked = w.manager === b.name;
    input.addEventListener('change', () => { if (input.checked) pickManager(b); });
    const runs = b.running ? 'manages ' + b.running + ' (running)' : b.manages.length ? 'manages ' + b.manages.join(', ') : b.worksIn ? 'works in ' + b.worksIn : null;
    return choiceCard({ class: 'wiz-choice wsn-bot', title: elsewhere ? 'A bot elsewhere runs on its own machine; Dozable never starts it' : null },
      input, h('span', { class: 'wsn-cc wsn-bot-row' }, h('span', { class: 'bot-avatar', 'aria-hidden': 'true' }, [...(b.avatar || b.name.charAt(0).toUpperCase())].slice(0, 2).join('')),
        h('span', { class: 'wsn-cc' }, h('span', { class: 'wsn-cc-title' }, b.name),
          h('span', { class: 'wsn-cc-desc' }, [agentWords(b.agent) + (b.model ? ' · ' + b.model : ''), ISO_WORDS[b.isolation] || b.isolation, runs].filter(Boolean).join(' · ')),
          elsewhere ? h('span', { class: 'wsn-cc-desc' }, 'a bot elsewhere runs on its own machine; Dozable never starts it') : null)));
  });
  const none = h('input', { type: 'radio', name: 'wsn-manager', value: '', 'data-wsn-bot': '' });
  none.checked = !w.manager;
  none.addEventListener('change', () => { if (none.checked) { w.manager = null; w.unfencedConfirmed = false; changed(true); } });
  const newBot = btn('A new agent / bot…', () => {
    save();
    state.botReturn = 'new-workspace';
    location.replace('#/bots/~new');
  }, { icon: 'plus', title: 'Define one now in the Agent / Bot editor — it is kept for next time, and you come back here' });
  newBot.dataset.wsnNewBot = '';
  return [
    h('h2', null, 'Which of your bots runs this workspace?'),
    h('fieldset', { class: 'wiz-choices wsn-roster' }, h('legend', { class: 'sr-only' }, 'The manager'), ...roster,
      choiceCard({ class: 'wiz-choice wsn-bot' }, none, h('span', { class: 'wsn-cc wsn-bot-row' }, h('span', { class: 'bot-avatar', 'aria-hidden': 'true' }, icon('user-round')),
        h('span', { class: 'wsn-cc' }, h('span', { class: 'wsn-cc-title' }, 'No manager — I manage'), h('span', { class: 'wsn-cc-desc' }, 'you start workers yourself; you drive'))))),
    h('div', { class: 'wsn-acts' }, newBot, h('small', { class: 'muted' }, 'It is kept in Agents / Bots for next time; you come back here with it chosen.')),
    identity(),
    slot('refusals'),
  ];
}
function agentWords(a) { return { 'claude-code': 'Claude Code', codex: 'Codex' }[a] || a; }
function pickManager(b) {
  const w = state.wsn;
  w.manager = b.name;
  w.unfencedConfirmed = false;
  const preset = presetOf(w.preset);
  w.managerIsolation = b.isolation === 'vm' ? 'vm' : preset && preset.managerIsolation && preset.managerIsolation !== 'unfenced' ? preset.managerIsolation : 'fenced';
  changed(true);
}
function identity() {
  const w = state.wsn, b = w.manager ? botOf(w.manager) : null;
  if (!b) return null;
  const rows = [
    ['agent & model', agentWords(b.agent) + (b.model ? ' · ' + b.model : ' · its default'), 'identity'],
    ['account', b.account ? (b.account === 'mac' ? 'this Mac’s login' : b.account) : 'this Mac’s login', 'account'],
    ['how it is reached', DELIVER_WORDS[b.deliver] || b.deliver, 'reached'],
    ['how it runs', ISO_WORDS[w.managerIsolation] + ' — next step', null],
  ];
  const poll = (b.deliver === 'webhook' || (b.deliver === 'inbox' && w.managerIsolation !== 'unfenced'))
    ? callout('warn', { compact: true, attrs: { 'data-wsn-poll': b.name }, body: b.name + ' is reached ' + (b.deliver === 'inbox' ? 'by its inbox, which only an unfenced session gets' : 'by a webhook')
        + '; a manager Dozable starts collects its own messages.',
      actions: [btn('Reach it by poll', () => reachByPoll(b.name), { small: true, icon: 'refresh-cw' })] }) : null;
  return h('div', { class: 'wsn-identity', 'data-wsn-identity': b.name },
    h('h3', null, 'Manager, in ' + mainName() + ' — from its identity'),
    h('table', { class: 'wsn-id' }, h('tbody', null, ...rows.map(([k, v, tab]) => h('tr', null, h('th', null, k), h('td', null, v),
      h('td', null, tab ? h('a', { href: botHash(b.name, tab), title: 'Changes ' + b.name + ' everywhere', on: { click: () => save() } }, 'Change here') : null))))),
    h('small', { class: 'muted' }, 'A change there changes ' + b.name + ' everywhere.'),
    poll);
}
async function reachByPoll(name) {
  try {
    const end = await waitForOp(await actOrThrow({ action: 'bot-set', name, deliver: 'poll' }), 60);
    if (!end || end.state !== 'done') throw new Error(end ? end.text : 'No answer yet — Operations shows how it ends.');
    toast(end.text);
    await loadBots(0);
    changed(true);
  } catch (e) { pageFailure(e.message || String(e)); }
}

// ── 3 · where it runs ────────────────────────────────────────────────────────────────────────────────────────────────
function radioCards(name, list, value, onPick, attr) {
  return list.map(([v, title, desc, disabled]) => {
    const input = h('input', { type: 'radio', name, value: v, disabled: disabled ? true : null });
    input.dataset[attr] = v;
    input.checked = value === v;
    input.addEventListener('change', () => { if (input.checked) onPick(v); });
    return choiceCard({ class: 'wiz-choice', title: disabled || null }, input, h('span', { class: 'wsn-cc' }, h('span', { class: 'wsn-cc-title' }, title,
      disabled === 'later' ? h('span', { class: 'ws-coming' }, 'later') : null), desc ? h('span', { class: 'wsn-cc-desc' }, desc) : null,
      v === 'unfenced' && value === 'unfenced' ? h('span', { class: 'ws-chip acts-as-you' }, icon('triangle-alert'), 'acts as you') : null));
  });
}
function stepWhere() {
  const w = state.wsn, b = w.manager ? botOf(w.manager) : null;
  const place = [['mac', 'This Mac', 'where it runs today'], ['cloud', 'Cloud', null, 'later']];
  const mgr = b ? radioCards('wsn-miso', [
    ['fenced', 'Fenced on this Mac', 'the default: ' + CONTROL.fenced],
    ['vm', 'Micro VM', CONTROL.vm + (b.isolation === 'vm' ? ' — ' + b.name + '’s default' : '')],
    ['unfenced', 'Unfenced on this Mac', 'only when you name it: ' + CONTROL.unfenced],
  ], w.managerIsolation, (v) => pickManagerIsolation(v), 'wsnMiso') : null;
  const workers = radioCards('wsn-wiso', [
    ['vm', 'Micro VM', CONTROL.vm],
    ['fenced', 'Fenced on this Mac', CONTROL.fenced],
    ['unfenced', 'Unfenced', 'never by default', 'never by default — a worker is unfenced only when doz worker add names it'],
  ], w.workerIsolation, (v) => { w.workerIsolation = v; changed(true); }, 'wsnWiso');
  const fromProject = w.fromProject && w.plan && w.plan.project && w.plan.project.preset;
  const net = radioCards('wsn-net', NETWORKS.map(([v, t, d]) => [v, t, d, fromProject ? 'filled in from ' + w.plan.project.file : null]),
    fromProject ? w.plan.project.preset : w.network, (v) => { w.network = v; changed(true); }, 'wsnNet');
  const controls = [
    b ? ['manager', CONTROL[w.managerIsolation]] : null,
    ['new workers', CONTROL[w.workerIsolation]],
    ['network', (fromProject ? w.plan.project.preset : w.network) + ((w.sites || []).length ? ' + ' + w.sites.join(', ') : '') + ' + the room (added for every agent)'],
    ['address guard', 'always on (cannot be turned off)'],
  ].filter(Boolean);
  return [
    h('h2', null, 'Where do its agents run?'),
    h('fieldset', { class: 'wiz-choices wsn-row' }, h('legend', null, 'Place'), ...radioCards('wsn-place', place, 'mac', () => {}, 'wsnPlace')),
    b ? h('fieldset', { class: 'wiz-choices wsn-row', 'data-wsn-manager-iso': w.managerIsolation }, h('legend', null, b.name + ' — the manager'), ...mgr) : null,
    h('fieldset', { class: 'wiz-choices wsn-row' }, h('legend', null, 'New workers — the workspace’s default'), ...workers),
    h('fieldset', { class: 'wiz-choices wsn-row' }, h('legend', null, 'Network preset'), ...net),
    h('div', { class: 'wsn-control' }, h('h3', null, 'Control'),
      h('table', { class: 'wsn-id', 'data-wsn-control': '' }, h('tbody', null, ...controls.map(([k, v]) => h('tr', null, h('th', null, k), h('td', null, v)))))),
    slot('refusals'),
  ];
}
function pickManagerIsolation(v) {
  const w = state.wsn;
  if (v !== 'unfenced') { w.managerIsolation = v; w.unfencedConfirmed = false; changed(true); return; }
  // Unfenced only when named — and confirmed: it acts as you.
  let confirmed = false;
  const d = dialog(w.manager + ' acts as you', w.manager + ' acts as you: no proxy, no placeholders, no guard. It reaches what you reach on this Mac — your files, your network, your keychain prompts — and anything beyond its chat tool asks you first.',
    [], 'Run it unfenced', async () => { confirmed = true; }, { danger: true, confirmCheck: 'Yes, ' + w.manager + ' acts as me', icon: 'triangle-alert' });
  d.dataset.wsnConfirm = '';
  d.addEventListener('close', () => {
    if (confirmed) { w.managerIsolation = 'unfenced'; w.unfencedConfirmed = true; } else if (w.managerIsolation === 'unfenced' && !w.unfencedConfirmed) w.managerIsolation = 'fenced';
    changed(true);
  });
}

// ── 4 · grants & when, the review ────────────────────────────────────────────────────────────────────────────────────
function stepWhen() {
  const w = state.wsn, b = w.manager ? botOf(w.manager) : null;
  const honest = b
    ? (w.managerIsolation === 'unfenced'
      ? 'No limits exist yet: an unfenced manager acts as you.'
      : 'No limits exist yet: a fenced or micro VM manager can only talk in the room — it cannot start or stop agents.')
    : 'No manager: you drive.';
  const later = (label) => h('li', { class: 'wsn-later' }, h('span', null, label), h('span', { class: 'ws-coming' }, 'later'));
  let rooms;
  if (!chatOn()) {
    rooms = [h('p', { class: 'muted', 'data-wsn-room': 'none' }, 'No room: chat is off.' + (b ? ' A manager needs chat.' : '')), chatOnForm({ onOn: chatCameOn })];
  } else {
    const opts = [['make', 'Its room #' + mainName() + ' is made; nothing is posted until it starts'], ...((w.rooms || []).map((r) => [r, 'Use #' + r + ' instead (an existing room)'])),
      ['none', 'No room']];
    const sel = h('select', { 'data-wsn-room': '', 'aria-label': 'Its room' }, ...opts.map(([v, l]) => h('option', { value: v }, l)));
    sel.value = opts.some(([v]) => v === w.roomChoice) ? w.roomChoice : 'make';
    sel.addEventListener('change', () => { w.roomChoice = sel.value; changed(true); });
    rooms = [sel, h('small', { class: 'muted' }, 'Every worker is always in #' + (w.roomChoice !== 'make' && w.roomChoice !== 'none' ? w.roomChoice : mainName()) + '. Other rooms come later.')];
  }
  const whenCards = radioCards('wsn-when', [
    ['now', 'Right now', 'Create and start: the brief is posted as your first message' + (b ? ', then ' + b.name + ' starts' : '; you drive')],
    ['later', 'Later — keep it setting up', 'Create, keep setting up: nothing is posted; start it from its page'],
    ['wake', 'When I wake it', null, 'later'],
  ], w.when, (v) => { w.when = v; changed(true); }, 'wsnWhen');
  return [
    h('h2', null, 'Grants & when'),
    callout(b && w.managerIsolation === 'unfenced' ? 'warn' : 'info', { compact: true, attrs: { 'data-wsn-honest': '' }, body: honest }),
    h('ul', { class: 'wsn-later-list' }, later('Grant presets'), later('Budget'), later('Also include a second voice'), later('Save as template…')),
    h('div', { class: 'field wsn-rooms' }, h('span', null, 'Its room'), ...rooms),
    h('fieldset', { class: 'wiz-choices wsn-row' }, h('legend', null, 'When'), ...whenCards),
    h('h3', null, 'The plan'),
    slot('lines'),
    slot('refusals'),
    slot('gaps'),
    tooBig() ? callout('warn', { compact: true, attrs: { 'data-wsn-too-big': '' }, body: 'The brief is too long for this page: copy the commands and run them in a terminal on this Mac (the CLI takes up to 256 KiB).' }) : null,
    slot('commands'),
  ];
}
function roomFields() {
  const w = state.wsn;
  if (w.roomChoice === 'none') return { noRoom: true };
  if (w.roomChoice && w.roomChoice !== 'make') return { room: w.roomChoice };
  return {};
}

// ── the actions: Create, keep setting up · Create and start ──────────────────────────────────────────────────────────
async function create(start) {
  const w = state.wsn;
  if (w.busy || newWorkspaceRefusal()) return;
  w.busy = start ? 'now' : 'later';
  w.error = '';
  paintPlan();
  const body = { action: 'workspace-new', ...req() };
  const name = body.workspace;
  try {
    const end = await waitForOp(await actOrThrow(body), 180);
    if (!end) throw new Error('No answer yet — Operations shows how it ends.');
    if (end.state !== 'done') throw new Error(end.text || name + ' was not made.');
    let line = end.text, tone = 'ok';
    if (start) {
      const confirmed = !!(w.manager && w.managerIsolation === 'unfenced' && w.unfencedConfirmed);
      try {
        const s = await waitForOp(await actOrThrow({ action: 'workspace-start', workspace: name, actsAsYou: confirmed }), 300);
        if (!s) { line = name + ' is made; its start has not answered yet — Operations shows how it ends.'; tone = 'info'; }
        else if (s.state === 'done') line = s.text;
        else { line = name + ' is made but not started: ' + (s.text || 'the start was refused') + ' — it is setting up; its page lists what is missing.'; tone = 'warn'; }
      } catch (e) { line = name + ' is made but not started: ' + (e.message || String(e)); tone = 'warn'; }
    }
    forgetNewWorkspace();
    try { await loadWorkspaces(0); } catch (_) { /* the next hello */ }
    addNote({ id: 'wsn:' + name, tone, icon: tone === 'ok' ? 'circle-check' : 'triangle-alert', sticky: tone !== 'ok', role: 'status', cls: 'toast',
      attrs: { 'data-wsn-made': name }, body: [line, ' ', h('a', { href: workspaceHash(name) }, 'Open ' + name)] });
    location.hash = workspaceHash(name);
  } catch (e) {
    if (state.wsn === w) { w.busy = ''; w.error = e.message || String(e); render(false); }
  }
}

/// The New workspace buttons' address (`bot`: a manager chosen).
export function newWorkspaceHash(bot) { return '#/new-workspace' + (bot ? '?bot=' + bot : ''); }
/// Open the wizard (from Home, the sidebar's +, an Agent / Bot).
export function openNewWorkspace(bot) {
  if (bot && state.wsn) state.wsn.manager = null;
  location.hash = newWorkspaceHash(bot);
}
