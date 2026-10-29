// views/overview — Sandboxes (the overview).
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon, mark, QUEUED_GLYPH } from '../dom/icons-9b284ea0ffb2ad04.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { api } from '../core/api-91016dbc2d27b20b.js';
import { bytes, mib } from '../core/format-b2e68384da8d2f36.js';
import { act, cancelOps } from '../core/operations-03d7dd105dcc61d2.js';
import { opRunningFor, PRIMARY_VERB, VERBS, verbsFor } from '../core/sandboxes-cb48eb6f1ec4e42f.js';
import { setting } from '../core/settings-353cfb79867783e4.js';
import { state } from '../core/state-2d94fd2b00c043b7.js';
import { card, meter, panel } from '../components/blocks-6b2d43608253a84f.js';
import { btn } from '../components/button-8109d54546d946d3.js';
import { dialog } from '../components/dialog-6d072078840e0e8c.js';
import { hostCard } from '../components/host-fff2510d6caf1122.js';
import { rowLifecycle } from '../components/lifecycle-ba62b68bdffd9011.js';
import { inTabOrder, renderNavSandboxes, sessionGlyph } from '../components/nav-4bb64c7e1ee51864.js';
import { hoverPeek } from '../components/nav-peek-ea9ef4157799036d.js';
import { paintRowOps } from '../components/notices-3fe56a3dbeb21a8c.js';
import { sandboxPill } from '../components/pills-a9d7d9ecb0cab5a8.js';
import { quickAddButton } from '../components/quick-add-0eec98ed7b8800cc.js';
import { thumbFrame } from '../components/session-thumb-15c86e68709456d7.js';
import { ISOLATED_NOTE } from '../components/workspace-chooser-a0962944605ba369.js';
import { newSandboxWizard } from './new-sandbox-ab8bacd03ef4e716.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const refresh = upcall('refresh');

/// 642 (owner): the page as drawn — patched in place on a refresh while it is shown, so a sandbox's row of session
/// pictures is never rebuilt. `strips`: each sandbox's.
const OV = { root: null, top: null, listHead: null, bulk: null, thead: null, tbody: null, list: [], strips: new Map() };
/// 642 (owner): the sandboxes ticked in the left margin, for the bulk controls (this page only).
const SEL = new Set();
/// 650: the operations the bulk controls started (each marked `batch`: it waits behind a person's own).
const BATCH = new Set();

// ── views ───────────────────────────────────────────────────────────────────
export async function viewOverview() {
  const o = await api('overview');
  state.overview = o;
  renderNavSandboxes();
  OV.list = o.sandboxes;
  for (const n of [...SEL]) if (!o.sandboxes.some((s) => s.name === n)) SEL.delete(n);
  const top = h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Sandboxes'),
      // 617 (owner): Quick try is the nav's TRY section now (its item and its +), not a button here.
      h('div', { class: 'actions' }, quickAddButton(), (() => {
        const b = btn('New sandbox', () => newSandboxWizard(), { primary: true, title: 'Step by step — your choices go in the project folder’s doz_project.yaml' });
        b.dataset.newSandbox = '';
        return b;
      })())),
    h('p', { class: 'sub' }, o.source === 'host' ? 'Live from the host.' : 'No host is running: read from the store (nothing is live). An action starts the host.'),
    h('div', { class: 'stats' },
      hostCard(o.host),
      card('Sandboxes', String(o.totals.sandboxes), o.totals.live + ' with a VM'),
      card('RAM held', mib(o.totals.ramHeldMiB), 'charged to this Mac now'),
      card('Disk', bytes(o.totals.diskBytes), 'allocated, all sandboxes')));
  if (!o.sandboxes.length) {
    dropStrips();
    OV.root = null;
    return h('div', null, top, h('h2', null, 'All sandboxes'),
      h('div', { class: 'panel' }, h('div', { class: 'empty-big' }, icon('box'), h('div', { class: 'e-title' }, 'No sandboxes yet'),
        h('p', null, 'A sandbox is a small Linux VM for one project. Quick add makes one with every default; New sandbox walks through each choice. In a terminal: doz new, or doz init then doz up.'),
        h('div', { class: 'actions center' }, quickAddButton()))));
  }
  const listHead = listHeadEl();
  const bulk = bulkBar();
  const thead = tableHead();
  // A refresh while the page is shown: the same table, its rows replaced in place and the pictures kept.
  if (OV.root && OV.root.isConnected) {
    OV.top.replaceWith(top); OV.listHead.replaceWith(listHead); OV.bulk.replaceWith(bulk); OV.thead.replaceWith(thead);
    Object.assign(OV, { top, listHead, bulk, thead });
    patchRows(o.sandboxes);
    paintRowOps();
    return null;
  }
  dropStrips();
  // No session column: counting sessions asks every session's holder in the guest, and this list
  // is kept live — sessions are on each sandbox's page (590 bug 3).
  const tbody = h('tbody');
  Object.assign(OV, { top, listHead, bulk, thead, tbody });
  OV.root = h('div', { 'data-overview': '' }, top, listHead, bulk, panel(h('table', { class: 'ov-table' }, thead, tbody)));
  patchRows(o.sandboxes);
  return OV.root;
}

