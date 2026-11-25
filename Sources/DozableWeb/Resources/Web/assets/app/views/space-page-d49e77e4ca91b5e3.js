// views/space-page — A space workspace's editor, #/w/NAME/space (and /space/watch: canvas and Live only, read-only) — web.md,
// "The space editor's page". The editor's core and its stylesheet load the first time the page opens, through the compiler's
// lazy-import table; nothing of it on a first load. Only the features this viewer may use are mounted: edit on this Mac only,
// the text view (Monaco) only once asked for. A dirty file is never left or reloaded without asking.
import { h, $ } from '../dom/h-f853cc7eb6672c45.js';
import { openOwnWindow } from '../core/windows-392fe33565b4f8f7.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { setLeaveGuard } from '../core/router-1159bbe5d01b97aa.js';
import { spaceHash, spaceWatchHash, workspaceHash } from '../core/routes-0babfc190b1519e4.js';
import { canChange, readSpace, spaceSource, spaceStorage } from '../core/space-editor-d511641d4a509b0d.js';
import { btn } from '../components/button-030d384b64f8d75d.js';
import { cmdLine } from '../components/cmd-line-adc8d3a1a3dcde29.js';
import { toast } from '../components/notices-0ff282536e70c5c2.js';

let core = null, styled = false;
/// The editor's core, loaded once (a failed load is tried again on the next visit).
export function loadEditor() {
  if (!core) core = import('/assets/vendor-space-editor-63169e0288867409/space-core.js').catch((e) => { core = null; throw e; });
  return core;
}
/// The editor's stylesheet, linked once per document (scoped to .space-editor; left in place on leave).
function linkEditorStyle() {
  if (styled) return;
  styled = true;
  document.head.append(h('link', { rel: 'stylesheet', href: '/assets/vendor-space-editor-63169e0288867409/space-editor.css', 'data-space-editor': 'style' }));
}

const narrowQ = matchMedia('(max-width: 760px)');
const TEXT_KEY = 'doz.space.text';
const remembered = () => { try { return localStorage.getItem(TEXT_KEY) === '1'; } catch (_) { return false; } };
const remember = () => { try { localStorage.setItem(TEXT_KEY, '1'); } catch (_) { /* this page only */ } };
const theme = () => { const t = document.documentElement.dataset.theme; return t === 'light' || t === 'dark' ? t : 'system'; };

let cur = null, gen = 0;

