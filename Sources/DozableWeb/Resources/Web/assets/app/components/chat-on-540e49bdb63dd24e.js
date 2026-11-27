// components/chat-on — the ONE way the page turns chat on: the typed action `chat-on` (exactly what `doz chat on --name NAME`
// does: you named first when you have no name yet, `chat.enabled` set, then the chat server until it is ready), followed to
// its end. Wherever the page says chat is off — the Chat page and a workspace's Room tab, a workspace's set-up item "a
// manager needs chat", the New workspace wizard's room and its gap — it offers this: the form (your name in chat, shown
// only while you have none, filled with the name `doz chat on` would give you; "Turn chat on"; its errors inline in
// Dozable's words; the terminal's command beneath) or, inline, the button alone. Another computer sees only the command:
// chat is turned on in this Mac's own browser, or in a terminal on the Mac. Turning chat off stays a terminal's.
import { apiFetch } from '../core/api-496fd9f39af2a514.js';
import { actOrThrow, waitForOp } from '../core/operations-d4d2df05019ab596.js';
import { isRemote } from '../core/session-d8c1f2499724d91c.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { cmdLine } from './cmd-line-297cfdc0127faef7.js';

/// The command a terminal would type (`name`: yours, when you name yourself here).
export const chatOnCommand = (name) => 'doz chat on --name ' + (name || 'YOUR-NAME');

/// The names chat/status gives this Mac's browser while chat is off: `named` (you have one) or `suggestedName`.
let lastStatus = null;
export function rememberChatStatus(st) { if (st) lastStatus = st; }

/// Turn chat on: `{ok: true, name}` or `{error: words}`.
export async function turnChatOn(name) {
  if (isRemote()) return { error: 'Chat is turned on only in this Mac’s own browser, or in a terminal on the Mac.' };
  const body = { action: 'chat-on' };
  if (name) body.name = name;
  try {
    const end = await waitForOp(await actOrThrow(body), 120);
    if (!end) return { error: 'No answer yet — Operations shows how it ends.' };
    if (end.state !== 'done') return { error: end.text || 'Chat did not come on.' };
    return { ok: true, name };
  } catch (e) { return { error: (e && e.message) || String(e) }; }
}

/// The form for a "chat is off" callout. `opts.onOn(name)`: chat is on (the view reads again); `opts.status`: chat/status.
export function chatOnForm(opts = {}) {
  const st = opts.status || lastStatus || {};
  const wrap = h('div', { class: 'chat-on', 'data-chat-on': '' });
  if (isRemote()) {
    wrap.append(h('span', null, 'Turn it on in a terminal on the Mac: '), cmdLine(chatOnCommand()));
    return wrap;
  }
  const needsName = !st.named;
  // (`field` is read again at the click: once the status says you have a name, it is gone and no name is sent.)
  const field = needsName ? h('input', { type: 'text', class: 'chat-on-name', 'data-chat-on-name': '', value: st.suggestedName || '', maxlength: '40',
    autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Your name in chat' }) : null;
  const err = h('p', { class: 'chat-on-error', role: 'alert', 'data-chat-on-error': '', hidden: true });
  const go = h('button', { type: 'button', class: 'btn primary', 'data-chat-on-go': '' }, icon('power'), 'Turn chat on');
  const cmd = h('div', { class: 'chat-on-cmd' }, h('span', { class: 'muted' }, 'Or in a terminal: '), cmdLine(chatOnCommand(field ? field.value.trim() : '')));
  const row = h('div', { class: 'chat-on-row' });
  if (field) {
    row.append(h('label', { class: 'chat-on-label' }, h('span', null, 'Your name in chat'), field));
    field.addEventListener('input', () => { err.hidden = true; cmd.replaceChildren(h('span', { class: 'muted' }, 'Or in a terminal: '), cmdLine(chatOnCommand(field.value.trim()))); });
    field.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); go.click(); } });
  }
  row.append(go);
  let known = Promise.resolve();
  go.addEventListener('click', async () => {
    await known;   // the status read below, when one is under way: your name or none
    const named = !field || !field.isConnected;
    const name = named ? '' : field.value.trim();
    if (!named && !name) { err.textContent = 'Say your name in chat: a lower-case letter, then lower-case letters, digits and -.'; err.hidden = false; field.focus(); return; }
    go.disabled = true; if (field) field.disabled = true;
    go.replaceChildren(icon('hourglass'), 'Turning chat on…');
    const r = await turnChatOn(name || null);
    if (r.ok) { if (opts.onOn) opts.onOn(name || null); return; }
    go.disabled = false; if (field) field.disabled = false;
    go.replaceChildren(icon('power'), 'Turn chat on');
    err.textContent = r.error;
    err.hidden = false;
  });
  wrap.append(row, err, cmd);
  // No status given (the wizard, a workspace's page): read it — your name once you have one, else the one to suggest.
  if (!opts.status && field) {
    known = apiFetch('chat/status').then((r) => (r.ok ? r.json() : null)).then((st2) => {
      if (!st2) return;
      rememberChatStatus(st2);
      if (st2.named) { field.closest('label').remove(); field.value = ''; } else if (!field.value && st2.suggestedName) field.value = st2.suggestedName;
    }).catch(() => { /* the field stays as it is */ });
  }
  return wrap;
}

/// The inline button (a set-up item, a wizard's gap): "Turn chat on", with no name asked — `doz chat on`'s own name when you
/// have none — its error beside it. Another computer: nothing (the item's command says it).
export function chatOnInline(opts = {}) {
  if (isRemote()) return null;
  const err = h('span', { class: 'chat-on-error', role: 'alert', 'data-chat-on-error': '', hidden: true });
  const go = h('button', { type: 'button', class: 'btn sm', 'data-chat-on-inline': '' }, icon('power'), 'Turn chat on');
  go.addEventListener('click', async () => {
    go.disabled = true;
    go.replaceChildren(icon('hourglass'), 'Turning chat on…');
    const r = await turnChatOn(null);
    if (r.ok) { if (opts.onOn) opts.onOn(null); return; }
    go.disabled = false;
    go.replaceChildren(icon('power'), 'Turn chat on');
    err.textContent = r.error;
    err.hidden = false;
  });
  return h('span', { class: 'chat-on-inline' }, go, err);
}
