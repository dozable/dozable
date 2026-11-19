// dashboard-walk.mjs — the dashboard's shell walked in a real headless Chrome (`make dashboard-walk`).
//
// Against `doz ui` on a SCRATCH store it checks what a machine can of the sidebar, Home, This Mac, Loose agents and
// Agents / Bots:
//   · Home with no workspace: the definition of a workspace, and how many sandboxes are in none;
//   · then `demo` (one sandbox adopted) and a bot: Home's row reads "setting up" and "you";
//   · the sidebar's parts in order — Home, Needs you (hidden), Chat (hidden: chat is off), Agents / Bots, Workspaces,
//     This Mac — and `demo` unfolding to its agent, which links to its sandbox;
//   · every old address lands on its canonical one and its view, with something on the page, no page error and no
//     "could not be read"; every link of This Mac opens its page;
//   · Loose agents and Agents / Bots list exactly what `doz workspace ls --loose --json` and `doz bot ls --json` do;
//   · with the daemon stopped, opening Home and Sandboxes starts none (no daemon.pid).
//
// Self-contained: Node >= 22 (global WebSocket and fetch), no packages. Never the person's own Dozable or browser: the
// store, the settings (XDG_CONFIG_HOME), the Chrome profile and the projects folder are under SCRATCH (default
// /tmp/doz-dashboard-walk); every seam css-perf sets keeps the run off this Mac's login, keychain and network; Chrome is
// headless on a scratch profile, its debugging port the OS's choice (Scripts/chrome-launch.mjs); `doz ui` takes a port
// the OS chooses, checked not to be one of the live ones; the sign-in link is read from its output and never printed;
// chat stays off and no VM starts. All of it is removed at the end (KEEP=1 keeps it).
//
// Inputs (environment): DOZ (default .build/debug/doz — `make cli` first), CHROME (default Google Chrome's app), SCRATCH.
// Run from the repository's root (make does).
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
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
  DOZ_TEST_LAUNCHCTL: '/usr/bin/false', DOZ_TEST_APPLICATIONS_DIR: S + '/applications', DOZ_PROGRESS: 'plain', NO_COLOR: '1' };
delete ENV.SSH_AUTH_SOCK;
function doz(args, input) {
  const r = spawnSync(DOZ, [...args, '--store', STORE], { env: ENV, encoding: 'utf8', input, timeout: 120_000 });
  if (r.status) console.log('  doz ' + args.join(' ') + ' → ' + r.status + ': ' + (r.stderr || '').trim().split('\n').pop());
  return r;
}
const dozJSON = (args) => JSON.parse(doz([...args, '--json']).stdout || 'null');

// ── the scratch store: three sandboxes (never started — no VM), chat off ─────────────────────────────────────────────
const SANDBOXES = ['alpha', 'beta', 'gamma'];
function stage() {
  rmSync(S, { recursive: true, force: true });
  for (const d of [STORE, XDG + '/doz', PROJECTS, S + '/codex-home', S + '/launch-agents', S + '/applications']) mkdirSync(d, { recursive: true });
  writeFileSync(XDG + '/doz/doz.toml', `[store]\npath = "${STORE}"\n\n[defaults]\nprojects_dir = "${PROJECTS}"\n\n[chat]\nenabled = false\n`);
  writeFileSync(S + '/no-gh', '#!/bin/sh\necho "not logged in" >&2\nexit 1\n', { mode: 0o755 });
  writeFileSync(S + '/gitconfig', '[user]\n\tname = dashboard-walk\n\temail = dashboard-walk@example.invalid\n');
  for (const n of SANDBOXES) doz(['create', n, '--image', 'lab', '--isolated']);
}

// ── Chrome over the DevTools protocol ────────────────────────────────────────────────────────────────────────────────
let ws, nextId = 1, chrome, ui;
const pending = new Map(), pageErrors = [];
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
  let page;
  for (let i = 0; i < 50 && !page; i++) { page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); if (!page) await sleep(200); }
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r, { once: true }));
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); return; }
    if (m.method === 'Runtime.exceptionThrown') pageErrors.push((m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text).split('\n')[0]);
  });
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
}
async function startUI() {
  // `doz ui` prints the sign-in link only to a terminal: run it on one (script(1)); the link is read here, never printed.
  ui = spawn('script', ['-q', '/dev/null', DOZ, 'ui', '--print-url', '--no-open', '--store', STORE], { env: ENV, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  let out = '';
  ui.stdout.on('data', (d) => { out += d; });
  for (let i = 0; i < 300; i++) { const m = /(http:\/\/127\.0\.0\.1:(\d+)\/#cap=[A-Za-z0-9_-]+)/.exec(out); if (m) return { link: m[1], port: Number(m[2]) }; await sleep(100); }
  throw new Error('no link from doz ui');
}

// ── the checks ───────────────────────────────────────────────────────────────────────────────────────────────────────
const failures = [];
let passed = 0;
function check(ok, what) { if (ok) { passed++; console.log('  ok   ' + what); } else { failures.push(what); console.log('  FAIL ' + what); } }
const text = (sel) => `(document.querySelector(${JSON.stringify(sel)})?.textContent || '')`;
/// The page shown: the view's own section has something in it, and no failure is said.
const SHOWN = `(() => { const v = state.view;
  const sec = v === 'sandbox' ? 'sbx' : v === 'sessions' ? 'grid' : v === 'mac' ? 'mac' : v === 'chat' ? 'chat' : 'view';
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
  // demo unfolds to its agent, which links to its sandbox.
  await waitFor(`!!document.querySelector('[data-nav-ws="demo"]')`, 10000);
  await evaluate(`(() => { const c = document.querySelector('[data-ws-fold="demo"]'); if (c && c.getAttribute('aria-expanded') !== 'true') c.click(); })()`);
  check(await waitFor(`!!document.querySelector('[data-nav-ws="demo"] a[data-ws-agent="alpha"][href="#/sandbox/alpha/~home"]')`, 8000),
    'the sidebar: demo unfolds to its agent alpha, linking to its sandbox');

  await walkOldAddresses();
  await walkThisMac();
  await walkLists();

  // Looking never starts the daemon: stop it, then open Home and Sandboxes.
  doz(['daemon', 'stop']);
  for (let i = 0; i < 100 && existsSync(STORE + '/daemon.pid'); i++) await sleep(100);
  check(!existsSync(STORE + '/daemon.pid'), 'the daemon is stopped');
  for (const h of ['#/mac/sandboxes', '#/home', '#/mac/loose', '#/bots']) { await goHash(h); await waitFor(SHOWN, 8000); }
  await sleep(4000);
  check(!existsSync(STORE + '/daemon.pid'), 'with the daemon stopped, opening Home, Sandboxes, Loose agents and Agents / Bots starts none');
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
  try { ui && process.kill(-ui.pid, 'SIGTERM'); } catch (_) { /* gone */ }
  spawnSync(DOZ, ['daemon', 'stop', '--store', STORE], { env: ENV, timeout: 60_000 });
  await sleep(500);
  if (process.env.KEEP !== '1') rmSync(S, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
}
process.exit(failed ? 1 : 0);
