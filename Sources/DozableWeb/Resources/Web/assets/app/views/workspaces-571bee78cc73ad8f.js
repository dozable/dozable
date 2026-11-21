// views/workspaces — The Workspaces page (#/workspaces; the sidebar's Workspaces heading): every workspace, finished and
// archived ones included, as rows or as a grid of cards — each its picture (components/space-picture.js: a space file's
// drawing, read only while on screen; a small tile for one made without a file), its name (its Home), its state, who
// drives and manages it, who is working, its room, when its log last moved and its one next action
// (components/ws-next.js). Show filters by state (with counts), Sort orders by state (the default, as Home and the
// sidebar), name or last activity. Layout and sort are kept in this browser; Show starts at Every workspace on each visit.
// Read on arrival, hello, `changed` and an operation's end like Home — never on a timer, and never a workspace's own read.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { full, plural, when } from '../core/format-b2e68384da8d2f36.js';
import { refresh } from '../core/router-1c2b9b3ceaae8f0d.js';
import { roomHash, workspaceHash } from '../core/routes-37c1065d5dad96cd.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { byState, isDone, loadWorkspaces } from '../core/workspaces-aa98b813f3dda08f.js';
import { paintWorkspaceCounts } from '../components/nav-3a5b2efc4d1ccf55.js';
import { forgetThumbs, spaceThumb } from '../components/space-picture-44434d427be7363a.js';
import { transitional } from '../components/ws-lifecycle-8062261107bea1d4.js';
import { driverChip, managerChip, workspacePill } from '../components/ws-marks-26369af31d4dbb6f.js';
import { renderNavWorkspaces } from '../components/ws-nav-2f15e7a07edf1b8e.js';
import { wsNext } from '../components/ws-next-6474518fbd2becdd.js';

const SHOW = [
  ['all', 'Every workspace', () => true],
  ['waiting', 'Waiting on you', (w) => w.state === 'waiting-on-you'],
  ['working', 'Working', (w) => w.state === 'working' || w.state === 'starting'],
  ['idle', 'Idle', (w) => w.state === 'idle'],
  ['setting-up', 'Setting up', (w) => w.state === 'setting-up'],
  ['asleep', 'Asleep', (w) => w.state === 'asleep'],
  ['done', 'Finished & archived', isDone],
];
const SORT = [['state', 'State'], ['name', 'Name'], ['last', 'Last activity']];
const LAYOUT_KEY = 'doz.workspaces.layout', SORT_KEY = 'doz.workspaces.sort';
const kept = (k, allowed, d) => { try { const v = localStorage.getItem(k); return allowed.includes(v) ? v : d; } catch (_) { return d; } };
const keep = (k, v) => { try { localStorage.setItem(k, v); } catch (_) { /* this page only */ } };

let show = 'all';
let refocus = null;      // the toolbar control a change came from: the keyboard keeps its place across the redraw
// Show starts at Every workspace on each visit (leaving the page resets it).
addEventListener('hashchange', () => { if (location.hash !== '#/workspaces') show = 'all'; });

/// The rows in an order: by state then name (Home's and the sidebar's), by name, or by last activity (newest first, none last).
function sorted(list, by) {
  if (by === 'name') return list.slice().sort((a, b) => a.name.localeCompare(b.name));
  if (by === 'last') return list.slice().sort((a, b) => (Date.parse(b.lastAt) || 0) - (Date.parse(a.lastAt) || 0) || a.name.localeCompare(b.name));
  return byState(list);
}

