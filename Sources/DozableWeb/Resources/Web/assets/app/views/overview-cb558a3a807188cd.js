// views/overview — Sandboxes (the overview).
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon, mark } from '../dom/icons-0a9984f90615977d.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { api } from '../core/api-0560a03cb0de25ef.js';
import { bytes, mib } from '../core/format-b2e68384da8d2f36.js';
import { act } from '../core/operations-773ff6e3f3377064.js';
import { opRunningFor, PRIMARY_VERB, VERBS, verbsFor } from '../core/sandboxes-a8ce08093e702ad4.js';
import { setting } from '../core/settings-f00434ef195e82b4.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { card, meter, panel } from '../components/blocks-6b2d43608253a84f.js';
import { btn } from '../components/button-f435595b4098d043.js';
import { dialog } from '../components/dialog-ee9a9a31b03dc349.js';
import { hostCard } from '../components/host-50f984429c6d7ea9.js';
import { rowLifecycle } from '../components/lifecycle-8b27035aea7b7d2b.js';
import { inTabOrder, renderNavSandboxes, sessionGlyph } from '../components/nav-8ff005d496c3ab03.js';
import { hoverPeek } from '../components/nav-peek-4a456b9466f848e1.js';
import { paintRowOps } from '../components/notices-90920b2aaea4c446.js';
import { sandboxPill } from '../components/pills-d7769a342034f780.js';
import { quickAddButton } from '../components/quick-add-c6046f005ed78bfd.js';
import { livePrefs, liveControls as sharedLiveControls, liveTurn, paintLiveStatus, SOCKET_CEILING } from '../components/live-controls-b9444b0cdb9b456a.js';
import { dropThumbTerm, openSockets, paintThumb, thumbFrame, thumbFreeze, thumbGoLive, thumbTerm, thumbThaw } from '../components/session-thumb-0d5a39a79157577e.js';
import { ISOLATED_NOTE } from '../components/workspace-chooser-35cbe6cb454a56e1.js';
import { newSandboxWizard } from './new-sandbox-e9981ed82979c21e.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const refresh = upcall('refresh');

/// 642 (owner): the page as drawn — patched in place on a refresh while it is shown, so a sandbox's row of session
/// pictures is never rebuilt (moving or rebuilding a picture's frame reloads its engine). `strips`: each sandbox's.
const OV = { root: null, top: null, listHead: null, bulk: null, thead: null, tbody: null, list: [], strips: new Map(), io: null };
/// 642 (owner): the sandboxes ticked in the left margin, for the bulk controls (this page only).
const SEL = new Set();
/// At most this many live pictures (and never past ui.grid_live_tiles), never past SOCKET_CEILING of the UI's 16 sockets.
/// Past the live cap a running session shows its last captured screen (no socket) — up to SAVED_MAX pictures in all.
const LIVE_MAX = 8, SAVED_MAX = 48;

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
  return h('tr', { class: 'click', 'data-sandbox-row': s.name, on: { click: () => { location.hash = '#/sandbox/' + s.name; },
    pointerenter: () => setHover(s.name), pointerleave: () => setHover(null) } },
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
  return h('div', { class: 'head has-title ov-list-head' }, h('h2', null, 'All sandboxes'), h('div', { class: 'actions' }, liveControls(), thumbsToggle()));
}
function redrawListHead() {
  if (!OV.listHead || !OV.listHead.isConnected) return;
  const lh = listHeadEl();
  OV.listHead.replaceWith(lh);
  OV.listHead = lh;
}
/// 642 (owner): Live − N + (how many pictures are live at once) · Cycle (they take turns) · − S s + (each turn).
function liveControls() {
  return sharedLiveControls(LIVE, (what) => { if (what !== 'limit') { stopCycle(); OV.turn = 0; } redrawListHead(); schedule(); });
}
function paintCycleStatus() { paintLiveStatus(OV.listHead, LIVE, OV.cand || 0); }
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
  st.box.style.setProperty('--ts', String(tw / 960));
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
      if (rows) st.tr = h('tr', { class: 'ov-strip', 'data-ov-strip': s.name, on: { pointerenter: () => setHover(s.name), pointerleave: () => setHover(null) } },
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
    for (const [k, th] of st.thumbs) if (!keep.has(k)) { dropThumbTerm(th.term); io().unobserve(th.el); th.wrap.remove(); st.thumbs.delete(k); }
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
        io().observe(th.el);
      }
      th.row = x;
    }
    if (!rows) layoutGrid(st, st.thumbs.size);
  }
  schedule();
}
function io() {
  if (!OV.io) OV.io = new IntersectionObserver((entries) => {
    for (const e of entries) for (const st of OV.strips.values()) for (const th of st.thumbs.values()) if (th.el === e.target) th.visible = e.isIntersecting;
    schedule();
  }, { rootMargin: '60px' });
  return OV.io;
}
function dropStrip(name) {
  const st = OV.strips.get(name);
  if (!st) return;
  for (const th of st.thumbs.values()) { dropThumbTerm(th.term); io().unobserve(th.el); }
  if (st.tr) st.tr.remove();
  else if (st.box.parentNode) st.box.parentNode.replaceChildren(h('span', { class: 'muted' }, '—'));
  OV.strips.delete(name);
  const tr = OV.tbody && OV.tbody.querySelector('tr[data-sandbox-row="' + CSS.escape(name) + '"]');
  if (tr) tr.classList.remove('has-strip');
}
function dropStrips() { for (const n of [...OV.strips.keys()]) dropStrip(n); }

