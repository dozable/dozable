// components/notes — 647: the notifications, at the right of the header — ONE store, three ways to show it (ui.notifications).
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-0a9984f90615977d.js';
import { setting } from '../core/settings-0b4a6cca79ee581c.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { btn } from './button-f435595b4098d043.js';
import { callout } from './callout-045a1af4db6ce704.js';

// 647 (owner: "always show notifications in the header, stacked from the right … implement all three, switch with a
// setting"). Every toast, page notice and banner is a NOTE here (`notices.js` makes them); `#notes` (fixed, over the
// header's right end — outside the shell, so a wizard's or a pause's inert parts never take it) draws them:
//   cards — the bell in the header (always — owner, after the first look: "the cards but with a permanent bell") and a
//           column hanging below it, newest on top, each with its full text and buttons; a passing one has a countdown
//           strip; the pointer on ANY card holds every countdown, and the stack turns opaque with Dismiss all;
//   pills — one line each IN the header row, the newest at the right, the rest folded into "+N"; a click opens its card;
//   bell  — a count; the newest shows beside it for a few seconds; a click opens the list.
// A passing note (a success) goes by itself after 8 s; a failure or a banner stays until it is dismissed or no longer
// true. Every note shown is kept in the history (`state.noteHistory`, this tab) — the Notifications page lists it.

/// id → {id, tone, title?, body, actions?, sticky, at, ttl?, icon?, cls?, attrs?, role?, onDismiss?, tag?}
state.notes = new Map();
const MAX = 12, TTL = 8000, FLASH_MS = 5000;
const timers = new Map();            // id → {handle, due} for a passing note; `due` is when it goes
const anims = new Map();             // id → its countdown strip's Animation (a card drawn at least once)
const els = new WeakMap();           // a note's card, built once (its body's nodes live in one place)
let open = null;                     // 'list', a note's id (pills: its card), or null
let flash = null, flashTimer = null; // bell: the newest note, shown beside it for a few seconds
let held = false;                    // the pointer is on a card: every countdown waits
const listeners = new Set();

export function notesMode() {
  const m = setting('ui.notifications', 'cards');
  return m === 'pills' || m === 'bell' ? m : 'cards';
}
/// Told after every change to the notes or their history (the Notifications page repaints).
export function watchNotes(fn) { listeners.add(fn); }
let telling = false;
function tell() {
  if (telling) return;
  telling = true;
  queueMicrotask(() => { telling = false; for (const fn of listeners) fn(); });
}

// ── the history: every note shown, how it ended, this tab ────────────────────
const HISTORY_KEY = 'doz.notes.history', HISTORY_MAX = 200;
state.noteHistory = (() => { try { const v = JSON.parse(sessionStorage.getItem(HISTORY_KEY) || '[]'); return Array.isArray(v) ? v.slice(-HISTORY_MAX) : []; } catch (_) { return []; } })();
let historySeq = state.noteHistory.reduce((m, e) => Math.max(m, e.seq || 0), 0);
for (const e of state.noteHistory) if (!e.ended) { e.ended = 'closed'; e.endedAt = e.at; }   // a page that reloaded shows none of them
const current = new Map();           // note id → its history entry while it shows
function saveHistory() { try { sessionStorage.setItem(HISTORY_KEY, JSON.stringify(state.noteHistory)); } catch (_) { /* this page only */ } }
function remember(note) {
  const text = textOf(note), was = current.get(note.id);
  if (was && was.text === text) return;                          // the same words again: the same notification
  if (was && !was.ended) { was.ended = 'replaced'; was.endedAt = Date.now(); }
  const e = { seq: ++historySeq, at: note.at, tone: toneOf(note), text: text.slice(0, 600), id: note.id };
  current.set(note.id, e);
  state.noteHistory.push(e);
  if (state.noteHistory.length > HISTORY_MAX) state.noteHistory.splice(0, state.noteHistory.length - HISTORY_MAX);
  saveHistory();
}
function ended(id, how) {
  const e = current.get(id);
  current.delete(id);
  if (!e || e.ended) return;
  e.ended = how; e.endedAt = Date.now();
  saveHistory();
}
/// Forget the history (the page's Clear history) — the notes showing now stay, and stay in it.
export function clearNoteHistory() {
  state.noteHistory = state.noteHistory.filter((e) => !e.ended);
  saveHistory();
  tell();
}

