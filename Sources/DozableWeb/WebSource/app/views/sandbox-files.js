// views/sandbox-files — 644: the sandbox page's Files tab — the tree of /workspace.
//
// Rules this module keeps:
//   · ONE persistent element per sandbox (the inspector's panels are rebuilt on every refresh; this one is re-inserted, so
//     what is open, selected and scrolled stays). A live refresh never re-lists: the first show, a watch batch (only the
//     folders it names), Refresh, a change made here (the folders it touched), an isolated sandbox coming to run.
//   · Names come from inside a sandbox — text only (the host made them inert). A name it had to alter is not changed here.
//   · The watch (643's stream) is open only while this tab is the shown tab of the visible page with the details open, and
//     only for a shared workspace; it names /workspace and every open folder. An isolated sandbox that does not run is
//     never asked anything (no list request: nothing can wake it).
//   · Which folders are open is the HOST's (files/tree), like the terminal layout. Changes are the typed actions
//     files-mkdir | files-new | files-move | files-rm; a delete asks with the one tick-box dialog.
import { $, h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { upcall } from '../core/hooks.js';
import { bytes } from '../core/format.js';
import { actOrThrow, waitOp } from '../core/operations.js';
import { tildePath } from '../core/paths.js';
import { isRemote } from '../core/session.js';
import { state } from '../core/state.js';
import { sview } from '../core/terminals.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { dialog } from '../components/dialog.js';
import { moreMenu } from '../components/menus.js';
import { failureFor, pageFailure, toast } from '../components/notices.js';

// Calls up the layers (provided by app.js — core/hooks.js):
const refreshSandbox = upcall('refreshSandbox');

const ROOT = '/workspace';
const MAX_OPEN = 63;                 // the host's FileTreeState.maximumExpanded (+ /workspace = the watch's 64)
const panels = new Map();
const guest = (rel) => (rel ? ROOT + '/' + rel : ROOT);
const relOf = (g) => (g === ROOT ? '' : g.startsWith(ROOT + '/') ? g.slice(ROOT.length + 1) : null);
const parentOf = (rel) => (rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '');
const join = (dir, name) => (dir ? dir + '/' + name : name);
const nameOf = (rel) => (rel ? rel.slice(rel.lastIndexOf('/') + 1) : ROOT);
const q = (rel) => 'path=' + encodeURIComponent(guest(rel));

function panelOf(name) {
  let P = panels.get(name);
  if (!P) {
    P = { name, lists: new Map(), expanded: new Set(), selected: '', focus: '', loaded: false, loading: false, es: null, esKey: '',
          retry: null, reopen: null, save: null, info: null, el: h('div', { class: 'files-panel', 'data-files': name }), drag: null };
    panels.set(name, P);
  }
  return P;
}

/// The panel for the sandbox page (called on every draw of its details): the same element, its facts updated.
export function filesPanel(name, d) {
  const P = panelOf(name);
  const i = d.info;
  const was = P.info;
  P.info = { workspace: i.workspace || null, phase: i.phase, busy: !!(i.busy || i.phase === 'booting') };
  const runs = (x) => x && x.phase === 'running' && !x.busy;
  // An isolated sandbox that came to run (or stopped): what was listed is not what is there now.
  if (!P.info.workspace && was && runs(was) !== runs(P.info)) { P.lists.clear(); P.loaded = false; }
  render(P);
  return P.el;
}

function shared(P) { return !!(P.info && P.info.workspace); }
function running(P) { return !!(P.info && P.info.phase === 'running' && !P.info.busy); }
/// What a change needs: a shared workspace (any phase) or a running isolated sandbox.
function changeWhy(P) {
  if (shared(P)) return null;
  if (!P.info || P.info.phase !== 'running') return 'Its files are inside it — changed while it runs';
  if (P.info.busy) return 'Wait until it settles';
  return null;
}
function shown(P) {
  return state.view === 'sandbox' && state.param === P.name && sview(P.name).inspTab === 'files' && P.el.isConnected
    && !($('sbx-body') && $('sbx-body').classList.contains('details-closed'));
}

/// Called whenever the tab, the page or the details may have changed: first look, and the watch.
export function syncFiles() {
  for (const P of panels.values()) {
    const on = shown(P);
    if (on && !P.loaded && !P.loading && (shared(P) || running(P))) load(P);
    syncWatch(P, on);
  }
}
window.addEventListener('hashchange', () => setTimeout(syncFiles, 0));

async function load(P) {
  P.loading = true;
  try {
    try { const t = await api('sandboxes/' + P.name + '/files/tree'); P.expanded = new Set(t.expanded || []); } catch (_) { /* none kept */ }
    await list(P, '');
    const open = [...P.expanded];
    for (let k = 0; k < open.length; k += 6) await Promise.all(open.slice(k, k + 6).map((r) => list(P, r)));
    P.loaded = true;
  } finally {
    P.loading = false;
    render(P);
    syncWatch(P, shown(P));
  }
}

/// One folder read again; a folder that is gone (or hidden now) is closed.
async function list(P, rel) {
  try {
    const l = await api('sandboxes/' + P.name + '/files?' + q(rel));
    P.lists.set(rel, l);
  } catch (e) {
    if (rel && e.status === 404 && P.expanded.has(rel)) { closeFolder(P, rel); return; }
    P.lists.set(rel, { error: e.message || String(e), code: e.code });
  }
}
async function relist(P, rels) {
  const want = [...new Set(rels)].filter((r) => r === '' || P.expanded.has(r));
  await Promise.all(want.map((r) => list(P, r)));
  render(P);
}
function relistAll(P) { return relist(P, ['', ...P.expanded]); }

function persist(P) {
  clearTimeout(P.save);
  P.save = setTimeout(() => {
    api('sandboxes/' + P.name + '/files/tree', { method: 'POST', json: { expanded: [...P.expanded] } }).catch(() => { /* kept in this page */ });
  }, 400);
}
function closeFolder(P, rel) {
  for (const r of [...P.expanded]) if (r === rel || r.startsWith(rel + '/')) P.expanded.delete(r);
  for (const r of [...P.lists.keys()]) if (r && (r === rel || r.startsWith(rel + '/'))) P.lists.delete(r);
  persist(P);
  scheduleWatch(P);
}
async function toggle(P, rel) {
  if (P.expanded.has(rel)) { closeFolder(P, rel); render(P); return; }
  if (P.expanded.size >= MAX_OPEN) { failureFor(P.name, 'At most ' + MAX_OPEN + ' folders are open at once — close one first'); return; }
  P.expanded.add(rel);
  render(P);
  await list(P, rel);
  persist(P);
  render(P);
  scheduleWatch(P);
}

// ── the watch: one stream per page, /workspace and every open folder ─────────────────────────────────────────────────
function scheduleWatch(P) { clearTimeout(P.reopen); P.reopen = setTimeout(() => syncWatch(P, shown(P)), 300); }
function stopWatch(P) {
  clearTimeout(P.retry);
  if (P.es) { P.es.close(); P.es = null; }
  P.esKey = '';
}
function syncWatch(P, on) {
  const rootOk = P.lists.get('') && !P.lists.get('').error;
  if (!on || !shared(P) || !rootOk) { stopWatch(P); return; }
  const folders = ['', ...[...P.expanded].sort()];
  const key = folders.join('\n');
  if (P.es && P.esKey === key) return;
  stopWatch(P);
  const es = new EventSource('/api/v1/sandboxes/' + P.name + '/files/watch?' + folders.map(q).join('&'));
  P.es = es;
  P.esKey = key;
  P.el.dataset.watching = String(folders.length);
  es.addEventListener('files', (ev) => {
    let b; try { b = JSON.parse(ev.data); } catch (_) { return; }
    if (b.resync) { relistAll(P); return; }
    relist(P, (b.folders || []).map(relOf).filter((r) => r !== null));
  });
  es.addEventListener('resync', () => { stopWatch(P); relistAll(P); scheduleWatch(P); });
  es.addEventListener('end', () => { stopWatch(P); });
  es.onerror = () => {
    if (P.es !== es) return;
    stopWatch(P);
    P.retry = setTimeout(() => { if (shown(P)) { relistAll(P).then(() => syncWatch(P, shown(P))); } }, 5000);
  };
}

// ── changes ─────────────────────────────────────────────────────────────────────────────────────────────────────────
/// One typed action, followed to its end; its failure is thrown (a dialog keeps it). Then the touched folders again.
async function change(P, body, touched) {
  const op = await actOrThrow({ ...body, sandbox: P.name });
  const done = await waitOp(op.id, 60000);
  if (!done || done.state === 'running') throw new Error('Still under way — see Operations');
  if (done.state === 'failed') throw new Error(done.text || 'It failed');
  await relist(P, touched);
  return done;
}
function validName(n) {
  if (!n || n === '.' || n === '..' || n.includes('/')) return 'One name, without /';
  if (new TextEncoder().encode(n).length > 255) return 'At most 255 bytes';
  return null;
}
function folderOfSelection(P) {
  const s = P.selected;
  if (s === '') return '';
  const kind = entryKind(P, s);
  return kind === 'folder' ? s : parentOf(s);
}
function entryKind(P, rel) {
  if (rel === '') return 'folder';
  const l = P.lists.get(parentOf(rel));
  const e = l && l.entries ? l.entries.find((x) => x.name === nameOf(rel)) : null;
  return e ? e.kind : null;
}
function newItem(P, kind, dir) {
  const label = kind === 'folder' ? 'New folder' : 'New file';
  dialog(label, 'In ' + guest(dir) + '.', [{ name: 'name', label: 'Name', required: true, placeholder: kind === 'folder' ? 'notes' : 'notes.md' }],
    'Create', async (v) => {
      const bad = validName(v.name);
      if (bad) throw new Error(bad);
      const rel = join(dir, v.name);
      if (dir && !P.expanded.has(dir)) { P.expanded.add(dir); persist(P); scheduleWatch(P); }
      await change(P, { action: kind === 'folder' ? 'files-mkdir' : 'files-new', path: guest(rel) }, [dir]);
      P.selected = rel; P.focus = rel;
      render(P);
    }, { icon: kind === 'folder' ? 'folder-plus' : 'file-plus' });
}
function renameItem(P, rel) {
  const dlg = dialog('Rename ' + nameOf(rel), 'In ' + guest(parentOf(rel)) + '. Nothing there is ever replaced.',
    [{ name: 'name', label: 'New name', required: true, value: nameOf(rel) }], 'Rename', async (v) => {
      const bad = validName(v.name);
      if (bad) throw new Error(bad);
      if (v.name === nameOf(rel)) return;
      await moveTo(P, rel, join(parentOf(rel), v.name));
    }, { icon: 'pencil' });
  const input = dlg.inputs.name;
  const dot = nameOf(rel).lastIndexOf('.');
  if (input) input.setSelectionRange(0, dot > 0 && entryKind(P, rel) !== 'folder' ? dot : input.value.length);
}
async function moveTo(P, rel, to) {
  await change(P, { action: 'files-move', path: guest(rel), to: guest(to) }, [parentOf(rel), parentOf(to)]);
  // what was open under it is open at its new place
  const moved = [...P.expanded].filter((r) => r === rel || r.startsWith(rel + '/'));
  for (const r of moved) { P.expanded.delete(r); P.expanded.add(to + r.slice(rel.length)); }
  if (moved.length) { persist(P); scheduleWatch(P); await relist(P, moved.map((r) => to + r.slice(rel.length))); }
  P.selected = to; P.focus = to;
  render(P);
}
/// The folders this panel knows (listed) — where Move… can put something.
function knownFolders(P, except) {
  const out = [''];
  for (const [dir, l] of P.lists) {
    if (!l.entries) continue;
    for (const e of l.entries) {
      const r = join(dir, e.name);
      if (e.kind === 'folder' && !e.state && r !== except && !r.startsWith(except + '/')) out.push(r);
    }
  }
  return [...new Set(out)].sort();
}
function moveItem(P, rel) {
  const here = parentOf(rel);
  const options = knownFolders(P, rel).map((r) => [r, guest(r)]);
  dialog('Move ' + nameOf(rel), 'To a folder this panel has listed (open a folder to offer it), or drag the row onto a folder. Nothing there is ever replaced.',
    [{ name: 'dir', label: 'Into', type: 'select', options, value: here }], 'Move', async (v) => {
      if (v.dir === here) return;
      await moveTo(P, rel, join(v.dir, nameOf(rel)));
    }, { icon: 'folder-input' });
}
function deleteItem(P, rel) {
  const kind = entryKind(P, rel);
  const l = kind === 'folder' ? P.lists.get(rel) : null;
  const n = l && l.entries ? l.entries.length : null;
  const what = kind === 'folder' ? 'the folder ' + guest(rel) + (n === null ? ' and everything in it' : n ? ' and the ' + n + ' item' + (n === 1 ? '' : 's') + ' in it' : '')
    : kind === 'link' ? 'the link ' + guest(rel) + ' (never what it points to)' : guest(rel);
  dialog('Delete ' + nameOf(rel), 'Deletes ' + what + ' in ' + P.name + '. It cannot be undone.', [], 'Delete', async () => {
    await change(P, { action: 'files-rm', path: guest(rel), recursive: kind === 'folder' ? true : undefined, confirm: guest(rel) }, [parentOf(rel)]);
    if (kind === 'folder') closeFolder(P, rel);
    if (P.selected === rel || P.selected.startsWith(rel + '/')) { P.selected = parentOf(rel); P.focus = P.selected; }
    render(P);
  }, { danger: true, icon: 'trash-2', confirmCheck: 'Yes, delete ' + guest(rel) + (kind === 'folder' ? ' with everything in it' : '') });
}
async function openItem(P, rel, reveal) {
  try {
    const r = await api('sandboxes/' + P.name + '/files/open', { method: 'POST', json: { path: guest(rel), reveal: !!reveal } });
    toast(r.message);
  } catch (e) { failureFor(P.name, e.message || String(e)); }
}
async function copyText(text, what) {
  try { await navigator.clipboard.writeText(text); toast('Copied ' + what); } catch (_) { pageFailure('This browser could not copy — ' + text); }
}

// ── drawing ─────────────────────────────────────────────────────────────────────────────────────────────────────────
function render(P) {
  const head = h('div', { class: 'files-head' }, h('h2', null, 'Files'));
  const why = changeWhy(P);
  const dir = folderOfSelection(P);
  const canList = shared(P) || running(P);
  const dirState = dir && P.lists.get(parentOf(dir)) && (P.lists.get(parentOf(dir)).entries || []).find((x) => x.name === nameOf(dir));
  const noNew = why || (dirState && dirState.state ? 'That folder is ' + dirState.state + ' by the workspace rules' : null);
  const newFile = btn('New file…', () => newItem(P, 'file', dir), { small: true, quiet: true, iconOnly: true, icon: 'file-plus', title: noNew || 'New file in ' + guest(dir) });
  const newFolder = btn('New folder…', () => newItem(P, 'folder', dir), { small: true, quiet: true, iconOnly: true, icon: 'folder-plus', title: noNew || 'New folder in ' + guest(dir) });
  const refresh = btn('Refresh', () => { relistAll(P); }, { small: true, quiet: true, iconOnly: true, icon: 'refresh-cw', title: 'List the open folders again' });
  newFile.disabled = newFolder.disabled = !canList || !!noNew;
  refresh.disabled = !canList;
  head.append(newFile, newFolder, refresh);
  const parts = [head];
  if (!P.info) { P.el.replaceChildren(...parts); return; }
  if (!shared(P) && !running(P)) {
    const phase = P.info.busy ? 'busy' : P.info.phase;
    parts.push(callout('info', { compact: true, attrs: { 'data-files-asleep': phase },
      title: P.info.busy ? P.name + ' is busy' : P.name + ' is ' + ({ off: 'shut down', asleep: 'asleep', paused: 'paused', hibernated: 'hibernated', failed: 'stopped' }[phase] || phase),
      body: 'It is isolated: its files are on its own disk, so they are listed while it runs. Looking here never wakes or starts it.' }));
    P.el.replaceChildren(...parts);
    return;
  }
  const root = P.lists.get('');
  const rules = [...P.lists.values()].some((l) => l.rules);
  parts.push(h('p', { class: 'files-note', 'data-files-note': '' },
    shared(P) ? ['Shared from ', h('code', null, tildePath(P.info.workspace)), ' — changes show as they happen.' + (rules ? ' Workspace rules apply: locked and read-only items are not changed here.' : '')]
      : 'Inside the sandbox — Refresh shows changes made since.'));
  if (!root) { parts.push(h('div', { class: 'fmsg' }, P.loading ? 'Listing…' : '')); P.el.replaceChildren(...parts); return; }
  if (root.error) {
    parts.push(callout('bad', { compact: true, body: root.error, actions: [btn('Try again', () => relistAll(P), { small: true })] }));
    P.el.replaceChildren(...parts);
    return;
  }
  const hadFocus = P.el.contains(document.activeElement) && document.activeElement.classList.contains('frow');
  const tree = h('div', { class: 'ftree', role: 'tree', 'aria-label': 'Files of ' + P.name, on: { keydown: (ev) => keys(P, ev) } });
  tree.append(row(P, '', { name: ROOT, kind: 'folder' }, 0));
  rows(P, '', 1, tree);
  parts.push(tree);
  P.el.replaceChildren(...parts);
  const focus = tree.querySelector('.frow[data-rel="' + CSS.escape(P.focus) + '"]') || tree.querySelector('.frow');
  if (focus) { focus.tabIndex = 0; if (hadFocus) focus.focus(); }
}
/// A line under a folder (listing, empty, cut). Its indent is a custom property set through CSSOM (the CSP refuses a
/// style attribute).
function msg(depth, text, bad) {
  const el = h('div', { class: 'fmsg' + (bad ? ' bad' : '') }, text);
  el.style.setProperty('--depth', String(depth));
  return el;
}
function rows(P, dir, depth, out) {
  const l = P.lists.get(dir);
  if (!l) { out.append(msg(depth, 'Listing…')); return; }
  if (l.error) { out.append(msg(depth, l.error, true)); return; }
  if (!l.entries.length) out.append(msg(depth, 'Empty'));
  for (const e of l.entries) {
    const rel = join(dir, e.name);
    out.append(row(P, rel, e, depth));
    if (e.kind === 'folder' && P.expanded.has(rel)) rows(P, rel, depth + 1, out);
  }
  if (l.truncated) out.append(msg(depth, 'Only the first ' + l.entries.length + ' are listed'));
  if (l.unlisted) out.append(msg(depth, l.unlisted + ' name' + (l.unlisted === 1 ? '' : 's') + ' with a line break not listed'));
}
/// Why this entry cannot be changed here (null: it can).
function lockedWhy(P, rel, e) {
  if (rel === '') return '/workspace itself is never changed';
  return changeWhy(P) || (e.state === 'locked' ? 'Locked by the workspace rules' : e.state === 'read-only' ? 'Read-only by the workspace rules'
    : e.altered ? 'Its name has characters that cannot be shown — change it inside the sandbox' : null);
}
function row(P, rel, e, depth) {
  const folder = e.kind === 'folder' && e.state !== 'locked';
  const open = folder && (rel === '' || P.expanded.has(rel));
  const ic = e.state === 'locked' ? 'lock' : e.kind === 'folder' ? (open ? 'folder-open' : 'folder') : e.kind === 'link' ? 'link' : 'file';
  const attrs = { class: 'frow' + (e.kind === 'folder' ? ' folder' : '') + (rel === '' ? ' root' : ''), role: 'treeitem', tabindex: '-1', 'data-rel': rel,
    'data-kind': e.kind, 'aria-level': String(depth + 1), 'aria-selected': P.selected === rel ? 'true' : 'false',
    title: guest(rel) + (e.target ? ' → ' + e.target : '') };
  if (folder && rel !== '') attrs['aria-expanded'] = open ? 'true' : 'false';
  const why = lockedWhy(P, rel, e);
  const el = h('div', attrs,
    folder && rel !== '' ? h('span', { class: 'caret', 'aria-hidden': 'true' }, icon('chevron-right')) : h('span', { class: 'caret', 'aria-hidden': 'true' }),
    icon(ic),
    h('span', { class: 'fname' }, e.name),
    e.target ? h('span', { class: 'ftarget' }, '→ ' + e.target) : null,
    e.state ? h('span', { class: 'tag ' + (e.state === 'locked' ? 'warn' : 'outline'), 'data-state': e.state }, e.state) : null,
    e.size != null ? h('span', { class: 'fsize' }, bytes(e.size)) : null,
    rowMenu(P, rel, e, why).el);
  el.style.setProperty('--depth', String(depth));
  el.addEventListener('click', (ev) => {
    if (ev.target.closest('.menu-wrap')) return;
    P.selected = rel; P.focus = rel;
    if (folder && rel !== '') toggle(P, rel); else render(P);
  });
  el.addEventListener('dblclick', (ev) => { if (!folder && e.kind === 'file' && shared(P) && !isRemote() && !ev.target.closest('.menu-wrap')) openItem(P, rel, false); });
  // drag a row onto a folder (or /workspace): a move
  if (!why) {
    el.draggable = true;
    el.addEventListener('dragstart', (ev) => { P.drag = rel; el.classList.add('dragging'); ev.dataTransfer.effectAllowed = 'move'; ev.dataTransfer.setData('text/plain', guest(rel)); });
    el.addEventListener('dragend', () => { P.drag = null; el.classList.remove('dragging'); });
  }
  if (e.kind === 'folder' && !e.state && !changeWhy(P)) {
    const ok = () => P.drag !== null && P.drag !== rel && parentOf(P.drag) !== rel && !(rel + '/').startsWith(P.drag + '/');
    el.addEventListener('dragover', (ev) => { if (ok()) { ev.preventDefault(); el.classList.add('drop'); } });
    el.addEventListener('dragleave', () => el.classList.remove('drop'));
    el.addEventListener('drop', (ev) => {
      el.classList.remove('drop');
      if (!ok()) return;
      ev.preventDefault();
      const from = P.drag;
      P.drag = null;
      moveTo(P, from, join(rel, nameOf(from))).catch((err) => failureFor(P.name, err.message || String(err)));
    });
  }
  return el;
}
function rowMenu(P, rel, e, why) {
  const isFolder = e.kind === 'folder' && e.state !== 'locked';
  const mac = shared(P) && !isRemote();
  const items = [];
  if (isFolder) {
    items.push({ label: 'New file here…', icon: 'file-plus', disabled: !!changeWhy(P) || e.state === 'read-only', why: changeWhy(P) || 'Read-only by the workspace rules', onSelect: () => newItem(P, 'file', rel) });
    items.push({ label: 'New folder here…', icon: 'folder-plus', disabled: !!changeWhy(P) || e.state === 'read-only', why: changeWhy(P) || 'Read-only by the workspace rules', onSelect: () => newItem(P, 'folder', rel) });
    items.push({ sep: true });
  }
  if (mac && e.state !== 'locked') {
    if (e.kind === 'file') items.push({ label: 'Open on the Mac', icon: 'external-link', desc: 'In its default app — documents only, as the agent’s own opening', onSelect: () => openItem(P, rel, false) });
    if (isFolder) items.push({ label: 'Open in the Finder', icon: 'external-link', onSelect: () => openItem(P, rel, false) });
    items.push({ label: 'Show in the Finder', icon: 'folder-open', desc: 'Selected in its folder', onSelect: () => openItem(P, rel, true) });
  }
  items.push({ label: 'Copy path', icon: 'copy', desc: guest(rel), onSelect: () => copyText(guest(rel), guest(rel)) });
  if (!shared(P) && e.kind !== 'folder') items.push({ label: 'Copy the doz get command', icon: 'download', desc: 'Copies it out to this Mac', onSelect: () => copyText('doz get ' + P.name + ' ' + guest(rel), 'the command') });
  if (rel !== '') {
    items.push({ sep: true });
    items.push({ label: 'Rename…', icon: 'pencil', disabled: !!why, why, onSelect: () => renameItem(P, rel) });
    items.push({ label: 'Move…', icon: 'folder-input', disabled: !!why, why, onSelect: () => moveItem(P, rel) });
    items.push({ sep: true });
    items.push({ label: 'Delete…', icon: 'trash-2', danger: true, disabled: !!why, why, onSelect: () => deleteItem(P, rel) });
  }
  // An open menu holds the page's re-render (sandbox.js); closing it lets the held one run.
  return moreMenu('More for ' + e.name, items, { small: true, onClose: () => { if (state.sbxHeld) { state.sbxHeld = false; refreshSandbox(); } } });
}
/// The tree's keys: ↑/↓ move, → opens (or goes in), ← closes (or goes up), Enter opens, F2 renames, Delete deletes.
function keys(P, ev) {
  const all = [...ev.currentTarget.querySelectorAll('.frow')];
  const cur = ev.target.closest('.frow');
  if (!cur || ev.target.closest('.menu-wrap')) return;
  const i = all.indexOf(cur), rel = cur.dataset.rel, kind = cur.dataset.kind;
  const go = (el) => { if (!el) return; P.focus = el.dataset.rel; P.selected = el.dataset.rel; for (const r of all) r.tabIndex = -1; el.tabIndex = 0; el.focus(); for (const r of all) r.setAttribute('aria-selected', r === el ? 'true' : 'false'); };
  const expanded = cur.getAttribute('aria-expanded');
  switch (ev.key) {
    case 'ArrowDown': ev.preventDefault(); go(all[i + 1]); break;
    case 'ArrowUp': ev.preventDefault(); go(all[i - 1]); break;
    case 'Home': ev.preventDefault(); go(all[0]); break;
    case 'End': ev.preventDefault(); go(all[all.length - 1]); break;
    case 'ArrowRight':
      ev.preventDefault();
      if (expanded === 'false') { P.focus = rel; P.selected = rel; toggle(P, rel); } else if (expanded === 'true' || rel === '') go(all[i + 1]);
      break;
    case 'ArrowLeft':
      ev.preventDefault();
      if (expanded === 'true') { P.focus = rel; P.selected = rel; toggle(P, rel); } else if (rel !== '') go(all.find((r) => r.dataset.rel === parentOf(rel)));
      break;
    case 'Enter':
      ev.preventDefault();
      P.focus = rel; P.selected = rel;
      if (expanded) toggle(P, rel); else if (kind === 'file' && shared(P) && !isRemote()) openItem(P, rel, false);
      break;
    case 'F2':
      ev.preventDefault();
      { const l = P.lists.get(parentOf(rel)), e = l && l.entries ? l.entries.find((x) => x.name === nameOf(rel)) : null; if (rel && e && !lockedWhy(P, rel, e)) renameItem(P, rel); }
      break;
    case 'Delete': case 'Backspace': {
      ev.preventDefault();
      const l = P.lists.get(parentOf(rel)), e = l && l.entries ? l.entries.find((x) => x.name === nameOf(rel)) : null;
      if (rel && e && !lockedWhy(P, rel, e)) deleteItem(P, rel);
      break;
    }
    default: break;
  }
}
