// views/chat-messages — a room's messages: the bubbles, the tombstone of a deleted one, the stub of a direct message
// between others, the room's change lines; reading the log (the newest page, then on as the server says more is left)
// and older pages as the reader scrolls up. Every message is untrusted text, drawn with h() and renderMarkdown. On a
// workspace's page (state.chat.scope) each sender's name carries its place in the workspace (role · agent program ·
// isolation · session), and the workspace's log lines sit among the messages by time (`drawSys`, core/ws-log.js) —
// never posted, only drawn.
import { state } from '../core/state-1036883eb74b9520.js';
import { canWrite, chatError, request, roomUrl, viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { cap, time } from '../core/chat-format-bc877d395788e64c.js';
import { renderMarkdown } from '../core/chat-markdown-a6b1b4fee6227bd8.js';
import { setSeen } from '../core/chat-storage-33378969d815dcb0.js';
import { interleave, lineAt, lineKey, lineText } from '../core/ws-log-725b407c6811cd6c.js';
import { isAsk } from '../core/asks-9233aabea7274757.js';
import { askCard, focusKey, refocus } from '../components/chat-ask-2c9d63c277036307.js';
import { drawAtts } from '../components/chat-attachments-2f26c808caeb92f7.js';
import { askDelete, startEdit } from '../components/chat-edit-3c5821a442721d5a.js';
import { moments, place } from '../components/chat-log-1fc6c219d594a8e3.js';
import { chatNote } from '../components/chat-note-95e0cc435178e0d8.js';
import { picker, reacts } from '../components/chat-reactions-dabdbbc50d150c8f.js';
import { moreMenu } from '../components/menus-2bfb74f31fa5969c.js';
import { chips } from '../components/chat-receipts-63c7f59c33da97d1.js';
import { watchTables } from '../components/chat-tables-e57e43edc3e205ea.js';
import { avatar } from '../dom/chat-avatar-afd4621f27e3492b.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';

const presenceOf = (n) => state.chat.presence.find((p) => p.name === n) || {};
const PAGE = 100;
const archived = () => ((state.chat.srv && state.chat.srv.archived) || []).includes(state.chat.room)
  || !!((state.chat.srv && state.chat.srv.closed) || {})[state.chat.room];

/// Read a direct message between others: the room records that the person did.
async function reveal(m) {
  try {
    const r = await request(roomUrl(state.chat.room, '/messages/' + m.msg_id + '/reveal'), { method: 'POST', json: {} });
    if (!r.ok) throw await chatError(r);
    const j = await r.json();
    if (j && j.msg_id === m.msg_id) add(j, true);
  } catch (e) { chatNote('Not revealed: ' + (e.message || e), true); }
}

function toText(m) {
  if (!m._to) return;
  m._to.replaceChildren(icon('arrow-right'), document.createTextNode(' ' + ((m.to || []).length ? m.to.map(cap).join(', ') : 'everyone')));
}
function edTag(m) {
  const w = m._when;
  if (!w) return;
  const old = w.querySelector('.chat-ed');
  if (old) old.remove();
  if (m.edited_at) w.append(h('span', { class: 'chat-ed', title: 'Edited ' + new Date(m.edited_at * 1000).toLocaleString() }, 'edited'));
}

/// An edited message changes where it stands (its place, reactions and marks kept).
export function edited(m) {
  const o = state.chat.byId.get(m.msg_id);
  if (!o || !o._el || o.kind || o.deleted || !o._body) return add(m, true);
  o.content = m.content; o.edited_at = m.edited_at; o.to = m.to; o.mentions = m.mentions; o.attachments = m.attachments;
  o._body.replaceChildren(renderMarkdown(o.content || ''));
  watchTables(o._body);
  toText(o); drawAtts(o); edTag(o);
}

function sync(m) {
  const o = state.chat.byId.get(m.msg_id);
  if (!o) return add(m);
  if (m.deleted && !o.deleted) return add(m, true);
  if (!m.deleted && (m.edited_at || 0) !== (o.edited_at || 0)) edited(m);
}

/// One message into the log (`again`: it replaces what is shown of it; `older`: it goes above everything shown).
export function add(m, again, older) {
  if (!m || typeof m.msg_id !== 'string') return;
  const old = state.chat.byId.get(m.msg_id);
  if (old && !again) return;
  const instead = old && old._el;
  const at = +m.at || 0;
  if (m.deleted) {   // a tombstone: who sent it, who deleted it, when — nothing of what it said
    const by = m.deleted_by || m.from;
    m._el = h('div', { class: 'chat-status chat-tomb', 'data-at': at,
      title: 'Sent ' + new Date(at * 1000).toLocaleString() + (m.deleted_at ? '\nDeleted ' + new Date(m.deleted_at * 1000).toLocaleString() : '') },
      cap(by) + ' deleted a message' + (m.deleted_by && m.deleted_by !== m.from ? ' from ' + cap(m.from) : '') + ' · ' + time(at));
    state.chat.byId.set(m.msg_id, m);
    place(m._el, instead, older);
    return;
  }
  if (m.kind === 'change') {
    m._el = h('div', { class: 'chat-status', 'data-at': at }, String(m.content || '') + ' · ' + time(at));
    state.chat.byId.set(m.msg_id, m);
    place(m._el, instead, older);
    return;
  }
  if (m.kind === 'private') {   // a direct message between others: who and when, not what — Reveal reads it (and says so)
    let rv = null;
    if (canWrite()) {
      rv = h('button', { type: 'button', class: 'chat-reveal', title: 'Read this direct message. The room records that you did.' }, icon('eye'), 'Reveal');
      rv.addEventListener('click', () => reveal(m));
    }
    m._el = h('div', { class: 'chat-status chat-dm-stub', 'data-at': at }, icon('users'),
      ' ' + cap(m.from) + ' sent ' + (m.to || []).map(cap).join(', ') + ' a direct message · ' + time(at) + ' ', rv);
    state.chat.byId.set(m.msg_id, m);
    place(m._el, instead, older);
    return;
  }
  const me = m.from === viewer();
  const sc = state.chat.scope, meta = sc && sc.who ? sc.who(m.from) : null;
  const top = h('div', { class: 'chat-top' },
    h('span', { class: 'chat-from' + (me ? ' is-detail' : '') }, cap(m.from)),
    meta && meta.text ? h('span', { class: 'chat-meta', title: meta.title || meta.text }, meta.text) : null,
    meta && meta.actsAsYou ? h('span', { class: 'ws-chip acts-as-you chat-acts', title: 'Unfenced on this Mac: it acts as you' }, icon('triangle-alert'), 'acts as you') : null,
    m.sender ? h('span', { class: 'chat-kind is-detail', title: String(m.sender.id || '') + ' · ' + (m.sender.verified ? 'verified by token' : 'not verified') }, String(m.sender.kind || '')) : null);
  m._to = h('span', { class: 'chat-to is-detail' });
  toText(m);
  top.append(m._to);
  if (m.private) {
    top.append(h('span', { class: 'chat-lock', title: m.revealed ? 'A direct message between others that you chose to read' : 'Only you and ' + (me ? (m.to || []).join(', ') : m.from) + ' see this' },
      icon('users'), ' direct to ' + (m.to || []).map(cap).join(', ') + (m.revealed ? ' · opened by you' : '')));
  }
  top.append(h('span', { class: 'chat-mid is-detail', title: m.msg_id }, m.msg_id.slice(0, 8)));
  const info = h('button', { type: 'button', class: 'chat-ibtn', title: 'Show or hide the detail: who it is for, its id, and what happened to it',
    'aria-label': 'Show or hide the detail of this message', 'aria-pressed': 'false' }, icon('info'));
  // The tools: the detail; react (to someone else's), edit (your own); Delete (any — you are the room's human).
  const tools = h('span', { class: 'chat-tools' }, info);
  if (canWrite()) {
    if (!me) tools.append(picker(m));
    if (!archived()) {
      if (me && m.kind !== 'ask') {
        const eb = h('button', { type: 'button', class: 'chat-ibtn', title: 'Edit this message', 'aria-label': 'Edit this message' }, icon('pencil'));
        eb.addEventListener('click', (e) => { e.stopPropagation(); startEdit(state.chat.byId.get(m.msg_id)); });
        tools.append(eb);
      }
      tools.append(moreMenu('More for this message', [{ label: 'Delete…', icon: 'trash-2', danger: true, desc: 'Erase its text for everyone',
        onSelect: () => askDelete(m) }], { small: true }).el);
    }
  }
  top.append(tools);
  const d = h('article', { class: 'chat-msg' + (me ? ' is-me' : '') + (m.private ? ' is-private' : '') }, top);
  info.addEventListener('click', (e) => { e.stopPropagation(); const on = d.classList.toggle('is-info'); info.setAttribute('aria-pressed', String(on)); });
  if (m.re_msg_id) {
    const was = state.chat.byId.get(m.re_msg_id);
    d.append(h('div', { class: 'chat-re is-detail', 'data-re': m.re_msg_id }, was && was.deleted ? 'answers a deleted message' : 'answers ' + String(m.re_msg_id).slice(0, 8)));
  }
  const body = h('div', { class: 'chat-md' });
  let refocusKey = null;
  if (m.kind === 'ask') {
    // An ask is its card; one whose ask cannot be read is its plain text (never Markdown).
    refocusKey = focusKey(instead);
    if (isAsk(m)) body.append(askCard(m)); else body.append(h('p', { class: 'chat-ask-plain' }, String(m.content || '')));
  } else {
    body.append(renderMarkdown(String(m.content || '')));
    watchTables(body);
  }
  d.append(body);
  m._body = body;
  m._atts = h('div', { class: 'chat-atts' });
  d.append(m._atts);
  drawAtts(m);
  m.reactions = m.reactions || [];
  m._rx = h('div', { class: 'chat-rx' });
  m._tick = h('span', { class: 'chat-tick' });
  d.append(h('div', { class: 'chat-foot' }, m._rx, m._tick));
  m._states = h('div', { class: 'chat-states is-detail' });
  d.append(m._states);
  reacts(m);
  chips(m);
  m._when = h('div', { class: 'chat-when', title: new Date(at * 1000).toLocaleString() }, time(at));
  edTag(m);
  const row = h('div', { class: 'chat-row' + (me ? ' is-me' : ''), 'data-who': m.from, 'data-at': at },
    avatar(presenceOf(m.from).avatar, m.from), h('div', { class: 'chat-col' }, d, m._when));
  m._el = row;
  state.chat.byId.set(m.msg_id, m);
  place(row, instead, older);
  if (refocusKey) refocus(row, refocusKey);
}

/// A touch screen has no hover: a tap on a bubble shows its tools (and hides another's); a tap on a link, a button or a
/// field is that control's own. One listener for the whole log.
export function watchTaps(log) {
  log.addEventListener('pointerup', (e) => {
    if (e.pointerType !== 'touch' || !(e.target instanceof Element) || e.target.closest('a, button, input, textarea, label, select')) return;
    const msg = e.target.closest('.chat-msg');
    for (const o of log.querySelectorAll('.chat-msg.is-tap')) if (o !== msg) o.classList.remove('is-tap');
    if (msg) msg.classList.toggle('is-tap');
  });
}

/// Read the log after what is shown: the newest page first time, then on while the server says more is left.
export async function fill() {
  const r = state.chat.room;
  for (;;) {
    const after = state.chat.lastSeq;
    const q = after > 0 ? '?after=' + after : '?limit=' + PAGE;
    const res = await request(roomUrl(r, '/messages' + q));
    if (r !== state.chat.room) return;
    if (!res.ok) return;
    const ms = await res.json();
    if (!Array.isArray(ms)) return;
    state.chat.bulk++;
    try {
      for (const m of ms) {
        sync(m);
        state.chat.lastSeq = Math.max(state.chat.lastSeq, +m.seq || 0);
        if (!state.chat.firstSeq || (+m.seq && +m.seq < state.chat.firstSeq)) state.chat.firstSeq = +m.seq || state.chat.firstSeq;
      }
    } finally { state.chat.bulk--; }
    if (after === 0) state.chat.older = res.headers.get('X-More') === 'true';   // the newest page: X-More says older are left
    if (!(after > 0 && res.headers.get('X-More') === 'true' && state.chat.lastSeq > after)) break;
  }
  drawSys();
  moments();
  if (state.chat.atFoot) { const l = $('chat-log'); l.scrollTop = l.scrollHeight; }
  if (document.visibilityState === 'visible') setSeen(r, state.chat.lastSeq);   // read only while it is seen
}

/// The workspace's log lines among the room's messages (a workspace's page only): drawn again from the lines known
/// (state.chat.scope.sysLines) — only those in the span loaded, each before the first message of a later time.
export function drawSys() {
  const l = $('chat-log');
  if (!l) return;
  for (const e of [...l.querySelectorAll('.chat-sys')]) e.remove();
  const sc = state.chat.scope;
  if (!sc || !state.chat.room) return;
  const shown = [...l.children].filter((c) => c.dataset.at !== undefined && !c.classList.contains('chat-moment')).map((el) => ({ at: +el.dataset.at, el }));
  const merged = interleave(shown, sc.sysLines(state.chat.room), !state.chat.older);
  const you = state.chat.human ? cap(state.chat.human) : 'You';
  const line = (x) => h('div', { class: 'chat-status chat-sys', 'data-at': lineAt(x), 'data-sys': lineKey(x), 'data-action': x.action,
    title: new Date(lineAt(x) * 1000).toLocaleString() + ' — from the workspace’s log (not posted in the room)' }, icon('history'), lineText(x, you) + ' · ' + time(lineAt(x)));
  let waiting = [];
  for (const x of merged) {
    if (x.kind === 'line') { waiting.push(x.item); continue; }
    for (const w of waiting) l.insertBefore(line(w), x.item.el);
    waiting = [];
  }
  const foot = l.querySelector('.chat-status.is-now');
  for (const w of waiting) { if (foot) l.insertBefore(line(w), foot); else l.append(line(w)); }
  moments();
  if (state.chat.atFoot) l.scrollTop = l.scrollHeight;
}

/// The page before the oldest shown, kept in place as it is drawn above.
export async function loadOlder() {
  if (state.chat.loadingOlder || !state.chat.older || !state.chat.firstSeq || state.chat.firstSeq <= 1) return;
  state.chat.loadingOlder = true;
  const r = state.chat.room, l = $('chat-log');
  try {
    const res = await request(roomUrl(r, '/messages?before=' + state.chat.firstSeq + '&limit=' + PAGE));
    if (r !== state.chat.room || !res.ok) return;
    const ms = await res.json();
    if (!Array.isArray(ms)) return;
    const h0 = l.scrollHeight;
    state.chat.bulk++;
    try {
      for (const m of ms.slice().sort((a, b) => (+b.seq || 0) - (+a.seq || 0))) {
        add(m, false, true);
        if (+m.seq) state.chat.firstSeq = Math.min(state.chat.firstSeq, +m.seq);
      }
    } finally { state.chat.bulk--; }
    state.chat.older = res.headers.get('X-More') === 'true';
    if (state.chat.scope) { const at = state.chat.atFoot; state.chat.atFoot = false; drawSys(); state.chat.atFoot = at; }
    moments();
    l.scrollTop += l.scrollHeight - h0;
  } catch (_) { /* scrolling up again tries again */ } finally { state.chat.loadingOlder = false; }
}
