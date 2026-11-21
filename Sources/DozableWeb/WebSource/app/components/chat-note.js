// components/chat-note — the line under the composer: what an action of the person's in chat came to (a refusal stays there
// until the next action or the next keystroke), else how the box works.
import { $ } from '../dom/h.js';

export const CHAT_HINT = 'Enter sends · Shift+Enter starts a new line · @ names someone · / lists commands';
export const CHAT_READ_ONLY = 'This browser may read chat but not write in it (on the Mac: doz config set serve.chat write).';

export function chatNote(text, bad) {
  const n = $('chat-note');
  if (!n) return;
  n.textContent = text || CHAT_HINT;
  n.classList.toggle('is-bad', !!bad);
  n.classList.toggle('is-hint', !text);   // the idle hint (a phone has no room for it)
}