export async function viewWorkspaces() {
  const l = await loadWorkspaces(0);
  paintWorkspaceCounts();
  renderNavWorkspaces();
  const all = l.workspaces;
  forgetThumbs(all.map((w) => w.name), 'list');
  const layout = kept(LAYOUT_KEY, ['rows', 'grid'], 'rows'), by = kept(SORT_KEY, SORT.map((s) => s[0]), 'state');
  const counts = new Map(SHOW.map(([id, , f]) => [id, all.filter(f).length]));
  const showSel = h('select', { 'aria-label': 'Show', 'data-wsl-show': '' }, ...SHOW.map(([id, label]) =>
    h('option', { value: id, selected: id === show ? true : null }, label + ' (' + counts.get(id) + ')')));
  showSel.addEventListener('change', () => { show = showSel.value; refocus = '[data-wsl-show]'; refresh(false); });
  const sortSel = h('select', { 'aria-label': 'Sort', 'data-wsl-sort': '' }, ...SORT.map(([id, label]) => h('option', { value: id, selected: id === by ? true : null }, label)));
  sortSel.addEventListener('change', () => { keep(SORT_KEY, sortSel.value); refocus = '[data-wsl-sort]'; refresh(false); });
  const seg = (id, label, ic) => h('button', { type: 'button', class: 'seg', 'aria-pressed': layout === id ? 'true' : 'false', 'data-wsl-layout': id,
    on: { click: () => { keep(LAYOUT_KEY, id); refocus = '[data-wsl-layout="' + id + '"]'; refresh(false); } } }, icon(ic), label);
  const toolbar = h('div', { class: 'toolbar wsl-toolbar' }, h('label', null, 'Show ', showSel), h('label', null, 'Sort ', sortSel),
    h('div', { class: 'segmented', role: 'group', 'aria-label': 'Layout' }, seg('rows', 'Rows', 'list'), seg('grid', 'Grid', 'layout-grid')));
  const f = (SHOW.find((s) => s[0] === show) || SHOW[0])[2];
  const list = sorted(all.filter(f), by);
  const body = !all.length ? h('p', { class: 'muted' }, 'No workspaces yet. ', h('a', { href: '#/home' }, 'Home'), ' says how to make one.')
    : !list.length ? h('p', { class: 'muted', 'data-wsl-none': '' }, 'None ' + (SHOW.find((s) => s[0] === show) || SHOW[0])[1].toLowerCase() + '.')
      : layout === 'grid' ? h('ul', { class: 'wsl-grid', 'data-wsl-list': 'grid' }, ...list.map(card)) : h('ul', { class: 'wsl-rows', 'data-wsl-list': 'rows' }, ...list.map(row));
  if (refocus) { const sel = refocus; refocus = null; requestAnimationFrame(() => { const el = document.querySelector('[data-workspaces] ' + sel); if (el) el.focus(); }); }
  return h('div', { class: 'wsl-page', 'data-workspaces': '' },
    h('div', { class: 'head' }, h('h1', null, 'Workspaces')),
    h('p', { class: 'sub' }, plural(all.length, 'workspace', 'workspaces') + ' on this Mac.'), toolbar, body);
}

/// Its picture, a link to its Home (the name beside it is the link the keyboard reaches); with no file, the small tile alone
/// (in the grid a thin band, a quarter of a drawing's height).
function pic(w) {
  const t = spaceThumb(w, 'list');
  return h('a', { href: workspaceHash(w.name), class: 'wsl-pic' + (w.space ? '' : ' is-plain'), tabindex: '-1', 'aria-hidden': 'true' }, t);
}
const lastText = (w) => (w.lastAt ? h('span', { class: 'wsl-last', title: full(w.lastAt) }, 'active ' + when(w.lastAt)) : h('span', { class: 'wsl-last muted' }, 'no activity yet'));
const roomLink = (w) => (w.room ? h('a', { href: roomHash(w.name), class: 'hm-room' }, '# ' + w.room) : h('span', { class: 'muted' }, 'no room'));
const working = (w) => (w.working && w.working.length ? w.working.join(', ') + ' working' : w.working ? 'nobody working' : '');

function row(w) {
  const folders = w.folders.length ? w.folders.map((p) => h('span', { class: 'hm-folder' }, tildePath(p))) : [h('span', { class: 'hm-folder muted' }, 'no folder')];
  return h('li', { class: 'wsl-row', 'data-wsl': w.name },
    pic(w),
    h('div', { class: 'wsl-main' },
      h('div', { class: 'wsl-top' }, h('a', { href: workspaceHash(w.name), class: 'wsl-name' }, w.name), workspacePill(w.state, w.words, transitional(w.name)),
        driverChip(w.driver), w.manager ? managerChip(w.manager) : null),
      h('div', { class: 'wsl-meta' }, working(w) ? h('span', null, working(w)) : null, ...folders),
      h('div', { class: 'wsl-meta' }, roomLink(w), lastText(w))),
    h('div', { class: 'wsl-next' }, wsNext(w, null)));
}

function card(w) {
  return h('li', { class: 'wsl-card', 'data-wsl': w.name },
    pic(w),
    h('div', { class: 'wsl-card-body' },
      h('div', { class: 'wsl-top' }, h('a', { href: workspaceHash(w.name), class: 'wsl-name' }, w.name), workspacePill(w.state, w.words, transitional(w.name))),
      w.manager ? h('div', { class: 'wsl-meta' }, managerChip(w.manager)) : null,
      h('div', { class: 'wsl-meta' }, w.working ? h('span', null, w.working.length + ' working') : null, lastText(w)),
      h('div', { class: 'wsl-meta' }, roomLink(w)),
      h('div', { class: 'wsl-next' }, wsNext(w, null))));
}
