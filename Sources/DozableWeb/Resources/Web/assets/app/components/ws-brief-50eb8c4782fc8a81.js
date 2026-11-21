// components/ws-brief — A workspace's brief, "The work", above its room: its text (Markdown, the chat's safe subset), its
// references (paths shown with ~; links only as core/util.js safeLink admits them), who wrote it and when, how many times
// it was edited; folded to one line or open; Edit (the brief only — `workspace-brief`, refused when it changed since it
// was read) and History (the log's edits: when, size; each after the start links to its line in the room). Older texts
// are not kept: each edit after the start was posted in the room with its text.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { renderMarkdown } from '../core/chat-markdown-d2b388ff50a05492.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { safeLink, utf8 } from '../core/util-0745432f65992dcb.js';
import { btn } from './button-8109d54546d946d3.js';
import { cmdLine } from './cmd-line-77edaf56061d85a4.js';

/// The most a brief may be from the browser (the actions' body is 16 KiB); beyond it the page shows the command.
export const BRIEF_MAX_BYTES = 15 * 1024;
const BODY_MAX_BYTES = 16 * 1024 - 64;

/// Whether `text` can be sent as the action's body (its JSON included), and its size in bytes.
export function briefFits(workspace, text, sha) {
  const bytes = utf8.encode(text).length;
  const body = utf8.encode(JSON.stringify({ action: 'workspace-brief', workspace, brief: text, ifBrief: sha })).length;
  return { bytes, ok: bytes <= BRIEF_MAX_BYTES && body <= BODY_MAX_BYTES };
}

const stamp = (iso) => { const d = new Date(iso); return Number.isNaN(+d) ? '' : d.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }); };

function ref(r) {
  if (/^https?:\/\//.test(r)) {
    const href = safeLink(r);
    return href ? h('a', { class: 'ws-ref', href, target: '_blank', rel: 'noopener noreferrer', referrerpolicy: 'no-referrer', title: r }, icon('external-link'), r)
      : h('span', { class: 'ws-ref', title: r }, icon('link'), r);
  }
  return h('span', { class: 'ws-ref', title: r }, icon('file'), tildePath(r));
}

