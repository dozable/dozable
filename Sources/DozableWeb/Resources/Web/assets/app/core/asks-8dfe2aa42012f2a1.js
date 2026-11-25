// core/asks — the ONE way the page answers an ask: the typed action `chat-decide` (exactly the HostOp `doz chat decide`
// sends), followed to its end. The decision card (components/chat-ask.js) and the space diagram (answerFromDiagram)
// both come here; nothing else sends the action. Another computer gets the words at once, with no request: asks are
// answered in this Mac's own browser for now. A refusal comes back in Dozable's words, as the daemon told it.
import { canWrite, viewer } from './chat-api-ec968582d97ebdcb.js';
import { actOrThrow, waitForOp } from './operations-47321c2f8a98caa2.js';
import { isRemote } from './session-d2120671b8ea9d60.js';

export const MAC_ONLY = "Asks are answered in this Mac's own browser for now.";
export const NOT_SHOWN = 'This ask is not shown here any more; open it in chat.';

const listeners = new Set();

/// Called with the message each time an ask changes where the page sees it (the stream's `ask` event, a new one).
export function onAskChange(fn) { listeners.add(fn); return () => listeners.delete(fn); }
export function askChanged(m) {
  for (const fn of [...listeners]) { try { fn(m); } catch (_) { /* a listener's own problem */ } }
}

/// A lower-case v4 UUID: the decision's id, so a retry of the same press is a duplicate, never a second decision.
function actionId() {
  if (globalThis.crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID().toLowerCase();
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const x = [...b].map((v) => v.toString(16).padStart(2, '0')).join('');
  return x.slice(0, 8) + '-' + x.slice(8, 12) + '-' + x.slice(12, 16) + '-' + x.slice(16, 20) + '-' + x.slice(20);
}

/// `#N`, or the first 8 of its id.
export function askName(m) {
  const n = m && m.ask && +m.ask.number;
  return n > 0 ? '#' + n : String((m && m.msg_id) || '').slice(0, 8);
}

/// Whether a message is an ask the page can draw as a card: an `ask` object with its questions.
export function isAsk(m) {
  return !!(m && m.kind === 'ask' && m.ask && typeof m.ask === 'object' && Array.isArray(m.ask.questions) && m.ask.questions.length > 0);
}

/// Whether the person here may answer it — the daemon's `ChatAskViewer.canAnswer`, and this Mac's browser with chat
/// writable: open, someone left to decide, the person among its deciders, and not the one who asked it.
export function canAnswer(m) {
  if (!isAsk(m) || isRemote() || !canWrite()) return false;
  const a = m.ask, me = viewer();
  return (a.state || 'open') === 'open' && !a.no_decider && (a.deciders || []).includes(me) && m.from !== me;
}

/// Answer an ask: `{room, ask, answers | decline (+ text) | reply}` → `{ok: true}` or `{refused: words}`.
export async function answerAsk({ room, ask, answers, decline, text, reply }) {
  if (isRemote()) return { refused: MAC_ONLY };
  const body = { action: 'chat-decide', room, ask, actionId: actionId() };
  if (answers) body.answers = answers;
  else if (decline) { body.decline = true; if (text) body.text = text; } else body.reply = reply;
  try {
    const end = await waitForOp(await actOrThrow(body), 120);
    if (!end) return { refused: 'No answer yet — Operations shows how it ends.' };
    if (end.state !== 'done') return { refused: end.text || 'It was not answered.' };
    return { ok: true };
  } catch (e) { return { refused: (e && e.message) || String(e) }; }
}

// The space diagram's asks: the attention items it was last given, by ask id → room.
const shown = new Map();

/// The diagram's attention items, as it draws them: each ask's room is remembered for its answer.
export function rememberAttention(items) {
  shown.clear();
  for (const i of items || []) if (i && i.kind === 'ask' && typeof i.askId === 'string' && typeof i.room === 'string') shown.set(i.askId, i.room);
}

/// The diagram's answer: `reply` is one option's label, or the words when the ask has no options — the same action.
export async function answerFromDiagram(askId, reply) {
  if (isRemote()) return { refused: MAC_ONLY };
  const room = shown.get(askId);
  if (!room) return { refused: NOT_SHOWN };
  if (typeof reply !== 'string' || !reply.trim()) return { refused: 'Say your answer.' };
  return answerAsk({ room, ask: askId, reply });
}
