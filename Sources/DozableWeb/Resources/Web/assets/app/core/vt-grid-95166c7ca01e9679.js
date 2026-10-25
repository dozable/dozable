// core/vt-grid — 648: a saved screen's VT (the SNAPSHOT the host captured: SGR, cursor moves, text) read into a GRID,
// so a sleeping sandbox's pictures are painted like every other — with no terminal engine. A small reader, not an
// emulator: printable text with East Asian widths, CR LF BS HT, CUP and the other cursor moves, ED/EL/ECH, SGR (16, 256
// and direct colours, bold, faint, italic, underline, inverse), the alternate screen and DECTCEM; every string (OSC, DCS,
// APC, PM, SOS) and every other sequence is skipped. What it cannot read it leaves out — never drawn as text.
import { FLAG_BOLD, FLAG_FAINT, FLAG_INVERSE, FLAG_ITALIC, FLAG_UNDERLINE, GRID_MAX_COLS, GRID_MAX_ROWS, GRID_ROW_TEXT, inertText } from './grid-4b92452852ac3a96.js';

/// The terminal's default colours (the page's terminal: frame.js THEME) and the 16-colour palette.
const DEFAULT_FG = '#e3e5ea', DEFAULT_BG = '#16171c';
const BASE16 = ['#1d1f21', '#cc6666', '#b5bd68', '#f0c674', '#81a2be', '#b294bb', '#8abeb7', '#c5c8c6',
                '#666666', '#d54e53', '#b9ca4a', '#e7c547', '#7aa6da', '#c397d8', '#70c0b1', '#eaeaea'];
const hex2 = (n) => n.toString(16).padStart(2, '0');
const rgb = (r, g, b) => '#' + hex2(r & 255) + hex2(g & 255) + hex2(b & 255);
function palette(n) {
  if (n < 16) return BASE16[n];
  if (n < 232) { const i = n - 16, v = (x) => (x ? 55 + x * 40 : 0); return rgb(v(Math.floor(i / 36)), v(Math.floor(i / 6) % 6), v(i % 6)); }
  const g = 8 + (n - 232) * 10;
  return rgb(g, g, g);
}

/// 2 for a wide character, 0 for one that joins the previous (combining marks, variation selectors, ZWJ), else 1.
export function cellWidth(cp) {
  if ((cp >= 0x300 && cp <= 0x36f) || (cp >= 0x200b && cp <= 0x200f) || (cp >= 0xfe00 && cp <= 0xfe0f) || (cp >= 0x1ab0 && cp <= 0x1aff)
      || (cp >= 0x20d0 && cp <= 0x20ff) || (cp >= 0xe0100 && cp <= 0xe01ef)) return 0;
  if ((cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf && cp !== 0x303f) || (cp >= 0xac00 && cp <= 0xd7a3)
      || (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0xfe30 && cp <= 0xfe4f) || (cp >= 0xff00 && cp <= 0xff60) || (cp >= 0xffe0 && cp <= 0xffe6)
      || (cp >= 0x1f300 && cp <= 0x1f64f) || (cp >= 0x1f900 && cp <= 0x1f9ff) || (cp >= 0x20000 && cp <= 0x3fffd)) return 2;
  return 1;
}

