// core/chat-api — chat's server calls. What is particular to the dashboard (the base address, the request function with
// its CSRF header, who is looking, how an attachment's address is made) is handed in once by app.js as an adapter
// (configure); views and components ask here and never name a header or an address themselves.
//
//   adapter = { title,                       // the view's name
//               request(path, {method, json}) -> Promise<Response>,
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

/// One request; the Response.
export function request(path, o = {}) { return adapter.request(path, o); }

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
