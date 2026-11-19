// chat-markdown-check — chat's Markdown renderer (WebSource/app/core/chat-markdown.js) in a real browser, over the corpus
// Tests/Fixtures/chat-markdown-cases.json ({name, in, members, why?}); each case's DOM, serialised, must equal
// Tests/Fixtures/chat-markdown-expected.json. `--update` writes the expectations instead (review every changed line).
// A case with `message` (and optionally `srv`) renders a whole message as the log does (views/chat-messages.js `add`):
// its reactions (their labels and who), the edited mark, attachments and their names, a direct message's stub with
// Reveal, the reactions picker's menu (from `srv.reactions`) — and, when it has a picture, the gallery over it. Chrome
// runs with TZ=UTC and en-US, so the times in them are the same on every Mac.
//
// Self-contained: Node >= 22, no packages. It serves Sources/DozableWeb/WebSource on 127.0.0.1 (a port the OS picks) to a
// headless Chrome with a scratch profile, started ONLY through Scripts/chrome-launch.mjs (spawnChrome). Not part of
// `make test` (no browser there): `make chat-markdown-check`.
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { spawnChrome } from './chrome-launch.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const WEB = join(ROOT, 'Sources/DozableWeb/WebSource');
const CASES = join(ROOT, 'Tests/Fixtures/chat-markdown-cases.json');
const EXPECTED = join(ROOT, 'Tests/Fixtures/chat-markdown-expected.json');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const S = process.env.SCRATCH || '/tmp/doz-chat-md';
const update = process.argv.includes('--update');
if (!S.startsWith('/tmp/')) { console.error('chat-markdown-check: SCRATCH must be under /tmp'); process.exit(64); }
if (!existsSync(CHROME)) { console.error('chat-markdown-check: no Chrome at ' + CHROME + ' (set CHROME)'); process.exit(66); }

