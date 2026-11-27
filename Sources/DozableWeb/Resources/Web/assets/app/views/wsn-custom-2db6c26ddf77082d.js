// views/wsn-custom — Custom's five steps in the New workspace wizard (782): Name · Manager · Workers · How they chat ·
// Confirm. Each step offers only the choices that work together (a bot that cannot manage is folded away with its reason
// and its one fix; where the manager runs is its bot's, never asked); a finding of the plan shows under the field it is
// about, in the wizard's words; Confirm shows the findings and the one consent ("acts as me") and nothing else.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { api } from '../core/api-496fd9f39af2a514.js';
import { actOrThrow, waitForOp } from '../core/operations-d4d2df05019ab596.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { setting } from '../core/settings-1dd31ee086a35147.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { loadBots } from '../core/workspaces-07036f2cf12d8805.js';
import { BOT_NAME, NETWORKS, PROGRAM_WORDS, WHERE_WORDS, WORKER_PLACES, WSN_STEPS, findingsOf, nameProblem, nextFree } from '../core/ws-new-078b8d9bbef0201f.js';
import { btn } from '../components/button-030d384b64f8d75d.js';
import { chatOnForm } from '../components/chat-on-540e49bdb63dd24e.js';
import { choiceCard } from '../components/choice-fdde57632eb1dcb5.js';
import { pageFailure, toast } from '../components/notices-0c2ff2db323bba12.js';
import { BRIEF_MAX_BYTES } from '../components/ws-brief-e63e4f1d8c18340d.js';
import { botOf, bots, changed, chatOn, managerWhere, projectPreset, render, save } from './wsn-state-4c875b2d70b97870.js';
import { chatNavCheck } from './chat-1bb72caecfb0f256.js';

const DELIVER_WORDS = { poll: 'reached by poll', inbox: 'reached by inbox', webhook: 'reached by webhook' };
export const projectsDir = () => setting('defaults.projects_dir', '~/doz-workspaces');
export const folderFor = (name) => tildePath(projectsDir().replace(/\/$/, '') + '/' + (name || 'NAME'));
const taken = () => ((state.workspaces && state.workspaces.workspaces) || []).map((x) => x.name);
const avatar = (b) => h('span', { class: 'bot-avatar', 'aria-hidden': 'true' }, [...((b && b.avatar) || (b ? b.name : '?').charAt(0).toUpperCase())].slice(0, 2).join(''));
const whereChip = (iso) => h('span', { class: 'wz-where is-' + iso, 'data-wz-where': iso }, WHERE_WORDS[iso] || iso);
const findingLine = (f) => h('small', { class: 'wz-finding', role: 'status', 'data-wz-finding': f.field }, f.text);

/// The name's problem now: the rule, a workspace of that name, else the plan's findings about the name.
export function nameIssue(w) {
  const p = nameProblem(w.name, taken());
  if (p) return p;
  const f = findingsOf(w.plan && w.plan.findings, 'name').find((x) => x.field === 'name');
  return f ? f.text : null;
}