/// Opening the page (from the router): `mode` 'edit' or 'watch'. The same workspace and mode again changes nothing.
export async function spaceEnter(name, mode) {
  if (cur && cur.name === name && cur.mode === mode) return;
  spaceLeave();
  const my = ++gen, root = $('space');
  document.title = name + ' — space';
  const c = cur = { name, mode, root, editor: null, dirty: false, offs: [] };
  root.replaceChildren(h('p', { class: 'sp-note muted' }, 'Opening the space editor…'));
  let f;
  try { f = await readSpace(name); } catch (e) {
    if (my !== gen) return;
    return paintNoFile(c, e);
  }
  if (my !== gen) return;
  const mac = canChange(f), watch = mode === 'watch', narrow = narrowQ.matches && !watch;
  const word = h('span', { class: 'sp-word', 'data-sp-word': '' });
  const reload = btn('Reload', () => reloadFile(c), { small: true, icon: 'rotate-ccw', title: 'Read the file again — your changes are lost' });
  reload.hidden = true;
  reload.dataset.spReload = '';
  const textBtn = btn('Text', () => openText(c), { small: true, icon: 'code-xml' });
  textBtn.dataset.spText = '';
  const host = h('div', { class: 'sp-editor', 'data-sp-editor': name });
  c.f = f; c.host = host; c.word = word; c.reload = reload; c.textBtn = textBtn; c.mac = mac;
  const parts = [];
  if (watch) {
    parts.push(h('a', { class: 'btn sm sp-watch-back', href: spaceHash(name), 'data-sp-back': '' }, icon('arrow-left'), 'Back to the editor'));
  } else {
    parts.push(h('div', { class: 'sp-bar', 'data-sp-bar': name },
      h('a', { class: 'sp-back', href: workspaceHash(name), 'data-sp-back': '' }, icon('arrow-left'), name),
      h('span', { class: 'sp-file' }, 'Drawn from ', h('code', null, f.file)), word, reload,
      h('span', { class: 'sp-gap' }),
      narrow ? h('span', { class: 'sp-note muted' }, 'Edit on a wider screen') : textBtn,
      btn('Watch', () => { location.hash = spaceWatchHash(name); }, { small: true, icon: 'eye', quiet: true }),
      // Its own window, one per workspace: a second click brings it forward with only a fragment change (a dirty file there is
      // never reloaded). The page's window.open is terminal.js's refusal — only core/windows.js opens a window.
      btn('Open in a new window', () => openOwnWindow(location.pathname + location.hash, 'doz-space-' + name, { w: 1280, h: 860 }),
        { small: true, icon: 'external-link', quiet: true, iconOnly: true }),
      mac ? null : h('span', { class: 'sp-remote' }, h('span', { class: 'muted' }, 'Changed only in this Mac’s own browser'), f.command ? cmdLine(f.command) : null)));
  }
  parts.push(host);
  root.replaceChildren(...parts);
  root.classList.toggle('sp-watching', watch);
  c.src = spaceSource(name, f, {
    saved: () => toast('Saved. Not applied: Up applies it.'),
    conflict: () => { reload.hidden = false; },
  });
  c.features = watch || narrow ? ['canvas', 'live', 'motion'] : mac ? ['canvas', 'edit', 'plan', 'live', 'motion'] : ['canvas', 'plan', 'live', 'motion'];
  if (!watch && !narrow && remembered()) c.features.push('text');
  c.storage = spaceStorage(name);
  setWord(c);
  textBtn.hidden = c.features.includes('text');
  // The guard: a dirty file is never left (another address), closed or reloaded (core/reconnect) without asking.
  setLeaveGuard((to) => { if (!c.dirty) return false; askLeave(c, to); return true; });
  const unload = (ev) => { if (c.dirty) { ev.preventDefault(); ev.returnValue = ''; } };
  addEventListener('beforeunload', unload);
  c.offs.push(() => removeEventListener('beforeunload', unload));
  const obs = new MutationObserver(() => { if (c.editor) c.editor.setTheme(theme()); });
  obs.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  c.offs.push(() => obs.disconnect());
  const onNarrow = () => { if (!c.dirty && !watch) { const n = c.name; spaceLeave(); spaceEnter(n, mode); } };
  narrowQ.addEventListener('change', onNarrow);
  c.offs.push(() => narrowQ.removeEventListener('change', onNarrow));
  await mountEditor(c, f.text);
}

async function mountEditor(c, text) {
  linkEditorStyle();
  let mod;
  try { mod = await loadEditor(); } catch (_) {
    if (cur !== c) return;
    c.host.replaceChildren(h('div', { class: 'sp-problem', role: 'alert', 'data-sp-failed': '' }, icon('triangle-alert'), 'The editor could not be loaded ',
      btn('Reload', () => location.reload(), { small: true, icon: 'rotate-ccw' })));
    return;
  }
  if (cur !== c) return;
  const s = c.src, watch = c.mode === 'watch';
  const opts = { text, fileName: s.fileName, readOnly: !c.mac || watch || !c.features.includes('edit'), plan: s.plan, subscribe: s.subscribe,
    runs: s.runs, run: s.run, openChat: s.openChat, simulate: false, motion: { appear: 'inflate', idle: 'breathe' }, motionMenu: c.mac && !watch,
    theme: theme(), storage: c.storage, watch, onDirtyChange: (d) => { c.dirty = d; state.spaceDirty = d; setWord(c); } };
  if (c.mac && !watch) { opts.onSave = s.onSave; opts.answer = s.answer; }
  c.editor = await mod.mountFeatures(c.host, opts, c.features);
  if (cur !== c) { c.editor.dispose(); c.editor = null; }
}

