// components/chat-composer-box — the composer's box: what is typed in each room is kept in this browser a moment after
// each keystroke and put back when the room opens again; the box grows with its lines. Attachments (the clip, a paste, a
// drop) are uploaded one by one as they are chosen and wait as chips until the message is sent. A file over the chat
// server's 20 MB is refused here, with the reason, before a byte is sent.
import { state } from '../core/state-67e05db59fafd5df.js';
import { MAX_FILE, chatError, cleanFileName, fileUrl, request } from '../core/chat-api-ec968582d97ebdcb.js';
import { getDraft, setDraft } from '../core/chat-storage-95add63ce40b26df.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { chatNote } from './chat-note-7d9b58ce10feea44.js';

let draftT = 0;
export function scheduleDraft() { clearTimeout(draftT); draftT = setTimeout(saveDraft, 400); }
export function saveDraft() {
  clearTimeout(draftT);
  const t = $('chat-text');
  if (state.chat.room && t && !state.chat.editing) setDraft(state.chat.room, t.value);   // an edit's text is never a draft
}
export function loadDraft() { const t = $('chat-text'); if (t) { t.value = getDraft(state.chat.room); grow(); } }
/// One line at first, then a line per line typed, at most ten (no script sets a size: the rows do).
export function grow() { const t = $('chat-text'); if (t) t.rows = Math.max(1, Math.min(10, t.value.split('\n').length)); }

const PICTURE = /^image\/(png|jpeg|gif|webp)$/;
const size = (n) => (n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : n >= 1024 ? Math.round(n / 1024) + ' KB' : n + ' bytes');

/// The chips of what waits to be sent (a picture's own thumbnail, else its name), each with a ✕.
export function showPending() {
  const box = $('chat-pend');
  if (!box) return;
  box.hidden = !state.chat.pending.length && !state.chat.uploading;
  const chips = state.chat.pending.map((a, i) => {
    const src = fileUrl(a.url);
    const x = h('button', { type: 'button', class: 'chat-pchip-x', title: 'Remove', 'aria-label': 'Remove ' + String(a.name) }, icon('x'));
    x.addEventListener('click', () => { state.chat.pending.splice(i, 1); showPending(); });
    return h('span', { class: 'chat-pchip' }, src && PICTURE.test(a.type) ? h('img', { class: 'chat-pchip-img', src, alt: '' }) : icon('file'),
      h('span', { class: 'chat-pchip-name' }, String(a.name)), h('small', { class: 'chat-pchip-size' }, size(+a.size || 0)), x);
  });
  if (state.chat.uploading) chips.push(h('span', { class: 'chat-pchip is-busy' }, icon('paperclip'), 'Uploading…'));
  box.replaceChildren(...chips);              // never a null: the DOM would write it as the text "null"
}

/// Upload files for the next message (not while editing: an edit keeps its attachments as they were).
export async function upload(files) {
  if (state.chat.editing) { chatNote('An edit keeps its attachments as they were: finish or cancel it first.', true); return; }
  for (const f of files) {
    if (state.chat.pending.length >= 10) { chatNote('A message takes at most 10 attachments.', true); return; }
    if (!f.size) { chatNote('Not attached: ' + (f.name || 'the file') + ' is empty.', true); continue; }
    if (f.size > MAX_FILE) { chatNote('Not attached: ' + (f.name || 'the file') + ' is ' + size(f.size) + ' — an attachment can be at most 20 MB.', true); continue; }
    const name = cleanFileName(f.name || (f.type === 'image/png' ? 'pasted.png' : 'pasted'));
    state.chat.uploading++;
    showPending();
    try {
      const r = await request('/files?name=' + encodeURIComponent(name), { method: 'POST', bytes: f, type: 'application/octet-stream' });
      if (!r.ok) throw await chatError(r);
      const a = await r.json();
      if (a && typeof a.id === 'string' && fileUrl(a.url)) { state.chat.pending.push(a); chatNote('Attached ' + String(a.name) + '. It goes with your next message.'); }
    } catch (e) {
      chatNote('Not attached: ' + (e.message || e), true);
    } finally { state.chat.uploading--; showPending(); }
  }
}
