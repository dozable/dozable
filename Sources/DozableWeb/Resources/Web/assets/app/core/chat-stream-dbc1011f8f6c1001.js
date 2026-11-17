// core/chat-stream — chat's live stream (the dashboard relays the chat server's): the one place it is opened. It is never
// left to the browser's own retries — every end closes it and says why (`gone`), and the view decides when to come back.
import { state } from './state-aebab1eadd270ec5.js';

/// Connect with {open(), event(e), gone(why)}: `event` gets each chat event already parsed (a JSON object with a kind);
/// `gone` is called once, with 'resync', the server's end reason ('chat-gone', 'session-ended', …) or 'error'.
export function openChatStream({ open, event, gone }) {
  const es = new EventSource('/api/v1/chat/stream');
  let over = false;
  const end = (why) => { if (over) return; over = true; es.close(); gone(why); };
  es.onopen = () => { if (!over) open(); };
  es.addEventListener('chat', (ev) => {
    let e = null;
    try { e = JSON.parse(ev.data); } catch (_) { return; }
    if (!over && e && typeof e === 'object' && typeof e.kind === 'string') event(e);
  });
  es.addEventListener('resync', () => end('resync'));
  es.addEventListener('end', (ev) => {
    let why = 'end';
    try { why = String(JSON.parse(ev.data).reason || 'end'); } catch (_) { /* */ }
    end(why);
  });
  es.onerror = () => end('error');
  state.chat.live = 'connecting';
  return { close: () => { over = true; es.close(); } };
}
