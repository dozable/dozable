// core/chat-api — chat's server calls. What is particular to the dashboard (the base address, the request function with
// its CSRF header, who is looking, how an attachment's address is made) is handed in once by app.js as an adapter
// (configure); views and components ask here and never name a header or an address themselves.
//
//   adapter = { title,                       // the view's name
//               request(path, {method, json, bytes, once}) -> Promise<Response>   (once: an X-Chat-Id goes with it),
//               viewer() -> the person's name in chat,
//               fileUrl('/files/ID/NAME') -> the dashboard's address of that attachment, or null }
let adapter = null;

export function configure(a) { adapter = a; }

/// The view's name, from the adapter.
export function pageTitle() { return adapter.title; }

/// The person looking (the owner's name in chat), from the adapter.
export function viewer() { return adapter.viewer(); }

/// /rooms/ROOM + tail, the room encoded.
export const roomUrl = (room, tail = '') => '/rooms/' + encodeURIComponent(room) + tail;

/// An attachment of this server, as the dashboard serves it — or null (anything else is never an address of ours).
export function fileUrl(u) { return adapter.fileUrl(String(u || '')); }

/// The dashboard's mapping (app.js hands it in as `fileUrl`): only `/files/ID/NAME` with a 16- or 32-hex id and the
/// characters a kept name has, at /api/v1/chat/files/ID/NAME (a space as %20).
export function dashboardFileUrl(u) {
  return /^\/files\/(?:[0-9a-f]{16}|[0-9a-f]{32})\/[A-Za-z0-9._ ()+%-]{1,360}$/.test(u) ? '/api/v1/chat' + u.replace(/ /g, '%20') : null;
}

/// One request; the Response. `once`: the chat server does it once for the id that goes with it (a reaction, an edit, a
/// delete) — a retried click is not a second one.
export function request(path, o = {}) { return adapter.request(path, o.once ? { ...o, actionId: actionId() } : o); }

/// One id per action of the person's: a version 4 UUID (the only form the dashboard passes on).
export function actionId() {
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  const x = [...b].map((v) => v.toString(16).padStart(2, '0')).join('');
  return x.slice(0, 8) + '-' + x.slice(8, 12) + '-' + x.slice(12, 16) + '-' + x.slice(16, 20) + '-' + x.slice(20);
}

/// Whether this browser may write in chat (this Mac's own always; another computer as `serve.chat` says).
export function canWrite() { return adapter.canWrite(); }

/// The chat server's attachment limit (20 MiB): a bigger file is refused here before it is sent.
export const MAX_FILE = 20 * 1024 * 1024;

/// A file's name as the chat server keeps it: `A-Za-z0-9._ ()+-`, at most 120 bytes, never starting with a dot or a space.
export function cleanFileName(n) {
  let s = String(n || '').replace(/[^A-Za-z0-9._ ()+-]/g, '-').replace(/^[. ]+/, '');
  if (s.length > 120) { const dot = s.lastIndexOf('.'); const ext = dot > 0 && s.length - dot <= 12 ? s.slice(dot) : ''; s = s.slice(0, 120 - ext.length) + ext; }
  return s || 'file';
}

/// An error in the dashboard's shape, from a refused Response.
export async function chatError(r) {
  let e = {};
  try { e = (await r.json()).error || {}; } catch (_) { /* not JSON */ }
  const err = new Error(e.message || 'the dashboard answered ' + r.status);
  err.status = r.status;
  err.code = e.code || 'http-' + r.status;
  return err;
}

/// GET a path and its JSON (a refusal throws chatError's error).
export async function getJSON(path) {
  const r = await request(path);
  if (!r.ok) throw await chatError(r);
  return r.json();
}