/// o: {workspace, brief ({text, refs, bytes, updatedAt, sha256} | null), denied (true: not shared with this browser),
/// edits (core/ws-log.js briefEdits), folded, onFold(folded), canEdit, editWhy, onSave(text, sha) → error text | null,
/// onJump(edit) — the edit's line in the room}.
export function briefCard(o) {
  const card = h('section', { class: 'ws-brief' + (o.folded ? ' is-folded' : ''), 'aria-label': 'The work', 'data-ws-brief': o.workspace });
  let editing = false, history = false;
  const draw = () => {
    const b = o.brief;
    const meta = b ? ['by you', stamp(b.updatedAt), o.edits.length ? 'edited ' + (o.edits.length === 1 ? 'once' : o.edits.length + ' times') : null].filter(Boolean).join(' · ') : '';
    const fold = h('button', { type: 'button', class: 'btn sm quiet ws-brief-fold', 'aria-expanded': o.folded ? 'false' : 'true',
      title: o.folded ? 'Show the whole brief' : 'Fold the brief to one line', on: { click: () => { o.folded = !o.folded; o.onFold(o.folded); draw(); } } },
      icon(o.folded ? 'chevron-down' : 'chevron-right'), o.folded ? 'Open' : 'Fold');
    const edit = btn('Edit', () => { editing = true; o.folded = false; draw(); }, { small: true, quiet: true, icon: 'pencil',
      title: o.canEdit ? 'Edit the brief — once the work has started, the edit is posted in the room as your message' : o.editWhy });
    if (!o.canEdit || !b) edit.disabled = true;
    const hist = h('button', { type: 'button', class: 'btn sm quiet', 'aria-expanded': history ? 'true' : 'false',
      on: { click: () => { history = !history; draw(); } } }, icon('history'), 'History');
    // A space workspace's brief is its file: "BRIEF.md — from the space file", and where an edit is saved.
    const label = b && b.file ? b.file + ' — from the space file' : 'The work';
    const head = h('div', { class: 'ws-brief-head' }, h('span', { class: 'ws-brief-label', 'data-ws-brief-file': b && b.file ? b.file : null }, label),
      h('span', { class: 'ws-brief-meta' }, meta),
      h('span', { class: 'ws-sp' }), editing ? null : edit, hist, editing ? null : fold);
    const kids = [head];
    if (o.denied) {
      kids.push(h('p', { class: 'ws-brief-denied' }, 'The brief is not shared with this browser. On the Mac: ',
        h('code', null, 'doz config set serve.chat read'), ' (or write).'));
    } else if (!b) {
      kids.push(h('p', { class: 'ws-brief-denied' }, 'The brief could not be read.'));
    } else if (editing) {
      if (b.savesTo) kids.push(h('p', { class: 'ws-brief-line muted', 'data-ws-brief-saves': '' }, 'Saved to ', h('code', null, tildePath(b.savesTo))));
      kids.push(editor(b));
    } else if (o.folded) {
      const first = String(b.text).split('\n').map((x) => x.trim()).find(Boolean) || '';
      kids.push(h('p', { class: 'ws-brief-line', title: first }, first, b.refs.length ? h('span', { class: 'ws-brief-n' }, ' · ' + b.refs.length + ' reference' + (b.refs.length === 1 ? '' : 's')) : null));
    } else {
      kids.push(h('div', { class: 'ws-brief-text chat-md' }, renderMarkdown(String(b.text))));
      if (b.refs.length) kids.push(h('div', { class: 'ws-refs' }, ...b.refs.map(ref)));
    }
    if (history) kids.push(historyList());
    card.classList.toggle('is-folded', !!o.folded && !editing);
    card.replaceChildren(...kids);
  };
  const historyList = () => {
    if (!o.edits.length) return h('p', { class: 'ws-brief-hist ws-brief-none' }, 'Not edited since it was written.');
    return h('ol', { class: 'ws-brief-hist', 'aria-label': 'Edits of the brief' }, ...o.edits.map((e) => h('li', null,
      h('span', null, stamp(e.at) + (e.bytes !== null ? ' · ' + e.bytes + ' bytes' : '')),
      e.announced ? [' · ', h('button', { type: 'button', class: 'chat-link', title: 'Its announcement in the room (the text as it was then)',
        on: { click: () => o.onJump(e) } }, 'in the room')] : h('span', { class: 'muted' }, ' · before the start (not posted)'))));
  };
  const editor = (b) => {
    const area = h('textarea', { class: 'ws-brief-area', rows: '8', 'aria-label': 'The brief', spellcheck: 'true' });
    area.value = String(b.text);
    const size = h('span', { class: 'ws-brief-size', 'aria-live': 'polite' });
    const err = h('p', { class: 'ws-brief-err', role: 'alert', hidden: true });
    const over = h('div', { class: 'ws-brief-over', hidden: true }, 'Too long to save from here. In a terminal on this Mac: ',
      cmdLine('doz workspace edit ' + o.workspace + ' --prompt-file FILE'));
    const save = btn('Save', async () => {
      save.disabled = true;
      err.hidden = true;
      const why = await o.onSave(area.value, b.sha256);
      if (why) { err.textContent = why; err.hidden = false; save.disabled = false; return; }
      editing = false;
      draw();
    }, { small: true, primary: true, icon: 'check' });
    const cancel = btn('Cancel', () => { editing = false; draw(); }, { small: true, quiet: true, icon: 'x' });
    const check = () => {
      const f = briefFits(o.workspace, area.value, b.sha256);
      size.textContent = f.bytes + ' bytes';
      over.hidden = f.ok;
      save.disabled = !f.ok || !area.value.trim();
    };
    area.addEventListener('input', check);
    check();
    setTimeout(() => area.focus(), 0);
    return h('div', { class: 'ws-brief-edit' }, area,
      h('div', { class: 'ws-brief-acts' }, save, cancel, size, h('span', { class: 'ws-sp' }),
        h('span', { class: 'muted' }, o.started ? 'Saved, it is posted in the room as your message.' : 'While setting up, nothing is posted.')),
      over, err);
  };
  // A read while the editor is open is kept for when it closes (the editor keeps its text and the sha256 it opened with).
  card.redraw = (next) => { Object.assign(o, next); if (!editing) draw(); };
  draw();
  return card;
}
