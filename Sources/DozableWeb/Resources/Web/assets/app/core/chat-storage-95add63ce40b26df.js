// core/chat-storage — what this browser keeps for chat (its own conveniences, never shared, never read by the server): the
// newest seq seen in each room (the unread markers) and the draft being typed in each room. Every read and write may fail
// (a private window): then nothing is kept.
const get = (k) => { try { return localStorage.getItem(k); } catch (_) { return null; } };
const put = (k, v) => { try { if (v === null || v === '') localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (_) { /* not kept */ } };

export const getSeen = (r) => { const v = get('doz.chat.seen:' + r); return v === null ? null : (parseInt(v, 10) || 0); };
export const setSeen = (r, n) => put('doz.chat.seen:' + r, String(n));
export const getDraft = (r) => get('doz.chat.draft:' + r) || '';
export const setDraft = (r, text) => put('doz.chat.draft:' + r, text || '');
