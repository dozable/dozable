// components/notes — 647: the notifications, at the right of the header — ONE store, three ways to show it (ui.notifications).
import { $, h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { setting } from '../core/settings.js';
import { state } from '../core/state.js';
import { callout } from './callout.js';

// 647 (owner: "always show notifications in the header, stacked from the right … implement all three, switch with a
// setting"). Every toast, page notice and banner is a NOTE here (`notices.js` makes them); `#notes` (fixed, over the
// header's right end — outside the shell, so a wizard's or a pause's inert parts never take it) draws them:
//   cards — a column hanging below the header, newest on top, each with its full text and buttons;
//   pills — one line each IN the header row, the newest at the right, the rest folded into "+N"; a click opens its card;
//   bell  — a count; the newest shows beside it for a few seconds; a click opens the list.
// A passing note (a success) goes by itself after 8 s (held while the pointer is on it); a failure or a banner stays
// until it is dismissed or no longer true. Every one is also kept in Activity › Messages (`logMessage`).

/// id → {id, tone, title?, body, actions?, sticky, at, ttl?, icon?, cls?, attrs?, role?, onDismiss?, tag?}
state.notes = new Map();
const MAX = 12, TTL = 8000, FLASH_MS = 5000;
const timers = new Map();
const els = new WeakMap();           // a note's card, built once (its body's nodes live in one place)
let open = null;                     // 'list', a note's id (pills: its card), or null
let flash = null, flashTimer = null; // bell: the newest note, shown beside it for a few seconds

export function notesMode() {
  const m = setting('ui.notifications', 'cards');
  return m === 'pills' || m === 'bell' ? m : 'cards';
}
/// Show a note (the same id again replaces it and moves it to the newest place).
export function addNote(n) {
  const old = state.notes.get(n.id);
  state.notes.delete(n.id);
  const note = { tone: 'info', sticky: true, ...n, at: Date.now() };
  state.notes.set(n.id, note);
  for (const id of state.notes.keys()) { if (state.notes.size <= MAX) break; dropNote(id, true); }
  clearTimeout(timers.get(n.id));
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
export function dropNote(id, quiet) {
  const n = state.notes.get(id);
  if (!n) return;
  state.notes.delete(id);
  clearTimeout(timers.get(id));
  timers.delete(id);
  if (open === id) open = null;
  if (flash === id) flash = null;
  if (!quiet) paintNotes();
}
export function noteById(id) { return state.notes.get(id) || null; }
/// Every note dismissed (the bell's Clear all, the Debug page).
export function clearNotes() {
  for (const n of [...state.notes.values()]) { if (n.onDismiss) n.onDismiss(); dropNote(n.id, true); }
  open = null;
  paintNotes();
}
function dismiss(id) {
  const n = state.notes.get(id);
  if (n && n.onDismiss) n.onDismiss();
  dropNote(id);
}
function arm(id, ms) { clearTimeout(timers.get(id)); timers.set(id, setTimeout(() => dropNote(id), ms)); }
function hold(id) { clearTimeout(timers.get(id)); }
function release(id) { const n = state.notes.get(id); if (n && !n.sticky) arm(id, 3000); }
/// A note's words on one line (a pill, the bell's flash, a title attribute).
export function textOf(n) {
  const parts = Array.isArray(n.body) ? n.body : [n.body];
  const body = parts.map((p) => (p == null ? '' : typeof p === 'string' ? p : p.textContent || '')).join('').replace(/\s+/g, ' ').trim();
  return n.title ? n.title + (body ? ' — ' + body : '') : body;
}
const TONE_ICON = { info: 'info', ok: 'circle-check', warn: 'triangle-alert', bad: 'circle-x' };
const toneOf = (n) => (TONE_ICON[n.tone] ? n.tone : 'info');

function card(n) {
  let el = els.get(n);
  if (el) return el;
  el = callout(toneOf(n), { compact: true, banner: true, title: n.title || undefined, body: n.body, actions: n.actions, icon: n.icon,
    dismiss: () => dismiss(n.id), role: n.role, cls: 'note' + (n.cls ? ' ' + n.cls : ''), attrs: { ...(n.attrs || {}), 'data-note': n.id } });
  if (!n.sticky) {
    el.addEventListener('mouseenter', () => hold(n.id));
    el.addEventListener('mouseleave', () => release(n.id));
  }
  els.set(n, el);
  return el;
}
function toggle(what) { open = open === what ? null : what; paintNotes(); }
function list(notes, opts = {}) {
  return h('div', { class: 'notes-pop notes-list', role: 'region', 'aria-label': 'Notifications' },
    notes.length ? h('div', { class: 'notes-col' }, ...notes.map(card)) : h('p', { class: 'muted notes-none' }, 'No notifications.'),
    opts.clear && notes.length ? h('div', { class: 'notes-foot' }, h('button', { type: 'button', class: 'btn sm quiet', 'data-notes-clear': '',
      on: { click: () => clearNotes() } }, 'Clear all')) : null);
}

/// Draw `#notes` in the setting's way. Called on every change, and when ui.notifications changes.
export function paintNotes() {
  const box = $('notes');
  if (!box) return;
  const mode = notesMode();
  box.className = 'notes mode-' + mode;
  box.dataset.count = String(state.notes.size);
  const notes = [...state.notes.values()];                     // oldest first
  if (mode === 'cards') { box.replaceChildren(h('div', { class: 'notes-col' }, ...notes.reverse().map(card))); return; }
  if (mode === 'pills') { paintPills(box, notes); return; }
  paintBell(box, notes);
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
  box.replaceChildren(...[h('div', { class: 'notes-row' }, more, ...shown.map(pill)), pop].filter(Boolean));   // (never a null: it writes "null")
}
function pill(n) {
  const t = textOf(n), on = open === n.id;
  const p = h('div', { class: 'note-pill ' + toneOf(n) + (on ? ' is-open' : ''), 'data-note': n.id, role: n.tone === 'bad' ? 'alert' : 'status' },
    h('button', { type: 'button', class: 'np-open', title: t, 'aria-expanded': on ? 'true' : 'false', on: { click: () => toggle(n.id) } },
      icon(n.icon || TONE_ICON[toneOf(n)]), h('span', { class: 'np-text' }, t)),
    h('button', { type: 'button', class: 'np-x', title: 'Dismiss', 'aria-label': 'Dismiss', on: { click: (ev) => { ev.stopPropagation(); dismiss(n.id); } } }, icon('x')));
  if (!n.sticky) { p.addEventListener('mouseenter', () => hold(n.id)); p.addEventListener('mouseleave', () => release(n.id)); }
  return p;
}
function paintBell(box, notes) {
  const n = notes.length;
  const worst = notes.some((x) => x.tone === 'bad') ? 'bad' : notes.some((x) => x.tone === 'warn') ? 'warn' : '';
  const f = flash && open !== 'list' ? state.notes.get(flash) : null;
  if (open && open !== 'list') open = null;
  const bell = h('button', { type: 'button', class: 'btn sm quiet icon-only note-bell' + (open === 'list' ? ' is-open' : ''), 'data-notes-bell': '',
    'aria-label': n ? n + ' notification' + (n === 1 ? '' : 's') : 'Notifications', title: 'Notifications', 'aria-expanded': open === 'list' ? 'true' : 'false',
    on: { click: () => toggle('list') } }, icon('bell'), n ? h('span', { class: 'note-count' + (worst ? ' ' + worst : '') }, String(n)) : null);
  const flashEl = f ? h('button', { type: 'button', class: 'note-flash ' + toneOf(f), title: textOf(f), on: { click: () => toggle('list') } },
    icon(f.icon || TONE_ICON[toneOf(f)]), h('span', { class: 'np-text' }, textOf(f))) : null;
  box.replaceChildren(...[h('div', { class: 'notes-row' }, flashEl, bell), open === 'list' ? list(notes.slice().reverse(), { clear: true }) : null].filter(Boolean));
}
// A click outside, or Escape, closes an open list or card. (The path, not the target: a click inside has repainted the
// box by the time it reaches the document, so its target is no longer in it.)
document.addEventListener('click', (ev) => { if (open && !ev.composedPath().includes($('notes'))) { open = null; paintNotes(); } });
document.addEventListener('keydown', (ev) => { if (open && ev.key === 'Escape') { open = null; paintNotes(); } });
matchMedia('(max-width: 760px)').addEventListener('change', () => paintNotes());