// ── 1 · Name ─────────────────────────────────────────────────────────────────────────────────────────────────────────
/// The name and folder fields — the template screen's too. `onName`: told as the name changes (the button's state).
export function nameAndFolder(w, onName) {
  const input = h('input', { type: 'text', name: 'workspace', autocomplete: 'off', spellcheck: 'false', maxlength: 40, 'data-wsn-name': '' });
  input.value = w.name;
  const check = h('small', { class: 'wz-check', role: 'status', 'data-wsn-name-check': '' });
  const path = h('code', { 'data-wsn-folder-path': '' }, folderFor(w.name));
  const paint = () => {
    const p = nameIssue(w);
    check.textContent = p || '';
    check.classList.toggle('is-bad', !!p);
    input.setAttribute('aria-invalid', p ? 'true' : 'false');
    path.textContent = folderFor(w.name);
  };
  paint();
  input.addEventListener('input', () => {
    w.name = input.value.trim();
    w.nameTouched = true;
    if (w.room.mode === 'new' && !w.room.touched) w.room.name = '';
    paint();
    changed(false);
    if (onName) onName();
  });
  const nf = h('input', { type: 'checkbox', 'data-wsn-new-folder': '' });
  nf.checked = !w.folder;
  nf.addEventListener('change', () => { if (nf.checked) { w.folder = null; w.newFolder = true; } else { w.newFolder = false; } changed(true); });
  let folderRow;
  if (!w.folder && w.newFolder) {
    folderRow = h('label', { class: 'wz-inline-check' }, nf, ' A new empty folder ', path);
  } else if (w.folder) {
    const ro = h('input', { type: 'checkbox', 'data-wsn-folder-ro': '' });
    ro.checked = w.folder.mode === 'ro';
    ro.addEventListener('change', () => { w.folder.mode = ro.checked ? 'ro' : 'rw'; changed(false); });
    folderRow = h('div', { class: 'wz-folder', 'data-wsn-folder': w.folder.path }, icon('folder'), h('code', null, tildePath(w.folder.path)),
      h('label', { class: 'wz-inline-check' }, ro, ' read-only'),
      btn('Change', () => chooseFolder(w), { small: true, quiet: true }),
      btn('A new empty folder', () => { w.folder = null; w.newFolder = true; changed(true); }, { small: true, quiet: true }));
  } else {
    folderRow = h('div', { class: 'wz-folder' }, h('label', { class: 'wz-inline-check' }, nf, ' A new empty folder'),
      btn('Choose a folder…', () => chooseFolder(w), { small: true, icon: 'folder-open', title: 'This Mac’s folder picker' }));
  }
  const folderFinding = findingsOf(w.plan && w.plan.findings, 'name').filter((f) => f.field === 'folder').map(findingLine);
  return [
    h('label', { class: 'field wz-name' }, h('span', null, 'Name'), input, check),
    h('div', { class: 'field wz-folders' }, h('span', null, 'Folder'), folderRow, ...folderFinding),
  ];
}
async function chooseFolder(w) {
  try {
    const r = await api('folder/choose', { method: 'POST', json: {} });
    if (r.cancelled || !r.path) return;
    w.folder = { path: r.path, mode: 'rw' };
    w.newFolder = false;
    changed(true);
  } catch (e) { pageFailure(e.message || String(e)); }
}

function stepName(w) {
  const desc = w.descOpen
    ? (() => {
      const t = h('textarea', { rows: 5, spellcheck: 'true', 'data-wsn-description': '', placeholder: 'What should the agents work on? It is posted in the room when the workspace starts — or write it later.' });
      t.value = w.description;
      t.addEventListener('input', () => { w.description = t.value; save(); });
      return h('label', { class: 'field wz-desc' }, h('span', null, 'Description (optional)'), t);
    })()
    : h('button', { type: 'button', class: 'linkish', 'data-wsn-add-description': '', on: { click: () => { w.descOpen = true; save(); render(false); } } }, '+ Add a description');
  return { body: [...nameAndFolder(w), desc], ok: () => !nameIssue(w) && new TextEncoder().encode(w.description).length <= BRIEF_MAX_BYTES };
}

