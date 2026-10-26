// components/notices — Notices: toasts (successes), the page notices, a sandbox's status line — a failure is never only a toast (603).
// 647: toasts, page notices and banners are the header's notes (components/notes.js), shown the way ui.notifications says.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon, QUEUED_GLYPH } from '../dom/icons-9b284ea0ffb2ad04.js';
import { cancelOps, opEnded } from '../core/operations-93483b02fa399174.js';
import { state } from '../core/state-80142c4ba729c12d.js';
import { btn } from './button-8109d54546d946d3.js';
import { callout } from './callout-f30e3ad8767a987a.js';
import { addNote, dropNote } from './notes-832651f649d83ac5.js';
import { paintStartProgress } from './start-progress-e9240d21a81f3878.js';

/// 603 (E7): a toast acknowledges a success (or says something worth knowing) and goes after 4 s. A FAILURE is
/// never only a toast: it is said where the action was started and stays until dismissed or fixed — in its
/// dialog (which stays open), its sandbox's status line (the sandbox page's bar, the Sandboxes row), the
/// step's own error slot, or the page notices at the top of the page. `toast(text, true)` is that last one.
/// 647: a note in the header (`components/notes.js`) that goes by itself — 8 s (635, owner: "too fast — i couldnt read
/// it"), held while the pointer is on it; every one is kept in Activity. `opts`: {cls, attrs} on its note.
let toastSeq = 0;
export function toast(text, bad, iconName, opts = {}) {
  if (bad) { pageFailure(text); return; }
  logMessage('ok', text);
  addNote({ id: 'toast:' + (++toastSeq), tone: iconName === 'info' ? 'info' : 'ok', icon: iconName || 'check', body: String(text), sticky: false,
    role: 'status', cls: 'toast' + (opts.cls ? ' ' + opts.cls : ''), attrs: opts.attrs });
}
/// 635 (owner: "shouldnt it be logged?"): every message this page showed — toasts, a session's notices, failures — newest
/// last, kept for this browser tab (Activity › Messages lists them).
const MESSAGES_KEY = 'doz.messages', MESSAGES_MAX = 100;
state.messages = (() => { try { const v = JSON.parse(sessionStorage.getItem(MESSAGES_KEY) || '[]'); return Array.isArray(v) ? v.slice(-MESSAGES_MAX) : []; } catch (_) { return []; } })();
export function logMessage(tone, text) {
  const last = state.messages[state.messages.length - 1];
  if (last && last.text === String(text) && Date.now() - last.at < 2000) return;
  state.messages.push({ at: Date.now(), tone, text: String(text).slice(0, 600) });
  if (state.messages.length > MESSAGES_MAX) state.messages.splice(0, state.messages.length - MESSAGES_MAX);
  try { sessionStorage.setItem(MESSAGES_KEY, JSON.stringify(state.messages)); } catch (_) { /* this page only */ }
}
/// The page notices: a failure with no closer home, or one whose home is not on screen — 647: a note in the header that
/// stays until dismissed (or no longer true); at most the newest five.
state.failures = new Map();
export function pageFailure(text, opts = {}) {
  const key = opts.key || String(text);
  if (!state.failures.has(key) || state.failures.get(key).text !== String(text)) logMessage(opts.tone || 'bad', (opts.title ? opts.title + ' — ' : '') + text);
  state.failures.delete(key);
  state.failures.set(key, { text: String(text), tone: opts.tone || 'bad' });
  while (state.failures.size > 5) { const old = state.failures.keys().next().value; state.failures.delete(old); dropNote('failure:' + old); }
  addNote({ id: 'failure:' + key, tone: opts.tone || 'bad', title: opts.title || null, body: String(text), actions: opts.actions || null, sticky: true,
    attrs: { 'data-failure': key }, onDismiss: () => state.failures.delete(key) });
}
/// A page notice that is no longer true (612: an agent that was blocked works again) goes without a click.
export function dropPageNotice(key) {
  state.failures.delete(key);
  dropNote('failure:' + key);
}
/// A failure about a sandbox: its status line when one is on screen (it stays there until dismissed, or until
/// the next operation on it), else the page notices.
state.sbxFail = new Map();
function statusSlotShown(name) { return !!name && [...document.querySelectorAll('[data-op-for]')].some((el) => el.dataset.opFor === name && el.getClientRects().length > 0); }
export function failureFor(name, text) {
  if (statusSlotShown(name)) { logMessage('bad', name + ': ' + text); state.sbxFail.set(name, { text: String(text), at: Date.now() }); paintRowOps(); }
  else pageFailure(name ? name + ': ' + text : text);
}
export function opFailed(op) {
  if (!statusSlotShown(op.sandbox)) pageFailure(op.label + ': ' + op.text, { key: 'op:' + op.id });
}
// 599 (594.B1/B2): what a session bridge did — "hello copied 42 chars", "hello opened https://… in your
// browser". Shown every time (a copy is the one thing an agent can hand the person unasked); two views of
// one session (a pane and a tile) are told the same thing once. A refusal is shown as a failure.
const recentBridgeNotices = new Map();
export function bridgeNotice(kind, text) {
  const k = String(kind).slice(0, 32), s = String(text).slice(0, 400), now = Date.now();
  for (const [key, at] of recentBridgeNotices) if (now - at > 2000) recentBridgeNotices.delete(key);
  if (recentBridgeNotices.has(k + '\n' + s)) return;
  recentBridgeNotices.set(k + '\n' + s, now);
  if (/-(refused|off)$/.test(k)) { pageFailure(s, { tone: 'warn', key: 'bridge:' + k + ':' + s }); return; }
  toast(s, false, 'info', { cls: 'bridge', attrs: { 'data-bridge': k } });
}
/// The newest operation of each sandbox, shown under its name in the list (live, without a refetch).
/// A running operation counts its seconds, so a two-minute first start (pull, flatten, bake) is
/// visibly alive; the text is the host's latest step.
/// 603: a failure stays (until dismissed, or the next operation on the sandbox); a success shows for a minute.
state.acked = new Set();
state.pageAt = Date.now();      // a failure from before this page loaded shows only as long as a success would
export function paintRowOps() {
  // 617: the sandbox page's terminal area shows a start's progress (and hands over to the terminal when it is done).
  paintStartProgress();
  for (const el of document.querySelectorAll('[data-op-for]')) {
    const name = el.dataset.opFor;
    const ops = [...state.ops.values()].filter((o) => o.sandbox === name);
    // While something runs, the OLDEST running operation (a start that others wait behind) — its
    // steps are the news; otherwise the newest outcome. 650: one under way for real before one still queued.
    const running = ops.filter((o) => o.state === 'running');
    const live = running.filter((o) => !o.queued);
    let o = live.length ? live[0] : running.length ? running[0] : ops[ops.length - 1];
    const fail = state.sbxFail.get(name);
    const oAt = o ? opEnded(o) : 0;
    let kind = 'none', text = '';
    const more = running.length > 1 ? ' · then ' + running.filter((x) => x !== o).map((x) => x.action).join(', ') : '';
    if (o && o.state === 'running' && o.queued) {
      kind = 'queued'; text = o.action + ' · ' + o.text + more;      // "wake · queued — 2 ahead", and a Cancel
    } else if (o && o.state === 'running') {
      const secs = Math.max(0, Math.round((Date.now() - new Date(o.startedAt).getTime()) / 1000));
      kind = 'running'; text = o.action + ' · ' + secs + ' s — ' + o.text + more;
    } else if (fail && (!o || fail.at >= oAt)) {
      kind = 'failed'; text = fail.text; o = null;
    } else if (o && o.state === 'failed' && !state.acked.has(o.id) && (oAt >= state.pageAt || Date.now() - oAt < 60000)) {
      kind = 'failed'; text = o.text;
    } else if (o && o.state === 'done' && Date.now() - oAt < 60000) {
      kind = 'done'; text = o.text;
    } else if (o && o.state === 'interrupted' && Date.now() - oAt < 60000) {
      kind = 'interrupted'; text = o.text;           // 605: ended while doz ui restarted, outcome not seen
    }
    // 617 (owner): on the sandbox's own page, while the build panel shows the start, the slot says nothing more about
    // it (the panel is the progress). A failure and the "off → running in N s" result still show here; a row on the
    // Sandboxes page keeps its running line (no panel there).
    if ((kind === 'running' || kind === 'queued') && el.dataset.banner && [...document.querySelectorAll('[data-start-progress]')].some((p) => p.dataset.startProgress === name)) {
      kind = 'none'; text = '';
    }
    const key = kind + '|' + text + (kind === 'queued' ? '|' + o.id : '');
    if (el.dataset.painted === key) continue;
    el.dataset.painted = key;
    // 650: a queued operation — the waiting mark, where it stands, and a quiet Cancel (nothing was sent for it yet).
    if (kind === 'queued') {
      const id = o.id;
      el.className = (el.dataset.banner ? 'op-banner' : 'row-op') + ' op-queued';
      el.replaceChildren(h('span', { class: 'wait-mark', 'aria-hidden': 'true' }, icon(QUEUED_GLYPH)), h('span', { class: 'op-text' }, text),
        btn('Cancel', () => cancelOps([id]), { small: true, quiet: true, title: 'Withdraw it — nothing was done yet' }));
      continue;
    }
    if (!el.dataset.banner) {
      el.textContent = kind === 'none' ? '' : (kind === 'running' ? '… ' : kind === 'done' ? '✓ ' : kind === 'interrupted' ? '– ' : '✕ ') + text;
      el.className = 'row-op' + (kind === 'none' ? ' empty-op' : ' op-' + kind);
      continue;
    }
    // The sandbox page's status slot: a quiet line while it runs, a callout when it ended.
    el.className = 'op-banner' + (kind === 'none' ? ' empty-op' : ' op-' + kind);
    if (kind === 'none') { el.replaceChildren(); continue; }
    if (kind === 'running') { el.replaceChildren(h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('span', { class: 'op-text' }, text)); continue; }
    const opId = o ? o.id : null;
    el.replaceChildren(callout(kind === 'done' ? 'ok' : kind === 'interrupted' ? 'info' : 'bad', { compact: true, body: text, dismiss: kind === 'failed' ? () => {
      if (opId) state.acked.add(opId); else state.sbxFail.delete(name);
      el.dataset.painted = '';
      paintRowOps();
    } : null }));
  }
}
// ── 594 W18: the host and the doz ui server, watched ─────────────────────────
// The footer holds two facts: this page's link to the `doz ui` server (#live) and the host's state and
// build (#host-live). A banner says each transition once: the host stopped (hibernated), died (its
// sandboxes shut down), came back as another build; doz ui stopped (the page retries on its own).
// 647: a banner is a note in the header that stays until dismissed or dropped (one per key). It returns the note
// (`tag` is the caller's own mark — reconnect's calm/stopped tone).
export function banner(key, kind, parts, actions = []) {
  return addNote({ id: 'banner:' + key, tone: kind || 'info', body: parts, actions, sticky: true, cls: 'b-' + (kind || 'info'),
    attrs: { 'data-banner': key }, role: kind === 'bad' ? 'alert' : 'status' });
}
export function dropBanner(key) {
  dropNote('banner:' + key);
}
