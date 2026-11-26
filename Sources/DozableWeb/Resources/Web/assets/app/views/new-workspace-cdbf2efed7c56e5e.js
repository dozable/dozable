// views/new-workspace — The New workspace wizard (#/new-workspace[?bot=NAME|?template=ID], 782): a modal over the page under
// it. It opens on a gallery — five templates, each drawn as the workspace it makes (⤢: the full-page view), and Custom.
// A template is one screen: the name (the next free workspaceN), a new empty folder, the manager only when the template has
// one, and Create and start — `workspace-from-template` (its files in ~/doz-workspaces/NAME, then up). Custom is five short
// steps (views/wsn-custom.js) ending in `workspace-new` and, with Start it now, `workspace-start`; its header draws the
// workspace as chosen so far. A new bot is made inline, at Create (`bot-new`), and nothing ever leaves the wizard. Every
// action is exactly one HostOp the CLI also sends; only this Mac's own browser makes or starts a workspace.
import { h, markChildren } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { actOrThrow, waitForOp } from '../core/operations-283a20408c4a56b6.js';
import { roomHash } from '../core/routes-0babfc190b1519e4.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { loadBots, loadWorkspaces } from '../core/workspaces-eb44da5e11322b41.js';
import { NETWORKS, PROGRAM_WORDS, WHERE_WORDS, WORKSPACE_DEFINITION, WSN_STEPS, findingsOf, madeNote, nextFree, pictureText, requestFrom,
  templateAgentWords, templateRequestFrom } from '../core/ws-new-10f315ce07ac06df.js';
import { chatRooms } from '../components/bot-invite-cc12bb753cf9238b.js';
import { btn } from '../components/button-030d384b64f8d75d.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { cmdLine } from '../components/cmd-line-0addb11225f36cdd.js';
import { wizardCloseRequest, wizMount } from '../components/modal-025aa4b8cb1f1195.js';
import { addNote } from '../components/notes-b982b305c6f4f5bc.js';
import { pageFailure, toast } from '../components/notices-7a75ec167a650349.js';
import { stepperNode } from '../components/stepper-9f1fb5c64eac92d6.js';
import { drawing, expandButton, fullView, viewSection } from '../components/wsn-picture-38319e72a876de2d.js';
import { actsAsYouNeeded, customStep, nameAndFolder, nameIssue } from './wsn-custom-a67cd7265039856f.js';
import { WSN_REMOTE, askPlan, botOf, bots, forgetNewWorkspace, fresh, loadTemplates, managerWhere, newWorkspaceRefusal, onPlan, onRender,
  projectPreset, restore, save } from './wsn-state-00cb0f1daadeb3d4.js';

export { forgetNewWorkspace, newWorkspaceDirty, newWorkspaceRefusal, WSN_REMOTE } from './wsn-state-00cb0f1daadeb3d4.js';

const THUMB = { w: 320, h: 160 };
const HEAD = { w: 264, h: 132 };

// ── the view ─────────────────────────────────────────────────────────────────────────────────────────────────────────
export async function viewNewWorkspace() {
  if (newWorkspaceRefusal()) {
    return h('div', { class: 'wizard wz', 'data-wsn': 'remote' }, head({ title: 'New workspace' }),
      h('div', { class: 'wiz-card' }, markChildren(h('div', { class: 'w-body' },
        callout('info', { cls: 'notice', icon: 'lock', attrs: { 'data-wsn-remote': '' }, title: 'Only on this Mac', body: WSN_REMOTE + '.' }),
        h('p', { class: 'sub' }, WORKSPACE_DEFINITION),
        cmdLine('doz workspace new --template ID')), 'w-item')));
  }
  if (!state.wsn) state.wsn = restore() || fresh();
  const w = state.wsn;
  if (state.wsnBot) { w.screen = 'custom'; w.step = 1; w.manager = state.wsnBot; w.managerPicked = true; state.wsnBot = null; }
  if (state.wsnTemplate) {
    Object.assign(w, { screen: 'template', template: state.wsnTemplate, manager: null, managerPicked: false, newBot: null, botForm: null, actsAsYou: false });
    state.wsnTemplate = null;
  }
  try { w.templates = await loadTemplates(); } catch (e) { w.templates = []; w.templatesError = e.message || String(e); }
  try { await Promise.all([loadBots(0), loadWorkspaces(0)]); } catch (_) { /* said where they are used */ }
  if (w.screen === 'template' && !w.templates.some((t) => t.id === w.template)) w.screen = 'gallery';
  readRooms(w);
  save();
  askPlan(true);
  return node();
}
function readRooms(w) {
  chatRooms().then((s) => {
    if (!s || state.wsn !== w) return;
    const owned = new Set(((state.workspaces && state.workspaces.workspaces) || []).map((x) => x.room).filter(Boolean));
    const archived = new Set(s.archived || []);
    w.rooms = Object.keys(s.rooms || {}).filter((r) => !owned.has(r) && !archived.has(r)).sort();
    if (w.screen === 'custom' && w.step === 3) draw(false);
  });
}

