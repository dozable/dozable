// core/op-stream — the chat window's ear for its own operations. The window has no dashboard stream of its own: an
// operation's end (an Ask's Decide, Turn chat on) is heard only from `/api/v1/stream`'s `op` events, so the stream is
// opened while an operation THIS window started runs and closed at the last one's end. Never while idle.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { api } from './api-47cfabfed13b475c.js';
import { adoptOperations, trackOp } from './operations-7b4c8e49fe46d1d8.js';
import { state } from './state-1036883eb74b9520.js';
// Calls up the layers (provided by chat.js — core/hooks.js):
const signedOut = upcall('signedOut'), helloSeen = upcall('helloSeen');

let es = null;
/// Operations this window did not start (another tab's, read back on `hello` or heard on the stream): never waited for.
const others = new Set();

const mine = () => [...state.ops.values()].filter((o) => o.state === 'running' && !others.has(o.id));

/// Open the stream while one of this window's operations runs; close it when none does. Called after every change.
export function followOps() {
  if (mine().length && !es && !state.signedOut) open();
  else if (!mine().length && es) close();
}

/// The stream is open now (the walk checks it is closed while idle).
export const opStreamOpen = () => !!es;

function close() { if (es) { es.close(); es = null; } }

function open() {
  const s = new EventSource('/api/v1/stream');
  es = s;
  s.addEventListener('hello', async (ev) => {
    let hello = {};
    try { hello = JSON.parse(ev.data); } catch (_) { /* an older doz ui */ }
    helloSeen(hello);
    // An end that came before the stream connected: the server's list says so.
    const known = new Set(state.ops.keys());
    try {
      const list = await api('operations');
      for (const o of list) if (!known.has(o.id)) others.add(o.id);
      adoptOperations(list);
    } catch (_) { /* the stream's own events follow */ }
    followOps();
  });
  s.addEventListener('op', (ev) => {
    let op = null;
    try { op = JSON.parse(ev.data); } catch (_) { return; }
    if (!op || !op.id) return;
    if (!state.ops.has(op.id)) others.add(op.id);
    trackOp(op);
    followOps();
  });
  s.addEventListener('resync', () => { if (es === s) { close(); followOps(); } });
  s.addEventListener('end', (ev) => {
    let reason = '';
    try { reason = JSON.parse(ev.data).reason; } catch (_) { /* */ }
    if (es === s) close();
    if (reason === 'session-ended' || reason === 'rotated' || reason === 'revoked') { signedOut('This window is signed out.', reason); return; }
    setTimeout(followOps, 1000);
  });
  s.onerror = () => { if (es === s) { close(); setTimeout(followOps, 2000); } };
}
