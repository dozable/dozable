// dashboard-walk.mjs — the dashboard's shell walked in a real headless Chrome (`make dashboard-walk`).
//
// Against `doz ui` on a SCRATCH store it checks what a machine can of the sidebar, Home, This Mac, Loose agents and
// Agents / Bots:
//   · Home with no workspace: the definition of a workspace, and how many sandboxes are in none;
//   · then `demo` (one sandbox adopted) and a bot: Home's row reads "setting up" and "you";
//   · the sidebar's parts in order — Home, Needs you (hidden), Chat (hidden: chat is off), Agents / Bots, Workspaces,
//     This Mac — and `demo` unfolding to its agent, which links to its screen in the workspace;
//   · every old address lands on its canonical one and its view, with something on the page, no page error and no
//     "could not be read"; every link of This Mac opens its page;
//   · On this Mac, Remove: three ended sessions, one running and an ended one filed in `demo` — Remove… on each ended tile
//     only (not the running one or the workspace's), Remove on one, then Remove all ended… (its dialog names the two left)
//     → no ended tile is left to remove; the leak sweep after;
//   · Loose agents and Agents / Bots list exactly what `doz workspace ls --loose --json` and `doz bot ls --json` do;
//   · Your Macs (the machine picker): a second scratch store runs a `doz ui` named `mini` on an OS-chosen port; `doz ui
//     macs add` keeps it (checked) and `air` (a closed port, --no-check); the brand button reads "Dozable · walkmac", Enter
//     opens the menu — this Mac, mini "seen", air "never checked" — whose links are exactly each origin and / in a new tab
//     (noopener noreferrer); following mini opens a tab with no #, ? or cap whose /api/v1/session answers 401 (that Mac's
//     own sign-in), and this page made no request to it; Escape gives the focus back; #/mac/macs lists what `doz ui macs ls
//     --json` does; at 390 px the top bar's name opens the same list;
//   · a workspace's page, with chat ON (its two ports the OS's choice, checked not live): `demo2` with a brief, a
//     reference, a folder, the adopted never-booted sandbox `beta`, an unrelated room `other`, started (no manager: you
//     drive — the brief is the kick-off). #/w/demo2/room → view `workspace`, the brief open with its text; the tabs in the
//     mockups' order, Home, Room and Agents enabled, "Permissions" from its constant; the kick-off bubble and a "started the work"
//     line in time order; Edit → Save posts the announcement bubble, adds "edited the work", History shows one edit; the
//     room strip lacks `other`, #/w/demo2/room/other opens the main room with the line saying so; #/chat still lists
//     `other` and there is exactly one #chat-text; the side panel is `doz workspace show demo2 --json`; an unfenced manager
//     (`demo3`) shows "acts as you"; the sidebar and Home lead to #/w/demo2; `interleave` against fixtures; at 390 px the
//     panel folds below the room;
//   · a workspace's agents, chat still on: #/w/demo2/agents lists exactly the agents of `doz workspace show demo2 --json`
//     with their chips, the greyed cloud row and Grid disabled; demo3's unfenced manager reads "acts as you"; from Loose
//     agents "Put in a workspace…" files gamma into demo (it leaves the loose list and joins demo's table; demo stays
//     setting up; its log says "adopted gamma") and a new sandbox delta into a NEW workspace (its name prefilled; its room
//     made; Home lists it); a harmless session on this Mac (/bin/sleep, unfenced, its holder deckhold-mac) filed into a
//     workspace that is setting up turns it started with nothing posted; #/w/demo/agent/gamma opens the sandbox's page
//     framed and a tab's switch keeps the #/w/ address; #/sandbox/gamma says "In demo"; "Take out…" makes gamma loose
//     again; at 390 px the table is cards. (Another computer's 403 for the three filing actions is ServeHTTPTests': the
//     walk's dashboard has no LAN side — its fixed port is a live one.)
//   · Agents / Bots, chat still on: far (elsewhere), tmp1 and the participant olda made with the CLI (their tokens read from
//     their files, never printed). 1 the roster equals doz bot ls --json (keeper, isolation); 2 #/bots/~new makes nova
//     (fenced by default, unfenced not preselected, elsewhere disabled with its command) and its fingerprint is the CLI's;
//     3 an instructions edit changes the CLI's sha256; 4 a crafted bot-new elsewhere is 400 and a crafted bot-token for far
//     is refused by the daemon (heldOnly), its fingerprint unchanged; 5 New token… changes nova's fingerprint; 6 adopting
//     olda (Q9's words) makes it a bot and its old token 401; 7 retire tmp1 (Show retired), retiring otto — a manager — is
//     refused with the release command; 8 Include in a room… puts otto in other, no token step. After every row the leak
//     sweep: the known tokens and dzc_ in the DOM, every /api/ answer, the console, page errors, both storages,
//     CacheStorage, IndexedDB, ui.operations.json, ui.log and doz ui's output, daemon.log, server.log and ps — zero, with a
//     positive control; no page error on any bot screen. (Another computer's 403 is ServeHTTPTests'.)
//   · the New workspace wizard, chat still on, a FAKE claude first on DOZ_TEST_MAC_PATH (no manager is started): 1 Home's New
//     workspace opens #/new-workspace over Home; 2 an empty prompt shows the brief's gap, counted on step 1, typing clears it,
//     the name suggested; 3 a typed folder and a :ro one; 4 the main folder's doz_project.yaml (network: open) fills in Open,
//     never written; 5 the stepper's count follows; 6 No manager, Right now, Create and start → show --json matches the
//     review, the kick-off bubble and "started the work"; 7 the copied commands are doz workspace new … --dry-run's; 8 mira,
//     Later → setting up, manager mira fenced, nothing posted, the banner's gaps live (a folder removed on disk adds one); 9
//     unfenced asks for the confirmation and the review says "acts as you"; 10 "+ A new agent / bot…" and back, the choices
//     intact; 11 ?bot=mira chooses her; 13 at 390 px the choices stack; 14 (below) with the daemon stopped it opens and the
//     plan answers. (Another computer's 403 for both actions and the plan route is ServeHTTPTests'.)
//   · Add a worker, chat still on, the FAKE claude (it reads START, says "NAME is up" with dozchat, sleeps), a scratch fence
//     home: 1 the Agents tab's + Add a worker opens #/w/demo2/agents/new — four columns, cloud disabled, fenced preselected,
//     the control row worker ls's words; 2 the live plan (as --dry-run's), micro VM shows its size, unfenced needs the tick
//     (never added); 3 a bot live elsewhere greyed with the sentence, a taken name's refusal beside the name, worker ls
//     unchanged; 4 Show the command is --dry-run's; 5 Add and start: in the panel, chat who, its "is up" line; 6 End…, ticked;
//     7 a chip opens the isolation guide at its card, four cards in order; 9 at 390 px the cards stack; 10 (below) with the
//     daemon stopped the page opens and the plan answers. (8, another computer's 403, is ServeHTTPTests'.)
//   · a workspace's lifecycle, chat still on: `life` (a brief, a scratch folder, an adopted unfenced session on this Mac
//     running /bin/sleep), started. 1 Sleep is the primary button and its dialog's table is `doz workspace sleep life
//     --dry-run --json`'s (the same rows and sha); at 390 px the table is cards; 2 Sleep → asleep, Home folds it into
//     "Asleep (1)" with its Wake; 3 Wake (Home's button) → awake, the session running again; 4 Finish… a plain
//     confirmation → finished, the composer still takes a post; 5 Reopen → asleep; 6 Archive… needs the name typed (a wrong
//     name keeps the button off; a crafted action with another name is 400), then the room's archived notice; 7 Restore →
//     finished; 8 Delete… with the Bin box unticked → gone from Home and the sidebar, its folder still on disk; 9 another
//     computer's 403 is ServeHTTPTests'; 11 (below) with the daemon stopped the plan route answers. The leak sweep after.
//   · the workspace drawn, chat still on: the first load (Home with only plain workspaces) fetches no renderer byte and
//     shows a plain tile, its bytes printed, the two glue modules at most 16 KB; `spc2` brought up from a space file (a
//     fenced worker running the FAKE claude) — Home and the unfolded sidebar show one thumbnail per space workspace and a
//     tile for each plain one (none in the sidebar), the renderer fetched once; #/w/spc2's hero draws, named; down → after
//     `changed` the hero's key and state sha change; 3 s without an event reads no state; the hero is a link to its
//     space editor; dark → a new key, light again → a cache hit; at 390 px the hero fits;
//     under reduced motion the hero has no animation; a toast does not cover the hero's drawing; a file that doesn't read → the marker and Dozable's problem line;
//     no CSP violation (a listener from every document's start); the leak sweep; pictures to SHOTS (the page light, dark, 390 px
//     and with a toast; Home light and 390 px; the sidebar with spc2 unfolded).
//   · the space editor's page, chat still on: `spc3` up from a space file that extends a defaults file (a fenced worker on the
//     FAKE claude that reports itself blocked; an unused sentinel in the .env beside it); 1 nothing of the editor fetched
//     before its page, its glue at most 16 KB; 2 the hero is a link to #/w/spc3/space, the page the whole window, a reload opens
//     it again; 3 the canvas draws, the core and canvas/edit/plan/live/motion fetched once, never Monaco, text, sim or timeline;
//     8 Live on (kept), 3 s without an event reads no state, the agent's "blocked" drawn after an event; 4 Text loads Monaco
//     then and only then; 5 typing → Unsaved, the leave guard (Stay), ⌘S saves (the file's sha is show --space's), "Not
//     applied"; 6 a stale save → "Changed elsewhere", nothing written, Reload; 7 a typo listed, a defaults file's problem
//     named; 9 a bot's Ask drawn and answered from it (chat-decide done); 11 watch; 13 390 px canvas only; 14 ? opens the
//     editor's keys, Escape stays, three visits leave no editor and no listener more; 12 another computer (its read rewritten
//     to canSave false): read-only, the command, no edit fetched; 10 after down the runs strip reads a run's frames; 15 no CSP
//     violation; 16 the leak sweep. Pictures: space-editor-light, -dark, -text, -conflict, space-watch, space-390,
//     space-another-computer.
//   · the chat window (a second DevTools socket on the browser's endpoint attaches every new window from its first byte):
//     1 the Chat page's pop-out opens /chat#/askw named doz-chat-askw — the room alone, live, the focus on the composer, no two
//     head controls overlapping (the bell included); 2 what it fetched: chat's code only, no other view, no overview, no
//     dashboard stream while idle; 3 a CLI post in the window and the dashboard; 4 a reload keeps the room and the draft;
//     5 a second click reuses the window; 6 Decide in the window (the dashboard's stream opens for it, then closes);
//     7 Turn chat on from the window; 8 reading there clears the dashboard's badge, markers never lower, presence stays
//     "here" after one closes; 10 four windows and the dashboard: no eviction loop, fetches answer; 11 cold bytes of both
//     documents (the window ≤ 40 %), and the warm open's; 9 another computer (session and chat/status rewritten): not shared,
//     then read-only; 12 390 px; 13 no CSP violation or page error from any window's start, the leak sweep; 14 (after the
//     space editor's rows) its "Open in a new window" opens its own window, reused. Pictures: chat-window-light, -dark,
//     -ask, -390.
//   · a workspace's Home tab: 1 #/w/demo2 opens it (selected; no picture outside it); 2 its cards each link their tab, Needs
//     you absent when nothing waits, the room's last messages, at most five log lines, no walk of the folders; 3 wiz2
//     (setting up) — Needs you lists what is missing and Start, its Room tab one line; 4 an open ask in askw's room in Needs
//     you, "Answer in the room" → #/w/askw/room, gone once decided; 5 an agent blocked (a harmless session reporting OSC 7501
//     blocked) named; 6 #/w/demo2/room mounts the room and the brief, Back and Forward keep the surface and the draft; 7 spc2's
//     hero on Home (a link to its space editor), off on Agents with no state read in 3 s; 8 a message arriving on Home is not
//     marked seen, and Home holds no chat stream.
//   · the Workspaces page: 1 the sidebar's heading opens #/workspaces, every workspace under Every with the listing's counts,
//     Show resets on a new visit; 2 Rows → Grid kept across a reload, Sort by Name and Last activity; 3 an <img> only for
//     space workspaces, plain tiles ≤ 40 px here and on Home, a plain card's band ≤ 30 % of a drawn one's, the renderer fetched once, the sidebar's box 0 px until drawn;
//     4 390 px; 5 the keyboard order and Space on the layout; 6 no CSP violation, the leak sweep. Pictures: ws-home-light,
//     ws-home-390, ws-home-needs, workspaces-rows-light, workspaces-rows-390, workspaces-grid-light, workspaces-grid-390.
//   · with the daemon stopped, opening Home, Sandboxes, a workspace's page and its agents starts none (no daemon.pid).
//   · from chat on, every permission is never (this Mac's ceiling, an everywhere never for every role): every check after
//     runs as the owner, never gated; an agent's Can do shows its Permissions and Ceiling as live, read-only rows.
//
// Self-contained: Node >= 22 (global WebSocket and fetch), no packages. Never the person's own Dozable or browser: the
// store, the settings (XDG_CONFIG_HOME), the Chrome profile and the projects folder are under SCRATCH (default
// /tmp/doz-dashboard-walk); every seam css-perf sets keeps the run off this Mac's login, keychain and network; Chrome is
// headless on a scratch profile, its debugging port the OS's choice (Scripts/chrome-launch.mjs); `doz ui` takes a port
// the OS chooses, checked not to be one of the live ones; the sign-in link is read from its output and never printed;
// chat is off for the shell's checks and on (OS-chosen ports) for a workspace's page; no VM starts and no agent program
// runs (the workspaces have no running manager). All of it is removed at the end (KEEP=1 keeps it).
//
// Inputs (environment): DOZ (default .build/debug/doz — `make cli` first), CHROME (default Google Chrome's app), SCRATCH;
// SHOTS=DIR (optional, under /tmp) keeps pictures of a workspace's page (light, dark, 390 px) for a person to look at;
// CHAT_WINDOW_ONLY=1 walks the chat window's rows alone (chat on, the asks' set-up, then those rows).
// SPACE_ONLY=1 walks the space editor's rows alone (chat on, then those rows: a quicker loop while working on them).
// Run from the repository's root (make does).
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { spawnChrome } from './chrome-launch.mjs';

const DOZ = resolve(process.env.DOZ || '.build/debug/doz');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const S = process.env.SCRATCH || '/tmp/doz-dashboard-walk';
const LIVE_PORTS = [7443, 8765, 8766, 8780, 8782, 8790, 8890, 8891, 8443];
if (!S.startsWith('/tmp/')) { console.error('dashboard-walk: SCRATCH must be under /tmp'); process.exit(64); }
if (!existsSync(DOZ)) { console.error('dashboard-walk: no doz at ' + DOZ + ' (make cli)'); process.exit(66); }
if (!existsSync(CHROME)) { console.error('dashboard-walk: no Chrome at ' + CHROME + ' (set CHROME)'); process.exit(66); }

const STORE = S + '/store', XDG = S + '/xdg', PROFILE = S + '/chrome', PROJECTS = S + '/projects';
const ENV = { ...process.env, XDG_CONFIG_HOME: XDG, DOZ_STORE: STORE, DO_NOT_TRACK: '1', DOZ_TEST_GUARD: '1', DOZ_TEST_NO_MAC_LOGIN: '1',
  DOZ_TEST_CREDENTIALS: 'memory', DOZ_TEST_CODEX_HOME: S + '/codex-home', DOZ_TEST_BROWSER_LOG: S + '/browser.log', DOZ_TEST_PASTEBOARD: S + '/pasteboard',
  DOZ_TEST_OPEN_URL: S + '/open-url', DOZ_TEST_FOLDER_PICKER: 'cancel', DOZ_TEST_FILE_PICKER: 'cancel', DOZ_TEST_MODEL_LIST: 'offline',
  DOZ_TEST_NPM_REGISTRY: 'offline', DOZ_TEST_BASE_REGISTRY: 'pinned', DOZ_TEST_CLAUDE_DOWNLOADS: 'offline', DOZ_TEST_GH: S + '/no-gh',
  DOZ_TEST_SSH_AUTH_SOCK: S + '/no-agent.sock', DOZ_TEST_CONTAINER: '/nonexistent/container', GIT_CONFIG_GLOBAL: S + '/gitconfig',
  DOZ_TEST_HOME: '/tmp/doz-dashboard-walk-home', DOZ_TEST_MAC_NAME: 'walkmac', DOZ_TEST_LAUNCH_AGENTS_DIR: S + '/launch-agents',
  DOZ_TEST_LAUNCHCTL: '/usr/bin/false', DOZ_TEST_APPLICATIONS_DIR: S + '/applications', DOZ_PROGRESS: 'plain', NO_COLOR: '1',
  // An inbox bot (made from the page) has the chat server look at Claude Code's sessions: a scratch folder, never the real one.
  DOZ_TEST_CLAUDE_SESSIONS: S + '/claude-sessions',
  // The sessions' PATH: a FAKE claude first (never the real one), so a manager's set-up check finds its program the same way
  // on every Mac. Nothing here starts a manager; the workers the walk adds run it (it reads START, says it is up, sleeps).
  // It lives in the fence's scratch home (a fenced session reads its tools there, as the CLI suite's does).
  DOZ_TEST_MAC_PATH: '/private' + S + '/fence-home/.local/bin:/usr/bin:/bin',
  // A fenced worker's scratch home (a guarded run without one is refused) — never the person's own.
  DOZ_TEST_FENCE_HOME: '/private' + S + '/fence-home',
  // The Bin of a delete with --bin-folders: a scratch folder — a test never reaches the real one (none is ticked here anyway).
  DOZ_TEST_TRASH_DIR: S + '/bin-of-the-walk',
  // A space file's brief must be under the home: in the walk, the scratch folder stands in for it.
  DOZ_TEST_BRIEF_HOME: S };
delete ENV.SSH_AUTH_SOCK;
function doz(args, input) {
  const r = spawnSync(DOZ, [...args, '--store', STORE], { env: ENV, encoding: 'utf8', input, timeout: 120_000 });
  if (r.status) console.log('  doz ' + args.join(' ') + ' → ' + r.status + ': ' + (r.stderr || '').trim().split('\n').pop());
  return r;
}
const dozJSON = (args) => JSON.parse(doz([...args, '--json']).stdout || 'null');
const realpath = (p) => realpathSync(p);
/// A path as the page shows it: the scratch home stands in for ~ (DOZ_TEST_HOME) — else as it is.
const tildeOf = (p) => p;

/// A FAKE claude (never the real one): with "Read START and do what it says." among its arguments it says in its room that
/// it is up — "NAME is up: <START's first line>" with dozchat — then sleeps; anything else just sleeps. The walk starts no
/// manager; the workers it adds run this.
const FAKE_CLAUDE = `#!/bin/sh
start=""
for a in "$@"; do
  case "$a" in "Read "*" and do what it says.") start="\${a#Read }"; start="\${start% and do what it says.}" ;; esac
done
[ -n "$start" ] || exec sleep 600
first=$(head -n 1 "$start")
room=$(sed -n 's/^Your room in chat: //p' "$start")
bot=$(printf '%s' "$first" | sed -n 's/^You are \\([^,]*\\),.*/\\1/p')
dozchat send "$room" "$bot is up: $first" > /dev/null 2>&1
# A space agent whose START says BLOCK-ME reports itself blocked (OSC 7501), as Claude Code does waiting on a permission.
if grep -q BLOCK-ME "$start"; then printf '\\033]7501;?\\033\\\\'; sleep 1; printf '\\033]7501;state=blocked:app=fake\\033\\\\'; fi
exec sleep 600
`;

// ── the scratch store: three sandboxes (never started — no VM), chat off ─────────────────────────────────────────────
const SANDBOXES = ['alpha', 'beta', 'gamma'];
/// The scratch store's folder of sessions on this Mac (the user's temp folder, `dh-` and 8 hex of the store path's sha256 —
/// MacPlace.socketDirectory): a session the walk ran leaves its exit record there, which the next run would list. Only
/// this store's own folder is ever removed.
function macSocketFolder() {
  const tmp = spawnSync('getconf', ['DARWIN_USER_TEMP_DIR'], { encoding: 'utf8' }).stdout.trim().replace(/\/+$/, '');
  return tmp ? tmp + '/dh-' + createHash('sha256').update(STORE).digest('hex').slice(0, 8) : null;
}
function clearMacSocketFolder() { const d = macSocketFolder(); if (d && d.includes('/dh-')) rmSync(d, { recursive: true, force: true }); }
function stage() {
  rmSync(S, { recursive: true, force: true });
  clearMacSocketFolder();
  for (const d of [STORE, XDG + '/doz', PROJECTS, S + '/codex-home', S + '/launch-agents', S + '/applications', S + '/claude-sessions', S + '/fence-home',
    S + '/bin-of-the-walk', S + '/life-work']) mkdirSync(d, { recursive: true });
  writeFileSync(XDG + '/doz/doz.toml', `[store]\npath = "${STORE}"\n\n[defaults]\nprojects_dir = "${PROJECTS}"\n\n[chat]\nenabled = false\n`);
  writeFileSync(S + '/no-gh', '#!/bin/sh\necho "not logged in" >&2\nexit 1\n', { mode: 0o755 });
  const fakebin = S + '/fence-home/.local/bin';
  mkdirSync(fakebin, { recursive: true });
  writeFileSync(fakebin + '/claude', FAKE_CLAUDE, { mode: 0o755 });
  // dozchat for the fake (a fenced session gets its own shim; this one is for an unfenced one).
  if (existsSync(dirname(DOZ) + '/dozchat-mac')) symlinkSync(dirname(DOZ) + '/dozchat-mac', fakebin + '/dozchat');
  writeFileSync(S + '/gitconfig', '[user]\n\tname = dashboard-walk\n\temail = dashboard-walk@example.invalid\n');
  for (const n of SANDBOXES) doz(['create', n, '--image', 'lab', '--isolated']);
}

// ── Chrome over the DevTools protocol ────────────────────────────────────────────────────────────────────────────────
let ws, nextId = 1, chrome, ui, devPort, uiB = false, pausedHook = null;
const pending = new Map(), pageErrors = [], requested = [];
const apiIds = new Set(), apiBodies = [], consoleLines = [], sseEvents = [];
let uiOut = '', chatPagePort = 0;
function send(method, params = {}) { const id = nextId++; ws.send(JSON.stringify({ id, method, params })); return new Promise((res, rej) => pending.set(id, { res, rej })); }
async function evaluate(expr, gesture = false) {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true, userGesture: gesture });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' in ' + expr.slice(0, 80));
  return r.result.value;
}
const soft = async (expr) => { try { return await evaluate(expr); } catch (_) { return null; } };
async function waitFor(expr, ms = 15000) { const end = Date.now() + ms; while (Date.now() < end) { if (await soft(expr)) return true; await sleep(120); } return false; }
async function startChrome() {
  rmSync(PROFILE, { recursive: true, force: true });
  mkdirSync(PROFILE, { recursive: true });
  // Its own responsible process (Scripts/chrome-launch.mjs): no macOS privacy notice charged to the terminal.
  chrome = spawnChrome(CHROME, ['--headless=new', `--user-data-dir=${PROFILE}`, '--no-first-run', '--no-default-browser-check', '--disable-component-update',
    '--disable-background-networking', '--disable-renderer-backgrounding', '--remote-debugging-port=0', '--hide-scrollbars', '--window-size=1440,900',
    'about:blank'], { stdio: 'ignore' }, S + '/bin');
  const f = PROFILE + '/DevToolsActivePort';
  for (let i = 0; i < 150 && !existsSync(f); i++) await sleep(100);
  const port = readFileSync(f, 'utf8').split('\n')[0];
  devPort = port;
  let page;
  for (let i = 0; i < 50 && !page; i++) { page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); if (!page) await sleep(200); }
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r, { once: true }));
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); return; }
    if (m.method === 'Runtime.exceptionThrown') pageErrors.push((m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text).split('\n').slice(0, 4).join(' ⏎ '));
    if (m.method === 'Network.requestWillBeSent') requested.push(m.params.request.url);
    // The leak sweep's sources: every /api/ answer's body (not the event streams), and the console.
    if (m.method === 'Network.responseReceived' && /\/api\/v1\//.test(m.params.response.url) && !/event-stream/.test(m.params.response.mimeType || '')) {
      apiIds.add(m.params.requestId);
    }
    if (m.method === 'Network.loadingFinished' && apiIds.has(m.params.requestId)) {
      apiIds.delete(m.params.requestId);
      send('Network.getResponseBody', { requestId: m.params.requestId }).then((b) => apiBodies.push(b.base64Encoded ? Buffer.from(b.body, 'base64').toString('utf8') : b.body), () => {});
    }
    if (m.method === 'Runtime.consoleAPICalled') consoleLines.push(m.params.args.map((a) => String(a.value ?? a.description ?? '')).join(' '));
    if (m.method === 'Fetch.requestPaused') { (pausedHook ? pausedHook(m.params) : send('Fetch.continueRequest', { requestId: m.params.requestId })).catch(() => {}); return; }
    if (m.method === 'Network.eventSourceMessageReceived') sseEvents.push({ at: Date.now(), name: m.params.eventName });
  });
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Network.enable');
  // Anything the page's CSP blocks, from each document's start (the walk's pictures row counts it: none).
  await send('Page.addScriptToEvaluateOnNewDocument', { source: `window.__violations = [];
    document.addEventListener('securitypolicyviolation', (e) => window.__violations.push(e.violatedDirective + ' ' + e.blockedURI));` });
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
}
async function startUI() {
  // `doz ui` prints the sign-in link only to a terminal: run it on one (script(1)); the link is read here, never printed.
  ui = spawn('script', ['-q', '/dev/null', DOZ, 'ui', '--print-url', '--no-open', '--store', STORE], { env: ENV, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  let out = '';
  ui.stdout.on('data', (d) => { out += d; uiOut += d; });
  for (let i = 0; i < 300; i++) { const m = /(http:\/\/127\.0\.0\.1:(\d+)\/#cap=[A-Za-z0-9_-]+)/.exec(out); if (m) return { link: m[1], port: Number(m[2]) }; await sleep(100); }
  throw new Error('no link from doz ui');
}

// ── the checks ───────────────────────────────────────────────────────────────────────────────────────────────────────
const SHOTS = process.env.SHOTS && process.env.SHOTS.startsWith('/tmp/') ? process.env.SHOTS : null;
async function shot(name, sel) {
  if (!SHOTS) return;
  mkdirSync(SHOTS, { recursive: true });
  // `sel`: only that element (its box on the page).
  const box = sel ? await evaluate(`(() => { const r = document.querySelector(${JSON.stringify(sel)}).getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; })()`) : null;
  const r = await send('Page.captureScreenshot', box ? { format: 'png', clip: { ...box, scale: 1 } } : { format: 'png' });
  writeFileSync(SHOTS + '/' + name + '.png', Buffer.from(r.data, 'base64'));
}
const failures = [];
let passed = 0;
function check(ok, what) { if (ok) { passed++; console.log('  ok   ' + what); } else { failures.push(what); console.log('  FAIL ' + what); } }
const text = (sel) => `(document.querySelector(${JSON.stringify(sel)})?.textContent || '')`;
/// The page shown: the view's own section has something in it, and no failure is said.
const SHOWN = `(() => { const v = state.view;
  const sec = v === 'sandbox' ? 'sbx' : v === 'sessions' ? 'grid' : v === 'mac' ? 'mac' : v === 'chat' ? 'chat' : v === 'workspace' ? 'ws' : 'view';
  const el = document.getElementById(sec);
  return !!el && !el.hidden && el.childElementCount > 0 && !(el.textContent || '').includes('could not be read'); })()`;
async function goHash(hash) {
  await evaluate(`location.hash = ${JSON.stringify(hash)}`);
  await sleep(250);
}

/// Every old address → [its canonical address, its view]. The plan's table, one sample of each row.
const OLD = [
  ['', '#/home', 'home'], ['#/', '#/home', 'home'], ['#/nowhere', '#/home', 'home'],
  ['#/overview', '#/mac/sandboxes', 'overview'], ['#/sessions', '#/mac/sessions', 'sessions'], ['#/terminals', '#/mac/sessions', 'sessions'],
  ['#/mac/build', '#/mac/here/build', 'mac'],
  ['#/recipes', '#/mac/templates', 'recipes'], ['#/recipes/dozable/claude-code', '#/mac/templates/dozable/claude-code', 'recipes'],
  ['#/settings/recipes', '#/mac/templates', 'recipes'], ['#/browse', '#/mac/templates/browse', 'browse'],
  ['#/images', '#/mac/images', 'images'], ['#/resources', '#/mac/resources', 'resources'], ['#/accounts', '#/mac/accounts', 'accounts'],
  ['#/devices', '#/mac/devices', 'devices'], ['#/doctor', '#/mac/doctor', 'doctor'], ['#/settings', '#/mac/settings', 'settings'],
  ['#/debug', '#/mac/debug', 'debug'],
  ['#/operations', '#/mac/logs/operations', 'operations'], ['#/activity', '#/mac/logs/activity', 'activity'],
  ['#/metrics', '#/mac/logs/metrics', 'metrics'], ['#/notifications', '#/mac/logs/notifications', 'notifications'],
  ['#/general', '#/chat', 'chat'], ['#/needs-you', '#/home', 'home'],
  // Unchanged.
  // (An off sandbox's page writes its own address without the tab: `~home` is kept only while it runs.)
  ['#/sandbox/beta', '#/sandbox/beta', 'sandbox'], ['#/sandbox/beta/~home', '#/sandbox/beta', 'sandbox'], ['#/chat', '#/chat', 'chat'],
  // A workspace's Home has one address; its Room tab's trailing slash goes.
  ['#/w/demo/', '#/w/demo', 'workspace'], ['#/w/demo/home', '#/w/demo', 'workspace'], ['#/w/demo/room/', '#/w/demo/room', 'workspace'],
];
const MODALS = [['#/new', 'new'], ['#/onboarding', 'onboarding'], ['#/try', 'try']];

async function walkOldAddresses() {
  for (const [old, want, view] of OLD) {
    await goHash('#/home');
    await goHash(old);
    const ok = await waitFor(`location.hash === ${JSON.stringify(want)} && state.view === ${JSON.stringify(view)} && ${SHOWN}`);
    check(ok, `${old || '(empty)'} → ${want} (${view})` + (ok ? '' : ` — got ${await soft('location.hash + " " + state.view')}`));
  }
  for (const [hash, modal] of MODALS) {
    await goHash('#/home');
    await goHash(hash);
    check(await waitFor(`state.modal === ${JSON.stringify(modal)} && location.hash === ${JSON.stringify(hash)}`), `${hash} opens its modal over the page`);
    await goHash('#/home');
    await waitFor('!state.modal');
  }
}

async function walkSidebar() {
  const parts = await evaluate(`[...document.querySelectorAll('#nav [data-nav-part]')].map((e) => e.dataset.navPart + (e.hidden ? ':hidden' : ''))`);
  check(JSON.stringify(parts) === JSON.stringify(['home', 'needs:hidden', 'chat:hidden', 'bots', 'workspaces', 'thismac']),
    'the sidebar: Home, Needs you (hidden), Chat (hidden — chat is off), Agents / Bots, Workspaces, This Mac — ' + parts.join(', '));
  check(await evaluate(`/Dozable/.test(${text('.side-brand')})`), 'the brand row says Dozable');
  // Every page from before is one click under This Mac.
  const mac = await evaluate(`[...document.querySelectorAll('#nav a[data-view][data-nav-mac]')].map((a) => a.dataset.view)`);
  for (const v of ['thismac', 'sessions', 'overview', 'mac', 'loose', 'recipes', 'browse', 'try', 'images', 'accounts', 'resources', 'devices',
    'operations', 'activity', 'notifications', 'metrics', 'doctor', 'onboarding', 'settings', 'debug']) {
    check(mac.includes(v), `This Mac in the sidebar has ${v}`);
  }
}

async function walkThisMac() {
  await goHash('#/mac');
  await waitFor(`state.view === 'thismac' && !!document.querySelector('[data-thismac]')`);
  const links = await evaluate(`[...document.querySelectorAll('[data-thismac] a[href^="#/"]')].map((a) => a.getAttribute('href'))`);
  check(links.length >= 10, `This Mac's page links to its pages (${links.length})`);
  for (const href of [...new Set(links)]) {
    await goHash('#/mac');
    await waitFor(`state.view === 'thismac'`);
    await goHash(href);
    const ok = await waitFor(`location.hash === ${JSON.stringify(href)} && ${SHOWN}`);
    check(ok, `This Mac › ${href} opens` + (ok ? '' : ` — got ${await soft('location.hash + " " + state.view')}`));
  }
}

async function walkLists() {
  const loose = (dozJSON(['workspace', 'ls', '--loose']) || { loose: [] }).loose.map((a) => a.name).sort();
  await goHash('#/mac/loose');
  await waitFor(`state.view === 'loose' && !!document.querySelector('[data-loose-page]')`);
  await waitFor(`document.querySelectorAll('[data-loose]').length === ${loose.length}`, 8000);
  const shown = (await evaluate(`[...document.querySelectorAll('[data-loose]')].map((e) => e.dataset.loose)`)).sort();
  check(JSON.stringify(shown) === JSON.stringify(loose), `Loose agents lists what doz workspace ls --loose --json does (${loose.join(', ')})`);
  const bots = (dozJSON(['bot', 'ls']) || { bots: [] }).bots.map((b) => b.name).sort();
  await goHash('#/bots');
  await waitFor(`state.view === 'bots' && !!document.querySelector('[data-bots-page]')`);
  await waitFor(`document.querySelectorAll('[data-bot]').length === ${bots.length}`, 8000);
  const shownBots = (await evaluate(`[...document.querySelectorAll('[data-bot]')].map((e) => e.dataset.bot)`)).sort();
  check(JSON.stringify(shownBots) === JSON.stringify(bots) && bots.length > 0, `Agents / Bots lists what doz bot ls --json does (${bots.join(', ')})`);
}

// ── Your Macs: the machine picker against a second scratch dashboard (`mini`) ─────────────────────────────────────────
const STORE_B = S + '/store-b', XDG_B = S + '/xdg-b';
const ENV_B = { ...ENV, XDG_CONFIG_HOME: XDG_B, DOZ_STORE: STORE_B, DOZ_TEST_MAC_NAME: 'mini', DOZ_TEST_BROWSER_LOG: S + '/browser-b.log' };
function freePort() {
  return new Promise((res) => { const srv = createServer(); srv.listen(0, '127.0.0.1', () => { const p = srv.address().port; srv.close(() => res(p)); }); });
}
async function key(k, code, vk) {
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, ...(k === 'Enter' ? { text: '\r' } : {}) });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk });
}
const ENTER = ['Enter', 'Enter', 13], ESC = ['Escape', 'Escape', 27];
const MENU = `document.querySelector('#mac-picker').closest('.brand-wrap').querySelector('.mac-menu')`;
async function walkMacs() {
  let p2 = await freePort();
  for (let i = 0; i < 5 && LIVE_PORTS.includes(p2); i++) p2 = await freePort();
  const closed = await freePort();
  check(p2 > 1023 && !LIVE_PORTS.includes(p2) && !LIVE_PORTS.includes(closed), `the other dashboard's port is the OS's choice, not a live one`);
  for (const d of [STORE_B, XDG_B + '/doz']) mkdirSync(d, { recursive: true });
  writeFileSync(XDG_B + '/doz/doz.toml', `[store]\npath = "${STORE_B}"\n\n[defaults]\nprojects_dir = "${PROJECTS}"\n\n[chat]\nenabled = false\n\n[ui]\nport = ${p2}\n`);
  const b = spawnSync(DOZ, ['ui', '--detach', '--no-open', '--store', STORE_B], { env: ENV_B, encoding: 'utf8', timeout: 60_000 });
  uiB = true;
  let up = false;
  for (let i = 0; i < 100 && !up; i++) { try { up = (await fetch(`http://127.0.0.1:${p2}/`)).status === 200; } catch (_) { await sleep(150); } }
  check(b.status === 0 && up, 'a second scratch doz ui (mini) answers on its port');
  const origin2 = `http://127.0.0.1:${p2}`, origin3 = `http://127.0.0.1:${closed}`;
  check(doz(['ui', 'macs', 'add', 'mini', origin2]).status === 0, 'doz ui macs add mini (checked)');
  check(doz(['ui', 'macs', 'add', 'air', origin3, '--no-check']).status === 0, 'doz ui macs add air --no-check');
  requested.length = 0;
  await goHash('#/home');
  await waitFor(`state.view === 'home'`);
  const label = await evaluate(`document.querySelector('#mac-picker .brand-line').textContent.replace(/\\s+/g, ' ').trim()`);
  check(/^Dozable ?· walkmac$/.test(label) && (await evaluate(`document.querySelector('#mac-picker').getAttribute('aria-expanded')`)) === 'false',
    `the brand row is a button reading "Dozable · walkmac", aria-expanded false (${label})`);
  await evaluate(`document.querySelector('#mac-picker').focus()`);
  await key(...ENTER);
  check(await waitFor(`!${MENU}.hidden && document.querySelector('#mac-picker').getAttribute('aria-expanded') === 'true'`), 'Enter opens the menu');
  check(await waitFor(`!!${MENU}.querySelector('[data-mac-link="mini"]')`, 8000), 'the menu reads Your Macs when it opens');
  const items = await evaluate(`[...${MENU}.querySelectorAll('[data-mac-here], [data-mac-link]')].map((e) => ({
    here: e.hasAttribute('data-mac-here'), name: e.dataset.macLink || e.querySelector('.mi-label').textContent, tag: e.tagName, href: e.getAttribute('href'),
    target: e.getAttribute('target'), rel: e.getAttribute('rel'), rp: e.getAttribute('referrerpolicy'), desc: e.dataset.desc || '', state: e.dataset.macState }))`);
  check(items.length === 3 && items[0].here && items[0].tag === 'BUTTON' && items[0].name === 'walkmac' && /you are here/.test(items[0].desc),
    'this Mac first, "you are here", not a link');
  const mini = items.find((i) => i.name === 'mini'), air = items.find((i) => i.name === 'air');
  check(mini && mini.tag === 'A' && mini.href === origin2 + '/' && mini.target === '_blank' && mini.rel === 'noopener noreferrer' && mini.rp === 'no-referrer',
    `mini is a link to exactly ${origin2}/ in a new tab, noopener noreferrer`);
  check(mini && mini.state === 'seen' && /^seen /.test(mini.desc), `mini: seen (${mini && mini.desc})`);
  check(air && air.href === origin3 + '/' && air.target === '_blank' && air.desc === 'never checked', `air: never checked, its link ${origin3}/`);
  check(await evaluate(`document.activeElement === ${MENU}.querySelector('[data-mac-link="mini"]')`), 'the focus is on the first Mac');
  await key(...ENTER);
  let tab = null;
  for (let i = 0; i < 60 && !tab; i++) {
    tab = (await (await fetch(`http://127.0.0.1:${devPort}/json/list`)).json()).find((t) => t.type === 'page' && t.url.startsWith(origin2));
    if (!tab) await sleep(150);
  }
  check(!!tab && tab.url === origin2 + '/' && !/[#?]|cap/.test(tab.url), `following mini opens a new tab at exactly ${origin2}/ (${tab && tab.url})`);
  if (tab) {
    const w2 = new WebSocket(tab.webSocketDebuggerUrl);
    await new Promise((r) => w2.addEventListener('open', r, { once: true }));
    let nid = 1;
    const ask2 = (expression) => new Promise((r) => {
      const id = ++nid;
      const on = (ev) => { const m = JSON.parse(ev.data); if (m.id === id) { w2.removeEventListener('message', on); r(m.result && m.result.result ? m.result.result.value : JSON.stringify(m)); } };
      w2.addEventListener('message', on);
      w2.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }));
    });
    for (let i = 0; i < 100 && (await ask2(`location.origin + ' ' + document.readyState`)) !== origin2 + ' complete'; i++) await sleep(100);
    const status = await ask2(`fetch('/api/v1/session').then((r) => r.status, (e) => 'failed: ' + e)`);
    check(status === 401, `mini's tab is not signed in — that Mac's own sign-in applies (/api/v1/session ${status})`);
    w2.close();
    await fetch(`http://127.0.0.1:${devPort}/json/close/${tab.id}`);
  }
  check(!requested.some((u) => u.includes(':' + p2) || u.includes(':' + closed)), 'this page made no request to another Mac');
  await evaluate(`document.querySelector('#mac-picker').focus()`);
  await key(...ENTER);
  await waitFor(`!${MENU}.hidden`);
  await key(...ESC);
  check(await waitFor(`${MENU}.hidden && document.activeElement === document.querySelector('#mac-picker')`), 'Escape closes it and gives the focus back');
  const ls = (dozJSON(['ui', 'macs', 'ls']) || { macs: [] }).macs.map((m) => m.name + ' ' + m.origin).sort();
  await goHash('#/mac/macs');
  await waitFor(`state.view === 'macs' && !!document.querySelector('[data-macs-page]')`);
  await waitFor(`document.querySelectorAll('[data-mac]').length === ${ls.length}`, 8000);
  const page = (await evaluate(`[...document.querySelectorAll('[data-mac]')].map((r) => r.dataset.mac + ' ' + r.querySelector('.mac-host').textContent)`)).sort();
  check(JSON.stringify(page) === JSON.stringify(ls) && ls.length === 2, `#/mac/macs lists what doz ui macs ls --json does (${ls.join(', ')})`);
  check(await evaluate(`/doz ui macs add NAME ADDRESS/.test(document.querySelector('[data-macs-add]').textContent) && !/paste/i.test(document.querySelector('[data-macs-page]').textContent)`),
    '#/mac/macs: the add command, and never "paste its link"');
  // A phone: the top bar's name opens the same list.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await goHash('#/home');
  await waitFor(`document.querySelector('#top-mac-picker').offsetParent !== null`, 8000);
  await evaluate(`document.querySelector('#top-mac-picker').click()`);
  const TOP = `document.querySelector('#top-mac-picker').closest('.brand-wrap').querySelector('.mac-menu')`;
  check(await waitFor(`!${TOP}.hidden && !!${TOP}.querySelector('[data-mac-link="mini"]')`, 8000), 'at 390 px the top bar’s name opens Your Macs');
  const box = await evaluate(`(() => { const r = ${TOP}.getBoundingClientRect(); return { l: r.left, w: r.width, t: r.top, top: document.querySelector('#topbar').getBoundingClientRect().bottom }; })()`);
  check(box.w >= 390 - 32 && box.t >= box.top, `…under the top bar at the window's width (${Math.round(box.w)} px)`);
  await key(...ESC);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  spawnSync(DOZ, ['ui', 'stop', '--store', STORE_B], { env: ENV_B, timeout: 60_000 });
  uiB = false;
}