function draw(focus) {
  if (state.modal !== 'new-workspace' || !state.wsn) return;
  const box = document.getElementById('wm-box');
  if (box && box.querySelector('.wz-view')) return;              // the full view is open: drawn when it closes
  // A field being typed in keeps its focus and caret: drawn again around it.
  const a = document.activeElement, key = a && box && box.contains(a) && a.matches('input[type=text], textarea') ? [...a.attributes].find((x) => x.name.startsWith('data-wsn')) : null;
  const caret = key ? [a.selectionStart, a.selectionEnd] : null;
  wizMount(node(), focus);
  if (key && !focus) {
    const again = box.querySelector('[' + key.name + ']');
    if (again) { again.focus(); try { again.setSelectionRange(caret[0], caret[1]); } catch (_) { /* not a text field */ } }
  }
}
onRender(draw);
onPlan(() => draw(false));

function go(screen, o = {}) {
  const w = state.wsn;
  w.screen = screen;
  if (o.template !== undefined) w.template = o.template;
  if (o.step !== undefined) w.step = Math.max(0, Math.min(4, o.step));
  w.error = '';
  save();
  askPlan(true);
  draw(true);
}

/// The modal's header: ← (back), the drawing with its ⤢, the title and one sentence, ✕; Custom's steps under it.
function head(o) {
  const close = btn('Close', () => wizardCloseRequest(), { quiet: true, iconOnly: true, icon: 'x', title: 'Close (Esc)' });
  close.dataset.wmClose = '';
  const back = o.back ? btn('Back', o.back, { quiet: true, iconOnly: true, icon: 'arrow-left', title: o.backTitle || 'Back' }) : null;
  if (back) back.dataset.wsnBack = '';
  const pic = o.picture ? h('span', { class: 'wz-head-pic', 'data-wsn-head-pic': '' }, drawing(o.picture, HEAD, 'thumb', o.title + ', drawn'),
    expandButton(o.title, (b) => o.expand(b))) : null;
  return h('header', { class: 'wm-head wz-head' },
    h('div', { class: 'wm-title-row' }, back, pic,
      h('div', { class: 'wz-head-text' }, h('h1', { id: 'wm-title' }, o.title), o.sub ? h('p', { class: 'wz-head-sub' }, o.sub) : null),
      h('span', { class: 'wm-gap' }), close),
    o.steps ? h('nav', { class: 'wm-steps', 'aria-label': 'Steps' }, o.steps.compact, o.steps.list) : null);
}

function node() {
  const w = state.wsn;
  if (w.screen === 'template') return templateScreen(w);
  if (w.screen === 'custom') return customScreen(w);
  return gallery(w);
}

