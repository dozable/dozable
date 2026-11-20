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
//     drive — the brief is the kick-off). #/w/demo2 → view `workspace`, the brief open with its text; the tabs in the
//     mockups' order, Room and Agents enabled, "Permissions" from its constant; the kick-off bubble and a "started the work"
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
//   · with the daemon stopped, opening Home, Sandboxes, a workspace's page and its agents starts none (no daemon.pid).
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
// SHOTS=DIR (optional, under /tmp) keeps pictures of a workspace's page (light, dark, 390 px) for a person to look at.
// Run from the repository's root (make does).
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:net';
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
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
  DOZ_TEST_TRASH_DIR: S + '/bin-of-the-walk' };
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
let ws, nextId = 1, chrome, ui, devPort, uiB = false;
const pending = new Map(), pageErrors = [], requested = [];
const apiIds = new Set(), apiBodies = [], consoleLines = [];
let uiOut = '', chatPagePort = 0;
function send(method, params = {}) { const id = nextId++; ws.send(JSON.stringify({ id, method, params })); return new Promise((res, rej) => pending.set(id, { res, rej })); }
async function evaluate(expr) {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
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
  });
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Network.enable');
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
async function shot(name) {
  if (!SHOTS) return;
  mkdirSync(SHOTS, { recursive: true });
  const r = await send('Page.captureScreenshot', { format: 'png' });
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
async function walkWorkspacePage() {
  let p1 = await freePort(), p2 = await freePort();
  for (let i = 0; i < 5 && (LIVE_PORTS.includes(p1) || LIVE_PORTS.includes(p2) || p1 === p2); i++) { p1 = await freePort(); p2 = await freePort(); }
  check(p1 > 1023 && p2 > 1023 && p1 !== p2 && !LIVE_PORTS.includes(p1) && !LIVE_PORTS.includes(p2), 'chat\'s two ports are the OS\'s choice, not live ones');
  chatPagePort = p1;
  doz(['config', 'set', 'chat.page_port', String(p1)]);
  doz(['config', 'set', 'chat.line_port', String(p2)]);
  check(doz(['chat', 'on', '--name', 'ada']).status === 0, 'chat on (scratch store, OS-chosen ports)');
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

  await goHash('#/w/demo2');
  check(await waitFor(`state.view === 'workspace' && state.param === 'demo2' && ${SHOWN}`), '#/w/demo2 → the view workspace');
  check(await waitFor(`/Walk the workspace page/.test(${text('[data-ws-brief="demo2"] .ws-brief-text')}) && !document.querySelector('[data-ws-brief="demo2"]').classList.contains('is-folded')`, 15000),
    'the brief is open, with its text');
  check(await evaluate(`!!document.querySelector('[data-ws-brief="demo2"] .ws-brief-text strong')`), '…its Markdown drawn (bold)');
  check(await evaluate(`!!document.querySelector('[data-ws-brief="demo2"] a.ws-ref[href="https://example.com/spec"][rel="noopener noreferrer"]')`), '…its reference a safe link');
  const tabs = await evaluate(`[...document.querySelectorAll('#ws [data-ws-tab]')].map((t) => ({ label: t.firstChild.textContent, off: t.getAttribute('aria-disabled') === 'true', coming: !!t.querySelector('.ws-coming') }))`);
  check(JSON.stringify(tabs.map((t) => t.label)) === JSON.stringify(['Room', 'Agents', 'Permissions', 'Network & secrets', 'Folders & points', 'Activity', 'Runs', 'Settings']),
    'the tabs in the mockups\' order (' + tabs.map((t) => t.label).join(' · ') + ')');
  check(tabs.filter((t) => !t.off).map((t) => t.label).join() === 'Room,Agents,Network & secrets,Folders & points,Activity,Runs'
    && tabs.filter((t) => t.off).map((t) => t.label).join() === 'Permissions,Settings' && tabs.filter((t) => t.off).every((t) => t.coming),
    'Room, Agents, Network & secrets, Folders & points, Activity and Runs work; Permissions and Settings are marked coming');
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
  await goHash('#/w/demo2');
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
  await goHash('#/w/demo3');
  check(await waitFor(`state.param === 'demo3' && /acts as you/.test(${text('#ws-panel [data-ws-agent="otto"]')}) && !!document.querySelector('#ws-head .acts-as-you')`, 10000),
    'an unfenced manager shows "acts as you" (the panel and the title row)');

  // The sidebar and Home lead to the page.
  await goHash('#/home');
  // demo2 started with nothing running is asleep: Home folds it into "Asleep (N)" — unfolded here.
  await waitFor(`!!document.querySelector('[data-ws="demo2"]') || !!document.querySelector('[data-home-group="asleep"]')`, 10000);
  await evaluate(`(() => { const g = document.querySelector('[data-home-group="asleep"]'); if (g && g.getAttribute('aria-expanded') !== 'true') g.click(); })()`);
  await waitFor(`!!document.querySelector('[data-ws="demo2"]')`, 10000);
  check(await evaluate(`[...document.querySelectorAll('[data-ws="demo2"] a')].every((a) => a.getAttribute('href') === '#/w/demo2') && document.querySelectorAll('[data-ws="demo2"] a').length >= 2`),
    'Home: demo2\'s links (its name, its room, Open room) lead to #/w/demo2');
  await evaluate(`(() => { const g = document.querySelector('[data-ws-group="~asleep"]'); if (g && g.getAttribute('aria-expanded') !== 'true') g.click(); })()`);
  check(await waitFor(`document.querySelector('[data-ws-link="demo2"]')?.getAttribute('href') === '#/w/demo2'`, 8000), 'the sidebar: demo2 opens #/w/demo2');

  // The merge itself, against fixtures (the page's own function).
  const kinds = (args) => evaluate(`interleave(${args}).map((x) => x.kind).join()`);
  const ms = `[{ at: 10 }, { at: 20 }]`, ls = `[{ at: '1970-01-01T00:00:05Z' }, { at: '1970-01-01T00:00:10Z' }, { at: '1970-01-01T00:00:25Z' }]`;
  check(await kinds(`${ms}, ${ls}, false`) === 'line,msg,msg,line', 'interleave: only the span loaded, a line before a message of its time');
  check(await kinds(`${ms}, ${ls}, true`) === 'line,line,msg,msg,line', 'interleave: everything when nothing older is left');
  check(await kinds(`[], ${ls}, false`) === 'line,line,line', 'interleave: every line with no message');

  // A phone: the panel folds below the room.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await goHash('#/w/demo2');
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
  check(await waitFor(`[...document.querySelectorAll('#chat-log .chat-row')].some((r) => /Launch notes for the walk/.test(r.textContent))`, 20000)
    && await waitFor(`/started the work/.test(${text('#chat-log .chat-sys[data-action="kicked-off"]')})`, 10000), 'wizard 6 #/w/wiz1: the kick-off bubble and "started the work"');
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
  check(await waitFor(`document.querySelector('#chat-text').disabled && /Closed: its workspace life is finished/.test(document.querySelector('#chat-text').placeholder)`, 15000),
    'life 4 …the composer is off with the closed notice');
  check(doz(['chat', 'send', 'life', 'a post after the finish']).status !== 0, 'life 4 …a post is refused (closed)');
  await goHash('#/w/life/runs');
  check(await waitFor(`!!document.querySelector('[data-wr-run][data-wr-status="written"]')`, 15000), 'life 4 Runs lists the run, its archive written');
  check(await evaluate(`document.querySelector('[data-wr-room-state]')?.dataset.wrRoomState === 'closed'`), 'life 4 …its room reads closed');
  await goHash('#/w/life');
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

// ── a workspace's wide views: Network & secrets, Folders & points, Activity and an agent's Can do ────────────────────
/// `wide`: a fenced session (widef) with a launch secret whose value is a SENTINEL and two more (widef2, widef3), each having been
/// refused one site; an unfenced session (wideu); the never-booted sandbox gamma. All harmless programs, no VM.
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
  check(await evaluate(`['permissions', 'ceiling'].every((id) => { const r = document.querySelector('[data-cando="' + id + '"]'); return r && r.getAttribute('aria-disabled') === 'true' && /later/.test(r.textContent); })`),
    'wide 4 Permissions (allow · ask · never) and Ceiling drawn disabled, "later"');
  const canCli = ((dozJSON(['workspace', 'show', 'wide', '--can-do', '--agent', 'widef']) || { reach: { agents: [{ capabilities: [] }] } }).reach.agents[0].capabilities).map((c) => c.id);
  await goHash('#/w/wide/agent/widef/can-do');
  await waitFor(`!!document.querySelector('[data-cando-table="widef"]')`, 15000);
  const canPage = await evaluate(`[...document.querySelectorAll('[data-cando-table="widef"] [data-cando]')].map((r) => r.dataset.cando)`);
  check(JSON.stringify(canPage) === JSON.stringify([...canCli, 'permissions', 'ceiling']), `wide 4 widef's rows are show --can-do --json's, then the two later ones (${canPage.length})`);
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
  await walkWorkspacePage();
  await walkAgents();
  await walkBots();
  await walkNewWorkspace();
  await walkAddWorker();
  await walkLifecycle();
  await walkWideViews();

  // Looking never starts the daemon: stop it, then open Home and Sandboxes.
  doz(['daemon', 'stop']);
  for (let i = 0; i < 100 && existsSync(STORE + '/daemon.pid'); i++) await sleep(100);
  check(!existsSync(STORE + '/daemon.pid'), 'the daemon is stopped');
  for (const h of ['#/mac/sandboxes', '#/home', '#/mac/loose', '#/bots', '#/bots/nova', '#/w/demo/agents', '#/w/demo2']) { await goHash(h); await waitFor(SHOWN, 8000); }
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
  await sleep(4000);
  check(!existsSync(STORE + '/daemon.pid'), 'with the daemon stopped, opening Home, Sandboxes, Loose agents, Agents / Bots, a workspace\'s agents, its page and Add a worker starts none');
  check(await evaluate(`!!document.querySelector('[data-ws="demo"]')`) || (await goHash('#/home'), await waitFor(`!!document.querySelector('[data-ws="demo"]')`, 8000)),
    'Home still lists demo with no daemon (answered from the store)');

  check(pageErrors.length === 0, 'no page error' + (pageErrors.length ? ': ' + pageErrors.slice(0, 3).join(' | ') : ''));
  failed = failures.length > 0;
  console.log(`dashboard-walk: ${passed} passed, ${failures.length} failed` + (failed ? '\n  ' + failures.join('\n  ') : ''));
  console.log(failed ? 'dashboard-walk: FAILED' : 'dashboard-walk: ok');
} catch (e) {
  console.log('dashboard-walk: FAILED — ' + (e.stack || e));
  failed = true;
} finally {
  try { chrome && chrome.kill('SIGKILL'); } catch (_) { /* gone */ }
  if (macSession) spawnSync(DOZ, ['sessions', 'end', '@mac', macSession, '--yes', '--store', STORE], { env: ENV, timeout: 60_000 });
  if (lifeSession) spawnSync(DOZ, ['sessions', 'end', '@mac', lifeSession, '--yes', '--store', STORE], { env: ENV, timeout: 60_000 });
  for (const s of wideSessions) spawnSync(DOZ, ['sessions', 'end', '@mac', s, '--yes', '--store', STORE], { env: ENV, timeout: 60_000 });
  for (const [w, n] of startedWorkers) spawnSync(DOZ, ['worker', 'end', w, n, '--store', STORE], { env: ENV, timeout: 60_000 });
  try { ui && process.kill(-ui.pid, 'SIGTERM'); } catch (_) { /* gone */ }
  if (uiB) spawnSync(DOZ, ['ui', 'stop', '--store', STORE_B], { env: ENV_B, timeout: 60_000 });
  spawnSync(DOZ, ['daemon', 'stop', '--store', STORE_B], { env: ENV_B, timeout: 60_000 });
  spawnSync(DOZ, ['daemon', 'stop', '--store', STORE], { env: ENV, timeout: 60_000 });
  await sleep(500);
  if (process.env.KEEP !== '1') { rmSync(S, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 }); clearMacSocketFolder(); }
}
process.exit(failed ? 1 : 0);