// ── a workspace's page, chat on ──────────────────────────────────────────────────────────────────────────────────────
const BRIEF = 'Walk the workspace page.\n\nKeep the **logo** reveal.\n';
// ── turning chat on from the page: the Chat page, a workspace's page (and Make its room), the wizard ─────────────────
const chatState = () => (dozJSON(['chat', 'status']) || {}).state;
async function walkChatOn() {
  const errorsBefore = pageErrors.length;
  let p1 = await freePort(), p2 = await freePort();
  for (let i = 0; i < 5 && (LIVE_PORTS.includes(p1) || LIVE_PORTS.includes(p2) || p1 === p2); i++) { p1 = await freePort(); p2 = await freePort(); }
  check(p1 > 1023 && p2 > 1023 && p1 !== p2 && !LIVE_PORTS.includes(p1) && !LIVE_PORTS.includes(p2), 'chat\'s two ports are the OS\'s choice, not live ones');
  chatPagePort = p1;
  doz(['config', 'set', 'chat.page_port', String(p1)]);
  doz(['config', 'set', 'chat.line_port', String(p2)]);
  // 1. The Chat page: the form (your name, prefilled), Turn chat on, and the chat view with no reload of the page.
  await goHash('#/chat');
  check(await waitFor(`!!document.querySelector('#chat-notice [data-chat-on] [data-chat-on-go]')`, 15000)
    && await evaluate(`(document.querySelector('[data-chat-on-name]')?.value || '').length > 0 && !!document.querySelector('#chat-notice [data-cmd^="doz chat on --name"]')`),
    'chat on 1 the Chat page while chat is off: the form, your name prefilled, Turn chat on, the terminal line beneath');
  await setField('[data-chat-on-name]', 'Ada Lovelace');
  await evaluate(`document.querySelector('[data-chat-on-go]').click()`);
  check(await waitFor(`!document.querySelector('[data-chat-on-error]')?.hidden && /not a name in chat/.test(document.querySelector('[data-chat-on-error]').textContent)`, 15000)
    && chatState() === 'off', 'chat on 1 …a name the chat refuses: Dozable\'s words inline, chat still off');
  await setField('[data-chat-on-name]', 'ada');
  await evaluate(`window.__walkStay = 1; document.querySelector('[data-chat-on-go]').click()`);
  check(await waitFor(`state.chat.status?.state === 'running' && !document.getElementById('chat-cols').hidden && !!document.getElementById('chat-text')`, 90000)
    && await evaluate(`window.__walkStay === 1 && ['live', 'connecting'].includes(state.chat.live)`) && chatState() === 'running'
    && (dozJSON(['chat', 'status']) || {}).human === 'ada', 'chat on 1 …Turn chat on: the chat view loads with no reload, "live", you are ada');
  // 2. A workspace's page: setting up with chat off — the set-up item's Turn chat on, then Make its room.
  doz(['chat', 'off']);
  doz(['bot', 'new', 'cwbot', '--agent', 'claude-code']);
  doz(['workspace', 'new', 'cw', '--prompt-file', '-', '--manager', 'cwbot'], 'Turn chat on from the page.\n');
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  await goHash('#/w/cw/room');
  check(await waitFor(`!!document.querySelector('[data-ws-noroom="cw"] [data-chat-on]') && document.querySelector('[data-ws-make-room="cw"]')?.disabled === true
    && !!document.querySelector('[data-ws-setup-line]')`, 15000),
    'chat on 2 a workspace setting up with chat off, its Room tab: No room yet with the form, Make its room off, the one setting-up line');
  await goHash('#/w/cw');
  check(await waitFor(`!!document.querySelector('[data-ws-card="needs"] [data-ws-setup] [data-gap="chat"] [data-chat-on-inline]')`, 15000),
    'chat on 2 …its Home: Needs you says "a manager needs chat" with Turn chat on');
  await evaluate(`document.querySelector('[data-gap="chat"] [data-chat-on-inline]').click()`);
  check(await waitFor(`!document.querySelector('[data-ws-setup] [data-gap="chat"]') && !!document.querySelector('[data-ws-setup] [data-gap="room"]')`, 90000) && chatState() === 'running',
    'chat on 2 …on: the set-up item clears, "no main room" instead');
  await goHash('#/w/cw/room');
  check(await waitFor(`document.querySelector('[data-ws-make-room="cw"]')?.disabled === false`, 30000), 'chat on 2 …Make its room on');
  await evaluate(`document.querySelector('[data-ws-make-room="cw"]').click()`);
  check(await waitFor(`!document.querySelector('[data-ws-noroom]') && state.chat.room === 'cw'`, 30000)
    && (dozJSON(['workspace', 'show', 'cw']) || {}).rooms?.some((r) => r.chatRoom === 'cw'),
    'chat on 2 Make its room: the room made (doz workspace show), the room view loads, the set-up items clear — '
    + JSON.stringify(await evaluate(`({ noroom: !!document.querySelector('[data-ws-noroom]'), gaps: [...document.querySelectorAll('[data-ws-setup] [data-gap]')].map((g) => g.dataset.gap),
      room: state.chat.room, err: document.querySelector('[data-ws-make-room-error]')?.textContent || '', btn: document.querySelector('[data-ws-make-room]')?.disabled,
      ops: [...state.ops.values()].filter((o) => o.action === 'workspace-edit' || /room/.test(o.label || '')).map((o) => [o.action, o.label, o.state, o.text]) })`)) + ' ' + JSON.stringify((dozJSON(['workspace', 'show', 'cw']) || {}).rooms));
  // 3. The wizard: chat off at step 4 — its room's form; on, the plan again with nothing typed lost; Create and start.
  doz(['chat', 'off']);
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  await goHash('#/new-workspace');
  await waitFor(`state.modal === 'new-workspace' && !!document.querySelector('[data-wsn="work"]')`, 10000);
  await wizType('[data-wsn-brief]', 'A room once chat is on.');
  await wizType('[data-wsn-name]', 'cwiz');
  await wizNext(1); await wizNext(2); await wizNext(3);
  check(await waitFor(`!!document.querySelector('.wsn-rooms [data-wsn-room="none"]') && !!document.querySelector('.wsn-rooms [data-chat-on-go]')`, 10000),
    'chat on 3 the wizard\'s step 4 with chat off: "No room: chat is off." and the form');
  await evaluate(`document.querySelector('.wsn-rooms [data-chat-on-go]').click()`);
  check(await waitFor(`!!document.querySelector('select[data-wsn-room]') && ${PLANNED} && state.wsn.brief === 'A room once chat is on.' && state.wsn.name === 'cwiz'
    && !document.querySelector('[data-wsn-create="now"]').disabled`, 90000),
    'chat on 3 …on: its room can be made, the plan again, nothing typed lost, Create and start on — ' + JSON.stringify(await evaluate(`({ select: !!document.querySelector('select[data-wsn-room]'),
      none: !!document.querySelector('[data-wsn-room="none"]'), err: document.querySelector('.wsn-rooms [data-chat-on-error]')?.textContent || '', gaps: (state.wsn?.plan?.gaps || []).map((g) => g.item),
      refusals: state.wsn?.plan?.refusals || [], name: state.wsn?.name, brief: state.wsn?.brief, planned: ${PLANNED}, start: document.querySelector('[data-wsn-create="now"]')?.disabled, on: state.chat.on })`)));
  check(/^doz chat on\n/.test(await evaluate(`document.querySelector('[data-wsn-commands]')?.textContent || ''`)), 'chat on 3 …the copied commands turn chat on first');
  await evaluate(`document.querySelector('[data-wsn-create="now"]').click()`);
  check(await waitFor(`state.view === 'workspace' && state.param === 'cwiz' && !state.modal`, 60000)
    && !!(dozJSON(['workspace', 'show', 'cwiz']) || {}).flags?.startedAt, 'chat on 3 Create and start: cwiz started, with its room');
  check(pageErrors.length === errorsBefore, 'chat on: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
}

async function walkWorkspacePage() {
  check(doz(['chat', 'on', '--name', 'ada']).status === 0, 'chat on (scratch store, OS-chosen ports): on already, the page turned it on');
  // From here every permission is never — this Mac's ceiling and an everywhere never for every role. Permissions constrain
  // agents and never the owner: every check below (the workspaces, the wizard, workers, the lifecycle) runs exactly as before.
  const allNever = ['workspace.read', 'agent.start', 'agent.stop', 'worker.start', 'worker.stop', 'isolation.unfenced', 'net.allow', 'secret.use',
    'keychain.use', 'folder.read', 'folder.write', 'delete', 'room.manage', 'chat.read', 'chat.post', 'workspace.sleep', 'workspace.finish',
    'workspace.archive', 'workspace.delete', 'bot.manage', 'grant.give', 'spend', 'sudo'].map((p) => p + '=never');
  check(doz(['permissions', 'ceiling', '--mac', ...allNever, 'chat.decide=never']).status === 0
    && ['manager', 'worker', 'member'].every((r) => doz(['permissions', 'grant', 'role:' + r, ...allNever, '--everywhere']).status === 0),
    'every permission never from here (this Mac\'s ceiling, an everywhere never for every role): the owner is never gated');
  check(doz(['chat', 'room', 'other']).status === 0, 'an unrelated room, other');
  const folder = PROJECTS + '/demo2-src';
  mkdirSync(folder, { recursive: true });
  check(doz(['workspace', 'new', 'demo2', '--prompt-file', '-', '--folder', folder, '--adopt', 'beta', '--ref', 'https://example.com/spec'], BRIEF).status === 0,
    'workspace new demo2 (a brief, a reference, a folder, the never-booted sandbox beta)');
  check(doz(['workspace', 'start', 'demo2']).status === 0, 'workspace start demo2 — no manager: you drive, the brief is the kick-off');
  doz(['bot', 'new', 'otto', '--agent', 'claude-code', '--isolation', 'unfenced']);
  doz(['workspace', 'new', 'demo3', '--prompt-file', '-', '--manager', 'otto', '--manager-isolation', 'unfenced'], 'An unfenced manager, recorded.\n');
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);

  await goHash('#/w/demo2/room');
  check(await waitFor(`state.view === 'workspace' && state.param === 'demo2' && ${SHOWN}`), '#/w/demo2/room → the view workspace, its Room tab');
  check(await waitFor(`/Walk the workspace page/.test(${text('[data-ws-brief="demo2"] .ws-brief-text')}) && !document.querySelector('[data-ws-brief="demo2"]').classList.contains('is-folded')`, 15000),
    'the brief is open, with its text');
  check(await evaluate(`!!document.querySelector('[data-ws-brief="demo2"] .ws-brief-text strong')`), '…its Markdown drawn (bold)');
  check(await evaluate(`!!document.querySelector('[data-ws-brief="demo2"] a.ws-ref[href="https://example.com/spec"][rel="noopener noreferrer"]')`), '…its reference a safe link');
  const tabs = await evaluate(`[...document.querySelectorAll('#ws [data-ws-tab]')].map((t) => ({ label: t.firstChild.textContent, off: t.getAttribute('aria-disabled') === 'true', coming: !!t.querySelector('.ws-coming') }))`);
  check(JSON.stringify(tabs.map((t) => t.label)) === JSON.stringify(['Home', 'Room', 'Agents', 'Permissions', 'Network & secrets', 'Folders & points', 'Activity', 'Runs', 'Settings']),
    'the tabs in the mockups\' order (' + tabs.map((t) => t.label).join(' · ') + ')');
  check(tabs.filter((t) => !t.off).map((t) => t.label).join() === 'Home,Room,Agents,Network & secrets,Folders & points,Activity,Runs'
    && tabs.filter((t) => t.off).map((t) => t.label).join() === 'Permissions,Settings' && tabs.filter((t) => t.off).every((t) => t.coming),
    'Home, Room, Agents, Network & secrets, Folders & points, Activity and Runs work; Permissions and Settings are marked coming');
  check(await evaluate(`PERMISSIONS_TAB === 'Permissions' && document.querySelector('#ws [data-ws-tab="permissions"]').firstChild.textContent === PERMISSIONS_TAB`),
    'the permissions tab reads "Permissions", from its one constant');
  check(await waitFor(`[...document.querySelectorAll('#chat-log .chat-row')].some((r) => /Walk the workspace page/.test(r.textContent))`, 20000), 'the kick-off bubble is in the room');
  check(await waitFor(`/started the work/.test(${text('#chat-log .chat-sys[data-action="kicked-off"]')})`, 10000), 'a "started the work" line from the log');
  const ordered = `(() => { const at = [...document.querySelectorAll('#chat-log [data-at]')].filter((e) => !e.classList.contains('chat-moment')).map((e) => +e.dataset.at);
    return at.length > 1 && at.every((t, i) => i === 0 || t >= at[i - 1]); })()`;
  check(await evaluate(ordered), 'the messages and the log\'s lines are in time order');
  check(await evaluate(`document.querySelectorAll('#chat-text').length === 1 && !!document.querySelector('#ws #chat-text')`), 'one composer, in the workspace\'s room');
  check(JSON.stringify(await evaluate(`[...document.querySelectorAll('#ws #chat-rooms [data-room]')].map((a) => a.dataset.room)`)) === '["demo2"]',
    'the room strip shows its room only (not other)');
  check(await evaluate(`!!document.querySelector('#ws .chat-rm-add[disabled]')`), '"+ room" is drawn, disabled');

  // The meta line under a member's name, and the brief edited from here.
  await evaluate(`[...document.querySelectorAll('[data-ws-brief="demo2"] button')].find((b) => /Edit/.test(b.textContent)).click()`);
  check(await waitFor(`!!document.querySelector('.ws-brief-area')`), 'Edit opens the brief\'s editor');
  await evaluate(`(() => { const a = document.querySelector('.ws-brief-area'); a.value = 'Walk it again, shorter.'; a.dispatchEvent(new Event('input')); })()`);
  await evaluate(`[...document.querySelectorAll('.ws-brief-acts button')].find((b) => /Save/.test(b.textContent)).click()`);
  check(await waitFor(`[...document.querySelectorAll('#chat-log .chat-row')].some((r) => /I edited the work:/.test(r.textContent) && /Walk it again, shorter/.test(r.textContent))`, 30000),
    'Save posts the announcement in the room, as you');
  check(await waitFor(`/edited the work/.test(${text('#chat-log .chat-sys[data-action="brief-edited"]')})`, 15000), '…and the log\'s "edited the work" line shows');
  check(await waitFor(`/Walk it again, shorter/.test(${text('[data-ws-brief="demo2"] .ws-brief-text')})`, 10000), '…and the brief shows the new text');
  await evaluate(`[...document.querySelectorAll('[data-ws-brief="demo2"] button')].find((b) => /History/.test(b.textContent)).click()`);
  check(await waitFor(`document.querySelectorAll('.ws-brief-hist li').length === 1 && !!document.querySelector('.ws-brief-hist .chat-link')`), 'History shows one edit, linked to the room');
  check(await evaluate(ordered), 'still in time order after the edit');

  // A workspace a space file made: "Defined by" and its up pill; its brief card is the file's, and Save writes the file —
  // never the store's copy.
  const SPACE = S + '/space';
  mkdirSync(SPACE, { recursive: true });
  writeFileSync(SPACE + '/BRIEF.md', 'The space walk.\n');
  writeFileSync(SPACE + '/spc.space.yaml', 'doz: space/3\nspace: spc\nbrief: BRIEF.md\nowner: ada\nchat:\n  rooms:\n    spc: { members: [owner] }\n');
  const up = doz(['workspace', 'up', '-f', SPACE + '/spc.space.yaml', '--yes']);
  check(up.status === 0, 'workspace up -f spc.space.yaml (a room, the run started; nothing unfenced, so nothing asked)');
  await goHash('#/w/spc');
  check(await waitFor(`!!document.querySelector('[data-ws-card="state"] [data-ws-space="spc.space.yaml"] [data-ws-space-pill="up"]') && /Defined by/.test(${text('[data-ws-space]')})`, 15000),
    'its Home says "Defined by spc.space.yaml" with its up pill');
  await goHash('#/w/spc/room');
  check(await waitFor(`/BRIEF\.md — from the space file/.test(${text('[data-ws-brief="spc"] .ws-brief-label')})`, 10000), 'the brief card is "BRIEF.md — from the space file"');
  await evaluate(`[...document.querySelectorAll('[data-ws-brief="spc"] button')].find((b) => /Edit/.test(b.textContent)).click()`);
  check(await waitFor(`!!document.querySelector('[data-ws-brief-saves]')`), '…its editor says where it saves');
  await evaluate(`(() => { const a = document.querySelector('.ws-brief-area'); a.value = 'The space walk, edited.'; a.dispatchEvent(new Event('input')); })()`);
  await evaluate(`[...document.querySelectorAll('.ws-brief-acts button')].find((b) => /Save/.test(b.textContent)).click()`);
  check(await waitFor(`/The space walk, edited/.test(${text('[data-ws-brief="spc"] .ws-brief-text')})`, 15000), '…Save shows the new text');
  check(/The space walk, edited/.test(readFileSync(SPACE + '/BRIEF.md', 'utf8')), '…and wrote it into BRIEF.md beside the space file');
  check(readFileSync(STORE + '/workspaces/spc/brief.md', 'utf8') === '', '…never into the store\'s copy');
  check(doz(['workspace', 'down', 'spc', '--yes']).status === 0, 'workspace down spc');
  await goHash('#/w/demo2');
  await waitFor(`state.param === 'demo2'`);
  await goHash('#/w/spc');
  check(await waitFor(`!!document.querySelector('[data-ws-space-pill="down"]')`, 15000), 'the pill says down (its Home)');
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await sleep(300);
  await shot('workspace-light');
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] });
  await sleep(300);
  await shot('workspace-dark');
  await send('Emulation.setEmulatedMedia', { features: [] });

  // Another room's address: one not this workspace's opens its main room, saying so.
  await goHash('#/w/demo2/room/other');
  check(await waitFor(`/no room other in demo2/.test(${text('[data-ws-missing]')}) && state.chat.room === 'demo2'`, 10000), '#/w/demo2/room/other opens the main room, with the line saying so');
  await goHash('#/chat');
  check(await waitFor(`state.view === 'chat' && !!document.querySelector('#chat #chat-rooms [data-room="other"]')`, 10000), '#/chat still lists other');
  check(await evaluate(`document.querySelectorAll('#chat-text').length === 1 && !!document.querySelector('#chat #chat-text')`), '…with the one composer back on the Chat page');
  await goHash('#/w/demo2/room');
  await waitFor(`state.view === 'workspace' && state.chat.room === 'demo2'`, 10000);

  // The side panel against the CLI.
  const show = dozJSON(['workspace', 'show', 'demo2']);
  await waitFor(`document.querySelectorAll('#ws-panel [data-ws-agent]').length === ${show.agents.length}`, 8000);
  const agents = (await evaluate(`[...document.querySelectorAll('#ws-panel [data-ws-agent]')].map((e) => e.dataset.wsAgent)`)).sort();
  const folders = await evaluate(`[...document.querySelectorAll('#ws-panel [data-ws-folder]')].map((e) => e.dataset.wsFolder)`);
  const net = await evaluate(`document.querySelector('#ws-panel [data-ws-network]').dataset.wsNetwork`);
  check(JSON.stringify(agents) === JSON.stringify(show.agents.map((a) => a.name).sort()) && JSON.stringify(folders) === JSON.stringify(show.folders.map((f) => f.path))
    && net === (show.defaults.network || 'locked'), `the side panel is doz workspace show demo2 --json (${agents.join(', ')}; ${folders.length} folder; ${net})`);
  check(await evaluate(`document.querySelector('#ws-panel [data-ws-agent="beta"]').dataset.iso === 'micro VM' && !!document.querySelector('#ws-panel [data-ws-agent="beta"] a[href="#/w/demo2/agent/beta"]')`),
    'beta: micro VM, linking to its screen in the workspace');
  check(await evaluate(`!!document.querySelector('#ws-panel #chat-people-pane')`), '"In this room" is the room\'s own people list, in the panel');
  await goHash('#/w/demo3/room');
  check(await waitFor(`state.param === 'demo3' && /acts as you/.test(${text('#ws-panel [data-ws-agent="otto"]')}) && !!document.querySelector('#ws-head .acts-as-you')`, 10000),
    'an unfenced manager shows "acts as you" (the panel and the title row)');

  // The sidebar and Home lead to the page.
  await goHash('#/home');
  // demo2 started with nothing running is asleep: Home folds it into "Asleep (N)" — unfolded here.
  await waitFor(`!!document.querySelector('[data-ws="demo2"]') || !!document.querySelector('[data-home-group="asleep"]')`, 10000);
  await evaluate(`(() => { const g = document.querySelector('[data-home-group="asleep"]'); if (g && g.getAttribute('aria-expanded') !== 'true') g.click(); })()`);
  await waitFor(`!!document.querySelector('[data-ws="demo2"]')`, 10000);
  check(await evaluate(`[...document.querySelectorAll('[data-ws="demo2"] a.hm-ws-name, [data-ws="demo2"] a.hm-thumb-link')].every((a) => a.getAttribute('href') === '#/w/demo2')
    && [...document.querySelectorAll('[data-ws="demo2"] a.hm-room, [data-ws="demo2"] .hm-next a')].every((a) => a.getAttribute('href') === '#/w/demo2/room')
    && document.querySelectorAll('[data-ws="demo2"] a.hm-room, [data-ws="demo2"] .hm-next a').length >= 1`),
    'Home: demo2\'s name leads to its Home (#/w/demo2), its room and Open room to its Room tab (#/w/demo2/room)');
  await evaluate(`(() => { const g = document.querySelector('[data-ws-group="~asleep"]'); if (g && g.getAttribute('aria-expanded') !== 'true') g.click(); })()`);
  check(await waitFor(`document.querySelector('[data-ws-link="demo2"]')?.getAttribute('href') === '#/w/demo2'`, 8000), 'the sidebar: demo2 opens #/w/demo2');
  await evaluate(`(() => { const c = document.querySelector('[data-ws-fold="demo2"]'); if (c && c.getAttribute('aria-expanded') !== 'true') c.click(); })()`);
  check(await waitFor(`document.querySelector('[data-nav-ws="demo2"] a[data-ws-room="demo2"]')?.getAttribute('href') === '#/w/demo2/room'`, 8000),
    'the sidebar: demo2\'s main room line opens its Room tab (#/w/demo2/room)');

  // The merge itself, against fixtures (the page's own function).
  const kinds = (args) => evaluate(`interleave(${args}).map((x) => x.kind).join()`);
  const ms = `[{ at: 10 }, { at: 20 }]`, ls = `[{ at: '1970-01-01T00:00:05Z' }, { at: '1970-01-01T00:00:10Z' }, { at: '1970-01-01T00:00:25Z' }]`;
  check(await kinds(`${ms}, ${ls}, false`) === 'line,msg,msg,line', 'interleave: only the span loaded, a line before a message of its time');
  check(await kinds(`${ms}, ${ls}, true`) === 'line,line,msg,msg,line', 'interleave: everything when nothing older is left');
  check(await kinds(`[], ${ls}, false`) === 'line,line,line', 'interleave: every line with no message');

  // A phone: the panel folds below the room.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await goHash('#/w/demo2/room');
  await waitFor(`state.view === 'workspace' && state.param === 'demo2'`);
  await sleep(500);
  const fold = await evaluate(`(() => { const r = document.querySelector('#ws-room').getBoundingClientRect(), p = document.querySelector('#ws-panel').getBoundingClientRect();
    return { room: r.bottom, panel: p.top, w: document.documentElement.scrollWidth }; })()`);
  await shot('workspace-390');
  check(fold.panel >= fold.room - 1 && fold.w <= 390, `at 390 px the panel is below the room, no sideways scroll (${Math.round(fold.room)} → ${Math.round(fold.panel)}, ${fold.w} px)`);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
}