/// The VT (bytes or a string) as a grid of `cols` × `rows` (the size the screen was saved at; else 80 × 24).
export function vtToGrid(input, cols, rows) {
  const W = Number.isInteger(cols) && cols >= 1 ? Math.min(GRID_MAX_COLS, cols) : 80;
  const H = Number.isInteger(rows) && rows >= 1 ? Math.min(GRID_MAX_ROWS, rows) : 24;
  const text = typeof input === 'string' ? input : new TextDecoder('utf-8', { fatal: false }).decode(input);
  const blank = () => ({ ch: ' ', fg: null, bg: null, fl: 0, w: 1 });
  const screen = () => Array.from({ length: H }, () => Array.from({ length: W }, blank));
  let main = screen(), cells = main, alt = null;
  let x = 0, y = 0, wrapNext = false, fg = null, bg = null, fl = 0, cursorOn = true, saved = { x: 0, y: 0 };
  const clamp = () => { x = Math.max(0, Math.min(W - 1, x)); y = Math.max(0, Math.min(H - 1, y)); wrapNext = false; };
  const scroll = () => { cells.shift(); cells.push(Array.from({ length: W }, blank)); };
  const lineFeed = () => { if (y === H - 1) scroll(); else y++; };
  const clearCell = (c) => { c.ch = ' '; c.fg = null; c.bg = bg; c.fl = 0; c.w = 1; };
  const put = (ch, cp) => {
    const w = cellWidth(cp);
    if (w === 0) { const px = wrapNext ? x : x - 1; if (px >= 0 && cells[y][px].w !== 0) cells[y][px].ch += ch; return; }
    if (wrapNext || x + w > W) { x = 0; lineFeed(); wrapNext = false; }
    const c = cells[y][x];
    Object.assign(c, { ch, fg, bg, fl, w });
    if (w === 2 && x + 1 < W) Object.assign(cells[y][x + 1], { ch: '', fg, bg, fl, w: 0 });
    if (x + w >= W) { x = W - 1; wrapNext = true; } else x += w;
  };
  const sgr = (ps) => {
    if (!ps.length) ps = [0];
    for (let i = 0; i < ps.length; i++) {
      const p = ps[i];
      if (p === 0) { fg = null; bg = null; fl = 0; }
      else if (p === 1) fl |= FLAG_BOLD;
      else if (p === 2) fl |= FLAG_FAINT;
      else if (p === 3) fl |= FLAG_ITALIC;
      else if (p === 4) fl |= FLAG_UNDERLINE;
      else if (p === 7) fl |= FLAG_INVERSE;
      else if (p === 22) fl &= ~(FLAG_BOLD | FLAG_FAINT);
      else if (p === 23) fl &= ~FLAG_ITALIC;
      else if (p === 24) fl &= ~FLAG_UNDERLINE;
      else if (p === 27) fl &= ~FLAG_INVERSE;
      else if (p >= 30 && p <= 37) fg = palette(p - 30);
      else if (p >= 90 && p <= 97) fg = palette(p - 82);
      else if (p >= 40 && p <= 47) bg = palette(p - 40);
      else if (p >= 100 && p <= 107) bg = palette(p - 92);
      else if (p === 39) fg = null;
      else if (p === 49) bg = null;
      else if (p === 38 || p === 48) {
        let c = null;
        if (ps[i + 1] === 5 && Number.isInteger(ps[i + 2])) { c = palette(Math.min(255, ps[i + 2])); i += 2; }
        else if (ps[i + 1] === 2 && ps.length >= i + 5) { c = rgb(ps[i + 2], ps[i + 3], ps[i + 4]); i += 4; }
        else break;
        if (p === 38) fg = c; else bg = c;
      }
    }
  };
  const erase = (row, from, to) => { for (let i = Math.max(0, from); i < Math.min(W, to); i++) clearCell(cells[row][i]); };
  const csi = (priv, params, final) => {
    const ps = params === '' ? [] : params.split(/[;:]/).map((v) => (v === '' ? 0 : parseInt(v, 10) || 0));
    const n = (i, d = 1) => (ps[i] ? ps[i] : d);
    if (priv === '?') {
      if (final === 'h' || final === 'l') for (const p of ps) {
        if (p === 25) cursorOn = final === 'h';
        else if (p === 1049 || p === 1047 || p === 47) {
          if (final === 'h' && !alt) { if (p === 1049) saved = { x, y }; alt = screen(); cells = alt; }
          else if (final === 'l' && alt) { alt = null; cells = main; if (p === 1049) ({ x, y } = saved); }
        }
      }
      return;
    }
    if (priv) return;
    switch (final) {
      case 'H': case 'f': y = n(0) - 1; x = n(1) - 1; clamp(); break;
      case 'A': y -= n(0); clamp(); break;
      case 'B': case 'e': y += n(0); clamp(); break;
      case 'C': case 'a': x += n(0); clamp(); break;
      case 'D': x -= n(0); clamp(); break;
      case 'E': y += n(0); x = 0; clamp(); break;
      case 'F': y -= n(0); x = 0; clamp(); break;
      case 'G': case '`': x = n(0) - 1; clamp(); break;
      case 'd': y = n(0) - 1; clamp(); break;
      case 'J': {
        const m = ps[0] || 0;
        if (m === 0) { erase(y, x, W); for (let r = y + 1; r < H; r++) erase(r, 0, W); }
        else if (m === 1) { for (let r = 0; r < y; r++) erase(r, 0, W); erase(y, 0, x + 1); }
        else for (let r = 0; r < H; r++) erase(r, 0, W);
        break;
      }
      case 'K': { const m = ps[0] || 0; if (m === 0) erase(y, x, W); else if (m === 1) erase(y, 0, x + 1); else erase(y, 0, W); break; }
      case 'X': erase(y, x, x + n(0)); break;
      case 'm': sgr(ps); break;
      case 's': saved = { x, y }; break;
      case 'u': ({ x, y } = saved); clamp(); break;
      default: break;
    }
  };
  // The reader: one pass over the code points.
  const cps = [...text];
  for (let i = 0; i < cps.length; i++) {
    const ch = cps[i], cp = ch.codePointAt(0);
    if (cp === 0x1b) {
      const nx = cps[i + 1];
      if (nx === '[') {
        let j = i + 2, priv = '';
        if (j < cps.length && /[?>=<]/.test(cps[j])) priv = cps[j++];
        let params = '';
        while (j < cps.length && /[0-9;:]/.test(cps[j])) params += cps[j++];
        while (j < cps.length && /[ -/]/.test(cps[j])) { priv = priv || cps[j]; j++; }    // intermediates: not ours
        if (j < cps.length) csi(priv, params, cps[j]);
        i = j;
      } else if (nx === ']' || nx === 'P' || nx === '_' || nx === '^' || nx === 'X') {
        // A string: up to BEL or ST (ESC \).
        let j = i + 2;
        while (j < cps.length && cps[j] !== '\x07' && !(cps[j] === '\x1b' && cps[j + 1] === '\\')) j++;
        i = cps[j] === '\x1b' ? j + 1 : j;
      } else if (nx === '7') { saved = { x, y }; i++; }
      else if (nx === '8') { ({ x, y } = saved); clamp(); i++; }
      else if (nx === 'c') { main = screen(); cells = main; alt = null; x = 0; y = 0; fg = null; bg = null; fl = 0; cursorOn = true; i++; }
      else if (nx === 'D') { lineFeed(); i++; }
      else if (nx === 'E') { x = 0; lineFeed(); i++; }
      else if (nx === 'M') { if (y > 0) y--; i++; }
      else if (nx === '(' || nx === ')' || nx === '*' || nx === '+' || nx === '#' || nx === '%') i += 2;   // charsets etc.
      else i++;
      continue;
    }
    if (cp === 0x0d) { x = 0; wrapNext = false; continue; }
    if (cp === 0x0a || cp === 0x0b || cp === 0x0c) { lineFeed(); wrapNext = false; continue; }
    if (cp === 0x08) { if (x > 0) x--; wrapNext = false; continue; }
    if (cp === 0x09) { x = Math.min(W - 1, (Math.floor(x / 8) + 1) * 8); continue; }
    if (cp < 0x20 || (cp >= 0x7f && cp <= 0x9f)) continue;
    put(ch, cp);
  }
  return gridOf(cells, W, H, cursorOn ? { x: Math.min(x, W - 1), y } : null);
}

