// core/grid — 648: a GRID, the one shape every painted session picture is drawn from (the host's feed, a tab's frame on
// Home, a saved screen): its checks, its text made inert, and plain text as a grid.
//
//   Grid = { cols, rows, gen, fg: '#rrggbb', bg: '#rrggbb', cursor: {x, y} | null, lines: [[Run]] }  (lines: exactly rows)
//   Run  = [col, text, fg | null, bg | null, flags, cells]   flags: 1 bold · 2 italic · 4 underline · 8 faint · 16 inverse
//                                                             (already applied: informational)
// A grid's text comes from inside a sandbox: untrusted. It is only ever drawn on a canvas (fillText), never markup.

export const GRID_MAX_COLS = 1000, GRID_MAX_ROWS = 500;
/// The text of one row, at most (the host caps it at 4 KiB; a character is at least a byte).
export const GRID_ROW_TEXT = 4096;
export const FLAG_BOLD = 1, FLAG_ITALIC = 2, FLAG_UNDERLINE = 4, FLAG_FAINT = 8, FLAG_INVERSE = 16;

const COLOUR = /^#[0-9a-fA-F]{6}$/;
const int = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;
const colourOrNull = (v) => v === null || (typeof v === 'string' && COLOUR.test(v));

/// Whether `g` is a grid this page will draw: every field typed and within its bounds, `lines` exactly `rows` long, each
/// run inside the row. Fields beyond the contract are ignored (a producer may add some); anything wrong refuses it whole.
export function validGrid(g) {
  if (!g || typeof g !== 'object' || Array.isArray(g)) return false;
  if (!int(g.cols, 1, GRID_MAX_COLS) || !int(g.rows, 1, GRID_MAX_ROWS) || !int(g.gen, 0, Number.MAX_SAFE_INTEGER)) return false;
  if (typeof g.fg !== 'string' || !COLOUR.test(g.fg) || typeof g.bg !== 'string' || !COLOUR.test(g.bg)) return false;
  if (g.cursor !== null && !(g.cursor && typeof g.cursor === 'object' && int(g.cursor.x, 0, g.cols - 1) && int(g.cursor.y, 0, g.rows - 1))) return false;
  if (!Array.isArray(g.lines) || g.lines.length !== g.rows) return false;
  for (const line of g.lines) {
    if (!Array.isArray(line) || line.length > g.cols) return false;
    let text = 0;
    for (const r of line) {
      if (!Array.isArray(r) || r.length !== 6) return false;
      const [col, s, fg, bg, flags, cells] = r;
      if (!int(col, 0, g.cols - 1) || typeof s !== 'string' || !colourOrNull(fg) || !colourOrNull(bg) || !int(flags, 0, 255)
          || !int(cells, 1, g.cols - col)) return false;
      text += s.length;
      if (text > GRID_ROW_TEXT) return false;
    }
  }
  return true;
}

/// Text made inert: C0, DEL, C1 and the bidi controls become U+FFFD (the host does this first; it is cheap to do again).
const NOT_INERT = /[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/g;
export function inertText(s) { return String(s).replace(NOT_INERT, '�'); }

/// Plain text (a saved screen without a grid) as a grid of `cols` × `rows` in the default colours: line by line, cut at
/// the width, the last `rows` lines kept.
export function textToGrid(text, cols, rows) {
  const all = String(text).replace(/\r\n?/g, '\n').split('\n');
  while (all.length > 1 && all[all.length - 1] === '') all.pop();
  const width = int(cols, 1, GRID_MAX_COLS) ? cols : Math.min(GRID_MAX_COLS, Math.max(20, ...all.map((l) => [...l].length)));
  const height = int(rows, 1, GRID_MAX_ROWS) ? rows : Math.min(GRID_MAX_ROWS, Math.max(1, all.length));
  const kept = all.slice(-height);
  const lines = [];
  for (let y = 0; y < height; y++) {
    const chars = [...inertText(kept[y] || '')].slice(0, width);
    const s = chars.join('').slice(0, GRID_ROW_TEXT);
    lines.push(s.trim() ? [[0, s, null, null, 0, Math.max(1, Math.min(width, chars.length))]] : []);
  }
  return { cols: width, rows: height, gen: 0, fg: '#e3e5ea', bg: '#16171c', cursor: null, lines };
}
