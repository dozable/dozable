// views/add-worker — Add a worker (#/w/NAME/agents/new): one page, the mockups' S12. Its fields are what `doz worker add`
// takes — the agent program (Claude Code or Codex; the others greyed, not yet as a worker), its name (the plan's next botN
// as the placeholder), the account (shown, never chosen), its one task, the rooms (the main one always), who it is
// (anonymous, or from a bot), where it is (a place of its own, or a new session in a running sandbox of the workspace) and
// where it runs — a comparison table of micro VM, fenced, unfenced and cloud (later), each heading a chip that opens the
// isolation guide; fenced chosen unless the workspace's or the bot's default is vm; unfenced never chosen for you, and only
// with the tick "It acts as you". Every change asks the plan route (`POST /api/v1/worker-plan`, debounced 300 ms, the
// latest wins) — a look: nothing written, nothing started — and its refusal is shown beside its field, the Add button off
// meanwhile. Show the command is the plan's (`doz worker add … --dry-run` prints the same). Add and start sends the ONE
// action `worker-add`. This Mac's own browser only; another computer sees the command.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-575fccc668c266ed.js';
import { COMPARE_ROWS, CLOUD, ISOLATIONS, compareCell } from '../core/isolation-eeb96279e071283f.js';
import { FIXED_TOOLS, LATER_AGENTS, TASK_MAX_BYTES, UNFENCED_TICK, WORKER_AGENTS, defaultColumn, fieldSlot, fits, utf8Length, workerRequestFrom } from '../core/add-worker-2a871285402777b7.js';
import { actOrThrow, waitForOp } from '../core/operations-bf324efee1735a56.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { agentsHash, workspaceHash } from '../core/routes-ce13c8979e42e1cc.js';
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { loadBots, loadWorkspace } from '../core/workspaces-58675c2e3031a177.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-d408fcba356d6a76.js';
import { isolationChip } from '../components/iso-chip-61adb195eb227252.js';
import { addNote } from '../components/notes-1979331b5b970ae1.js';
import { addCommand, workerRefusal } from '../components/worker-end-a2943c99cd2aa2b4.js';

const PLAN_WAIT_MS = 300;
const COLUMNS = [...ISOLATIONS.filter((x) => x.id !== 'elsewhere'), CLOUD];
const ACCOUNT_WORDS = { mac: 'this Mac’s own login' };

/// The bots that may be started here as a worker, and why one may not (one live elsewhere: the one-live sentence).
function botChoices(aw) {
  return aw.bots.filter((b) => !b.retiredAt && b.isolation !== 'elsewhere' && b.keeper !== 'elsewhere').map((b) => {
    const other = b.running && b.running !== aw.workspace ? ['manages', b.running, 'doz workspace stop ' + b.running]
      : b.worksIn && b.worksIn !== aw.workspace ? ['works in', b.worksIn, 'doz worker end ' + b.worksIn + ' ' + b.name] : null;
    return { bot: b, why: other ? b.name + ' already ' + other[0] + ' ' + other[1] + ', which is running. For now a bot runs in one live workspace at a time — ' + other[2] + ' first.' : null };
  });
}
/// The running sandboxes of this workspace a worker may join: an adopted agent's or another worker's — never the manager's.
function sharedPlaces(d) {
  const out = [];
  for (const a of d.agents) {
    if (a.kind !== 'sandbox' || a.role === 'manager' || a.state !== 'running' || !a.sandbox || out.includes(a.sandbox)) continue;
    if (d.agents.some((m) => m.role === 'manager' && m.sandbox === a.sandbox)) continue;
    out.push(a.sandbox);
  }
  return out;
}

function form(aw) {
  const f = aw.f, bot = f.who === 'bot' ? aw.bots.find((b) => b.name === f.bot) : null;
  if (!f.picked) f.column = defaultColumn(aw.detail.workerIsolation, bot ? bot.isolation : null);
  return f;
}
function request(aw) { return workerRequestFrom(form(aw)); }

// ── the plan: asked on every change (debounced), the latest answer wins ──────────────────────────────────────────────
let planTimer = null, planReader = null;
function changed(aw, now) {
  paintForm(aw);
  clearTimeout(planTimer);
  planTimer = setTimeout(() => readPlan(aw), now ? 0 : PLAN_WAIT_MS);
}
async function readPlan(aw) {
  if (state.aw !== aw || workerRefusal()) return;
  if (planReader) planReader.abort();
  const reader = new AbortController();
  planReader = reader;
  aw.asking = true;
  paintPlan(aw);
  try {
    const p = await api('worker-plan', { method: 'POST', json: request(aw), signal: reader.signal });
    if (planReader !== reader || state.aw !== aw) return;
    aw.plan = p;
    aw.planError = '';
  } catch (e) {
    if (e.name === 'AbortError' || planReader !== reader) return;
    aw.planError = e.message || String(e);
  } finally {
    if (planReader === reader) { planReader = null; aw.asking = false; }
  }
  paintPlan(aw);
}