/// Show a note (the same id again replaces it and moves it to the newest place).
export function addNote(n) {
  const old = state.notes.get(n.id);
  state.notes.delete(n.id);
  const note = { tone: 'info', sticky: true, ...n, at: Date.now() };
  state.notes.set(n.id, note);
  remember(note);
  for (const id of state.notes.keys()) { if (state.notes.size <= MAX) break; dropNote(id, true, 'overflow'); }
  stopTimer(n.id);
  anims.delete(n.id);
  if (!note.sticky) arm(note.id, note.ttl || TTL);
  if (!old || textOf(old) !== textOf(note)) {
    flash = note.id;
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => { flash = null; if (notesMode() === 'bell') paintNotes(); }, FLASH_MS);
  }
  if (open === n.id && old) open = n.id;
  paintNotes();
  return note;
}
/// `how` it ended, for the history: resolved (no longer true — the default), dismissed, expired, overflow.
export function dropNote(id, quiet, how = 'resolved') {
  const n = state.notes.get(id);
  if (!n) return;
  state.notes.delete(id);
  stopTimer(id);
  anims.delete(id);
  ended(id, how);
  if (open === id) open = null;
  if (flash === id) flash = null;
  if (!state.notes.size) setHeld(false);
  if (!quiet) paintNotes(); else tell();
}
export function noteById(id) { return state.notes.get(id) || null; }
/// Every note dismissed (Dismiss all, the bell's Clear all, the Debug page).
export function clearNotes() {
  for (const n of [...state.notes.values()]) { if (n.onDismiss) n.onDismiss(); dropNote(n.id, true, 'dismissed'); }
  open = null;
  paintNotes();
}
export function dismissNote(id) {
  const n = state.notes.get(id);
  if (n && n.onDismiss) n.onDismiss();
  dropNote(id, false, 'dismissed');
}

// ── a passing note's countdown: a timer, and the strip drawn from the same numbers ──
function arm(id, ms) {
  stopTimer(id);
  const due = Date.now() + ms;
  timers.set(id, { due, left: ms, handle: held ? null : setTimeout(() => dropNote(id, false, 'expired'), ms) });
}
function stopTimer(id) { const t = timers.get(id); if (t) clearTimeout(t.handle); timers.delete(id); }
/// The pointer on any card holds every countdown where it is; leaving lets them all go on from there.
function setHeld(on) {
  if (held === on) return;
  held = on;
  const now = Date.now();
  for (const [id, t] of timers) {
    if (on) { clearTimeout(t.handle); t.handle = null; t.left = Math.max(0, t.due - now); }
    else { t.due = now + t.left; t.handle = setTimeout(() => dropNote(id, false, 'expired'), t.left); }
  }
  for (const a of anims.values()) { try { if (on) a.pause(); else a.play(); } catch (_) { /* a finished one */ } }
  const box = $('notes');
  if (box) box.classList.toggle('is-held', on);
}
function strip(n) {
  const t = timers.get(n.id), total = n.ttl || TTL;
  const bar = h('i', { class: 'note-timer-bar' });
  const el = h('div', { class: 'note-timer', 'aria-hidden': 'true' }, bar);
  if (!t || typeof bar.animate !== 'function') return el;
  // An Animation keeps its time when its element is moved (a repaint re-inserts the cards); a CSS one would restart.
  const a = bar.animate([{ transform: 'scaleX(1)' }, { transform: 'scaleX(0)' }], { duration: total, easing: 'linear', fill: 'forwards' });
  a.currentTime = Math.max(0, total - (held ? t.left : t.due - Date.now()));
  if (held) a.pause();
  anims.set(n.id, a);
  return el;
}
// Which card the pointer is on is read from the document (cards are re-inserted at each repaint, so enter/leave on
// them would be lost): over a card or the stack around it holds; anywhere else, or out of the window, lets go.
document.addEventListener('mouseover', (ev) => setHeld(!!(ev.target.closest && ev.target.closest('.notes-stack, .notes-pop')) && state.notes.size > 0));
document.documentElement.addEventListener('mouseleave', () => setHeld(false));

