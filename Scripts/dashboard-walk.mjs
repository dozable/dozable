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
  for (const d of [STORE, XDG + '/doz', PROJECTS, S + '/codex-home', S + '/launch-agents', S + '/applications']) mkdirSync(d, { recursive: true });
  writeFileSync(XDG + '/doz/doz.toml', `[store]\npath = "${STORE}"\n\n[defaults]\nprojects_dir = "${PROJECTS}"\n\n[chat]\nenabled = false\n`);
  writeFileSync(S + '/no-gh', '#!/bin/sh\necho "not logged in" >&2\nexit 1\n', { mode: 0o755 });
  writeFileSync(S + '/gitconfig', '[user]\n\tname = dashboard-walk\n\temail = dashboard-walk@example.invalid\n');
  for (const n of SANDBOXES) doz(['create', n, '--image', 'lab', '--isolated']);
}

// ── Chrome over the DevTools protocol ────────────────────────────────────────────────────────────────────────────────
let ws, nextId = 1, chrome, ui, devPort, uiB = false;
const pending = new Map(), pageErrors = [], requested = [];
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
  ui.stdout.on('data', (d) => { out += d; });
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
  check(JSON.stringify(tabs.map((t) => t.label)) === JSON.stringify(['Room', 'Agents', 'Permissions', 'Network & secrets', 'Folders & points', 'Activity', 'Settings']),
    'the tabs in the mockups\' order (' + tabs.map((t) => t.label).join(' · ') + ')');
  check(tabs.filter((t) => !t.off).map((t) => t.label).join() === 'Room,Agents' && tabs.slice(2).every((t) => t.coming), 'Room and Agents work; the others are marked coming');
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
  await evaluate(`document.querySelector('[data-add-worker]').click()`);
  check(await evaluate(`/doz worker add demo2 --task/.test(document.querySelector('.wsa-add').textContent) && !document.querySelector('.wsa-add').hidden`), '"+ Add a worker" shows the command');
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
  await walkLists();
  await walkMacs();
  await walkWorkspacePage();
  await walkAgents();

  // Looking never starts the daemon: stop it, then open Home and Sandboxes.
  doz(['daemon', 'stop']);
  for (let i = 0; i < 100 && existsSync(STORE + '/daemon.pid'); i++) await sleep(100);
  check(!existsSync(STORE + '/daemon.pid'), 'the daemon is stopped');
  for (const h of ['#/mac/sandboxes', '#/home', '#/mac/loose', '#/bots', '#/w/demo/agents', '#/w/demo2']) { await goHash(h); await waitFor(SHOWN, 8000); }
  check(await waitFor(`state.view === 'workspace' && /Walk it again/.test(${text('[data-ws-brief="demo2"]')})`, 10000), 'with the daemon stopped, #/w/demo2 still reads (from the store)');
  await sleep(4000);
  check(!existsSync(STORE + '/daemon.pid'), 'with the daemon stopped, opening Home, Sandboxes, Loose agents, Agents / Bots, a workspace\'s agents and its page starts none');
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
  try { ui && process.kill(-ui.pid, 'SIGTERM'); } catch (_) { /* gone */ }
  if (uiB) spawnSync(DOZ, ['ui', 'stop', '--store', STORE_B], { env: ENV_B, timeout: 60_000 });
  spawnSync(DOZ, ['daemon', 'stop', '--store', STORE_B], { env: ENV_B, timeout: 60_000 });
  spawnSync(DOZ, ['daemon', 'stop', '--store', STORE], { env: ENV, timeout: 60_000 });
  await sleep(500);
  if (process.env.KEEP !== '1') { rmSync(S, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 }); clearMacSocketFolder(); }
}
process.exit(failed ? 1 : 0);