// The pictures: live only while the page is shown and the picture is on screen; capped (as the sandbox Home's are).
let scheduled = false;
function schedule() {
  if (scheduled) return;
  scheduled = true;
  setTimeout(() => { scheduled = false; placeThumbs(); }, 40);
}
function shown() {
  return !!OV.root && OV.root.isConnected && state.view === 'overview' && !state.modal && document.visibilityState === 'visible' && setting('ui.terminals', true);
}
/// 642 (owner): how many pictures are live at once (this browser; ui.grid_live_tiles until changed), whether the live
/// ones take turns, and how long each turn is.
const LIVE = livePrefs('overview', LIVE_MAX);
function liveLimit() { return LIVE.limit(); }
function cycleOn() { return LIVE.cycle(); }
function startCycle() { if (!OV.cycleTimer) OV.cycleTimer = setInterval(() => { OV.turn = (OV.turn || 0) + 1; placeThumbs(); }, LIVE.hold() * 1000); }
function stopCycle() { clearInterval(OV.cycleTimer); OV.cycleTimer = null; }
/// 642 (owner): the sandbox under the pointer — its pictures are live first.
function setHover(name) { if (OV.hover !== name) { OV.hover = name; schedule(); } }

function placeThumbs() {
  const on = shown();
  const all = [];
  for (const st of OV.strips.values()) for (const th of st.thumbs.values()) all.push([st, th]);
  // The hovered sandbox's pictures first: they take the live slots before any other.
  if (OV.hover) all.sort((a, b) => (b[0].name === OV.hover) - (a[0].name === OV.hover));
  const want = (st, th) => (th.row.saved ? 'saved' : st.phase === 'running' && !st.busy ? 'live' : null);
  for (const [st, th] of all) {
    const w = want(st, th);
    if (th.term && (!on || !th.visible || !w || (w === 'saved' && th.kind !== 'saved'))) { dropThumbTerm(th.term); th.term = null; th.kind = null; }
  }
  if (!on) { stopCycle(); if (!OV.root || !OV.root.isConnected) dropStrips(); return; }
  const cap = liveLimit();
  // Cycling: more running pictures on screen than live slots — the hovered sandbox's keep theirs, the rest take turns.
  const cand = all.filter(([st, th]) => th.visible && want(st, th) === 'live').map(([, th]) => th);
  const cycling = cycleOn() && cap > 0 && cand.length > cap;
  if (cycling) startCycle(); else stopCycle();
  // The pictures that hold a live slot now: the hovered sandbox's first; then, cycling, the next of the rest in turn —
  // else those already live, then the first in the page's order.
  const firm = all.filter(([st, th]) => st.name === OV.hover && cand.includes(th)).map(([, th]) => th);
  const turn = liveTurn(cand, firm, cap, cycling, OV.turn, (th) => th.kind === 'live');
  OV.cand = cand.length;
  paintCycleStatus();
  // A live picture whose turn is over (or past the limit) lets go of its socket and keeps its last frame.
  let live = 0;
  for (const [, th] of all) {
    if (!th.term || th.kind !== 'live') continue;
    if (turn.has(th)) live++;
    else { thumbFreeze(th.term); th.kind = 'frozen'; }
  }
  let savedN = all.filter(([, th]) => th.term && th.kind !== 'live').length;
  for (const [st, th] of all) {
    const w = want(st, th);
    let plate = '';
    if (!w) plate = 'no picture';
    else if (!th.visible) plate = '';
    else if (w === 'live') {
      const room = turn.has(th) && live < cap && openSockets() < SOCKET_CEILING;
      if (th.term && th.kind !== 'live' && room) { if (th.kind === 'frozen') thumbThaw(th.term); else thumbGoLive(th.term); th.kind = 'live'; live++; }
      else if (!th.term) {
        if (room) { th.term = thumbTerm(st.name, th.session, null, th.screen); th.kind = 'live'; live++; }
        // Past the live cap: its last captured screen (host.screen_capture_minutes — no socket), live once there is room.
        else if (savedN < SAVED_MAX) { th.term = thumbTerm(st.name, th.session, { savedAt: th.row.savedAt || null, savedReason: 'periodic' }, th.screen); th.kind = 'still'; savedN++; }
        else plate = 'Not live — Open';
      }
    } else if (w === 'saved' && !th.term) {
      if (savedN < SAVED_MAX) { th.term = thumbTerm(st.name, th.session, th.row, th.screen); th.kind = 'saved'; savedN++; }
      else plate = 'Show';
    }
    paintThumb(th, th.term ? (th.kind === 'still' ? 'saved' : th.kind) : null, plate);
  }
}
// Leaving the page (or hiding the tab) lets every picture go.
window.addEventListener('hashchange', () => setTimeout(schedule, 0));
document.addEventListener('visibilitychange', schedule);

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
  return h('div', { class: 'ov-bulk', 'data-ov-bulk-bar': '' },
    h('span', { class: 'ob-what' }, n ? n + ' selected' : 'All ' + OV.list.length + ' sandboxes'),
    n ? h('button', { type: 'button', class: 'btn sm quiet', on: { click: () => { SEL.clear(); repaintSelection(); } } }, 'Clear') : null,
    h('span', { class: 'btn-group', role: 'group', 'aria-label': n ? 'For the selected sandboxes' : 'For every sandbox' }, buttons.slice(0, 4)),
    buttons[4]);
}
function runBulk(b, jobs) {
  const go = () => Promise.all(jobs.map(([name, verb]) => act({ action: verb, sandbox: name })));
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
