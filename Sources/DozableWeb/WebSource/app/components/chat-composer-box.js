// components/chat-composer-box — the composer's box: what is typed in each room is kept in this browser a moment after
// each keystroke and put back when the room opens again; the box grows with its lines.
import { state } from '../core/state.js';
import { getDraft, setDraft } from '../core/chat-storage.js';
import { $ } from '../dom/h.js';

let draftT = 0;
export function scheduleDraft() { clearTimeout(draftT); draftT = setTimeout(saveDraft, 400); }
export function saveDraft() {
  clearTimeout(draftT);
  const t = $('chat-text');
  if (state.chat.room && t) setDraft(state.chat.room, t.value);
}
export function loadDraft() { const t = $('chat-text'); if (t) { t.value = getDraft(state.chat.room); grow(); } }
/// One line at first, then a line per line typed, at most ten (no script sets a size: the rows do).
export function grow() { const t = $('chat-text'); if (t) t.rows = Math.max(1, Math.min(10, t.value.split('\n').length)); }
