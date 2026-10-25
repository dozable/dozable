// doz ui — the terminal frame (591, owner ruling T2).
//
// The terminal engine (vendored ghostty-web, pinned) runs HERE, in an iframe the page loads with
// `sandbox="allow-scripts"` only: an OPAQUE origin. This document has no cookie, no storage, no
// access to the page, and its CSP lets it connect to nothing (`connect-src 'none'`) — so an engine
// compromise by hostile terminal output cannot reach the API, the CSRF token or the session. The
// page owns the WebSocket; this frame only draws and reports keys, over a narrow message protocol:
//
//   page → frame   {t:'init', wasm: ArrayBuffer, mode, fontSize}   once: compile the engine (one WASM
//                                                          instance); fontSize 9–32 (ui.terminal_font_size);
//                                                          mode interactive | watch | saved (593)
//                  {t:'write', data: ArrayBuffer}         terminal bytes to draw
//                  {t:'paste', text}                      a paste the PAGE made safe (and confirmed)
//                  {t:'focus'} · {t:'keep-scrollback'} (after a boot view, before the session's screen)
//                  {t:'live', mode}                       593: a SAVED screen becomes the live session
//                                                          (interactive | watch) — only from saved
//                  {t:'top'}                              593: scroll to the first line (a Boot log)
//                  {t:'grid', gen}                        648: the screen as a GRID, unless it is still `gen`
//   frame → page   {t:'ready'} · {t:'opened', cols, rows} · {t:'data', s} (keys, reports)
//                  {t:'grid', grid} · {t:'grid', same: true}   648: the answer (core/grid.js has the shape)
//                  {t:'resize', cols, rows} · {t:'title', s} · {t:'paste', text, bracketed}
//                  {t:'paste-too-big', bytes} · {t:'failed'} (the engine did not load)
//                  {t:'key'}                              593: a key was pressed on a SAVED screen —
//                                                          no content; the page decides (wake/resume)
//                  {t:'link', url}                        636: a Cmd-clicked link — the page checks and opens it
//
// 593 §9 — `saved` mode: a session's last saved screen (VT the host captured) drawn read-only and
// selectable while its sandbox does not run. Nothing is ever sent from it — no keys, no reports, no
// focus reports, no paste; a key press is only announced ('key'), so the page can wake the sandbox.
//
// Every message is checked here (source = the parent, known type, typed fields, capped sizes); anything
// else is dropped and counted. The hardening that was the page's is kept, inside the frame:
//   · a link opens only on a Cmd-click, and never from here: the URL goes to the page, which allows http/https to
//     another host only and opens it (Ctrl clicks dropped; this sandbox has no allow-popups): upstream #194, 636;
//   · the engine's own paste handler never runs: a paste goes to the page, which encodes it (Ghostty
//     1.3.0's encode), asks when unsafe or large, refuses over 1 MiB (CVE-2026-26982, upstream #193);
//   · drops are refused; Cmd-chords stay the browser's; focus reports are sent (the engine does not);
//   · one WASM instance per terminal — one frame per terminal (upstream #141).
'use strict';

const MAX_WRITE = 1 << 20;
const MAX_PASTE = 1 << 20;
const THEME = { background: '#16171c', foreground: '#e3e5ea', cursor: '#c9ccd6', selectionBackground: '#3b4a6b' };
const frameStats = { dropped: 0 };
let term = null;
let mode = 'interactive';
let focused = false;
let fit = null;
let pendingSize = null;
let fixed = null;

