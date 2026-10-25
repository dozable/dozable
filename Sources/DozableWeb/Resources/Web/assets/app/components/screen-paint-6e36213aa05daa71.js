// components/screen-paint — 648: a session's picture PAINTED from its GRID (core/grid.js) on a 2D canvas: no iframe, no
// terminal engine, no WebAssembly, no socket. The canvas is its box × devicePixelRatio; the screen keeps a terminal's
// cell shape and is centred in the box; the default background first, then each run's background, then its text —
// fillText with a maxWidth of its cells, so the columns hold — bold, italic, faint, underline, and the cursor as an
// outlined block. Too small to draw at all (a font under 2 device pixels) the text is drawn as bars, like a minimap.
// A picture is drawn again only when what it shows changed (its source and `gen`) or its box was resized.
import { FLAG_BOLD, FLAG_FAINT, FLAG_ITALIC, FLAG_UNDERLINE, inertText, textToGrid } from '../core/grid-4b92452852ac3a96.js';

/// A terminal cell's width over its height (ui-monospace / SF Mono: 0.6 em wide at a line height of one em).
const CELL_ASPECT = 0.6;
const FONT = 'ui-monospace, "SF Mono", Menlo, monospace';
/// The page's terminal colours (frame.js THEME) for a run without its own colour; the grid's own when asked.
const THEME = { fg: '#e3e5ea', bg: '#16171c', cursor: '#c9ccd6' };

/// Paint `grid` on `canvas`. `opts`: `gridColours` (draw the defaults the grid carries instead of the page's terminal's),
/// `cursor` (false: no cursor). Returns false when the canvas has no size yet (not laid out).
export function paintGrid(canvas, grid, opts = {}) {
  const dpr = Math.max(1, Math.min(3, window.devicePixelRatio || 1));
  const W = Math.round(canvas.clientWidth * dpr), H = Math.round(canvas.clientHeight * dpr);
  if (!W || !H) return false;
  if (canvas.width !== W) canvas.width = W;
  if (canvas.height !== H) canvas.height = H;
  const ctx = canvas.getContext('2d', { alpha: false });
  const dfg = opts.gridColours ? grid.fg : THEME.fg, dbg = opts.gridColours ? grid.bg : THEME.bg;
  ctx.globalAlpha = 1;
  ctx.fillStyle = dbg;
  ctx.fillRect(0, 0, W, H);
  // The cell: as big as the box allows with a terminal's shape; the screen centred.
  const ch = Math.min(H / grid.rows, W / (grid.cols * CELL_ASPECT));
  const cw = ch * CELL_ASPECT;
  const ox = (W - grid.cols * cw) / 2, oy = (H - grid.rows * ch) / 2;
  const px = (col) => Math.round(ox + col * cw);
  const rowTop = (y) => Math.round(oy + y * ch);
  // Backgrounds first (a run's text may overhang its cells by a pixel).
  for (let y = 0; y < grid.rows; y++) {
    const top = rowTop(y), bottom = rowTop(y + 1);
    for (const r of grid.lines[y]) {
      if (!r[3]) continue;
      ctx.fillStyle = r[3];
      ctx.fillRect(px(r[0]), top, px(r[0] + r[5]) - px(r[0]), bottom - top);
    }
  }
  const fontPx = ch * 0.9;
  // Bars only when text could not be drawn at all: tiny text still shows a log moving, bars of equal lines do not.
  const bars = fontPx < 2;
  let font = '';
  ctx.textBaseline = 'middle';
  for (let y = 0; y < grid.rows; y++) {
    const mid = oy + (y + 0.55) * ch;
    for (const r of grid.lines[y]) {
      const text = r[1];
      if (!text || !text.trim()) { if (r[4] & FLAG_UNDERLINE) underline(ctx, r, px, oy + (y + 0.92) * ch, r[2] || dfg, dpr); continue; }
      const fl = r[4];
      ctx.globalAlpha = fl & FLAG_FAINT ? 0.5 : 1;
      ctx.fillStyle = r[2] || dfg;
      if (bars) { paintBars(ctx, r, cw, ox, oy + y * ch, ch); }
      else {
        const f = (fl & FLAG_ITALIC ? 'italic ' : '') + (fl & FLAG_BOLD ? 'bold ' : '') + fontPx.toFixed(1) + 'px ' + FONT;
        if (f !== font) { ctx.font = f; font = f; }
        ctx.fillText(inertText(text), ox + r[0] * cw, mid, r[5] * cw);
      }
      if (fl & FLAG_UNDERLINE) underline(ctx, r, px, oy + (y + 0.92) * ch, r[2] || dfg, dpr);
    }
  }
  ctx.globalAlpha = 1;
  if (grid.cursor && opts.cursor !== false) {
    const lw = Math.max(1, Math.round(dpr));
    ctx.strokeStyle = opts.gridColours ? grid.fg : THEME.cursor;
    ctx.lineWidth = lw;
    const x0 = px(grid.cursor.x), y0 = rowTop(grid.cursor.y);
    ctx.strokeRect(x0 + lw / 2, y0 + lw / 2, Math.max(lw, px(grid.cursor.x + 1) - x0 - lw), Math.max(lw, rowTop(grid.cursor.y + 1) - y0 - lw));
  }
  return true;
}
function underline(ctx, r, px, y, colour, dpr) {
  ctx.fillStyle = colour;
  ctx.fillRect(px(r[0]), Math.round(y), px(r[0] + r[5]) - px(r[0]), Math.max(1, Math.round(dpr * 0.75)));
}
/// Text too small to read: each run of non-blank characters as a bar half a cell high.
function paintBars(ctx, r, cw, ox, top, ch) {
  const chars = [...r[1]];
  const step = r[5] / Math.max(1, chars.length);
  let start = -1;
  const flush = (end) => { if (start >= 0) ctx.fillRect(ox + (r[0] + start * step) * cw, top + ch * 0.3, (end - start) * step * cw, Math.max(1, ch * 0.45)); start = -1; };
  for (let i = 0; i < chars.length; i++) { if (chars[i] === ' ') flush(i); else if (start < 0) start = i; }
  flush(chars.length);
}