// Leaving the page forgets it: the next visit starts from a fresh form, with the workspace and the bots read again.
window.addEventListener('hashchange', () => { if (!/^#\/w\/[a-z0-9-]+\/agents\/new$/.test(location.hash)) state.aw = null; });

// ── the page ─────────────────────────────────────────────────────────────────────────────────────────────────────────
export async function viewAddWorker() {
  const name = state.param;
  if (state.aw && state.aw.workspace === name && state.aw.node && state.aw.node.isConnected) return null;   // built: kept as typed
  const back = h('a', { href: agentsHash(name) }, 'Its agents');
  const crumb = h('nav', { class: 'agent-crumb', 'aria-label': 'Where this is' }, h('a', { href: workspaceHash(name) }, name),
    h('span', { class: 'agent-crumb-sep', 'aria-hidden': 'true' }, '›'), back, h('span', { class: 'agent-crumb-sep', 'aria-hidden': 'true' }, '›'),
    h('span', { class: 'agent-crumb-here', 'aria-current': 'page' }, 'Add a worker'));
  const head = h('div', { class: 'head' }, h('h1', null, 'Add a worker to ' + name));
  const why = workerRefusal();
  if (why) {
    state.aw = null;
    return h('div', { class: 'aw', 'data-add-worker-page': name }, crumb, head,
      callout('info', { attrs: { 'data-aw-remote': '' }, title: 'Workers are added only in this Mac’s own browser',
        body: ['Or in a terminal on the Mac:', cmdLine(addCommand(name))] }));
  }
  let d;
  // Read afresh on every visit: who is live where changes from the CLI too (a bot live elsewhere is greyed by it).
  try { d = await loadWorkspace(name, 0); } catch (e) {
    state.aw = null;
    return h('div', { class: 'aw', 'data-add-worker-page': name }, crumb, head,
      callout(e.status === 404 ? 'warn' : 'bad', { title: e.status === 404 ? name + ' is not a workspace' : 'This workspace could not be read', body: e.message || String(e) }));
  }
  let bots = { bots: [] };
  try { bots = await loadBots(0); } catch (_) { /* anonymous only */ }
  const aw = { workspace: name, detail: d, bots: bots.bots || [], plan: null, planError: '', busy: false, error: '', showCmd: false, asking: false,
    f: { workspace: name, task: '', name: '', who: 'anon', bot: '', agent: 'claude-code', place: 'own', column: 'fenced', picked: false, unfencedTicked: false,
         cpus: '', memory: '', rooms: [], tools: [] } };
  state.aw = aw;
  aw.node = build(aw, crumb, head);
  paintForm(aw);
  readPlan(aw);
  return aw.node;
}

function slot(aw, k) { return aw.slots[k]; }
function problemSlot(k) { return h('p', { class: 'aw-problem', 'data-aw-problem': k, role: 'alert', hidden: true }); }

function build(aw, crumb, head) {
  const f = aw.f, d = aw.detail;
  aw.slots = {};
  for (const k of ['top', 'task', 'name', 'agent', 'who', 'rooms', 'in', 'where', 'size', 'tools']) aw.slots[k] = problemSlot(k);
  // Agent: Claude Code, Codex; the others greyed.
  const agents = h('div', { class: 'aw-agents', role: 'radiogroup', 'aria-label': 'Agent' },
    ...WORKER_AGENTS.map(([v, l]) => {
      const i = h('input', { type: 'radio', name: 'aw-agent', value: v, 'data-aw-agent': v });
      i.checked = f.agent === v;
      i.addEventListener('change', () => { f.agent = v; changed(aw); });
      return h('label', { class: 'aw-pill' }, i, l);
    }),
    ...LATER_AGENTS.map((l) => h('span', { class: 'aw-pill is-off', title: 'Not yet as a worker', 'aria-disabled': 'true' }, l, h('span', { class: 'ws-coming' }, 'not yet as a worker'))));
  const agentField = h('div', { class: 'field aw-field', 'data-aw-field': 'agent' }, h('span', null, 'Agent'), agents, slot(aw, 'agent'));
  // Name and account.
  const nameIn = h('input', { type: 'text', 'data-aw-name': '', autocomplete: 'off', spellcheck: 'false', maxlength: '40', 'aria-label': 'Its name in chat' });
  nameIn.addEventListener('input', () => { f.name = nameIn.value; changed(aw); });
  aw.nameIn = nameIn;
  aw.account = h('span', { class: 'aw-readonly', 'data-aw-account': '' }, '…');
  const nameRow = h('div', { class: 'aw-row' },
    h('label', { class: 'field aw-field', 'data-aw-field': 'name' }, h('span', null, 'Name'), nameIn, slot(aw, 'name')),
    h('div', { class: 'field aw-field' }, h('span', null, 'Account'), aw.account, h('small', { class: 'muted' }, 'Shown, not chosen: its bot’s, else this Mac’s default.')));
  // The task.
  const task = h('textarea', { 'data-aw-task': '', rows: '4', spellcheck: 'true', placeholder: 'What it is to do — its START says it in full.', 'aria-label': 'Its one task' });
  aw.taskSize = h('small', { class: 'muted aw-size', 'data-aw-task-size': '' });
  task.addEventListener('input', () => { f.task = task.value; changed(aw); });
  const taskField = h('label', { class: 'field aw-field', 'data-aw-field': 'task' }, h('span', null, 'Its one task'), task, aw.taskSize, slot(aw, 'task'));
  // Rooms: the main one always.
  const main = d.rooms.find((r) => r.main);
  const others = d.rooms.filter((r) => !r.main);
  const rooms = h('div', { class: 'aw-checks' },
    main ? h('label', { class: 'aw-check', title: 'Every worker is in the main room' }, h('input', { type: 'checkbox', checked: true, disabled: true, 'data-aw-room': main.label }), '#' + main.room) : h('span', { class: 'muted' }, 'No main room yet.'),
    ...others.map((r) => {
      const i = h('input', { type: 'checkbox', 'data-aw-room': r.label });
      i.addEventListener('change', () => { f.rooms = i.checked ? [...f.rooms, r.label] : f.rooms.filter((x) => x !== r.label); changed(aw); });
      return h('label', { class: 'aw-check' }, i, '# ' + r.label);
    }));
  const roomsField = h('div', { class: 'field aw-field', 'data-aw-field': 'rooms' }, h('span', null, 'Rooms'), rooms, slot(aw, 'rooms'));
  // Who: anonymous (recommended) or from a bot.
  const choices = botChoices(aw);
  const botSel = h('select', { 'data-aw-bot': '', 'aria-label': 'The bot' }, h('option', { value: '' }, choices.length ? 'Choose a bot…' : 'No bot runs here'),
    ...choices.map((c) => h('option', { value: c.bot.name, disabled: c.why ? true : null, title: c.why || null, 'data-why': c.why || null }, c.bot.name + (c.why ? ' — live elsewhere' : ''))));
  aw.botWhy = h('small', { class: 'muted', 'data-aw-bot-why': '', hidden: true });
  botSel.addEventListener('change', () => { f.bot = botSel.value; f.who = f.bot ? 'bot' : f.who; whoBot.checked = !!f.bot || whoBot.checked; changed(aw); });
  const whoAnon = h('input', { type: 'radio', name: 'aw-who', value: 'anon', 'data-aw-who': 'anon', checked: true });
  const whoBot = h('input', { type: 'radio', name: 'aw-who', value: 'bot', 'data-aw-who': 'bot' });
  whoAnon.addEventListener('change', () => { f.who = 'anon'; changed(aw); });
  whoBot.addEventListener('change', () => { f.who = 'bot'; changed(aw); });
  const whoField = h('div', { class: 'field aw-field', 'data-aw-field': 'who' }, h('span', null, 'Who'),
    h('label', { class: 'aw-radio' }, whoAnon, h('span', null, h('b', null, 'A new worker, anonymous'), ' — a name like bot1, settings from this workspace; it leaves chat when it ends (recommended)')),
    h('label', { class: 'aw-radio' }, whoBot, h('span', null, h('b', null, 'From a bot'), ' — its identity, account and instructions; no grants as a worker; its token is kept when it ends'), botSel),
    aw.botWhy, slot(aw, 'who'));
  // In: a place of its own, or a new session in a running sandbox of the workspace.
  const places = sharedPlaces(d);
  const inOwn = h('input', { type: 'radio', name: 'aw-in', value: 'own', 'data-aw-in': 'own', checked: true });
  inOwn.addEventListener('change', () => { f.place = 'own'; changed(aw); });
  const inField = h('div', { class: 'field aw-field', 'data-aw-field': 'in' }, h('span', null, 'In'),
    h('label', { class: 'aw-radio' }, inOwn, h('span', null, h('b', null, 'A place of its own'), ' — a new session on this Mac, or its own micro VM: where it runs, beside')),
    ...places.map((x) => {
      const i = h('input', { type: 'radio', name: 'aw-in', value: x, 'data-aw-in': x });
      i.addEventListener('change', () => { f.place = x; changed(aw); });
      return h('label', { class: 'aw-radio' }, i, h('span', null, h('b', null, 'A new session in ' + x), ' — shares ' + x + ': workers there can read each other’s placeholders'));
    }),
    places.length ? null : h('small', { class: 'muted' }, 'No sandbox of ' + d.name + ' runs that a worker could share (never the manager’s).'),
    slot(aw, 'in'));
  // Where it runs: the comparison table, a column chosen.
  aw.colInputs = {};
  const headCells = COLUMNS.map((c) => {
    const i = h('input', { type: 'radio', name: 'aw-col', value: c.id, 'data-aw-col': c.id, disabled: c.later ? true : null, 'aria-label': c.title });
    if (!c.later) i.addEventListener('change', () => { f.column = c.id; f.picked = true; if (c.id !== 'unfenced') f.unfencedTicked = false; changed(aw); });
    aw.colInputs[c.id] = i;
    return h('th', { 'data-col': c.id, class: c.later ? 'is-later' : null },
      h('span', { class: 'aw-col-h' }, i, isolationChip(c.chip), c.later ? h('span', { class: 'ws-coming' }, 'later') : null));
  });
  const table = h('table', { class: 'aw-cmp', 'data-aw-compare': '' },
    h('thead', null, h('tr', null, h('th', null, h('span', { class: 'sr-only' }, 'Where it runs')), ...headCells)),
    h('tbody', null, ...COMPARE_ROWS.map(([k, label]) => h('tr', { 'data-row': k }, h('th', null, label),
      ...COLUMNS.map((c) => h('td', { 'data-col': c.id, class: (c.later ? 'is-later' : '') + (k === 'control' ? ' aw-mono' : '') || null }, compareCell(c, k)))))));
  const tick = h('input', { type: 'checkbox', 'data-aw-unfenced-tick': '' });
  tick.addEventListener('change', () => { f.unfencedTicked = tick.checked; changed(aw); });
  aw.tick = tick;
  aw.tickRow = h('label', { class: 'aw-tick', hidden: true }, tick, h('span', null, UNFENCED_TICK));
  aw.sharedNote = h('p', { class: 'muted aw-shared-note', hidden: true });
  const cpus = h('input', { type: 'number', min: '1', max: '64', 'data-aw-cpus': '', 'aria-label': 'CPUs', placeholder: 'default' });
  const memory = h('input', { type: 'text', 'data-aw-memory': '', 'aria-label': 'Memory', placeholder: 'like 4G', maxlength: '16', autocomplete: 'off' });
  cpus.addEventListener('input', () => { f.cpus = cpus.value; changed(aw); });
  memory.addEventListener('input', () => { f.memory = memory.value; changed(aw); });
  aw.size = h('div', { class: 'aw-row aw-size-row', hidden: true },
    h('label', { class: 'field' }, h('span', null, 'CPUs'), cpus), h('label', { class: 'field' }, h('span', null, 'Memory'), memory), slot(aw, 'size'));
  const whereField = h('div', { class: 'field aw-field', 'data-aw-field': 'where' }, h('span', null, 'Where it runs'),
    h('div', { class: 'aw-cmp-wrap' }, table), aw.tickRow, aw.sharedNote, aw.size, slot(aw, 'where'));
  // More: the allowed tools (fenced Claude Code only); its folder and network, read from the plan.
  const toolsIn = h('input', { type: 'text', 'data-aw-tools': '', placeholder: 'Edit, Bash(git status:*)', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'More tools it may use without asking' });
  toolsIn.addEventListener('input', () => { f.tools = toolsIn.value.split(',').map((x) => x.trim()).filter(Boolean); changed(aw); });
  aw.toolsIn = toolsIn;
  aw.facts = h('dl', { class: 'facts aw-facts', 'data-aw-facts': '' });
  const more = h('details', { class: 'aw-more' }, h('summary', null, 'More'),
    h('div', { class: 'field aw-field', 'data-aw-field': 'tools' }, h('span', null, 'Allowed without asking'),
      h('div', { class: 'aw-checks' }, ...FIXED_TOOLS.map((t) => h('label', { class: 'aw-check' }, h('input', { type: 'checkbox', checked: true, disabled: true }), h('code', null, t)))),
      toolsIn, h('small', { class: 'muted' }, 'A fenced Claude Code worker only; its chat tool is always allowed.'), slot(aw, 'tools')),
    aw.facts);
  // The plan's lines, the command, the buttons.
  aw.notes = h('ul', { class: 'aw-notes', 'data-aw-notes': '' });
  aw.cmd = h('div', { class: 'aw-cmd', 'data-aw-command': '', hidden: true });
  aw.status = h('p', { class: 'muted aw-status', 'data-aw-status': '', role: 'status' });
  aw.err = h('p', { class: 'aw-problem', 'data-aw-error': '', role: 'alert', hidden: true });
  const show = h('button', { type: 'button', class: 'btn sm quiet', 'data-aw-show-command': '', 'aria-expanded': 'false',
    on: { click: () => { aw.showCmd = !aw.showCmd; show.setAttribute('aria-expanded', String(aw.showCmd)); paintPlan(aw); } } }, icon('square-terminal'), 'Show the command');
  aw.add = h('button', { type: 'button', class: 'btn primary', 'data-aw-add': '', on: { click: () => addAndStart(aw) } }, icon('play'), 'Add and start');
  const cancel = h('a', { class: 'btn', href: agentsHash(d.name), 'data-aw-cancel': '' }, 'Cancel');
  aw.agentField = agentField;
  return h('div', { class: 'aw', 'data-add-worker-page': d.name }, crumb, head,
    h('p', { class: 'sub' }, 'An agent with one task, in ' + d.name + '’s room. It says there when it is up; Dozable posts nothing.'),
    slot(aw, 'top'),
    h('div', { class: 'aw-grid' },
      h('div', { class: 'aw-col' }, agentField, nameRow, taskField, roomsField, whoField, inField),
      h('div', { class: 'aw-col' }, whereField, more)),
    aw.notes, aw.cmd, aw.err,
    h('div', { class: 'aw-foot' }, show, h('span', { class: 'ws-sp' }), aw.status, cancel, aw.add));
}

/// What the form itself decides: which fields show, the column, the tick, the task's size.
function paintForm(aw) {
  const f = form(aw);
  aw.agentField.hidden = f.who === 'bot';
  const own = f.place === 'own';
  for (const [id, i] of Object.entries(aw.colInputs)) {
    i.checked = own && f.column === id;
    if (id !== 'cloud') i.disabled = !own;
  }
  for (const cell of aw.node.querySelectorAll('.aw-cmp [data-col]')) cell.classList.toggle('is-chosen', own && cell.dataset.col === f.column);
  aw.tickRow.hidden = !(own && f.column === 'unfenced');
  aw.tick.checked = f.unfencedTicked;
  aw.sharedNote.hidden = own;
  aw.sharedNote.textContent = own ? '' : 'In ' + f.place + ' it has the sandbox’s isolation: micro VM · proxy · placeholders · shares ' + f.place + '.';
  aw.size.hidden = !(own && f.column === 'vm');
  const bytes = utf8Length(f.task);
  aw.taskSize.textContent = bytes > TASK_MAX_BYTES ? bytes + ' bytes — over 15 KiB: use the command, with the task in a file' : bytes ? bytes + ' bytes' : '';
  aw.taskSize.classList.toggle('is-bad', bytes > TASK_MAX_BYTES);
  const sel = aw.node.querySelector('[data-aw-bot]');
  const opt = sel && sel.selectedOptions[0];
  aw.botWhy.hidden = !(opt && opt.dataset.why);
  aw.botWhy.textContent = opt && opt.dataset.why ? opt.dataset.why : '';
  paintButtons(aw);
}

/// Why Add and start may not be pressed now (null: it may).
function blocked(aw) {
  const f = aw.f, p = aw.plan;
  if (aw.busy) return 'Adding…';
  if (!f.task.trim()) return 'Its task first.';
  if (f.who === 'bot' && !f.bot) return 'Choose the bot first.';
  if (!fits(request(aw))) return 'Too long for this page — copy the command and run it in a terminal on this Mac.';
  if (f.place === 'own' && f.column === 'unfenced' && !f.unfencedTicked) return 'Tick “' + UNFENCED_TICK + '” to add it unfenced.';
  if (aw.asking || !p) return 'Checking…';
  if (aw.planError) return aw.planError;
  if (p.problem) return p.problem.text;
  return null;
}
function paintButtons(aw) {
  const why = blocked(aw);
  aw.add.disabled = !!why;
  aw.add.title = why || 'Add it and start it now';
  aw.status.textContent = aw.busy ? 'Adding…' : why && why !== (aw.plan && aw.plan.problem && aw.plan.problem.text) ? why : '';
}

/// What the plan said: the name it would take, the account, the refusal beside its field, the facts, the command.
function paintPlan(aw) {
  if (state.aw !== aw) return;
  const p = aw.plan, f = aw.f;
  aw.nameIn.placeholder = p && p.name && f.who !== 'bot' ? p.name : 'botN';
  aw.nameIn.disabled = f.who === 'bot';
  if (f.who === 'bot') aw.nameIn.value = f.bot || '';
  else if (aw.nameIn.value !== f.name) aw.nameIn.value = f.name;
  aw.account.textContent = !p || !p.name ? '—' : p.account ? (ACCOUNT_WORDS[p.account] || p.account) : 'yours — it acts as you';
  for (const [k, el] of Object.entries(aw.slots)) { el.hidden = true; el.textContent = ''; }
  if (p && p.problem) {
    const el = aw.slots[fieldSlot(p.problem.field)] || aw.slots.top;
    el.hidden = false;
    el.textContent = p.problem.text;
    el.dataset.field = p.problem.field;
  } else if (aw.planError) {
    aw.slots.top.hidden = false;
    aw.slots.top.textContent = aw.planError;
  }
  const fact = (k, v) => (v ? [h('dt', null, k), h('dd', null, v)] : []);
  aw.facts.replaceChildren(...(p && p.name ? [
    ...fact('Folder', h('span', { class: 'ws-path', title: p.folder }, tildePath(p.folder || ''))),
    ...fact('Network', (p.network || '—') + (p.network === 'not limited' ? '' : ' + the room')),
    ...fact('Runs', p.place),
    ...fact('Control', h('span', { class: 'aw-mono', 'data-aw-control': '' }, p.control || '—')),
    ...fact('Directed by', p.director),
  ] : [h('dt', null, 'Folder, network'), h('dd', { class: 'muted' }, 'shown once it can be added')]));
  aw.notes.replaceChildren(...((p && p.notes) || []).map((n) => h('li', null, n)));
  aw.notes.hidden = !(p && p.notes && p.notes.length);
  aw.cmd.hidden = !aw.showCmd || !p;
  if (p) {
    aw.cmd.replaceChildren(cmdLine(p.command, { cls: 'aw-cmd-line' }),
      p.taskInFile ? h('p', { class: 'muted' }, 'The task is over 1 KiB: save it as task.txt in the folder you run the command from.') : null,
      h('p', { class: 'muted' }, 'In a terminal on this Mac. With --dry-run it shows the same plan and adds nothing.'));
  }
  aw.err.hidden = !aw.error;
  aw.err.textContent = aw.error;
  paintButtons(aw);
}

// ── Add and start: the ONE action ────────────────────────────────────────────────────────────────────────────────────
async function addAndStart(aw) {
  if (blocked(aw) || workerRefusal()) return;
  const req = request(aw);
  const body = { action: 'worker-add', ...req };
  if (aw.f.place === 'own' && aw.f.column === 'unfenced') body.confirm = 'unfenced';
  aw.busy = true;
  aw.error = '';
  paintPlan(aw);
  try {
    const end = await waitForOp(await actOrThrow(body), 240);
    if (!end) throw new Error('No answer yet — Operations shows how it ends.');
    if (end.state !== 'done') throw new Error(end.text || 'It was not added.');
    try { await loadWorkspace(aw.workspace, 0); } catch (_) { /* the next hello */ }
    addNote({ id: 'aw:' + aw.workspace, tone: 'ok', icon: 'circle-check', sticky: false, role: 'status', cls: 'toast', attrs: { 'data-aw-added': aw.workspace },
      body: [end.text, ' ', h('a', { href: agentsHash(aw.workspace) }, 'Its agents')] });
    state.aw = null;
    location.hash = workspaceHash(aw.workspace);
  } catch (e) {
    aw.busy = false;
    aw.error = e.message || String(e);
    paintPlan(aw);
    readPlan(aw);
  }
}