// ── 2 · Manager ──────────────────────────────────────────────────────────────────────────────────────────────────────
function stepManager(w) {
  const fits = new Map(((w.plan && w.plan.managers) || []).map((m) => [m.bot, m]));
  const radio = (value, on) => {
    const i = h('input', { type: 'radio', name: 'wsn-manager', value, 'data-wsn-bot': value });
    i.checked = (w.manager || '') === value;
    i.addEventListener('change', () => { if (i.checked) { on(); w.managerPicked = true; w.actsAsYou = false; changed(true); } });
    return i;
  };
  const card = (b, iso, extra) => choiceCard({ class: 'wiz-choice' }, radio(b.name, () => { w.manager = b.name; }),
    h('span', { class: 'wz-bot-row' }, avatar(b), h('span', { class: 'wz-cc' }, h('span', { class: 'wz-cc-title' }, b.name, whereChip(iso)),
      h('span', { class: 'wz-cc-desc' }, extra))));
  const able = bots().filter((b) => fits.has(b.name) && fits.get(b.name).fits);
  // The first fitting bot is preselected, until the person picks.
  if (!w.managerPicked && !w.manager && able.length && w.plan) { w.manager = able[0].name; save(); }
  const unable = bots().filter((b) => fits.has(b.name) && !fits.get(b.name).fits);
  const list = able.map((b) => card(b, b.isolation, (PROGRAM_WORDS[b.agent] || b.agent) + ' · ' + (DELIVER_WORDS[b.deliver] || b.deliver)));
  if (w.newBot) list.unshift(card({ name: w.newBot.name }, w.newBot.isolation, (PROGRAM_WORDS[w.newBot.agent] || w.newBot.agent) + ' · made when you create the workspace'));
  const none = radio('', () => { w.manager = null; });
  const folded = unable.length ? h('details', { class: 'wz-unable', 'data-wsn-unable': String(unable.length) },
    h('summary', null, unable.length + ' more bot' + (unable.length === 1 ? '' : 's') + ' cannot manage it now'),
    h('ul', null, ...unable.map((b) => {
      const f = fits.get(b.name);
      return h('li', { 'data-wsn-unable-bot': b.name }, avatar(b), h('b', null, b.name), h('span', { class: 'muted' }, f.why),
        f.fix ? btn(f.fix.label, () => fixBot(w, b.name, f.fix), { small: true }) : null);
    }))) : null;
  return {
    body: [
      h('h2', null, 'Who manages it?'),
      h('fieldset', { class: 'wiz-choices wz-roster' }, h('legend', { class: 'sr-only' }, 'The manager'), ...list),
      folded,
      h('fieldset', { class: 'wiz-choices wz-roster' }, h('legend', { class: 'sr-only' }, 'Or'),
        choiceCard({ class: 'wiz-choice' }, none, h('span', { class: 'wz-cc' }, h('span', { class: 'wz-cc-title' }, 'No manager — I drive'),
          h('span', { class: 'wz-cc-desc' }, 'You add workers from the workspace’s page.')))),
      w.botForm ? newBotForm(w) : (w.newBot ? null : (() => {
        const b = btn('New bot', () => { w.botForm = { name: nextFree('boss', bots().map((x) => x.name)), agent: 'claude-code', isolation: 'fenced' }; render(false); }, { icon: 'plus' });
        b.dataset.wsnNewBot = '';
        return h('div', { class: 'wz-acts' }, b);
      })()),
    ],
    ok: () => true,
  };
}
async function fixBot(w, name, fix) {
  try {
    const body = fix.action === 'poll' ? { action: 'bot-set', name, deliver: 'poll' } : { action: 'bot-token', name, confirm: name };
    const end = await waitForOp(await actOrThrow(body), 60);
    if (!end || end.state !== 'done') throw new Error(end ? end.text : 'No answer yet — Operations shows how it ends.');
    toast(end.text);
    await loadBots(0);
    w.manager = name;
    changed(true);
  } catch (e) { pageFailure(e.message || String(e)); }
}