/// A saved screen's plain text, painted (monochrome, the size it was saved at when known).
export function paintText(canvas, text, opts = {}) {
  return paintGrid(canvas, textToGrid(text, opts.cols, opts.rows), opts);
}

// ── a picture: a canvas that remembers what it shows, so it is painted again only on a change or a resize ──
const pictures = new WeakMap();
const resized = new Set();
let resizeFrame = 0;
const sizes = typeof ResizeObserver === 'function' ? new ResizeObserver((entries) => {
  for (const e of entries) resized.add(e.target);
  if (!resizeFrame) resizeFrame = requestAnimationFrame(() => {
    resizeFrame = 0;
    for (const c of resized) { const p = pictures.get(c); if (p && p.grid) p.paint(); }
    resized.clear();
  });
}) : null;

/// A picture on `canvas` (made once per canvas). `show(grid, source)`: painted when `source` or the grid's `gen` changed
/// (else nothing — the same screen: a producer's gen moves with every change); `clear()`: the plain background; `drop()`:
/// stops watching its size.
export function picture(canvas, opts = {}) {
  let p = pictures.get(canvas);
  if (p) return p;
  p = {
    canvas, grid: null, key: '',
    show(grid, source) {
      const key = String(source || '') + '#' + grid.gen;
      if (key === p.key && p.grid) return false;
      p.grid = grid; p.key = key;
      p.paint();
      return true;
    },
    paint() { if (p.grid) paintGrid(canvas, p.grid, opts); },
    clear() {
      p.grid = null; p.key = '';
      const ctx = canvas.width && canvas.height ? canvas.getContext('2d', { alpha: false }) : null;
      if (ctx) { ctx.fillStyle = THEME.bg; ctx.fillRect(0, 0, canvas.width, canvas.height); }
    },
    drop() { if (sizes) sizes.unobserve(canvas); pictures.delete(canvas); },
  };
  pictures.set(canvas, p);
  if (sizes) sizes.observe(canvas);
  return p;
}