function mainRow(s) {
  const box = h('input', { type: 'checkbox', 'aria-label': 'Select ' + s.name, 'data-ov-select': s.name,
    on: { click: (ev) => ev.stopPropagation(), change: (ev) => { if (ev.target.checked) SEL.add(s.name); else SEL.delete(s.name); repaintSelection(); } } });
  box.checked = SEL.has(s.name);
  return h('tr', { class: 'click', 'data-sandbox-row': s.name, on: { click: () => { location.hash = '#/sandbox/' + s.name; } } },
    h('td', { class: 'ov-sel', on: { click: (ev) => ev.stopPropagation() } }, box),
    // Owner, 2026-10-23: the tool's mark beside the name, and where its workspace is (from ~).
    h('td', null, h('div', { class: 'ov-name' }, s.icon && s.icon.d ? mark(s.icon, 'ov-mark') : icon('box'),
      h('a', { class: 'name', href: '#/sandbox/' + s.name }, s.name)),
      h('div', { class: 'sub2' }, s.image),
      s.workspace
        ? h('div', { class: 'sub2 ov-ws', 'data-ov-ws': '', title: s.workspace }, icon('folder'), h('span', null, tildePath(s.workspace)))
        : h('div', { class: 'sub2 no-ws', 'data-isolated': '', title: ISOLATED_NOTE }, 'isolated — no shared folder'),
      h('div', { 'data-op-for': s.name })),
    h('td', null, sandboxPill(s), s.diedWithHost ? h('div', { class: 'st-warn sub2' }, 'died with its host') : null),
    // 642 (owner): without the rows of pictures, a Sessions column — its pictures as a grid in a 4:3 box (kept across refreshes).
    subRows() ? null : h('td', { class: 'ov-sess', 'data-ov-sess': s.name }, h('span', { class: 'muted' }, '—')),
    h('td', { class: 'num' }, h('div', null, s.ramHeldMiB ? mib(s.ramHeldMiB) : '—'), h('div', { class: 'sub2' }, 'of ' + mib(s.memoryMiB)), meter(s.ramHeldMiB, s.memoryMiB)),
    h('td', { class: 'num' }, bytes(s.diskBytes)),
    h('td', null, s.network, s.deniedConnections ? [' ', h('span', { class: 'tag warn' }, s.deniedConnections + ' denied')] : null),
    s.accountApplies
      ? h('td', null, s.account || '—', s.credentialState ? h('div', { class: (s.credentialState === 'ok' ? 'st-ok' : 'st-warn') + ' sub2' }, s.credentialState) : null,
        s.foreignCredentials ? h('div', { class: 'st-warn sub2' }, s.foreignCredentials + ' own credential(s)') : null)
      : h('td', { class: 'muted', title: 'its network cannot reach an account’s API' }, 'n/a'),
    h('td', { class: 'row-acts-cell' }, rowLifecycle(s)));
}
const cols = () => (subRows() ? 8 : 9);
function tableHead() {
  const all = h('input', { type: 'checkbox', 'aria-label': 'Select every sandbox', 'data-ov-select-all': '',
    on: { change: (ev) => { SEL.clear(); if (ev.target.checked) for (const s of OV.list) SEL.add(s.name); repaintSelection(); } } });
  const n = OV.list.filter((s) => SEL.has(s.name)).length;
  all.checked = n > 0 && n === OV.list.length;
  all.indeterminate = n > 0 && n < OV.list.length;
  const names = subRows() ? ['Sandbox', 'Phase', 'RAM held', 'Disk', 'Network', 'Account'] : ['Sandbox', 'Phase', 'Sessions', 'RAM held', 'Disk', 'Network', 'Account'];
  return h('thead', null, h('tr', null, h('th', { class: 'ov-sel' }, all),
    names.map((c) => h('th', { class: c === 'RAM held' || c === 'Disk' ? 'num' : null }, c)), h('th', null, h('span', { class: 'sr-only' }, 'Actions'))));
}