// ── This Mac: Remove ended sessions (this Mac's own browser) ─────────────────────────────────────────────────────────
// Three ended sessions and one running, plus an ended one filed in a workspace: Remove on one tile, then Remove all ended
// (the dialog names the two left); no Remove on the running tile or the workspace's; the leak sweep after.
async function walkRemoveEnded() {
  const folder = PROJECTS + '/remove-walk';
  mkdirSync(folder, { recursive: true });
  const run = (s, argv) => spawnSync(DOZ, ['run', '@mac', '-d', '--unfenced', '--session', s, '--folder', folder, '--store', STORE, '--', ...argv],
    { env: ENV, encoding: 'utf8', timeout: 120_000 }).status === 0;
  const made = ['rme1', 'rme2', 'rme3', 'rmws'].map((s) => run(s, ['/bin/sh', '-c', 'echo ended-' + s])).every(Boolean) && run('rmrun', ['/bin/sleep', '600']);
  if (!made) { console.log('  note no session on this Mac could start here (deckhold-mac?) — make test-cli-host holds the forget rows'); return; }
  doz(['workspace', 'adopt', 'demo', '@mac/rmws']);
  const sessions = () => dozJSON(['sessions', '@mac']) || [];
  for (let i = 0; i < 100 && !['rme1', 'rme2', 'rme3', 'rmws'].every((n) => sessions().find((x) => x.name === n)?.ended); i++) await sleep(200);
  await goHash('#/mac/here');
  const TILE = (n) => `document.querySelector('.mac-tile[data-session="${n}"]')`;
  const hasRemove = (n) => `!![...(${TILE(n)}?.querySelectorAll('.mac-acts button') || [])].find((b) => b.textContent.startsWith('Remove'))`;
  check(await waitFor(`${hasRemove('rme1')} && ${hasRemove('rme2')} && ${hasRemove('rme3')}`, 15000), 'remove: each ended tile has Remove…');
  check(await waitFor(`!!${TILE('rmrun')} && !!${TILE('rmws')}`, 10000) && !(await evaluate(hasRemove('rmrun'))) && !(await evaluate(hasRemove('rmws'))),
    'remove: no Remove on the running tile or the workspace\'s');
  const HEAD = `[...document.querySelectorAll('#mac .head button')].find((b) => b.textContent.startsWith('Remove all ended'))`;
  check(await evaluate(`!!${HEAD} && !${HEAD}.hidden`), 'remove: Remove all ended… in the header (this Mac\'s own browser)');
  await evaluate(`[...${TILE('rme1')}.querySelectorAll('.mac-acts button')].find((b) => b.textContent.startsWith('Remove')).click()`);
  await waitFor(`!!document.querySelector('dialog.dlg[open]')`, 8000);
  const one = await evaluate(`document.querySelector('dialog.dlg[open]').textContent`);
  check(/rme1/.test(one) && /carried back first/.test(one), 'remove: the dialog names it and says its conversations are carried back first');
  check(await submitDialog(), 'remove: Remove rme1');
  check(await waitFor(`!${TILE('rme1')}`, 20000) && !sessions().some((x) => x.name === 'rme1'), 'remove: rme1 is gone from the page and from doz sessions @mac');
  await waitFor(`!!${HEAD} && !${HEAD}.hidden`, 8000);
  await evaluate(`${HEAD}.click()`);
  await waitFor(`!!document.querySelector('dialog.dlg[open]')`, 8000);
  const all = await evaluate(`document.querySelector('dialog.dlg[open]').textContent`);
  check(/Remove 2 ended sessions/.test(all) && /rme2/.test(all) && /rme3/.test(all) && !/rmws/.test(all) && !/rmrun/.test(all),
    'remove: Remove all ended… lists the two left, not the running or the workspace\'s');
  check(await submitDialog(), 'remove: Remove all ended');
  check(await waitFor(`!${TILE('rme2')} && !${TILE('rme3')}`, 20000), 'remove: no ended tile is left to remove');
  const left = sessions().map((x) => x.name);
  check(left.includes('rmrun') && left.includes('rmws') && !left.includes('rme2') && !left.includes('rme3'), 'remove: the running and the workspace\'s session are still there');
  check(await waitFor(`!${HEAD} || ${HEAD}.hidden`, 8000), 'remove: Remove all ended… is gone with them');
  await leakSweep('removing ended sessions');
  // Put back what the rest of the walk expects: no session of these.
  doz(['workspace', 'release', 'demo', '@mac/rmws']);
  for (const s of ['rmrun', 'rmws']) { doz(['sessions', 'end', '@mac', s, '--yes']); doz(['sessions', 'end', '@mac', s, '--yes']); }
}

// ── a workspace's agents, filing, an agent's screen (chat on) ────────────────────────────────────────────────────────
const SUBMIT = `document.querySelector('dialog.dlg[open] button[type=submit]')`;
async function submitDialog() {
  await waitFor(`!!${SUBMIT} && !${SUBMIT}.disabled`, 8000);
  await evaluate(`${SUBMIT}.click()`);
  return waitFor(`!document.querySelector('dialog.dlg[open]')`, 30000);
}
const looseNames = () => (dozJSON(['workspace', 'ls', '--loose']) || { loose: [] }).loose.map((a) => a.name);
let macSession = null;
async function walkAgents() {
  // The Agents tab against the CLI.
  const show = dozJSON(['workspace', 'show', 'demo2']);
  await goHash('#/w/demo2/agents');
  check(await waitFor(`state.view === 'workspace' && state.wsTab === 'agents' && !!document.querySelector('[data-agents-table="demo2"]') && ${SHOWN}`, 10000),
    '#/w/demo2/agents → the Agents tab');
  const rows = (await evaluate(`[...document.querySelectorAll('[data-agents-table="demo2"] tr[data-agent-row]')].map((r) => r.dataset.agentRow).filter(Boolean)`)).sort();
  check(JSON.stringify(rows) === JSON.stringify(show.agents.map((a) => a.name).sort()), `…exactly the agents of doz workspace show demo2 --json (${rows.join(', ')})`);
  check(await evaluate(`document.querySelector('[data-agent-row="beta"] [data-place]')?.dataset.place === 'this Mac' && document.querySelector('[data-agent-row="beta"] [data-iso]')?.dataset.iso === 'micro VM'`),
    '…beta with its place and isolation chips (this Mac · micro VM)');
  check(await evaluate(`(() => { const c = document.querySelector('tr[data-kind="cloud"]'); return !!c && c.getAttribute('aria-disabled') === 'true' && /cloud worker/.test(c.textContent); })()`),
    '…the greyed cloud row, last');
  check(await evaluate(`!!document.querySelector('[data-wsa-view="grid"][disabled]') && /coming/.test(document.querySelector('[data-wsa-view="grid"]').textContent)`), '…Grid drawn disabled, "coming"');
  check(await evaluate(`document.querySelector('#ws [data-ws-tab="agents"]').getAttribute('aria-selected') === 'true' && document.querySelector('#ws .ws-body').hidden`),
    '…the Agents tab selected, the room hidden');
  check(await evaluate(`document.querySelector('a[data-add-worker="demo2"]')?.getAttribute('href') === '#/w/demo2/agents/new'`), '"+ Add a worker" leads to its page (#/w/demo2/agents/new)');
  await goHash('#/w/demo3/agents');
  check(await waitFor(`!!document.querySelector('[data-agents-table="demo3"] [data-agent-row="otto"] .acts-as-you')`, 10000), 'an unfenced manager\'s row reads "acts as you"');

  // Loose agents › Put in a workspace… → an existing workspace (demo): gamma.
  await goHash('#/mac/loose');
  await waitFor(`!!document.querySelector('[data-put-in="gamma"]')`, 10000);
  await evaluate(`document.querySelector('[data-put-in="gamma"]').click()`);
  check(await waitFor(`!!document.querySelector('dialog.dlg[open] [data-piw="gamma"]')`, 8000), 'Put in a workspace… opens its dialog for gamma');
  check(await evaluate(`/Only the workspace’s record changes; gamma keeps running as it is/.test(document.querySelector('dialog.dlg[open]').textContent)`), '…with the plan line');
  await evaluate(`(() => { const r = document.querySelector('[data-piw-ws="demo"]'); r.checked = true; r.dispatchEvent(new Event('change')); })()`);
  check(await evaluate(`/doz workspace adopt demo gamma/.test(document.querySelector('dialog.dlg[open] .piw-cmd').textContent)`), '…its command: doz workspace adopt demo gamma');
  check(await submitDialog(), '…Put in closes it');
  check(await waitFor(`!document.querySelector('[data-loose="gamma"]')`, 15000) && !looseNames().includes('gamma'), 'gamma leaves the loose list (page and CLI)');
  const demo = dozJSON(['workspace', 'show', 'demo']);
  check(demo.agents.some((a) => a.name === 'gamma') && demo.state === 'setting-up', `gamma is in demo, which stays setting up (${demo.state}: gamma is not running)`);
  await goHash('#/w/demo/agents');
  check(await waitFor(`!!document.querySelector('[data-agents-table="demo"] [data-agent-row="gamma"]')`, 10000), '…and joins demo\'s table');
  await goHash('#/w/demo');
  check(await waitFor(`state.view === 'workspace' && state.param === 'demo' && /setting up/.test(${text('#ws-head [data-ws-state]')})`, 10000), '#/w/demo still reads setting up');
  check(await evaluate(`api('workspaces/demo/log').then((r) => r.lines.some((l) => /adopted gamma/.test(l.text)))`), 'demo\'s log says "adopted gamma"');

  // A new workspace from a loose agent: delta (a new sandbox, never started).
  doz(['create', 'delta', '--image', 'lab', '--isolated']);
  await goHash('#/mac/loose');
  await waitFor(`!!document.querySelector('[data-put-in="delta"]')`, 15000);
  await evaluate(`document.querySelector('[data-put-in="delta"]').click()`);
  await waitFor(`!!document.querySelector('dialog.dlg[open] [data-piw="delta"]')`, 8000);
  await evaluate(`(() => { const r = document.querySelector('[data-piw-mode="new"]'); r.checked = true; r.dispatchEvent(new Event('change')); })()`);
  check(await evaluate(`document.querySelector('[data-piw-new]').value === 'delta' && document.querySelector('[data-piw-brief]').value === 'The work in delta.'`),
    'a new workspace: its name prefilled (delta) and the brief "The work in delta."');
  check(await evaluate(`/Its room #delta is made; nothing is posted/.test(document.querySelector('.piw-room').textContent)`), '…"Its room #delta is made; nothing is posted"');
  check(await submitDialog(), '…Put in closes it');
  const delta = dozJSON(['workspace', 'show', 'delta']);
  check(!!delta && delta.agents.some((a) => a.name === 'delta') && delta.rooms.some((r) => r.main && r.chatRoom === 'delta'), 'workspace delta made with delta in it, its room #delta');
  const posted = dozJSON(['chat', 'read', 'delta', '--last', '20']) || [];
  check(!posted.some((m) => m.from === 'ada' && m.kind !== 'change'), '…nothing posted in it');
  await goHash('#/home');
  check(await waitFor(`!!document.querySelector('[data-ws="delta"]')`, 10000), 'Home lists delta');

  // A harmless session on this Mac filed into a workspace that is setting up: started, nothing posted.
  const folder = PROJECTS + '/macws';
  mkdirSync(folder, { recursive: true });
  // `--store` before `--`: everything after it is the program's own argv.
  const ran = spawnSync(DOZ, ['run', '@mac', '-d', '--unfenced', '--session', 'wkmac', '--folder', folder, '--store', STORE, '--', '/bin/sleep', '600'],
    { env: ENV, encoding: 'utf8', timeout: 120_000 });
  if (ran.status === 0) {
    macSession = 'wkmac';
    doz(['workspace', 'new', 'macws', '--prompt-file', '-'], 'File a running session.\n');
    check(dozJSON(['workspace', 'show', 'macws']).state === 'setting-up', 'macws is setting up');
    const ses = (dozJSON(['sessions', '@mac']) || []).find((x) => x.name === 'wkmac');
    check(!!ses && !ses.ended && !ses.gone, 'wkmac runs on this Mac (/bin/sleep, unfenced)');
    await goHash('#/mac/loose');
    await waitFor(`!!document.querySelector('[data-put-in="@mac/wkmac"]')`, 15000);
    await evaluate(`document.querySelector('[data-put-in="@mac/wkmac"]').click()`);
    await waitFor(`!!document.querySelector('dialog.dlg[open] [data-piw="@mac/wkmac"]')`, 8000);
    check(await evaluate(`document.querySelector('.piw-hint').dataset.piwRunning === 'yes'`), '…the dialog says it is running');
    await evaluate(`(() => { const r = document.querySelector('[data-piw-ws="macws"]'); r.checked = true; r.dispatchEvent(new Event('change')); })()`);
    check(await submitDialog(), 'filing @mac/wkmac (running) into macws');
    check(await waitFor(`[...document.querySelectorAll('[data-filed="macws"]')].some((n) => /macws is started: wkmac was already running\. The brief was not posted/.test(n.textContent))`, 10000),
      '…the result line: started, the brief not posted');
    await goHash('#/w/macws');
    check(await waitFor(`state.param === 'macws' && !/setting up/.test(${text('#ws-head [data-ws-state]')}) && !document.querySelector('#ws .ws-setup')`, 10000),
      '…its pill is no longer setting up, and the setting-up banner is gone');
    const said = dozJSON(['chat', 'read', 'macws', '--last', '20']) || [];
    check(!said.some((m) => m.from === 'ada' && m.kind !== 'change'), '…nothing posted in its room');
  } else {
    console.log('  note no session on this Mac could start here (deckhold-mac?) — test-cli-workspace rows 36–37 hold that check');
  }

  // An agent's screen: gamma's sandbox page, framed.
  await goHash('#/w/demo/agent/gamma');
  check(await waitFor(`state.view === 'sandbox' && state.param === 'gamma' && state.frame && state.frame.workspace === 'demo' && !!document.querySelector('#sbx [data-agent-frame="demo/gamma"]')`, 15000),
    '#/w/demo/agent/gamma opens gamma\'s sandbox page, framed (breadcrumb, chips)');
  check(await waitFor(`location.hash.startsWith('#/w/demo/agent/gamma')`, 5000), '…its address stays #/w/demo/agent/gamma');
  check(await waitFor(`!!document.querySelector('#sbx [data-agent-in-ws="demo"]')`, 8000), '…the Overview has "In this workspace"');
  await evaluate(`(() => { const t = [...document.querySelectorAll('#sbx .tab-wrap')].find((x) => !x.classList.contains('is-active')) || document.querySelector('#sbx .tab-wrap'); t && (t.querySelector('button, .tab') || t).click(); renderTerminals(); })()`);
  await sleep(400);
  check(await evaluate(`location.hash.startsWith('#/w/demo/agent/gamma') && state.view === 'sandbox'`), `…switching its tabs keeps #/w/… (${await evaluate('location.hash')})`);
  await goHash('#/sandbox/gamma');
  check(await waitFor(`state.view === 'sandbox' && !state.frame && document.querySelector('#sbx [data-member-of]')?.dataset.memberOf === 'demo' && /In demo as gamma/.test(${text('#sbx [data-member-of]')})`, 10000),
    '#/sandbox/gamma is not redirected: it says "In demo as gamma — open it there"');
  await evaluate(`document.querySelector('#sbx [data-take-out="gamma"]').click()`);
  check(await waitFor(`/Take gamma out of demo/.test(document.querySelector('dialog.dlg[open]')?.textContent || '')`, 8000), 'Take out… asks, plainly');
  check(await submitDialog(), '…Take out closes it');
  check(await waitFor(`state.workspaces && !state.workspaces.workspaces.some((w) => (w.places || []).includes('gamma'))`, 10000) && looseNames().includes('gamma'), 'gamma is loose again');

  // A phone: the table is cards.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await goHash('#/w/demo2/agents');
  await waitFor(`!!document.querySelector('[data-agents-table="demo2"]')`, 10000);
  await sleep(400);
  const cards = await evaluate(`(() => { const t = document.querySelector('[data-agents-table="demo2"]'); return { head: getComputedStyle(t.querySelector('thead')).display,
    row: getComputedStyle(t.querySelector('tbody tr')).display, w: document.documentElement.scrollWidth }; })()`);
  await shot('agents-390');
  check(cards.head === 'none' && cards.row === 'flex' && cards.w <= 390, `at 390 px the agents table is cards, no sideways scroll (${cards.head}, ${cards.row}, ${cards.w} px)`);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await goHash('#/w/demo2/agents');
  await shot('agents-light');
}