/// + New bot, inline: its name, its program, where it runs (unfenced never preselected). Made when the workspace is
/// created (nothing is made if the wizard is left); how it is reached follows where it runs.
function newBotForm(w) {
  const f = w.botForm;
  const name = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', maxlength: 40, 'data-wsn-bot-name': '' });
  name.value = f.name;
  const check = h('small', { class: 'wz-check', role: 'status' });
  const program = h('select', { 'data-wsn-bot-program': '' }, h('option', { value: 'claude-code' }, 'Claude Code'), h('option', { value: 'codex' }, 'Codex'));
  program.value = f.agent;
  program.addEventListener('change', () => { f.agent = program.value; });
  const problem = () => !BOT_NAME.test(f.name) ? 'A lower-case letter, then lower-case letters, digits and -'
    : botOf(f.name) ? f.name + ' is taken' : null;
  const make = h('button', { type: 'button', class: 'btn primary', 'data-wsn-bot-make': '' }, 'Make the bot');
  const paint = () => { const p = problem(); check.textContent = p || ''; check.classList.toggle('is-bad', !!p); make.disabled = !!p; };
  name.addEventListener('input', () => { f.name = name.value.trim(); paint(); });
  paint();
  const seg = h('div', { class: 'wz-seg', role: 'radiogroup', 'aria-label': 'Runs in' }, ...[['vm', 'Sandbox'], ['fenced', 'Fenced on this Mac'], ['unfenced', 'Unfenced — acts as you']].map(([v, l]) => {
    const b = h('button', { type: 'button', role: 'radio', 'aria-checked': f.isolation === v ? 'true' : 'false', class: f.isolation === v ? 'is-on' : null, 'data-wsn-bot-runs': v }, l);
    b.addEventListener('click', () => { f.isolation = v; render(false); });
    return b;
  }));
  make.addEventListener('click', () => {
    if (problem()) return;
    w.newBot = { name: f.name, agent: f.agent, isolation: f.isolation };
    w.botForm = null;
    w.manager = f.name;
    w.actsAsYou = false;
    changed(true);
  });
  return h('div', { class: 'wz-newbot', 'data-wsn-bot-form': '' },
    h('div', { class: 'wz-newbot-row' },
      h('label', { class: 'field' }, h('span', null, 'Bot name'), name, check),
      h('label', { class: 'field' }, h('span', null, 'Program'), program)),
    h('div', { class: 'field' }, h('span', null, 'Runs in'), seg,
      f.isolation === 'unfenced' ? h('small', { class: 'wz-warn' }, icon('triangle-alert'), 'It acts as you on this Mac — your files, keys and network.') : null),
    h('div', { class: 'wz-acts' }, make, btn('Cancel', () => { w.botForm = null; render(false); }, { quiet: true }), h('small', { class: 'muted' }, 'Kept in Agents / Bots.')));
}

// ── 3 · Workers ──────────────────────────────────────────────────────────────────────────────────────────────────────
function cards(name, list, value, pick, attr, chip) {
  return list.map(([v, title, desc]) => {
    const i = h('input', { type: 'radio', name, value });
    i.dataset[attr] = v;
    i.value = v;
    i.checked = value === v;
    i.addEventListener('change', () => { if (i.checked) pick(v); });
    return choiceCard({ class: 'wiz-choice' }, i, h('span', { class: 'wz-cc' }, h('span', { class: 'wz-cc-title' }, title, chip && chip(v)),
      h('span', { class: 'wz-cc-desc' }, desc)));
  });
}
function stepWorkers(w) {
  const pp = projectPreset(w);
  const fileChip = (v) => (pp === v ? h('span', { class: 'ws-chip', 'data-wsn-from-project': '' }, 'from doz_project.yaml') : null);
  return {
    body: [
      h('fieldset', { class: 'wiz-choices wz-row' }, h('legend', null, 'Where new workers run'),
        ...cards('wsn-wiso', WORKER_PLACES, w.workerIsolation, (v) => { w.workerIsolation = v; changed(true); }, 'wsnWiso')),
      h('fieldset', { class: 'wiz-choices wz-row3' }, h('legend', null, 'What they may reach'),
        ...cards('wsn-net', NETWORKS, w.network, (v) => { w.network = v; w.netPicked = v !== pp; changed(true); }, 'wsnNet', fileChip)),
    ],
    ok: () => true,
  };
}