/// 635: a WATCH (and a thumbnail's saved screen) is laid out at its session's size (cols × rows, from the page) and scaled to fit this frame — never
/// fitted to the frame: laid out smaller than the session, a program's full-screen redraws scrolled.
function sessionSize(cols, rows) {
  if (!term) { pendingSize = { cols, rows }; return; }
  if (!fixed) {
    quietly(() => fit.dispose());                    // the frame's own size no longer decides the grid
    const host = document.getElementById('term');
    if (host) host.style.inset = '0';                // the whole frame, so the picture is centred in it
    new ResizeObserver(scaleToFit).observe(document.documentElement);
  }
  fixed = { cols, rows };
  if (term.cols !== cols || term.rows !== rows) quietly(() => term.resize(cols, rows));
  scaleToFit();
}
/// The CANVAS is scaled (the host clips what overflows its own box — scaling the host showed a clipped corner, small),
/// up or down, by one factor: the whole session in the frame, its aspect kept.
function scaleToFit() {
  const host = document.getElementById('term');
  const canvas = host && host.querySelector('canvas');
  if (!fixed || !canvas) return;
  const w = canvas.offsetWidth, h = canvas.offsetHeight;
  const hw = host.clientWidth, hh = host.clientHeight;
  if (!w || !h || !hw || !hh) return;
  const s = Math.min(hw / w, hh / h);
  // Centred in the frame (owner): the spare width or height split on both sides.
  const x = Math.max(0, (hw - w * s) / 2), y = Math.max(0, (hh - h * s) / 2);
  canvas.style.transformOrigin = '0 0';
  canvas.style.transform = 'translate(' + x + 'px, ' + y + 'px) scale(' + s + ')';
}

// 636 (owner: "yes cmd-click"): the engine opens a link only on a Cmd/Ctrl click, through window.open — this frame
// opens nothing itself (no allow-popups); it hands the URL to the page, which checks it and opens it. Ctrl-clicks are
// still dropped (on a Mac, Ctrl-click is the context click), so only Cmd-click gets here.
const MAX_LINK = 2048;
window.open = function linkToPage(url) {
  const s = String(url || '');
  if (s.length <= MAX_LINK) toPage({ t: 'link', url: s });
  return null;
};

function toPage(msg) { window.parent.postMessage(msg, '*'); }
function quietly(fn, fallback) { try { return fn(); } catch (_) { return fallback; } }

async function init(wasm, m, fontSize) {
  mode = m;
  // The page fetched the engine's WebAssembly from its own origin; this frame compiles it
  // ('wasm-unsafe-eval') into its OWN instance — no fetch from here (connect-src 'none').
  const { instance } = await WebAssembly.instantiate(wasm, { env: { log: () => {} } });
  const engine = new GhosttyWeb.Ghostty(instance);
  const host = document.getElementById('term');
  // `scrollback` is BYTES in 0.4.0's WASM (upstream #140), not lines: the default 10 000 kept ~10 KB,
  // too little for a boot log. 4 MiB.
  term = new GhosttyWeb.Terminal({ ghostty: engine, fontSize, fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
                                   theme: THEME, cursorBlink: false, disableStdin: mode === 'watch', scrollback: 4 * 1024 * 1024 });
  // 648: a read-only screen (a thumbnail, a watch, a saved screen) never takes the focus as it loads. The engine's open()
  // focuses its element whatever the mode, and a frame that takes the focus makes the browser scroll the PAGE to bring
  // it into view — the dashboard jumped ~400 px each time a picture loaded after a scroll (the 647 thumb-scroll trace).
  // The engine is vendored byte for byte, so its focus is held here, around open() — and until the second focus its
  // focus() defers with setTimeout(0) has run (a timer set after it runs after it); a click still focuses a frame.
  const realFocus = HTMLElement.prototype.focus;
  if (mode !== 'interactive') HTMLElement.prototype.focus = function () {};
  try { term.open(host); } finally { setTimeout(() => { HTMLElement.prototype.focus = realFocus; }, 0); }
  fit = new GhosttyWeb.FitAddon();
  term.loadAddon(fit);
  fit.fit();
  fit.observeResize();
  if (pendingSize) { const s = pendingSize; pendingSize = null; sessionSize(s.cols, s.rows); }
  term.onData((s) => { if (mode === 'interactive') toPage({ t: 'data', s }); });
  term.onResize((d) => { screenGen = (screenGen % 0xffffffff) + 1; toPage({ t: 'resize', cols: d.cols, rows: d.rows }); });
  term.onTitleChange((s) => toPage({ t: 'title', s: String(s).slice(0, 120) }));
  guard(document.documentElement);
  mouseGuard(document.documentElement);
  term.attachCustomWheelEventHandler(onWheel);
  toPage({ t: 'opened', cols: term.cols, rows: term.rows });
  if (mode === 'interactive') term.focus();
}