// ── the New workspace wizard (chat on): #/new-workspace over Home, its four steps, the plan's gaps live, the two actions ──
const WIZ_NEXT = `document.querySelector('[data-wsn-next]')`;
/// The plan answered for what the wizard shows now (the latest request's name, and nothing still being asked).
const PLANNED = `(!!state.wsn && !!state.wsn.plan && state.wsn.plan.name === state.wsn.name)`;
async function wizNext(step) {
  await evaluate(`${WIZ_NEXT}.click()`);
  return waitFor(`!!state.wsn && state.wsn.step === ${step} && !!document.querySelector('[data-wsn-body]')`, 8000);
}
async function wizType(sel, value) { await setField(sel, value); await sleep(600); await waitFor(PLANNED, 10000); }
async function wizClose() {
  await evaluate(`document.querySelector('#wm-box [data-wm-close]').click()`);
  if (await waitFor(`!!document.querySelector('dialog.dlg[open]')`, 2000)) await submitDialog();
  return waitFor(`!state.modal`, 8000);
}
async function walkNewWorkspace() {
  const errorsBefore = pageErrors.length;
  const A = PROJECTS + '/wiz-a', B = PROJECTS + '/wiz-b', C = PROJECTS + '/wiz-c';
  for (const d of [A, B, C]) mkdirSync(d, { recursive: true });
  const yaml = 'name: wiz-a\nimage: claude-code\nnetwork: open\n';
  writeFileSync(A + '/doz_project.yaml', yaml);
  // 1. Home's New workspace opens the wizard over Home.
  await goHash('#/home');
  await waitFor(`state.view === 'home' && !!document.querySelector('[data-ws-new="home"]')`, 10000);
  await evaluate(`document.querySelector('[data-ws-new="home"]').click()`);
  check(await waitFor(`location.hash === '#/new-workspace' && state.modal === 'new-workspace' && state.view === 'home' && !!document.querySelector('[data-wsn="work"]')`, 10000),
    'wizard 1 Home\'s New workspace opens #/new-workspace over Home');
  check(await evaluate(`!!document.querySelector('#nav-ws-new:not([disabled])')`), 'wizard 1 …and the sidebar\'s Workspaces + is there');
  // 2. An empty prompt: the brief's gap, counted on step 1; typing clears it.
  check(await waitFor(`!!state.wsn?.plan && state.wsn.plan.gaps.some((g) => g.item === 'brief') && Number(document.querySelector('[data-wsn-step="work"] [data-step-count]')?.dataset.stepCount) >= 1`, 10000),
    'wizard 2 an empty prompt: the brief\'s gap, counted on step 1 ("N to set up")');
  await wizType('[data-wsn-brief]', 'Launch notes for the walk: short and plain.');
  check(await waitFor(`${PLANNED} && !state.wsn.plan.gaps.some((g) => g.item === 'brief') && state.wsn.name === 'launch-notes-for-the-walk'`, 10000),
    'wizard 2 typing clears it, and the name is suggested from the prompt (launch-notes-for-the-walk)');
  // 5. The stepper's count follows the plan.
  check(await evaluate(`document.querySelectorAll('[data-step-count]').length === 0`), 'wizard 5 the stepper\'s count follows the plan (none left)');
  // 3 and 4. A folder typed (its doz_project.yaml fills in Open), and a read-only one.
  await setField('[data-wsn-folder-input]', A);
  await evaluate(`document.querySelector('.wsn-folders .wsn-add button').click()`);
  await waitFor(`state.wsn.folders.length === 1`, 5000);
  await setField('[data-wsn-folder-input]', B + ':ro');
  await evaluate(`document.querySelector('.wsn-folders .wsn-add button').click()`);
  await sleep(700);
  check(await waitFor(`document.querySelectorAll('[data-wsn-folder]').length === 2 && document.querySelector('[data-wsn-folder-mode=${JSON.stringify(B)}]')?.value === 'ro'`, 8000),
    'wizard 3 a typed folder and a :ro one: two rows, the second read-only');
  check(await waitFor(`!!document.querySelector('[data-wsn-project]') && state.wsn.fromProject && ${PLANNED} && state.wsn.plan.lines.includes('network: open + the room')`, 12000),
    'wizard 4 the main folder\'s doz_project.yaml (network: open) fills in Open — "used to fill in choices"');
  check(/never written/.test(await evaluate(text('[data-wsn-project]'))) && readFileSync(A + '/doz_project.yaml', 'utf8') === yaml, 'wizard 4 …never written');
  // 6. No manager, right now: Create and start.
  await wizType('[data-wsn-name]', 'wiz1');
  check(await wizNext(1) && await evaluate(`!!document.querySelector('[data-wsn-bot="mira"]') && document.querySelector('[data-wsn-bot=""]').checked`),
    'wizard 6 step 2: the roster (mira) with "No manager — I manage" chosen');
  check(await wizNext(2) && await evaluate(`document.querySelector('[data-wsn-net="open"]').checked && document.querySelector('[data-wsn-wiso="unfenced"]').disabled`),
    'wizard 6 step 3: Open filled in; new workers never unfenced by default');
  check(await wizNext(3) && await waitFor(`${PLANNED} && state.wsn.plan.gaps.length === 0 && !document.querySelector('[data-wsn-create="now"]').disabled`, 10000),
    'wizard 6 step 4: no gap — Create and start enabled');
  const honest = await evaluate(text('[data-wsn-honest]'));
  check(honest === 'No manager: you drive.', 'wizard 6 the honest line: "No manager: you drive."');
  const lines = await evaluate(`state.wsn.plan.lines`);
  const copied = await evaluate(`document.querySelector('[data-wsn-commands]').textContent`);
  await evaluate(`document.querySelector('[data-wsn-create="now"]').click()`);
  check(await waitFor(`state.view === 'workspace' && state.param === 'wiz1' && !state.modal`, 60000), 'wizard 6 Create and start → #/w/wiz1');
  const w1 = dozJSON(['workspace', 'show', 'wiz1']) || {};
  const rA = realpath(A), rB = realpath(B);
  check(w1.flags?.startedAt && JSON.stringify(w1.folders?.map((f) => [f.path, f.mode, f.main])) === JSON.stringify([[rA, 'rw', true], [rB, 'ro', false]])
    && w1.defaults?.network === 'open' && w1.defaults?.isolation === 'fenced' && w1.origin?.project === rA + '/doz_project.yaml' && !w1.agents?.length
    && lines.includes('folders: 2 (1 read-only), main ' + tildeOf(rA)), 'wizard 6 doz workspace show wiz1 --json matches the review (started, two folders, open, fenced workers, from the project)');
  check(await waitFor(`location.hash === '#/w/wiz1'`, 5000), 'wizard 6 …it opens on its Home');
  await goHash('#/w/wiz1/room');
  check(await waitFor(`[...document.querySelectorAll('#chat-log .chat-row')].some((r) => /Launch notes for the walk/.test(r.textContent))`, 20000)
    && await waitFor(`/started the work/.test(${text('#chat-log .chat-sys[data-action="kicked-off"]')})`, 10000), 'wizard 6 #/w/wiz1/room: the kick-off bubble and "started the work"');
  // 7. The copied commands are doz workspace new … --dry-run's for the same choices.
  const dry = JSON.parse(doz(['workspace', 'new', 'wiz1', '--prompt-file', '-', '--folder', A, '--folder', B + ':ro', '--from-project', '--worker-isolation', 'fenced',
    '--start', '--dry-run', '--json'], 'Launch notes for the walk: short and plain.\n').stdout || '{}');
  check(dry.commands && copied === dry.commands + dry.startCommand + '\n', 'wizard 7 Copy as doz commands is exactly doz workspace new … --dry-run\'s commands (and the start)');

  // 8. mira, keep setting up: setting up, manager mira (fenced), nothing posted; the banner's gaps live.
  await goHash('#/new-workspace');
  await waitFor(`state.modal === 'new-workspace' && !!document.querySelector('[data-wsn="work"]') && state.wsn.brief === ''`, 10000);
  await wizType('[data-wsn-brief]', 'Keep it setting up.');
  await setField('[data-wsn-folder-input]', C);
  await evaluate(`document.querySelector('.wsn-folders .wsn-add button').click()`);
  await wizType('[data-wsn-name]', 'wiz2');
  await wizNext(1);
  await evaluate(`document.querySelector('[data-wsn-bot="mira"]').click()`);
  check(await waitFor(`state.wsn.manager === 'mira' && !!document.querySelector('[data-wsn-identity="mira"]')`, 5000), 'wizard 8 mira chosen: her identity shown (Change here)');
  await wizNext(2);
  check(await evaluate(`document.querySelector('[data-wsn-miso="fenced"]').checked`), 'wizard 8 the manager fenced by default');
  await wizNext(3);
  await evaluate(`document.querySelector('[data-wsn-when="later"]').click()`);
  await waitFor(`state.wsn.when === 'later' && ${PLANNED}`, 8000);
  check(/cannot start or stop agents/.test(await evaluate(text('[data-wsn-honest]'))), 'wizard 8 the honest line: a fenced manager can only talk in the room');
  await waitFor(`!document.querySelector('[data-wsn-create="later"]').disabled`, 10000);
  await evaluate(`document.querySelector('[data-wsn-create="later"]').click()`);
  check(await waitFor(`state.view === 'workspace' && state.param === 'wiz2' && !state.modal`, 60000), 'wizard 8 Create, keep setting up → #/w/wiz2');
  const w2 = dozJSON(['workspace', 'show', 'wiz2']) || {};
  const m2 = (w2.agents || []).find((a) => a.role === 'manager');
  const posts2 = (dozJSON(['chat', 'read', 'wiz2', '--last', '50']) || []).filter((m) => m.from === 'ada' && m.kind !== 'change');
  check(w2.state === 'setting-up' && m2?.bot === 'mira' && m2?.isolation === 'fenced' && posts2.length === 0, 'wizard 8 setting up, manager mira (fenced), nothing posted');
  check(await waitFor(`!!document.querySelector('[data-ws-setup]') && !!document.querySelector('[data-ws-start="wiz2"]')`, 10000), 'wizard 8 the setting-up banner with its Start');
  const before = Number(await evaluate(`document.querySelector('[data-ws-setup]').dataset.wsSetup`));
  rmSync(C, { recursive: true, force: true });
  await goHash('#/home');
  await goHash('#/w/wiz2');
  check(await waitFor(`Number(document.querySelector('[data-ws-setup]')?.dataset.wsSetup) === ${before + 1} && !!document.querySelector('[data-ws-setup] [data-gap="folder"]')
    && document.querySelector('[data-ws-start="wiz2"]').disabled`, 15000), `wizard 8 removing its folder on disk adds the folder gap (${before} → ${before + 1}); Start disabled`);
  mkdirSync(C, { recursive: true });

  // 9. Unfenced asks for the confirmation, and the review says "acts as you".
  await goHash('#/new-workspace');
  await waitFor(`state.modal === 'new-workspace' && !!state.wsn`, 10000);
  await wizType('[data-wsn-brief]', 'An unfenced manager.');
  await wizType('[data-wsn-name]', 'wiz3');
  await wizNext(1);
  await evaluate(`document.querySelector('[data-wsn-bot="mira"]').click()`);
  await wizNext(2);
  await evaluate(`document.querySelector('[data-wsn-miso="unfenced"]').click()`);
  check(await waitFor(`!!document.querySelector('dialog.dlg[open][data-wsn-confirm]') && document.querySelector('dialog.dlg[open] button[type=submit]').disabled`, 5000),
    'wizard 9 unfenced opens the confirmation ("acts as you"), its button waiting for the tick');
  await evaluate(`document.querySelector('dialog.dlg[open] button.quiet').click()`);
  check(await waitFor(`!document.querySelector('dialog.dlg[open]') && state.wsn.managerIsolation === 'fenced'`, 5000), 'wizard 9 …cancelled: back to fenced');
  // (its close event redraws the step — wait for it; then the label, as a person clicks it)
  await sleep(400);
  await evaluate(`document.querySelector('[data-wsn-miso="unfenced"]').closest('label').click()`);
  await tick();
  await submitDialog();
  check(await waitFor(`state.wsn.managerIsolation === 'unfenced' && state.wsn.unfencedConfirmed && !!document.querySelector('[data-wsn-manager-iso="unfenced"] .acts-as-you')`, 5000),
    'wizard 9 …confirmed: unfenced, the row marked "acts as you"');
  await wizNext(3);
  check(await waitFor(`${PLANNED} && state.wsn.plan.lines.includes('manager: mira · unfenced · acts as you') && !!document.querySelector('[data-wsn-lines] .acts-as-you')
    && /an unfenced manager acts as you/.test(${text('[data-wsn-honest]')})`, 10000), 'wizard 9 the review and the honest line say "acts as you"');
  await wizClose();

  // 10. "+ A new agent / bot…" and back, the wizard's choices intact.
  await goHash('#/new-workspace');
  await waitFor(`state.modal === 'new-workspace' && !!state.wsn && state.wsn.brief === ''`, 10000);
  await wizType('[data-wsn-brief]', 'A return trip.');
  await wizType('[data-wsn-name]', 'wiz4');
  await wizNext(1);
  await evaluate(`document.querySelector('[data-wsn-new-bot]').click()`);
  check(await waitFor(`state.view === 'bot' && !state.modal && !!document.querySelector('[data-bot-form="~new"]') && !!document.querySelector('[data-bot-return]')`, 10000),
    'wizard 10 "+ A new agent / bot…" opens the editor, saying it comes back');
  await setField('[data-bot-form] input[data-bf="name"]', 'vera');
  await evaluate(`document.querySelector('[data-bot-make]').click()`);
  check(await waitFor(`state.modal === 'new-workspace' && !!state.wsn && state.wsn.brief === 'A return trip.' && state.wsn.name === 'wiz4' && state.wsn.step === 1
    && state.wsn.manager === 'vera' && !!document.querySelector('[data-wsn-bot="vera"]')?.checked`, 30000), 'wizard 10 …made vera and came back: the choices intact, vera chosen');
  await wizClose();
  // 11. ?bot=mira chooses her.
  await goHash('#/new-workspace?bot=mira');
  check(await waitFor(`state.modal === 'new-workspace' && state.wsn?.manager === 'mira'`, 10000), 'wizard 11 #/new-workspace?bot=mira chooses her');
  await wizClose();
  // 13. A phone: the steps' choices stack.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await goHash('#/new-workspace');
  await waitFor(`state.modal === 'new-workspace' && !!state.wsn`, 10000);
  await wizType('[data-wsn-brief]', 'On a phone.');
  await wizNext(1); await wizNext(2);
  await sleep(400);
  await shot('new-workspace-390');
  const stack = await evaluate(`(() => { const c = [...document.querySelectorAll('.wsn-row .wiz-choice')].slice(0, 2).map((e) => e.getBoundingClientRect());
    const box = document.getElementById('wm-box'); return { below: c.length === 2 && c[1].top >= c[0].bottom - 1, w: box.scrollWidth - box.clientWidth }; })()`);
  check(stack.below && stack.w <= 0, 'wizard 13 at 390 px the steps\' choices stack, no sideways scroll');
  await wizClose();
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  // 12. Another computer: 403 for both actions and the plan route is ServeHTTPTests' (the walk's dashboard has no LAN side).
  check(pageErrors.length === errorsBefore, 'wizard: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore).join(' | ') : ''));
}

// ── Agents / Bots (chat on): the roster, a new bot from the page, an edit, elsewhere only in a terminal, a new token,
// adopting a participant, retiring, adding a bot to a room — and after every row the leak sweep ────────────────────────
const knownTokens = [];
const swept = { dom: 0, api: 0, console: 0, errors: 0, storage: 0, cache: 0, indexeddb: 0, files: 0, ps: 0 };
let sweeps = 0;
/// How many times a known token or the token shape `dzc_` appears in `s`.
function hits(s) {
  const t = String(s || '');
  let n = (t.match(/dzc_/g) || []).length;
  for (const k of knownTokens) if (k) n += t.split(k).length - 1;
  return n;
}
/// The leak sweep: every token the walk knows and the `dzc_` shape, in the page's DOM, every /api/ answer read so far, the
/// console, page errors, this origin's local and session storage, CacheStorage, IndexedDB, the store's operations file,
/// ui.log (and doz ui's own output), daemon.log, the chat server's server.log and every process's command line. ZERO.
async function leakSweep(row) {
  sweeps++;
  const found = {
    dom: hits(await evaluate(`document.documentElement.outerHTML`)),
    api: hits(apiBodies.join('\n')),
    console: hits(consoleLines.join('\n')),
    errors: hits(pageErrors.join('\n')),
    storage: hits(await evaluate(`(() => { const out = []; for (const s of [localStorage, sessionStorage]) for (let i = 0; i < s.length; i++) { const k = s.key(i); out.push(k, s.getItem(k)); } return out.join('\\n'); })()`)),
    cache: hits(await evaluate(`(async () => { const out = []; for (const n of await caches.keys()) { const c = await caches.open(n);
      for (const r of await c.keys()) { out.push(r.url); try { out.push(await (await c.match(r)).text()); } catch (_) { /* opaque */ } } } return out.join('\\n'); })()`)),
    indexeddb: hits(await evaluate(`(async () => { const out = []; for (const d of (await indexedDB.databases()) || []) { out.push(d.name);
      const db = await new Promise((res, rej) => { const q = indexedDB.open(d.name); q.onsuccess = () => res(q.result); q.onerror = () => rej(q.error); });
      for (const s of db.objectStoreNames) { const all = await new Promise((res) => { const q = db.transaction(s).objectStore(s).getAll(); q.onsuccess = () => res(q.result); q.onerror = () => res([]); });
        out.push(JSON.stringify(all)); } db.close(); } return out.join('\\n'); })()`)),
    files: hits([STORE + '/ui.operations.json', STORE + '/ui.log', STORE + '/daemon.log', STORE + '/chat/server.log']
      .map((f) => (existsSync(f) ? readFileSync(f, 'utf8') : '')).join('\n') + uiOut),
    ps: hits(spawnSync('ps', ['-axww', '-o', 'command'], { encoding: 'utf8' }).stdout),
  };
  for (const k of Object.keys(found)) swept[k] += found[k];
  const total = Object.values(found).reduce((a, b) => a + b, 0);
  check(total === 0, `the leak sweep after ${row}: no token anywhere (` + Object.entries(found).map(([k, v]) => k + ' ' + v).join(', ') + ')');
}
/// Open a ⋯ (by its aria-label) and choose an item by its label.
async function menuPick(label, item) {
  await evaluate(`document.querySelector('button[aria-label=${JSON.stringify(label)}]').click()`);
  await waitFor(`[...document.querySelectorAll('[role=menuitem]')].some((m) => m.offsetParent && m.textContent.startsWith(${JSON.stringify(item)}))`, 5000);
  await evaluate(`[...document.querySelectorAll('[role=menuitem]')].find((m) => m.offsetParent && m.textContent.startsWith(${JSON.stringify(item)})).click()`);
}
const DIALOG = `document.querySelector('dialog.dlg[open]')`;
async function tick() { await waitFor(`!!${DIALOG}?.querySelector('[data-confirm-check]')`, 8000); await evaluate(`(() => { const b = ${DIALOG}.querySelector('[data-confirm-check]'); b.click(); })()`); }
async function setField(sel, value, ev = 'input') {
  return evaluate(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return false; e.value = ${JSON.stringify(value)};
    e.dispatchEvent(new Event(${JSON.stringify(ev)}, { bubbles: true })); return true; })()`);
}
/// A crafted action from the page (its own session and CSRF token): {status, body}.
const craft = (body) => evaluate(`(async () => { const r = await fetch('/api/v1/actions', { method: 'POST', credentials: 'same-origin',
  headers: { 'Content-Type': 'application/json', 'X-Doz-CSRF': state.csrf }, body: ${JSON.stringify(JSON.stringify(body))} });
  return { status: r.status, body: await r.text() }; })()`);
const botShow = (n) => dozJSON(['bot', 'show', n]) || {};
async function walkBots() {
  const errorsBefore = pageErrors.length;
  // Made in a terminal: a bot elsewhere (its token to a file), tmp1 to retire, and olda, a plain participant to adopt.
  check(doz(['bot', 'new', 'far', '--agent', 'codex', '--isolation', 'elsewhere', '--to-file', S + '/far.token']).status === 0, 'bot new far --isolation elsewhere --to-file (the CLI)');
  knownTokens.push(readFileSync(S + '/far.token', 'utf8').trim());
  check(doz(['bot', 'new', 'tmp1', '--agent', 'codex']).status === 0, 'bot new tmp1 (to retire)');
  check(doz(['chat', 'add', 'olda', '--to-file', S + '/olda.token']).status === 0, 'chat add olda --to-file (a participant to adopt)');
  knownTokens.push(readFileSync(S + '/olda.token', 'utf8').trim());
  check(knownTokens.every((t) => /^dzc_/.test(t)), 'the walk knows far\'s and olda\'s tokens (from their files — never printed)');
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);

  // 1. The roster against doz bot ls --json, the new columns included.
  const cli = (dozJSON(['bot', 'ls']) || { bots: [] }).bots;
  await goHash('#/bots');
  await waitFor(`state.view === 'bots' && document.querySelectorAll('[data-bot]').length === ${cli.length}`, 10000);
  const rows = await evaluate(`[...document.querySelectorAll('[data-bot]')].map((r) => ({ name: r.dataset.bot, keeper: r.querySelector('[data-bot-keeper]').dataset.botKeeper,
    iso: r.querySelector('[data-iso]').dataset.iso, acts: !!r.querySelector('.acts-as-you') }))`);
  check(JSON.stringify(rows.map((r) => r.name).sort()) === JSON.stringify(cli.map((b) => b.name).sort()), `1 the roster lists what doz bot ls --json does (${cli.map((b) => b.name).join(', ')})`);
  check(cli.every((b) => { const r = rows.find((x) => x.name === b.name); return r && r.keeper === b.tokenKeeper && r.iso === b.isolation && r.acts === (b.isolation === 'unfenced'); }),
    '1 …each row\'s key keeper and isolation as the CLI says ("acts as you" on the unfenced one)');
  await leakSweep('row 1 (the roster)');

  // 2. #/bots/~new makes nova: fenced (the default), inbox, instructions; its fingerprint as the CLI says.
  await goHash('#/bots/~new');
  check(await waitFor(`state.view === 'bot' && !!document.querySelector('[data-bot-form="~new"]')`, 10000), '2 #/bots/~new → the new bot\'s form');
  check(await evaluate(`document.querySelector('[data-bf-choice="isolation:fenced"]').checked && !document.querySelector('[data-bf-choice="isolation:unfenced"]').checked`),
    '2 …fenced by default; unfenced never preselected');
  check(await evaluate(`document.querySelector('[data-bf-choice="isolation:elsewhere"]').disabled
    && /doz bot new .* --isolation elsewhere --to-file/.test(document.querySelector('[data-bot-form] .bf-elsewhere')?.dataset.cmd || '')`), '2 …elsewhere disabled, with its command');
  await setField('[data-bot-form] input[data-bf="name"]', 'nova');
  await evaluate(`document.querySelector('[data-bf-choice="deliver:inbox"]').click()`);
  await setField('[data-bot-form] textarea[data-bf="instructions"]', 'Answer in one line.\nAsk before anything costly.\n');
  check(await waitFor(`/collects its messages with dozchat/.test(${text('[data-bot-form]')})`, 3000), '2 inbox for a fenced bot says it collects its messages with dozchat');
  await evaluate(`document.querySelector('[data-bot-make]').click()`);
  check(await waitFor(`location.hash === '#/bots/nova' && !!document.querySelector('[data-bot-page="nova"] [data-bot-fp]')`, 30000), '2 Make → #/bots/nova' + ((await soft(`document.querySelector('[data-bf-error]')?.textContent || ''`)) || '').replace(/^(.+)$/, ' (the form says: $1)'));
  const nova = botShow('nova');
  check(nova.isolation?.default === 'fenced' && nova.deliver === 'inbox' && nova.instructions?.bytes > 0 && nova.token?.keeper === 'dozable', '2 …doz bot show nova: fenced, inbox, instructions, held');
  check(await evaluate(`document.querySelector('[data-bot-fp]').dataset.botFp`) === nova.token?.fingerprint && /held by Dozable · fp /.test(await evaluate(text('[data-bot-key]'))),
    '2 the page\'s fingerprint is doz bot show nova --json\'s: "held by Dozable · fp …"');
  await leakSweep('row 2 (a new bot)');

  // 3. Its instructions edited: the CLI's sha256 changes; the page says they apply from its next session.
  const sha = nova.instructions?.sha256;
  await goHash('#/bots/nova/instructions');
  await waitFor(`!!document.querySelector('[data-bot-form="nova/instructions"] textarea')`, 10000);
  check(/applies from its next session/.test(await evaluate(text('[data-bot-form]'))), '3 the instructions tab says a change applies from its next session');
  await setField('[data-bot-form] textarea[data-bf="instructions"]', 'Answer in two lines.\n');
  await evaluate(`document.querySelector('[data-bot-save]').click()`);
  check(await waitFor(`!!document.querySelector('[data-bot-last]')`, 30000), '3 Save → the change\'s line');
  check(botShow('nova').instructions?.sha256 !== sha, '3 …doz bot show: the instructions\' sha256 changed');
  await leakSweep('row 3 (an edit)');

  // 4. Elsewhere is the terminal's: disabled with its command; a crafted bot-new elsewhere 400; a crafted new token for far
  // refused by the daemon (heldOnly), its fingerprint unchanged.
  await goHash('#/bots/nova/runs');
  await waitFor(`!!document.querySelector('[data-bot-form="nova/runs"]')`, 10000);
  check(await evaluate(`document.querySelector('[data-bf-choice="isolation:elsewhere"]').disabled && /--isolation elsewhere --to-file/.test(document.querySelector('.bf-elsewhere')?.dataset.cmd || '')`),
    '4 How it runs: elsewhere disabled, with the command');
  const bad = await craft({ action: 'bot-new', name: 'far2', agent: 'codex', isolation: 'elsewhere' });
  check(bad.status === 400 && /in a terminal on this Mac/.test(bad.body) && !/dzc_/.test(bad.body), `4 a crafted bot-new elsewhere → 400 with the command (${bad.status})`);
  const farFp = botShow('far').token?.fingerprint;
  const rot = await craft({ action: 'bot-token', name: 'far', confirm: 'far' });
  const opId = (() => { try { return JSON.parse(rot.body).id; } catch (_) { return null; } })();
  check(rot.status === 202 && !!opId, '4 a crafted bot-token for far is taken as an operation (202)');
  check(await waitFor(`(() => { const o = state.ops.get(${JSON.stringify(opId)}); return !!o && o.state === 'failed' && /a bot elsewhere gets its token in a terminal on this Mac/.test(o.text); })()`, 20000),
    '4 …and refused by the daemon: a bot elsewhere gets its token in a terminal');
  check(botShow('far').token?.fingerprint === farFp, '4 …far\'s fingerprint unchanged');
  await leakSweep('row 4 (elsewhere)');

  // 5. A new token for nova, with the tick: its fingerprint changes; nothing shown.
  const fp0 = botShow('nova').token?.fingerprint;
  await goHash('#/bots/nova');
  await waitFor(`!!document.querySelector('[data-bot-page="nova"]')`, 10000);
  await menuPick('More for nova', 'New token…');
  check(await waitFor(`/the old one is refused from now on; a running nova stops working until started again/i.test(${DIALOG}?.textContent || '')`, 8000), '5 New token… says the old one is refused and a running nova stops');
  await tick();
  check(await submitDialog(), '5 …ticked and replaced');
  const fp1 = botShow('nova').token?.fingerprint;
  check(fp1 && fp1 !== fp0, '5 nova\'s fingerprint changed (doz bot show)');
  check(await waitFor(`document.querySelector('[data-bot-fp]')?.dataset.botFp === ${JSON.stringify(fp1)}`, 10000), '5 …and the page shows the new fingerprint, no token');
  await leakSweep('row 5 (a new token)');

  // 6. Adopt olda from the page: Q9's words, the tick; chat who marks it a bot; its old token is refused (401).
  await goHash('#/bots');
  await waitFor(`!!document.querySelector('[data-bots-adopt]')`, 10000);
  await evaluate(`document.querySelector('[data-bots-adopt]').click()`);
  await waitFor(`!!${DIALOG}?.querySelector('select[name=who]')`, 8000);
  await setField('dialog.dlg[open] select[name=who]', 'olda', 'change');
  await waitFor(`!!${SUBMIT} && !${SUBMIT}.disabled`, 8000);
  await evaluate(`${SUBMIT}.click()`);                // the chooser closes and the adopt dialog opens at once
  check(await waitFor(`/olda becomes a bot\\. Its token is replaced: Dozable never had the old one\\. An agent still using the old token stops working the moment this runs\\./.test(${DIALOG}?.textContent || '')`, 8000),
    '6 the adopt dialog says the token is replaced, in Q9\'s words');
  await setField('dialog.dlg[open] select[name=agent]', 'codex', 'change');
  await tick();
  check(await submitDialog(), '6 …ticked: olda is a bot');
  const who = dozJSON(['chat', 'who']);
  const oldaRow = (Array.isArray(who) ? who : who?.participants || []).find((r) => r.name === 'olda');
  check(oldaRow?.bot === true, '6 doz chat who marks olda a bot');
  const old = await fetch(`http://127.0.0.1:${chatPagePort}/agent/receive?wait=0`, { headers: { Authorization: 'Bearer ' + knownTokens[1] } }).then((r) => r.status, () => 0);
  check(old === 401, `6 olda's old token is refused (${old})`);
  await leakSweep('row 6 (adopt)');

  // 7. Retire tmp1: it leaves the roster, its screen says retired, "Show retired" lists only the retired; retiring a bot in a
  // workspace (otto manages demo3) is refused with the release command, the dialog open.
  await goHash('#/bots/tmp1');
  await waitFor(`!!document.querySelector('[data-bot-page="tmp1"]')`, 10000);
  await menuPick('More for tmp1', 'Retire…');
  await tick();
  check(await submitDialog(), '7 Retire… tmp1, ticked');
  check(await waitFor(`!!document.querySelector('[data-bot-retired]')`, 15000) || (await goHash('#/bots/tmp1'), await waitFor(`!!document.querySelector('[data-bot-retired]')`, 10000)),
    '7 tmp1\'s screen reads retired');
  await goHash('#/bots');
  check(await waitFor(`!document.querySelector('[data-bot="tmp1"]') && !!document.querySelector('[data-bot="nova"]')`, 10000), '7 tmp1 leaves the roster');
  await evaluate(`document.querySelector('[data-bots-retired]').click()`);
  const retired = (dozJSON(['bot', 'ls', '--retired']) || { bots: [] }).bots.map((b) => b.name).sort();
  check(await waitFor(`document.querySelector('[data-bots-page]')?.dataset.botsPage === 'retired'
    && JSON.stringify([...document.querySelectorAll('[data-bot]')].map((r) => r.dataset.bot).sort()) === ${JSON.stringify(JSON.stringify(retired))}`, 10000),
    `7 Show retired lists only the retired (${retired.join(', ')})`);
  await evaluate(`document.querySelector('[data-bots-retired]').click()`);
  await goHash('#/bots/otto');
  await waitFor(`!!document.querySelector('[data-bot-page="otto"]')`, 10000);
  await menuPick('More for otto', 'Retire…');
  await tick();
  await evaluate(`${SUBMIT}.click()`);
  check(await waitFor(`/doz workspace release demo3 otto/.test(${DIALOG}?.querySelector('.dlg-error')?.textContent || '')`, 20000),
    '7 retiring otto (in demo3) is refused with "doz workspace release demo3 otto", the dialog open');
  await evaluate(`${DIALOG}.close()`);
  check(!(dozJSON(['bot', 'ls']) || { bots: [] }).bots.find((b) => b.name === 'otto')?.retiredAt, '7 …otto is not retired');
  await leakSweep('row 7 (retire)');

  // 8. Add otto to the room other, as a voice: the chat server's /invite, no token step.
  await menuPick('More for otto', 'Include in a room…');
  await waitFor(`!!${DIALOG}?.querySelector('select[name=room]')`, 8000);
  check(await evaluate(`!${DIALOG}.querySelector('input[type=password], [data-secret]')`), '8 Include in a room…: no token step');
  await setField('dialog.dlg[open] select[name=room]', 'other', 'change');
  check(await submitDialog(), '8 …otto invited to other');
  let rooms = null;
  for (let i = 0; i < 30 && !(rooms && (rooms.other || []).includes('otto')); i++) { rooms = dozJSON(['chat', 'rooms']); await sleep(300); }
  check((rooms?.other || []).includes('otto'), '8 doz chat rooms: otto is in other');
  const ottoWho = ((d) => (Array.isArray(d) ? d : d?.participants || []).find((r) => r.name === 'otto'))(dozJSON(['chat', 'who']));
  check((ottoWho?.rooms || []).includes('other'), '8 doz chat who: otto\'s rooms include other');
  await leakSweep('row 8 (add to a room)');

  check(pageErrors.length === errorsBefore, '10 no page error on any bot screen' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  // The sweep's positive control: it finds a token where there is one, and it read what it says it read.
  check(hits('x ' + knownTokens[0] + ' y') >= 1 && hits('dzc_') === 1, 'the leak sweep finds a known token and the dzc_ shape when they are there');
  check(apiBodies.length > 20 && existsSync(STORE + '/daemon.log') && existsSync(STORE + '/chat/server.log') && existsSync(STORE + '/ui.operations.json'),
    `…and it read ${apiBodies.length} /api/ answers, daemon.log, server.log and the operations file`);
  console.log(`  leak sweep: ${sweeps} sweeps, ${apiBodies.length} /api/ answers — ` + Object.entries(swept).map(([k, v]) => k + ' ' + v).join(', '));
}

// ── Add a worker (chat on): #/w/demo2/agents/new, the plan live, a fenced FAKE claude added and ended, the guide ───────
const startedWorkers = [];
const AW_PLANNED = `(!!state.aw && !!state.aw.plan && !state.aw.asking)`;
async function awType(sel, value) { await setField(sel, value); await sleep(500); await waitFor(AW_PLANNED, 10000); }
async function awPick(sel) { await evaluate(`(() => { const i = document.querySelector(${JSON.stringify(sel)}); i.checked = true; i.dispatchEvent(new Event('change', { bubbles: true })); })()`); await sleep(500); await waitFor(AW_PLANNED, 10000); }
const workerLs = (w) => (dozJSON(['worker', 'ls', w, '--all']) || { agents: [] }).agents;
const chatLines = (room) => { const r = dozJSON(['chat', 'read', room, '--last', '100']); return Array.isArray(r) ? r : []; };
async function walkAddWorker() {
  const errorsBefore = pageErrors.length;
  doz(['config', 'set', 'mac.account', 'none']);
  // 1. From the Agents tab: the page, the table's four columns, cloud disabled, fenced preselected.
  await goHash('#/w/demo2/agents');
  await waitFor(`!!document.querySelector('a[data-add-worker="demo2"]')`, 10000);
  await evaluate(`document.querySelector('a[data-add-worker="demo2"]').click()`);
  check(await waitFor(`location.hash === '#/w/demo2/agents/new' && state.view === 'addworker' && !!document.querySelector('[data-add-worker-page="demo2"] [data-aw-compare]') && ${AW_PLANNED}`, 15000),
    'add 1 "+ Add a worker" in the Agents tab opens #/w/demo2/agents/new');
  const cols = await evaluate(`[...document.querySelectorAll('[data-aw-compare] thead th[data-col]')].map((t) => t.dataset.col)`);
  check(JSON.stringify(cols) === '["vm","fenced","unfenced","cloud"]', `add 1 the comparison table's columns: micro VM, fenced, unfenced, cloud (${cols})`);
  check(await evaluate(`document.querySelector('[data-aw-col="cloud"]').disabled && document.querySelector('[data-aw-col="fenced"]').checked && !document.querySelector('[data-aw-col="unfenced"]').checked`),
    'add 1 cloud drawn disabled (later); fenced preselected, unfenced not');
  check(await evaluate(`[...document.querySelectorAll('[data-aw-compare] thead [data-iso-guide]')].map((a) => a.getAttribute('href')).join(' ') === '#/guide/isolation/vm #/guide/isolation/fenced #/guide/isolation/unfenced'`),
    'add 1 each heading is a chip that opens the guide at its choice');
  // 2. The plan live: the name, the place; vm shows its size; unfenced needs the tick (never added here).
  await awType('[data-aw-task]', 'List the files of the walk.');
  const dry = dozJSON(['worker', 'add', 'demo2', '--task', 'List the files of the walk.', '--dry-run']) || {};
  const p2 = await evaluate(`state.aw.plan`);
  check(p2.name && p2.name === dry.name && p2.place === dry.place && p2.place === '@mac/demo2-' + p2.name && !p2.problem,
    `add 2 the live plan: ${p2.name} on ${p2.place}, as --dry-run says (${dry.name}, ${dry.place})`);
  check(await evaluate(`document.querySelector('[data-aw-name]').placeholder === ${JSON.stringify(dry.name || '?')} && !document.querySelector('[data-aw-add]').disabled`),
    'add 2 the name\'s placeholder is the plan\'s next name; Add and start enabled');
  await awPick('[data-aw-col="vm"]');
  check(await evaluate(`!document.querySelector('.aw-size-row').hidden && state.aw.plan.isolation === 'vm' && state.aw.plan.sandbox === 'demo2-' + state.aw.plan.name`),
    'add 2 micro VM: CPUs and memory shown, the plan a sandbox of its own');
  await awPick('[data-aw-col="unfenced"]');
  check(await evaluate(`!document.querySelector('.aw-tick').hidden && document.querySelector('[data-aw-add]').disabled && state.aw.plan.actsAsYou === true`)
    && /It acts as you: your files, Keychain and network/.test(await evaluate(text('.aw-tick'))),
    'add 2 unfenced: the tick "It acts as you: your files, Keychain and network", Add disabled until it is ticked');
  await awPick('[data-aw-col="fenced"]');
  check(await evaluate(`document.querySelector('.aw-tick').hidden && !document.querySelector('[data-aw-add]').disabled`), 'add 2 back to fenced: no tick, Add enabled');
  // 3. A bot live elsewhere is greyed with the sentence; a taken name's refusal beside the name; nothing changes.
  const wb = doz(['bot', 'new', 'wally', '--agent', 'claude-code']);
  const wr = doz(['worker', 'add', 'wiz1', '--from-bot', 'wally', '--task', 'wait in wiz1']);
  const wally = (dozJSON(['bot', 'ls']) || { bots: [] }).bots.find((b) => b.name === 'wally');
  if (wr.status === 0) startedWorkers.push(['wiz1', 'wally']);
  await goHash('#/w/demo2/agents');
  await goHash('#/w/demo2/agents/new');
  await waitFor(`state.view === 'addworker' && ${AW_PLANNED}`, 15000);
  const before = JSON.stringify(workerLs('demo2'));
  const greyed = wr.status === 0 && await waitFor(`(() => { const o = document.querySelector('[data-aw-bot] option[value="wally"]'); return !!o && o.disabled && /wally already works in wiz1, which is running\. For now a bot runs in one live workspace at a time/.test(o.dataset.why || ''); })()`, 8000);
  const seen = greyed ? '' : ` — bot new ${wb.status}, worker add ${wr.status} ${(wr.stderr || '').trim().split('\n').pop() || ''}, doz bot ls: worksIn ${wally?.worksIn ?? '?'}, `
    + `the page: ${await evaluate(`(() => { const o = document.querySelector('[data-aw-bot] option[value="wally"]'); return o ? 'disabled ' + o.disabled + ', why ' + (o.dataset.why || '-') : 'no option (bots read: ' + (state.bots?.bots || []).map((b) => b.name + ':' + (b.worksIn || '-')).join(' ') + ')'; })()`)}`;
  check(greyed, 'add 3 a bot live in another workspace (wally works in wiz1) is greyed with the sentence' + seen);
  await awType('[data-aw-task]', 'List the files of the walk.');
  await awType('[data-aw-name]', 'mira');
  const refusal = dozJSON(['worker', 'add', 'demo2', 'mira', '--task', 'x', '--dry-run']) || {};
  check(await waitFor(`state.aw.plan.problem?.field === 'name' && !document.querySelector('[data-aw-problem="name"]').hidden && document.querySelector('[data-aw-add]').disabled`, 8000)
    && (await evaluate(text('[data-aw-problem="name"]'))) === (refusal.problem?.text || '?'), `add 3 a taken name: the add's sentence beside the name (${refusal.problem?.text}), Add disabled`);
  check(JSON.stringify(workerLs('demo2')) === before, 'add 3 …doz worker ls demo2 unchanged');
  await awType('[data-aw-name]', '');
  // 4. Show the command is --dry-run's.
  await evaluate(`document.querySelector('[data-aw-show-command]').click()`);
  const shown = await evaluate(`document.querySelector('[data-aw-command] [data-cmd]')?.dataset.cmd`);
  const dry4 = dozJSON(['worker', 'add', 'demo2', '--task', 'List the files of the walk.', '--dry-run']) || {};
  check(shown && shown === dry4.command, `add 4 Show the command is doz worker add … --dry-run's (${shown})`);
  // 5. Add and start: in the panel, in chat who, and its "is up" line.
  const name = await evaluate(`state.aw.plan.name`);
  await evaluate(`document.querySelector('[data-aw-add]').click()`);
  check(await waitFor(`location.hash === '#/w/demo2' && state.view === 'workspace'`, 60000), `add 5 Add and start → #/w/demo2`);
  startedWorkers.push(['demo2', name]);
  const row = workerLs('demo2').find((a) => a.name === name);
  check(row && row.role === 'worker' && row.isolation === 'fenced' && row.task === 'List the files of the walk.', `add 5 doz worker ls: ${name}, fenced, its task`);
  await goHash('#/w/demo2/agents/new');
  await waitFor(`state.view === 'addworker' && !!document.querySelector('[data-row="control"] td[data-col="fenced"]')`, 10000);
  const cell = await evaluate(text('[data-row="control"] td[data-col="fenced"]'));
  check(row && cell === row.control, `add 1 the table's control words are worker ls's (${cell})`);
  await goHash('#/w/demo2');
  check(await waitFor(`!!document.querySelector('#ws [data-ws-agent=${JSON.stringify(name)}]')`, 20000), `add 5 ${name} in the side panel`);
  let who = null;
  for (let i = 0; i < 20 && !(who && JSON.stringify(who).includes('"' + name + '"')); i++) { who = dozJSON(['chat', 'who']); await sleep(300); }
  check(JSON.stringify(who || {}).includes('"' + name + '"'), `add 5 doz chat who lists ${name}`);
  let up = false;
  for (let i = 0; i < 100 && !up; i++) { up = chatLines('demo2').some((m) => m.from === name && String(m.content || '').startsWith(name + ' is up: You are ' + name)); if (!up) await sleep(300); }
  check(up, `add 5 "${name} is up" — the fenced FAKE claude read its START and said so in the room`);
  // 6. End… with its tick.
  await goHash('#/w/demo2/agents');
  await waitFor(`!!document.querySelector('[data-agent-row=${JSON.stringify(name)}]')`, 10000);
  await menuPick('More for ' + name, 'End…');
  await tick();
  check(await submitDialog(), `add 6 End… ${name}, ticked`);
  let ended = false;
  for (let i = 0; i < 30 && !ended; i++) { ended = workerLs('demo2').find((a) => a.name === name)?.state === 'ended'; if (!ended) await sleep(300); }
  check(ended, `add 6 doz worker ls --all: ${name} ended`);
  if (ended) startedWorkers.splice(startedWorkers.findIndex(([w, n]) => w === 'demo2' && n === name), 1);
  // 7. An isolation chip opens the guide at that choice; four cards in order.
  await goHash('#/w/demo2/agents');
  await waitFor(`!!document.querySelector('[data-agent-row="beta"] a[data-iso-guide]')`, 10000);
  await evaluate(`document.querySelector('[data-agent-row="beta"] a[data-iso-guide]').click()`);
  check(await waitFor(`location.hash === '#/guide/isolation/vm' && state.view === 'guide' && !!document.querySelector('[data-iso-card="vm"].is-current')`, 10000),
    'add 7 beta\'s "micro VM" chip opens #/guide/isolation/vm, its card highlighted');
  const order = await evaluate(`[...document.querySelectorAll('[data-iso-card]')].map((c) => c.dataset.isoCard).join(' ')`);
  check(order === 'vm fenced unfenced elsewhere', `add 7 four cards, in order of isolation (${order})`);
  check(/Not isolated by Dozable/.test(await evaluate(text('[data-iso-card="elsewhere"]'))) && /keys never go inside/.test(await evaluate(text('.iso-keys'))),
    'add 7 elsewhere "not isolated by Dozable"; keys never go inside');
  for (const id of ['fenced', 'unfenced', 'elsewhere']) {
    await goHash('#/guide/isolation/' + id);
    check(await waitFor(`!!document.querySelector('[data-iso-card=${JSON.stringify(id)}].is-current') && document.querySelectorAll('.iso-card.is-current').length === 1`, 8000), `add 7 #/guide/isolation/${id} highlights its card`);
  }
  await goHash('#/bots');
  await waitFor(`!!document.querySelector('[data-bot="mira"] a[data-iso-guide="fenced"]')`, 10000);
  check(await evaluate(`document.querySelector('[data-bot="mira"] a[data-iso-guide]').getAttribute('href') === '#/guide/isolation/fenced'`), 'add 7 Agents / Bots\' chips lead to the guide too');
  // 8. Another computer: 403 for worker-add, worker-end and the plan route — ServeHTTPTests' (this dashboard has no LAN side).
  check(true, 'add 8 another computer\'s 403 for the three is ServeHTTPTests.testWorkersAreThisMacsBrowserOnlyWhateverTheServeSettings\'');
  // 9. At 390 px the guide's cards stack, and the page has no sideways scroll.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await goHash('#/guide/isolation');
  await waitFor(`state.view === 'guide' && !!document.querySelector('[data-iso-card="fenced"]')`, 8000);
  await sleep(300);
  const stack = await evaluate(`(() => { const a = document.querySelector('[data-iso-card="vm"]').getBoundingClientRect(), b = document.querySelector('[data-iso-card="fenced"]').getBoundingClientRect();
    return { below: b.top >= a.bottom - 1, w: document.documentElement.scrollWidth }; })()`);
  await shot('guide-390');
  check(stack.below && stack.w <= 390, `add 9 at 390 px the guide's cards stack, no sideways scroll (${stack.w} px)`);
  await goHash('#/w/demo2/agents/new');
  await waitFor(`state.view === 'addworker' && ${AW_PLANNED}`, 10000);
  await sleep(300);
  const narrow = await evaluate(`document.documentElement.scrollWidth`);
  await shot('add-worker-390');
  check(narrow <= 390, `add 9 at 390 px Add a worker has no sideways scroll (${narrow} px; the table scrolls in its box)`);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await goHash('#/w/demo2/agents/new');
  await shot('add-worker-light');
  await goHash('#/guide/isolation/fenced');
  await shot('guide-light');
  check(pageErrors.length === errorsBefore, 'add: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
}

/// A lifecycle dialog open and read: its plan shown (the table, or its refusals).
const WL_READ = `!!document.querySelector('dialog.dlg[open][data-ws-lifecycle] .wl-plan')`;
async function wlSubmit(ms = 60000) {
  await waitFor(`!!${SUBMIT} && !${SUBMIT}.disabled`, 10000);
  await evaluate(`${SUBMIT}.click()`);
  return waitFor(`!document.querySelector('dialog.dlg[open]')`, ms);
}
const wsState = (n) => (dozJSON(['workspace', 'show', n]) || {}).state;
async function walkLifecycle() {
  const errorsBefore = pageErrors.length;
  doz(['workspace', 'new', 'life', '--prompt-file', '-', '--folder', S + '/life-work'], 'Look after the launch.\n');
  // (`--store` before `--`: what follows it is the program's own argv.)
  const run = spawnSync(DOZ, ['run', '@mac', '-d', '--unfenced', '--session', 'lifesh', '--folder', S + '/life-work', '--store', STORE, '--', '/bin/sleep', '600'],
    { env: ENV, encoding: 'utf8', timeout: 120_000 });
  if (run.status === 0) lifeSession = 'lifesh';
  doz(['workspace', 'adopt', 'life', '@mac/lifesh']);
  doz(['workspace', 'start', 'life']);
  // 1. Sleep is the primary button; its dialog is the dry run's plan.
  await goHash('#/w/life');
  const primary1 = await waitFor(`state.view === 'workspace' && !!document.querySelector('#ws-head [data-ws-primary="sleep"]')`, 15000);
  check(primary1, 'life 1 Sleep is the primary button of a running workspace'
    + (primary1 ? '' : ` — ${wsState('life')}; the title row: ${await evaluate(`[...document.querySelectorAll('#ws-head [data-ws-primary], #ws-head [data-ws-state]')].map((e) => e.outerHTML.slice(0, 120)).join(' | ')`)}`));
  if (!primary1) return;
  await evaluate(`document.querySelector('#ws-head [data-ws-primary="sleep"]').click()`);
  await waitFor(WL_READ, 15000);
  const dry = dozJSON(['workspace', 'sleep', 'life', '--dry-run']) || { rows: [] };
  const shown = await evaluate(`({ sha: document.querySelector('[data-wl-plan]').dataset.wlSha,
    rows: [...document.querySelectorAll('[data-wl-agent]')].map((r) => [r.dataset.wlAgent, r.children[2].textContent, r.children[3].textContent]) })`);
  check(shown.sha === dry.sha && JSON.stringify(shown.rows) === JSON.stringify(dry.rows.map((r) => [r.name, r.after, r.back])),
    `life 1 the dialog's table is doz workspace sleep life --dry-run --json's (sha ${shown.sha} / ${dry.sha}; ${JSON.stringify(shown.rows)})`);
  // 10. At 390 px the table is cards.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await sleep(300);
  const cards = await evaluate(`(() => { const r = document.querySelector('[data-wl-agent]'); return { block: getComputedStyle(r).display === 'block', w: document.documentElement.scrollWidth }; })()`);
  await shot('lifecycle-390');
  check(cards.block && cards.w <= 390, `life 10 at 390 px the plan's table is cards, no sideways scroll (${cards.w} px)`);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await shot('lifecycle-sleep');
  // 2. Sleep → asleep; Home folds it into Asleep (1) with its Wake.
  check(await wlSubmit(), 'life 2 Sleep: the operation ended');
  check(await waitFor(`!!document.querySelector('#ws-head [data-ws-state="asleep"]')`, 20000) && wsState('life') === 'asleep', `life 2 asleep (${wsState('life')})`);
  await goHash('#/home');
  check(await waitFor(`/Asleep \\(\\d+\\)/.test(document.querySelector('[data-home-group="asleep"]')?.textContent || '') && !document.querySelector('[data-ws="life"]')`, 15000),
    'life 2 Home folds it into "Asleep (N)"');
  await evaluate(`document.querySelector('[data-home-group="asleep"]').click()`);
  check(await waitFor(`!!document.querySelector('[data-ws="life"] [data-home-next="wake"]')`, 10000), 'life 2 …unfolded, its row\'s next action is Wake');
  // 3. Wake from Home.
  await evaluate(`document.querySelector('[data-ws="life"] [data-home-next="wake"]').click()`);
  await waitFor(WL_READ, 15000);
  check(await wlSubmit(), 'life 3 Wake: the operation ended');
  let awake = false;
  for (let i = 0; i < 40 && !awake; i++) { const st = wsState('life'); awake = st && st !== 'asleep'; if (!awake) await sleep(300); }
  const sh = (dozJSON(['sessions', '@mac']) || []).find((r) => r.name === 'lifesh');
  check(awake && sh && !sh.ended, `life 3 awake (${wsState('life')}), lifesh running again`);
  // 4. Finish…: a plain confirmation, its room closed (0.52.15, the owner's decision — it said "the composer still takes a
  // post" in 0.52.12); finished; the composer off with the closed notice; a post refused; the Runs tab lists the run, archived.
  await goHash('#/w/life');
  await waitFor(`state.view === 'workspace' && !!document.querySelector('button[aria-label="More for life"]')`, 10000);
  await menuPick('More for life', 'Finish…');
  await waitFor(WL_READ, 15000);
  check(await evaluate(`!document.querySelector('[data-wl-typed]')`), 'life 4 Finish… is a plain confirmation (no name to type)');
  check(await evaluate(`/finish closes the room to new messages until you reopen/.test(document.querySelector('[data-wl-plan]')?.textContent || '')
    && !!document.querySelector('[data-wl-room="life"]') && !!document.querySelector('[data-wl-archive]') && !document.querySelector('[data-wl-tick="noArchive"]').checked`),
    'life 4 …the room\'s row, "finish closes the room…", the archive section, "Finish without an archive" unticked');
  const finishDry = dozJSON(['workspace', 'finish', 'life', '--dry-run']);
  check(!!finishDry && finishDry.sha === await evaluate(`document.querySelector('[data-wl-plan]').dataset.wlSha`), 'life 4 …the dialog\'s plan is finish --dry-run --json\'s (the same sha)');
  check(await wlSubmit(), 'life 4 Finish: the operation ended');
  check(await waitFor(`!!document.querySelector('#ws-head [data-ws-state="finished"]')`, 20000) && wsState('life') === 'finished', 'life 4 finished');
  await waitFor(`!!document.querySelector('#chat-text')`, 10000);
  check(doz(['chat', 'send', 'life', 'a post after the finish']).status !== 0, 'life 4 …a post is refused (closed)');
  await goHash('#/w/life/runs');
  check(await waitFor(`!!document.querySelector('[data-wr-run][data-wr-status="written"]')`, 15000), 'life 4 Runs lists the run, its archive written');
  check(await evaluate(`document.querySelector('[data-wr-room-state]')?.dataset.wrRoomState === 'closed'`), 'life 4 …its room reads closed');
  // Back in the room (its state read again on arrival): the composer off, with the closed notice.
  await goHash('#/w/life/room');
  check(await waitFor(`!!document.querySelector('#chat-text') && document.querySelector('#chat-text').disabled && /Closed: its workspace life is finished/.test(document.querySelector('#chat-text').placeholder)`, 20000),
    'life 4 …the composer is off with the closed notice');
  // 5. Reopen (the primary button) → asleep.
  await waitFor(`!!document.querySelector('#ws-head [data-ws-primary="reopen"]')`, 10000);
  await evaluate(`document.querySelector('#ws-head [data-ws-primary="reopen"]').click()`);
  await waitFor(WL_READ, 15000);
  check(await wlSubmit() && await waitFor(`!!document.querySelector('#ws-head [data-ws-state="asleep"]')`, 20000), `life 5 Reopen → asleep (${wsState('life')})`);
  // 6. Archive…: the name typed; a crafted action with another name is 400; the room's archived notice.
  await menuPick('More for life', 'Archive…');
  await waitFor(WL_READ + ` && !!document.querySelector('[data-wl-typed]')`, 15000);
  await setField('[data-wl-typed]', 'lif');
  check(await evaluate(`${SUBMIT}.disabled`), 'life 6 Archive…: a wrong name keeps the button off');
  const sha = await evaluate(`document.querySelector('[data-wl-plan]').dataset.wlSha`);
  const forged = await craft({ action: 'workspace-archive', workspace: 'life', ifPlan: sha, confirm: 'lif' });
  check(forged.status === 400 && wsState('life') === 'asleep', `life 6 a crafted archive with another name: ${forged.status}, nothing done`);
  await setField('[data-wl-typed]', 'life');
  check(await evaluate(`!${SUBMIT}.disabled`), 'life 6 …the name typed: the button on');
  check(await wlSubmit(120000), 'life 6 Archive: the operation ended');
  check(await waitFor(`!!document.querySelector('#ws-head [data-ws-state="archived"]')`, 20000) && wsState('life') === 'archived', 'life 6 archived');
  check(await waitFor(`/archived/.test(document.querySelector('#chat-text')?.placeholder || '')`, 15000), 'life 6 …the room shows the archived notice');
  // 7. Restore → finished.
  await evaluate(`document.querySelector('#ws-head [data-ws-primary="restore"]').click()`);
  await waitFor(WL_READ, 15000);
  check(await wlSubmit() && await waitFor(`!!document.querySelector('#ws-head [data-ws-state="finished"]')`, 20000), `life 7 Restore → finished (${wsState('life')})`);
  // 8. Delete…: the Bin box unticked; gone from Home and the sidebar; the folder still there.
  await menuPick('More for life', 'Delete…');
  await waitFor(WL_READ + ` && !!document.querySelector('[data-wl-tick="binFolders"]')`, 15000);
  check(await evaluate(`!document.querySelector('[data-wl-tick="binFolders"]').checked && !document.querySelector('[data-wl-tick="removeSandboxes"]').checked`),
    'life 8 Delete…: "Also move its folders to the Bin" and "Also remove…" unticked');
  await setField('[data-wl-typed]', 'life');
  check(await wlSubmit(120000), 'life 8 Delete: the operation ended');
  check(await waitFor(`location.hash === '#/home' && !document.querySelector('[data-ws="life"]') && !document.querySelector('[data-nav-ws="life"]')`, 20000), 'life 8 gone from Home and the sidebar');
  check(!(dozJSON(['workspace', 'ls']) || { workspaces: [] }).workspaces.some((w) => w.name === 'life') && existsSync(S + '/life-work'), 'life 8 …its record gone, its folder still on disk');
  check(true, 'life 9 another computer\'s 403 for the eight and the plan route is ServeHTTPTests.testTheLifecycleIsThisMacsBrowserOnlyWhateverTheServeSettings\'');
  check(pageErrors.length === errorsBefore, 'life: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  await leakSweep('the lifecycle');
}
let lifeSession = null;

// ── a finished workspace's room archived, then removed for good, from the Runs tab (this Mac's own browser) ─────────────
async function walkRooms() {
  const errorsBefore = pageErrors.length;
  doz(['workspace', 'new', 'rmw', '--prompt-file', '-'], 'Keep its record.\n');
  doz(['workspace', 'start', 'rmw']);
  for (const m of ['first in the run', 'second in the run', 'third in the run']) doz(['chat', 'send', 'rmw', m]);
  const fin = doz(['workspace', 'finish', 'rmw', '--yes']);
  check(fin.status === 0, 'rooms 1 rmw finished, its run archived (' + fin.status + ')');
  await goHash('#/w/rmw/runs');
  check(await waitFor(`document.querySelector('[data-wr-room-state]')?.dataset.wrRoomState === 'closed'`, 15000), 'rooms 1 its room reads closed on the Runs tab');
  // 2. Archive room…: its plan, then the copy.
  await evaluate(`document.querySelector('[data-wr-room-archive="rmw"]').click()`);
  check(await waitFor(`document.querySelector('dialog.dlg[open]')?.dataset.wrRoomDialog === 'archive' && !!document.querySelector('dialog.dlg[open]')?.dataset.wrSha`, 15000),
    'rooms 2 Archive room… shows its plan');
  check(await wlSubmit(120000), 'rooms 2 Archive: the operation ended');
  check(await waitFor(`document.querySelector('[data-wr-room-state]')?.dataset.wrRoomState === 'archived'`, 20000), 'rooms 2 …the room reads archived');
  // 3. Remove room…: a wrong name keeps the button off; a forged confirm is refused; the right name removes it.
  await evaluate(`document.querySelector('[data-wr-room-rm="rmw"]').click()`);
  await waitFor(`document.querySelector('dialog.dlg[open]')?.dataset.wrRoomDialog === 'rm' && !!document.querySelector('dialog.dlg[open]')?.dataset.wrSha`, 15000);
  await setField('[data-wr-typed]', 'rm');
  check(await evaluate(`${SUBMIT}.disabled`), 'rooms 3 Remove room…: a wrong name keeps the button off');
  const sha = await evaluate(`document.querySelector('dialog.dlg[open]').dataset.wrSha`);
  const forged = await craft({ action: 'chat-room-rm', room: 'rmw', ifPlan: sha, confirm: 'rm' });
  check(forged.status === 400 && doz(['chat', 'rooms']).stdout.includes('rmw —'), `rooms 3 a forged confirm: ${forged.status}, nothing removed`);
  await setField('[data-wr-typed]', 'rmw');
  check(await evaluate(`!${SUBMIT}.disabled`), 'rooms 3 …the name typed: the button on');
  check(await wlSubmit(120000), 'rooms 3 Remove: the operation ended');
  check(await waitFor(`document.querySelector('[data-wr-room-state]')?.dataset.wrRoomState === 'gone'`, 20000) && !doz(['chat', 'rooms']).stdout.includes('rmw —'),
    'rooms 3 …the room reads gone, and doz chat rooms no longer lists it');
  const gone = dozJSON(['chat', 'rooms', '--gone']) || [];
  check(gone.some((t) => t.name === 'rmw' && t.id && t.archive), 'rooms 3 …its tombstone kept');
  // 4. The run's archived messages are still readable.
  await evaluate(`document.querySelector('[data-wr-run] .wr-actions button')?.click()`);
  check(await waitFor(`/third in the run/.test(document.querySelector('[data-wr-page] [data-wr-room="rmw"]')?.textContent || '')`, 15000),
    'rooms 4 run 1\'s chat is still read from its archive');
  check(pageErrors.length === errorsBefore, 'rooms: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  await leakSweep('the rooms');
}

// ── asks in chat: the decision card (chat on) ────────────────────────────────────────────────────────────────────────
/// A bot's ask with dozchat (beside doz) and its own token from its file: the answer's msg_id.
function botAsk(bot, args) {
  const r = spawnSync(dirname(DOZ) + '/dozchat-mac', ['ask', 'askw', ...args], { encoding: 'utf8', timeout: 60_000,
    env: { PATH: '/usr/bin:/bin', HOME: S, CHAT_URL: 'http://127.0.0.1:' + chatPagePort, CHAT_TOKEN_FILE: S + '/' + bot + '.token' } });
  try { return JSON.parse(r.stdout).msg_id || ''; } catch (_) { return ''; }
}
const askNumber = (id) => (((dozJSON(['chat', 'asks', 'askw']) || {}).asks || []).find((a) => a.msgId === id) || {}).number || 0;
const CARD = (id) => `document.querySelector('[data-ask="${id}"]')`;
async function walkAsks() {
  const errorsBefore = pageErrors.length;
  for (const b of ['askerbot', 'decbot']) {
    doz(['chat', 'add', b, '--to-file', S + '/' + b + '.token']);
    knownTokens.push(readFileSync(S + '/' + b + '.token', 'utf8').trim());
  }
  doz(['chat', 'set', 'decbot', '--role', 'decider']);
  doz(['workspace', 'new', 'askw', '--prompt-file', '-'], 'Answer the bots.\n');
  doz(['workspace', 'start', 'askw']);
  for (const b of ['askerbot', 'decbot']) doz(['chat', 'send', 'askw', '/invite @' + b]);
  // The page reads the workspaces again on a reload — the CLI's changes are no event of their own.
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  await goHash('#/w/askw/room');
  await waitFor(`state.view === 'workspace' && state.chat.room === 'askw' && state.chat.live === 'live'`, 20000);
  // 1. A bot's ask of two questions is a card.
  writeFileSync(S + '/ask-qs.json', JSON.stringify([
    { id: 'build', header: 'Build', question: 'Which build goes out?', options: [{ id: 'web', label: 'Web' }, { id: 'desktop', label: 'Desktop' }] },
    { id: 'when', question: 'When?', options: [{ id: 'today', label: 'Today' }, { id: 'monday', label: 'Monday' }] }]));
  const a1 = botAsk('askerbot', ['Release today', '--questions', S + '/ask-qs.json', '--reason', 'the tests pass']);
  const drawn = await waitFor(`!!${CARD(a1)}`, 15000);
  const card = await evaluate(`(() => { const c = ${CARD(a1)}; if (!c) return null; return { title: c.querySelector('.chat-ask-title')?.textContent, reason: c.querySelector('.chat-ask-reason')?.textContent,
    qs: c.querySelectorAll('fieldset.chat-ask-q').length, letters: [...c.querySelectorAll('.chat-ask-letter')].map((e) => e.textContent).join(''),
    other: /Something else/.test(c.textContent), decline: !!c.querySelector('.chat-ask-decline-btn'), state: c.querySelector('.chat-ask-state')?.textContent }; })()`);
  check(drawn && card && card.title === 'Release today' && /the tests pass/.test(card.reason) && card.qs === 2 && card.letters.startsWith('AB')
    && card.other && card.decline && /^open · expires in/.test(card.state), 'ask 1 a bot\'s ask is a card: title, reason, two questions, lettered options, Something else, Decline, open · expires in'
    + (card ? ` (${JSON.stringify(card)})` : ` — not drawn: ${JSON.stringify(await evaluate(`({ view: state.view, room: state.chat.room, live: state.chat.live,
      last: [...state.chat.byId.values()].slice(-3).map((m) => [m.kind || '', !!m.ask, String(m.msg_id).slice(0, 8)]), id: ${JSON.stringify(a1)} })`))}; ${pageErrors.slice(-2).join(' | ')}`));
  if (!drawn) return;
  // 2. Answered by keyboard only: focus on its first option, B, Tab, A, then ⌘Enter.
  await evaluate(`${CARD(a1)}.querySelector('input.chat-ask-input').focus()`);
  await key('b', 'KeyB', 66);
  await key('Tab', 'Tab', 9);
  await key('a', 'KeyA', 65);
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, modifiers: 4 });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, modifiers: 4 });
  const decided = await waitFor(`/decided by you/.test(${CARD(a1)}?.querySelector('.chat-ask-state')?.textContent || '')`, 20000);
  const left = (dozJSON(['chat', 'asks', 'askw']) || { asks: [1] }).asks;
  check(decided && left.length === 0 && /B\. Desktop/.test(await evaluate(`${CARD(a1)}.textContent`)),
    'ask 2 answered by keyboard only (B, Tab, A, ⌘Enter): "decided by you", B. Desktop shown, doz chat asks --json empty');
  // 3. Answered by the CLI meanwhile: a second action from the page is refused in Dozable's words, and the op says so.
  const a3 = botAsk('askerbot', ['Ship it?', '--option', 'yes=Yes', '--option', 'no=No']);
  await waitFor(`!!${CARD(a3)}`, 15000);
  const n3 = askNumber(a3);
  doz(['chat', 'decide', 'askw', '#' + n3, 'A']);
  const crafted = await craft({ action: 'chat-decide', room: 'askw', ask: '#' + n3, reply: 'B', actionId: randomUUID() });
  let opId = '';
  try { opId = JSON.parse(crafted.body).id; } catch (_) { /* no op */ }
  const ended = await waitFor(`(state.ops.get(${JSON.stringify(opId)}) || {}).state === 'failed'`, 20000);
  const opText = await evaluate(`(state.ops.get(${JSON.stringify(opId)}) || {}).text || ''`);
  check(crafted.status === 202 && ended && opText === 'It was already answered: decided by Ada.' && await waitFor(`/decided by you/.test(${CARD(a3)}?.textContent || '')`, 10000),
    `ask 3 a card the CLI answered: the crafted second action ends "${opText}", the card reads decided`);
  // 5. Read-only: an ask only decbot decides shows no control and its line. 4. Live: it came without a reload; a withdraw
  // turns it withdrawn.
  const r4 = doz(['chat', 'ask', 'askw', 'Lunch at noon?', '--option', 'yes=Yes', '--decider', 'decbot', '--json']);
  let a4 = '';
  try { a4 = JSON.parse(r4.stdout).msgId; } catch (_) { /* refused */ }
  check(await waitFor(`!!${CARD(a4)}`, 15000), 'ask 4 a CLI-posted ask appears live, with no reload');
  check(await evaluate(`${CARD(a4)}.querySelectorAll('input, textarea, button').length === 0 && /You asked this/.test(${CARD(a4)}.querySelector('.chat-ask-state').textContent)`),
    'ask 5 read-only: your own ask shows no control and "You asked this"');
  const a5 = botAsk('askerbot', ['Read the shared folder?', '--option', 'yes=Allow', '--decider', 'decbot']);
  check(await waitFor(`!!${CARD(a5)}`, 15000) && await evaluate(`${CARD(a5)}.querySelectorAll('input, textarea, button').length === 0
    && /Only Decbot can answer/.test(${CARD(a5)}.querySelector('.chat-ask-state').textContent)`), 'ask 5 read-only: an ask only decbot decides shows no control and "Only Decbot can answer"');
  spawnSync(dirname(DOZ) + '/dozchat-mac', ['withdraw', 'askw', a5], { encoding: 'utf8', timeout: 60_000,
    env: { PATH: '/usr/bin:/bin', HOME: S, CHAT_URL: 'http://127.0.0.1:' + chatPagePort, CHAT_TOKEN_FILE: S + '/askerbot.token' } });
  doz(['chat', 'withdraw', 'askw', '#' + askNumber(a4)]);
  check(await waitFor(`/withdrawn/.test(${CARD(a4)}?.querySelector('.chat-ask-state')?.textContent || '')`, 15000), 'ask 4 …withdrawn from the CLI, the card turns "withdrawn" live');
  // 6. The diagram's path: the hashed core/asks module, answerFromDiagram(id, 'Yes') → ok; again → refused.
  const a6 = botAsk('askerbot', ['Deploy now?', '--option', 'yes=Yes', '--option', 'no=No']);
  await waitFor(`!!${CARD(a6)}`, 15000);
  const diag = await evaluate(`(async () => { const u = performance.getEntriesByType('resource').map((e) => e.name).find((n) => /\\/assets\\/app\\/core\\/asks-[0-9a-f]+\\.js$/.test(n));
    if (!u) return { none: true }; const m = await import(u); m.rememberAttention([{ kind: 'ask', askId: ${JSON.stringify(a6)}, room: 'askw' }]);
    const one = await m.answerFromDiagram(${JSON.stringify(a6)}, 'Yes'); const two = await m.answerFromDiagram(${JSON.stringify(a6)}, 'Yes');
    const gone = await m.answerFromDiagram('0b7e2c4a-1111-4222-8333-444455556666', 'Yes'); return { one, two, gone }; })()`);
  check(diag && diag.one && diag.one.ok === true && diag.two && /^It was already answered/.test(diag.two.refused || '') && /not shown here any more/.test(diag.gone?.refused || ''),
    'ask 6 the diagram\'s path: answerFromDiagram(id, "Yes") → {ok: true}; again → refused "It was already answered…"' + ` (${JSON.stringify(diag)})`);
  // 7. At 390 px: no sideways scroll, rows of at least 44 px; an answer in words, then the leak sweep for it.
  const a7 = botAsk('askerbot', ['Anything else?', '--option', 'no=No']);
  await waitFor(`!!${CARD(a7)}`, 15000);
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await sleep(400);
  const phone = await evaluate(`(() => { const c = ${CARD(a7)}; c.scrollIntoView(); const rows = [...c.querySelectorAll('.chat-ask-opt')].map((e) => e.getBoundingClientRect().height);
    return { scroll: document.scrollingElement.scrollWidth, log: document.querySelector('#chat-log').scrollWidth - document.querySelector('#chat-log').clientWidth, rows }; })()`);
  check(phone.scroll <= 390 && phone.log <= 0 && phone.rows.length > 0 && phone.rows.every((h) => h >= 44), `ask 7 at 390 px: no sideways scroll, option rows ≥ 44 px (${JSON.stringify(phone)})`);
  const words = 'FAKE-ASK-ANSWER-' + process.pid + '-7d1e';
  await evaluate(`(() => { const c = ${CARD(a7)}; const o = [...c.querySelectorAll('.chat-ask-opt')].find((l) => /Something else/.test(l.textContent)).querySelector('input'); o.click(); })()`);
  await setField(`[data-ask="${a7}"] textarea.chat-ask-text`, words);
  await evaluate(`${CARD(a7)}.querySelector('.chat-ask-answer').click()`);
  await waitFor(`/decided by you/.test(${CARD(a7)}?.textContent || '')`, 20000);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  const said = ['ui.operations.json', 'ui.log'].map((f) => (existsSync(STORE + '/' + f) ? readFileSync(STORE + '/' + f, 'utf8') : '')).join('\n') + uiOut + consoleLines.join('\n');
  check(await waitFor(`(${CARD(a7)}?.textContent || '').includes(${JSON.stringify(words)})`, 15000) && !said.includes(words), 'ask 7 the answer in words is shown in the card, and in no operation, ui.log or console line');
  check(pageErrors.length === errorsBefore, 'asks: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  await leakSweep('the asks');
}

// ── the chat window: a room popped out into a window of its own ─────────────────────────────────────────────────────
// The browser's own endpoint (one more socket) attaches to every new window from its first byte (waiting for the debugger),
// so each one's requests, bytes, errors and CSP violations are counted from its document's start.
let bws = null, bNext = 1, mainTarget = null, nextKid = {};
const bPending = new Map(), kids = new Map();
function bsend(method, params = {}, sessionId) {
  const id = bNext++;
  bws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
  // A window that never answers (closed, or paused) never holds the walk: 20 s, then an error.
  return new Promise((res, rej) => { bPending.set(id, { res, rej }); setTimeout(() => { if (bPending.delete(id)) rej(new Error(method + ': no answer')); }, 20000); });
}
async function kevaluate(k, expr, gesture = false) {
  const r = await bsend('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true, userGesture: gesture }, k.sid);
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' in ' + expr.slice(0, 80));
  return r.result.value;
}
const ksoft = async (k, expr) => { try { return await kevaluate(k, expr); } catch (_) { return null; } };
async function kwait(k, expr, ms = 15000) { const end = Date.now() + ms; while (Date.now() < end) { if (await ksoft(k, expr)) return true; await sleep(120); } return false; }
async function kshot(k, name) {
  if (!SHOTS) return;
  mkdirSync(SHOTS, { recursive: true });
  const r = await bsend('Page.captureScreenshot', { format: 'png' }, k.sid);
  writeFileSync(SHOTS + '/' + name + '.png', Buffer.from(r.data, 'base64'));
}
async function browserSocket() {
  if (bws) return;
  mainTarget = (await (await fetch(`http://127.0.0.1:${devPort}/json/list`)).json()).find((t) => t.type === 'page' && t.url.startsWith('http://127.0.0.1')).id;
  const v = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
  bws = new WebSocket(v.webSocketDebuggerUrl);
  await new Promise((r) => bws.addEventListener('open', r, { once: true }));
  bws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && bPending.has(m.id)) { const p = bPending.get(m.id); bPending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); return; }
    if (m.method === 'Target.attachedToTarget') {
      const { sessionId, targetInfo, waitingForDebugger } = m.params;
      if (targetInfo.type !== 'page' || targetInfo.targetId === mainTarget) { if (waitingForDebugger) bsend('Runtime.runIfWaitingForDebugger', {}, sessionId).catch(() => {}); return; }
      const opts = nextKid;
      nextKid = {};
      const k = { sid: sessionId, target: targetInfo.targetId, opener: targetInfo.openerId || null, requested: [], bytes: new Map(), errors: [], streams: new Map(), ready: null };
      kids.set(sessionId, k);
      k.ready = (async () => {
        await bsend('Network.enable', {}, sessionId);
        if (opts.cold) await bsend('Network.setCacheDisabled', { cacheDisabled: true }, sessionId);
        await bsend('Runtime.enable', {}, sessionId);
        await bsend('Page.enable', {}, sessionId);
        await bsend('Page.addScriptToEvaluateOnNewDocument', { source: `window.__violations = [];
          document.addEventListener('securitypolicyviolation', (e) => window.__violations.push(e.violatedDirective + ' ' + e.blockedURI));` }, sessionId);
        await bsend('Emulation.setDeviceMetricsOverride', { width: opts.width || 440, height: opts.height || 760, deviceScaleFactor: 1, mobile: false }, sessionId);
        if (opts.fetch) await opts.fetch(k);
        await bsend('Runtime.runIfWaitingForDebugger', {}, sessionId);
      })().catch(() => {});
      return;
    }
    if (m.method === 'Target.detachedFromTarget' && kids.has(m.params.sessionId)) { kids.get(m.params.sessionId).gone = true; return; }
    const k = m.sessionId && kids.get(m.sessionId);
    if (!k) return;
    const p = m.params || {};
    if (m.method === 'Network.requestWillBeSent') {
      k.requested.push(p.request.url);
      if (/\/api\/v1\/stream$/.test(p.request.url)) k.streams.set(p.requestId, 'open');
    }
    if (m.method === 'Network.responseReceived' && /\/api\/v1\//.test(p.response.url) && !/event-stream/.test(p.response.mimeType || '')) k.api = (k.api || new Set()).add(p.requestId);
    // Served from this browser's cache: no byte over the wire.
    if ((m.method === 'Network.responseReceived' && (p.response.fromDiskCache || p.response.fromPrefetchCache)) || m.method === 'Network.requestServedFromCache') (k.cached = k.cached || new Set()).add(p.requestId);
    if (m.method === 'Network.loadingFinished') {
      k.bytes.set(p.requestId, p.encodedDataLength);
      if (k.streams.has(p.requestId)) k.streams.set(p.requestId, 'closed');
      if (k.api && k.api.has(p.requestId)) {
        k.api.delete(p.requestId);
        bsend('Network.getResponseBody', { requestId: p.requestId }, k.sid).then((b) => apiBodies.push(b.base64Encoded ? Buffer.from(b.body, 'base64').toString('utf8') : b.body), () => {});
      }
    }
    if (m.method === 'Network.loadingFailed' && k.streams.has(p.requestId)) k.streams.set(p.requestId, 'closed');
    if (m.method === 'Network.requestWillBeSent' && /^http/.test(p.request.url)) k.urls = (k.urls || new Map()).set(p.requestId, p.request.url);
    if (m.method === 'Runtime.exceptionThrown') k.errors.push((p.exceptionDetails.exception?.description || p.exceptionDetails.text).split('\n').slice(0, 4).join(' ⏎ '));
    if (m.method === 'Fetch.requestPaused' && k.paused) k.paused(p).catch(() => {});
  });
  await bsend('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
}
/// The new window (one not seen before `since`) whose address matches, once it is attached and running.
async function newKid(since, re, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    for (const k of kids.values()) {
      if (since.has(k.sid) || k.gone) continue;
      await Promise.race([k.ready, sleep(5000)]);
      const href = await ksoft(k, 'location.href');
      if (href && re.test(href)) return k;
    }
    await sleep(150);
  }
  return null;
}
const liveKids = () => [...kids.values()].filter((k) => !k.gone);
const pageFetched = (k) => k.requested.filter((u) => /^http:\/\/127\.0\.0\.1/.test(u) && !/\/api\//.test(u)).map((u) => new URL(u).pathname);
const kbytes = (k) => [...k.bytes.entries()].filter(([id]) => !/\/api\//.test((k.urls || new Map()).get(id) || '') && !(k.cached && k.cached.has(id))).reduce((a, [, b]) => a + b, 0);
const POP = `document.querySelector('#chat-pop')`;
/// The head's controls (and the notification bell in the window's corner) that overlap one another: none may.
const HEAD_OVERLAPS = `(() => { const els = [...document.querySelectorAll('#chat-surface .chat-head > *'), document.querySelector('#notes .note-bell')]
  .filter((e) => e && !e.hidden && e.getClientRects().length && e.getBoundingClientRect().width > 0);
  const name = (e) => e.id || e.className; const out = [];
  for (let i = 0; i < els.length; i++) for (let j = i + 1; j < els.length; j++) { const a = els[i].getBoundingClientRect(), b = els[j].getBoundingClientRect();
    if (a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5) out.push(name(els[i]) + ' × ' + name(els[j])); }
  return { n: els.length, out }; })()`;
async function popOut() { await evaluate(`${POP}.click()`, true); }
async function walkChatWindow(origin) {
  const errorsBefore = pageErrors.length;
  await browserSocket();
  const room = 'askw';
  // Three more rooms for row 10 (a workspace made while chat is on makes its room).
  for (const n of ['win1', 'win2', 'win3']) doz(['workspace', 'new', n, '--prompt-file', '-'], 'A room for a chat window.\n');
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  await goHash('#/chat/' + room);
  await waitFor(`state.view === 'chat' && state.chat.room === ${JSON.stringify(room)} && state.chat.live === 'live'`, 20000);
  check(await waitFor(`!${POP}.hidden && ${POP}.getAttribute('href') === '/chat#/${room}' && ${POP}.target === 'doz-chat-${room}'`, 8000),
    'window 1 the Chat page\'s head has the pop-out: a link to /chat#/askw, its target the room\'s window');
  // 1. The pop-out opens the room's own window.
  const before = new Set(kids.keys());
  const dashBefore = requested.length;
  await popOut();
  const w = await newKid(before, /\/chat#\/askw$/);
  check(!!w, 'window 1 the pop-out opens a new window at /chat#/askw');
  if (!w) return;
  check(await kwait(w, `window.name === 'doz-chat-${room}' && document.title.startsWith('${room} — Chat') && !!document.querySelector('#chat-surface.is-solo')
    && !document.querySelector('#chat-cols').hidden && document.querySelector('#chat-room-name').textContent === 'askw'
    && document.querySelector('#chat-live').textContent === 'live'`, 20000),
    'window 1 …named doz-chat-askw, the room drawn alone (no rooms pane), its title "askw — Chat", the chip live — '
    + JSON.stringify(await ksoft(w, `({ name: window.name, title: document.title, live: document.querySelector('#chat-live')?.textContent, room: document.querySelector('#chat-room-name')?.textContent })`)));
  check(await kevaluate(w, `document.activeElement && document.activeElement.id === 'chat-text'`), 'window 1 …the focus starts on the composer');
  check(await kevaluate(w, `getComputedStyle(document.querySelector('.chat-rooms-pane')).display === 'none' && !!document.querySelector('#chat-dash[href="/#/chat/askw"]')
    && document.querySelector('#chat-pop').hidden`), 'window 1 …no rooms pane, "Open in the dashboard" → /#/chat/askw, no pop-out of its own');
  const ov = await kevaluate(w, HEAD_OVERLAPS);
  check(ov.n >= 4 && ov.out.length === 0, `window 1 …no two controls in its head overlap, the bell included (${ov.n} controls${ov.out.length ? ': ' + ov.out.join(', ') : ''})`);
  const warmBytes = kbytes(w), warmCached = (w.cached || new Set()).size;
  // 2. What the window fetched: only chat's code, no other view, no overview, no dashboard stream while idle.
  await sleep(1500);
  const got = pageFetched(w);
  const mods = got.filter((p) => p.startsWith('/assets/app/'));
  const others = got.filter((p) => !p.startsWith('/assets/app/') && !/^\/chat$/.test(p) && !/^\/assets\/chat-[0-9a-f]{16}\.js$/.test(p)
    && !/^\/assets\/app-[0-9a-f]{16}\.css$/.test(p) && !/^\/assets\/vendor-lucide-icons-[0-9a-f]{16}\.svg$/.test(p) && !/^\/assets\/icon-[0-9a-f]{16}\.svg$/.test(p) && p !== '/sw.js');
  const views = mods.filter((p) => /^\/assets\/app\/views\//.test(p) && !/^\/assets\/app\/views\/chat/.test(p));
  const api = w.requested.filter((u) => /\/api\//.test(u)).map((u) => new URL(u).pathname);
  check(others.length === 0 && views.length === 0 && mods.length > 30 && !api.includes('/api/v1/overview') && !api.includes('/api/v1/stream'),
    `window 2 fetched: the document, its entry, the stylesheet, the sprite, the icon and ${mods.length} of chat's modules — no other view, no overview, no dashboard stream while idle`
    + (others.length || views.length ? ' ' + JSON.stringify({ others, views }) : ''));
  const dashMods = requested.filter((u) => /\/assets\/app\//.test(u)).length;
  console.log(`  ·    window 2 the window fetched ${got.length} files (${mods.length} modules) and ${api.length} API reads: ${[...new Set(api)].join(' ')}; the dashboard's first load fetched ${dashMods} module URLs`);
  // 3. A CLI post is in the window and the dashboard.
  const said = 'Seen in two places ' + process.pid;
  doz(['chat', 'send', room, said]);
  const has = (t) => `[...state.chat.byId.values()].some((m) => m.content === ${JSON.stringify(t)})`;
  const inWin = (t) => `(document.querySelector('#chat-log')?.textContent || '').includes(${JSON.stringify(t)})`;
  check(await kwait(w, inWin(said), 15000) && await waitFor(has(said), 15000), 'window 3 a CLI post shows in the window and in the dashboard');
  // 4. A reload keeps the room and the draft.
  const draft = 'a draft kept ' + process.pid;
  await kevaluate(w, `(() => { const t = document.getElementById('chat-text'); t.value = ${JSON.stringify(draft)}; t.dispatchEvent(new Event('input', { bubbles: true })); })()`);
  await sleep(700);
  await bsend('Page.reload', {}, w.sid);
  check(await kwait(w, `document.querySelector('#chat-room-name')?.textContent === 'askw' && document.getElementById('chat-text')?.value === ${JSON.stringify(draft)}`, 20000),
    'window 4 a reload keeps the room and the draft');
  await kwait(w, `document.querySelector('#chat-live')?.textContent === 'live'`, 15000);
  // 5. A second click brings the same window forward: no new window, the draft kept, nothing fetched again.
  const kidsNow = liveKids().length, fetchedNow = pageFetched(w).length;
  await popOut();
  await sleep(1200);
  check(liveKids().length === kidsNow && !w.gone && pageFetched(w).length === fetchedNow && await kevaluate(w, `document.getElementById('chat-text').value === ${JSON.stringify(draft)}`),
    `window 5 a second click reuses the window (the same target), the draft kept, nothing fetched again (${liveKids().length} windows)`);
  await kevaluate(w, `(() => { const t = document.getElementById('chat-text'); t.value = ''; t.dispatchEvent(new Event('input', { bubbles: true })); })()`);
  // SHOTS: light, dark.
  await kevaluate(w, `document.documentElement.dataset.theme = 'light'`);
  await sleep(300);
  await kshot(w, 'chat-window-light');
  await kevaluate(w, `document.documentElement.dataset.theme = 'dark'`);
  await sleep(300);
  await kshot(w, 'chat-window-dark');
  await kevaluate(w, `delete document.documentElement.dataset.theme`);
  // 6. An Ask decided in the window: the dashboard's stream opens for its operation, then closes.
  const a = botAsk('askerbot', ['From the window?', '--option', 'yes=Yes', '--option', 'no=No']);
  const card = `document.querySelector('[data-ask="${a}"]')`;
  check(await kwait(w, `!!${card}?.querySelector('.chat-ask-answer')`, 15000), 'window 6 a bot\'s ask is a card in the window');
  await kevaluate(w, `${card}.scrollIntoView()`);
  await kshot(w, 'chat-window-ask');
  const streamsBefore = w.streams.size;
  await kevaluate(w, `(() => { const c = ${card}; c.querySelector('input.chat-ask-input').click(); c.querySelector('.chat-ask-answer').click(); })()`);
  const decided = await kwait(w, `/decided by you/.test(${card}?.querySelector('.chat-ask-state')?.textContent || '')`, 30000);
  await sleep(1500);
  const opened = [...w.streams.values()].slice(streamsBefore);
  check(decided && (dozJSON(['chat', 'asks', room]) || { asks: [1] }).asks.every((x) => x.msgId !== a) && opened.length >= 1 && [...w.streams.values()].every((s) => s === 'closed'),
    `window 6 Decide in the window: chat-decide done ("decided by you"), /api/v1/stream opened for it (${opened.length}) and closed after`);
  // 7. Turn chat on from the window while chat is off.
  doz(['chat', 'off']);
  await bsend('Page.reload', {}, w.sid);
  check(await kwait(w, `!!document.querySelector('#chat-notice [data-chat-on] [data-chat-on-go]') && document.querySelector('#chat-pop').hidden`, 20000),
    'window 7 chat off: the window says so, with Turn chat on');
  const sBefore = w.streams.size;
  await kevaluate(w, `document.querySelector('[data-chat-on-go]').click()`);
  check(await kwait(w, `!document.querySelector('#chat-cols').hidden && document.querySelector('#chat-room-name')?.textContent === 'askw' && document.querySelector('#chat-live')?.textContent === 'live'`, 90000)
    && chatState() === 'running' && w.streams.size > sBefore, 'window 7 …Turn chat on from the window: chat runs, the room comes back, its operation heard on the stream');
  await sleep(1500);
  check([...w.streams.values()].every((s) => s === 'closed'), 'window 7 …and the stream closed again once it ended');
  // 8. Read in the window, the dashboard's badge clears; two windows on one room never lower a marker; presence.
  await goHash('#/home');
  await sleep(5600);                                            // the dashboard's chat stream closes 5 s after leaving Chat
  const seen = () => evaluate(`+(localStorage.getItem('doz.chat.seen:askw') || 0)`);
  const m0 = await seen();
  const marks = [m0];
  const second = new Set(kids.keys());
  nextKid = {};
  await bsend('Target.createTarget', { url: origin + '/chat#/askw' });
  const w2 = await newKid(second, /\/chat#\/askw$/);
  await kwait(w2, `document.querySelector('#chat-live')?.textContent === 'live'`, 20000);
  const said8 = 'Read in the window ' + process.pid;
  doz(['chat', 'send', room, said8]);
  for (let i = 0; i < 30; i++) { marks.push(await seen()); if (await ksoft(w, inWin(said8)) && await ksoft(w2, inWin(said8))) break; await sleep(200); }
  await sleep(800);
  for (let i = 0; i < 5; i++) { marks.push(await seen()); await sleep(150); }
  const never = marks.every((v, i) => i === 0 || v >= marks[i - 1]);
  check(marks[marks.length - 1] > m0 && never, `window 8 reading in the windows moves the marker forward only (${m0} → ${marks[marks.length - 1]}, ${marks.length} samples, never lower)`);
  check(await waitFor(`!(state.chat.unread.askw && state.chat.unread.askw.n) && document.getElementById('chat-badge').hidden`, 8000),
    'window 8 …and the dashboard\'s badge for it clears (another window read it)');
  if (w2) await bsend('Target.closeTarget', { targetId: w2.target });
  await sleep(2500);
  const pres = await evaluate(`(async () => { const r = await fetch('/api/v1/chat/presence', { credentials: 'same-origin' }); const j = await r.json(); return (j.find((p) => p.name === 'ada') || {}).state || ''; })()`);
  check(/^(here|present)$/.test(pres), `window 8 …one window closed, the other open: ada is still "${pres}"`);
  console.log('  ·    window 10 four windows');
  // 10. Four chat windows and the dashboard: no eviction loop, fetches answer.
  await goHash('#/chat');
  await waitFor(`state.view === 'chat' && !!state.chat.srv`, 15000);
  const rooms = (await evaluate(`Object.keys(state.chat.srv.rooms).filter((r) => (state.chat.srv.rooms[r] || []).includes('ada') && !(state.chat.srv.archived || []).includes(r))`)).filter((r) => r !== room).slice(0, 3);
  const four = [w];
  for (const r of rooms) {
    await goHash('#/chat/' + r);
    await waitFor(`state.chat.room === ${JSON.stringify(r)} && !${POP}.hidden`, 10000);
    const was = new Set(kids.keys());
    await popOut();
    const k = await newKid(was, new RegExp('/chat#/' + r + '$'));
    if (k) four.push(k);
  }
  await sleep(4000);
  const states = [];
  for (const k of four) states.push(await ksoft(k, `document.querySelector('#chat-live')?.textContent || ''`));
  const answers = [];
  // The dashboard leaves Chat (its chat stream closes 5 s later): over plain HTTP a browser keeps 6 connections to one
  // origin, and four windows' streams + the dashboard's own stream leave one for fetches (web.md, "The chat window").
  await goHash('#/home');
  await sleep(5600);
  for (const k of four) answers.push(await ksoft(k, `(async () => { const t = Date.now(); const r = await fetch('/api/v1/chat/status', { credentials: 'same-origin' }); return r.status === 200 && Date.now() - t < 5000; })()`));
  const dashAnswers = await evaluate(`(async () => { const r = await fetch('/api/v1/chat/status', { credentials: 'same-origin' }); return r.status === 200; })()`);
  check(four.length === 4 && states.every((s) => s === 'live') && answers.every(Boolean) && dashAnswers,
    `window 10 four chat windows and the dashboard: every stream live, none paused (no eviction loop), every fetch answers (${JSON.stringify({ states, answers, dashAnswers })})`);
  for (const k of four.slice(1)) await bsend('Target.closeTarget', { targetId: k.target });
  console.log('  ·    window 11 cold loads');
  // 11. Cold first-load bytes of both documents (cache off), and the window's warm open.
  await goHash('#/home');
  const coldOf = async (url, re, settle) => {
    const was = new Set(kids.keys());
    nextKid = { cold: true, width: 1440, height: 900 };
    await bsend('Target.createTarget', { url });
    const k = await newKid(was, re, 20000);
    if (!k) return { bytes: 0, files: 0 };
    await kwait(k, settle, 30000);
    await sleep(2500);
    const out = { bytes: kbytes(k), files: pageFetched(k).length, k };
    return out;
  };
  const dcold = await coldOf(origin + '/#/home', /\/#\/home$/, `typeof state === 'undefined' ? false : !!document.querySelector('[data-home]')`);
  const wcold = await coldOf(origin + '/chat#/askw', /\/chat#\/askw$/, `document.querySelector('#chat-live')?.textContent === 'live'`);
  check(dcold.bytes > 0 && wcold.bytes > 0 && wcold.bytes <= 0.4 * dcold.bytes,
    `window 11 cold first load (cache off): the dashboard ${dcold.bytes} B in ${dcold.files} files, the window ${wcold.bytes} B in ${wcold.files} files (${Math.round(100 * wcold.bytes / Math.max(1, dcold.bytes))} %); the window opened warm from the dashboard: ${warmBytes} B (${warmCached} of its files from this browser's cache)`);
  for (const c of [dcold, wcold]) if (c.k) await bsend('Target.closeTarget', { targetId: c.k.target });
  // 9. Another computer: chat not shared, then shared read-only.
  const remote = async (shared) => {
    w.paused = async (p) => {
      const body = await bsend('Fetch.getResponseBody', { requestId: p.requestId }, w.sid).catch(() => null);
      if (/\/api\/v1\/chat\/status$/.test(p.request.url) && !shared) {
        await bsend('Fetch.fulfillRequest', { requestId: p.requestId, responseCode: 403, responseHeaders: [{ name: 'Content-Type', value: 'application/json' }],
          body: Buffer.from(JSON.stringify({ error: { code: 'chat-remote', message: 'Chat is not shared with another computer' } })).toString('base64') }, w.sid);
        return;
      }
      let j = {};
      try { j = JSON.parse(body.base64Encoded ? Buffer.from(body.body, 'base64').toString('utf8') : body.body); } catch (_) { /* */ }
      if (/\/api\/v1\/session$/.test(p.request.url)) j.serve = { exposure: 'remote', secure: true, secretsAllowed: false, mac: 'walkmac' };
      else j.access = 'read';
      await bsend('Fetch.fulfillRequest', { requestId: p.requestId, responseCode: 200, responseHeaders: p.responseHeaders, body: Buffer.from(JSON.stringify(j)).toString('base64') }, w.sid);
    };
    await bsend('Fetch.enable', { patterns: [{ urlPattern: '*/api/v1/session', requestStage: 'Response' }, { urlPattern: '*/api/v1/chat/status', requestStage: 'Response' }] }, w.sid);
    await bsend('Page.reload', {}, w.sid);
  };
  await remote(false);
  check(await kwait(w, `/Chat is not shared with this browser/.test(document.querySelector('#chat-notice')?.textContent || '') && document.querySelector('#chat-cols').hidden`, 20000),
    'window 9 another computer with serve.chat off: "Chat is not shared with this browser"');
  const a9 = botAsk('askerbot', ['Read from afar?', '--option', 'yes=Yes']);
  await remote(true);
  check(await kwait(w, `document.getElementById('chat-text')?.disabled === true && !!document.querySelector('[data-ask="${a9}"]')
    && document.querySelectorAll('[data-ask="${a9}"] input, [data-ask="${a9}"] button').length === 0`, 20000),
    'window 9 …with serve.chat read: the composer off, the decision card read-only (the 403s are ServeHTTPTests\')');
  await bsend('Fetch.disable', {}, w.sid);
  w.paused = null;
  spawnSync(dirname(DOZ) + '/dozchat-mac', ['withdraw', room, a9], { encoding: 'utf8', timeout: 60_000,
    env: { PATH: '/usr/bin:/bin', HOME: S, CHAT_URL: 'http://127.0.0.1:' + chatPagePort, CHAT_TOKEN_FILE: S + '/askerbot.token' } });
  await bsend('Page.reload', {}, w.sid);
  await kwait(w, `document.querySelector('#chat-live')?.textContent === 'live'`, 20000);
  // 12. At 390 px no sideways scroll.
  await bsend('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true }, w.sid);
  await sleep(500);
  const phone = await kevaluate(w, `({ scroll: document.scrollingElement.scrollWidth, people: getComputedStyle(document.querySelector('#chat-people-pane')).display })`);
  check(phone.scroll <= 390, `window 12 at 390 px no sideways scroll (${JSON.stringify(phone)})`);
  const ov390 = await kevaluate(w, HEAD_OVERLAPS);
  check(ov390.out.length === 0, `window 12 …and no two controls in its head overlap, the bell included (${ov390.n} controls${ov390.out.length ? ': ' + ov390.out.join(', ') : ''})`);
  await kshot(w, 'chat-window-390');
  await bsend('Emulation.setDeviceMetricsOverride', { width: 440, height: 760, deviceScaleFactor: 1, mobile: false }, w.sid);
  // 13. No CSP violation in any window from its start, no page error; the leak sweep (the windows' answers included).
  let violations = 0, errors = [];
  for (const k of kids.values()) {
    if (!k.gone) violations += (await ksoft(k, 'window.__violations.length')) || 0;
    errors = errors.concat(k.errors);
  }
  check(violations === 0 && (await evaluate('window.__violations.length')) === 0, `window 13 no CSP violation in the dashboard or any window from its start (${violations})`);
  check(errors.length === 0 && pageErrors.length === errorsBefore, 'window 13 no page error in any window' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
  const kidDom = await ksoft(w, `document.documentElement.outerHTML + (() => { const o = []; for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); o.push(k, localStorage.getItem(k)); } return o.join('\\n'); })()`);
  check(hits(kidDom) === 0, 'window 13 the window\'s DOM and storage hold no token');
  await leakSweep('the chat window');
  await bsend('Target.closeTarget', { targetId: w.target });
}

/// 14. The space editor's "Open in a new window": its own window, named for the workspace; a second click reuses it.
async function walkSpaceWindow(name) {
  await browserSocket();
  await goHash('#/w/' + name + '/space');
  const BTN = `[...document.querySelectorAll('[data-sp-bar] button')].find((b) => b.getAttribute('aria-label') === 'Open in a new window')`;
  await waitFor(`!!(${BTN})`, 20000);
  const was = new Set(kids.keys());
  await evaluate(`(${BTN}).click()`, true);
  const k = await newKid(was, new RegExp('/#/w/' + name + '/space$'), 20000);
  check(!!k && await kwait(k, `window.name === 'doz-space-${name}' && !!document.querySelector('#space .space-editor')`, 30000),
    'window 14 the space editor\'s "Open in a new window" opens one: its own window at #/w/' + name + '/space, named doz-space-' + name);
  if (!k) return;
  const n = liveKids().length;
  await evaluate(`(${BTN}).click()`, true);
  await sleep(1500);
  check(liveKids().length === n && !k.gone, 'window 14 …a second click reuses it (no new window)');
  await bsend('Target.closeTarget', { targetId: k.target });
  await goHash('#/w/' + name);
}

// ── a workspace's wide views: Network & secrets, Folders & points, Activity and an agent's Can do ────────────────────
/// `wide`: a fenced session (widef) with a launch secret whose value is a SENTINEL and two more (widef2, widef3), each having been
/// refused one site; an unfenced session (wideu); the never-booted sandbox gamma. All harmless programs, no VM.
// ── the workspace drawn ────────────────────────────────────────────────────────────────────────────────────────────
const RENDERER = /\/assets\/vendor-space-editor-[0-9a-f]{16}\/space-render\.js/;
let firstLoad = null;
async function walkFirstLoad() {
  check(!requested.some((u) => EDITOR_ANY.test(u)), 'pictures: the first load (Home with only plain workspaces) fetches no byte of the space editor (its renderer included)');
  check(await waitFor(`!!document.querySelector('[data-ws="demo"] [data-pic-tile="Made without a space file"]')`, 8000), 'pictures: …a plain tile for demo, made without a space file');
  firstLoad = await evaluate(`(() => { const all = performance.getEntriesByType('navigation').concat(performance.getEntriesByType('resource'))
    .filter((e) => !e.name.includes('/api/'));
    return { files: all.length, bytes: all.reduce((n, e) => n + (e.encodedBodySize || 0), 0) }; })()`);
  const web = 'Sources/DozableWeb/Resources/Web/assets/app/';
  const glue = ['core/space-pictures-', 'components/space-picture-'].map((p) => {
    const dir = web + p.split('/')[0];
    const f = readdirSync(dir).find((n) => n.startsWith(p.split('/')[1]) && n.endsWith('.js'));
    return f ? readFileSync(dir + '/' + f).length : 1e9;
  });
  const editorGlue = ['views/space-page-', 'core/space-editor-'].map((p) => {
    const dir = web + p.split('/')[0];
    const f = readdirSync(dir).find((n) => n.startsWith(p.split('/')[1]) && n.endsWith('.js'));
    return f ? readFileSync(dir + '/' + f).length : 1e9;
  });
  console.log(`  first load: ${firstLoad.files} files, ${firstLoad.bytes} bytes (the two picture modules ${glue[0]} + ${glue[1]} bytes; the editor's ${editorGlue[0]} + ${editorGlue[1]} bytes)`);
  check(glue[0] + glue[1] <= 16384, `pictures: the two glue modules are at most 16 KB (${glue[0] + glue[1]} bytes)`);
  check(editorGlue[0] + editorGlue[1] <= 16384, `space 1 the editor's two glue modules are at most 16 KB (${editorGlue[0] + editorGlue[1]} bytes)`);
}
const pictureSessions = [];
const HERO = (w) => `document.querySelector('[data-ws-hero="${w}"]')`;
const heroKey = (w) => evaluate(`${HERO(w)}?.dataset.picKey || ''`);
async function walkPictures() {
  const errorsBefore = pageErrors.length;
  const SPACE = S + '/space';
  mkdirSync(SPACE, { recursive: true });
  writeFileSync(SPACE + '/BRIEF.md', 'The space walk.\n');
  const SPC2 = 'doz: space/3\nspace: spc2\nbrief: BRIEF.md\nowner: ada\nagents:\n  w1: { kind: claude-code, isolation: fenced, prompt: watch the walk }\n'
    + 'chat:\n  rooms:\n    spc2: { main: true, members: [owner, w1] }\n';
  writeFileSync(SPACE + '/spc2.space.yaml', SPC2);
  const up = doz(['workspace', 'up', '-f', SPACE + '/spc2.space.yaml', '--yes']);
  if (up.status === 0) pictureSessions.push('spc2-w1');
  check(up.status === 0, 'pictures: workspace up -f spc2.space.yaml (a fenced worker running the FAKE claude)');
  // Home, read again on a reload: one thumbnail per space workspace on screen, a tile for each plain one.
  const mark = requested.length;
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  // (the setup, never done here, opens over Home on a load: another page first closes it)
  await goHash('#/mac/sandboxes');
  await goHash('#/home');
  await waitFor(`state.view === 'home' && !state.modal`, 10000);
  check(await waitFor(`!!document.querySelector('[data-ws="spc2"] .sp-thumb img.sp-img:not([hidden])')`, 20000), 'pictures: Home draws spc2\'s thumbnail');
  const rows = (dozJSON(['workspace', 'ls']) || { workspaces: [] }).workspaces;
  await sleep(800);
  const home = await evaluate(`[...document.querySelectorAll('tr[data-ws]')].map((r) => ({ name: r.dataset.ws, img: !!r.querySelector('.sp-thumb[data-pic] img.sp-img:not([hidden])'),
    tile: !!r.querySelector('[data-pic-tile]') }))`);
  const wrong = home.filter((r) => { const w = rows.find((x) => x.name === r.name); return !w || (w.space ? !r.img : !r.tile); });
  check(home.length > 2 && !wrong.length, `pictures: Home — a thumbnail for each space workspace, a tile for each plain one (${home.length} rows${wrong.length ? '; wrong: ' + wrong.map((r) => r.name).join(', ') : ''})`);
  // The sidebar: spc2 unfolded shows its picture; demo (plain) unfolded shows none.
  for (const n of ['spc2', 'demo']) await evaluate(`(() => { const c = document.querySelector('[data-ws-fold="${n}"]'); if (c && c.getAttribute('aria-expanded') !== 'true') c.click(); })()`);
  check(await waitFor(`!!document.querySelector('[data-nav-ws="spc2"] .nav-ws-thumb img.sp-img:not([hidden])')`, 15000), 'pictures: the unfolded sidebar draws spc2');
  check(await evaluate(`!!document.querySelector('[data-nav-ws="demo"] [data-ws-inside]') && !document.querySelector('[data-nav-ws="demo"] .nav-ws-thumb')`), 'pictures: …and nothing for demo, made without a space file');
  check(requested.slice(mark).filter((u) => RENDERER.test(u)).length === 1, `pictures: the renderer is fetched once (${requested.slice(mark).filter((u) => RENDERER.test(u)).length})`);
  // Pictures for a person: Home light, the sidebar with spc2 unfolded, Home at 390 px.
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  await sleep(1200);
  await shot('pictures-home-light');
  await shot('pictures-sidebar', '#nav');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await sleep(1200);
  await shot('pictures-home-390');
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await evaluate(`delete document.documentElement.dataset.theme`);
  // The hero on #/w/spc2.
  await goHash('#/w/spc2');
  check(await waitFor(`!!${HERO('spc2')}?.dataset.picKey && !!${HERO('spc2')}.querySelector('svg.space-render')`, 20000), 'pictures: #/w/spc2 draws its hero');
  check(/spc2, drawn from its space file/.test(await evaluate(`${HERO('spc2')}.getAttribute('aria-label')`)), 'pictures: …its aria-label names it');
  const ms = await evaluate(`JSON.stringify(pictureStats.ms)`);
  console.log('  render times (ms, this Mac): ' + ms);
  // No event, no read: 3 s with no changed / host / hello reads no state.
  await sleep(1500);
  const r0 = requested.filter((u) => /\/api\/v1\/workspace-state$/.test(u)).length, t0 = Date.now();
  await sleep(3000);
  const evs = sseEvents.filter((e) => e.at >= t0 && ['changed', 'host', 'hello'].includes(e.name)).length;
  const reads = requested.filter((u) => /\/api\/v1\/workspace-state$/.test(u)).length - r0;
  check(evs > 0 ? reads <= evs * 4 : reads === 0, `pictures: 3 s — ${evs} event(s), ${reads} state read(s) (none without an event; no timer reads)`);
  // The hero is a link to the space editor's page (the editor's own rows are walkSpace's).
  check(await evaluate(`${HERO('spc2')}.tagName === 'A' && ${HERO('spc2')}.getAttribute('href') === '#/w/spc2/space'`), 'pictures: the hero is a link to #/w/spc2/space');
  // Theme: dark is a new drawing; light again is the cache's.
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  await waitFor(`(${HERO('spc2')}.dataset.picKey || '').includes('|light|')`, 10000);
  const light = await heroKey('spc2');
  await evaluate(`document.documentElement.dataset.theme = 'dark'`);
  check(await waitFor(`(${HERO('spc2')}.dataset.picKey || '').includes('|dark|')`, 10000), 'pictures: dark — a new drawing');
  await shot('pictures-dark');
  const hits = await evaluate('pictureStats.hits');
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  const again = await waitFor(`${HERO('spc2')}.dataset.picKey === ${JSON.stringify(light)} && pictureStats.hits > ${hits}`, 10000);
  check(again, 'pictures: light again — the same drawing, from the cache' + (again ? '' : ` (was ${light}, now ${await heroKey('spc2')}, hits ${await evaluate('pictureStats.hits')})`));
  await shot('pictures-light');
  await evaluate(`delete document.documentElement.dataset.theme`);
  // Reduced motion: the hero is a still.
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  await sleep(300);
  check(await evaluate(`${HERO('spc2')}.querySelector('svg').getAnimations({ subtree: true }).length === 0`), 'pictures: under reduced motion the hero has no animation');
  await send('Emulation.setEmulatedMedia', { features: [] });
  // A toast never covers the hero's drawing: a brief saved on the Room tab announces itself in a card, then Home's hero is
  // shown while it is up. (On the Room tab there is no hero.)
  await goHash('#/w/spc2/room');
  check(await waitFor(`!!document.querySelector('[data-ws-brief="spc2"]') && !document.body.classList.contains('ws-hero-on')`, 10000), 'pictures: the Room tab shows no hero');
  await evaluate(`[...document.querySelectorAll('[data-ws-brief="spc2"] button')].find((b) => /Edit/.test(b.textContent)).click()`);
  await waitFor(`!!document.querySelector('.ws-brief-area')`, 8000);
  await evaluate(`(() => { const a = document.querySelector('.ws-brief-area'); a.value = 'The space walk, seen.'; a.dispatchEvent(new Event('input')); })()`);
  await evaluate(`[...document.querySelectorAll('.ws-brief-acts button')].find((b) => /Save/.test(b.textContent)).click()`);
  const toastSeen = await waitFor(`[...document.querySelectorAll('.notes .callout.note')].some((n) => n.getBoundingClientRect().height > 0)`, 15000);
  await goHash('#/w/spc2');
  await waitFor(`document.body.classList.contains('ws-hero-on')`, 5000);
  const toast = toastSeen && await waitFor(`[...document.querySelectorAll('.notes .callout.note')].some((n) => n.getBoundingClientRect().height > 0)`, 2000);
  const overlap = await evaluate(`(() => { const p = ${HERO('spc2')}.querySelector('.ws-hero-pic').getBoundingClientRect();
    return [...document.querySelectorAll('.notes .callout.note')].map((n) => n.getBoundingClientRect()).filter((r) => r.height > 0)
      .filter((r) => r.left < p.right && r.right > p.left && r.top < p.bottom && r.bottom > p.top).length; })()`);
  check(toast && overlap === 0, `pictures: a toast while the hero is shown does not cover its drawing (${toast ? overlap + ' overlapping' : 'no toast seen'})`);
  await shot('pictures-toast');
  // (the brief's editor scrolled the page: the hero back on screen — only pictures on screen are read)
  await evaluate(`window.scrollTo(0, 0)`);
  check(await waitFor(`document.body.classList.contains('ws-hero-on')`, 8000), 'pictures: …the hero back on screen');
  // A state change redraws: down, then after `changed` a new key with a new state sha. (The down of a space whose agents
  // all run on this Mac is no event of its own — `changed` follows the sandboxes; so a sandbox made beside it, never
  // booted, is the event here.)
  const before = await heroKey('spc2'), downAt = Date.now(), readsBefore = await evaluate('pictureStats.stateReads');
  const down = doz(['workspace', 'down', 'spc2', '--yes']);
  check(down.status === 0, 'pictures: workspace down spc2');
  doz(['create', 'pictures-poke', '--image', 'lab', '--isolated']);
  const redrawn = await waitFor(`(() => { const k = ${HERO('spc2')}?.dataset.picKey || ''; return k && k.split('|')[1] !== ${JSON.stringify(before.split('|')[1])}; })()`, 30000);
  check(redrawn, 'pictures: …after changed, the hero is drawn again with a new state sha' + (redrawn ? '' : ` (events ${sseEvents.filter((e) => e.at >= downAt).map((e) => e.name).join(',')};`
    + ` state reads ${(await evaluate('pictureStats.stateReads')) - readsBefore}; key ${await heroKey('spc2')})`));
  // 390 px: the hero fits.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  check(await waitFor(`(${HERO('spc2')}?.dataset.picKey || '').includes('|800x560|')`, 10000), 'pictures: at 390 px the hero is drawn at its narrow size');
  const fit = await evaluate(`({ w: ${HERO('spc2')}.getBoundingClientRect().width, page: document.documentElement.scrollWidth })`);
  check(fit.w <= 390 && fit.page <= 390, `pictures: …and fits (${Math.round(fit.w)} px, the page ${fit.page} px)`);
  await shot('pictures-390');
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  // A file that doesn't read: the marker and Dozable's problem line (read again on arriving).
  writeFileSync(SPACE + '/spc2.space.yaml', 'doz: space/3\nspace: spc2\nagents: [one, two]\n');
  await goHash('#/w/demo2');
  await waitFor(`state.param === 'demo2'`);
  await goHash('#/w/spc2');
  check(await waitFor(`!!${HERO('spc2')}.querySelector('svg.space-render.problem')`, 15000), 'pictures: a file that doesn\'t read draws the marker');
  check(await waitFor(`(() => { const p = document.querySelector('[data-ws-hero-problem]'); return !!p && !p.hidden && /doesn.t read/.test(p.textContent) && !!p.querySelector('[data-cmd*="--dry-run"]'); })()`, 15000),
    'pictures: …and Dozable\'s problem line with the dry run\'s command');
  writeFileSync(SPACE + '/spc2.space.yaml', SPC2);
  check((await evaluate('window.__violations.length')) === 0, 'pictures: no CSP violation' + ((await evaluate('window.__violations.join(" | ")')) || ''));
  check(pageErrors.length === errorsBefore, 'pictures: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  await leakSweep('the workspace drawn');
}

// ── the space editor's page ───────────────────────────────────────────────────────────────────────────────────────────
const EDITOR_ANY = /\/assets\/vendor-space-editor-[0-9a-f]{16}\//;
const treeFile = (f) => new RegExp('/assets/vendor-space-editor-[0-9a-f]{16}/' + f.replace(/[.]/g, '\\.') + '$');
const fetchedSince = (mark, f) => requested.slice(mark).filter((u) => treeFile(f).test(u)).length;
const SE = (sel) => `document.querySelector('#space .space-editor ${sel}')`;
const spaceSessions = [];
async function keyMod(k, code, modifiers) {
  const vk = k.length === 1 ? k.toUpperCase().charCodeAt(0) : 0;
  for (const type of ['keyDown', 'keyUp']) await send('Input.dispatchKeyEvent', { type, key: k, code, modifiers, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, ...(type === 'keyDown' && !modifiers ? { text: k } : {}) });
}
const MONACO_INPUT = `document.querySelector('#space .monaco-editor .native-edit-context, #space .monaco-editor textarea')`;
async function typeInText(t) {
  await evaluate(`${MONACO_INPUT}.focus()`);
  await send('Input.insertText', { text: t });
}
/// The leak sweep's and a listener count: the window's and the document's listeners (DOMDebugger), for the dispose rows.
async function listenerCount() {
  let n = 0;
  for (const expr of ['window', 'document']) {
    const o = await send('Runtime.evaluate', { expression: expr });
    n += (await send('DOMDebugger.getEventListeners', { objectId: o.result.objectId })).listeners.length;
  }
  return n;
}
/// A real click at an element's centre (the editor's own controls listen for the pointer).
async function clickAt(expr) {
  const p = await evaluate(`(() => { const e = ${expr}; if (!e) return null; e.scrollIntoView({ block: 'nearest' }); const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
  if (!p) return false;
  for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x: p[0], y: p[1], button: 'left', clickCount: 1 });
  return true;
}
const strayTabs = async () => (await (await fetch(`http://127.0.0.1:${devPort}/json/list`)).json()).filter((t) => t.type === 'page' && !t.url.startsWith('http://127.0.0.1')).map((t) => t.url);
async function walkSpace() {
  const errorsBefore = pageErrors.length;
  const SPACE = S + '/space3';
  mkdirSync(SPACE, { recursive: true });
  writeFileSync(SPACE + '/BRIEF.md', 'The editor walk.\n');
  const SENTINEL = 'spc3-sentinel-' + randomUUID();
  knownTokens.push(SENTINEL);
  writeFileSync(SPACE + '/.env', 'SPC3_UNUSED=' + SENTINEL + '\n');
  const DEFAULTS = 'doz: space-defaults/3\npersist:\n  team-chat: { room: spc3 }\n';
  writeFileSync(SPACE + '/walk_defaults.yaml', DEFAULTS);
  const SPC3 = 'doz: space/3\nextends: ./walk_defaults.yaml\nspace: spc3\nbrief: BRIEF.md\nowner: ada\nagents:\n'
    + '  w3: { kind: claude-code, isolation: fenced, prompt: BLOCK-ME and watch the editor }\n'
    + 'chat:\n  rooms:\n    spc3: { main: true, members: [owner, w3] }\n';
  writeFileSync(SPACE + '/spc3.space.yaml', SPC3);
  doz(['chat', 'add', 'spcask', '--to-file', S + '/spcask.token']);
  if (existsSync(S + '/spcask.token')) knownTokens.push(readFileSync(S + '/spcask.token', 'utf8').trim());
  const up = doz(['workspace', 'up', '-f', SPACE + '/spc3.space.yaml', '--yes']);
  if (up.status === 0) spaceSessions.push('spc3-w3');
  doz(['chat', 'send', 'spc3', '/invite @spcask']);
  check(up.status === 0, 'space: workspace up -f spc3.space.yaml (extends a defaults file; a fenced worker on the FAKE claude)');
  // 1. Nothing of the editor before its page: the first load fetched no byte of the tree but the renderer's.
  check(!requested.some((u) => EDITOR_ANY.test(u) && !RENDERER.test(u)), 'space 1 nothing of the editor is fetched before its page (the renderer only, for pictures)');
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  await goHash('#/mac/sandboxes');
  // 2. The hero is a link to the page; following it opens the editor.
  await goHash('#/w/spc3');
  check(await waitFor(`document.querySelector('[data-ws-hero="spc3"]')?.getAttribute('href') === '#/w/spc3/space'`, 20000)
    && await evaluate(`/Edit the space/.test(document.querySelector('[data-ws-hero-band="spc3"] [data-ws-hero-open]')?.textContent || '')`),
    'space 2 the hero is a link to #/w/spc3/space (a new tab with ⌘-click), beside "Edit the space"');
  const mark = requested.length;
  await evaluate(`document.querySelector('[data-ws-hero="spc3"]').click()`);
  check(await waitFor(`location.hash === '#/w/spc3/space' && state.view === 'space' && document.body.classList.contains('space-page') && !document.getElementById('space').hidden`, 10000)
    && await evaluate(`getComputedStyle(document.querySelector('.side')).display === 'none' && document.title === 'spc3 — space'`), 'space 2 …it opens the page: the whole window, its title');
  // 3. The canvas draws; only the features this viewer may use are fetched.
  check(await waitFor(`!!${SE('svg.scene [data-id]')} || !!${SE('.canvas-stage svg')}`, 30000), 'space 3 the canvas draws');
  await sleep(800);
  const got = ['space-core.js', 'space-canvas.js', 'space-edit.js', 'space-plan.js', 'space-live.js', 'space-motion.js'].filter((f) => fetchedSince(mark, f) === 1);
  const never = ['monaco/monaco.js', 'monaco/editor.worker.js', 'monaco/monaco.css', 'monaco/codicon.ttf', 'space-text.js', 'space-sim.js', 'space-timeline.js'].filter((f) => fetchedSince(mark, f) > 0);
  check(got.length === 6 && never.length === 0, `space 3 fetched: the core, canvas, edit, plan, live, motion once each (${got.length}); never Monaco, text, sim or timeline (${never.join(', ') || 'none'})`);
  check(await evaluate(`document.querySelector('[data-sp-word]')?.textContent === 'Saved' && !!document.querySelector('[data-sp-text]:not([hidden])')`), 'space 3 …the bar: Saved, Text');
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  await sleep(1200);
  await shot('space-editor-light');
  await evaluate(`document.documentElement.dataset.theme = 'dark'`);
  await sleep(1200);
  await shot('space-editor-dark');
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  // Reload and a bookmark: the same address opens the editor again.
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  check(await waitFor(`state.view === 'space' && !!${SE('.canvas-stage')}`, 30000), 'space 2 …a reload (a bookmark) opens the editor again');
  // 8. Live on (the viewer's choice, kept in this browser), then live from the events only: 3 s without one reads no state.
  await evaluate(`(() => { const b = ${SE('.live-toggle')}; if (b && b.getAttribute('aria-pressed') !== 'true') b.click(); })()`);
  check(await waitFor(`${SE('.live-toggle')}?.getAttribute('aria-pressed') === 'true'`, 5000) && await evaluate(`localStorage.getItem('doz.space.spc3.live') === '1'`),
    'space 8 Live on, kept for this viewer (doz.space.spc3.live)');
  await sleep(1500);
  const s0 = requested.filter((u) => /\/api\/v1\/workspace-state$/.test(u)).length, t0 = Date.now();
  await sleep(3000);
  const evs = sseEvents.filter((e) => e.at >= t0 && ['changed', 'host', 'hello'].includes(e.name)).length;
  const reads = requested.filter((u) => /\/api\/v1\/workspace-state$/.test(u)).length - s0;
  check(evs > 0 ? reads <= evs * 2 : reads === 0, `space 8 3 s — ${evs} event(s), ${reads} state read(s): none without an event (no polling)`);
  // 8. The FAKE agent reports itself blocked: after an event, the drawing's attention (a sandbox made beside it is the event).
  doz(['create', 'space-poke', '--image', 'lab', '--isolated']);
  check(await waitFor(`/w3: blocked/.test(document.querySelector('#space .space-editor').textContent)`, 30000),
    'space 8 the agent blocked: the drawing\'s attention says so, after an event');
  // 4. Text: Monaco is fetched then, and only then.
  const tm = requested.length;
  await evaluate(`document.querySelector('[data-sp-text]').click()`);
  check(await waitFor(`!!document.querySelector('#space .monaco-editor') && spaceNow().features.includes('text')`, 30000), 'space 4 Text opens the text view (added to the editor)');
  await sleep(1500);
  const mon = ['monaco/monaco.js', 'monaco/monaco.css', 'monaco/editor.worker.js', 'space-text.js'].map((f) => fetchedSince(tm, f));
  const font = fetchedSince(tm, 'monaco/codicon.ttf');
  check(mon.every((n) => n === 1) && font <= 1 && fetchedSince(0, 'monaco/monaco.js') === 1, `space 4 …Monaco, its stylesheet, its worker and the text feature fetched after the click, once (${mon.join(',')}; the icon font ${font})`);
  await shot('space-editor-text');
  // 5. Typing makes it dirty; the guard holds a hash change (Stay keeps it); ⌘S saves over the version read.
  await typeInText('# typed in the walk\n');
  check(await waitFor(`state.spaceDirty === true && document.querySelector('[data-sp-word]').textContent === 'Unsaved'`, 10000), 'space 5 typing: Unsaved');
  await evaluate(`location.hash = '#/w/spc3/agents'`);
  check(await waitFor(`!!document.querySelector('dialog[data-sp-dialog="leave"][open]') && location.hash === '#/w/spc3/space'`, 5000), 'space 5 the guard: leaving asks, the address stays');
  await evaluate(`[...document.querySelectorAll('dialog[data-sp-dialog="leave"] button')].find((b) => b.textContent === 'Stay').click()`);
  check(await waitFor(`!document.querySelector('dialog[open]') && state.view === 'space' && state.spaceDirty`, 5000), 'space 5 …Stay keeps the page and the changes');
  await evaluate(`${MONACO_INPUT}.focus()`);
  await keyMod('s', 'KeyS', 4);
  check(await waitFor(`!state.spaceDirty && document.querySelector('[data-sp-word]').textContent === 'Saved'`, 30000), 'space 5 ⌘S saves: Saved');
  const disk = readFileSync(SPACE + '/spc3.space.yaml', 'utf8');
  const shown = dozJSON(['workspace', 'show', 'spc3', '--space']) || {};
  const shaDisk = createHash('sha256').update(disk).digest('hex');
  check(disk.includes('# typed in the walk') && (shown.sha256 || shown.space?.sha256) === shaDisk, `space 5 …the file holds it and show --space --json has its sha (${(shown.sha256 || shown.space?.sha256 || '?').slice(0, 8)} = ${shaDisk.slice(0, 8)})`);
  check(await waitFor(`[...document.querySelectorAll('.notes .callout')].some((n) => /Not applied: Up applies it/.test(n.textContent))`, 8000), 'space 5 …"Saved. Not applied: Up applies it."');
  // 6. Changed on disk since: ⌘S → Changed elsewhere, nothing written; Reload takes the file as it is.
  const elsewhere = disk + '# changed elsewhere\n';
  writeFileSync(SPACE + '/spc3.space.yaml', elsewhere);
  await typeInText('# typed again\n');
  await keyMod('s', 'KeyS', 4);
  check(await waitFor(`/Changed elsewhere/.test(${SE('#se-filebar')}?.textContent || '') && !document.querySelector('[data-sp-reload]').hidden`, 30000)
    && readFileSync(SPACE + '/spc3.space.yaml', 'utf8') === elsewhere, 'space 6 a stale save: "Changed elsewhere", nothing written, Reload offered');
  await shot('space-editor-conflict');
  await evaluate(`document.querySelector('[data-sp-reload]').click()`);
  check(await waitFor(`spaceNow().text === ${JSON.stringify(elsewhere)} && !state.spaceDirty`, 15000), 'space 6 …Reload: the file as it is now, clean');
  // 7. A typo: listed and marked; the defaults file's problem named, not placed in this file.
  await typeInText('agentz: 1\n');
  check(await waitFor(`[...document.querySelectorAll('#space #se-problems-list .prob')].some((p) => /agentz/.test(p.textContent))`, 20000), 'space 7 a typo is listed');
  await evaluate(`(() => { const t = ${JSON.stringify(elsewhere)}; })()`);
  writeFileSync(SPACE + '/walk_defaults.yaml', DEFAULTS + 'agents: { x: {} }\n');
  await typeInText('# again\n');
  check(await waitFor(`[...document.querySelectorAll('#space #se-problems-list .prob.other-file')].some((p) => /walk_defaults/.test(p.textContent))`, 20000),
    'space 7 …a problem in the defaults file is named with its file, not placed here');
  writeFileSync(SPACE + '/walk_defaults.yaml', DEFAULTS);
  await evaluate(`(async () => { const e = document.querySelector('[data-sp-reload]'); e.hidden = false; e.click(); })()`);
  await waitFor(`!state.spaceDirty`, 10000);
  // 9. A bot's Ask in the space's room: drawn through onAskChange and the next state; answered through the Ask flow.
  const askId = (() => {
    writeFileSync(S + '/spc3-q.json', JSON.stringify([{ id: 'ship', question: 'Ship the editor?', options: [{ id: 'yes', label: 'Yes' }, { id: 'no', label: 'No' }] }]));
    const r = spawnSync(dirname(DOZ) + '/dozchat-mac', ['ask', 'spc3', 'Ship the editor', '--questions', S + '/spc3-q.json'], { encoding: 'utf8', timeout: 60_000,
      env: { PATH: '/usr/bin:/bin', HOME: S, CHAT_URL: 'http://127.0.0.1:' + chatPagePort, CHAT_TOKEN_FILE: S + '/spcask.token' } });
    try { return JSON.parse(r.stdout).msg_id || ''; } catch (_) { return ''; }
  })();
  doz(['create', 'space-poke2', '--image', 'lab', '--isolated']);
  const asked = await waitFor(`document.querySelectorAll('#space .space-editor .ask-card').length > 0`, 30000);
  check(!!askId && asked, 'space 9 a bot\'s Ask in spc3 is drawn on the canvas' + (askId ? '' : ' (no ask made)'));
  if (asked) {
    await clickAt(`[...document.querySelectorAll('#space .space-editor #se-problems-list .prob.k-ask')].find((b) => /Ship the editor/.test(b.textContent))`);
    await waitFor(`!!${SE('dialog.ask-dlg[open] .ask-option')}`, 8000);
    await clickAt(`[...document.querySelectorAll('#space .space-editor dialog.ask-dlg .ask-option')].find((b) => b.textContent === 'Yes')`);
    await clickAt(`[...document.querySelectorAll('#space .space-editor dialog.ask-dlg .dlg-foot button')].find((b) => b.textContent === 'Send')`);
    const answered = await waitFor(`[...state.ops.values()].some((o) => o.action === 'chat-decide' && o.state === 'done')`, 30000);
    check(answered && !(((dozJSON(['chat', 'asks', 'spc3']) || {}).asks || []).some((a) => a.msgId === askId)), 'space 9 …answered from the drawing: the operation done, the ask no longer open');
  }
  // 11. Watch: read-only, the canvas with Live on, no bar.
  await goHash('#/w/spc3/space/watch');
  check(await waitFor(`state.view === 'space' && spaceNow()?.mode === 'watch' && !!${SE('.canvas-stage')}`, 20000)
    && await evaluate(`!document.querySelector('[data-sp-bar]') && !!document.querySelector('[data-sp-back][href="#/w/spc3/space"]')
      && ${SE('.live-toggle')}?.getAttribute('aria-pressed') === 'true' && !document.querySelector('#space .monaco-editor')`), 'space 11 watch: the canvas, Live on, no bar, no text, "Back to the editor"');
  await shot('space-watch');
  // 13. 390 px: the canvas only, no sideways scroll.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await goHash('#/w/spc3');
  await goHash('#/w/spc3/space');
  check(await waitFor(`state.view === 'space' && !!${SE('.canvas-stage')}`, 20000), 'space 13 at 390 px the editor opens');
  await evaluate(`document.querySelectorAll('.notes .b-x').forEach((b) => b.click())`);
  await sleep(2500);
  const narrow = await evaluate(`({ w: document.documentElement.scrollWidth, f: spaceNow().features.join(','), mon: !!document.querySelector('#space .monaco-editor'),
    note: /Edit on a wider screen/.test(document.querySelector('[data-sp-bar]')?.textContent || '') })`);
  check(narrow.w <= 390 && narrow.f === 'canvas,live,motion' && !narrow.mon && narrow.note, `space 13 …the canvas only (${narrow.f}), "Edit on a wider screen", ${narrow.w} px`);
  // The drawing fits on its first paint, no Fit pressed: drawn shapes inside the canvas's box.
  const inside = await evaluate(`(() => { const st = ${SE('.canvas-stage')}.getBoundingClientRect();
    return [...document.querySelectorAll('#space .space-editor .canvas-stage svg [data-id]')].map((e) => e.getBoundingClientRect())
      .filter((r) => r.width > 0 && r.height > 0 && r.left >= st.left - 1 && r.right <= st.right + 1 && r.top >= st.top - 1 && r.bottom <= st.bottom + 1).length; })()`);
  check(inside > 0, `space 13 …the drawing is visible on its first paint, no Fit pressed (${inside} shapes inside the canvas's box)`);
  await shot('space-390');
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  // 14. The dashboard's keys stay out; ? inside opens the editor's own sheet.
  await goHash('#/w/spc3');
  await goHash('#/w/spc3/space');
  await waitFor(`!!${SE('.canvas-stage')}`, 20000);
  await evaluate(`(() => { const c = ${SE('.canvas-stage')}; c.setAttribute('tabindex', c.getAttribute('tabindex') || '-1'); c.focus(); })()`);
  for (const type of ['keyDown', 'keyUp']) {
    await send('Input.dispatchKeyEvent', { type, key: '?', code: 'Slash', modifiers: 8, windowsVirtualKeyCode: 191, nativeVirtualKeyCode: 191, ...(type === 'keyDown' ? { text: '?' } : {}) });
  }
  check(await waitFor(`!!${SE('dialog.keys-dlg[open]')}`, 5000) && await evaluate(`!document.getElementById('sc-title')`), 'space 14 ? inside opens the editor\'s own keys, not the dashboard\'s');
  // (Escape without a native key code: CDP's native 27 is another key on a Mac.)
  for (const type of ['keyDown', 'keyUp']) await send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  check(await waitFor(`!${SE('dialog.keys-dlg[open]')}`, 3000) && await evaluate(`state.view === 'space'`), 'space 14 …Escape closes it and never leaves the page');
  const strays = (await strayTabs());
  check(strays.length === 0 && (await evaluate('document.visibilityState')) === 'visible', `space 14 …and no other tab opened (${strays.join(', ') || 'none'})`);
  // Dispose three times: no editor left, no listener growing.
  await goHash('#/w/spc3');
  const before = await listenerCount();
  for (let i = 0; i < 3; i++) {
    await goHash('#/w/spc3/space');
    await waitFor(`!!${SE('.canvas-stage')}`, 20000);
    await goHash('#/w/spc3');
    await waitFor(`state.view === 'workspace'`, 5000);
  }
  await sleep(500);
  const after = await listenerCount();
  check(await evaluate(`document.querySelectorAll('.space-editor').length === 0 && document.getElementById('space').childElementCount === 0`) && after <= before,
    `space 14 entered and left three times: no editor left, listeners ${before} → ${after}`);
  // 12. Another computer (its file read as canSave false): no edit fetched, no Save, the text read-only, no answer.
  await send('Fetch.enable', { patterns: [{ urlPattern: '*/api/v1/workspace-space', requestStage: 'Response' }] });
  pausedHook = async (p) => {
    const b = await send('Fetch.getResponseBody', { requestId: p.requestId });
    const j = JSON.parse(b.base64Encoded ? Buffer.from(b.body, 'base64').toString('utf8') : b.body);
    j.canSave = false; j.command = 'doz workspace edit spc3 --space-file ' + j.shownPath + ' --if-match ' + j.sha256;
    await send('Fetch.fulfillRequest', { requestId: p.requestId, responseCode: 200, responseHeaders: p.responseHeaders, body: Buffer.from(JSON.stringify(j)).toString('base64') });
  };
  const rm = requested.length;
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  await goHash('#/w/spc3/space');
  check(await waitFor(`state.view === 'space' && !!${SE('.canvas-stage')}`, 30000), 'space 12 another computer: the editor opens');
  await sleep(1500);
  const remote = await evaluate(`({ word: document.querySelector('[data-sp-word]')?.textContent, said: /Changed only in this Mac/.test(document.querySelector('[data-sp-bar]')?.textContent || ''),
    cmd: !!document.querySelector('[data-sp-bar] [data-cmd^="doz workspace edit spc3"]'), f: spaceNow().features.join(',') })`);
  check(remote.word === 'Read-only here' && remote.said && remote.cmd && fetchedSince(rm, 'space-edit.js') === 0 && !remote.f.includes('edit'),
    `space 12 …read-only here, "Changed only in this Mac's own browser" and the command; no edit feature fetched (${remote.f})`);
  await shot('space-another-computer');
  await send('Fetch.disable');
  pausedHook = null;
  check(true, 'space 12 …another computer\'s 403 for the save and an answer is ServeHTTPTests\' (testTheSpaceFileIsReadRemotelyWithServeChatButNeverSaved, testAnAskIsAnsweredOnlyInThisMacsBrowserWhateverTheServeSettings)');
  // 10. Runs: after down, the strip lists the run with its frames; stepping one reads its frames.
  await goHash('#/w/spc3');
  check(doz(['workspace', 'down', 'spc3', '--yes']).status === 0, 'space 10 workspace down spc3');
  spaceSessions.length = 0;
  await goHash('#/w/spc3/space');
  await waitFor(`!!${SE('.canvas-stage')}`, 20000);
  const fr = requested.length;
  const chips = await waitFor(`document.querySelectorAll('#space .space-editor .run-chip').length > 0`, 20000);
  if (chips) await clickAt(`document.querySelector('#space .space-editor .run-chip')`);
  await sleep(2000);
  check(chips && requested.slice(fr).some((u) => /\/api\/v1\/workspace-run-frames$/.test(u)),
    'space 10 the runs strip lists the run; choosing it reads its frames');
  await goHash('#/w/spc3');
  // 15, 16.
  check((await evaluate('window.__violations.length')) === 0, 'space 15 no CSP violation' + ((await evaluate('window.__violations.join(" | ")')) || ''));
  check(pageErrors.length === errorsBefore, 'space: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  await leakSweep('the space editor (the .env sentinel, the bot\'s token)');
}

// ── a workspace's Home tab ─────────────────────────────────────────────────────────────────────────────────────────
const homeSessions = [];
const CARDS = `Object.fromEntries([...document.querySelectorAll('#ws-home [data-ws-card]')].map((c) => [c.dataset.wsCard, c.querySelector('.ws-card-h a')?.getAttribute('href') || null]))`;
async function walkHome() {
  const errorsBefore = pageErrors.length;
  // 1. #/w/demo2 is its Home: the tab selected, no picture outside it.
  await goHash('#/w/demo2/agents');
  const mark0 = requested.length;
  await goHash('#/w/demo2');
  check(await waitFor(`state.view === 'workspace' && state.wsTab === 'home' && document.querySelector('#ws [data-ws-tab="home"]')?.getAttribute('aria-selected') === 'true'
    && !!document.querySelector('#ws-home [data-ws-home="demo2"]') && !document.getElementById('ws-home').hidden`, 15000), 'home 1 #/w/demo2 opens its Home tab, selected');
  check(await evaluate(`![...document.querySelectorAll('.ws-hero-band')].some((b) => !b.closest('#ws-home')) && !document.getElementById('ws-hero')`), 'home 1 …no picture outside Home');
  // 2. Its cards, each heading its tab's address; Needs you absent when nothing waits.
  await waitFor(`!!document.querySelector('#ws-home [data-ws-card="network"]')`, 10000);
  const cards = await evaluate(CARDS);
  const want = { state: '#/w/demo2/runs', who: '#/w/demo2/agents', room: '#/w/demo2/room', activity: '#/w/demo2/activity', folders: '#/w/demo2/folders', network: '#/w/demo2/network' };
  check(Object.entries(want).every(([k, v]) => cards[k] === v), 'home 2 the cards state, who, room, activity, folders and network, each heading its tab ' + JSON.stringify(cards));
  check(!('needs' in cards), 'home 2 …Needs you absent when nothing waits');
  check(await waitFor(`(() => { const n = document.querySelectorAll('#ws-home [data-ws-card="room"] [data-ws-home-msg]').length; return n >= 1 && n <= 2; })()`, 10000),
    'home 2 …the room card shows its last messages (at most two)');
  check(await evaluate(`(() => { const n = document.querySelectorAll('#ws-home [data-ws-card="activity"] .ws-home-log li').length; return n >= 1 && n <= 5; })()`), 'home 2 …recent activity: at most five lines');
  check(await evaluate(`!!document.querySelector('#ws-home [data-ws-card="folders"] [data-ws-folder]') && !!document.querySelector('#ws-home [data-ws-card="who"] [data-ws-agent="beta"]')`),
    'home 2 …its folder and its agents, as the side panel has them');
  check(!requested.slice(mark0).some((u) => /\/api\/v1\/workspace-folders$/.test(u)), 'home 2 …no walk of its folders');
  // 3. Setting up: Needs you lists what is missing and Start; the Room tab keeps one line.
  await goHash('#/w/wiz2');
  check(await waitFor(`!!document.querySelector('#ws-home [data-ws-card="needs"] [data-ws-setup]') && !!document.querySelector('#ws-home [data-ws-start="wiz2"]')
    && /doz workspace start wiz2/.test(${text('#ws-home [data-ws-card="needs"]')})`, 15000), 'home 3 wiz2 (setting up): Needs you lists what is missing, Start and its command');
  await goHash('#/w/wiz2/room');
  check(await waitFor(`!!document.querySelector('#ws-notice [data-ws-setup-line]') && /Home shows what is missing/.test(${text('#ws-notice [data-ws-setup-line]')})
    && !document.querySelector('#ws-notice [data-gap]')`, 10000), 'home 3 …its Room tab: the one line, "Home shows what is missing"');
  // 4. An open ask in askw's room is in Needs you, linking to the room (answered there); decided, gone on the next arrival.
  const ask = botAsk('askerbot', ['Ready for Home?', '--option', 'yes=Yes', '--option', 'no=No']);
  await goHash('#/w/askw');
  check(await waitFor(`document.querySelector('#ws-home [data-ws-home-ask="${ask}"] a[data-ws-home-answer]')?.getAttribute('href') === '#/w/askw/room'`, 15000)
    && /Ready for Home\?/.test(await evaluate(text('#ws-home [data-ws-card="needs"]'))), 'home 4 an open ask in its room is in Needs you, "Answer in the room" → #/w/askw/room');
  check(await evaluate(`!document.querySelector('#ws-home [data-ask]') && !document.querySelector('#ws-home .chat-ask-input')`), 'home 4 …never answered here (no decision card on Home)');
  doz(['chat', 'decide', 'askw', '#' + askNumber(ask), 'A']);
  await goHash('#/w/askw/agents');
  await goHash('#/w/askw');
  check(await waitFor(`!document.querySelector('#ws-home [data-ws-home-ask="${ask}"]')`, 15000), 'home 4 …decided, gone on the next arrival');
  // 8. A message arriving while on Home is not marked seen (Home is not the room; the room card follows while the stream is open).
  await goHash('#/w/askw/room');
  await waitFor(`state.chat.room === 'askw' && state.chat.live === 'live'`, 15000);
  await goHash('#/w/askw');
  await waitFor(`state.wsTab === 'home'`, 5000);
  const words = 'while you are on Home ' + process.pid;
  const seenBefore = await evaluate(`localStorage.getItem('doz.chat.seen:askw')`);
  spawnSync(dirname(DOZ) + '/dozchat-mac', ['send', 'askw', words], { encoding: 'utf8', timeout: 60_000,
    env: { PATH: '/usr/bin:/bin', HOME: S, CHAT_URL: 'http://127.0.0.1:' + chatPagePort, CHAT_TOKEN_FILE: S + '/askerbot.token' } });
  const last = (dozJSON(['chat', 'read', 'askw', '--last', '1']) || [])[0] || {};
  check(last.content === words, 'home 8 a bot posts in askw while the page is on its Home');
  const live = await waitFor(`(${text('#ws-home [data-ws-card="room"]')}).includes(${JSON.stringify(words)})`, 4000);
  await sleep(800);
  const seen = await evaluate(`localStorage.getItem('doz.chat.seen:askw')`);
  check(seen === seenBefore && (last.seq === undefined || +seen < +last.seq), `home 8 …not marked seen (the marker ${seenBefore} → ${seen}, the message ${last.seq})` + (live ? '; the room card shows it at once' : ''));
  check(await waitFor(`state.chat.live !== 'live'`, 9000), 'home 8 …and Home holds no chat stream (closed 5 s after the room was left)');
  // 5. An agent blocked: Needs you names it.
  const run = spawnSync(DOZ, ['run', '@mac', '-d', '--unfenced', '--session', 'homeblk', '--store', STORE, '--', '/bin/sh', '-c',
    "printf '\\033]7501;?\\033\\\\'; sleep 1; printf '\\033]7501;state=blocked:app=fake\\033\\\\'; exec sleep 600"], { env: ENV, encoding: 'utf8', timeout: 120_000 });
  if (run.status === 0) {
    homeSessions.push('homeblk');
    doz(['workspace', 'new', 'homew', '--prompt-file', '-'], 'Wait on me.\n');
    doz(['workspace', 'adopt', 'homew', '@mac/homeblk']);
    await send('Page.reload');
    await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
    await goHash('#/mac/sandboxes');
    let blocked = false;
    for (let i = 0; i < 20 && !blocked; i++) {
      await goHash('#/w/homew/agents');
      await goHash('#/w/homew');
      blocked = await waitFor(`!!document.querySelector('#ws-home [data-ws-card="needs"] [data-ws-stuck="homeblk"]')`, 1500);
    }
    check(blocked && /is blocked/.test(await evaluate(text('#ws-home [data-ws-stuck="homeblk"]'))), 'home 5 an agent blocked: Needs you names it ("homeblk is blocked"), linking to Agents');
    await shot('ws-home-needs');
  } else {
    console.log('  note no session on this Mac could start here (deckhold-mac?) — home 5 skipped');
  }
  // 6. The Room tab: chat and the brief; Back and Forward between Home and Room keep the chat where it was.
  await goHash('#/w/demo2/room');
  check(await waitFor(`state.chat.room === 'demo2' && !!document.querySelector('#ws-room #chat-surface') && !!document.querySelector('#ws-brief [data-ws-brief="demo2"]')`, 15000),
    'home 6 #/w/demo2/room mounts the room and the brief');
  await evaluate(`window.__surf = document.getElementById('chat-surface'); window.__draft = 'a draft kept ' + Date.now(); document.getElementById('chat-text').value = window.__draft`);
  await goHash('#/w/demo2');
  await waitFor(`state.wsTab === 'home'`, 5000);
  await evaluate(`history.back()`);
  check(await waitFor(`location.hash === '#/w/demo2/room' && state.wsTab === 'room' && state.chat.room === 'demo2' && document.getElementById('chat-surface') === window.__surf
    && document.getElementById('chat-text').value === window.__draft && !document.getElementById('ws-room').closest('[hidden]')`, 10000), 'home 6 Back from Home: the same room, its surface and what was typed kept');
  await evaluate(`history.forward()`);
  check(await waitFor(`location.hash === '#/w/demo2' && state.wsTab === 'home' && !document.getElementById('ws-home').hidden`, 10000), 'home 6 …Forward: Home again');
  await evaluate(`document.getElementById('chat-text').value = ''`);
  // 7. spc2's Home: the hero drawn, a link to its space editor; on another tab it is off, and nothing reads.
  await goHash('#/w/spc2');
  check(await waitFor(`!!document.querySelector('#ws-home [data-ws-hero="spc2"]')?.dataset.picKey`, 20000), 'home 7 spc2\'s Home draws the workspace (data-pic-key)');
  check(await evaluate(`document.querySelector('[data-ws-hero="spc2"]').getAttribute('href') === '#/w/spc2/space'
    && !!document.querySelector('[data-ws-hero-band="spc2"] [data-ws-hero-open][href="#/w/spc2/space"]')`), 'home 7 …the drawing and "Edit the space" lead to its space editor');
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  await sleep(1200);
  await shot('ws-home-light');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await sleep(1200);
  const phone = await evaluate(`(() => { const cs = [...document.querySelectorAll('#ws-home .ws-card')].map((c) => Math.round(c.getBoundingClientRect().left));
    return { w: document.documentElement.scrollWidth, iw: innerWidth, lefts: [...new Set(cs)].length }; })()`);
  await shot('ws-home-390');
  check(phone.w <= phone.iw && phone.lefts === 1, `workspaces 4 at 390 px Home has no sideways scroll and one column of cards (${phone.w}/${phone.iw} px, ${phone.lefts} column)`);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await evaluate(`delete document.documentElement.dataset.theme`);
  await send('Emulation.setEmulatedMedia', { features: [] });
  await goHash('#/w/spc2/agents');
  await sleep(800);
  const r0 = requested.filter((u) => /\/api\/v1\/workspace-state$/.test(u)).length, t0 = Date.now();
  await sleep(3000);
  const evs = sseEvents.filter((e) => e.at >= t0 && ['changed', 'host', 'hello'].includes(e.name)).length;
  const reads = requested.filter((u) => /\/api\/v1\/workspace-state$/.test(u)).length - r0;
  check(await evaluate(`!document.body.classList.contains('ws-hero-on') && document.querySelector('[data-ws-hero="spc2"] svg') ? document.querySelector('[data-ws-hero="spc2"] svg').getAnimations({ subtree: true }).length === 0 : !document.body.classList.contains('ws-hero-on')`)
    && (evs > 0 || reads === 0), `home 7 on Agents the drawing is off (no ws-hero-on, no animation) and 3 s read no state (${reads} read(s), ${evs} event(s))`);
  check(pageErrors.length === errorsBefore, 'home: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
}

// ── the Workspaces page ────────────────────────────────────────────────────────────────────────────────────────────
const SHOW_F = { all: () => true, waiting: (w) => w.state === 'waiting-on-you', working: (w) => w.state === 'working' || w.state === 'starting',
  idle: (w) => w.state === 'idle', 'setting-up': (w) => w.state === 'setting-up', asleep: (w) => w.state === 'asleep', done: (w) => w.state === 'finished' || w.state === 'archived' };
const WSL = `[...document.querySelectorAll('[data-wsl]')].map((e) => e.dataset.wsl)`;
async function walkWorkspacesList() {
  const errorsBefore = pageErrors.length;
  // 1. The sidebar's Workspaces heading opens it; every workspace under Every; the counts are the listing's.
  await goHash('#/home');
  await waitFor(`state.view === 'home'`, 8000);
  await evaluate(`document.querySelector('#nav a[data-nav="workspaces"]').click()`);
  check(await waitFor(`location.hash === '#/workspaces' && state.view === 'workspaces' && !!document.querySelector('[data-workspaces] [data-wsl]')`, 15000)
    && await evaluate(`document.querySelector('#nav a[data-nav="workspaces"]').getAttribute('aria-current') === 'page'`), 'workspaces 1 the sidebar\'s Workspaces heading opens #/workspaces, marked');
  await evaluate(`document.querySelector('[data-wsl-layout="rows"]').click()`);
  await waitFor(`!!document.querySelector('[data-wsl-list="rows"]')`, 8000);
  const ls = (dozJSON(['workspace', 'ls']) || { workspaces: [] }).workspaces;
  const names = (await evaluate(WSL)).slice().sort();
  check(JSON.stringify(names) === JSON.stringify(ls.map((w) => w.name).sort()), `workspaces 1 Every workspace lists each one, finished and archived included (${names.length}: ${ls.filter(SHOW_F.done).length} done)`);
  const pageRows = await evaluate(`state.workspaces.workspaces`);
  const opts = await evaluate(`[...document.querySelectorAll('[data-wsl-show] option')].map((o) => [o.value, +((o.textContent.match(/[0-9]+(?=[)]$)/) || [])[0] ?? -1)])`);
  check(opts.length === 7 && opts.every(([v, n]) => n === pageRows.filter(SHOW_F[v]).length) && pageRows.length === ls.length,
    'workspaces 1 …each Show choice\'s count is the listing\'s ' + JSON.stringify(opts));
  // Show: one filter, then Every again on the next visit.
  await evaluate(`(() => { const s = document.querySelector('[data-wsl-show]'); s.value = 'asleep'; s.dispatchEvent(new Event('change')); })()`);
  check(await waitFor(`(${WSL}).every((n) => state.workspaces.workspaces.find((w) => w.name === n)?.state === 'asleep')`, 8000), 'workspaces 1 Show Asleep lists only asleep ones');
  await goHash('#/home');
  await goHash('#/workspaces');
  check(await waitFor(`document.querySelector('[data-wsl-show]')?.value === 'all'`, 8000), 'workspaces 1 …a new visit starts at Every workspace');
  // 2. Rows → Grid, kept across a reload; Sort by Name and by Last activity.
  const mark = requested.length;
  await evaluate(`document.querySelector('[data-wsl-layout="grid"]').click()`);
  check(await waitFor(`!!document.querySelector('[data-wsl-list="grid"]') && document.querySelector('[data-wsl-layout="grid"]').getAttribute('aria-pressed') === 'true'`, 8000), 'workspaces 2 Grid');
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf`, 30000);
  await goHash('#/mac/sandboxes');
  await goHash('#/workspaces');
  check(await waitFor(`!!document.querySelector('[data-wsl-list="grid"]')`, 15000), 'workspaces 2 …still Grid after a reload (kept in this browser)');
  await evaluate(`(() => { const s = document.querySelector('[data-wsl-sort]'); s.value = 'name'; s.dispatchEvent(new Event('change')); })()`);
  await sleep(500);
  const byName = await evaluate(WSL);
  check(JSON.stringify(byName) === JSON.stringify(byName.slice().sort((a, b) => a.localeCompare(b))) && byName.length === ls.length, 'workspaces 2 Sort by Name');
  await evaluate(`(() => { const s = document.querySelector('[data-wsl-sort]'); s.value = 'last'; s.dispatchEvent(new Event('change')); })()`);
  await sleep(500);
  const byLast = await evaluate(WSL);
  const rowsNow = await evaluate(`state.workspaces.workspaces`);
  const wantLast = rowsNow.slice().sort((a, b) => (Date.parse(b.lastAt) || 0) - (Date.parse(a.lastAt) || 0) || a.name.localeCompare(b.name)).map((w) => w.name);
  const cliLast = Object.fromEntries(ls.map((w) => [w.name, w.lastAt || null]));
  check(JSON.stringify(byLast) === JSON.stringify(wantLast) && rowsNow.filter((w) => w.lastAt && cliLast[w.name]).length >= ls.length - 1,
    'workspaces 2 Sort by Last activity: newest first, per each row\'s lastAt (doz workspace ls --json\'s)');
  await evaluate(`(() => { const s = document.querySelector('[data-wsl-sort]'); s.value = 'state'; s.dispatchEvent(new Event('change')); })()`);
  await sleep(500);
  // 3. Pictures only for space workspaces; a plain one a small tile here and on Home; the sidebar's box 0 px until drawn.
  await waitFor(`!!document.querySelector('[data-wsl="spc2"] img.sp-img:not([hidden])')`, 20000);
  const pics = await evaluate(`[...document.querySelectorAll('[data-wsl]')].map((e) => ({ name: e.dataset.wsl, img: !!e.querySelector('img.sp-img'),
    tile: [...e.querySelectorAll('[data-pic-tile]')].map((t) => Math.round(t.getBoundingClientRect().width)) }))`);
  const spaced = new Set(ls.filter((w) => w.space).map((w) => w.name));
  const off = pics.filter((p) => (spaced.has(p.name) ? !p.img : p.img || !p.tile.length || p.tile.some((x) => x > 40)));
  check(!off.length, `workspaces 3 an <img> only for each space workspace, a tile ≤ 40 px for each plain one (${pics.length}${off.length ? '; wrong: ' + JSON.stringify(off) : ''})`);
  // In the grid a plain card's band is thin: at most 30 % of a drawn one's.
  const bands = await evaluate(`(() => { const hs = (sel) => [...document.querySelectorAll('.wsl-grid ' + sel)].map((e) => e.getBoundingClientRect().height);
    return { drawn: hs('.wsl-pic:not(.is-plain)'), plain: hs('.wsl-pic.is-plain') }; })()`);
  check(bands.drawn.length > 0 && bands.plain.length > 0 && Math.max(...bands.plain) <= 0.3 * Math.min(...bands.drawn),
    `workspaces 3 a plain card's band is thin: ≤ 30 % of a drawn one's (${Math.round(Math.max(...bands.plain))} / ${Math.round(Math.min(...bands.drawn))} px)`);
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  await sleep(1200);
  await shot('workspaces-grid-light');
  await evaluate(`delete document.documentElement.dataset.theme`);
  await goHash('#/home');
  await waitFor(`state.view === 'home' && !!document.querySelector('tr[data-ws]')`, 10000);
  const homeTiles = await evaluate(`[...document.querySelectorAll('tr[data-ws] [data-pic-tile]')].map((t) => Math.round(t.getBoundingClientRect().width))`);
  check(homeTiles.length > 0 && homeTiles.every((x) => x <= 40), `workspaces 3 …Home's plain tiles are small too (${homeTiles.join(', ')} px)`);
  check(requested.slice(mark).filter((u) => RENDERER.test(u)).length === 1, `workspaces 3 the renderer fetched once since the reload (${requested.slice(mark).filter((u) => RENDERER.test(u)).length})`);
  // (spc2 is down now: it may sit under a folded group)
  for (const g of ['~asleep', '~done']) await evaluate(`(() => { const b = document.querySelector('[data-ws-group="${g}"]'); if (b && b.getAttribute('aria-expanded') !== 'true') b.click(); })()`);
  await waitFor(`!!document.querySelector('[data-ws-fold="spc2"]')`, 8000);
  await evaluate(`(() => { const c = document.querySelector('[data-ws-fold="spc2"]'); if (c && c.getAttribute('aria-expanded') !== 'true') c.click(); })()`);
  const navDrawn = await waitFor(`!!document.querySelector('[data-nav-ws="spc2"] .sp-thumb-nav[data-pic-key] img:not([hidden])')`, 15000);
  check(navDrawn, 'workspaces 3 the sidebar\'s box, 0 px tall until drawn, is still seen and drawn');
  const nav = !navDrawn ? { before: -1, drawn: 0 } : await evaluate(`(() => { const t = document.querySelector('[data-nav-ws="spc2"] .sp-thumb-nav'); const r = t.getBoundingClientRect(); const drawn = r.height / r.width;
    const k = t.dataset.picKey, img = t.querySelector('img'); delete t.dataset.picKey; img.hidden = true; const before = t.getBoundingClientRect().height;
    t.dataset.picKey = k; img.hidden = false; return { drawn: Math.round(drawn * 1000) / 1000, before }; })()`);
  check(nav.before === 0 && Math.abs(nav.drawn - 0.625) < 0.02, `workspaces 3 …the sidebar's box is 0 px before a picture, 16:10 after (${nav.before} px; ${nav.drawn})`);
  // 4. 390 px: both layouts, no sideways scroll; the grid one column.
  await goHash('#/workspaces');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await sleep(1200);
  const g390 = await evaluate(`({ w: document.documentElement.scrollWidth, iw: innerWidth, cols: new Set([...document.querySelectorAll('.wsl-card')].map((c) => Math.round(c.getBoundingClientRect().left))).size })`);
  await shot('workspaces-grid-390');
  await evaluate(`document.querySelector('[data-wsl-layout="rows"]').click()`);
  await waitFor(`!!document.querySelector('[data-wsl-list="rows"]')`, 8000);
  await sleep(1200);
  const r390 = await evaluate(`({ w: document.documentElement.scrollWidth, iw: innerWidth })`);
  await shot('workspaces-rows-390');
  check(g390.w <= g390.iw && g390.cols === 1 && r390.w <= r390.iw, `workspaces 4 at 390 px no sideways scroll, the grid one column (grid ${g390.w}/${g390.iw}, ${g390.cols} column; rows ${r390.w}/${r390.iw})`);
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await evaluate(`document.documentElement.dataset.theme = 'light'`);
  await sleep(1200);
  await shot('workspaces-rows-light');
  await evaluate(`delete document.documentElement.dataset.theme`);
  // 5. The keyboard: Tab from the toolbar reaches the first row's name, then its room, then its action; Space toggles the layout.
  await evaluate(`document.querySelector('[data-wsl-layout="grid"]').focus()`);
  const seq = [];
  for (let i = 0; i < 3; i++) {
    await key('Tab', 'Tab', 9);
    seq.push(await evaluate(`(() => { const a = document.activeElement, li = a.closest('[data-wsl]'); return { li: li ? li.dataset.wsl : null, first: li === document.querySelector('[data-wsl]'),
      cls: a.className, href: a.getAttribute('href') }; })()`));
  }
  const first = await evaluate(`document.querySelector('[data-wsl]').dataset.wsl`);
  check(seq.every((x) => x.first) && /wsl-name/.test(seq[0].cls) && seq[0].href === '#/w/' + first && (seq[1].href === '#/w/' + first + '/room' || /btn/.test(seq[1].cls)),
    'workspaces 5 Tab from the toolbar: the first row\'s name, then its room, then its action ' + JSON.stringify(seq));
  await evaluate(`document.querySelector('[data-wsl-layout="grid"]').focus()`);
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: ' ', code: 'Space', windowsVirtualKeyCode: 32, text: ' ' });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: ' ', code: 'Space', windowsVirtualKeyCode: 32 });
  check(await waitFor(`!!document.querySelector('[data-wsl-list="grid"]') && document.activeElement === document.querySelector('[data-wsl-layout="grid"]')`, 8000),
    'workspaces 5 Space on Grid toggles the layout, the focus kept on it');
  await evaluate(`document.querySelector('[data-wsl-layout="rows"]').click()`);
  // 6. No CSP violation; the first load's glue as before; the leak sweep.
  check((await evaluate('window.__violations.length')) === 0, 'workspaces 6 no CSP violation');
  check(pageErrors.length === errorsBefore, 'workspaces: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  await leakSweep('Home and the Workspaces page');
}

const wideSessions = [];
const WIDE_SENTINEL = 'FAKE-WIDE-SENTINEL-' + process.pid + '-9c3a';
async function walkWideViews() {
  const errorsBefore = pageErrors.length;
  const work = S + '/wide-work', src = S + '/wide-src', out = S + '/wide-outside';
  for (const d of [work, src, out]) mkdirSync(d, { recursive: true, mode: 0o700 });
  writeFileSync(src + '/token', WIDE_SENTINEL + '\n', { mode: 0o600 });
  writeFileSync(work + '/before.txt', 'old\n');
  spawnSync('touch', ['-t', '202001010000', work + '/before.txt']);
  writeFileSync(out + '/outside-new.txt', 'x\n');
  symlinkSync(out, work + '/out');
  knownTokens.push(WIDE_SENTINEL);
  const fenced = (s, extra) => spawnSync(DOZ, ['run', '@mac', '-d', '--fenced', '--session', s, '--folder', work, '--permissions', 'standard,site:api.wide.test', ...extra,
    '--store', STORE, '--', '/bin/sh', '-c', 'curl -s -m 5 -o /dev/null https://wideblocked.test/ ; exec sleep 600'], { env: ENV, encoding: 'utf8', timeout: 120_000 });
  let r = fenced('widef', ['--secret', 'WIDE_TOKEN,src=' + src + '/token,to=api.wide.test:443']);
  if (r.status === 0) wideSessions.push('widef');
  check(r.status === 0, 'wide: a fenced session with a launch secret (the sentinel) — ' + (r.stderr || '').trim().split('\n').pop());
  for (const n of ['widef2', 'widef3']) { r = fenced(n, []); if (r.status === 0) wideSessions.push(n); }
  r = spawnSync(DOZ, ['run', '@mac', '-d', '--unfenced', '--session', 'wideu', '--folder', work, '--store', STORE, '--', '/bin/sleep', '600'], { env: ENV, encoding: 'utf8', timeout: 120_000 });
  if (r.status === 0) wideSessions.push('wideu');
  doz(['workspace', 'new', 'wide', '--prompt-file', '-', '--folder', work, '--no-room', '--adopt', '@mac/widef', '--adopt', '@mac/widef2', '--adopt', '@mac/widef3', '--adopt', '@mac/wideu', '--adopt', 'gamma'],
    'See what it reaches.\n');
  await sleep(1100);
  writeFileSync(work + '/after.txt', 'new\n');
  // The two fenced sessions' refusals are in their proxies' logs once curl gave up.
  let refused = false;
  for (let i = 0; i < 40 && !refused; i++) {
    const rr = dozJSON(['workspace', 'show', 'wide', '--network']);
    refused = !!rr && rr.reach.agents.filter((a) => a.network.refused.some((x) => x.host === 'wideblocked.test')).length === 3;
    if (!refused) await sleep(300);
  }
  check(refused, 'wide: widef, widef2 and widef3 were each refused wideblocked.test (the daemon\'s proxies)');

  // 1. Network & secrets equals show --network --json.
  const cli = (dozJSON(['workspace', 'show', 'wide', '--network']) || { reach: { agents: [] } }).reach;
  await goHash('#/w/wide/network');
  check(await waitFor(`state.view === 'workspace' && !!document.querySelector('[data-ws-network="wide"]')`, 15000), 'wide 1 #/w/wide/network draws Network & secrets');
  const rows = await evaluate(`[...document.querySelectorAll('[data-wsn="permissions"] [data-net-agent]')].map((r) => r.dataset.netAgent)`);
  check(JSON.stringify(rows) === JSON.stringify([...cli.agents.map((a) => a.name), '~new']), `wide 1 one row per agent of show --network --json, then new workers (${rows})`);
  const held = await evaluate(`[...document.querySelectorAll('[data-held]')].map((r) => r.dataset.held)`);
  const cliHeld = cli.agents.flatMap((a) => a.held.map((x) => x.name + ' ' + a.name));
  check(JSON.stringify(held) === JSON.stringify(cliHeld) && held.includes('WIDE_TOKEN widef'), `wide 1 held for agents: by name, as the CLI's (${held})`);
  check(/fingerprint/i.test(await evaluate(text('[data-wsn="held"]'))) && (await evaluate(text('[data-wsn="held"]'))).includes(cli.agents.find((a) => a.name === 'widef').held[0].fingerprint),
    'wide 1 …with the fingerprint, never a value');
  check(/Nothing here shows a secret/.test(await evaluate(text('.wsn-foot'))), 'wide 1 the footer says no value is shown');
  check(await evaluate(`/not limited, not logged/.test(document.querySelector('[data-net-agent="wideu"]').textContent)`), 'wide 1 the unfenced agent: not limited, not logged');
  // 2. Allow for one agent (a fenced session: mac-net-policy), then listed.
  const defaultsBefore = JSON.stringify((dozJSON(['workspace', 'show', 'wide']) || {}).defaults);
  check(await waitFor(`!!document.querySelector('[data-allow-one="widef site:wideblocked.test"]:not([disabled])')`, 8000), 'wide 2 Allow for widef is offered');
  await evaluate(`document.querySelector('[data-allow-one="widef site:wideblocked.test"]').click()`);
  let sites = [];
  for (let i = 0; i < 40 && !sites.includes('wideblocked.test'); i++) { sites = (dozJSON(['net', 'show', '@mac', '--session', 'widef']) || {}).sites || []; if (!sites.includes('wideblocked.test')) await sleep(300); }
  check(sites.includes('wideblocked.test'), `wide 2 Allow for widef: doz net show @mac --session widef lists the site (${sites})`);
  check(await waitFor(`/wideblocked\.test/.test(document.querySelector('[data-net-agent="widef"]')?.textContent || '')`, 15000), 'wide 2 …and the page reads it again: listed in widef\'s row');
  // …and its Can do says custom too: one source for the preset (the permissions report), the page's and the CLI's.
  await goHash('#/w/wide/agent/widef/can-do');
  await waitFor(`!!document.querySelector('[data-cando-table="widef"] [data-cando="network"]')`, 15000);
  const canNet = await evaluate(text('[data-cando-table="widef"] [data-cando="network"]'));
  const cliNet = (((dozJSON(['workspace', 'show', 'wide', '--can-do', '--agent', 'widef']) || {}).reach || { agents: [{ capabilities: [] }] }).agents[0].capabilities
    .find((c) => c.id === 'network') || {}).state || '';
  check(/\(custom\)/.test(canNet) && /\(custom\)/.test(cliNet), `wide 2 …widef's Can do network row says custom, as Network & secrets does (page: ${canNet.slice(0, 80)}; CLI: ${cliNet})`);
  await goHash('#/w/wide/network');
  await waitFor(`!!document.querySelector('[data-net-agent="widef"]')`, 15000);
  check(/custom/.test(await evaluate(text('[data-net-agent="widef"]'))), 'wide 2 …and Network & secrets says custom for widef');
  // 3. For all: one operation per agent that can be limited and lacks it (widef2, gamma if proxied); unfenced not.
  await waitFor(`!!document.querySelector('[data-allow-all="site:wideblocked.test"]')`, 8000);
  const forAll = await evaluate(`(() => { const b = [...document.querySelectorAll('[data-allow-all="site:wideblocked.test"]')].find((x) => !x.disabled); return b ? Number(b.dataset.allowCount) : 0; })()`);
  const eligible = cli.agents.filter((a) => a.network.proxied && a.name !== 'widef').length;
  check(forAll === eligible && forAll >= 1, `wide 3 For all offers one change per agent that can be limited (${forAll}; ${eligible} proxied besides widef)`);
  const n0 = await evaluate(`(async () => (await (await fetch('/api/v1/operations', { credentials: 'same-origin' })).json()).filter((o) => /net-policy$/.test(o.action)).length)()`);
  await evaluate(`[...document.querySelectorAll('[data-allow-all="site:wideblocked.test"]')].find((x) => !x.disabled).click()`);
  let n1 = n0;
  for (let i = 0; i < 60 && n1 < n0 + forAll; i++) { n1 = await evaluate(`(async () => (await (await fetch('/api/v1/operations', { credentials: 'same-origin' })).json()).filter((o) => /net-policy$/.test(o.action)).length)()`); if (n1 < n0 + forAll) await sleep(300); }
  check(n1 - n0 === forAll, `wide 3 For all sent ${n1 - n0} operations, one per eligible agent`);
  let sites2 = [];
  for (let i = 0; i < 40 && !sites2.includes('wideblocked.test'); i++) { sites2 = (dozJSON(['net', 'show', '@mac', '--session', 'widef2']) || {}).sites || []; if (!sites2.includes('wideblocked.test')) await sleep(300); }
  check(sites2.includes('wideblocked.test'), 'wide 3 …widef2 has it too');
  check(JSON.stringify((dozJSON(['workspace', 'show', 'wide']) || {}).defaults) === defaultsBefore, 'wide 3 the new workers\' default unchanged (' + defaultsBefore + ')');
  // 4. Can do: an unfenced agent's "acts as you"; the later rows disabled; a fenced one's rows are the CLI's.
  await goHash('#/w/wide/agent/wideu/can-do');
  check(await waitFor(`state.view === 'wsagent' && !!document.querySelector('[data-cando-table="wideu"]')`, 15000), 'wide 4 #/w/wide/agent/wideu/can-do draws its Can do');
  check(await evaluate(`/acts as you/.test(document.querySelector('[data-cando="control"]').textContent) && !!document.querySelector('[data-cando="control"] .acts-as-you')`),
    'wide 4 an unfenced agent: the warning chip "acts as you"');
  // Its permissions and ceiling: live rows (not disabled, no "later"), read only (no control in the table but the command to
  // copy), the counts `doz permissions show W --agent A` prints.
  check(await evaluate(`['permissions', 'ceiling'].every((id) => { const r = document.querySelector('[data-cando="' + id + '"]'); return r && r.getAttribute('aria-disabled') !== 'true' && !r.classList.contains('is-later') && !/\\blater\\b/.test(r.textContent); })`),
    'wide 4 Permissions (allow · ask · never) and Ceiling are live rows, not "later"');
  const uCounts = ((dozJSON(['permissions', 'show', 'wide', '--agent', 'wideu']) || { agents: [{}] }).agents[0] || {}).rows || [];
  const tally = (a) => uCounts.filter((r) => r.answer === a).length;
  const wantCounts = `allow ${tally('allow')} · ask ${tally('ask')} · never ${tally('never')}`;
  const pageCounts = await evaluate(text('[data-cando-table="wideu"] [data-cando="permissions"] .cando-state'));
  check(uCounts.length > 0 && pageCounts === wantCounts, `wide 4 …its Permissions row says what doz permissions show says (${pageCounts} / ${wantCounts})`);
  check(await evaluate(`!document.querySelector('[data-cando-table] input, [data-cando-table] select, [data-cando-table] textarea, [data-cando-table] [contenteditable]') && [...document.querySelectorAll('[data-cando-table] button')].every((b) => b.closest('.cmd-copy'))`),
    'wide 4 …and nothing in the table edits (Edit comes with the permissions screens)');
  const canCli = ((dozJSON(['workspace', 'show', 'wide', '--can-do', '--agent', 'widef']) || { reach: { agents: [{ capabilities: [] }] } }).reach.agents[0].capabilities).map((c) => c.id);
  await goHash('#/w/wide/agent/widef/can-do');
  await waitFor(`!!document.querySelector('[data-cando-table="widef"]')`, 15000);
  const canPage = await evaluate(`[...document.querySelectorAll('[data-cando-table="widef"] [data-cando]')].map((r) => r.dataset.cando)`);
  check(JSON.stringify(canPage) === JSON.stringify(canCli) && canCli.slice(-2).join(' ') === 'permissions ceiling',
    `wide 4 widef's rows are show --can-do --json's, its permissions and ceiling last (${canPage.length})`);
  // 5. Folders & points: a changed file appears; Take only for a micro VM agent; the honest line.
  const fcli = (dozJSON(['workspace', 'show', 'wide', '--folders']) || { folders: { folders: [] } }).folders;
  await goHash('#/w/wide/folders');
  check(await waitFor(`!!document.querySelector('[data-ws-folders="wide"]')`, 15000), 'wide 5 #/w/wide/folders draws Folders & points');
  const changes = await evaluate(`[...document.querySelectorAll('[data-change]')].map((e) => e.dataset.change)`);
  const cliChanges = fcli.folders.flatMap((f) => f.changes.map((c) => c.path));
  check(changes.includes('after.txt') && !changes.includes('before.txt') && !changes.some((c) => c.startsWith('out')) && JSON.stringify(changes) === JSON.stringify(cliChanges),
    `wide 5 changed since the start: after.txt, not before.txt nor through the link — show --folders --json's (${changes})`);
  const nfolders = await evaluate(`document.querySelectorAll('[data-wsf-folder]').length`);
  check(nfolders === fcli.folders.length && nfolders === 1, `wide 5 one folder: the sessions' /tmp/… is the workspace's /private/tmp/… (${nfolders})`);
  const takes = await evaluate(`[...document.querySelectorAll('[data-take-point]')].map((b) => b.dataset.takePoint)`);
  check(JSON.stringify(takes) === JSON.stringify(['gamma']), `wide 5 Take a restore point offered only for the micro VM agent (${takes})`);
  check(/never which agent changed it/.test(await evaluate(text('[data-wsf-honest]'))), 'wide 5 the honest line: by folder, never which agent');
  // 6. Activity: the log in pages (Load older), this dashboard's operations for its agents, filtered.
  const logFile = STORE + '/workspaces/wide/log.jsonl';
  let filler = '';
  for (let i = 0; i < 230; i++) filler += JSON.stringify({ v: 1, at: new Date(Date.UTC(2026, 0, 1, 0, 0, i)).toISOString().replace(/\.\d{3}Z$/, 'Z'), by: 'you', action: 'refs-edited', added: 1 }) + '\n';
  const kept = readFileSync(logFile, 'utf8');
  writeFileSync(logFile, filler + kept, { mode: 0o600 });
  await goHash('#/w/wide/activity');
  check(await waitFor(`!!document.querySelector('[data-ws-activity="wide"] [data-wsc-older]')`, 15000), 'wide 6 Activity: a full page, with Load older');
  const before6 = await evaluate(`document.querySelectorAll('[data-wsc-kind="log"]').length`);
  await evaluate(`document.querySelector('[data-wsc-older]').click()`);
  check(await waitFor(`document.querySelectorAll('[data-wsc-kind="log"]').length > ${before6}`, 10000), `wide 6 Load older appends the page before (${before6} → ${await evaluate(`document.querySelectorAll('[data-wsc-kind="log"]').length`)})`);
  const small = await evaluate(`(async () => { const r = await fetch('/api/v1/workspace-activity', { method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-Doz-CSRF': state.csrf }, body: JSON.stringify({ workspace: 'wide', limit: 2 }) }); const a = await r.json();
    const r2 = await fetch('/api/v1/workspace-activity', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Doz-CSRF': state.csrf },
      body: JSON.stringify({ workspace: 'wide', limit: 2, before: a.first }) }); const b = await r2.json(); return { a: a.lines.length, more: a.more, b: b.lines.length, first: [a.first, b.first] }; })()`);
  const cliPage = dozJSON(['workspace', 'log', 'wide', '--limit', '2']) || {};
  check(small.a === 2 && small.more && small.b === 2 && small.first[0] === cliPage.first && small.first[1] < small.first[0],
    `wide 6 the route with a small limit pages as doz workspace log --limit 2 does (${JSON.stringify(small)}, CLI first ${cliPage.first})`);
  await evaluate(`document.querySelector('[data-wsc-filter="network"]').click()`);
  const net = await evaluate(`[...document.querySelectorAll('[data-wsc-kind]')].map((e) => e.dataset.wscKind + ':' + e.dataset.action)`);
  check(net.length >= 1 + forAll && net.every((x) => /^op:(mac-)?net-policy$/.test(x)), `wide 6 Network: the Allow operations for its agents only (${net.length})`);
  await evaluate(`document.querySelector('[data-wsc-filter="all"]').click()`);
  const foreign = await evaluate(`(async () => (await (await fetch('/api/v1/operations', { credentials: 'same-origin' })).json()).filter((o) => o.sandbox && !['gamma'].includes(o.sandbox)).map((o) => o.id))()`);
  check(await evaluate(`![...document.querySelectorAll('[data-wsc-kind="op"]')].some((e) => ${JSON.stringify(foreign)}.includes(e.dataset.id))`), 'wide 6 …no operation of another workspace\'s agent');
  // 7. Another computer: mac-net-policy 403 — ServeHTTPTests' (this dashboard has no LAN side).
  check(true, 'wide 7 another computer\'s 403 for mac-net-policy is ServeHTTPTests.testMacNetPolicyIsThisMacsBrowserOnlyWhateverTheServeSettings\'');
  // 8. At 390 px the tables are cards, no sideways scroll.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  for (const [hash, sel] of [['#/w/wide/network', '[data-wsn="permissions"] tr[data-net-agent]'], ['#/w/wide/agent/widef/can-do', '[data-cando-table] tr[data-cando]']]) {
    await goHash(hash);
    await waitFor(`!!document.querySelector(${JSON.stringify(sel)})`, 15000);
    await sleep(300);
    const c = await evaluate(`({ flex: getComputedStyle(document.querySelector(${JSON.stringify(sel)})).display === 'flex', w: document.documentElement.scrollWidth })`);
    await shot('wide-390-' + hash.split('/').pop());
    check(c.flex && c.w <= 390, `wide 8 at 390 px ${hash}: each row a card, no sideways scroll (${c.w} px)`);
  }
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  for (const t of ['network', 'folders', 'activity']) { await goHash('#/w/wide/' + t); await waitFor(`!!document.querySelector('[data-ws-${t}="wide"]')`, 15000); await shot('wide-' + t); }
  check(pageErrors.length === errorsBefore, 'wide: no page error' + (pageErrors.length > errorsBefore ? ': ' + pageErrors.slice(errorsBefore, errorsBefore + 3).join(' | ') : ''));
  await leakSweep('the wide views (the secret sentinel)');
}

let failed = false;
try {
  console.log('dashboard-walk: a scratch store at ' + S);
  stage();
  const { link, port } = await startUI();
  check(port > 1023 && !LIVE_PORTS.includes(port), 'doz ui is on a port the OS chose, not a live one');
  const origin = link.replace(/\/#.*/, '');
  await startChrome();
  await send('Page.navigate', { url: link });
  if (!(await waitFor(`!!document.querySelector('#nav') && typeof state === 'object' && !!state.csrf`, 30000))) throw new Error('the dashboard did not load');
  // An onboarding never done opens the setup over Home: close it (its own page is checked with the old addresses).
  await goHash('#/home');
  await waitFor(`state.view === 'home' && !state.modal && !!document.querySelector('[data-home]')`);
  if (process.env.CHAT_WINDOW_ONLY === '1') {
    // Only the chat window's rows (with the asks' set-up they use): chat on at OS-chosen ports.
    const [p1, p2] = [await freePort(), await freePort()];
    chatPagePort = p1;
    doz(['config', 'set', 'chat.page_port', String(p1)]);
    doz(['config', 'set', 'chat.line_port', String(p2)]);
    check(doz(['chat', 'on', '--name', 'ada']).status === 0, 'chat on (CHAT_WINDOW_ONLY)');
    await walkAsks();
    await walkChatWindow(origin);
    failed = failures.length > 0;
    console.log(`dashboard-walk (CHAT_WINDOW_ONLY): ${passed} passed, ${failures.length} failed` + (failed ? '\n  ' + failures.join('\n  ') : ''));
    throw Object.assign(new Error('chat window only'), { spaceOnly: true });
  }
  if (process.env.SPACE_ONLY === '1') {
    // Only the space editor's rows (a quicker loop while working on them): chat on at OS-chosen ports, then the rows.
    const [p1, p2] = [await freePort(), await freePort()];
    chatPagePort = p1;
    doz(['config', 'set', 'chat.page_port', String(p1)]);
    doz(['config', 'set', 'chat.line_port', String(p2)]);
    check(doz(['chat', 'on', '--name', 'ada']).status === 0, 'chat on (SPACE_ONLY)');
    await walkSpace();
    await walkSpaceWindow('spc3');
    failed = failures.length > 0;
    console.log(`dashboard-walk (SPACE_ONLY): ${passed} passed, ${failures.length} failed` + (failed ? '\n  ' + failures.join('\n  ') : ''));
    throw Object.assign(new Error('space only'), { spaceOnly: true });
  }

  // Home, before any workspace.
  await waitFor(`!!document.querySelector('[data-home-empty]')`, 10000);
  const empty = await evaluate(text('[data-home]'));
  check(empty.includes('A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects). Work starts only once it is fully set up.'),
    'Home with no workspace: the definition, word for word');
  check(/3 sandboxes and 0 sessions on this Mac are not in any workspace/.test(empty), 'Home with no workspace: the loose count (3 sandboxes)');
  check(await evaluate(`!!document.querySelector('[data-home-empty] a[href="#/mac/loose"]')`), 'Home with no workspace: Put them in workspaces… → Loose agents');

  // A workspace and a bot.
  doz(['workspace', 'new', 'demo', '--prompt-file', '-', '--adopt', 'alpha'], 'Walk the dashboard.\n');
  doz(['bot', 'new', 'mira', '--agent', 'claude-code']);
  // The page reads the workspaces again on the stream's hello (a reload) — the CLI's changes are no event of their own.
  await send('Page.reload');
  await waitFor(`typeof state === 'object' && !!state.csrf && state.view === 'home'`, 30000);
  await waitFor(`!!document.querySelector('[data-ws="demo"]')`, 20000);
  const pill = await evaluate(text('[data-ws="demo"] [data-ws-state]')), driver = await evaluate(text('[data-ws="demo"] .ws-driver'));
  check(pill === 'setting up' && driver === 'you', `Home's row for demo reads "setting up" and "you" (${pill} · ${driver})`);
  check(await evaluate(`!!document.querySelector('#home-needs') && document.querySelector('#home-needs').hidden`), 'Home: the Needs you slot is there, hidden');
  await walkFirstLoad();

  await walkSidebar();
  // demo unfolds to its agent, which links to its screen in the workspace.
  await waitFor(`!!document.querySelector('[data-nav-ws="demo"]')`, 10000);
  await evaluate(`(() => { const c = document.querySelector('[data-ws-fold="demo"]'); if (c && c.getAttribute('aria-expanded') !== 'true') c.click(); })()`);
  check(await waitFor(`!!document.querySelector('[data-nav-ws="demo"] a[data-ws-agent="alpha"][href="#/w/demo/agent/alpha"]')`, 8000),
    'the sidebar: demo unfolds to its agent alpha, linking to its screen in the workspace');

  await walkOldAddresses();
  await walkThisMac();
  await walkRemoveEnded();
  await walkLists();
  await walkMacs();
  await walkChatOn();
  await walkWorkspacePage();
  await walkAgents();
  await walkBots();
  await walkNewWorkspace();
  await walkAddWorker();
  await walkLifecycle();
  await walkRooms();
  await walkAsks();
  await walkChatWindow(origin);
  await walkWideViews();
  await walkPictures();
  await walkSpace();
  await walkSpaceWindow('spc3');
  await walkHome();
  await walkWorkspacesList();

  // Looking never starts the daemon: stop it, then open Home and Sandboxes.
  doz(['daemon', 'stop']);
  for (let i = 0; i < 100 && existsSync(STORE + '/daemon.pid'); i++) await sleep(100);
  check(!existsSync(STORE + '/daemon.pid'), 'the daemon is stopped');
  for (const h of ['#/mac/sandboxes', '#/home', '#/mac/loose', '#/bots', '#/bots/nova', '#/w/demo/agents', '#/w/demo2', '#/w/demo2/room']) { await goHash(h); await waitFor(SHOWN, 8000); }
  check(await waitFor(`state.view === 'workspace' && /Walk it again/.test(${text('[data-ws-brief="demo2"]')})`, 10000), 'with the daemon stopped, #/w/demo2 still reads (from the store)');
  // The wide views with the daemon stopped: each tab reads from the store, none starts it.
  for (const [h, sel] of [['#/w/wide/network', '[data-ws-network="wide"]'], ['#/w/wide/folders', '[data-ws-folders="wide"]'], ['#/w/wide/activity', '[data-ws-activity="wide"]'],
    ['#/w/wide/agent/widef/can-do', '[data-cando-table="widef"]']]) {
    await goHash(h);
    check(await waitFor(`!!document.querySelector(${JSON.stringify(sel)})`, 15000), `with the daemon stopped, ${h} reads`);
  }
  await goHash('#/w/wide/network');
  check(await waitFor(`/not known: no daemon is running/.test(document.querySelector('[data-ws-network="wide"]')?.textContent || '')`, 15000),
    'with the daemon stopped, Network & secrets says the refusals are not known');
  check(!existsSync(STORE + '/daemon.pid'), 'with the daemon stopped, the wide views start none');
  // 14. The wizard with the daemon stopped: it opens and the plan answers (chat judged from its setting).
  await goHash('#/new-workspace');
  check(await waitFor(`state.modal === 'new-workspace' && !!state.wsn?.plan && !state.wsn.planError`, 15000), 'wizard 14 with the daemon stopped, the wizard opens and the plan answers');
  await wizClose();
  // 10. Add a worker with the daemon stopped: the page opens, the plan answers, nothing starts.
  await goHash('#/w/demo2/agents/new');
  check(await waitFor(`state.view === 'addworker' && !!state.aw?.plan && !state.aw.planError`, 15000), 'add 10 with the daemon stopped, Add a worker opens and the plan answers');
  await awType('[data-aw-task]', 'List the files with no daemon.');
  check(await evaluate(`!state.aw.plan.problem && (state.aw.plan.notes || []).some((n) => /checked again when you add/.test(n))`), 'add 10 …saying what is checked again when you add');
  // 11. A lifecycle verb's plan with the daemon stopped: answered from the store.
  const p11 = await evaluate(`(async () => { const r = await fetch('/api/v1/workspace-lifecycle-plan', { method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-Doz-CSRF': state.csrf }, body: JSON.stringify({ workspace: 'demo2', verb: 'sleep' }) });
    return { status: r.status, body: await r.json() }; })()`);
  check(p11.status === 200 && p11.body.verb === 'sleep' && p11.body.factsKnown === false, `life 11 with the daemon stopped, the plan route answers (${p11.status})`);
  // Runs with the daemon stopped: the tab and the CLI answer from the store.
  await goHash('#/w/rmw/runs');
  check(await waitFor(`!!document.querySelector('[data-wr-run][data-wr-status="written"]')`, 15000), 'rooms 5 with the daemon stopped, the Runs tab reads');
  const stoppedRuns = dozJSON(['workspace', 'runs', 'rmw']);
  check(!!stoppedRuns && stoppedRuns.runs.length === 1 && !existsSync(STORE + '/daemon.pid'), 'rooms 5 …and doz workspace runs --json answers; neither starts the daemon');
  await sleep(4000);
  check(!existsSync(STORE + '/daemon.pid'), 'with the daemon stopped, opening Home, Sandboxes, Loose agents, Agents / Bots, a workspace\'s agents, its page and Add a worker starts none');
  check(await evaluate(`!!document.querySelector('[data-ws="demo"]')`) || (await goHash('#/home'), await waitFor(`!!document.querySelector('[data-ws="demo"]')`, 8000)),
    'Home still lists demo with no daemon (answered from the store)');

  check(pageErrors.length === 0, 'no page error' + (pageErrors.length ? ': ' + pageErrors.slice(0, 3).join(' | ') : ''));
  failed = failures.length > 0;
  console.log(`dashboard-walk: ${passed} passed, ${failures.length} failed` + (failed ? '\n  ' + failures.join('\n  ') : ''));
  console.log(failed ? 'dashboard-walk: FAILED' : 'dashboard-walk: ok');
} catch (e) {
  if (!e.spaceOnly) { console.log('dashboard-walk: FAILED — ' + (e.stack || e)); failed = true; }
} finally {
  try { chrome && chrome.kill('SIGKILL'); } catch (_) { /* gone */ }
  if (macSession) spawnSync(DOZ, ['sessions', 'end', '@mac', macSession, '--yes', '--store', STORE], { env: ENV, timeout: 60_000 });
  if (lifeSession) spawnSync(DOZ, ['sessions', 'end', '@mac', lifeSession, '--yes', '--store', STORE], { env: ENV, timeout: 60_000 });
  for (const s of wideSessions.concat(pictureSessions, homeSessions, spaceSessions)) spawnSync(DOZ, ['sessions', 'end', '@mac', s, '--yes', '--store', STORE], { env: ENV, timeout: 60_000 });
  for (const [w, n] of startedWorkers) spawnSync(DOZ, ['worker', 'end', w, n, '--store', STORE], { env: ENV, timeout: 60_000 });
  try { ui && process.kill(-ui.pid, 'SIGTERM'); } catch (_) { /* gone */ }
  if (uiB) spawnSync(DOZ, ['ui', 'stop', '--store', STORE_B], { env: ENV_B, timeout: 60_000 });
  spawnSync(DOZ, ['daemon', 'stop', '--store', STORE_B], { env: ENV_B, timeout: 60_000 });
  spawnSync(DOZ, ['daemon', 'stop', '--store', STORE], { env: ENV, timeout: 60_000 });
  await sleep(500);
  if (process.env.KEEP !== '1') { rmSync(S, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 }); clearMacSocketFolder(); }
}
process.exit(failed ? 1 : 0);
