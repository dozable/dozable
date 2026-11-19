// core/ws-new — The New workspace wizard's pure parts (#/new-workspace): its steps, a name suggested from the prompt's
// first words, which step a set-up gap belongs to, and the request the wizard sends — the widened `workspace-new`
// action's fields, which are also the plan route's body (`POST /api/v1/workspace-plan`). Pure: no DOM, no state, no
// imports — WebModulesTests runs it in JavaScriptCore.

/// The owner's definition, word for word (user text: a workspace is defined this way wherever it is defined).
export const WORKSPACE_DEFINITION = 'A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects). Work starts only once it is fully set up.';

/// The four steps (the mockups' S04–S07).
export const WSN_STEPS = [
  { id: 'work', title: 'The work' },
  { id: 'manager', title: 'Who manages' },
  { id: 'where', title: 'Where it runs' },
  { id: 'when', title: 'Grants & when' },
];

/// The store's rule for a workspace's name.
export const WORKSPACE_NAME = /^[a-z0-9][a-z0-9-]{0,39}$/;

/// A name from the prompt's first words: lower-case letters and digits joined by '-', at most 40, never starting or ending
/// with '-' — '' when the text has none ("A 60-second launch video for MyApp 2.0" → "a-60-second-launch-video").
export function slugFrom(text) {
  const words = String(text || '').toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .split(/[^a-z0-9]+/).filter(Boolean).slice(0, 5);
  let out = '';
  for (const w of words) {
    const next = out ? out + '-' + w : w;
    if (next.length > 40) break;
    out = next;
  }
  return out.slice(0, 40).replace(/^-+|-+$/g, '');
}

/// The step (0-based) a set-up gap is fixed in: the brief, a folder or an adopted agent → the work; the manager → who
/// manages; chat and the room → grants & when.
export function gapStep(item) {
  if (item === 'manager') return 1;
  if (item === 'chat' || item === 'room') return 3;
  return 0;
}

/// The brief as it is sent: ending with a line break (so the commands' heredoc gives the same bytes back).
export function briefText(text) {
  const t = String(text || '');
  return t === '' || t.endsWith('\n') ? t : t + '\n';
}

/// The fields sent for the wizard's choices `c` — `{name, brief, refs, folders, newFolder, fromProject, room, noRoom,
/// manager, managerIsolation, workerIsolation, network}`. Nothing is sent that the person did not choose, beyond the
/// wizard's own defaults (fenced workers, the network preset shown); the network is the project's when it fills it in.
export function requestFrom(c) {
  const r = { workspace: c.name || '', brief: briefText(c.brief) };
  if (c.refs && c.refs.length) r.refs = c.refs.slice();
  if (c.folders && c.folders.length) r.folders = c.folders.map((f) => ({ path: f.path, mode: f.mode === 'ro' ? 'ro' : 'rw' }));
  if (c.newFolder) r.newFolder = true;
  if (c.fromProject) r.fromProject = true;
  if (c.noRoom) r.noRoom = true; else if (c.room) r.room = c.room;
  if (c.manager) {
    r.manager = c.manager;
    if (c.managerIsolation) r.managerIsolation = c.managerIsolation;
  }
  if (c.workerIsolation) r.workerIsolation = c.workerIsolation;
  if (c.network && !c.fromProject) r.network = c.network;
  return r;
}