/// Cells → a grid: runs of equal colours and flags; blank default cells left out; a wide character's tail adds nothing.
function gridOf(cells, W, H, cursor) {
  const lines = [];
  for (let y = 0; y < H; y++) {
    const row = cells[y], runs = [];
    let run = null, used = 0;
    for (let x = 0; x < W; x++) {
      const c = row[x];
      if (c.w === 0) { if (run) run[5]++; continue; }
      let cfg = c.fg, cbg = c.bg, fl = c.fl;
      if (fl & FLAG_INVERSE) { const f = cfg || DEFAULT_FG; cfg = cbg || DEFAULT_BG; cbg = f; }
      if (run && run[2] === cfg && run[3] === cbg && run[4] === fl) { run[1] += c.ch; run[5]++; }
      else { run = [x, c.ch, cfg, cbg, fl, 1]; runs.push(run); }
    }
    const kept = [];
    for (const r of runs) {
      // Blank default cells are left out: a run without a background loses its leading and trailing spaces.
      if (!r[3] && !(r[4] & FLAG_UNDERLINE)) {
        const lead = r[1].length - r[1].trimStart().length;
        const trail = r[1].length - r[1].trimEnd().length;
        if (lead === r[1].length) continue;
        r[0] += lead; r[5] -= lead + trail; r[1] = r[1].slice(lead, r[1].length - trail);
      }
      r[1] = inertText(r[1]);
      if (used + r[1].length > GRID_ROW_TEXT) r[1] = r[1].slice(0, Math.max(0, GRID_ROW_TEXT - used));
      used += r[1].length;
      if (r[5] > 0) kept.push(r);
    }
    lines.push(kept);
  }
  return { cols: W, rows: H, gen: 0, fg: DEFAULT_FG, bg: DEFAULT_BG, cursor, lines };
}