function setWord(c) {
  c.word.textContent = c.mode === 'watch' ? '' : !c.mac || !c.features.includes('edit') ? 'Read-only here' : c.dirty ? 'Unsaved' : 'Saved';
  c.word.dataset.spWord = c.dirty ? 'unsaved' : 'clean';
}

/// The text view, added to the editor as it is (its file, undo and selection kept — dirty or clean); kept for this viewer.
async function openText(c) {
  if (!c.editor || c.features.includes('text')) return;
  c.textBtn.disabled = true;
  c.storage.set('view', 'both');
  try { await c.editor.addFeatures(['text']); } catch (e) { c.textBtn.disabled = false; toast(e.message || String(e), true); return; }
  if (cur !== c) return;
  c.features = [...c.features, 'text'];
  c.textBtn.hidden = true;
  remember();
}

/// After a conflict: the file as it is now (the changes here are lost).
async function reloadFile(c) {
  try { const t = await c.src.reread(); if (cur === c && c.editor) { c.editor.setText(t); c.reload.hidden = true; } } catch (e) { toast(e.message || String(e), true); }
}

function askLeave(c, to) {
  choose('Leave with unsaved changes?', 'Your changes to ' + c.f.file + ' are not saved.', 'Leave', 'leave', 'Stay').then((leave) => {
    if (!leave) return;
    setLeaveGuard(null);
    c.dirty = false; state.spaceDirty = false;
    location.hash = to;
  });
}

/// A two-button question → true for the first.
function choose(title, text, yes, id, no = 'Cancel') {
  return new Promise((resolve) => {
    const d = h('dialog', { class: 'dlg', 'aria-labelledby': 'sp-q', 'data-sp-dialog': id });
    const done = (v) => { resolve(v); d.close(); };
    const stay = h('button', { type: 'button', class: 'btn', on: { click: () => done(false) } }, no);
    d.append(h('div', { class: 'dlg-head' }, h('h2', { class: 'h-title', id: 'sp-q' }, title)), h('div', { class: 'dlg-body' }, h('p', null, text)),
      h('div', { class: 'dlg-foot' }, stay, h('button', { type: 'button', class: 'btn primary', 'data-sp-yes': '', on: { click: () => done(true) } }, yes)));
    d.addEventListener('close', () => { resolve(false); d.remove(); });
    document.body.append(d);
    d.showModal();
    stay.focus();
  });
}

function paintNoFile(c, e) {
  const remote = e && e.status === 403;
  c.root.replaceChildren(h('div', { class: 'sp-none', 'data-sp-none': c.name },
    h('a', { class: 'sp-back', href: workspaceHash(c.name), 'data-sp-back': '' }, icon('arrow-left'), c.name),
    remote ? h('p', null, icon('boxes'), 'Shown to another computer only with serve.chat read')
      : h('p', null, icon('boxes'), (e && e.message) || 'Made without a space file', ' — ', cmdLine('doz workspace up -f FILE'), ' makes one')));
}

/// Leaving the page (the router): the editor disposed, its listeners and the guard gone.
export function spaceLeave() {
  gen++;
  const c = cur;
  cur = null;
  state.spaceDirty = false;
  if (!c) return;
  setLeaveGuard(null);
  for (const off of c.offs) off();
  if (c.src && c.src.stop) c.src.stop();
  if (c.editor) c.editor.dispose();
  c.root.replaceChildren();
}

/// For the walk (app.js exposes it): what the page holds now.
export function spaceNow() {
  return cur && { name: cur.name, mode: cur.mode, features: cur.features || [], dirty: cur.dirty, text: cur.editor ? cur.editor.getText() : null };
}
