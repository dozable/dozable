// views/chat-live — chat's live stream, while the chat view is shown (the chat server treats the person as here exactly
// while it is open), and 5 s after the view is left. Every end comes back by itself with a growing pause; every return
// reads the room's log again after what is shown, and presence and unread counts, so nothing missed in the gap stays
// missing and nothing reloads.
import { state } from '../core/state-1036883eb74b9520.js';
import { viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { askChanged } from '../core/asks-b27aaf2b833e1fb8.js';
import { setSeen } from '../core/chat-storage-33378969d815dcb0.js';
import { openChatStream } from '../core/chat-stream-5146183b814250bf.js';
import { reacts } from '../components/chat-reactions-fa0ee8e593503bdf.js';
import { chips } from '../components/chat-receipts-63c7f59c33da97d1.js';
import { loadUnread, setPreview, showUnread } from '../components/chat-unread-9284e62b88511529.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { add, edited, fill } from './chat-messages-e428386ba69802ce.js';
import { changes, loadPresence, people } from './chat-people-246bc7547ebaccac.js';
import { refreshState } from './chat-rooms-3efe35cebfdd2c9f.js';

const MEMBERCHANGE = / (invited|removed|left|created|added|rejoined|taken|archived|reopened) /;
let stream = null, retry = 0, retryT = 0, leaveT = 0, opened = false;
const endFns = new Set();

/// Called with the reason when the stream ends for good (signed out, rotated, revoked, moved) — the chat window says so
/// over itself. → stop.
export function onLiveEnd(fn) { endFns.add(fn); return () => endFns.delete(fn); }

function paintLive(s) {
  state.chat.live = s;
  const el = $('chat-live');
  if (!el) return;
  el.className = 'chat-live is-' + s;
  if (s === 'paused') {
    // Another chat window of this browser took this stream (the dashboard keeps a few): nothing retries by itself.
    el.replaceChildren('paused — another chat window took this stream ',
      h('button', { type: 'button', class: 'btn sm quiet chat-live-again', 'data-chat-reconnect': '' }, 'Reconnect'));
    el.querySelector('button').addEventListener('click', () => { retry = 0; connect(); });
    return;
  }
  el.textContent = s === 'live' ? 'live' : s === 'reconnecting' ? 'reconnecting…' : s === 'connecting' ? 'connecting…' : 'not connected';
}

// A room is marked read only while it is seen: back in view, what was drawn meanwhile is read now.
document.addEventListener('visibilitychange', () => {
  const c = state.chat;
  if (document.visibilityState === 'visible' && c.active && c.room && c.lastSeq) setSeen(c.room, c.lastSeq);
});

function event(e) {
  const c = state.chat;
  if (!c.srv) return;
  if (e.kind === 'hello') { if (e.version && c.srv.version && e.version !== c.srv.version) refreshState(); return; }
  if (e.kind === 'presence') { if (Array.isArray(e.presence)) { c.presence = e.presence; changes(c.presence); people(); } return; }
  const m = e.message;
  if (e.kind === 'message' && m && !m.kind && c.srv.rooms[e.room]) setPreview(e.room, m);
  // An ask's preview is what it asks, never its lettered text.
  if (e.kind === 'message' && m && m.kind === 'ask' && c.srv.rooms[e.room]) {
    setPreview(e.room, { ...m, content: 'asks: ' + String((m.ask && m.ask.question) || '').split('\n')[0] });
  }
  // An ask changed (decided, expired, withdrawn, no decider left): here its card is drawn again, keeping what the person
  // chose; elsewhere the counts are read again.
  if (e.kind === 'ask' && m) {
    if (e.room === c.room) add(m, true); else if (c.srv.rooms[e.room]) loadUnread();
    askChanged(m);
    return;
  }
  if ((e.kind === 'edited' || e.kind === 'deleted') && m && c.srv.rooms[e.room]) {
    const p = c.previews[e.room];
    if (e.kind === 'edited' && p && p.msg_id === m.msg_id) setPreview(e.room, m);
    if (e.kind === 'deleted' || e.room !== c.room) loadUnread();
    if (e.room === c.room) { if (e.kind === 'edited') edited(m); else add(m, true); }
    return;
  }
  if (e.room !== c.room) {   // another room: a count, not the message
    if (e.kind === 'message' && m && m.kind === 'change' && MEMBERCHANGE.test(' ' + m.content + ' ')) refreshState();
    if (e.kind === 'message' && m && m.kind !== 'change' && m.kind !== 'private' && m.from !== viewer() && c.srv.rooms[e.room]) {
      const u = c.unread[e.room] || (c.unread[e.room] = { n: 0, m: 0 });
      u.n++;
      if ((m.mentions || []).includes(viewer())) u.m++;
      showUnread();
    }
    return;
  }
  if (e.kind === 'revealed' && m) { add(m, true); return; }
  if (e.kind === 'reaction' && e.reaction) {
    const x = c.byId.get(e.reaction.msg_id);
    if (x && x._rx) {
      x.reactions = (x.reactions || []).filter((r) => !(r.who === e.reaction.who && r.reaction === e.reaction.reaction));
      if (!e.reaction.removed) x.reactions.push(e.reaction);
      reacts(x);
    }
    return;
  }
  if (e.kind === 'message' && m) {
    if (m.kind === 'change' && MEMBERCHANGE.test(' ' + m.content + ' ')) refreshState();
    add(m);
    if (m.kind === 'ask') askChanged(m);
    c.lastSeq = Math.max(c.lastSeq, +m.seq || 0);
    if (c.active && document.visibilityState === 'visible') setSeen(c.room, c.lastSeq);
  }
  if (e.kind === 'state' && e.state) {
    const x = c.byId.get(e.state.msg_id);
    if (x && x._states) { x.states = (x.states || []).concat([e.state]); chips(x); }
  }
}

function connect() {
  clearTimeout(retryT);
  if (stream) return;
  paintLive(opened ? 'reconnecting' : 'connecting');
  stream = openChatStream({
    open() {
      retry = 0;
      paintLive('live');
      if (opened) { fill(); loadPresence(); loadUnread(); }   // back after a gap: catch up on what was missed
      opened = true;
    },
    event,
    gone(why) {
      stream = null;
      if (!state.chat.active && !leaveT) { paintLive('off'); return; }
      if (why === 'session-ended' || why === 'rotated' || why === 'revoked' || why === 'moved') {
        paintLive('off');
        for (const fn of [...endFns]) { try { fn(why); } catch (_) { /* a listener's own problem */ } }
        return;
      }
      // Evicted by another stream of this browser: no retry (two windows would take it from each other forever).
      if (why === 'replaced') { paintLive('paused'); return; }
      paintLive('reconnecting');
      const wait = why === 'resync' ? 0 : Math.min(30000, 1000 * 2 ** Math.min(retry, 5));
      retry++;
      retryT = setTimeout(connect, wait);
    },
  });
}

/// Open the stream (the chat view is shown); a leave in its last 5 s is undone.
export function startLive() { clearTimeout(leaveT); leaveT = 0; connect(); }

/// The chat view was left: the stream closes 5 s later (a quick look elsewhere keeps it).
export function stopLive(now) {
  clearTimeout(leaveT);
  const stop = () => { leaveT = 0; clearTimeout(retryT); if (stream) { stream.close(); stream = null; } opened = false; paintLive('off'); };
  if (now) stop(); else leaveT = setTimeout(stop, 5000);
}
