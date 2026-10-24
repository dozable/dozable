// css-perf.mjs — what the dashboard's stylesheet costs the browser, measured the same way each time (`make css-perf`).
//
// A real headless Chrome against `doz ui` on a SCRATCH store walks a fixed path — All sandboxes → a sandbox's page →
// Accounts & keys → Settings → All sandboxes → the sandbox's page, each at 1100, 1440, 900 and 1440 px — RUNS times
// (default 5), recording Chrome's style-recalculation time (UpdateLayoutTree) and its CSS selector statistics (the
// Performance panel's "selector stats": time, match attempts and fast rejects per selector). The medians are compared
// with Tests/Fixtures/css-perf-baseline.json. It fails when:
//   · the recalculation time rises more than 10 % over the baseline (the check stops regressions; it promises no speed);
//   · any selector of app.css takes more than 1 ms of matching over the walk;
//   · any selector of app.css tried at least 100 times costs more than 2 µs per attempt.
// (The browser's own stylesheet is in the statistics too, and so is the one universal rule css-lint allows — the
// box-sizing reset `*`: both are reported, neither is ours to fail on.)
// It prints the 20 costliest selectors. `--write-baseline` records this build's medians as the baseline (after a change
// that is meant to move them — say so in the commit).
//
// Self-contained: Node >= 22 (global WebSocket and fetch), no packages. Never the person's own Dozable or browser: the
// store, the settings (XDG_CONFIG_HOME), the Chrome profile and the projects folder are under SCRATCH (default
// /tmp/doz-css-perf), every seam that keeps a run off this Mac's login, keychain and network is set, and all of it is
// removed at the end (KEEP=1 keeps it).
//
// Inputs (environment): DOZ (default .build/debug/doz — `make cli` first), CHROME (default Google Chrome's app),
// SCRATCH, RUNS, BASELINE (default Tests/Fixtures/css-perf-baseline.json), SHEET (default
// Sources/DozableWeb/WebSource/app.css), OUT (a JSON report, optional). Run from the repository's root (make does).
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const DOZ = resolve(process.env.DOZ || '.build/debug/doz');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const S = process.env.SCRATCH || '/tmp/doz-css-perf';
const RUNS = Number(process.env.RUNS || 5);
const BASELINE = resolve(process.env.BASELINE || 'Tests/Fixtures/css-perf-baseline.json');
const SHEET = resolve(process.env.SHEET || 'Sources/DozableWeb/WebSource/app.css');   // the sheet the limits apply to
const WRITE = process.argv.includes('--write-baseline');
const LIMITS = { recalcRise: 0.10, selectorMs: 1, perAttemptUs: 2, minAttempts: 100 };
if (!S.startsWith('/tmp/')) { console.error('css-perf: SCRATCH must be under /tmp'); process.exit(64); }
if (!existsSync(DOZ)) { console.error('css-perf: no doz at ' + DOZ + ' (make cli)'); process.exit(66); }
if (!existsSync(CHROME)) { console.error('css-perf: no Chrome at ' + CHROME + ' (set CHROME)'); process.exit(66); }

const STORE = S + '/store', XDG = S + '/xdg', PROFILE = S + '/chrome', PROJECTS = S + '/projects';
const ENV = { ...process.env, XDG_CONFIG_HOME: XDG, DOZ_STORE: STORE, DO_NOT_TRACK: '1', DOZ_TEST_GUARD: '1', DOZ_TEST_NO_MAC_LOGIN: '1',
  DOZ_TEST_CREDENTIALS: 'memory', DOZ_TEST_CODEX_HOME: S + '/codex-home', DOZ_TEST_BROWSER_LOG: S + '/browser.log', DOZ_TEST_PASTEBOARD: S + '/pasteboard',
  DOZ_TEST_OPEN_URL: S + '/open-url', DOZ_TEST_FOLDER_PICKER: 'cancel', DOZ_TEST_FILE_PICKER: 'cancel', DOZ_TEST_MODEL_LIST: 'offline',
  DOZ_TEST_NPM_REGISTRY: 'offline', DOZ_TEST_BASE_REGISTRY: 'pinned', DOZ_TEST_CLAUDE_DOWNLOADS: 'offline', DOZ_TEST_GH: S + '/no-gh',
  DOZ_TEST_SSH_AUTH_SOCK: S + '/no-agent.sock', DOZ_TEST_CONTAINER: '/nonexistent/container', GIT_CONFIG_GLOBAL: S + '/gitconfig',
  DOZ_TEST_HOME: '/tmp/doz-css-perf-home', DOZ_PROGRESS: 'plain', NO_COLOR: '1' };
