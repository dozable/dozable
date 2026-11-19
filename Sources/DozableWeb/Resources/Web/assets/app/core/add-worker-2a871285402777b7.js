// core/add-worker — The Add a worker page's pure parts (views/add-worker.js, #/w/NAME/agents/new): the request its form
// sends (the plan route's body and the `worker-add` action's fields — exactly what `doz worker add` takes), the column of
// the comparison table chosen before the person picks (never unfenced), the page's field a refusal is shown beside, and
// whether the body fits the actions' 16 KiB. Pure: imports nothing.

/// The longest task the page sends (the server's `WebWorkerAdd.maximumTaskBytes`): beyond it, the command with the task in
/// a file. The actions' body stays within 16 KiB.
export const TASK_MAX_BYTES = 15 * 1024;
export const BODY_MAX_BYTES = 16 * 1024 - 64;
/// What a fenced Claude Code worker may always do without asking (WorkerLaunch.defaultAllowedTools).
export const FIXED_TOOLS = ['Bash(dozchat:*)'];
/// The agent programs a worker runs today; the others are drawn, greyed.
export const WORKER_AGENTS = [['claude-code', 'Claude Code'], ['codex', 'Codex']];
export const LATER_AGENTS = ['Grok Build', 'OpenCode', 'Local model'];
/// The tick an unfenced worker needs (the action's `confirm`).
export const UNFENCED_TICK = 'It acts as you: your files, Keychain and network';

/// The column chosen before the person picks: micro VM when the workspace's default or the bot's is vm, else fenced —
/// never unfenced, whatever a default says.
export function defaultColumn(workspaceDefault, botDefault) {
  return workspaceDefault === 'vm' || botDefault === 'vm' ? 'vm' : 'fenced';
}

/// The request from the form `f`: {workspace, task, name, who: 'anon'|'bot', bot, agent, place: 'own'|SANDBOX, column,
/// picked (the person chose the column), cpus, memory, rooms: [labels], tools: [rules]}. Only what differs from the CLI's
/// own default is sent, so the command reads as a person would type it.
export function workerRequestFrom(f) {
  const r = { workspace: f.workspace, task: f.task || '' };
  const name = (f.name || '').trim();
  if (f.who === 'bot' && f.bot) r.fromBot = f.bot;
  else if (name) r.name = name;
  if (f.who !== 'bot' && f.agent && f.agent !== 'claude-code') r.agent = f.agent;
  const own = !f.place || f.place === 'own';
  if (!own) r.sandbox = f.place;
  if (own && f.picked && f.column && f.column !== 'cloud') r.isolation = f.column;
  if (own && f.column === 'vm') {
    const c = parseInt(f.cpus, 10);
    if (String(f.cpus || '').trim() && c > 0) r.cpus = c;
    if (String(f.memory || '').trim()) r.memory = String(f.memory).trim();
  }
  const rooms = (f.rooms || []).filter(Boolean);
  if (rooms.length) r.rooms = rooms;
  const tools = (f.tools || []).map((t) => String(t).trim()).filter((t) => t && !FIXED_TOOLS.includes(t));
  if (tools.length && own && f.column === 'fenced' && (f.who === 'bot' || !f.agent || f.agent === 'claude-code')) r.allowTools = tools;
  return r;
}

/// The page's field a refusal (the plan's `problem.field`) is shown beside; anything about the workspace or chat at the top.
export function fieldSlot(field) {
  switch (field) {
    case 'task': return 'task';
    case 'name': return 'name';
    case 'agent': return 'agent';
    case 'fromBot': return 'who';
    case 'rooms': return 'rooms';
    case 'sandbox': return 'in';
    case 'isolation': case 'session': return 'where';
    case 'cpus': case 'memory': return 'size';
    case 'allowTools': return 'tools';
    default: return 'top';
  }
}

/// The bytes of a string as UTF-8, without TextEncoder (a pure module).
export function utf8Length(s) {
  let n = 0;
  for (const ch of String(s)) { const c = ch.codePointAt(0); n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4; }
  return n;
}

/// Whether the task and the whole body fit what the page sends (else: the command, with the task in a file).
export function fits(request) {
  return utf8Length(request.task || '') <= TASK_MAX_BYTES && utf8Length(JSON.stringify({ action: 'worker-add', ...request, confirm: 'unfenced' })) <= BODY_MAX_BYTES;
}