// ── 642 (owner): each sandbox's sessions as pictures — a row under it (on by default; this browser remembers), else a
// grid of small ones in its Sessions cell. Resting on one shows it larger (components/nav-peek.js). ─────────────────
function subRows() { try { return localStorage.getItem('doz.overview.thumbs') !== 'off'; } catch (_) { return true; } }
function listHeadEl() {
  return h('div', { class: 'head has-title ov-list-head' }, h('h2', null, 'All sandboxes'), h('div', { class: 'actions' }, thumbsToggle()));
}
function thumbsToggle() {
  const box = h('input', { type: 'checkbox', 'data-ov-thumbs': '',
    on: { change: (ev) => {
      try { localStorage.setItem('doz.overview.thumbs', ev.target.checked ? 'on' : 'off'); } catch (_) { /* this page only */ }
      dropStrips(); OV.root = null; refresh(false);   // the other layout: the table drawn anew
    } } });
  box.checked = subRows();
  return h('label', { class: 'ov-toggle', title: 'Each sandbox’s session pictures in a row under it — off: small, in a Sessions column' }, box, 'Thumbnails under each sandbox');
}
/// The sessions a sandbox shows pictures of: a running one's (live), a sleeping one's (saved) — never a shut-down one's.
function stripSessions(s) {
  if (!['running', 'paused', 'asleep', 'hibernated'].includes(s.phase)) return [];
  return inTabOrder(s.name, s.sessionList || []).filter((x) => x.saved || s.phase === 'running');
}
/// The Sessions cell's box (CSS px): 4:3, its pictures in the squarest grid that holds them all.
const CELL_W = 128, CELL_H = 96, CELL_GAP = 2;
function layoutGrid(st, n) {
  const colsN = Math.ceil(Math.sqrt(n)), rows = Math.ceil(n / colsN);
  const tw = Math.floor(Math.min((CELL_W - (colsN - 1) * CELL_GAP) / colsN, ((CELL_H - (rows - 1) * CELL_GAP) / rows) * 4 / 3));
  st.box.style.setProperty('--tw', tw + 'px');
  st.box.style.gridTemplateColumns = 'repeat(' + colsN + ', ' + tw + 'px)';
  st.box.title = n + ' session' + (n === 1 ? '' : 's');
}
/// An existing row brought up to `nu`: every cell replaced but the Sessions cell (its pictures stay where they are).
function patchRow(old, nu) {
  const a = [...old.cells], b = [...nu.cells];
  if (a.length !== b.length) { old.replaceWith(nu); return nu; }
  a.forEach((c, i) => { if (!c.classList.contains('ov-sess')) c.replaceWith(b[i]); });
  return old;
}
/// Bring the table's rows to `list`: each main row replaced where it stands, each strip kept (its pictures with it).
function patchRows(list) {
  const names = new Set(list.map((s) => s.name));
  for (const tr of [...OV.tbody.querySelectorAll('tr[data-sandbox-row]')]) if (!names.has(tr.dataset.sandboxRow)) tr.remove();
  for (const [n] of OV.strips) if (!names.has(n)) dropStrip(n);
  const rows = subRows();
  let prev = null;
  for (const s of list) {
    let tr = mainRow(s);
    const old = OV.tbody.querySelector('tr[data-sandbox-row="' + CSS.escape(s.name) + '"]');
    if (old) tr = patchRow(old, tr); else if (prev) prev.after(tr); else OV.tbody.prepend(tr);
    prev = tr;
    const sessions = stripSessions(s);
    if (!sessions.length) { dropStrip(s.name); continue; }
    let st = OV.strips.get(s.name);
    if (!st) {
      st = { name: s.name, thumbs: new Map(), phase: s.phase, busy: false,
        box: h('div', { class: rows ? 'ov-strip-box' : 'ov-grid', role: 'list', 'aria-label': s.name + '’s sessions' }) };
      if (rows) st.tr = h('tr', { class: 'ov-strip', 'data-ov-strip': s.name },
        h('td', { class: 'ov-sel' }), h('td', { colspan: String(cols() - 1) }, st.box));
      OV.strips.set(s.name, st);
    }
    if (rows) {
      if (tr.nextElementSibling !== st.tr) tr.after(st.tr);
      tr.classList.add('has-strip');
      prev = st.tr;
    } else {
      const td = tr.querySelector('td.ov-sess');
      if (td && st.box.parentNode !== td) td.replaceChildren(st.box);
    }
    st.phase = s.phase;
    st.busy = !!s.busy || opRunningFor(s.name);
    const keep = new Set(sessions.map((x) => x.name));
    for (const [k, th] of st.thumbs) if (!keep.has(k)) { th.source.drop(); th.wrap.remove(); st.thumbs.delete(k); }
    for (const x of sessions) {
      let th = st.thumbs.get(x.name);
      if (!th) {
        th = thumbFrame('Open ' + x.name, () => { location.hash = '#/sandbox/' + s.name + '/' + x.name; }, false);
        th.session = x.name;
        const t = th;
        hoverPeek(th.el, s.name, () => t.row);
        th.wrap = rows
          ? h('div', { class: 'ov-th', role: 'listitem', 'data-ov-thumb': x.name }, th.el,
            h('div', { class: 'ov-th-name', title: x.program + ' · ' + x.name }, sessionGlyph(x), h('span', null, x.name)))
          : h('div', { class: 'ov-tile', role: 'listitem', 'data-ov-thumb': x.name }, th.el);
        st.thumbs.set(x.name, th);
        st.box.append(th.wrap);
      }
      th.row = x;
    }
    if (!rows) layoutGrid(st, st.thumbs.size);
  }
  schedule();
}
function dropStrip(name) {
  const st = OV.strips.get(name);
  if (!st) return;
  for (const th of st.thumbs.values()) th.source.drop();
  if (st.tr) st.tr.remove();
  else if (st.box.parentNode) st.box.parentNode.replaceChildren(h('span', { class: 'muted' }, '—'));
  OV.strips.delete(name);
  const tr = OV.tbody && OV.tbody.querySelector('tr[data-sandbox-row="' + CSS.escape(name) + '"]');
  if (tr) tr.classList.remove('has-strip');
}
function dropStrips() { for (const n of [...OV.strips.keys()]) dropStrip(n); }