delete ENV.SSH_AUTH_SOCK;
function doz(args, input) {
  const r = spawnSync(DOZ, [...args, '--store', STORE], { env: ENV, encoding: 'utf8', input, timeout: 120_000 });
  if (r.status) console.log('  doz ' + args.join(' ') + ' → ' + r.status + ': ' + (r.stderr || '').trim().split('\n').pop());
  return r;
}

// ── the scratch store: sandboxes of three agents (none started — no VM), a key, the settings ────────────────────────
const SBX = 'web-app';
function stage() {
  rmSync(S, { recursive: true, force: true });
  for (const d of [STORE, XDG + '/doz', PROJECTS, S + '/codex-home']) mkdirSync(d, { recursive: true });
  writeFileSync(XDG + '/doz/doz.toml', `[store]\npath = "${STORE}"\n\n[defaults]\nprojects_dir = "${PROJECTS}"\n`);
  writeFileSync(S + '/no-gh', '#!/bin/sh\necho "not logged in" >&2\nexit 1\n', { mode: 0o755 });
  writeFileSync(S + '/gitconfig', '[user]\n\tname = css-perf\n\temail = css-perf@example.invalid\n');
  doz(['create', SBX, '--image', 'claude-code', '--network', 'nat', '--workspace', PROJECTS + '/' + SBX]);
  doz(['create', 'notes', '--image', 'pi', '--network', 'nat', '--workspace', PROJECTS + '/notes']);
  doz(['create', 'scratch', '--image', 'lab', '--isolated']);
  doz(['create', 'docs-site', '--image', 'claude-code', '--workspace', PROJECTS + '/docs-site']);
  doz(['account', 'add', 'work', '--api-key', '--no-verify', '--force'], 'sk-ant-api03-' + 'x'.repeat(80) + '\n');
}

