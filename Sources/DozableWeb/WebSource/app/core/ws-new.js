// core/ws-new — The New workspace wizard's pure parts (#/new-workspace): Custom's five steps, the name rule, the request
// each path sends (`workspace-new`, `workspace-from-template` — the plan route takes the first's fields), the drawing of the
// workspace as chosen so far (the renderer's words, the same the dashboard's pictures read), and the next free names.
// Pure: no DOM, no state, no imports — WebModulesTests runs it in JavaScriptCore.

/// The owner's definition, word for word (user text: a workspace is defined this way wherever it is defined).
export const WORKSPACE_DEFINITION = 'A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects). Work starts only once it is fully set up.';

/// Custom's five steps; each finding of the plan names one of their ids (`step`).
export const WSN_STEPS = [
  { id: 'name', title: 'Name' },
  { id: 'manager', title: 'Manager' },
  { id: 'workers', title: 'Workers' },
  { id: 'chat', title: 'How they chat' },
  { id: 'confirm', title: 'Confirm' },
];

/// The store's rule for a workspace's name (and so a room's made for it).
export const WORKSPACE_NAME = /^[a-z0-9][a-z0-9-]{0,39}$/;
/// A bot's name in chat.
export const BOT_NAME = /^[a-z][a-z0-9-]{0,39}$/;

/// What runs where, as a person reads it.
export const WHERE_WORDS = { vm: 'Sandbox', sandbox: 'Sandbox', fenced: 'Fenced on this Mac', unfenced: 'Unfenced — acts as you', elsewhere: 'Another machine' };
export const PROGRAM_WORDS = { 'claude-code': 'Claude Code', codex: 'Codex' };
export const NETWORKS = [
  ['locked', 'Locked', 'Its AI model only, and the room.'],
  ['standard', 'Standard', 'Its model, GitHub, package registries, error reports and the room.'],
  ['open', 'Open', 'Any site, every connection logged.'],
];
export const WORKER_PLACES = [
  ['fenced', 'Fenced on this Mac', 'On this Mac behind the fence: the folder writable, your keychain closed. Mac tools like Xcode work.'],
  ['vm', 'Sandbox', 'A small Linux machine of its own: the folder is all of your Mac it sees.'],
];

/// The name's problem as the person types (null: none) — the rule, then a workspace of that name.
export function nameProblem(name, taken) {
  if (!name) return 'Give it a name';
  if (!WORKSPACE_NAME.test(name)) return '1–40 characters of a-z, 0-9 and -, not starting with -';
  if ((taken || []).includes(name)) return name + ' is taken';
  return null;
}

/// The first `prefix`N (N ≥ 1) not in `taken`.
export function nextFree(prefix, taken) {
  const t = new Set(taken || []);
  for (let n = 1; n < 100000; n++) if (!t.has(prefix + n)) return prefix + n;
  return prefix;
}

/// The description as sent: '' when blank, else ending with a line break.
export function descriptionText(text) {
  const t = String(text || '');
  if (!t.trim()) return '';
  return t.endsWith('\n') ? t : t + '\n';
}

/// Custom's request — `workspace-new`'s fields (and the plan route's body) for the choices `c`: {name, description,
/// newFolder, folder: {path, mode}|null, manager (a bot that exists) and its isolation, workerIsolation, network or
/// fromProject, room: {mode: 'new'|'existing'|'none', name}, invite}. The manager runs where its bot runs, always.
export function requestFrom(c) {
  const r = { workspace: c.name || '' };
  const d = descriptionText(c.description);
  if (d) r.brief = d;
  if (c.folder && c.folder.path) r.folders = [{ path: c.folder.path, mode: c.folder.mode === 'ro' ? 'ro' : 'rw' }];
  else if (c.newFolder) r.newFolder = true;
  if (c.fromProject) r.fromProject = true;
  else if (c.network) r.network = c.network;
  if (c.manager) {
    r.manager = c.manager;
    if (c.managerIsolation) r.managerIsolation = c.managerIsolation;
  }
  if (c.workerIsolation) r.workerIsolation = c.workerIsolation;
  const room = c.room || { mode: 'new' };
  if (room.mode === 'none') r.noRoom = true;
  else if (room.mode === 'existing' && room.name) r.room = room.name;
  else if (room.name && room.name !== c.name) r.roomName = room.name;
  if (room.mode !== 'none' && c.invite && c.invite.length) r.invite = c.invite.slice();
  return r;
}

/// A template's request — `workspace-from-template`'s fields.
export function templateRequestFrom(c) {
  const r = { template: c.template, workspace: c.name || '' };
  if (c.folder && c.folder.path) r.folder = c.folder.path;
  if (c.manager) r.manager = c.manager;
  if (c.actsAsYou) r.actsAsYou = true;
  return r;
}

/// One agent of the drawing in the renderer's words: on this Mac (fenced or unfenced) or in the Sandbox `box`.
function placed(where, role) {
  if (where === 'vm' || where === 'sandbox') return { kind: 'claude-code', role, where: 'sandbox:box' };
  return { kind: 'claude-code', role, where: 'mac', isolation: where === 'unfenced' ? 'unfenced' : 'fenced' };
}

/// The workspace as chosen so far, drawn (Custom's header): the manager where its bot runs, the "new workers" stand-in where
/// new workers will run, the room and anyone invited. In the renderer's words: its version line, then each key in JSON.
export function pictureText(c) {
  const space = WORKSPACE_NAME.test(c.name || '') ? c.name : 'workspace';
  const agents = {};
  let box = false;
  if (c.managerWhere) {
    agents[c.managerName || 'manager'] = placed(c.managerWhere, 'manager');
    box = box || c.managerWhere === 'vm';
  }
  agents['new-workers'] = placed(c.workerIsolation || 'fenced', 'worker');
  box = box || c.workerIsolation === 'vm';
  const room = c.room && c.room.mode === 'existing' && c.room.name ? c.room.name : c.room && c.room.name ? c.room.name : space;
  const members = ['owner', ...Object.keys(agents)];
  for (const i of c.invite || []) {
    if (agents[i] || !BOT_NAME.test(i)) continue;
    agents[i] = { external: { bot: i } };
    members.push(i);
  }
  const doc = { space, owner: 'you', agents };
  if (box) doc.sandboxes = { box: {} };
  if (!c.room || c.room.mode !== 'none') doc.chat = { rooms: { [WORKSPACE_NAME.test(room) ? room : space]: { main: true, members } } };
  return 'doz: space/3.1\n' + Object.keys(doc).map((k) => JSON.stringify(k) + ': ' + JSON.stringify(doc[k])).join('\n') + '\n';
}

/// The findings of one step (`step`: an id of WSN_STEPS; 'name' also takes the folder's).
export function findingsOf(findings, step) {
  return (findings || []).filter((f) => f.step === step);
}

/// The note a made workspace gets, from its row as read just after: one whose agent already stopped in error (it waits on
/// you) is never said "started" — the room says why. [line, tone].
export function madeNote(name, line, tone, row) {
  if (tone === 'ok' && row && row.state === 'waiting-on-you') return [name + ' is made but waits on you — its room says why', 'warn'];
  return [line, tone];
}
/// A template's agents in the full view's words: [name, role words, where words].
export function templateAgentWords(a) {
  const role = a.where === 'manager' ? 'manager — your bot, where it runs' : a.readOnly ? a.role + ' — reads only' : a.role;
  return [a.name, role, a.where === 'manager' ? null : WHERE_WORDS[a.where] || a.where];
}
