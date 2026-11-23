// views/ws-activity — A workspace's Activity tab (#/w/NAME/activity): its log in pages, newest first (`POST
// /api/v1/workspace-activity` — one page of `workspace-log`; Load older asks the page before the oldest line), merged with
// the operations this dashboard started for its agents (`/api/v1/operations`: the last 50, filtered here — core/ws-activity.js
// `mergeActivity`), filtered All · You · Agents · Lifecycle · Network. Read afresh on every visit; a `changed` event or an
// operation's end reads the newest page again (the pages loaded stay).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { api } from '../core/api-47cfabfed13b475c.js';
import { clock, full, when } from '../core/format-b2e68384da8d2f36.js';
import { state } from '../core/state-1036883eb74b9520.js';
import { ACTIVITY_FILTERS, mergeActivity } from '../core/ws-activity-dc03f4d9a1f02811.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { cmdLine } from '../components/cmd-line-e4888d1119b3caa7.js';

const PAGE = 200;
let cur = null;     // {name, lines, first, more, hidden, ops, filter, host, places}

async function page(name, before) {
  return api('workspace-activity', { method: 'POST', json: before != null ? { workspace: name, before, limit: PAGE } : { workspace: name, limit: PAGE } });
}

/// Lines merged once each (a line is the same when its time, action, agent and words are).
function mergeLines(have, add) {
  const key = (l) => [l.at, l.action, l.agent || '', l.text].join('|');
  const seen = new Set(have.map(key));
  return [...have, ...add.filter((l) => !seen.has(key(l)))];
}

function draw() {
  const c = cur;
  const items = mergeActivity(c.lines, c.ops, c.name, c.places, c.filter);
  const filters = h('span', { class: 'segmented wsc-filters', role: 'group', 'aria-label': 'Show' }, ...ACTIVITY_FILTERS.map((f) =>
    h('button', { type: 'button', class: 'seg' + (f.id === c.filter ? ' active' : ''), 'aria-pressed': f.id === c.filter ? 'true' : 'false', 'data-wsc-filter': f.id,
      on: { click: () => { c.filter = f.id; draw(); } } }, f.label)));
  const list = items.length ? h('ol', { class: 'wsc-list', 'data-wsc-count': String(items.length) }, ...items.map((x) => h('li', { 'data-wsc-kind': x.kind, 'data-action': x.action, 'data-id': x.id || null },
    h('span', { class: 'wsc-time', title: full(x.at) }, new Date(x.at).toDateString() === new Date().toDateString() ? clock(x.at) : full(x.at)),
    h('span', { class: 'wsc-who' }, x.kind === 'op' ? h('span', { class: 'ws-chip' }, icon('activity'), 'operation') : x.by === 'you' ? 'you' : 'Dozable'),
    h('span', { class: 'wsc-text' }, x.text, x.kind === 'op' && x.state !== 'done' ? h('span', { class: 'pill' }, x.state) : null))))
    : h('p', { class: 'muted', 'data-wsc-count': '0' }, 'Nothing here.');
  const older = c.more ? h('button', { type: 'button', class: 'btn sm', 'data-wsc-older': String(c.first), on: { click: loadOlder } }, 'Load older') : null;
  c.host.replaceChildren(h('div', { class: 'wsc', 'data-ws-activity': c.name },
    h('div', { class: 'wsa-tools' }, filters, h('span', { class: 'ws-sp' }), h('span', { class: 'muted' }, c.lines.length + ' log line' + (c.lines.length === 1 ? '' : 's') + ' read')),
    list, older,
    c.hidden ? h('p', { class: 'muted', 'data-wsc-hidden': String(c.hidden) }, c.hidden + ' lines about sessions on this Mac are not shown to this browser.') : null,
    h('p', { class: 'muted' }, 'Operations: those started from this dashboard, the last 50. The log is everything the workspace’s record says happened, ',
      'newest first' + (c.lines.length ? ' — the oldest read ' + when(c.lines[c.lines.length - 1].at) : '') + '.'),
    h('div', { class: 'cando-cmds' }, cmdLine('doz workspace log ' + c.name + ' --limit ' + PAGE))));
}

async function loadOlder() {
  const c = cur;
  if (!c || c.first == null) return;
  try {
    const p = await page(c.name, c.first);
    if (cur !== c) return;
    c.lines = mergeLines(c.lines, p.lines);
    c.first = p.first; c.more = p.more; c.hidden += p.hidden;
    draw();
  } catch (e) { c.host.prepend(callout('bad', { compact: true, body: e.message || String(e) })); }
}

/// The tab, drawn into `host`. `fresh` false (a `changed` event, an operation's end): the newest page again, merged into
/// what is loaded; else everything read afresh.
export async function activityTab(name, host, places, fresh = true) {
  let p, ops;
  try { [p, ops] = await Promise.all([page(name), api('operations').catch(() => [])]); } catch (e) {
    host.replaceChildren(callout('bad', { title: 'Its activity could not be read', body: e.message || String(e) }));
    return;
  }
  if (fresh || !cur || cur.name !== name) cur = { name, lines: p.lines, first: p.first, more: p.more, hidden: p.hidden, ops: [], filter: (cur && cur.name === name && cur.filter) || 'all', host, places };
  else { cur.lines = mergeLines(p.lines, cur.lines); cur.host = host; cur.places = places; }
  cur.ops = Array.isArray(ops) ? ops : [];
  draw();
}
/// Whether the tab is showing (for the page's refresh).
export function activityShown() { return !!cur && state.view === 'workspace' && state.wsTab === 'activity'; }
