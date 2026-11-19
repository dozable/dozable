// components/ws-lifecycle — A workspace's lifecycle in the dashboard: check, then ask. Each verb (stop, sleep, wake, finish,
// reopen, archive, restore, delete) opens a dialog drawn from ITS plan (POST /api/v1/workspace-lifecycle-plan — the one
// `doz workspace VERB W --dry-run` reads): what each agent becomes, what is kept and what goes (with sizes), the queue, what
// would be refused, "Show the command", and its confirmation (the name typed for archive and delete; Also free… and Also
// move its folders to the Bin unticked). Its button sends exactly one action, `workspace-VERB`, carrying the plan's sha — a
// workspace that changed since is refused, nothing done. This Mac's own browser only: another computer gets every button
// disabled, titled, with the command.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-575fccc668c266ed.js';
import { actOrThrow, waitForOp } from '../core/operations-7313aaf4b246f2e4.js';
import { isRemote } from '../core/session-312b29269085e944.js';
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { LIFECYCLE, MENU_ORDER, TRANSITIONAL, actionBody, canConfirm, planBody, primaryVerb, sizeWords } from '../core/ws-lifecycle-1120deefa7a3b5d8.js';
import { btn } from './button-8109d54546d946d3.js';
import { callout } from './callout-f30e3ad8767a987a.js';
import { cmdLine } from './cmd-line-cd34d267397493c0.js';
import { dialog } from './dialog-9c713118d7ef88d3.js';
import { toast } from './notices-4a3a8a4f95efab5b.js';

/// Why this browser may not change a workspace's lifecycle (null: it may).
export const LIFECYCLE_REMOTE = 'Only from this Mac’s own browser';
export function lifecycleRefusal() { return isRemote() ? LIFECYCLE_REMOTE : null; }
export const lifecycleCommand = (verb, w) => 'doz workspace ' + verb + ' ' + w;

/// The word a running lifecycle operation of `name` puts on its pill ("sleeping…"); null: none runs.
export function transitional(name) {
  for (const o of state.ops.values()) {
    if (o.state !== 'running' || !o.action || !o.action.startsWith('workspace-')) continue;
    const verb = o.action.slice('workspace-'.length);
    if (TRANSITIONAL[verb] && o.label === verb + ' ' + name) return TRANSITIONAL[verb];
  }
  return null;
}

function item(i) {
  return h('li', { class: 'wl-item' }, i.path ? h('code', { class: 'wl-path' }, i.path) : null, h('span', null, i.text),
    i.bytes ? h('span', { class: 'wl-size' }, sizeWords(i.bytes)) : null);
}

const ISO = { vm: 'micro VM', fenced: 'fenced', unfenced: 'unfenced · acts as you', elsewhere: 'elsewhere' };

/// The plan as the dialog shows it: the table (a card per agent on a phone), kept and goes, the queue, the refusals, the
/// notes, and the command.
export function planView(p) {
  const head = ['Agent', 'Now', 'After', 'Back'];
  const rows = p.rows.map((r) => h('tr', { class: 'wl-row' + (r.changes ? ' is-changing' : ''), 'data-wl-agent': r.name },
    h('td', { 'data-label': head[0] }, h('b', null, r.name), h('span', { class: 'wl-sub' }, r.role + ' · ' + r.place + ' · ' + (ISO[r.isolation] || r.isolation))),
    h('td', { 'data-label': head[1] }, r.now + (r.activity ? ' · ' + r.activity : '')),
    h('td', { 'data-label': head[2] }, r.after),
    h('td', { 'data-label': head[3] }, r.back)));
  const table = p.rows.length ? h('table', { class: 'wl-table' }, h('thead', null, h('tr', null, ...head.map((c) => h('th', null, c)))), h('tbody', null, rows))
    : h('p', { class: 'muted' }, 'It has no agents.');
  const lists = h('div', { class: 'wl-lists' },
    p.keeps.length ? h('div', { class: 'wl-keeps' }, h('h3', null, 'Kept'), h('ul', null, ...p.keeps.map(item))) : null,
    p.goes.length ? h('div', { class: 'wl-goes' }, h('h3', null, 'Goes'), h('ul', null, ...p.goes.map(item))) : null);
  const cmd = h('details', { class: 'wl-cmd' }, h('summary', null, 'Show the command'), cmdLine(p.command),
    p.commands.length ? h('div', { class: 'wl-today' }, h('p', { class: 'muted' }, 'Today, one agent at a time:'), ...p.commands.map((c) => cmdLine(c))) : null);
  return h('div', { class: 'wl-plan', 'data-wl-plan': p.verb, 'data-wl-sha': p.sha },
    table, lists,
    p.queue.note ? h('p', { class: 'wl-queue muted' }, icon('hourglass'), p.queue.note) : null,
    p.refusals.length ? callout('bad', { compact: true, title: 'It cannot be done now', body: h('ul', null, ...p.refusals.map((x) => h('li', null, x))), attrs: { 'data-wl-refusals': String(p.refusals.length) } }) : null,
    p.notes.length ? h('ul', { class: 'wl-notes muted' }, ...p.notes.map((n) => h('li', null, n))) : null,
    cmd);
}