/// A note's words on one line (a pill, the bell's flash, a title attribute, the history).
export function textOf(n) {
  const parts = Array.isArray(n.body) ? n.body : [n.body];
  const body = parts.map((p) => (p == null ? '' : typeof p === 'string' ? p : p.textContent || '')).join('').replace(/\s+/g, ' ').trim();
  return n.title ? n.title + (body ? ' — ' + body : '') : body;
}
export const TONE_ICON = { info: 'info', ok: 'circle-check', warn: 'triangle-alert', bad: 'circle-x' };
const toneOf = (n) => (TONE_ICON[n.tone] ? n.tone : 'info');

function card(n) {
  let el = els.get(n);
  if (el) return el;
  el = callout(toneOf(n), { compact: true, banner: true, title: n.title || undefined, body: n.body, actions: n.actions, icon: n.icon,
    dismiss: () => dismissNote(n.id), role: n.role, cls: 'note' + (n.cls ? ' ' + n.cls : '') + (n.sticky ? '' : ' passing'),
    attrs: { ...(n.attrs || {}), 'data-note': n.id } });
  if (!n.sticky) el.append(strip(n));
  els.set(n, el);
  return el;
}
function toggle(what) { open = open === what ? null : what; paintNotes(); }
const historyLink = () => h('a', { href: '#/notifications', class: 'notes-history', 'data-notes-history': '', on: { click: () => { open = null; } } }, 'History');
function list(notes, opts = {}) {
  return h('div', { class: 'notes-pop notes-list', role: 'region', 'aria-label': 'Notifications' },
    notes.length ? h('div', { class: 'notes-col' }, ...notes.map(card)) : h('p', { class: 'muted notes-none' }, 'No notifications.'),
    h('div', { class: 'notes-foot' }, historyLink(), opts.clear && notes.length ? h('button', { type: 'button', class: 'btn sm quiet', 'data-notes-clear': '',
      on: { click: () => clearNotes() } }, 'Clear all') : null));
}
function bellButton(notes, opts) {
  const n = notes.length;
  const worst = notes.some((x) => x.tone === 'bad') ? 'bad' : notes.some((x) => x.tone === 'warn') ? 'warn' : '';
  return h('button', { type: 'button', class: 'btn sm quiet icon-only note-bell' + (opts.open ? ' is-open' : ''), 'data-notes-bell': '',
    'aria-label': (n ? n + ' notification' + (n === 1 ? '' : 's') : 'No notifications') + (opts.history ? ' — open the history' : ''),
    title: opts.history ? 'Notification history' : 'Notifications', 'aria-expanded': opts.history ? null : opts.open ? 'true' : 'false',
    on: { click: opts.click } }, icon('bell'), n ? h('span', { class: 'note-count' + (worst ? ' ' + worst : '') }, String(n)) : null);
}

