// views/chat-live — chat's live stream, while the chat view is shown (the chat server treats the person as here exactly
// while it is open), and 5 s after the view is left. Every end comes back by itself with a growing pause; every return
// reads the room's log again after what is shown, and presence and unread counts, so nothing missed in the gap stays
// missing and nothing reloads.
import { state } from '../core/state-58b070d3f17c1c53.js';
import { viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { setSeen } from '../core/chat-storage-95add63ce40b26df.js';
import { openChatStream } from '../core/chat-stream-13e4bcee7f0e04c5.js';
import { reacts } from '../components/chat-reactions-5ceac4046763ced6.js';
import { chips } from '../components/chat-receipts-7846ac9d891c8025.js';
import { loadUnread, setPreview, showUnread } from '../components/chat-unread-40ec2368b8ae2956.js';
import { $ } from '../dom/h-f853cc7eb6672c45.js';
import { add, edited, fill } from './chat-messages-3243cbdad5577b66.js';
import { changes, loadPresence, people } from './chat-people-49a9b25d6af40b7e.js';
import { refreshState } from './chat-rooms-23134d3a3566be9c.js';

const MEMBERCHANGE = / (invited|removed|left|created|added|rejoined|taken|archived|reopened) /;
let stream = null, retry = 0, retryT = 0, leaveT = 0, opened = false;

function paintLive(s) {
  state.chat.live = s;
  const el = $('chat-live');
  if (!el) return;
  el.className = 'chat-live is-' + s;
  el.textContent = s === 'live' ? 'live' : s === 'reconnecting' ? 'reconnecting…' : s === 'connecting' ? 'connecting…' : 'not connected';
}

function event(e) {
  const c = state.chat;
  if (!c.srv) return;
  if (e.kind === 'hello') { if (e.version && c.srv.version && e.version !== c.srv.version) refreshState(); return; }
  if (e.kind === 'presence') { if (Array.isArray(e.presence)) { c.presence = e.presence; changes(c.presence); people(); } return; }
  const m = e.message;
  if (e.kind === 'message' && m && !m.kind && c.srv.rooms[e.room]) setPreview(e.room, m);
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
    c.lastSeq = Math.max(c.lastSeq, +m.seq || 0);
    if (c.active) setSeen(c.room, c.lastSeq);
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
      if (why === 'session-ended' || why === 'rotated' || why === 'revoked') { paintLive('off'); return; }
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
