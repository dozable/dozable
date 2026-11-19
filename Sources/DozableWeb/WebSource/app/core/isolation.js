// core/isolation — Where an agent runs, in words: the four choices in order of isolation (micro VM, fenced on this Mac,
// unfenced on this Mac, elsewhere) and the cloud column drawn as later. ONE module of words, read by the isolation guide
// (views/isolation-guide.js, #/guide/isolation[/ID]) and the Add a worker page's comparison table (views/add-worker.js).
// Pure: imports nothing. `control` is exactly `doz worker ls`'s CONTROL (WorkerLaunch.control — a test holds them equal).

/// The four choices, in order of isolation. `chip`: the word an isolation chip shows; `rows`: the comparison table's cells.
export const ISOLATIONS = [
  {
    id: 'vm', chip: 'micro VM', title: 'micro VM', place: 'this Mac',
    what: 'A separate small Linux machine. Your folder appears inside; everything else of your Mac does not exist for it. It starts in a moment and sleeps with its programs kept.',
    for: 'Almost every worker — several Claude Code sessions on a video project, a render that hibernates overnight.',
    notFor: 'Xcode, the Simulator, Mac-only tools.',
    figure: ['your Mac', 'Linux VM', 'agent · /workspace', 'no network card'],
    control: 'micro VM · proxy · placeholders',
    rows: { place: 'this Mac', files: 'its folders only', network: 'through the proxy, by its permissions', keys: 'placeholders',
      cost: 'about 1 GB while it runs; nothing asleep', macTools: 'no', sleeps: 'yes', approvals: 'off — the VM is the boundary', manager: 'later, by its grants' },
    commands: [['doz worker add W --task "…" --isolation vm', 'a worker in a micro VM of its own'], ['doz create NAME --dry-run', 'a sandbox: what it would be and reach']],
  },
  {
    id: 'fenced', chip: 'fenced', title: 'fenced on this Mac', place: 'this Mac',
    what: 'macOS’s own sandbox around one program: its project folder, its own temp and caches, the network through the proxy; your Keychain and other folders closed.',
    for: 'Managers, and Mac and iOS builds — xcodebuild test with packages from GitHub, the project writable and nothing else.',
    notFor: 'Signing and notarising (they need your Keychain), Java.',
    figure: ['your Mac', 'macOS sandbox', 'agent · its folder', 'keychain closed'],
    control: 'proxy · placeholders · guard',
    rows: { place: 'this Mac', files: 'its folders; reads your tools', network: 'through the proxy, by its permissions', keys: 'placeholders',
      cost: 'a process', macTools: 'yes', sleeps: 'resumes its conversation', approvals: 'yours to give, narrow', manager: 'later, by its grants' },
    commands: [['doz worker add W --task "…"', 'a worker, fenced (the default)'], ['doz run @mac --dry-run --xcode -- claude', 'what a fenced build session could do']],
  },
  {
    id: 'unfenced', chip: 'unfenced', title: 'unfenced on this Mac', place: 'this Mac',
    what: 'No isolation: your files, Keychain and network, as if you typed it. Its screen is still held, watched and logged in the room.',
    for: 'Looking after this Mac itself — launch agents, disk space, Homebrew, logs.',
    notFor: 'Anything a fence or a micro VM can do. It always asks you, and is never a default.',
    figure: ['your Mac', '', 'agent, as you —', 'no boundary'],
    control: 'no proxy · no placeholders · no guard · acts as you',
    rows: { place: 'this Mac', files: 'everything', network: 'yours, not limited', keys: 'your real ones',
      cost: 'nothing but the risk', macTools: 'yes', sleeps: 'no', approvals: 'yours to give', manager: '✕ always asks you' },
    commands: [['doz worker add W --task "…" --isolation unfenced', 'a worker that acts as you'], ['doz run @mac --unfenced --session admin -- claude', 'a session with no isolation at all']],
  },
  {
    id: 'elsewhere', chip: 'elsewhere', title: 'elsewhere', place: 'another machine',
    what: 'An agent on another machine (over Tailscale, say) or a webhook bot. It joins the rooms with its own token and is never you. It is not isolated by Dozable: Dozable does not hold, start or watch it.',
    for: 'A bot you already run.',
    notFor: 'A worker Dozable starts — that is one of the three above.',
    figure: ['this Mac', 'another', 'token', ''],
    control: 'not run by Dozable · token only',
    rows: null,
    commands: [['doz bot new NAME --agent codex --isolation elsewhere --to-file ~/NAME.token', 'its token, once, in a file for that machine']],
  },
];

/// The comparison table's rows (the Add a worker page): [key, label].
export const COMPARE_ROWS = [
  ['place', 'place'], ['files', 'your files'], ['network', 'network'], ['keys', 'keys'], ['control', 'control it gets'], ['cost', 'cost'],
  ['macTools', 'Mac tools (Xcode)'], ['sleeps', 'sleeps with programs kept'], ['approvals', 'approval prompts'], ['manager', 'manager may choose it'],
];

/// The cloud column: drawn, never chosen.
export const CLOUD = { id: 'cloud', chip: 'cloud', title: 'cloud', later: true,
  rows: { place: 'cloud — later', files: 'as micro VM', network: 'as micro VM', keys: 'as micro VM', control: 'as micro VM', cost: 'billed (later)',
    macTools: 'as micro VM', sleeps: 'as micro VM', approvals: 'as micro VM', manager: 'later' } };

/// Whatever the choice, keys never go inside — the guide's closing line.
export const KEYS_NEVER_INSIDE = 'Whatever the choice, your keys never go inside a micro VM or a fenced session — the proxy swaps a placeholder for the real key on the way out. An unfenced agent is the one exception, and the reason it always asks.';

/// One choice by its id (`vm`, `fenced`, `unfenced`, `elsewhere`), or null.
export function isolationById(id) { return ISOLATIONS.find((x) => x.id === id) || null; }

/// The choice an isolation chip's word names (`micro VM` → vm; `fenced`, `unfenced`, `elsewhere`; a recorded `vm` too), or
/// null for a word that names none (an adopted session with no isolation recorded: "on this Mac").
export function isolationIdOf(word) {
  if (word === 'micro VM' || word === 'vm') return 'vm';
  return ['fenced', 'unfenced', 'elsewhere'].includes(word) ? word : null;
}

/// A cell of the comparison table for a choice and a row key.
export function compareCell(choice, key) {
  if (key === 'control') return choice.later ? choice.rows.control : choice.control;
  return choice.rows ? choice.rows[key] : '';
}