// ── the gallery ──────────────────────────────────────────────────────────────────────────────────────────────────────
function gallery(w) {
  const cards = (w.templates || []).map((t) => {
    const open = h('button', { type: 'button', class: 'wz-card-open', 'data-wsn-template': t.id, on: { click: () => useTemplate(t.id) } },
      h('span', { class: 'wz-card-pic' }, t.picture ? drawing(t.picture, THUMB, 'thumb', t.title + ', drawn') : null),
      h('span', { class: 'wz-card-text' }, h('b', null, t.title), h('span', null, t.summary)));
    return h('div', { class: 'wz-card', 'data-wsn-card': t.id }, open, expandButton(t.title, (b) => templateView(t, b, true)));
  });
  const custom = h('button', { type: 'button', class: 'wz-card-open wz-custom', 'data-wsn-template': 'custom',
    on: { click: () => { Object.assign(w, { step: 0, manager: null, managerPicked: false, newBot: null, botForm: null, actsAsYou: false }); go('custom'); } } },
    h('span', { class: 'wz-card-text' }, h('b', null, 'Custom'), h('span', null, 'Choose the manager, where workers run and the room yourself.')),
    h('span', { class: 'ws-chip' }, '5 short steps'));
  return h('div', { class: 'wizard wz', 'data-wsn': 'gallery' }, head({ title: 'New workspace' }),
    h('div', { class: 'wiz-card' }, h('div', { class: 'w-body wz-gallery-body' },
      w.templatesError ? callout('bad', { compact: true, body: w.templatesError }) : null,
      h('div', { class: 'wz-gallery', 'data-wsn-gallery': String(cards.length) }, ...cards,
        h('div', { class: 'wz-card is-custom', 'data-wsn-card': 'custom' }, custom)))));
}

/// The full-page view of a template: the drawing labelled; its agents, room and network; Use this template (from the
/// gallery only — the template's own screen already is its action).
function templateView(t, opener, withAction) {
  const agents = t.agents.map((a) => {
    const [n, role, where] = templateAgentWords(a);
    return h('div', { class: 'wz-agent' }, h('span', { class: 'bot-avatar', 'aria-hidden': 'true' }, n.charAt(0).toUpperCase()), h('b', null, n),
      h('span', { class: 'muted' }, role), where ? h('span', { class: 'wz-where is-' + a.where }, where) : null);
  });
  fullView({ title: t.title, summary: t.summary, text: t.picture || '', opener,
    info: [viewSection('Agents', ...agents), viewSection('Room', h('p', null, '#' + (state.wsn.name || 'workspaceN') + ' · ' + t.room)),
      viewSection('Network', h('p', null, t.network))],
    action: withAction ? { label: 'Use this template', run: () => useTemplate(t.id) } : null });
}
/// A template's screen: its own manager choice (never one left from another screen).
function useTemplate(id) {
  Object.assign(state.wsn, { manager: null, managerPicked: false, newBot: null, botForm: null, actsAsYou: false });
  go('template', { template: id });
}