const TYPES = { '.js': 'text/javascript', '.html': 'text/html', '.css': 'text/css' };
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path === '/h.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end('<!doctype html><title>h</title>'); return; }
  const f = normalize(join(WEB, path));
  if (!f.startsWith(WEB + '/') || !existsSync(f)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': TYPES[extname(f)] || 'application/octet-stream' });
  res.end(readFileSync(f));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = 'http://127.0.0.1:' + server.address().port;

const PROFILE = S + '/chrome';
rmSync(PROFILE, { recursive: true, force: true });
mkdirSync(PROFILE, { recursive: true });
const chrome = spawnChrome(CHROME, ['--headless=new', `--user-data-dir=${PROFILE}`, '--no-first-run', '--no-default-browser-check',
  '--disable-component-update', '--disable-background-networking', '--remote-debugging-port=0', '--lang=en-US', 'about:blank'],
  { stdio: 'ignore', env: { ...process.env, TZ: 'UTC', LANG: 'en_US.UTF-8' } }, S + '/bin');
let code = 1;
try {
  const f = PROFILE + '/DevToolsActivePort';
  for (let i = 0; i < 150 && !existsSync(f); i++) await sleep(100);
  const port = readFileSync(f, 'utf8').split('\n')[0];
  let page;
  for (let i = 0; i < 50 && !page; i++) { page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); if (!page) await sleep(200); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r, { once: true }));
  let id = 0;
  const pend = new Map();
  ws.addEventListener('message', (m) => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.navigate', { url: base + '/h.html' });
  await sleep(400);
  const cases = JSON.parse(readFileSync(CASES, 'utf8'));
  const expr = `(async () => {
    const md = await import('/app/core/chat-markdown.js');
    const st = await import('/app/core/state.js');
    const api = await import('/app/core/chat-api.js');
    api.configure({ title: 'Chat', request: () => { throw new Error('no requests here'); }, viewer: () => 'ada', fileUrl: api.dashboardFileUrl,
      canWrite: () => true });
    const views = await import('/app/views/chat-messages.js');
    const gal = await import('/app/components/chat-gallery.js');
    const log = document.createElement('div');
    log.id = 'chat-log';
    const down = document.createElement('button');
    down.id = 'chat-down';
    document.body.append(log, down);
    const out = {};
    for (const c of ${JSON.stringify(cases)}) {
      st.state.chat.members = new Set(c.members);
      if (c.message) {
        Object.assign(st.state.chat, { byId: new Map(), room: 'room1', presence: [], bulk: 1, atFoot: true,
          srv: c.srv || { rooms: { room1: c.members }, archived: [], reactions: [] } });
        log.replaceChildren();
        views.add(c.message);
        let html = log.innerHTML;
        const pick = log.querySelector('.chat-pick .menu');
        if (pick) html += '\\n' + pick.outerHTML;
        const im = log.querySelector('img.chat-att');
        if (im) {
          gal.showGallery(im);
          const g = document.querySelector('.chat-gal');
          html += '\\n' + g.outerHTML;
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        }
        out[c.name] = html;
        continue;
      }
      const box = document.createElement('div');
      box.append(md.renderMarkdown(c.in));
      out[c.name] = box.innerHTML;
    }
    return out;
  })()`;
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) { console.error('the page threw:', JSON.stringify(r.result.exceptionDetails).slice(0, 600)); throw new Error('threw'); }
  const got = r.result.result.value;
  // what a case may never produce, whatever the expectation says
  // (a value inside quotes is the attribute's text — an aria-label may SAY "onerror=" — so a handler is looked for in the tag
  // with its values emptied; an address is looked for in href and src themselves)
  const forbiddenTag = /<script|<iframe|<svg|\son[a-z]+=/i;
  const forbiddenUrl = /\s(href|src)="(javascript:|data:|http:\/\/127\.|http:\/\/localhost|mailto:)|\ssrc="http/i;
  const forbidden = { test: (t) => forbiddenTag.test(t.replace(/="[^"]*"/g, '=""')) || forbiddenUrl.test(t) };
  let unsafe = 0;
  for (const c of cases) {
    const html = got[c.name];
    // our own drawing is allowed: an icon of the sprite and an avatar's shape (every value in them is ours)
    const tags = (html.match(/<[a-z][^>]*>/gi) || []).filter((t) => !/^<svg class="(icon|chat-av)[ "]/.test(t));
    if (tags.some((t) => forbidden.test(t))) { unsafe++; console.log("UNSAFE " + c.name + ": " + tags.filter((t) => forbidden.test(t)).join(" ").slice(0, 400)); }
  }
  if (update) {
    const text = JSON.stringify(got, null, 1).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f-]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
    writeFileSync(EXPECTED, text + '\n');
    console.log(`wrote ${Object.keys(got).length} expectations; ${unsafe} unsafe`);
    code = unsafe ? 1 : 0;
  } else {
    const want = JSON.parse(readFileSync(EXPECTED, 'utf8'));
    let bad = 0;
    for (const c of cases) {
      if (got[c.name] === want[c.name]) continue;
      bad++;
      const a = String(want[c.name]), b = String(got[c.name]);
      let k = 0;
      while (k < a.length && a[k] === b[k]) k++;
      const show = (x) => JSON.stringify(x.slice(Math.max(0, k - 30), k + 120)).replace(/[^\x20-\x7e]/g, (ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'));
      console.log(`DIFF ${c.name}\n  input: ${JSON.stringify(c.in ?? c.message).slice(0, 160)}\n  want:  ${show(a)}\n  got:   ${show(b)}`);
    }
    console.log(`chat-markdown-check: ${cases.length} cases, ${bad} different, ${unsafe} unsafe`);
    code = bad || unsafe ? 1 : 0;
  }
  ws.close();
} catch (e) {
  console.error('chat-markdown-check: ' + (e.message || e));
} finally {
  chrome.kill('SIGKILL');
  server.close();
  // Chrome's helpers may still be writing the profile a moment after the kill: wait for its end, then retry the removal.
  await new Promise((r) => { if (chrome.exitCode !== null || chrome.signalCode) r(); else chrome.once('exit', r); setTimeout(r, 3000); });
  await new Promise((r) => setTimeout(r, 500));
  rmSync(PROFILE, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
}
process.exit(code);
