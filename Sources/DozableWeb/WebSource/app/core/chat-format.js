// core/chat-format — chat's words for times and names (pure).
export const time = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
// Moments: a spurt of conversation starts at the first message and after a silence of MOMENT_GAP or more; a centred line
// with its start time opens each one, worked out from the log each time it changes.
export const MOMENT_GAP = 20 * 60;   // seconds
const dayAgo = (d) => {
  const n = new Date();
  return Math.round((new Date(n.getFullYear(), n.getMonth(), n.getDate()) - new Date(d.getFullYear(), d.getMonth(), d.getDate())) / 864e5);
};
const clock = (d) => d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP])M$/i, (x, c) => ' ' + c.toLowerCase() + 'm');
export function momentLabel(t) {
  const d = new Date(t * 1000), a = dayAgo(d);
  if (a === 0) return 'Today ' + clock(d);
  if (a === 1) return 'Yesterday ' + clock(d);
  const o = { weekday: 'short', day: 'numeric', month: 'short' };
  if (d.getFullYear() !== new Date().getFullYear()) o.year = 'numeric';
  return d.toLocaleDateString([], o).replace(',', '') + ', ' + clock(d);
}
export const mins = (s) => { s = Math.max(0, Math.round(s)); return s < 90 ? s + ' s' : s < 5400 ? Math.round(s / 60) + ' min' : (s / 3600).toFixed(1) + ' h'; };
export const cap = (n) => String(n).charAt(0).toUpperCase() + String(n).slice(1);
export const shown = (n) => (n > 99 ? '99+' : String(n));
/// A message's text without its Markdown, on one line (the rooms list's preview).
export const plain = (t) => String(t).replace(/```/g, ' ').replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+/gm, '')
  .replace(/[*_`~]+/g, '').replace(/\s+/g, ' ').trim();
export const shortWhen = (t) => {
  const d = new Date(t * 1000), a = dayAgo(d);
  return a <= 0 ? clock(d) : a === 1 ? 'Yest.' : a < 7 ? d.toLocaleDateString([], { weekday: 'short' }) : d.toLocaleDateString([], { day: 'numeric', month: 'short' });
};
