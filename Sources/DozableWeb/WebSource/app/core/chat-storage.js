// core/chat-storage — what this browser keeps for chat (its own conveniences, never shared, never read by the server): the
// newest seq seen in each room (the unread markers, shared by this browser's windows) and the draft being typed in each room. Every read and write may fail
// (a private window): then nothing is kept.
const get = (k) => { try { return localStorage.getItem(k); } catch (_) { return null; } };
const put = (k, v) => { try { if (v === null || v === '') localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (_) { /* not kept */ } };

export const getSeen = (r) => { const v = get('doz.chat.seen:' + r); return v === null ? null : (parseInt(v, 10) || 0); };
/// A marker only moves forward: two windows on one room (the dashboard and a chat window) never lower it.
export const setSeen = (r, n) => { const was = getSeen(r); put('doz.chat.seen:' + r, String(was === null ? (+n || 0) : Math.max(was, +n || 0))); };
/// The storage key's prefix of the markers (another window's change arrives as a `storage` event).
export const SEEN_PREFIX = 'doz.chat.seen:';
export const getDraft = (r) => get('doz.chat.draft:' + r) || '';
export const setDraft = (r, text) => put('doz.chat.draft:' + r, text || '');