/// Draw `#notes` in the setting's way. Called on every change, and when ui.notifications changes.
export function paintNotes() {
  const box = $('notes');
  if (!box) return;
  const mode = notesMode();
  box.className = 'notes mode-' + mode + (held ? ' is-held' : '');
  box.dataset.count = String(state.notes.size);
  const notes = [...state.notes.values()];                     // oldest first
  if (mode === 'cards') paintCards(box, notes);
  else if (mode === 'pills') paintPills(box, notes);
  else paintBell(box, notes);
  tell();
}
function paintCards(box, notes) {
  const bell = bellButton(notes, { history: true, click: () => { location.hash = '#/notifications'; } });
  const n = notes.length;
  const stack = n ? h('div', { class: 'notes-stack', role: 'region', 'aria-label': 'Notifications' },
    h('div', { class: 'notes-col' }, ...notes.slice().reverse().map(card)),
    h('div', { class: 'notes-stack-foot' }, h('span', { class: 'muted' }, n + ' notification' + (n === 1 ? '' : 's')), historyLink(),
      btn('Dismiss all', () => clearNotes(), { small: true, icon: 'x' }))) : null;
  box.replaceChildren(...[h('div', { class: 'notes-row' }, bell), stack].filter(Boolean));   // (never a null: it writes "null")
}
function paintPills(box, notes) {
  const max = matchMedia('(max-width: 760px)').matches ? 1 : 3;
  const shown = notes.slice(-max), rest = notes.slice(0, Math.max(0, notes.length - max));
  if (open && open !== 'list' && !state.notes.has(open)) open = null;
  if (open === 'list' && !rest.length) open = null;
  const more = rest.length ? h('button', { type: 'button', class: 'note-more' + (open === 'list' ? ' is-open' : ''), 'data-notes-more': '',
    'aria-expanded': open === 'list' ? 'true' : 'false', title: rest.length + ' more', on: { click: () => toggle('list') } }, '+' + rest.length) : null;
  const pop = open === 'list' ? list(rest.slice().reverse())
    : open ? h('div', { class: 'notes-pop' }, card(state.notes.get(open))) : null;
  box.replaceChildren(...[h('div', { class: 'notes-row' }, more, ...shown.map(pill)), pop].filter(Boolean));
}
function pill(n) {
  const t = textOf(n), on = open === n.id;
  return h('div', { class: 'note-pill ' + toneOf(n) + (on ? ' is-open' : ''), 'data-note': n.id, role: n.tone === 'bad' ? 'alert' : 'status' },
    h('button', { type: 'button', class: 'np-open', title: t, 'aria-expanded': on ? 'true' : 'false', on: { click: () => toggle(n.id) } },
      icon(n.icon || TONE_ICON[toneOf(n)]), h('span', { class: 'np-text' }, t)),
    h('button', { type: 'button', class: 'np-x', title: 'Dismiss', 'aria-label': 'Dismiss', on: { click: (ev) => { ev.stopPropagation(); dismissNote(n.id); } } }, icon('x')));
}
function paintBell(box, notes) {
  const f = flash && open !== 'list' ? state.notes.get(flash) : null;
  if (open && open !== 'list') open = null;
  const bell = bellButton(notes, { open: open === 'list', click: () => toggle('list') });
  const flashEl = f ? h('button', { type: 'button', class: 'note-flash ' + toneOf(f), title: textOf(f), on: { click: () => toggle('list') } },
    icon(f.icon || TONE_ICON[toneOf(f)]), h('span', { class: 'np-text' }, textOf(f))) : null;
  box.replaceChildren(...[h('div', { class: 'notes-row' }, flashEl, bell), open === 'list' ? list(notes.slice().reverse(), { clear: true }) : null].filter(Boolean));
}
// A click outside, or Escape, closes an open list or card. (The path, not the target: a click inside has repainted the
// box by the time it reaches the document, so its target is no longer in it.)
document.addEventListener('click', (ev) => { if (open && !ev.composedPath().includes($('notes'))) { open = null; paintNotes(); } });
document.addEventListener('keydown', (ev) => { if (open && ev.key === 'Escape') { open = null; paintNotes(); } });
matchMedia('(max-width: 760px)').addEventListener('change', () => paintNotes());
