// components/space-export — The space editor's Export menu (web.md, "The space editor's page"): the file (YAML), the drawing
// as SVG and as PNG, each downloaded as a file named after the workspace. For whoever may read the file — this Mac's own
// browser and another computer with serve.chat read or write alike —, from what this viewer already read; what is true
// now is in a drawing only when ticked. Exports are of the file as saved, never an unsaved change.
import { h } from '../dom/h.js';
import { btn } from './button.js';
import { menuButton } from './menus.js';
import { toast } from './notices.js';
import { makeExport } from '../core/space-export.js';

const LIVE_KEY = 'doz.space.export.live';
const kept = () => { try { return localStorage.getItem(LIVE_KEY) === '1'; } catch (_) { return false; } };
const keep = (on) => { try { if (on) localStorage.setItem(LIVE_KEY, '1'); else localStorage.removeItem(LIVE_KEY); } catch (_) { /* this page only */ } };
/// The drawing's theme: the dashboard's, else this browser's.
const themeNow = () => { const t = document.documentElement.dataset.theme; return t === 'light' || t === 'dark' ? t : matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'; };

/// The file `blob` saved as `name` by this browser (a link clicked, then let go).
function download({ name, blob }) {
  const url = URL.createObjectURL(blob);
  const a = h('a', { href: url, download: name, hidden: true });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

/// The Export button for workspace `w`; `file()` → the file as this viewer read it last ({text, picture?}).
export function exportMenu(w, file) {
  let live = kept(), busy = false;
  const run = async (kind) => {
    if (busy) return;
    busy = true;
    try { download(await makeExport(w, file(), kind, { live, theme: themeNow() })); } catch (e) {
      toast('Not exported: ' + (e && e.message || e), true);
    } finally { busy = false; }
  };
  const items = () => [
    { label: 'The file (YAML)', icon: 'file', desc: 'As saved — it holds the agents’ prompts, the members and the folders’ paths', data: { 'sp-export': 'yaml' }, onSelect: () => run('yaml') },
    { label: 'The drawing (SVG)', icon: 'image', desc: 'As saved, in this theme', data: { 'sp-export': 'svg' }, onSelect: () => run('svg') },
    { label: 'The drawing (PNG)', icon: 'image', desc: 'As saved, in this theme', data: { 'sp-export': 'png' }, onSelect: () => run('png') },
    { sep: true },
    { label: 'Drawings show what is happening now', icon: 'activity', check: live, desc: 'Who is working, waiting or stuck — off by default',
      data: { 'sp-export-live': live ? 'on' : 'off' }, onSelect: () => { live = !live; keep(live); ctl.setItems(items()); } },
  ];
  const trigger = btn('Export', () => {}, { small: true, icon: 'download', quiet: true });
  trigger.dataset.spExportMenu = w;
  const ctl = menuButton(trigger, items(), { label: 'Export the space', align: 'end' });
  return ctl.el;
}
