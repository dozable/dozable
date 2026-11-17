// core/api — The server: one typed request (fetch, the CSRF header, the error shape).
import { upcall } from './hooks-a4b871a481b363cd.js';
import { state } from './state-c277f13a220e3933.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const signedOut = upcall('signedOut');

// ── HTTP ────────────────────────────────────────────────────────────────────
class HttpError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
/// The Response itself, for a caller that reads its status and headers (chat — core/chat-api.js): the same request as
/// api() (the CSRF header on every unsafe one, a 401 signs the page out), the one place this page calls fetch.
/// `actionId`: chat's X-Chat-Id (a call done once per id). `bytes` + `type`: a body that is not JSON (an attachment).
export async function apiFetch(path, opts = {}) {
  const init = { method: opts.method || 'GET', credentials: 'same-origin', cache: 'no-store', headers: {} };
  if (init.method !== 'GET') init.headers['X-Doz-CSRF'] = state.csrf || '';
  if (opts.actionId) init.headers['X-Chat-Id'] = opts.actionId;
  if (opts.json !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.json);
  } else if (opts.bytes !== undefined) {
    init.headers['Content-Type'] = opts.type || 'application/octet-stream';
    init.body = opts.bytes;
  }
  const r = await fetch('/api/v1/' + path, init);
  if (r.status === 401) {
    let e = {};
    try { e = (await r.clone().json()).error || {}; } catch (_) { /* not JSON */ }
    signedOut(e.message || 'HTTP 401', e.code || 'http-401');
  }
  return r;
}
export async function api(path, opts = {}) {
  const init = { method: opts.method || 'GET', credentials: 'same-origin', cache: 'no-store', headers: {} };
  if (init.method !== 'GET') init.headers['X-Doz-CSRF'] = state.csrf || '';
  if (opts.bearer) init.headers['Authorization'] = 'Bearer ' + opts.bearer;
  if (opts.display) init.headers['X-Doz-Display'] = opts.display;
  if (opts.signal) init.signal = opts.signal;             // an AbortController's: the caller may cancel the read
  if (opts.json !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.json);
  }
  const r = await fetch('/api/v1/' + path, init);
  if (r.status === 204) return null;
  let body = null;
  try { body = await r.json(); } catch (_) { /* not JSON */ }
  if (!r.ok) {
    const e = body && body.error ? body.error : { code: 'http-' + r.status, message: 'HTTP ' + r.status };
    if (r.status === 401) signedOut(e.message, e.code);
    throw new HttpError(r.status, e.code, e.message);
  }
  return body;
}
