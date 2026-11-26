// core/space-export — A space's exports (web.md, "The space editor's page"): the file as it is saved (YAML), and its drawing
// as SVG and as PNG, made in this browser from what this viewer already read — the file (`workspace-space`) and, only when
// asked, the state (`workspace-state`, the viewer's own projection). The drawing is the vendored renderer's `render()` (what
// the peer's exportSvg wraps; its export entry is not vendored), loaded through the pictures' loader; the PNG is that
// drawing rasterised here. No route or action of its own; nothing is sent anywhere.
import { api } from './api-496fd9f39af2a514.js';
import { loadRenderer } from './space-pictures-25bdb63b8ef211eb.js';

/// A picture's size (px); a PNG has 2 pixels for each.
const SIZE = { width: 1600, height: 1000, padding: 24 }, SCALE = 2;

/// The file name, after the workspace: NAME.workspace.yaml, NAME.svg, NAME.png.
export const exportName = (w, kind) => w + (kind === 'yaml' ? '.workspace.yaml' : '.' + kind);

/// The drawing's SVG markup, in one theme (a picture has one, whoever looks at it); a file that doesn't read is said in
/// words, never drawn as a fault.
async function drawing(drawn, st, theme) {
  const { render } = await loadRenderer();
  const svg = render(drawn, st, { ...SIZE, detail: 'hero', theme: theme === 'dark' ? 'dark' : 'light' });
  const head = svg.slice(0, svg.indexOf('>') + 1);
  if (/\bclass="[^"]*\bproblem\b/.test(head)) throw new Error('The file doesn’t read here — doz workspace up -f FILE --dry-run says why');
  return svg;
}

/// The SVG drawn on a canvas at SCALE → a PNG (the page's CSP allows img-src data:).
async function png(svg) {
  const img = new Image();
  await new Promise((ok, bad) => {
    img.onload = () => ok();
    img.onerror = () => bad(new Error('the drawing could not be read back as an image'));
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  });
  const c = document.createElement('canvas');
  c.width = SIZE.width * SCALE; c.height = SIZE.height * SCALE;
  const g = c.getContext('2d');
  if (!g) throw new Error('this browser gives no 2D canvas');
  g.drawImage(img, 0, 0, c.width, c.height);
  return new Promise((ok, bad) => c.toBlob((b) => (b ? ok(b) : bad(new Error('this browser made no PNG of it'))), 'image/png'));
}

/// The space file `f` as this viewer read it ({text, picture?}) as `kind` ('yaml' | 'svg' | 'png') → {name, blob}.
/// `live`: the drawing with what is true now (read now, as this viewer may read it); `theme`: 'light' or 'dark'.
/// The YAML is the file's own text, byte for byte. A drawing is of the file in the renderer's words (`picture`, else
/// the text) — as the workspace's pictures are drawn.
export async function makeExport(w, f, kind, { live = false, theme = 'light' } = {}) {
  const name = exportName(w, kind);
  if (kind === 'yaml') return { name, blob: new Blob([f.text], { type: 'application/yaml' }) };
  const st = live ? await api('workspace-state', { method: 'POST', json: { workspace: w } }) : undefined;
  const drawn = f.picture || f.text;
  const svg = await drawing(drawn, st, theme);
  return { name, blob: kind === 'svg' ? new Blob([svg], { type: 'image/svg+xml' }) : await png(svg) };
}