// The pictures (648: painted — components/session-thumb.js): EVERY picture is live — a running sandbox's from the host's
// feed, polled only while it is on screen and this page is shown; a sleeping one's from its saved screen; never a
// shut-down one's. No engine, no socket: nothing to cap, nothing to take turns.
let scheduled = false;
function schedule() {
  if (scheduled) return;
  scheduled = true;
  setTimeout(() => { scheduled = false; placeThumbs(); }, 40);
}
function placeThumbs() {
  if (!OV.root || !OV.root.isConnected || state.view !== 'overview') { dropStrips(); return; }
  if (state.modal) return;                                       // a wizard over the page: the pictures stay as they are
  const on = setting('ui.terminals', true);
  for (const st of OV.strips.values()) for (const th of st.thumbs.values()) {
    const running = st.phase === 'running' && !st.busy;
    th.source.want(!on ? null : th.row.saved ? { kind: 'saved', sandbox: st.name, session: th.session, savedAt: th.row.savedAt || null }
      : running ? { kind: 'live', sandbox: st.name, session: th.session } : null);
  }
}
// Leaving the page lets every picture go.
window.addEventListener('hashchange', () => setTimeout(schedule, 0));

// ── 642 (owner): the bulk controls — on the ticked sandboxes, or all of them when none is ticked ─────────────────────
/// Each control: the verb it asks of a sandbox in its phase (null: not for that one).
const BULK = [
  { key: 'up', label: 'Start', icon: 'play', desc: 'Start, resume or wake each one', verb: (s) => PRIMARY_VERB[s.phase] || null },
  { key: 'pause', label: 'Pause', icon: 'pause', verb: (s) => (verbsFor(s.phase).includes('pause') ? 'pause' : null) },
  { key: 'sleep', label: 'Sleep', icon: 'moon+cpu', verb: (s) => (verbsFor(s.phase).includes('sleep') ? 'sleep' : null) },
  { key: 'hibernate', label: 'Hibernate', icon: 'moon+cylinder', verb: (s) => (verbsFor(s.phase).includes('hibernate') ? 'hibernate' : null) },
  { key: 'shutdown', label: 'Shut down', icon: 'power', danger: true, verb: (s) => (verbsFor(s.phase).includes('shutdown') ? 'shutdown' : null) },
];
function targets() {
  const picked = OV.list.filter((s) => SEL.has(s.name));
  return picked.length ? picked : OV.list;
}
function bulkBar() {
  const t = targets();
  const n = OV.list.filter((s) => SEL.has(s.name)).length;
  const free = (s) => !s.busy && s.phase !== 'booting' && !opRunningFor(s.name) && !state.transitions.has(s.name);
  const buttons = BULK.map((b) => {
    const jobs = t.filter(free).map((s) => [s.name, b.verb(s)]).filter(([, v]) => v);
    const what = b.desc || (VERBS[b.key] ? VERBS[b.key][1] : '');
    const el = btn(b.label + (jobs.length ? ' ' + jobs.length : ''), () => runBulk(b, jobs), { small: true, quiet: !b.danger, danger: !!b.danger, icon: b.icon,
      title: jobs.length ? what + ' — ' + jobs.map(([x]) => x).join(', ') : 'None of ' + (n ? 'the selected' : 'them') + ' can ' + b.label.toLowerCase() + ' now' });
    el.disabled = !jobs.length;
    el.dataset.ovBulk = b.key;
    return el;
  });
  // 650: what of the batches started here still waits its turn — said, with one Cancel for them all.
  const waiting = [...BATCH].map((id) => state.ops.get(id)).filter((o) => o && o.state === 'running' && o.queued);
  for (const id of [...BATCH]) { const o = state.ops.get(id); if (!o || o.state !== 'running') BATCH.delete(id); }
  return h('div', { class: 'ov-bulk', 'data-ov-bulk-bar': '' },
    h('span', { class: 'ob-what' }, n ? n + ' selected' : 'All ' + OV.list.length + ' sandboxes'),
    n ? h('button', { type: 'button', class: 'btn sm quiet', on: { click: () => { SEL.clear(); repaintSelection(); } } }, 'Clear') : null,
    h('span', { class: 'btn-group', role: 'group', 'aria-label': n ? 'For the selected sandboxes' : 'For every sandbox' }, buttons.slice(0, 4)),
    waiting.length ? h('span', { class: 'ob-queued', 'data-ov-queued': String(waiting.length) },
      h('span', { class: 'wait-mark', 'aria-hidden': 'true' }, icon(QUEUED_GLYPH)), waiting.length + ' queued',
      btn('Cancel all', () => cancelOps(waiting.map((o) => o.id)), { small: true, quiet: true, title: 'Withdraw every one still waiting — nothing was done for them yet' })) : null,
    buttons[4]);
}
function runBulk(b, jobs) {
  const go = () => Promise.all(jobs.map(([name, verb]) => act({ action: verb, sandbox: name, batch: true }).then((op) => { if (op) BATCH.add(op.id); }))).then(() => repaintSelection());
  if (!b.danger) { go(); return; }
  dialog('Shut down ' + jobs.length + ' sandbox' + (jobs.length === 1 ? '' : 'es') + '?', 'Running programs end in ' + jobs.map(([x]) => x).join(', ')
    + '; each disk is kept. Start cold-boots the same disk.', [], 'Shut down', async () => { await go(); }, { danger: true });
}
function repaintSelection() {
  if (!OV.root || !OV.root.isConnected) return;
  const bulk = bulkBar(), thead = tableHead();
  OV.bulk.replaceWith(bulk); OV.thead.replaceWith(thead);
  OV.bulk = bulk; OV.thead = thead;
  for (const box of OV.tbody.querySelectorAll('input[data-ov-select]')) box.checked = SEL.has(box.dataset.ovSelect);
}
