// components/chat-edit — the person edits their own message in the composer (the pencil, the Up arrow in an empty box,
// /edit) and deletes any message with a confirming tick. Both go with an X-Chat-Id, so the server does each once. An
// empty text is refused with a note: Delete is the way to remove a message.
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { chatError, request, roomUrl, viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { $ } from '../dom/h-f853cc7eb6672c45.js';
import { dialog } from './dialog-d63a999377472e4d.js';
import { chatNote } from './chat-note-7d9b58ce10feea44.js';
import { grow, saveDraft, showPending } from './chat-composer-box-7f2f47534031d1ab.js';

/// The person's own latest message in the room shown (nil: none).
export const latestOwn = () => [...state.chat.byId.values()].filter((m) => m.from === viewer() && !m.kind && !m.deleted && m._body)
  .reduce((a, m) => (!a || (+m.seq || 0) > (+a.seq || 0) ? m : a), null);

export function startEdit(m) {
  if (!m || m.deleted || m.kind || m.from !== viewer()) return;
  const t = $('chat-text');
  if (!state.chat.editing) {
    saveDraft();
    state.chat.editing = { draft: t.value, pending: state.chat.pending };
    state.chat.pending = [];
    showPending();
  }
  state.chat.editing.id = m.msg_id;
  t.value = String(m.content || '');
  $('chat-editbar').hidden = false;
  $('chat-form').classList.add('is-editing');
  $('chat-send').lastChild.textContent = 'Save';
  $('chat-cmds').hidden = true;
  grow();
  t.focus();
  t.setSelectionRange(t.value.length, t.value.length);
}

export function endEdit() {
  const was = state.chat.editing;
  if (!was) return;
  state.chat.editing = null;
  const t = $('chat-text');
  t.value = was.draft;
  state.chat.pending = was.pending;
  showPending();
  $('chat-editbar').hidden = true;
  $('chat-form').classList.remove('is-editing');
  $('chat-send').lastChild.textContent = 'Send';
  grow();
}

export async function saveEdit() {
  const m = state.chat.byId.get(state.chat.editing.id), text = $('chat-text').value.trim();
  if (!m || m.deleted) { endEdit(); return; }
  if (text === String(m.content || '').trim()) { endEdit(); return; }
  if (!text && !(m.attachments || []).length) { chatNote('A message cannot be saved empty. Use Delete to remove it.', true); return; }
  try {
    const r = await request(roomUrl(state.chat.room, '/messages/' + m.msg_id + '/edit'), { method: 'POST', json: { text }, once: true });
    if (!r.ok) throw await chatError(r);
    const j = await r.json();
    if (j.state === 'refused') { chatNote('Not saved: ' + (j.detail || 'refused'), true); return; }
    endEdit();
    chatNote('Saved.');
  } catch (e) { chatNote('Not saved: ' + (e.message || e), true); }
}

/// Delete a message (the person may delete anyone's): asked first, with a box to tick.
export function askDelete(m) {
  const who = m.from === viewer() ? 'your message' : 'this message from ' + String(m.from);
  dialog('Delete message', 'Its text is erased for everyone; a line saying who deleted it stays in the room. Agents that had it are told to disregard it.',
    [], 'Delete', async () => {
      const r = await request(roomUrl(state.chat.room, '/messages/' + m.msg_id + '/delete'), { method: 'POST', json: {}, once: true });
      if (!r.ok) throw await chatError(r);
      const j = await r.json();
      if (j.state === 'refused') throw new Error(j.detail || 'the chat server refused it');
    }, { danger: true, confirmCheck: 'Yes, delete ' + who, icon: 'trash-2' });
}