// ── a template's one screen ──────────────────────────────────────────────────────────────────────────────────────────
function templateScreen(w) {
  const t = (w.templates || []).find((x) => x.id === w.template);
  const create = createButton(() => createFromTemplate(w, t));
  const body = [...nameAndFolder(w, () => paintCreate(create, w))];
  if (t.needs.manager) body.push(managerSelect(w));
  const acts = actsAsYouTick(w, create);
  if (acts) body.push(acts);
  body.push(h('div', { class: 'dlg-error', role: 'alert', 'data-wsn-error': '' }, w.error || ''));
  paintCreate(create, w);
  return h('div', { class: 'wizard wz', 'data-wsn': 'template', 'data-wsn-for': t.id },
    head({ title: t.title, sub: t.summary, back: () => go('gallery'), backTitle: 'Templates', picture: t.picture, expand: (b) => templateView(t, b, false) }),
    h('form', { class: 'wiz-card', novalidate: '', on: { submit: (ev) => { ev.preventDefault(); create.click(); } } },
      markChildren(h('div', { class: 'w-body' }, ...body), 'w-item'),
      h('div', { class: 'w-foot wiz-buttons', 'data-wsn-foot': '' }, h('span', { class: 'wiz-gap' }), create)));
}
/// The manager: the bots that can manage it (each with where it runs), then a new bot made at Create.
function managerSelect(w) {
  const fits = ((w.plan && w.plan.managers) || []).filter((m) => m.fits).map((m) => botOf(m.bot)).filter(Boolean);
  const nb = w.newBot || { name: nextFree('boss', bots().map((b) => b.name)), agent: 'claude-code', isolation: 'fenced' };
  if (!w.managerPicked) w.manager = fits.length ? fits[0].name : nb.name;
  w.newBot = w.manager === nb.name ? nb : null;
  const sel = h('select', { 'data-wsn-manager': '', 'aria-label': 'Manager' },
    ...fits.map((b) => h('option', { value: b.name }, b.name + ' — ' + (PROGRAM_WORDS[b.agent] || b.agent) + ', ' + (WHERE_WORDS[b.isolation] || b.isolation))),
    h('option', { value: nb.name }, 'A new bot, ' + nb.name + ' — Claude Code, Fenced on this Mac'));
  sel.value = w.manager;
  sel.addEventListener('change', () => {
    w.manager = sel.value;
    w.managerPicked = true;
    w.newBot = sel.value === nb.name ? nb : null;
    w.actsAsYou = false;
    save();
    draw(false);
  });
  return h('label', { class: 'field' }, h('span', null, 'Manager'), sel);
}
function actsAsYouTick(w, create) {
  if (!actsAsYouNeeded(w)) return null;
  const tick = h('input', { type: 'checkbox', 'data-wsn-acts-as-you': '' });
  tick.checked = !!w.actsAsYou;
  tick.addEventListener('change', () => { w.actsAsYou = tick.checked; save(); paintCreate(create, w); });
  return h('div', { class: 'wz-acts-as-you' }, h('p', null, icon('triangle-alert'), w.manager + ' runs unfenced: it acts as you on this Mac — your files, keys and network.'),
    h('label', { class: 'wz-inline-check' }, tick, ' Yes, ' + w.manager + ' acts as me'));
}
function createButton(run) {
  const b = h('button', { type: 'button', class: 'btn lg primary', 'data-wsn-create': '' });
  b.addEventListener('click', () => { if (!b.disabled) run(); });
  return b;
}
/// The button's label follows the tick (Create and start · Create); disabled while something on screen is wrong.
function paintCreate(b, w) {
  const custom = w.screen === 'custom';
  const start = custom ? w.start : true;
  const blocked = !!w.busy || !!nameIssue(w) || (actsAsYouNeeded(w) && !w.actsAsYou)
    || (custom && (((w.plan && w.plan.findings) || []).length > 0 || !w.plan)) || (!custom && !w.plan);
  b.disabled = blocked;
  b.replaceChildren(w.busy ? icon('hourglass') : icon(start ? 'play' : 'folder-plus'), start ? 'Create and start' : 'Create');
}