// ── Chrome over the DevTools protocol ────────────────────────────────────────────────────────────────────────────────
let ws, nextId = 1, chrome, ui, traceDone = null;
const pending = new Map(), traceEvents = [], pageErrors = [];
function send(method, params = {}) { const id = nextId++; ws.send(JSON.stringify({ id, method, params })); return new Promise((res, rej) => pending.set(id, { res, rej })); }
async function evaluate(expr) {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
  return r.result.value;
}
const soft = async (expr) => { try { return await evaluate(expr); } catch (_) { return null; } };
async function waitFor(expr, ms = 25000) { const end = Date.now() + ms; while (Date.now() < end) { if (await soft(expr)) return true; await sleep(150); } return false; }
async function startChrome() {
  rmSync(PROFILE, { recursive: true, force: true });
  mkdirSync(PROFILE, { recursive: true });
  chrome = spawn(CHROME, ['--headless=new', `--user-data-dir=${PROFILE}`, '--no-first-run', '--no-default-browser-check', '--disable-component-update',
    '--disable-background-networking', '--disable-renderer-backgrounding', '--remote-debugging-port=0', '--hide-scrollbars', '--window-size=1440,900',
    'about:blank'], { stdio: 'ignore' });
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
    if (m.method === 'Tracing.dataCollected') traceEvents.push(...m.params.value);
    if (m.method === 'Tracing.tracingComplete' && traceDone) traceDone();
  });
  await send('Runtime.enable');
  await send('Page.enable');
  await viewport(1440);
}
async function viewport(w) { await send('Emulation.setDeviceMetricsOverride', { width: w, height: 900, deviceScaleFactor: 1, mobile: false }); await sleep(400); }
async function startUI() {
  // `doz ui` prints the sign-in link only to a terminal: run it on one (script(1)); the link is read here, never printed.
  ui = spawn('script', ['-q', '/dev/null', DOZ, 'ui', '--print-url', '--no-open', '--store', STORE], { env: ENV, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  let out = '';
  ui.stdout.on('data', (d) => { out += d; });
  for (let i = 0; i < 300; i++) { const m = /(http:\/\/127\.0\.0\.1:\d+\/#cap=[A-Za-z0-9_-]+)/.exec(out); if (m) return m[1]; await sleep(100); }
  throw new Error('no link from doz ui');
}
async function go(origin, hash) {
  await send('Page.navigate', { url: origin + '/' + hash });
  await waitFor(`!!document.querySelector('#view h1, #sbx:not([hidden]) h1')`);
  await sleep(800);
}

// ── one walk under a trace: the recalculations and the selector statistics ──────────────────────────────────────────
const WALK = ['#/overview', '#/sandbox/' + SBX, '#/accounts', '#/settings', '#/overview', '#/sandbox/' + SBX];
async function measuredWalk(origin) {
  traceEvents.length = 0;
  await send('Tracing.start', { transferMode: 'ReportEvents',
    traceConfig: { includedCategories: ['devtools.timeline', 'disabled-by-default-blink.debug'], recordMode: 'recordAsMuchAsPossible' } });
  for (const hash of WALK) {
    await go(origin, hash);
    for (const w of [1100, 1440, 900, 1440]) await viewport(w);
  }
  const done = new Promise((r) => { traceDone = r; });
  await send('Tracing.end');
  await done;
  const per = new Map();
  let recalcs = 0, recalcUs = 0;
  for (const e of traceEvents) {
    if (e.name === 'UpdateLayoutTree' && e.ph === 'X') { recalcs++; recalcUs += e.dur || 0; }
    const st = e.args?.selector_stats?.selector_timings;
    if (!st) continue;
    for (const s of st) {
      const o = per.get(s.selector) || { elapsedUs: 0, attempts: 0, matches: 0, fastRejects: 0 };
      o.elapsedUs += s['elapsed (us)'] || 0; o.attempts += s.match_attempts || 0; o.matches += s.match_count || 0; o.fastRejects += s.fast_reject_count || 0;
      per.set(s.selector, o);
    }
  }
  const selectorUs = [...per.values()].reduce((t, r) => t + r.elapsedUs, 0);
  return { recalcs, recalcMs: recalcUs / 1000, selectorMs: selectorUs / 1000, per };
}
const median = (xs) => { const a = [...xs].sort((x, y) => x - y); const n = a.length; return n ? (n % 2 ? a[(n - 1) / 2] : (a[n / 2 - 1] + a[n / 2]) / 2) : 0; };
const r2 = (x) => Math.round(x * 100) / 100;

let failed = false;
try {
  console.log('css-perf: a scratch store at ' + S);
  stage();
  const link = await startUI();
  const origin = link.replace(/\/#.*/, '');
  await startChrome();
  await send('Page.navigate', { url: link });
  if (!(await waitFor(`!!document.querySelector('#nav') && !!document.querySelector('#view h1')`, 30000))) throw new Error('the dashboard did not load');
  await sleep(1500);
  await measuredWalk(origin);              // a warm-up walk: caches, fonts, the icon sprite — not counted
  const runs = [];
  for (let i = 0; i < RUNS; i++) {
    const r = await measuredWalk(origin);
    runs.push(r);
    console.log(`  walk ${i + 1}/${RUNS}: ${r.recalcs} recalculations, ${r2(r.recalcMs)} ms; selector matching ${r2(r.selectorMs)} ms`);
  }
  const selectors = new Set(runs.flatMap((r) => [...r.per.keys()]));
  const rows = [...selectors].map((sel) => {
    const xs = runs.map((r) => r.per.get(sel) || { elapsedUs: 0, attempts: 0, matches: 0, fastRejects: 0 });
    const elapsedUs = median(xs.map((x) => x.elapsedUs)), attempts = median(xs.map((x) => x.attempts));
    return { selector: sel, elapsedUs: r2(elapsedUs), attempts, matches: median(xs.map((x) => x.matches)), fastRejects: median(xs.map((x) => x.fastRejects)),
             usPerAttempt: attempts ? r2(elapsedUs / attempts * 1000) / 1000 : 0 };
  }).sort((a, b) => b.elapsedUs - a.elapsedUs);
  const result = { recalcs: median(runs.map((r) => r.recalcs)), recalcMs: r2(median(runs.map((r) => r.recalcMs))),
    selectorMs: r2(median(runs.map((r) => r.selectorMs))), selectors: rows.length, runs: RUNS, chrome: (await send('Browser.getVersion')).product };
  console.log(`css-perf: median of ${RUNS} walks — ${result.recalcs} recalculations, ${result.recalcMs} ms recalculating, ${result.selectorMs} ms matching ${result.selectors} selectors`);
  console.log('  the 20 costliest selectors (median over the walks):');
  for (const r of rows.slice(0, 20)) console.log(`    ${String(r.elapsedUs).padStart(8)} µs  ${String(r.attempts).padStart(7)} tries  ${r.usPerAttempt.toFixed(3)} µs/try  ${r.selector}`);
  // The limits are the dashboard's sheet's: the browser's own stylesheet shows in the statistics too (`:not(svg)`, `div` …)
  // and is not ours to change; nor is the one universal rule css-lint allows (the box-sizing reset, `*`).
  const ownSelectors = new Set();
  for (const m of readFileSync(SHEET, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{/g)) {
    let depth = 0, cur = '';
    for (const c of m[1]) {
      if (c === '(' || c === '[') depth++; else if (c === ')' || c === ']') depth--;
      if (c === ',' && depth === 0) { ownSelectors.add(cur.replace(/\s+/g, ' ').trim()); cur = ''; } else cur += c;
    }
    ownSelectors.add(cur.replace(/\s+/g, ' ').trim());
  }
  const ours = (sel) => sel !== '*' && ownSelectors.has(sel.replace(/\s+/g, ' ').trim());
  const over = [];
  for (const r of rows) {
    if (!ours(r.selector)) continue;
    if (r.elapsedUs / 1000 > LIMITS.selectorMs) over.push(`${r.selector}: ${r2(r.elapsedUs / 1000)} ms of matching (limit ${LIMITS.selectorMs} ms)`);
    if (r.attempts >= LIMITS.minAttempts && r.usPerAttempt > LIMITS.perAttemptUs) over.push(`${r.selector}: ${r.usPerAttempt} µs per attempt (limit ${LIMITS.perAttemptUs} µs)`);
  }
  const mine = rows.filter((r) => ours(r.selector));
  result.ownSelectorMs = r2(mine.reduce((t, r) => t + r.elapsedUs, 0) / 1000);
  console.log(`  of which the dashboard's own sheet (less the * reset): ${result.ownSelectorMs} ms over ${mine.length} selectors; its costliest: ` +
    (mine[0] ? `${mine[0].selector} ${mine[0].elapsedUs} µs` : '—'));
  if (process.env.OUT) writeFileSync(process.env.OUT, JSON.stringify({ ...result, top: rows.slice(0, 40) }, null, 1));
  if (WRITE) {
    writeFileSync(BASELINE, JSON.stringify({ note: 'make css-perf --write-baseline: the median of the walks on this build; compared by make css-perf',
      recorded: new Date().toISOString().slice(0, 10), ...result, top: rows.slice(0, 20) }, null, 1) + '\n');
    console.log('css-perf: baseline written to ' + BASELINE);
  } else {
    if (!existsSync(BASELINE)) throw new Error('no baseline at ' + BASELINE + ' (make css-perf ARGS=--write-baseline)');
    const base = JSON.parse(readFileSync(BASELINE, 'utf8'));
    const rise = (result.recalcMs - base.recalcMs) / base.recalcMs;
    console.log(`css-perf: recalculation ${result.recalcMs} ms against the baseline's ${base.recalcMs} ms (${rise >= 0 ? '+' : ''}${r2(rise * 100)} %); ` +
      `matching ${result.selectorMs} ms against ${base.selectorMs} ms`);
    if (rise > LIMITS.recalcRise) over.push(`recalculation rose ${r2(rise * 100)} % over the baseline (limit ${LIMITS.recalcRise * 100} %)`);
  }
  if (pageErrors.length) over.push('the page threw: ' + pageErrors.slice(0, 3).join(' | '));
  for (const o of over) console.log('  FAIL ' + o);
  failed = over.length > 0;
  console.log(failed ? 'css-perf: FAILED' : 'css-perf: ok');
} catch (e) {
  console.log('css-perf: FAILED — ' + (e.stack || e));
  failed = true;
} finally {
  try { chrome && chrome.kill('SIGKILL'); } catch (_) { /* gone */ }
  try { ui && process.kill(-ui.pid, 'SIGTERM'); } catch (_) { /* gone */ }
  spawnSync(DOZ, ['host', 'stop', '--store', STORE], { env: ENV, timeout: 60_000 });
  await sleep(500);
  if (process.env.KEEP !== '1') rmSync(S, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
}
process.exit(failed ? 1 : 0);
