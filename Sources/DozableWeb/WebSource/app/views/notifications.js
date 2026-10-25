// views/notifications — 647 (owner: "add Notification history page"): every notification this tab has shown, newest
// first — the ones showing now (with Dismiss) and how each of the others ended. Kept by components/notes.js
// (`state.noteHistory`, this browser tab); nothing here asks the host.
import { $, h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { state } from '../core/state.js';
import { panel } from '../components/blocks.js';
import { btn } from '../components/button.js';
import { TONE_ICON, clearNoteHistory, clearNotes, dismissNote, watchNotes } from '../components/notes.js';

const FILTERS = [
  { id: 'all', label: 'All', test: () => true },
  { id: 'showing', label: 'Showing', test: (e) => !e.ended },
  { id: 'bad', label: 'Failures', test: (e) => e.tone === 'bad' },
  { id: 'warn', label: 'Warnings', test: (e) => e.tone === 'warn' },
  { id: 'ok', label: 'Successes', test: (e) => e.tone === 'ok' },
];
const ENDED = { dismissed: 'Dismissed', expired: 'Went by itself', resolved: 'No longer true', replaced: 'Replaced by a newer one',
  overflow: 'Too many at once', closed: 'Page reloaded' };
let filter = 'all';
const time = (ms) => new Date(ms).toLocaleTimeString();

export async function viewNotifications() { return node(); }
function node() {
  const all = state.noteHistory.slice().reverse();
  const showing = all.filter((e) => !e.ended).length;
  const f = FILTERS.find((x) => x.id === filter) || FILTERS[0];
  const rows = all.filter(f.test).map(row);
  const seg = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Show' }, FILTERS.map((x) => {
    const n = all.filter(x.test).length;
    return h('button', { type: 'button', class: 'seg' + (x.id === f.id ? ' active' : ''), 'aria-pressed': x.id === f.id ? 'true' : 'false',
      'data-nh-filter': x.id, on: { click: () => { filter = x.id; repaint(); } } }, x.label + (n ? ' · ' + n : ''));
  }));
  return h('div', { class: 'nh-page' },
    h('div', { class: 'head' }, h('h1', null, 'Notifications'),
      h('div', { class: 'row' },
        showing ? btn('Dismiss all', () => clearNotes(), { small: true, icon: 'x' }) : null,
        all.length > showing ? btn('Clear history', () => clearNoteHistory(), { small: true, quiet: true, icon: 'trash-2' }) : null)),
    h('p', { class: 'sub' }, 'Every notification this tab has shown, newest first — the ones that went by themselves too. Kept until the tab is closed.'),
    h('div', { class: 'nh-tools' }, seg),
    panel(rows.length ? h('ul', { class: 'nh-list', 'data-note-history': '' }, rows) : null,
      all.length ? 'Nothing here with this filter.' : 'No notifications yet.'));
}
function row(e) {
  const live = !e.ended && state.notes.has(e.id);
  return h('li', { class: 'nh-row ' + (TONE_ICON[e.tone] ? e.tone : 'info') + (live ? ' is-live' : ''), 'data-nh': String(e.seq) },
    h('span', { class: 'nh-icon' }, icon(TONE_ICON[e.tone] || 'info')),
    h('span', { class: 'nh-t' }, time(e.at)),
    h('span', { class: 'nh-text' }, e.text),
    h('span', { class: 'nh-end' }, live
      ? [h('span', { class: 'nh-live' }, 'Showing'), btn('Dismiss', () => dismissNote(e.id), { small: true, quiet: true, icon: 'x' })]
      : h('span', { class: 'muted', title: e.endedAt ? time(e.endedAt) : null }, ENDED[e.ended] || 'Ended')));
}
function repaint() { if (state.view === 'notifications') $('view').replaceChildren(node()); }
watchNotes(repaint);