// ── Custom ───────────────────────────────────────────────────────────────────────────────────────────────────────────
function customPicture(w) {
  return pictureText({ name: w.name, managerName: w.manager, managerWhere: managerWhere(w), workerIsolation: w.workerIsolation,
    room: w.room.mode === 'new' ? { mode: 'new', name: w.room.name || w.name } : w.room, invite: w.invite });
}
function customView(opener) {
  const w = state.wsn, mw = managerWhere(w);
  const agents = [
    w.manager ? h('div', { class: 'wz-agent' }, h('b', null, w.manager), h('span', { class: 'muted' }, 'manager'), h('span', { class: 'wz-where is-' + mw }, WHERE_WORDS[mw] || mw)) : null,
    h('div', { class: 'wz-agent' }, h('b', null, 'new workers'), h('span', { class: 'muted' }, 'added later'),
      h('span', { class: 'wz-where is-' + w.workerIsolation }, WHERE_WORDS[w.workerIsolation])),
  ];
  const room = w.room.mode === 'none' ? 'No room' : '#' + (w.room.name || w.name) + ' · you' + (w.manager ? ', ' + w.manager : '') + ', every worker'
    + (w.invite.length ? ', ' + w.invite.join(', ') : '');
  const net = (NETWORKS.find((n) => n[0] === w.network) || NETWORKS[0])[1];
  fullView({ title: w.name || 'New workspace', text: customPicture(w), opener,
    info: [viewSection('Agents', ...agents), viewSection('Room', h('p', null, room)), viewSection('Network', h('p', null, net))] });
}
function customScreen(w) {
  const stepGo = (i) => go('custom', { step: i });
  const { body, ok } = customStep(w, stepGo);
  const last = w.step === 4;
  const next = h('button', { type: 'submit', class: 'btn lg primary', 'data-wsn-next': '' }, h('span', { class: 'btn-label' }, 'Next'), icon('arrow-right'));
  const create = createButton(() => createCustom(w));
  const startTick = h('input', { type: 'checkbox', 'data-wsn-start': '' });
  startTick.checked = w.start;
  startTick.addEventListener('change', () => { w.start = startTick.checked; save(); paintCreate(create, w); });
  const copy = last ? btn('Commands', () => copyCommands(w), { small: true, quiet: true, icon: 'copy', title: 'Copy the doz commands that make the same workspace' }) : null;
  if (copy) copy.dataset.wsnCopy = '';
  const back = btn('Back', () => (w.step === 0 ? go('gallery') : stepGo(w.step - 1)), { icon: 'arrow-left' });
  back.dataset.wsnStepBack = '';
  const foot = last
    ? [back, h('span', { class: 'wiz-gap' }), h('label', { class: 'wz-inline-check' }, startTick, ' Start it now'), create]
    : [back, h('span', { class: 'wiz-gap' }), next];
  const form = h('form', { class: 'wiz-card', 'data-wsn-body': WSN_STEPS[w.step].id, novalidate: '' },
    markChildren(h('div', { class: 'w-body' }, ...body,
      copy ? h('div', { class: 'wz-copy' }, copy, w.copied ? h('pre', { class: 'wz-cmd', 'data-wsn-commands': '' }, w.copied) : null) : null,
      h('div', { class: 'dlg-error', role: 'alert', 'data-wsn-error': '' }, w.error || '')), 'w-item'),
    h('div', { class: 'w-foot wiz-buttons', 'data-wsn-foot': '' }, ...foot));
  form.addEventListener('submit', (ev) => { ev.preventDefault(); if (!last && ok()) stepGo(w.step + 1); });
  // Next (or Create) follows what is on screen as it changes, with no redraw.
  form.addEventListener('input', () => { next.disabled = !ok(); if (last) paintCreate(create, w); });
  next.disabled = !ok();
  if (last) paintCreate(create, w);
  const steps = stepperNode(WSN_STEPS, w.step, { data: 'data-wsn-step', href: '#/new-workspace', go: (i) => (i !== w.step ? () => stepGo(i) : null),
    count: (i) => (i < 4 && i !== w.step ? findingsOf(w.plan && w.plan.findings, WSN_STEPS[i].id).length : 0) });
  return h('div', { class: 'wizard wz', 'data-wsn': WSN_STEPS[w.step].id },
    head({ title: 'New workspace', picture: customPicture(w), expand: customView, steps }), form);
}
async function copyCommands(w) {
  const p = w.plan;
  if (!p) return;
  const text = p.commands + (w.start ? p.startCommand + '\n' : '');
  w.copied = text;
  try { await navigator.clipboard.writeText(text); toast('Copied — paste it in a terminal on this Mac'); } catch (_) { pageFailure('This browser could not copy — select the commands below'); }
  draw(false);
}