// ── 4 · How they chat ────────────────────────────────────────────────────────────────────────────────────────────────
function stepChat(w) {
  const hasManager = !!w.manager;
  // While chat is off here, the step watches chat's state itself (whoever turns it on — this button, another tab, a terminal,
  // or a page drawn again from its kept choices) and is drawn again, the plan asked again, when it changes.
  if (!chatOn()) watchChat(w);
  if (!chatOn() && w.chatStarting) {
    return { body: [h('p', { class: 'wz-starting', 'data-wsn-chat-starting': '' }, icon('hourglass'), 'Starting chat…')], ok: () => false };
  }
  if (!chatOn()) {
    return {
      body: [h('p', { 'data-wsn-chat-off': '' }, 'Chat is off. A manager and its workers talk in a room, so chat comes on with this workspace.'),
        chatOnForm({ onOn: async () => { w.chatStarting = true; await chatNavCheck(); changed(true); chatComing(w); } })],
      ok: () => !hasManager,
    };
  }
  const f = findingsOf(w.plan && w.plan.findings, 'chat');
  const roomName = w.room.mode === 'new' ? (w.room.name || w.name) : w.room.name;
  let field;
  if (w.room.mode === 'existing') {
    const sel = h('select', { 'data-wsn-room-existing': '', 'aria-label': 'An existing room' }, ...(w.rooms || []).map((r) => h('option', { value: r }, '#' + r)));
    if (!w.room.name && w.rooms && w.rooms[0]) w.room.name = w.rooms[0];
    sel.value = w.room.name;
    sel.addEventListener('change', () => { w.room.name = sel.value; changed(true); });
    field = [sel, h('button', { type: 'button', class: 'linkish', on: { click: () => { w.room = { mode: 'new', name: '' }; changed(true); } } }, 'Make a new room')];
  } else if (w.room.mode === 'none') {
    field = [h('p', { 'data-wsn-room': 'none' }, 'No room.'), h('button', { type: 'button', class: 'linkish', on: { click: () => { w.room = { mode: 'new', name: '' }; changed(true); } } }, 'Make a room')];
  } else {
    const input = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', maxlength: 40, 'data-wsn-room': '' });
    input.value = roomName;
    input.addEventListener('input', () => { w.room.name = input.value.replace(/^#/, '').trim(); w.room.touched = true; changed(false); });
    field = [h('div', { class: 'wz-hash' }, h('span', { 'aria-hidden': 'true' }, '#'), input),
      h('small', { class: 'muted' }, h('button', { type: 'button', class: 'linkish', 'data-wsn-room-use': '', on: { click: () => { w.room = { mode: 'existing', name: '' }; changed(true); } } }, 'Use a room I have'),
        // No room only with no manager: a manager needs a room.
        !hasManager ? [' · ', h('button', { type: 'button', class: 'linkish', 'data-wsn-room-none': '', on: { click: () => { w.room = { mode: 'none', name: '' }; w.invite = []; changed(true); } } }, 'No room')] : null,
        ' · Its history stays; archiving the workspace makes it read-only.')];
  }
  const roomFindings = f.filter((x) => x.field === 'room').map((x) => h('small', { class: 'wz-finding', role: 'status' }, x.text,
    x.fix && x.fix.action === 'use-room' ? h('button', { type: 'button', class: 'linkish', on: { click: () => { w.room = { mode: 'existing', name: roomName }; changed(true); } } }, ' ' + x.fix.label) : null));
  const mb = w.manager ? (botOf(w.manager) || (w.newBot && w.newBot.name === w.manager ? { name: w.manager, deliver: w.newBot.isolation === 'unfenced' && w.newBot.agent === 'claude-code' ? 'inbox' : 'poll' } : null)) : null;
  const member = (av, n, what) => h('li', { class: 'wz-member' }, av, h('b', null, n), h('span', { class: 'muted' }, what));
  const others = bots().filter((b) => b.name !== w.manager && b.isolation !== 'elsewhere');
  const chips = others.map((b) => {
    const on = w.invite.includes(b.name);
    return h('button', { type: 'button', class: 'wz-chip' + (on ? ' is-on' : ''), 'aria-pressed': on ? 'true' : 'false', 'data-wsn-invite': b.name,
      on: { click: () => { w.invite = on ? w.invite.filter((x) => x !== b.name) : [...w.invite, b.name]; changed(true); } } }, avatar(b), b.name, h('span', { class: 'muted' }, 'bot'));
  });
  return {
    body: [
      h('div', { class: 'field wz-room' }, h('span', null, 'Room'), ...field, ...roomFindings),
      w.room.mode === 'none' ? null : h('div', { class: 'field' }, h('span', null, 'In the room'), h('ul', { class: 'wz-members' },
        member(avatar({ name: state.chat && state.chat.me ? state.chat.me : 'you' }), 'you', 'reads and writes' + (w.description.trim() ? '; the description is posted as your first message' : '')),
        mb ? member(avatar(mb), mb.name, 'manager · ' + (DELIVER_WORDS[mb.deliver] || 'reached by poll')) : null,
        member(h('span', { class: 'bot-avatar', 'aria-hidden': 'true' }, '+'), 'every worker', 'joins when it starts · reads the room with dozchat'))),
      w.room.mode === 'none' || !others.length ? null : h('div', { class: 'field' }, h('span', null, 'Also invite ', h('span', { class: 'muted' }, '(optional)')), h('div', { class: 'wz-chips' }, ...chips)),
      ...f.filter((x) => x.field !== 'room').map(findingLine),
    ],
    ok: () => !f.some((x) => x.field === 'chat') && !(w.room.mode === 'existing' && !w.room.name),
  };
}

/// One watcher at a time: every second while the wizard shows How they chat with chat off, the chat status is read again;
/// when chat comes on the plan is asked again and the step drawn.
let watching = null;
function watchChat(w) {
  if (watching === w) return;
  watching = w;
  const tick = async () => {
    if (state.wsn !== w || state.modal !== 'new-workspace' || w.screen !== 'custom' || w.step !== 3) { watching = null; return; }
    await chatNavCheck();
    if (chatOn()) { watching = null; changed(true); chatComing(w); return; }
    setTimeout(tick, 1000);
  };
  setTimeout(tick, 1000);
}

/// Chat just turned on (its operation is done): the dashboard's chat status and the daemon's plan can still say off for a
/// while. Both are read again every second — the step drawn each time chat's state changes — until chat is on AND the plan
/// says so, while the wizard stays on this step (at most 3 minutes). Until then the step says "Starting chat…", Next off.
function chatComing(w) {
  let n = 0, wasOn = chatOn();
  const again = async () => {
    if (state.wsn !== w || w.screen !== 'custom' || w.step !== 3 || n++ > 180) { if (state.wsn === w) w.chatStarting = false; return; }
    await chatNavCheck();
    const on = chatOn(), planOn = !findingsOf(w.plan && w.plan.findings, 'chat').some((f) => f.field === 'chat');
    if (on && planOn) { w.chatStarting = false; render(false); return; }
    changed(on !== wasOn);              // the plan asked again; drawn when chat's state changed
    wasOn = on;
    setTimeout(again, 1000);
  };
  setTimeout(again, 1000);
}

// ── 5 · Confirm ──────────────────────────────────────────────────────────────────────────────────────────────────────
/// Whether the chosen manager acts as you (its bot runs unfenced).
export const actsAsYouNeeded = (w) => managerWhere(w) === 'unfenced';
function stepConfirm(w, go) {
  const all = (w.plan && w.plan.findings) || [];
  const stepOf = (id) => Math.max(0, WSN_STEPS.findIndex((s) => s.id === id));
  const rows = all.map((f) => h('li', { class: 'wz-find', 'data-wsn-finding': f.step }, icon('triangle-alert'), h('span', null, f.text),
    f.step !== 'confirm' ? h('button', { type: 'button', class: 'linkish', on: { click: () => go(stepOf(f.step)) } }, 'Change') : null));
  const acts = actsAsYouNeeded(w) ? (() => {
    const tick = h('input', { type: 'checkbox', 'data-wsn-acts-as-you': '' });
    tick.checked = !!w.actsAsYou;
    tick.addEventListener('change', () => { w.actsAsYou = tick.checked; save(); });
    return h('div', { class: 'wz-acts-as-you', 'data-wsn-acts': w.manager },
      h('p', null, icon('triangle-alert'), w.manager + ' runs unfenced: it acts as you on this Mac — your files, keys and network.'),
      h('label', { class: 'wz-inline-check' }, tick, ' Yes, ' + w.manager + ' acts as me'));
  })() : null;
  const ok = !rows.length && !w.planError;
  return {
    body: [
      ok ? h('p', { class: 'wz-ok', 'data-wsn-ok': '' }, icon('circle-check'), 'Everything checks out. It can start as soon as it is made.')
        : h('ul', { class: 'wz-finds', 'data-wsn-findings': String(rows.length) }, ...rows, w.planError ? h('li', { class: 'wz-find' }, w.planError) : null),
      acts,
    ],
    ok: () => ok && (!actsAsYouNeeded(w) || w.actsAsYou),
  };
}

/// The step's body and whether it may go on.
export function customStep(w, go) {
  return [stepName, stepManager, stepWorkers, stepChat, (x) => stepConfirm(x, go)][w.step](w);
}
