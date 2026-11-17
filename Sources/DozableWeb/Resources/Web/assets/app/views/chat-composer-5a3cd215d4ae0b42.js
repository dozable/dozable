// views/chat-composer — the person writes: Enter sends, Shift+Enter (or Option+Enter) starts a new line; one popup above
// the box offers the room's members after an @ and the chat server's commands after a / at the start. A command is the
// server's (it acts on it); /protocol is shown here only and sends nothing.
import { state } from '../core/state-aebab1eadd270ec5.js';
import { chatError, getJSON, request, roomUrl, viewer } from '../core/chat-api-1d17d676033725e8.js';
import { cap, time } from '../core/chat-format-bc877d395788e64c.js';
import { renderMarkdown } from '../core/chat-markdown-f9ea2f2ffddf0e09.js';
import { grow, saveDraft, scheduleDraft } from '../components/chat-composer-box-8729e13adb58fd90.js';
import { toFoot } from '../components/chat-log-cc2f838d26f73fa3.js';
import { watchTables } from '../components/chat-tables-e57e43edc3e205ea.js';
import { avatar } from '../dom/chat-avatar-361c05fc193f626a.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';

const CMDS = [
  { cmd: '/dm ', help: 'A direct message: /dm @name the text. Only they see it.' },
  { cmd: '/room ', help: 'Make a new room: /room name @member @member.' },
  { cmd: '/archive', help: 'Make this room read-only. Its history stays.' },
  { cmd: '/unarchive', help: 'Open an archived room again.' },
  { cmd: '/invite ', help: 'Add a participant to this room: /invite @name.' },
  { cmd: '/remove ', help: 'Take a participant out of this room: /remove @name.' },
  { cmd: '/hold ', help: 'Limit agent-only chatter: /hold on, /hold 12, or /hold off.' },
  { cmd: '/protocol', help: 'Show the message protocol here. Nothing is sent.' },
];
let cmdAt = 0;
const presenceOf = (n) => state.chat.presence.find((p) => p.name === n) || {};
const roomMembers = () => (state.chat.srv && state.chat.srv.rooms[state.chat.room]) || [];

/// What the line under the box says: a refusal or a state, else how the box works.
const HINT = 'Enter sends · Shift+Enter starts a new line · @ names someone · / lists commands';
function note(text, bad) {
  const n = $('chat-note');
  n.textContent = text || HINT;
  n.classList.toggle('is-bad', !!bad);
}