/// 593: a key on a saved screen — announced (at most every 2 s), never typed: modifiers alone and the
/// browser's Cmd-chords do not count.
const MODIFIER_KEYS = new Set(['Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'Fn', 'OS']);
let lastKeyNotice = 0;
function savedKey(ev) {
  if (mode !== 'saved' || ev.metaKey || MODIFIER_KEYS.has(ev.key)) return;
  ev.preventDefault();
  ev.stopPropagation();
  const now = Date.now();
  if (now - lastKeyNotice < 2000) return;
  lastKeyNotice = now;
  toPage({ t: 'key' });
}

// ── 594 (owner's walkthrough W14): the mouse, as a terminal program asks for it ──────────────────
// ghostty-web 0.4.0 tracks the mouse modes (1000/1002/1003, 1005/1006/1015, 1007) but never REPORTS the
// mouse: its wheel handler sends arrow keys whenever the alternate screen is up ("Scroll wheel is
// sending arrow keys" — Claude Code), and a click only ever selects. So, here:
//   · the program tracks the mouse (1000/1002/1003) — the wheel sends wheel reports (buttons 64/65 with
//     the modifiers), and a click, a drag and (1003) plain motion reach it as reports, in the encoding it
//     asked for (SGR 1006, urxvt 1015, UTF-8 1005, else X10). Shift held: the terminal's own selection
//     and wheel instead, as in a native terminal (Shift+drag selects);
//   · it does not: in the alternate screen the wheel is arrow keys only when it asked for them
//     (alternate scroll, 1007), and otherwise does nothing (that screen has no scrollback); on the
//     main screen the wheel scrolls the terminal's own scrollback.
// Reports are input: sent only in an interactive pane (never watch, never a saved screen).
const mouse = { acc: 0, pressed: null, lastCell: null };
function modeOn(n) { return !!(term && quietly(() => term.getMode(n, false), false)); }
function tracking() { return modeOn(1003) ? 1003 : modeOn(1002) ? 1002 : modeOn(1000) ? 1000 : 0; }
function encoding() { return modeOn(1006) ? 'sgr' : modeOn(1015) ? 'urxvt' : modeOn(1005) ? 'utf8' : 'x10'; }
function modifiers(ev) { return (ev.shiftKey ? 4 : 0) | (ev.altKey ? 8 : 0) | (ev.ctrlKey ? 16 : 0); }

/// One report: `button` (0–2 buttons, 3 = no button, 64/65 wheel; +32 motion; + modifiers), 1-based
/// cell; `release`: SGR's lower-case m (the other encodings say a release with button 3). null: the
/// cell cannot be said in this encoding (X10/UTF-8 beyond their range).
function mouseReport(enc, button, col, row, release) {
  switch (enc) {
    case 'sgr': return '\x1b[<' + button + ';' + col + ';' + row + (release ? 'm' : 'M');
    case 'urxvt': return '\x1b[' + ((release ? 3 : button) + 32) + ';' + col + ';' + row + 'M';
    case 'utf8':
      if (col > 2015 || row > 2015) return null;
      return '\x1b[M' + String.fromCharCode((release ? 3 : button) + 32, col + 32, row + 32);
    default:
      if (col > 95 || row > 95) return null;                          // one byte each, 7-bit safe
      return '\x1b[M' + String.fromCharCode((release ? 3 : button) + 32, col + 32, row + 32);
  }
}

/// The 1-based cell under a mouse event.
function cellAt(ev) {
  const canvas = document.querySelector('#term canvas');
  if (!canvas || !term) return null;
  const r = canvas.getBoundingClientRect();
  const m = quietly(() => term.renderer.getMetrics(), null);
  const cw = (m && m.width) || r.width / term.cols, ch = (m && m.height) || r.height / term.rows;
  const col = Math.min(term.cols, Math.max(1, Math.floor((ev.clientX - r.left) / cw) + 1));
  const row = Math.min(term.rows, Math.max(1, Math.floor((ev.clientY - r.top) / ch) + 1));
  return { col, row, ch };
}

function sendReport(button, cell, release) {
  const s = mouseReport(encoding(), button, cell.col, cell.row, release);
  if (s) toPage({ t: 'data', s });
}

/// The wheel (the engine calls this first; true = handled, its own handler does nothing).
function onWheel(ev) {
  screenGen = (screenGen % 0xffffffff) + 1;                            // 648: the viewport may move
  const interactive = mode === 'interactive';
  if (interactive && tracking() && !ev.shiftKey) {
    const cell = cellAt(ev);
    if (!cell) return true;
    const lines = ev.deltaMode === 1 ? ev.deltaY : ev.deltaMode === 2 ? ev.deltaY * term.rows : ev.deltaY / cell.ch;
    mouse.acc += lines;
    const n = Math.min(10, Math.trunc(Math.abs(mouse.acc)));
    if (!n) return true;
    const button = (mouse.acc < 0 ? 64 : 65) | modifiers(ev) & ~4;
    mouse.acc -= Math.sign(mouse.acc) * n;
    for (let i = 0; i < n; i++) sendReport(button, cell, false);
    return true;
  }
  mouse.acc = 0;
  if (quietly(() => term.wasmTerm.isAlternateScreen(), false)) {
    // Arrow keys only when the program asked for alternate scroll (and only as input).
    return !(interactive && modeOn(1007));
  }
  return false;                                                        // the scrollback
}

function mouseGuard(root) {
  const takes = (ev) => mode === 'interactive' && !ev.shiftKey && !ev.metaKey && tracking() !== 0;
  root.addEventListener('mousedown', (ev) => {
    if (!takes(ev) || ev.button > 2) return;
    const cell = cellAt(ev);
    if (!cell) return;
    ev.preventDefault();
    ev.stopPropagation();                                              // no selection starts
    term.focus();
    mouse.pressed = ev.button;
    mouse.lastCell = cell.col + ',' + cell.row;
    sendReport(ev.button | modifiers(ev), cell, false);
  }, true);
  window.addEventListener('mousemove', (ev) => {
    if (mode !== 'interactive' || !term) return;
    const t = tracking();
    if (!t || (mouse.pressed === null && t !== 1003) || (mouse.pressed !== null && t === 1000)) return;
    const cell = cellAt(ev);
    if (!cell) return;
    const key = cell.col + ',' + cell.row;
    if (key === mouse.lastCell) return;
    mouse.lastCell = key;
    if (mouse.pressed !== null) { ev.preventDefault(); ev.stopPropagation(); }
    sendReport((mouse.pressed === null ? 3 : mouse.pressed) + 32 | modifiers(ev), cell, false);
  }, true);
  window.addEventListener('mouseup', (ev) => {
    if (mouse.pressed === null) return;
    const button = mouse.pressed;
    mouse.pressed = null;
    const cell = cellAt(ev);
    if (!cell || mode !== 'interactive' || !tracking()) return;
    ev.preventDefault();
    ev.stopPropagation();
    sendReport(button | modifiers(ev), cell, true);
  }, true);
}

function guard(root) {
  // Links: a Cmd-click reaches the engine, whose link handler calls window.open (above: to the page); a Ctrl-click
  // is dropped (a Mac's context click), and so is any modified click outside the interactive/watch screens.
  for (const type of ['click', 'auxclick', 'mousedown', 'mouseup']) {
    root.addEventListener(type, (ev) => {
      const cmdClick = ev.metaKey && !ev.ctrlKey && type === 'click' && ev.button === 0;
      if ((ev.metaKey || ev.ctrlKey) && !cmdClick) { ev.preventDefault(); ev.stopPropagation(); }
    }, true);
  }
  // The engine shows a pointer over a link; say what opens it.
  const host = document.getElementById('term');
  if (host) new MutationObserver(() => {
    const over = host.style.cursor === 'pointer';
    if (over && !host.title) host.title = '⌘-click to open the link';
    else if (!over && host.title) host.removeAttribute('title');
  }).observe(host, { attributes: true, attributeFilter: ['style'] });
  // Paste: to the page (which makes it safe), never the engine's own handler. Drops refused.
  root.addEventListener('paste', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (mode !== 'interactive' || !term) return;
    const text = ev.clipboardData ? ev.clipboardData.getData('text/plain') : '';
    if (!text) return;
    if (text.length > MAX_PASTE) { toPage({ t: 'paste-too-big', bytes: text.length }); return; }
    toPage({ t: 'paste', text, bracketed: quietly(() => term.hasBracketedPaste(), false) });
  }, true);
  root.addEventListener('drop', (ev) => { ev.preventDefault(); ev.stopPropagation(); }, true);
  // Keys: Cmd-C copies a selection; Cmd-V pastes (the paste event above); every other Cmd-chord is
  // the browser's and never reaches the guest.
  root.addEventListener('keydown', (ev) => {
    if (mode === 'saved') { savedKey(ev); if (!ev.metaKey) return; }
    if (!ev.metaKey) return;
    if (ev.code === 'KeyV') return;
    if (ev.code === 'KeyC' && term && quietly(() => term.hasSelection(), false)) {
      ev.preventDefault();
      // 606: an http page (doz serve on the LAN) is not a secure context — no clipboard API there.
      if (navigator.clipboard) navigator.clipboard.writeText(term.getSelection()).catch(() => {});
    }
    ev.stopPropagation();
  }, true);
  // Focus reports (DEC 1004): the engine tracks the mode but does not send them. They are reports:
  // the UI process never wakes a sandbox for one.
  window.addEventListener('focus', () => {
    if (focused) return;
    focused = true;
    if (mode !== 'saved' && term && quietly(() => term.hasFocusEvents(), false)) toPage({ t: 'data', s: '\x1b[I' });
  });
  window.addEventListener('blur', () => {
    if (!focused) return;
    focused = false;
    if (mode !== 'saved' && term && quietly(() => term.hasFocusEvents(), false)) toPage({ t: 'data', s: '\x1b[O' });
  });
}

// ── the protocol: only the parent, only these messages, each field typed and capped.
function valid(m) {
  if (!m || typeof m !== 'object' || typeof m.t !== 'string') return false;
  switch (m.t) {
    case 'init': return !term && m.wasm instanceof ArrayBuffer && (m.mode === 'interactive' || m.mode === 'watch' || m.mode === 'saved')
                        && Number.isInteger(m.fontSize) && m.fontSize >= 9 && m.fontSize <= 32 && Object.keys(m).length === 4;
    case 'live': return !!term && mode === 'saved' && (m.mode === 'interactive' || m.mode === 'watch') && Object.keys(m).length === 2;
    case 'write': return !!term && m.data instanceof ArrayBuffer && m.data.byteLength <= MAX_WRITE && Object.keys(m).length === 2;
    case 'paste': return !!term && typeof m.text === 'string' && m.text.length <= MAX_PASTE && Object.keys(m).length === 2;
    case 'focus': case 'keep-scrollback': case 'top': return !!term && Object.keys(m).length === 1;
    case 'size': return (mode === 'watch' || mode === 'saved') && Number.isInteger(m.cols) && m.cols >= 2 && m.cols <= 1000
                        && Number.isInteger(m.rows) && m.rows >= 1 && m.rows <= 500 && Object.keys(m).length === 3;
    case 'grid': return !!term && Number.isInteger(m.gen) && m.gen >= 0 && m.gen <= 0xffffffff && Object.keys(m).length === 2;
    default: return false;
  }
}

// ── 648: the screen as a GRID (the page's painted pictures — Home's picture of a session that has a tab). `gen` moves
// with every change this frame makes to the screen (a write, a resize, a mode); a question with the current gen is
// answered {t:'grid', same: true}. Built from the engine's render state: the viewport's cells with their resolved
// colours (black background = the default), its default colours, the cursor. Text is made inert here too.
let screenGen = 1;
const GRID_ROW_TEXT = 4096;
// The C0/C1 controls, DEL and the bidi controls never leave this frame as text.
const NOT_INERT = /[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/g;
const hex2 = (n) => (n & 255).toString(16).padStart(2, '0');
const hex = (r, g, b) => '#' + hex2(r) + hex2(g) + hex2(b);
function screenGrid() {
  const w = term.wasmTerm;
  w.update();
  const { cols, rows } = w.getDimensions();
  if (!(cols >= 1 && cols <= 1000 && rows >= 1 && rows <= 500)) return null;
  const colours = w.getColors();
  const dfg = hex(colours.foreground.r, colours.foreground.g, colours.foreground.b);
  const dbg = hex(colours.background.r, colours.background.g, colours.background.b);
  const cur = w.getCursor();
  const cells = w.getViewport();                       // a pool the next call reuses: read it now
  const lines = [];
  for (let y = 0; y < rows; y++) {
    const runs = [];
    let run = null, used = 0;
    for (let x = 0; x < cols; x++) {
      const c = cells[y * cols + x];
      if (!c) break;
      if (c.width === 0) { if (run) run[5]++; continue; }            // a wide character's tail
      const inv = (c.flags & 16) !== 0;
      let fr = c.fg_r, fgc = c.fg_g, fb = c.fg_b, br = c.bg_r, bgc = c.bg_g, bb = c.bg_b;
      const defaultBg = br === 0 && bgc === 0 && bb === 0;
      if (inv) { [fr, fgc, fb, br, bgc, bb] = [defaultBg ? colours.background.r : br, defaultBg ? colours.background.g : bgc, defaultBg ? colours.background.b : bb, fr, fgc, fb]; }
      let fg = hex(fr, fgc, fb), bg = inv || !defaultBg ? hex(br, bgc, bb) : null;
      if (fg === dfg) fg = null;
      if (bg === dbg) bg = null;
      const flags = (c.flags & 1 ? 1 : 0) | (c.flags & 2 ? 2 : 0) | (c.flags & 4 ? 4 : 0) | (c.flags & 128 ? 8 : 0) | (inv ? 16 : 0);
      let ch = ' ';
      if (!(c.flags & 32)) {                                          // invisible text is drawn as blanks
        if (c.grapheme_len > 0) ch = quietly(() => w.getGraphemeString(y, x), ' ') || ' ';
        else if (c.codepoint) ch = String.fromCodePoint(c.codepoint);
      }
      if (run && run[2] === fg && run[3] === bg && run[4] === flags) { run[1] += ch; run[5]++; }
      else { run = [x, ch, fg, bg, flags, 1]; runs.push(run); }
    }
    const kept = [];
    for (const r of runs) {
      if (!r[3] && !(r[4] & 4)) {                                     // blank default cells are left out
        const lead = r[1].length - r[1].trimStart().length, trail = r[1].length - r[1].trimEnd().length;
        if (lead === r[1].length) continue;
        r[0] += lead; r[5] -= lead + trail; r[1] = r[1].slice(lead, r[1].length - trail);
      }
      r[1] = r[1].replace(NOT_INERT, '�');
      if (used + r[1].length > GRID_ROW_TEXT) r[1] = r[1].slice(0, Math.max(0, GRID_ROW_TEXT - used));
      used += r[1].length;
      if (r[5] > 0 && r[0] + r[5] <= cols) kept.push(r);
    }
    lines.push(kept);
  }
  const cursor = cur && cur.visible && cur.x >= 0 && cur.x < cols && cur.y >= 0 && cur.y < rows ? { x: cur.x, y: cur.y } : null;
  return { cols, rows, gen: screenGen, fg: dfg, bg: dbg, cursor, lines };
}
function answerGrid(asked) {
  if (asked === screenGen) { toPage({ t: 'grid', same: true }); return; }
  const g = quietly(screenGrid, null);
  if (g) toPage({ t: 'grid', grid: g });
}
window.addEventListener('message', (ev) => {
  if (ev.source !== window.parent || !valid(ev.data)) { frameStats.dropped++; return; }
  const m = ev.data;
  if (m.t !== 'grid' && m.t !== 'focus' && m.t !== 'paste') screenGen = (screenGen % 0xffffffff) + 1;   // 648: the screen may change
  switch (m.t) {
    case 'init': init(m.wasm, m.mode, m.fontSize).catch(() => toPage({ t: 'failed' })); break;
    case 'write': term.write(new Uint8Array(m.data)); break;
    case 'grid': answerGrid(m.gen); break;
    case 'paste': if (mode === 'interactive') term.paste(m.text); break;
    case 'size': sessionSize(m.cols, m.rows); break;
    case 'focus': term.focus(); break;
    // 593: the saved screen becomes the live session (the page then attaches; its SNAPSHOT redraws).
    case 'live': mode = m.mode; break;
    // 593: a Boot log opens at its first line (the steps), not at the console's end.
    case 'top': quietly(() => term.scrollToTop()); break;
    // After the boot view: the screen (the boot log's end) scrolls into the scrollback before the
    // session's first screen replaces it — the terminal alone knows how tall it is.
    case 'keep-scrollback': term.write('\x1b[999;1H' + '\r\n'.repeat(term.rows)); break;
  }
});

toPage({ t: 'ready' });