/// Open `verb`'s dialog for workspace `d` (its detail); `onDone(end)` after its operation ended.
export async function openLifecycle(d, verb, onDone) {
  const v = LIFECYCLE[verb];
  const o = { removeSandboxes: false, binFolders: false, typed: '', actsAsYou: false, needsActsAsYou: false };
  const body = h('div', { class: 'wl-body' }, h('p', { class: 'muted' }, 'Reading what it would do…'));
  const extras = h('div', { class: 'wl-extras' });
  let plan = null;
  const dlg = dialog(v.label + ' ' + d.name + '?', null, [{ name: 'plan', type: 'custom', el: h('div', null, body, extras), get: () => null }],
    v.label, async () => {
      if (!canConfirm(plan, o)) throw new Error('Nothing to do until it can be done.');
      const end = await waitForOp(await actOrThrow(actionBody(plan, o)), 600);
      if (!end) throw new Error('No answer yet — Operations shows how it ends.');
      if (end.state !== 'done') throw new Error(end.text || d.name + ': ' + verb + ' did not finish.');
      toast(end.text);
      if (onDone) onDone(end);
    }, { danger: verb === 'delete' || verb === 'archive', icon: v.icon });
  dlg.dataset.wsLifecycle = verb;
  dlg.classList.add('wl-dialog');
  const submit = dlg.querySelector('.dlg-buttons button[type="submit"]');
  const gate = () => { if (submit) submit.disabled = !canConfirm(plan, o); };
  gate();
  async function read() {
    try {
      plan = await api('workspace-lifecycle-plan', { method: 'POST', json: planBody(d.name, verb, o) });
    } catch (e) {
      plan = null;
      body.replaceChildren(callout('bad', { compact: true, body: e.message || String(e) }));
      gate();
      return;
    }
    const m = d.agents.find((a) => a.role === 'manager');
    o.needsActsAsYou = verb === 'wake' && !!(m && m.actsAsYou) && plan.rows.some((r) => r.name === m.name && r.changes);
    body.replaceChildren(h('p', { class: 'wl-state' }, d.name + ' is ' + plan.state.replace(/-/g, ' ') + ' now.'), planView(plan));
    drawExtras(m);
    gate();
  }
  function tick(label, key, desc) {
    const box = h('input', { type: 'checkbox', 'data-wl-tick': key });
    box.checked = !!o[key];
    box.addEventListener('change', () => { o[key] = box.checked; if (key === 'actsAsYou') gate(); else read(); });
    return h('label', { class: 'field check wl-tick' }, box, h('span', null, label, desc ? h('small', null, desc) : null));
  }
  function drawExtras(m) {
    const parts = [];
    if (verb === 'archive' || verb === 'delete') {
      const own = plan.goes.find((g) => g.text.startsWith('the sandboxes '));
      const words = own && own.bytes ? 'Also free ' + sizeWords(own.bytes) + ': remove the sandboxes Dozable made for it' : 'Also remove the sandboxes Dozable made for it';
      parts.push(tick(words, 'removeSandboxes', verb === 'archive' ? 'A template of each is kept first; adopted sandboxes are never removed' : 'Adopted sandboxes are never removed'));
    }
    if (verb === 'delete') parts.push(tick('Also move its folders on this Mac to the Bin', 'binFolders', d.folders.map((f) => f.path).join(', ') || 'It has no folder'));
    if (o.needsActsAsYou) parts.push(tick('Yes, ' + m.name + ' acts as me: unfenced, no proxy, no placeholders, no guard', 'actsAsYou'));
    if (plan.confirm === 'typed') {
      const input = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', 'data-wl-typed': '', placeholder: plan.confirmName });
      input.value = o.typed;
      input.addEventListener('input', () => { o.typed = input.value.trim(); gate(); });
      parts.push(h('label', { class: 'field wl-typed' }, h('span', null, 'Type ' + plan.confirmName + ' to ' + verb + ' it'), input));
    }
    extras.replaceChildren(...parts);
  }
  read();
  return dlg;
}

/// The page's one primary button for its state (Sleep, Wake, Reopen, Restore; setting up's Start is the page's own).
export function primaryButton(d, onDone) {
  const verb = primaryVerb(d.state);
  if (!verb || verb === 'start') return null;
  const why = lifecycleRefusal();
  const v = LIFECYCLE[verb];
  const b = btn(v.label, () => openLifecycle(d, verb, onDone), { primary: true, small: true, icon: v.icon,
    title: why ? why + ' — ' + lifecycleCommand(verb, d.name) : v.desc });
  b.dataset.wsPrimary = verb;
  if (why || transitional(d.name)) b.disabled = true;
  return b;
}

/// The ⋯ menu's lifecycle items: Stop the manager · Sleep everything · Wake everything · — · Finish… · Archive… · Delete….
export function lifecycleItems(d, onDone) {
  const why = lifecycleRefusal();
  const manager = d.agents.some((a) => a.role === 'manager');
  const out = [];
  for (const verb of MENU_ORDER) {
    if (!verb) { out.push({ sep: true }); continue; }
    const v = LIFECYCLE[verb];
    const off = why || (verb === 'stop' && !manager ? 'It has no manager' : null);
    out.push({ label: v.item, icon: v.icon, desc: why ? why + ': ' + lifecycleCommand(verb, d.name) : v.desc, disabled: !!off,
      why: off ? off + (why ? ' — ' + lifecycleCommand(verb, d.name) : '') : null, data: { 'ws-lifecycle': verb },
      onSelect: () => openLifecycle(d, verb, onDone) });
  }
  return out;
}