function mentionAt() {
  const t = $('chat-text'), upto = t.value.slice(0, t.selectionStart), m = /(^|[\s(])@([A-Za-z0-9_-]*)$/.exec(upto);
  return m ? { start: upto.length - m[2].length - 1, word: m[2].toLowerCase() } : null;
}
function popupList() {
  const v = $('chat-text').value;
  const others = roomMembers().filter((n) => n !== viewer());
  if (v.startsWith('/') && !/\s/.test(v)) return CMDS.filter((c) => c.cmd.startsWith(v)).map((c) => ({ kind: 'cmd', label: c.cmd.trim(), help: c.help, cmd: c.cmd }));
  const at = mentionAt();
  if (!at) return [];
  return others.filter((n) => n.startsWith(at.word)).map((n) => {
    const p = presenceOf(n);
    return { kind: 'who', label: '@' + n, help: (p.state || '') + (p.kind && p.kind !== 'human' ? ' · ' + String(p.kind).replace('-', ' ') : ''), name: n, at };
  });
}
function showCmds() {
  const list = popupList(), box = $('chat-cmds'), t = $('chat-text');
  if (!list.length) { box.hidden = true; t.removeAttribute('aria-activedescendant'); t.setAttribute('aria-expanded', 'false'); return; }
  cmdAt = Math.min(cmdAt, list.length - 1);
  box.replaceChildren(...list.map((c, i) => {
    const row = h('div', { class: 'chat-cmd' + (i === cmdAt ? ' is-on' : ''), role: 'option', id: 'chat-cmd-' + i, 'aria-selected': i === cmdAt ? 'true' : 'false' },
      c.kind === 'who' ? avatar(presenceOf(c.name).avatar, c.name, 'sm') : null,
      h('code', { class: 'chat-cmd-label' }, c.label), h('span', { class: 'chat-cmd-help' }, c.help));
    row.addEventListener('mousedown', (e) => { e.preventDefault(); pick(c); });
    return row;
  }));
  box.hidden = false;
  t.setAttribute('aria-expanded', 'true');
  t.setAttribute('aria-activedescendant', 'chat-cmd-' + cmdAt);
}
function pick(c) {
  const t = $('chat-text');
  $('chat-cmds').hidden = true;
  if (c.kind === 'who') {
    const end = t.selectionStart, ins = '@' + c.name + ' ';
    t.value = t.value.slice(0, c.at.start) + ins + t.value.slice(end);
    const pos = c.at.start + ins.length;
    t.focus();
    t.setSelectionRange(pos, pos);
    return;
  }
  t.value = c.cmd;
  t.focus();
  if (c.cmd === '/protocol') $('chat-form').requestSubmit();
}

/// /protocol for the person: shown in the log only, never sent to the room.
async function showProtocol() {
  try {
    const p = await getJSON('/protocol');
    const lp = p.line_port || {};
    const text = ['**Message protocol, version ' + p.version + '**', '', p.what, '', p.format, '', p.trust, '',
      '**An agent on the line port** ' + (lp.how || ''), '', '**Commands:** ' + Object.entries(p.commands || {}).map(([k, v]) => '`' + k + '` (' + v + ')').join(', '), '',
      '**Reactions:** ' + ((p.reactions || {}).standard || []).join(', ') + ', or any emoji.', '',
      '**States:** ' + Object.entries(p.delivery_states || {}).map(([k, v]) => '`' + k + '` ' + v).join('; ') + '.'].filter((x) => x !== undefined).join('\n');
    const body = h('div', { class: 'chat-md' });
    body.append(renderMarkdown(text));
    watchTables(body);
    const card = h('div', { class: 'chat-local' }, h('div', { class: 'chat-tag' }, 'Only you see this · not sent to the room · ' + time(Date.now() / 1000)), body);
    const log = $('chat-log'), foot = log.querySelector('.chat-status.is-now');
    if (foot) log.insertBefore(card, foot); else log.append(card);
    card.scrollIntoView({ block: 'start' });
  } catch (e) { note('The protocol could not be read: ' + (e.message || e), true); }
}

async function send(ev) {
  ev.preventDefault();
  const t = $('chat-text'), text = t.value.trim();
  $('chat-cmds').hidden = true;
  if (!text || !state.chat.room) return;
  if (text === '/protocol') { t.value = ''; grow(); showProtocol(); return; }
  // Leading @names address the message to those members (as the chat server's own page does); an unknown one stops it.
  const to = [], members = roomMembers();
  if (!/^\/(dm|hold)(\s|$)/.test(text)) {
    for (const w of text.split(/\s+/)) {
      if (w[0] !== '@') break;
      const n = w.slice(1).replace(/[,:.]$/, '').toLowerCase();
      if (members.includes(n)) to.push(n); else { note('No participant @' + n + ' in this room. Nothing was sent.', true); return; }
    }
  }
  const btn = $('chat-send');
  btn.disabled = true;
  try {
    const r = await request(roomUrl(state.chat.room, '/messages'), { method: 'POST', json: to.length ? { content: text, to } : { content: text } });
    if (!r.ok) throw await chatError(r);
    const j = await r.json();
    t.value = '';
    saveDraft();
    grow();
    toFoot();
    note(j.state && j.state !== 'queued' && j.state !== 'delivered' ? cap(j.state) + (j.detail ? ': ' + j.detail : '') : '');
  } catch (e) {
    note('Not sent: ' + (e.message || e), true);
  } finally { btn.disabled = false; }
}

export function initComposer() {
  const t = $('chat-text');
  t.addEventListener('input', () => { cmdAt = 0; showCmds(); grow(); scheduleDraft(); });
  t.addEventListener('click', showCmds);
  t.addEventListener('blur', () => setTimeout(() => { $('chat-cmds').hidden = true; t.setAttribute('aria-expanded', 'false'); }, 120));
  t.addEventListener('keydown', (e) => {
    const box = $('chat-cmds');
    if (!box.hidden) {
      const list = popupList();
      if (list.length) {
        if (e.key === 'ArrowDown') { e.preventDefault(); cmdAt = (cmdAt + 1) % list.length; showCmds(); return; }
        if (e.key === 'ArrowUp') { e.preventDefault(); cmdAt = (cmdAt + list.length - 1) % list.length; showCmds(); return; }
        if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey && !e.metaKey && !e.ctrlKey)) { e.preventDefault(); pick(list[cmdAt]); return; }
        if (e.key === 'Escape') { e.preventDefault(); box.hidden = true; return; }
      }
    }
    if (e.key !== 'Enter' || e.isComposing) return;
    if (e.shiftKey) return;                                   // the browser adds the new line
    if (e.altKey) {
      e.preventDefault();
      const a = t.selectionStart;
      t.value = t.value.slice(0, a) + '\n' + t.value.slice(t.selectionEnd);
      t.setSelectionRange(a + 1, a + 1);
      grow();
      return;
    }
    e.preventDefault();
    $('chat-form').requestSubmit();
  });
  $('chat-form').addEventListener('submit', send);
  note('');
  window.addEventListener('pagehide', saveDraft);
}
