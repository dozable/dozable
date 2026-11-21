// components/mac-picker — The machine picker: "Dozable · <this Mac> ▾" in the brand row (and the phone's top bar) opens
// Your Macs — this Mac first ("you are here"), then each Mac kept with `doz ui macs add`, then Add a Mac… and Manage….
//
// Picking a Mac is a PLAIN LINK to its origin and `/` in a new tab (noopener, noreferrer, no referrer): that Mac's own
// sign-in applies there, and nothing of this Mac's — no token, cookie, link, query or fragment — is passed, kept or shown.
// The page never calls another Mac; whether one answered is what the last `doz ui macs check` (or add) recorded. The list
// (GET /api/v1/macs, one read-only operation) is read when the menu opens, and again on `hello` / `changed` while it is
// open — never on a timer.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-47cfabfed13b475c.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { state } from '../core/state-1036883eb74b9520.js';
import { menuButton } from './menus-b8f822d6b7817c72.js';

/// How long a check that found it counts as "seen" (filled dot); older, it is "last seen …".
export const SEEN_FRESH_MS = 10 * 60 * 1000;

const REASONS = {
  'not-dozable': 'something answered, but not a Dozable dashboard',
  redirected: 'it redirects to https — add it with its https:// address',
  refused: 'nothing answered',
  timeout: 'no answer within 3 seconds',
  tls: 'its https certificate was not accepted',
  dns: 'its name was not found',
};

/// What the picker says of one Mac, from what the last check recorded: {fresh, line}.
export function macStatus(m, now = Date.now()) {
  const checked = m.lastCheckAt ? Date.parse(m.lastCheckAt) : NaN;
  if (m.lastResult === 'reachable' && now - checked < SEEN_FRESH_MS) return { fresh: true, line: 'seen ' + when(m.lastCheckAt) };
  if (m.lastResult && m.lastResult !== 'reachable') {
    return { fresh: false, unreachable: true, line: 'couldn’t be reached at the last check: ' + (REASONS[m.lastResult] || 'no answer')
      + (m.lastSeenAt ? ' · last seen ' + when(m.lastSeenAt) : '') + ' · doz ui macs check ' + m.name };
  }
  if (m.lastSeenAt) return { fresh: false, line: 'last seen ' + when(m.lastSeenAt) };
  return { fresh: false, line: 'never checked' };
}

/// The menu's entries for a list read from the server (null: not read yet; an Error: it could not be).
export function macItems(list, origin = location.origin) {
  const here = brandName();
  if (list instanceof Error) {
    return [hereItem(here, null), { sep: true }, { label: 'Your Macs could not be read', icon: 'triangle-alert', disabled: true, why: list.message || String(list) },
      ...tail()];
  }
  if (!list) return [hereItem(here, null), { sep: true }, { label: 'Reading your Macs…', icon: 'hourglass', disabled: true, why: 'a moment' }, ...tail()];
  const self = list.macs.find((m) => m.origin === origin);       // this Mac kept under a name: shown once, as this Mac
  const others = list.macs.filter((m) => m.origin !== origin);
  const items = [hereItem((list.thisMac && list.thisMac.name) || here, self)];
  if (others.length) items.push({ sep: true }, { heading: 'Your Macs' });
  for (const m of others) {
    const st = macStatus(m);
    items.push({
      href: m.origin + '/', target: '_blank', label: m.name,
      lead: h('span', { class: 'mac-dot' + (st.fresh ? ' is-seen' : ''), 'aria-hidden': 'true' }),
      extra: [h('code', { class: 'mac-host' }, m.host), m.scheme === 'http' ? h('span', { class: 'mac-tag' }, 'plain HTTP') : null,
        m.reportedName && m.reportedName.toLowerCase() !== m.name ? h('span', { class: 'mac-says' }, '(says: ' + m.reportedName + ')') : null],
      desc: st.line, trail: h('span', { class: 'mac-open' }, 'Open ', icon('external-link')),
      data: { 'mac-link': m.name, 'mac-state': st.fresh ? 'seen' : st.unreachable ? 'unreachable' : 'unseen' },
    });
  }
  items.push(...tail());
  return items;
}

function hereItem(name, self) {
  return { label: name || 'This Mac', icon: 'check', disabled: true, why: 'this Mac · you are here' + (self ? ' (kept as ' + self.name + ')' : ''),
    data: { 'mac-here': '' } };
}
function tail() {
  return [{ sep: true },
    { href: '#/mac/macs', label: 'Add a Mac…', icon: 'plus', data: { 'mac-add': '' } },
    { href: '#/mac/macs', label: 'Manage…', icon: 'settings', data: { 'mac-manage': '' } }];
}
/// This Mac's name as the page's brand row shows it ("· studio" → studio).
function brandName() {
  const t = (document.getElementById('brand-mac') || {}).textContent || '';
  return t.replace(/^·\s*/, '').trim() || null;
}

const pickers = [];
let last = null;
let reading = null;
async function read() {
  if (reading) return reading;
  reading = api('macs').then((l) => { last = l; return l; }, (e) => { last = e; return e; }).finally(() => { reading = null; });
  return reading;
}
/// Paint every picker with the list as last read. An open one opened from the keyboard (its focus on the button, in its
/// menu, or lost with the item it was on) gets its focus on the first Mac.
function paintAll() {
  for (const p of pickers) {
    const a = document.activeElement;
    const keyboard = p.isOpen() && (a === p.button || p.menu.contains(a) || a === document.body || !a);
    p.setItems(macItems(last));
    if (keyboard && p.focusFirst) { p.focusFirst = false; const f = p.menu.querySelector('.menu-item:not(:disabled)'); if (f) f.focus(); }
  }
}

/// Make `button` (in the page's markup) the picker: its menu, its ▾, the read on open.
export function macPicker(button, opts = {}) {
  const parent = button.parentNode, next = button.nextSibling;
  const caret = h('span', { class: 'brand-caret', 'aria-hidden': 'true' }, icon('chevron-down'));
  (button.querySelector('.brand-line') || button).append(caret);
  button.title = 'Switch Mac — your Macs';
  const ctl = menuButton(button, macItems(last), {
    label: 'Your Macs', align: 'start',
    onOpen: () => { read().then(paintAll); },
  });
  // Opened from the keyboard (Enter, Space — a click with no pointer — or ArrowDown): the focus goes to the first Mac once
  // the list is read.
  button.addEventListener('click', (ev) => { ctl.focusFirst = ev.detail === 0; }, true);
  button.addEventListener('keydown', (ev) => { if (ev.key === 'ArrowDown') ctl.focusFirst = true; }, true);
  ctl.el.classList.add('brand-wrap');
  ctl.menu.classList.add('mac-menu');
  if (opts.top) ctl.menu.classList.add('from-top');
  parent.insertBefore(ctl.el, next);
  pickers.push(ctl);
  return ctl;
}

/// `hello` / `changed`: read the list again only while a picker is open.
export function refreshMacPicker() {
  if (state.signedOut || !pickers.some((p) => p.isOpen())) return;
  read().then(paintAll);
}

/// `g m`: open the picker that is on screen (the top bar's on a phone, else the sidebar's).
export function openMacPicker() {
  const shown = pickers.find((p) => p.button.offsetParent !== null) || pickers[0];
  if (shown) shown.open(true);
}