// ── Create ───────────────────────────────────────────────────────────────────────────────────────────────────────────
/// The new bot first (made only now — nothing is made if the wizard is left), as `bot-new` with what it was given; how it
/// is reached follows where it runs (an unfenced Claude Code bot by its inbox, any other by poll).
async function makeNewBot(w) {
  if (!w.newBot || w.manager !== w.newBot.name) return;
  const b = w.newBot;
  const end = await waitForOp(await actOrThrow({ action: 'bot-new', name: b.name, agent: b.agent, isolation: b.isolation,
    deliver: b.isolation === 'unfenced' && b.agent === 'claude-code' ? 'inbox' : 'poll' }), 60);
  if (!end || end.state !== 'done') throw new Error(end ? end.text : 'No answer yet — Operations shows how it ends.');
  w.newBot = null;
  await loadBots(0);
}
async function createCustom(w) {
  if (w.busy || newWorkspaceRefusal()) return;
  w.busy = true; w.error = '';
  draw(false);
  const name = w.name;
  try {
    const where = managerWhere(w);
    await makeNewBot(w);
    const body = { action: 'workspace-new', ...requestFrom({ ...w, managerIsolation: where, fromProject: !!projectPreset(w) && !w.netPicked }) };
    const end = await waitForOp(await actOrThrow(body), 180);
    if (!end) throw new Error('No answer yet — Operations shows how it ends.');
    if (end.state !== 'done') throw new Error(end.text || name + ' was not made.');
    let line = name + ' is made', tone = 'ok';
    if (w.start) {
      try {
        const s = await waitForOp(await actOrThrow({ action: 'workspace-start', workspace: name, actsAsYou: !!(where === 'unfenced' && w.actsAsYou) }), 300);
        if (!s) { line = name + ' is made; its start has not answered yet — Operations shows how it ends.'; tone = 'info'; }
        else if (s.state === 'done') line = name + ' is made and started';
        else { line = name + ' is made but not started: ' + (s.text || 'the start was refused'); tone = 'warn'; }
      } catch (e) { line = name + ' is made but not started: ' + (e.message || String(e)); tone = 'warn'; }
    }
    done(name, line, tone);
  } catch (e) {
    if (state.wsn === w) { w.busy = false; w.error = e.message || String(e); draw(false); }
  }
}
async function createFromTemplate(w, t) {
  if (w.busy || newWorkspaceRefusal()) return;
  w.busy = true; w.error = '';
  draw(false);
  const name = w.name;
  try {
    const acts = actsAsYouNeeded(w) && w.actsAsYou;
    if (t.needs.manager) await makeNewBot(w);
    const end = await waitForOp(await actOrThrow({ action: 'workspace-from-template',
      ...templateRequestFrom({ template: t.id, name, folder: w.folder, manager: t.needs.manager ? w.manager : null, actsAsYou: acts }) }), 600);
    if (!end) throw new Error('No answer yet — Operations shows how it ends.');
    if (end.state !== 'done') throw new Error(end.text || name + ' was not made.');
    done(name, name + ' is made and started', /a step failed/.test(end.text) ? 'warn' : 'ok');
  } catch (e) {
    if (state.wsn === w) { w.busy = false; w.error = e.message || String(e); draw(false); }
  }
}
/// Made: the wizard closes, the workspace's page opens with its room in front, a note says so — "started" only while
/// nothing of it already waits on you (an agent that exited in error).
async function done(name, line, tone) {
  forgetNewWorkspace();
  try { await loadWorkspaces(0); } catch (_) { /* the next hello */ }
  [line, tone] = madeNote(name, line, tone, state.workspaces && state.workspaces.workspaces.find((x) => x.name === name));
  addNote({ id: 'wsn:' + name, tone, icon: tone === 'ok' ? 'circle-check' : 'triangle-alert', sticky: tone !== 'ok', role: 'status', cls: 'toast',
    attrs: { 'data-wsn-made': name }, body: [line, ' · ', h('a', { href: roomHash(name) }, 'Open its room')] });
  location.hash = roomHash(name);
}

/// The New workspace buttons' address (`bot`: a manager chosen).
export function newWorkspaceHash(bot) { return '#/new-workspace' + (bot ? '?bot=' + bot : ''); }
/// Every entry opens a FRESH wizard (any draft is forgotten); the draft is kept only for a reload of the wizard's own
/// address and for the browser's Back and Forward.
export function openNewWorkspace(bot) {
  forgetNewWorkspace();
  location.hash = newWorkspaceHash(bot);
}
